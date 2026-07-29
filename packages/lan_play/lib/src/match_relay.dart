import 'dart:async';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/match_transport.dart';

import 'protocol.dart';

/// The bound peer's whole game-side responsibility: an append-only event log,
/// the commit-reveal roll documents, and a stream of what has been committed.
///
/// ## It is a RELAY, not a referee (Plan 17)
///
/// This replaces `HostAuthority`, and the deletion is the point of the whole
/// unification. The relay does NOT:
///
///  * validate a move, a cube action or a resignation (no rules engine here at
///    all — [Game] is never constructed);
///  * decide whose turn it is, or refuse an out-of-turn write;
///  * generate a die, or hold a [Random] for anything but its resume token;
///  * compute a game or match result.
///
/// Every one of those is now enforced by BOTH peers' `NetMatchController`s, which
/// re-derive each roll from its commit-reveal document and replay each event
/// through the rules engine, freezing the match on a violation. The relay is the
/// LAN counterpart of `firestore.rules`: it polices document shape and ordering
/// and nothing else, so the two transports place their trust in exactly the same
/// place.
///
/// What it therefore DOES enforce, and all it enforces:
///
///  1. **Authorship comes from the connection, never from the wire.** Every
///     write names its author here ([hostAuthor] for the bound peer's own
///     writes, [guestAuthor] for anything that arrived over the socket), so a
///     guest cannot author an event as the host. This is what makes
///     [TransportSession.sideOf] trustworthy on both peers, and hence what makes
///     the controllers' author↔seat check meaningful.
///  2. **Event seqs are write-once and contiguous from 1.** A seq already used
///     is [TransportContested] (the writer is behind and must resync); a seq
///     beyond the next free one is [TransportRejected] (a hole would break every
///     folder's contiguity assumption).
///  3. **Roll documents are write-once per phase**, in the order
///     commit → entropy → reveal, with entropy from the NON-roller and the
///     reveal from the roller only. Identical to the shipped Firestore rules,
///     because the fairness argument depends on it: the roller must be bound to
///     its secret before it can see the witness's entropy.
///
/// The relay keeps the log so it can answer a reconnect: a guest that drops comes
/// back with `hello` and is handed the WHOLE log and every roll document
/// ([welcome]), which is the only resync path either peer needs.
class MatchRelay {
  MatchRelay({
    required this.config,
    String? resumeToken,
    Random? tokenRandom,
  }) : resumeToken = resumeToken ?? _mintToken(tokenRandom);

  /// The identity the bound peer's own writes are stamped with.
  ///
  /// The two author ids are CONSTANTS rather than negotiated names: the relay
  /// knows which side a frame came from (its own call, or the guest socket) and
  /// nothing on the wire can change that. A display name is UI decoration and
  /// deliberately plays no part in identity.
  static const String hostAuthor = 'host';

  /// The identity every write that arrived over the guest socket is stamped with.
  static const String guestAuthor = 'guest';

  /// The match parameters the host fixed; the guest adopts them.
  final MatchConfig config;

  /// This match's identity, echoed in every [welcome].
  ///
  /// A host that restarts mints a new one, which is how the guest's controller
  /// learns that the match it was folding is gone rather than silently writing
  /// the new one into the old one's history row.
  final String resumeToken;

  final List<EventFrame> _events = [];
  final Map<int, RollFrame> _rolls = {};
  final _committed = StreamController<InboundFrame>.broadcast();

  bool _closed = false;

  /// Every frame the relay has committed, as it commits it: an [EventFrame] per
  /// log entry and a [RollFrame] per PHASE a roll reaches.
  ///
  /// Broadcast and non-buffering, so a listener attaches before the first write
  /// and reads [events]/[rollFrames] for anything it may have missed.
  Stream<InboundFrame> get committed => _committed.stream;

  /// The log, oldest first.
  List<EventFrame> get events => List.unmodifiable(_events);

  /// Every roll document, ascending by index.
  List<RollFrame> get rollFrames {
    final ns = _rolls.keys.toList()..sort();
    return [for (final n in ns) _rolls[n]!];
  }

  /// The last committed seq; 0 before any event.
  int get lastSeq => _events.length;

  /// The seq the next event must claim.
  int get nextSeq => _events.length + 1;

  /// The side [author] plays, or null for a stranger. The host keeps
  /// [TransportSession.hostSide]; the guest gets the other seat.
  static Player? sideOf(String author) => switch (author) {
        hostAuthor => TransportSession.hostSide,
        guestAuthor => TransportSession.hostSide.opponent,
        _ => null,
      };

  /// The side the guest plays.
  static Player get guestSide => TransportSession.hostSide.opponent;

  // --- reads (the resync pulls) ----------------------------------------------

