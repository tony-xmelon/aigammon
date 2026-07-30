/// The `MatchTransport` seam: the ONE pipe both LAN (socket relay) and online
/// (Firestore) play flow through, so a single match controller can drive either.
///
/// ## What a transport is (and is not)
///
/// A transport is a DUMB PIPE. It carries two kinds of frame between the two
/// peers of a match — seq-numbered [EventFrame]s (the append-only game log) and
/// the three-message commit-reveal [RollFrame] handshake (see `fair_dice.dart`)
/// — plus a connection signal. It does NOT referee: it never validates a move,
/// never derives dice, never decides whose turn it is. Both peers run the same
/// controller, and that controller is the referee (mutual validation + a freeze
/// on a proven cheat). Whoever binds the LAN socket is a network role, not a
/// game authority.
///
/// This is why the online trust model (commit-reveal fair dice + per-event
/// validation, so neither peer trusts the other) can subsume LAN's old
/// host-authoritative model: the transport shrinks to exactly the surface below,
/// and everything above it is shared.
///
/// ## The fold / resync contract (normative — every transport guarantees it)
///
/// This contract is what lets one controller fold a socket stream and a
/// Firestore stream through identical code:
///
///  * **Event seq is strictly increasing and contiguous from 1.** Every
///    committed [EventFrame] is delivered on [inbound] AT LEAST ONCE — duplicates
///    are possible, and the device's OWN events are delivered back to it too (the
///    fold advances on them). The controller folds in seq order and ignores any
///    frame whose `seq <= lastFolded`. A transport whose native index is 0-based
///    (the shipped Firestore `events/{seq}` model) maps onto this 1-based seq
///    space; `eventsSince(0)` therefore means "the whole log".
///  * **A gap is closed by [eventsSince], never incrementally.** If an
///    [EventFrame] arrives with `seq > lastFolded + 1`, earlier events were
///    missed. `eventsSince(lastFolded)` returns EXACTLY the events with
///    `seq > afterSeq`, ascending and contiguous — a full authoritative answer,
///    not a delta that could itself have holes. (A full replace-from-log is the
///    only recovery path; there is no server snapshot to seed from.)
///  * **[inbound] carries no history.** It is live-from-now, so the controller
///    PRIMES its fold with `eventsSince(0)` (+ [rollsSince]) right after
///    [connect] rather than assuming a replayed backlog, and re-primes whenever
///    a [ResetFrame] says to.
///  * **A [ResetFrame] means "throw your fold away and replay from the log".**
///    It arrives UNPROMPTED — after a reconnect, or when the match identity
///    changed under us (a host restart, a room-code collision). Its
///    `resumeToken` is the authority's current one: a token that differs from
///    the one the controller has been folding under invalidates every per-match
///    watermark — AND the session, so such a frame MUST carry
///    [ResetFrame.session] (the new match's config and seats).
///  * **[inbound] may emit errors WITHOUT closing.** A transient read failure
///    surfaces as a [TransportUnavailable] on the stream and the stream keeps
///    running; the controller shows a banner and folds on. A transport never
///    ends [inbound] to signal trouble — that is what [status] is for.
///  * **A [RollFrame]'s `n` is the roll index** (1-based: `n` is
///    `1 + roll-bearing events folded so far`). A roll advances through the
///    phases committed → entropy → reveal, and the transport RE-EMITS its
///    [RollFrame] on [inbound] each time a phase lands. The controller can also
///    pull the current frame at any time with [fetchRoll], which returns the
///    exact current document (or null if roll `n` does not exist yet).
///  * **Ordering promised WITHIN a kind, not across kinds.** [EventFrame]s are
///    ordered among themselves by seq; a roll's phases arrive in order. The
///    interleaving of events and rolls is NOT promised (and neither is the
///    absence of duplicates), so the controller must tolerate a roll event
///    arriving before its roll document and fetch it ([fetchRoll]) when it does.
///  * **Writes are optimistic and index-claimed.** [sendEvent] at a taken seq and
///    [createRoll] at a taken `n` throw [TransportContested] — the caller resyncs
///    and retries at the next free index. A roll-phase write the relay/rules
///    refuse (entropy on one's own roll, a second reveal, …) throws
///    [TransportRejected] and must NEVER be retried.
///  * **A write resolves only once it is COMMITTED.** `await sendEvent(...)`
///    returning normally means the entry is in the log and will come back on
///    [inbound]; it does NOT mean merely "handed to the socket". A write that did
///    not reach the log throws — [TransportUnavailable] when it may or may not
///    have landed (retry after a resync), [TransportContested]/[TransportRejected]
///    when it definitively did not. This is what lets one controller gate its UI
///    on a single `await` on both substrates.
///
/// A transport that honours all of the above is interchangeable with any other —
/// and that is CHECKED, not asserted: `lib/transport_contract.dart` turns the
/// clauses above into one reusable suite, which runs against [InMemoryTransport]
/// (this package), `SocketTransport` over a real loopback socket (`lan_play`) and
/// `FirestoreTransport` against the emulator (`online_client`). Add a clause here
/// and add it there.
library;

import 'package:backgammon_core/backgammon_core.dart';

import 'fair_dice.dart';

// ---------------------------------------------------------------------------
// Match configuration
// ---------------------------------------------------------------------------

/// The match parameters the two peers agree on: fixed for the match's life.
///
/// Deliberately the same two fields both shipped transports already carry
/// (online's `MatchDoc.length`/`cubeless`, LAN's `MatchConfig`), so neither
/// implementation loses information mapping onto it.
class MatchConfig {
  const MatchConfig({required this.length, this.cubeless = false});

  /// Match length in points (odd, 1..25). `1` is a single game.
  final int length;

  /// True for a cubeless match (no doubling cube).
  final bool cubeless;

  @override
  bool operator ==(Object other) =>
      other is MatchConfig &&
      other.length == length &&
      other.cubeless == cubeless;

  @override
  int get hashCode => Object.hash(length, cubeless);

  @override
  String toString() => 'MatchConfig(length: $length, cubeless: $cubeless)';
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// The result of [MatchTransport.connect]: everything the controller needs to
/// start folding, none of it changing for the match's life.
///
/// Seats are POSITIONAL and identical on both transports: the host plays
/// [hostSide] ([Player.white]) and the joiner plays its opposite. That single
/// convention is what lets the controller map an author identity to a seat
/// ([sideOf]) — which it must, to validate that an event's author holds the seat
/// the event claims, and that an opening roll came from the host.
class TransportSession {
  const TransportSession({
    required this.assignedSide,
    required this.config,
    required this.localAuthor,
    required this.hostAuthor,
    required this.matchCode,
    this.guestAuthor,
    this.resumeToken,
  });

  /// The seat this device plays (== `sideOf(localAuthor)`).
  final Player assignedSide;

  /// The match's HUMAN-FACING handle — online's invite code, LAN's room code.
  ///
  /// Distinct from [resumeToken] (a durability handle): this is what the UI
  /// shows and what a history record is keyed by.
  final String matchCode;

  /// The agreed match parameters.
  final MatchConfig config;

  /// This device's identity in the author/roller space shared by every
  /// [EventFrame.author] and [RollFrame.roller].
  final String localAuthor;

  /// The host's identity — the [hostSide] seat. The opening roller by
  /// convention, and never null (the host is always present).
  final String hostAuthor;

  /// The joiner's identity — the [hostSide]-opposite seat. Null until the
  /// opponent has joined (only relevant to a transport that can start before the
  /// second seat is filled).
  final String? guestAuthor;

  /// A durable handle to THIS match, echoed on reconnect/resume.
  ///
  /// For a [Capabilities.durable] transport it identifies the match across a
  /// restart; a resume token that differs from the one a match was folding under
  /// means the identity changed (host restarted, room-code collision) and the
  /// controller must reset its per-match watermarks. Null for a transport that
  /// cannot resume.
  final String? resumeToken;