  /// EXACTLY the events with `seq > afterSeq`, ascending and contiguous.
  List<EventFrame> eventsSince(int afterSeq) =>
      [for (final e in _events) if (e.seq > afterSeq) e];

  /// The current document for roll [n], or null if it does not exist yet.
  RollFrame? roll(int n) => _rolls[n];

  /// Every roll with index `>= from`, ascending.
  List<RollFrame> rollsFrom(int from) =>
      [for (final r in rollFrames) if (r.n >= from) r];

  /// The frame that answers a `hello`: the match, the guest's seat, the identity
  /// token, and EVERYTHING the relay holds.
  WelcomeMessage welcome() => WelcomeMessage(
        config: config,
        side: guestSide,
        resume: resumeToken,
        log: events,
        rolls: rollFrames,
      );

  // --- writes ----------------------------------------------------------------

  /// Append one event, authored by [author].
  ///
  /// Throws [TransportContested] when [seq] is taken (the writer is behind) and
  /// [TransportRejected] when it would leave a hole.
  EventFrame appendEvent({
    required String author,
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) {
    _ensureOpen();
    if (seq <= lastSeq) {
      throw TransportContested('seq-taken', 'events/$seq already exists',
          peerLastSeq: lastSeq);
    }
    if (seq > nextSeq) {
      throw TransportRejected(
          'seq-gap', 'events/$seq would leave a hole after $lastSeq',
          peerLastSeq: lastSeq);
    }
    final frame =
        EventFrame(seq: seq, gameNo: gameNo, event: event, author: author);
    _events.add(frame);
    _publish(frame);
    return frame;
  }

  /// Phase 1: create roll [n] with [author]'s commitment.
  RollFrame createRoll({
    required String author,
    required int n,
    required String commit,
  }) {
    _ensureOpen();
    if (_rolls.containsKey(n)) {
      throw TransportContested('roll-taken', 'rolls/$n already exists',
          peerLastSeq: lastSeq);
    }
    final frame = RollFrame(n: n, roller: author, commit: commit);
    _rolls[n] = frame;
    _publish(frame);
    return frame;
  }

  /// Phase 2: the WITNESS's entropy. Refused for the roller, and write-once.
  RollFrame addEntropy({
    required String author,
    required int n,
    required String entropy,
  }) {
    _ensureOpen();
    final roll = _reqRoll(n);
    if (roll.roller == author) {
      throw TransportRejected(
          'entropy-by-roller', 'the roller of roll $n cannot add its entropy',
          peerLastSeq: lastSeq);
    }
    if (roll.entropy != null || roll.reveal != null) {
      throw TransportRejected(
          'entropy-write-once', 'entropy for roll $n is already set',
          peerLastSeq: lastSeq);
    }
    return _replace(RollFrame(
      n: roll.n,
      roller: roll.roller,
      commit: roll.commit,
      entropy: entropy,
    ));
  }

  /// Phase 3: the ROLLER's reveal. Refused before the entropy lands (that
  /// ordering IS the fairness guarantee), and write-once.
  RollFrame addReveal({
    required String author,
    required int n,
    required String reveal,
  }) {
    _ensureOpen();
    final roll = _reqRoll(n);
    if (roll.roller != author) {
      throw TransportRejected(
          'reveal-not-roller', 'only the roller of roll $n may reveal',
          peerLastSeq: lastSeq);
    }
    if (roll.entropy == null) {
      throw TransportRejected('reveal-before-entropy',
          'roll $n has no entropy to be bound to yet',
          peerLastSeq: lastSeq);
    }
    if (roll.reveal != null) {
      throw TransportRejected(
          'reveal-write-once', 'roll $n has already been revealed',
          peerLastSeq: lastSeq);
    }
    return _replace(RollFrame(
      n: roll.n,
      roller: roll.roller,
      commit: roll.commit,
      entropy: roll.entropy,
      reveal: reveal,
    ));
  }

  /// Release the [committed] stream. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _committed.close();
  }

  // --- internals -------------------------------------------------------------

  RollFrame _reqRoll(int n) {
    final roll = _rolls[n];
    if (roll == null) {
      throw TransportRejected('no-roll', 'rolls/$n does not exist',
          peerLastSeq: lastSeq);
    }
    return roll;
  }

  RollFrame _replace(RollFrame frame) {
    _rolls[frame.n] = frame;
    _publish(frame);
    return frame;
  }

  void _publish(InboundFrame frame) {
    if (!_committed.isClosed) _committed.add(frame);
  }

  void _ensureOpen() {
    if (_closed) {
      throw const TransportUnavailable('relay-closed', 'the relay is closed');
    }
  }

  static const _tokenAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String _mintToken(Random? rng) {
    final r = rng ?? Random.secure();
    return [
      for (var i = 0; i < 12; i++)
        _tokenAlphabet[r.nextInt(_tokenAlphabet.length)],
    ].join();
  }
}