  /// The seat the host plays; the joiner plays [Player.black]. A fixed
  /// convention across LAN and online.
  static const Player hostSide = Player.white;

  /// True when this device is the host (the [hostSide] seat, the opening roller).
  bool get isHost => localAuthor == hostAuthor;

  /// The seat [author] holds, or null if [author] is neither participant.
  ///
  /// The one mapping the controller cannot derive on its own, and the reason the
  /// seat identities travel on the session: it turns an opaque author string on
  /// an inbound frame into a [Player] it can check the frame against.
  Player? sideOf(String author) {
    if (author == hostAuthor) return hostSide;
    if (guestAuthor != null && author == guestAuthor) return hostSide.opponent;
    return null;
  }
}

// ---------------------------------------------------------------------------
// Inbound frames
// ---------------------------------------------------------------------------

/// A frame delivered on [MatchTransport.inbound]: an [EventFrame] (a log entry),
/// a [RollFrame] (a commit-reveal roll at some phase) or a [ResetFrame]
/// (discard the fold and replay).
sealed class InboundFrame {
  const InboundFrame();
}

/// "Throw your fold away and replay from the log."
///
/// The one frame that is not data but an instruction, and the only one that
/// arrives UNPROMPTED: a transport emits it when it can no longer promise that
/// what the controller folded so far is a prefix of the authority's log — after
/// a reconnect that may have skipped frames, or when the match identity changed
/// underneath us (a host restarted on the same room code; a durable match was
/// re-opened elsewhere).
///
/// The controller responds by re-priming (`eventsSince(0)` + [
/// MatchTransport.rollsSince]) and folding the answer from scratch. If
/// [resumeToken] differs from the token the controller has been folding under,
/// the MATCH IDENTITY changed and every per-match watermark
/// (persisted-through / acknowledged-through / match-persisted) must be reset
/// too, so the new match is not silently written into the old one's row.
///
/// An identity change also invalidates the [TransportSession] itself — a
/// different match has its own [MatchConfig] (length, cubeless) and its own seat
/// assignment — which is why [session] exists and why carrying it is NORMATIVE
/// whenever [resumeToken] differs. Replaying a different match's log under the
/// old config is not a cosmetic error: the fold would seed [MatchState] with the
/// wrong match length, and a stale `cubeless` flag turns the opponent's
/// perfectly legal double into a `cube-in-cubeless` freeze.
final class ResetFrame extends InboundFrame {
  const ResetFrame({this.resumeToken, this.reason, this.session});

  /// The authority's CURRENT resume token, or null for a transport that has
  /// none. Compare against the folding token to detect an identity change.
  final String? resumeToken;

  /// Why the reset happened, for logs and the connection chip.
  final String? reason;

  /// The authority's CURRENT session — config and seat identities included.
  ///
  /// MUST be non-null when [resumeToken] differs from the token the controller
  /// has been folding under (see the class doc); optional, and simply re-adopted,
  /// when the identity is unchanged. A controller that receives a session-less
  /// identity change re-reads the session with [MatchTransport.connect] rather
  /// than replaying a new match under the old one's parameters.
  final TransportSession? session;

  @override
  String toString() => 'ResetFrame(token: $resumeToken, reason: $reason)';
}

/// One append-only log entry: a [GameEvent] stamped with its match-wide [seq],
/// the [gameNo] it belongs to, and the identity that [author]ed it.
///
/// Shaped exactly like online's `RemoteEvent` and LAN's `LogEntry` (the two it
/// unifies), so the controller's fold is transport-agnostic. [author] is what
/// the folding peer checks against [TransportSession.sideOf].
final class EventFrame extends InboundFrame {
  const EventFrame({
    required this.seq,
    required this.gameNo,
    required this.event,
    required this.author,
  });

  /// Strictly increasing across the whole match, contiguous from 1.
  final int seq;

  /// 1-based game number within the match.
  final int gameNo;

  final GameEvent event;

  /// The identity that appended this entry (transport-authenticated).
  final String author;

  @override
  String toString() =>
      'EventFrame(seq: $seq, gameNo: $gameNo, author: $author, '
      'event: ${event.runtimeType})';
}

/// One commit-reveal roll document at whatever phase it has reached.
///
/// [commit] is present the moment the roll exists (a roll is CREATED with its
/// commitment — see [MatchTransport.createRoll]); [entropy] and [reveal] fill in
/// as the handshake advances. The frame is re-emitted on [inbound] at each new
/// phase. The derivation helpers ([completed]/[phase]/[isComplete]) mirror
/// online's `RollDoc` so the controller reuses them unchanged.
final class RollFrame extends InboundFrame {
  const RollFrame({
    required this.n,
    required this.roller,
    required this.commit,
    this.entropy,
    this.reveal,
  });

  /// The roll index (1-based).
  final int n;

  /// The identity of the player whose roll this is (the committer).
  final String roller;

  /// The roller's commitment. Non-null whenever the frame exists.
  final String commit;

  /// The witness's entropy, once contributed.
  final String? entropy;

  /// The roller's revealed secret, once published.
  final String? reveal;

  /// True once all three protocol values are present.
  bool get isComplete => entropy != null && reveal != null;

  /// The phase this roll has reached, in the vocabulary of `fair_dice.dart`.
  FairDicePhase get phase {
    if (reveal != null) return FairDicePhase.revealed;
    if (entropy != null) return FairDicePhase.entropy;
    return FairDicePhase.committed;
  }

  /// The finished roll (for deriving/validating dice), or null while a phase is
  /// still outstanding. Verifying the commitment is the caller's job — see
  /// [CompletedRoll].
  CompletedRoll? get completed => isComplete
      ? CompletedRoll(
          commit: commit, entropy: entropy!, reveal: reveal!, index: n)
      : null;

  @override
  String toString() =>
      'RollFrame(n: $n, roller: $roller, phase: ${phase.name})';
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

/// The transport's connection lifecycle, as the UI's connection chip sees it.
///
/// The same vocabulary LAN's `GuestConnectionStatus` already uses (including
/// [busy], which the shipped UI branches on and which [reconnecting] cannot
/// express: the link is healthy, the ROOM is occupied). The app controller
/// adapts this pure-Dart signal to a `ValueListenable` for the widget layer.
enum TransportStatus {
  /// The first connection attempt is in flight; nothing has folded yet.
  connecting,

  /// Connected and live — frames flow.
  connected,

  /// The link dropped and a retry is under way. Play continues once it clears.
  reconnecting,

  /// The link works but the match cannot be entered yet — a relay whose single
  /// guest slot is taken. Self-clearing: the transport keeps retrying.
  busy,

  /// Terminally failed; retrying cannot help (wrong room, protocol mismatch).
  failed;

  /// True for the states where frames are NOT flowing but the transport is
  /// still trying — a banner, not a gate.
  bool get isTransient =>
      this == connecting || this == reconnecting || this == busy;
}

/// A [TransportStatus] transition, carrying the reason when there is one.
///
/// Emitted on [MatchTransport.statusStream], which carries the status and its
/// reason TOGETHER so a listener never has to read [MatchTransport.statusReason]
/// back out of the transport and risk seeing a later transition's reason.
/// [MatchTransport.status]/[MatchTransport.statusReason] mirror the last event
/// for a caller that only wants the current value (LAN carries these reason
/// strings today).
class TransportStatusEvent {
  const TransportStatusEvent(this.status, [this.reason]);

  final TransportStatus status;

  /// Why the link is reconnecting, busy or failed; null for the happy
  /// transitions.
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is TransportStatusEvent &&
      other.status == status &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(status, reason);

  @override
  String toString() => reason == null
      ? 'TransportStatusEvent(${status.name})'
      : 'TransportStatusEvent(${status.name}: $reason)';
}

// ---------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------

/// What a transport can and cannot do beyond carrying frames — the two axes the
/// controller branches on.
class Capabilities {
  const Capabilities({required this.durable, required this.rejoinable});

  /// The match survives the app process ending and can be re-opened later
  /// (Firestore: yes; a socket: no). Gates whether resume tokens mean anything.
  final bool durable;

  /// A peer that dropped can rejoin the SAME live match mid-play (Firestore:
  /// yes, both peers re-read the log; a socket: no, the session ends with the
  /// connection). Gates the controller's durable-rejoin path.
  final bool rejoinable;

  @override
  String toString() =>
      'Capabilities(durable: $durable, rejoinable: $rejoinable)';
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// The base of the three typed transport faults. Sealed: a caller can switch
/// exhaustively on the meaning rather than string-matching a code.
sealed class TransportException implements Exception {
  const TransportException(this.code, this.message, {this.peerLastSeq});

  /// A stable machine code (e.g. the mapped-from backend status).
  final String code;

  /// A human-readable description.
  final String message;

  /// The authority's last committed seq, WHEN THE REFUSAL REPORTS IT (a LAN
  /// `reject` does). `peerLastSeq > lastFolded` tells the caller it is behind
  /// and should resync rather than merely surface the error. Null when unknown.
  final int? peerLastSeq;

  @override
  String toString() => peerLastSeq == null
      ? '$runtimeType($code): $message'
      : '$runtimeType($code): $message (peerLastSeq: $peerLastSeq)';
}

/// The relay or the security rules REFUSED the operation, and an identical retry
/// would fail identically: a phase-skip on a roll, a write to the wrong seat, a
/// non-participant access. Never retryable.
///
/// (Maps online's `PermissionDeniedException` and a LAN `reject` level with our
/// seq.)
final class TransportRejected extends TransportException {
  const TransportRejected(super.code, super.message, {super.peerLastSeq});
}

/// A create LOST THE RACE for a write-once index: [MatchTransport.sendEvent] at a
/// taken seq, or [MatchTransport.createRoll] at a taken roll `n`. Our view of the
/// log is behind — the caller resyncs ([MatchTransport.eventsSince]) and retries
/// at the next free index.
///
/// (Maps online's `AlreadyExistsException` and a LAN `reject` whose `lastSeq` is
/// ahead of ours.)
final class TransportContested extends TransportException {
  const TransportContested(super.code, super.message, {super.peerLastSeq});
}

/// A TRANSIENT failure — a dropped socket, a poll blip, a timeout. Self-heals on
/// the next successful exchange; the caller surfaces it as a banner, not a gate.
final class TransportUnavailable extends TransportException {
  const TransportUnavailable(super.code, super.message);
}

// ---------------------------------------------------------------------------
// The interface
// ---------------------------------------------------------------------------

/// The one pipe a match controller drives, implemented once per network
/// substrate (socket relay, Firestore). See the library doc for the fold/resync
/// contract every implementation guarantees.
///
/// Lifecycle: [connect] once, then fold [inbound] and drive rolls/events;
/// [eventsSince]/[fetchRoll] are the resync pulls; [complete] is end-of-match
/// bookkeeping; [dispose] tears everything down. All I/O methods may throw a
/// [TransportException] (typically the three typed subclasses).
abstract class MatchTransport {
  /// Establish the session — sign in / handshake / bind — and return the
  /// [TransportSession] (assigned seat, config, resume token, seat identities).
  ///
  /// After this resolves, [status] is [TransportStatus.connected] and [inbound]
  /// is live. Idempotent-friendly: calling it again returns the current session.
  Future<TransportSession> connect();

  /// The live frame stream: [EventFrame]s and [RollFrame]s, at least once, per
  /// the fold/resync contract. BROADCAST — the controller may listen, cancel and
  /// re-listen (a resync) without tearing the transport down.
  Stream<InboundFrame> get inbound;

  /// Append [event] to the log at [seq] (the caller's `lastFolded + 1`).
  ///
  /// Throws [TransportContested] if [seq] is already taken (resync and retry at
  /// the next free index).
  Future<void> sendEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  });

  /// Phase 1 — create roll [n] carrying the roller's [commit].
  ///
  /// Throws [TransportContested] if roll [n] already exists.
  Future<void> createRoll(int n, String commit);

  /// Phase 2 — contribute the witness's [entropy] to roll [n].
  ///
  /// Throws [TransportRejected] if the relay/rules refuse it (own roll, twice,
  /// after a reveal) — never retryable.
  Future<void> sendEntropy(int n, String entropy);

  /// Phase 3 — publish the roller's [reveal] for roll [n].
  ///
  /// Throws [TransportRejected] if refused (not the roller, before entropy,
  /// twice).
  Future<void> sendReveal(int n, String reveal);

  /// Resync pull: EXACTLY the events with `seq > afterSeq`, ascending and
  /// contiguous. The authoritative answer that closes a gap.
  Future<List<EventFrame>> eventsSince(int afterSeq);

  /// Resync pull: the current [RollFrame] for roll [n], or null if it does not
  /// exist yet.
  Future<RollFrame?> fetchRoll(int n);

  /// Resync pull: every roll with index `>= from`, ascending.
  ///
  /// The bulk companion to [fetchRoll], so a full replace-from-log costs ONE
  /// round trip for the rolls instead of one per roll (the shipped online
  /// controller's `fetchRollsFrom(code, 1)`).
  Future<List<RollFrame>> rollsSince(int from);

  /// End-of-match bookkeeping (e.g. flip the match document to complete). Best
  /// effort — the event log remains the authority — so a failure here is
  /// swallowed by the caller.
  Future<void> complete();

  /// The connection-lifecycle stream, each event carrying its reason. Pairs with
  /// [status]/[statusReason], which are updated in lockstep BEFORE each event is
  /// emitted.
  Stream<TransportStatusEvent> get statusStream;

  /// The current connection status.
  TransportStatus get status;

  /// Why the link is [TransportStatus.reconnecting] or [TransportStatus.failed],
  /// or null for the healthy states. Read alongside [status].
  String? get statusReason;

  /// Whether the OPPONENT is currently present in the match.
  ///
  /// Orthogonal to [status], which is this device's own link health: a bound
  /// host can be perfectly [TransportStatus.connected] while nobody has joined
  /// yet, or after the guest walked away. Two behaviours need it — the host must
  /// not open the match with a roll before a joiner exists, and the connection
  /// chip must say "waiting for opponent" rather than "connected".
  ///
  /// Starts false, and for a transport that cannot tell (a pure relay with no
  /// presence signal) stays true once [connect] resolves — documented per
  /// implementation.
  bool get opponentPresent;

  /// The [opponentPresent] change stream (broadcast).
  Stream<bool> get opponentPresence;

  /// What this transport can do beyond carrying frames — see [Capabilities].
  Capabilities get capabilities;

  /// How long the transport currently expects to take to notice a remote change
  /// — a poll interval, or [Duration.zero] for a push transport.
  ///
  /// The controller reuses it as the beat for its OWN self-healing retries (a
  /// roll whose document has not landed yet), so a fast-polling transport heals
  /// fast and a slow one does not spin.
  Duration get inboundCadence;

  /// Hint that latency matters right now (`fast: true`, a dice handshake in
  /// flight) or no longer does (`fast: false`, waiting on the opponent).
  ///
  /// Advisory: a polling transport switches interval (and so changes
  /// [inboundCadence]); a socket or listener transport ignores it. This is the
  /// ONLY pacing lever the controller has — everything else about read budget
  /// (which seq to resume from, which finished rolls never to re-read) is the
  /// transport's own business, not the controller's.
  void setPaceHint({required bool fast});

  /// Release everything (sockets, streams, timers). Idempotent, and awaitable
  /// because a socket close is asynchronous.
  Future<void> dispose();
}
