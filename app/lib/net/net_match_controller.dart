import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:match_transport/match_transport.dart';

import '../data/persistence_hooks.dart';
import '../game/applied_move.dart';
import '../game/match_controller.dart';
import '../game/player_agent.dart';

/// A PROVEN protocol violation by the other peer — the one fault a networked
/// match never recovers from.
///
/// There is no server and no referee in the unified model, so the honest peer IS
/// the referee: it re-derives every roll from the commit-reveal frames and
/// replays every event through the rules engine. When something does not add up,
/// the match is FROZEN rather than repaired — silently accepting an event the
/// rules engine refuses would be accepting a cheat, and refetching cannot help
/// because the log is exactly what the opponent wrote.
///
/// Distinct from a transient [TransportException]/[NetMatchException] on purpose:
/// transient faults self-heal on the next successful fold, a freeze never does.
///
/// (Renamed from the shipped `OnlineCheatException`; every code and both
/// headlines are unchanged, because the LAN transport now needs exactly the same
/// vocabulary.)
class MatchCheatException implements Exception {
  const MatchCheatException(this.code, this.detail, {this.headline = illegal});

  /// The headline used for rule-breaking events (out of turn, wrong author, a
  /// move the engine refuses).
  static const String illegal =
      "Opponent's client sent an illegal move — match frozen.";

  /// The headline used for a broken commit-reveal (tampered reveal, dice that do
  /// not match the roll the two peers agreed on).
  static const String dice =
      "Opponent's client sent tampered dice — match frozen.";

  /// A stable machine code: `not-a-participant`, `wrong-author`,
  /// `cube-in-cubeless`, `opening-not-host`, `roll-author`, `dice-mismatch`,
  /// `fair-dice`, `malformed-roll`, `illegal-event`.
  final String code;

  /// What exactly was violated, appended to [headline].
  final String detail;

  final String headline;

  /// The single line the UI shows.
  String get message => '$headline $detail';

  @override
  String toString() => message;
}

/// A non-fatal fault surfaced through [MatchController.error] while playing over
/// a [MatchTransport]. Shaped like the shipped `OnlineException` /
/// `LanMatchException` (a machine [code] plus a user-readable [message]) so the
/// game screen's error banner treats all of them the same way.
class NetMatchException implements Exception {
  const NetMatchException(this.code, this.message);

  /// A stable machine code: `offline`, `rejected`, `diverged`,
  /// `roll-contested`.
  final String code;

  /// The line the banner shows.
  final String message;

  @override
  String toString() => 'NetMatchException($code): $message';
}

/// The roller's half of one commit-reveal roll, plus the transport bookkeeping
/// that makes each phase retryable without repeating a write.
class _RollerDrive {
  _RollerDrive({
    required this.n,
    required this.opening,
    required this.gameNo,
    Random? rng,
  }) : session = RollerSession(rollIndex: n, rng: rng);

  /// The roll index this drive owns.
  final int n;

  /// True for a game's opening roll (derived with [openingDiceFrom], written as
  /// an [OpeningRollEvent]).
  final bool opening;

  /// The `gameNo` the resulting event is stamped with.
  final int gameNo;

  final RollerSession session;

  /// The commitment frame exists.
  bool committed = false;

  /// The secret has been taken out of the session — held here so a failed
  /// reveal can be retried (the session is single-use).
  String? revealValue;

  /// The reveal has landed (or was already present).
  bool revealSent = false;

  /// The derived roll has been appended to the event log.
  bool eventSent = false;

  /// One of this drive's writes was REFUSED by the backend. Deterministic, so
  /// the drive stops dead rather than re-attempting on the roll beat; only a
  /// deliberate [NetMatchController.rollDice] clears it. See
  /// [NetMatchController._rejectRoll].
  bool refused = false;
}

/// The witness's half of one roll: contribute entropy, then verify the reveal.
class _WitnessDrive {
  _WitnessDrive(this.n, {Random? rng})
      : session = WitnessSession(rollIndex: n, rng: rng);

  final int n;
  final WitnessSession session;
  bool entropySent = false;
  bool verified = false;
}

/// The ONE [MatchController] for networked play, over any [MatchTransport].
///
/// It replaces `OnlineMatchController` (Firestore) and `LanMatchController`
/// (socket + `HostAuthority`) with a single fold, a single trust model and a
/// single roll protocol; the transport is a dumb pipe (see the `match_transport`
/// library doc for the normative fold/resync contract this class relies on).
/// Every hardened behaviour of both shipped controllers survives here — the list
/// below says where.
///
/// ## Dice — commit-reveal, both roles
///
/// Neither peer may pick its own dice, so every roll goes through the three-phase
/// [RollFrame] handshake (see `fair_dice.dart`):
///
///  * the ROLLER publishes `commit = sha256(secretA)` ([MatchTransport.createRoll]),
///    waits for the witness's `entropy`, publishes `reveal = secretA`, derives the
///    dice from `sha256(A ‖ B)` and appends the [RollEvent]/[OpeningRollEvent];
///  * the WITNESS sees the commit, contributes `entropy`, verifies the reveal
///    against the commitment and re-derives the same dice to check that the
///    roller's event carries EXACTLY them.
///
/// Two conventions make the two peers agree without talking:
///
///  * **the roll index** `n` is `1 + (roll-bearing events already folded)` —
///    [OpeningRollEvent]s and [RollEvent]s across the whole match. Both peers fold
///    the same log, so both compute the same `n`, and it is recovered for free by a
///    resync (which recounts from the log);
///  * **the opening roller is the HOST seat** ([TransportSession.hostSide], i.e.
///    white). Nobody is "on turn" before an opening roll, so the seat cannot decide
///    it; the host creates it, the joiner contributes entropy, and fairness holds
///    regardless of who committed.
///
/// A witness answers ONLY the due roll (`n == rollCount + 1`, roller on turn) —
/// see [_isDueRoll], which closes the dice-LOOKAHEAD break.
///
/// ## Validation — the honest peer is the referee
///
/// Every event authored by the OPPONENT is checked before it folds:
///
///  1. the author must be a participant, and the seat it claims
///     ([TransportSession.sideOf]) must match the event's player; an
///     [OpeningRollEvent] must come from the host;
///  2. a roll-bearing event must carry exactly the dice its [RollFrame] derives
///     ([diceMatchRoll]/[openingDiceMatchRoll]), and that frame's `roller` must be
///     the event's author;
///  3. the rules engine must accept it ([Game.append] throws otherwise).
///
/// Any failure FREEZES the match with a [MatchCheatException] — see [cheatError].
/// A freeze stops folding, stops rolling, closes every gate and never self-heals,
/// unlike the transient [error] a read blip produces.
///
/// ## Seq base — CONTIGUOUS FROM 1
///
/// This controller implements the transport contract verbatim: event seqs are
/// strictly increasing and contiguous **from 1**, so `_lastSeq == 0` means
/// "nothing folded", the next free index is `_lastSeq + 1`, and `eventsSince(0)`
/// is the whole log. The shipped Firestore log is 0-based; mapping it onto this
/// space is the FirestoreTransport's job (Task 4), not the controller's — exactly
/// as the contract's "a transport whose native index is 0-based maps onto this
/// 1-based seq space" clause requires.
///
/// ## Transport ownership — THE CONTROLLER OWNS IT
///
/// [disposeController] disposes the [transport]. One owner, matching what
/// `LanMatchController` already did with its link, so a screen never has to
/// reason about half-torn-down state: build a transport, hand it over, and only
/// ever dispose the controller. Screens (Tasks 3/4) must NOT also close the
/// transport.
///
/// ## Divergence and resync
///
/// The only recovery path is a FULL REPLACE: re-read every event and roll
/// ([MatchTransport.eventsSince]/[MatchTransport.rollsSince]) and rebuild from
/// scratch — there is no snapshot to seed scores from, the log is the only truth.
/// Three watermarks survive it so a rebuild does not re-fire history the user has
/// already lived through: [_persistedThrough], [_acknowledgedThrough] and
/// [_matchPersisted]. They survive a replace of the SAME match only: a
/// [ResetFrame] (or a reconnect) bearing a DIFFERENT `resumeToken` is a different
/// match identity, and every watermark from the old one is void — see
/// [_adoptIdentity].
///
/// A replace request can itself fail (a read blip), and nothing else would wake
/// it, so [_replaceFromLog] arms a bounded retry chain ([_maxResyncAttempts]).
///
/// ## Sending is not delivering
///
/// A write resolves only once COMMITTED (contract), so an `await` on
/// [MatchTransport.sendEvent] is the gate. But a committed event still has to come
/// BACK on `inbound` for the fold to advance, and a relay can silently drop a
/// frame, so the [submitting] latch also carries a deadline ([_onGateTimeout]): a
/// lost frame costs one timeout and a banner, never the rest of the match.
///
/// ## Game-end pause
///
/// The host appends the next game's opening roll as soon as a game ends, but the
/// UI still shows a game-over dialog. A finished game sets [awaitingNextGame] and
/// BUFFERS every later event until [continueToNextGame] drains the queue.
class NetMatchController extends ChangeNotifier implements MatchController {
  NetMatchController({
    required this.transport,
    TransportSession? session,
    this.persistence = const NoopPersistence(),
    this.gateTimeout = const Duration(seconds: 5),
    this.rng,
  }) {
    if (session != null) _adoptSession(session);
  }

  /// The pipe this controller drives. OWNED: [disposeController] disposes it.
  final MatchTransport transport;

  /// Persistence seam invoked as the match progresses. Defaults to a no-op so
  /// play works with persistence off; a failing hook is non-fatal (see
  /// [_persist]).
  final MatchPersistence persistence;

  /// How long a latched [submitting] gate may last before it re-opens itself.
  ///
  /// Covers the frame a relay drops silently: the write COMMITTED (so the await
  /// returned) but the echo never arrived, and nothing else would ever unlatch
  /// the gate. Hundreds of times a LAN round trip, so reaching it really does
  /// mean the answer is gone.
  final Duration gateTimeout;

  /// Injected only by tests, to make protocol secrets reproducible. NEVER
  /// non-null in production — a predictable secret is a predictable roll, and a
  /// predictable roll is a riggable one.
  @visibleForTesting
  final Random? rng;

  TransportSession? _session;

  /// The session [connect] returned. Throws before [playMatch] has connected.
  TransportSession get session {
    final s = _session;
    if (s == null) throw StateError('the transport has not connected yet');
    return s;
  }

  /// The seat whose decisions are submitted; the other side is the opponent's.
  ///
  /// Available only once connected (the transport assigns it) — the UI gates on
  /// [isReady], which is strictly later.
  Player get localSide => session.assignedSide;

  /// The match's human-facing handle (invite code / room code).
  String get matchCode => session.matchCode;

  /// True when this device holds the host seat (and is therefore the protocol
  /// roller for every opening roll).
  bool get isHost => session.isHost;

  String get _author => session.localAuthor;

  Game? _game;
  MatchState _match = MatchState(matchLength: 1);

  /// The 1-based number of the current game within the match. `0` until the
  /// first event folds.
  int _gameNumber = 0;

  /// The last INGESTED seq. Seqs are contiguous FROM 1, so `0` means "nothing
  /// yet" and the next free index is `_lastSeq + 1`.
  int _lastSeq = 0;

  /// Roll-bearing events ingested so far (openings + turn rolls, whole match).
  /// The next roll's index is `_rollCount + 1`.
  int _rollCount = 0;

  /// [OpeningRollEvent]s ingested so far — i.e. the highest game number that has
  /// been STARTED, buffered games included.
  int _openingsIngested = 0;

  /// The highest game number whose game-over folded. Together with
  /// [_openingsIngested] this answers "does a new opening roll need making?"
  /// without depending on the game-over pause.
  int _lastFinishedGameNo = 0;

  /// The last game written through [persistence] — so a rebuild does not record
  /// a game twice.
  int _persistedThrough = 0;

  /// The last game whose game-over pause the user dismissed — so a rebuild does
  /// not re-open a dialog they already closed.
  int _acknowledgedThrough = 0;

  /// Whether the decided match has already been written through
  /// [MatchPersistence.onMatchFinished].
  bool _matchPersisted = false;

  /// Which match the three watermarks above are ABOUT: the resume token the fold
  /// is running under. See [_adoptIdentity].
  String? _matchIdentity;

  /// Whether end-of-match bookkeeping has been sent.
  bool _completionSent = false;

  bool _awaitingNextGame = false;
  bool _started = false;
  bool _disposed = false;
  bool _replacing = false;
  bool _resyncing = false;
  bool _replaceAgain = false;

  /// Whether the link has been away since it was last [TransportStatus.connected]
  /// — the trigger for a durable rejoin.
  bool _droppedSinceConnect = false;

  /// A transient fault (read blip, failed submission). Cleared by the next
  /// successful fold.
  Object? _transientError;

  /// A proven protocol violation. Never cleared — see [MatchCheatException].
  MatchCheatException? _cheatError;

  Object? _persistenceError;

  /// Set while a full replace could not fold the log we just fetched with an
  /// event of OUR OWN — the one failure a resync cannot fix.
  Object? _replaceFailure;

  /// Serialises persistence hooks so a game's [MatchPersistence.onGameFinished]
  /// completes before the next game's (and before
  /// [MatchPersistence.onMatchFinished]), even though each is scheduled
  /// fire-and-forget from the synchronous fold.
  Future<void> _persistChain = Future<void>.value();

  /// Completes the first time a game folds (so [state]/[game] become safe to
  /// read), or when the controller is disposed before that happens. See [ready].
  final Completer<void> _ready = Completer<void>();

  StreamSubscription<InboundFrame>? _sub;
  StreamSubscription<TransportStatusEvent>? _statusSub;
  StreamSubscription<bool>? _presenceSub;

  /// Events received but not yet ingested. Normally drained to empty on arrival;
  /// an entry stays only while its [RollFrame] is still being fetched
  /// (validation cannot run without it).
  final List<EventFrame> _inbox = [];

  /// Events ingested while paused between games, folded on [continueToNextGame].
  List<EventFrame> _buffer = [];

  /// Every roll frame seen, by index. The validation side reads it to re-derive
  /// what a roll event was REQUIRED to say.
  final Map<int, RollFrame> _rolls = {};

  /// Roll indices with a [MatchTransport.fetchRoll] in flight (see [_fetchRoll]).
  final Set<int> _fetchingRolls = {};

  /// The highest roll index that already existed when this fold FIRST primed
  /// itself, or null until it has. See [_pinFailure]: rolls above it are rolls
  /// this device must have witnessed, so their entropy is ours or forged; rolls at
  /// or below it predate us and can only be taken as found.
  int? _rollFloor;

  _RollerDrive? _roller;
  final Map<int, _WitnessDrive> _witnesses = {};

  /// What THIS device has asked the transport to append, by seq: the encoded
  /// forms it attempted at each index (more than one when a write timed out and
  /// the retried decision differed).
  ///
  /// The ledger behind the `forged-as-us` check in [_validate]. A relay that is
  /// also a player cannot be trusted to attribute honestly — on a LAN the host
  /// chooses every `author` the guest folds — and an event forged as OURS is the
  /// one attribution the rest of this class treats as beyond suspicion: it
  /// unlatches the gate ([_ingest]) and routes a fold failure to a harmless
  /// RESYNC instead of a freeze ([_onFoldFailure]). We know exactly what we
  /// wrote, so we can say so.
  final Map<int, Set<String>> _ownWrites = {};

  /// The lowest seq this device has ever attempted to write, or null before its
  /// first write.
  ///
  /// The ledger is only authoritative from here up. A [Capabilities.durable]
  /// match re-entered in a NEW process legitimately contains our own events from
  /// the previous one, and those are not in this ledger; but we only ever write
  /// at `lastFolded + 1`, having folded the whole log first, so every such event
  /// sits strictly BELOW our first write of this session.
  int? _ownWriteFloor;

  bool _pumping = false;

  /// A pump was requested while one was running; see [_pumpRolls].
  bool _pumpAgain = false;
  Timer? _rollRetry;

  /// The paced re-drain armed when the inbox is blocked on a roll frame that has
  /// not completed. See [_armInboxRetry].
  Timer? _inboxRetry;

  /// The pending retry of a full replace that failed, and how many have been
  /// spent on the current divergence. See [_replaceFromLog].
  Timer? _resyncRetry;
  int _resyncAttempts = 0;
  String _resyncReason = '';

  /// How many times one divergence will re-read the log before giving up and
  /// leaving the banner for the user.
  static const int _maxResyncAttempts = 5;

  /// Consecutive full replays that FETCHED fine and then failed to fold.
  ///
  /// [_maxResyncAttempts] bounds the other half — a replace whose fetch failed —
  /// but nothing bounded this one, and it is the more expensive of the two. A
  /// permanently unfoldable own event (our engine refuses an event we ourselves
  /// wrote, so it is not a cheat and not retryable) leaves the fold stuck below
  /// the log's end forever; every subsequent inbound frame then arrives as a GAP
  /// and asks for the whole log again. One `eventsSince(0)` + `rollsSince(1)` per
  /// inbound frame, on a 50,000-read daily quota, for the rest of the match.
  ///
  /// So: three failed replays in a row and the log is not re-read again. The
  /// banner stays, the folded state stays published, and any FORWARD progress
  /// (a replay that folds) clears the count.
  int _failedReplays = 0;
  static const int _maxFailedReplays = 3;

  /// The roll index a refetch has already been spent on because the opponent
  /// held it when our turn said it was ours. See [_onContestedRoll].
  int? _contestedRoll;

  /// The last pace hint handed to the transport, so a hint is sent only on a
  /// change.
  bool? _paceFast;

  // Pending-decision notifiers for the LOCAL side.
  final ValueNotifier<GameState?> _pendingMove = ValueNotifier(null);
  final ValueNotifier<GameState?> _pendingCube = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> _pendingResign =
      ValueNotifier(null);

  // Constant null-valued notifiers returned for the opponent's side.
  final ValueNotifier<GameState?> _nullState = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> _nullResign =
      ValueNotifier(null);

  /// The last folded move, published for the animation layer, carrying the board
  /// it was applied TO (captured before the fold). See [AppliedMove].
  final ValueNotifier<AppliedMove?> _lastMove =
      ValueNotifier<AppliedMove?>(null);

  final ValueNotifier<TransportStatus> _linkStatus =
      ValueNotifier<TransportStatus>(TransportStatus.connecting);

  final ValueNotifier<bool> _opponentPresent = ValueNotifier<bool>(false);

  /// The gate latch, as a notifier so the UI can watch it directly. Backed by
  /// [_submitting], which is what the rest of this class reads and writes.
  final ValueNotifier<bool> _submittingGate = ValueNotifier<bool>(false);

  /// Bounds how long the latch may last. See [_onGateTimeout].
  Timer? _gateTimer;

  bool get _submitting => _submittingGate.value;

  /// Latching ALWAYS arms the deadline; unlatching always disarms it, however
  /// the answer arrived.
  set _submitting(bool latched) {
    if (_disposed) return;
    _gateTimer?.cancel();
    _gateTimer = null;
    _submittingGate.value = latched;
    if (latched) _gateTimer = Timer(gateTimeout, _onGateTimeout);
  }

  // --- observable state ------------------------------------------------------

  /// The current game's derived state.
  ///
  /// Throws [StateError] if read before the first opening roll has folded; the
  /// UI must gate on [isReady].
  @override
  GameState get state {
    final g = _game;
    if (g == null) throw StateError('no game has started yet');
    return g.state;
  }

  @override
  MatchState get match => _match;

  @override
  int get gameNumber => _gameNumber;

  @override
  Game get game {
    final g = _game;
    if (g == null) throw StateError('no game has started yet');
    return g;
  }

  /// True once the first opening roll has been folded — i.e. [state] and [game]
  /// are safe to read. The UI must not push the game screen until this is true.
  bool get isReady => _game != null;

  /// The last seq this controller has taken in (folded, or buffered behind the
  /// game-over pause). `0` before the first event.
  int get lastSeq => _lastSeq;

  /// Roll-bearing events folded so far; the next roll's index is this plus one.
  int get rollCount => _rollCount;

  /// Completes once the controller [isReady] (the first game has folded), or when
  /// it is disposed beforehand. Callers should `await` this, then check [isReady]
  /// — a disposed-before-ready controller completes the future but leaves
  /// [isReady] `false`, so the caller can bail without reading [state].
  Future<void> get ready => _ready.future;

  /// The proven protocol violation that froze this match, or `null`.
  ///
  /// While non-null the controller is inert: nothing folds, no roll advances,
  /// every gate is shut, and [error] keeps reporting this. The UI should show
  /// [MatchCheatException.message] prominently — the match cannot continue.
  MatchCheatException? get cheatError => _cheatError;

  /// True while the match is frozen by a [cheatError].
  bool get frozen => _cheatError != null;

  /// The link's lifecycle, for the UI's connection chip.
  ValueListenable<TransportStatus> get linkStatus => _linkStatus;

  /// Why the link is reconnecting/busy/failed, or null when healthy.
  String? get linkReason => transport.statusReason;

  /// Whether the OPPONENT is present, for the connection chip and for gating the
  /// opening roll (nobody to witness it otherwise).
  ValueListenable<bool> get opponentPresent => _opponentPresent;

  /// True while a local intent is in flight and the log has not answered it yet
  /// — the "sending…" window. Exposed as a listenable so the UI can show
  /// progress without polling; [awaitingHumanTurn] and the pending notifiers
  /// already account for it.
  ValueListenable<bool> get submitting => _submittingGate;

  /// The most recently folded move (for the animation layer), or `null`.
  @override
  ValueListenable<AppliedMove?> get lastMove => _lastMove;

  /// True while waiting on the opponent (the match is active but it is NOT the
  /// local side's moment to act).
  ///
  /// Deliberately does NOT gate on a transient [error]: a read/submit blip is a
  /// banner, not a change of turn. A freeze DOES close it — nothing is coming.
  @override
  bool get isThinking {
    final g = _game;
    if (g == null || frozen || _match.isMatchOver || _awaitingNextGame) {
      return false;
    }
    return !_localActsNow(g.state);
  }

  /// The fault to show: a freeze if there is one, otherwise the last transient
  /// failure (or `null` when healthy).
  @override
  Object? get error => _cheatError ?? _transientError;

  /// The last non-fatal persistence failure, or `null` when healthy.
  @override
  Object? get persistenceError => _persistenceError;

  /// Whether this match is played without the doubling cube — the host's choice,
  /// carried in the session's [MatchConfig] and honoured by both peers.
  @override
  bool get cubeless => _session?.config.cubeless ?? false;

  @override
  bool get matchOver => _match.isMatchOver;

  @override
  bool get awaitingNextGame => _awaitingNextGame;

  /// True while the local side's pre-roll gate is open.
  ///
  /// Does NOT gate on a transient [error]: a blip must never lock the pre-roll
  /// controls, or one network hiccup would deadlock the loop (a retried
  /// [rollDice] RESUMES the roll drive it left behind). A freeze does close it.
  @override
  bool get awaitingHumanTurn {
    final g = _game;
    if (g == null ||
        frozen ||
        _match.isMatchOver ||
        _awaitingNextGame ||
        _submitting) {
      return false;
    }
    final s = g.state;
    return s.turn == localSide && s.phase == GamePhase.awaitingRoll;
  }

  /// True while a roll handshake is outstanding for EITHER side: from the moment
  /// a drive of ours exists (its commitment is written immediately after) or a
  /// roll frame we have not folded yet is seen, until that roll's event folds and
  /// pushes [_rollCount] past it.
  ///
  /// Drives [MatchTransport.setPaceHint] — the only pacing lever the controller
  /// has. A drive that stalls (a peer that walks away mid-handshake) therefore
  /// holds the fast window open until the user leaves the match, which is the
  /// cheaper side of the trade against making a live handshake feel slow.
  bool get _diceProtocolInFlight {
    if (frozen || _match.isMatchOver) return false;
    if (_roller != null) return true;
    // ONLY the due index counts. A peer that squats the roll frames for its
    // future turns (see [_isDueRoll]) must not be able to pin the fast cadence
    // open for the rest of the match — that would be a read-quota drain even
    // though the lookahead itself is refused.
    return _rolls.containsKey(_rollCount + 1);
  }

  // --- lifecycle -------------------------------------------------------------

  @override
  Future<void> playMatch() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      _adoptSession(await transport.connect());
    } catch (e) {
      if (_disposed) return;
      _transientError = e;
      _completeReady();
      _notify();
      return;
    }
    if (_disposed) return;
    // SUBSCRIBE BEFORE PRIMING. `inbound` carries no history and does not
    // buffer, so anything emitted between connect and the prime would be lost —
    // and on a relay the opponent's first frames routinely land in exactly that
    // window (the shipped LAN links had to seed themselves for this reason). A
    // frame that arrives during the prime is merged by seq, not dropped.
    _sub = transport.inbound.listen(_onFrame, onError: _onInboundError);
    _statusSub = transport.statusStream.listen(_onStatus);
    _presenceSub = transport.opponentPresence.listen(_onPresence);
    _linkStatus.value = transport.status;
    _opponentPresent.value = transport.opponentPresent;
    await _replaceFromLog();
    if (_disposed) return;
    unawaited(_pumpRolls());
  }

  void _adoptSession(TransportSession s) {
    _session = s;
    _match = MatchState(matchLength: s.config.length);
    _adoptIdentity(s.resumeToken);
  }

  @override
  void disposeController() {
    if (_disposed) return;
    _disposed = true;
    // Unblock anyone awaiting readiness; [isReady] stays false so they can bail.
    _completeReady();
    _rollRetry?.cancel();
    _rollRetry = null;
    _inboxRetry?.cancel();
    _inboxRetry = null;
    _resyncRetry?.cancel();
    _resyncRetry = null;
    _gateTimer?.cancel();
    _gateTimer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_statusSub?.cancel());
    _statusSub = null;
    unawaited(_presenceSub?.cancel());
    _presenceSub = null;
    // The controller OWNS the transport — see the class doc. One owner, so a
    // screen only ever has to dispose the controller.
    unawaited(transport.dispose());
    _pendingMove.dispose();
    _pendingCube.dispose();
    _pendingResign.dispose();
    _nullState.dispose();
    _nullResign.dispose();
    _lastMove.dispose();
    _linkStatus.dispose();
    _opponentPresent.dispose();
    _submittingGate.dispose();
    super.dispose();
  }

  @override
  void continueToNextGame() {
    if (!_awaitingNextGame) {
      throw StateError('not awaiting the next game');
    }
    _awaitingNextGame = false;
    _acknowledgedThrough = _gameNumber;
    final queued = _buffer;
    _buffer = [];
    for (var i = 0; i < queued.length; i++) {
      // A buffered event may itself end another game and re-pause; hold the
      // remainder back for the next continue.
      if (_awaitingNextGame || frozen) {
        _buffer.addAll(queued.sublist(i));
        break;
      }
      _applyEvent(queued[i]);
    }
    _afterFold();
    _drainInbox();
    if (!_disposed && !frozen) unawaited(_pumpRolls());
  }

  // --- pre-roll verbs --------------------------------------------------------

  /// Start (or RESUME) this device's half of the commit-reveal roll.
  ///
  /// The gate latches for the whole protocol — two round trips at worst — and a
  /// failure re-opens it WITHOUT discarding the drive, so pressing Roll again
  /// picks the same roll `n` up where it stopped rather than starting a second
  /// one.
  @override
  void rollDice() {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    final n = _rollCount + 1;
    if (_roller == null) {
      final claimed = _rolls[n];
      if (claimed != null) {
        _onContestedRoll(n);
        return;
      }
      _roller =
          _RollerDrive(n: n, opening: false, gameNo: _gameNumber, rng: rng);
    }
    // A press of Roll is the ONE bounded retry a refused write gets — the
    // automatic beat never re-attempts one (see [_rejectRoll]).
    _roller!.refused = false;
    _submitting = true;
    _transientError = null;
    _notify();
    unawaited(_pumpRolls());
  }

  /// Someone else's commitment already sits at the index our turn says is ours.
  ///
  /// The honest reading is that our fold is behind, so the first sighting
  /// triggers ONE re-read. If the claim survives that, the peer is out of
  /// protocol — but the roll index is write-once, so there is nothing to seize
  /// and nothing provably illegal to freeze on either. It stays a surfaced
  /// waiting state rather than a silent stall or a resync loop.
  void _onContestedRoll(int n) {
    _submitting = false;
    _transientError = NetMatchException(
      'roll-contested',
      'the other player has already claimed roll $n — waiting for them to '
          'finish it',
    );
    _notify();
    if (_contestedRoll == n) return; // already re-read for this index
    _contestedRoll = n;
    _resync('roll $n was claimed by the opponent');
  }

  @override
  void offerDouble() {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    if (cubeless) throw StateError('this match is played without the cube');
    if (!_doublingLegal(state)) {
      throw StateError('doubling is not legal now');
    }
    _submitDecision(DoubleEvent(localSide));
  }

  @override
  void offerResign(ResignValue value) {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    _submitDecision(ResignOfferEvent(localSide, value));
  }

  // --- interaction surface ---------------------------------------------------

  @override
  bool isLocalHuman(Player side) => side == localSide;

  @override
  ValueListenable<GameState?> pendingMoveOf(Player side) =>
      side == localSide ? _pendingMove : _nullState;

  @override
  void submitMove(Player side, Move move) {
    _requireLocal(side);
    _submitDecision(MoveEvent(localSide, move));
  }

  @override
  ValueListenable<GameState?> pendingCubeOf(Player side) =>
      side == localSide ? _pendingCube : _nullState;

  @override
  void submitCubeResponse(Player side, CubeAction action) {
    _requireLocal(side);
    _submitDecision(
        action == CubeAction.take ? TakeEvent(localSide) : DropEvent(localSide));
  }

  @override
  ValueListenable<(GameState, ResignValue)?> pendingResignOf(Player side) =>
      side == localSide ? _pendingResign : _nullResign;

  @override
  void submitResignResponse(Player side, bool accept) {
    _requireLocal(side);
    _submitDecision(accept
        ? ResignAcceptEvent(localSide)
        : ResignDeclineEvent(localSide));
  }

  @override
  MatchContext contextFor(Player actor) {
    final actorScore =
        actor == Player.white ? _match.whiteScore : _match.blackScore;
    final opponentScore =
        actor == Player.white ? _match.blackScore : _match.whiteScore;
    return MatchContext(
      moverAway: _match.matchLength - actorScore,
      opponentAway: _match.matchLength - opponentScore,
      crawfordPlayed: _match.crawfordPlayed,
    );
  }

  // --- inbound ---------------------------------------------------------------

  /// One inbound frame.
  ///
  /// A [RollFrame] is taken in FIRST-CLASS, before any event drain, deliberately:
  /// a roll-bearing event can only be validated against its roll frame, and the
  /// contract does not promise the two arrive in a useful order.
  void _onFrame(InboundFrame frame) {
    if (_disposed || frozen) return;
    switch (frame) {
      case ResetFrame():
        _onReset(frame);
      case RollFrame():
        _rolls[frame.n] = frame;
        if (!_verifyRollDoc(frame)) return;
        _drainInbox();
        if (_disposed || frozen) return;
        unawaited(_pumpRolls());
      case EventFrame():
        _inbox.add(frame);
        _drainInbox();
        if (_disposed || frozen) return;
        unawaited(_pumpRolls());
    }
  }

  /// A transient read failure on [MatchTransport.inbound]. Per the contract the
  /// stream KEEPS RUNNING, so this is a banner and nothing else.
  void _onInboundError(Object error) {
    if (_disposed || frozen) return;
    _transientError = error;
    _notify();
  }

  /// "Throw your fold away and replay from the log."
  ///
  /// Unprompted, so it must always be honoured — even while a replace is already
  /// in flight (which is why [_runReplace] can queue one). A `resumeToken` that
  /// differs from the one we have been folding under means the MATCH IDENTITY
  /// changed and every per-match watermark is void.
  void _onReset(ResetFrame frame) {
    _cancelResyncRetry();
    // The SESSION first, and the whole session — not just the token.
    //
    // A reset whose token differs is a different MATCH (a host restart, a
    // room-code collision), and a different match has its own [MatchConfig] and
    // its own seat. Adopting only the identity used to leave the config stale, so
    // the replayed log was folded with the previous match's length and — worse —
    // with the previous match's `cubeless` flag, which turns the new opponent's
    // perfectly legal double into a `cube-in-cubeless` FREEZE. That was the one
    // path in this class that could freeze an honest opponent.
    final s = frame.session;
    if (s != null) {
      _adoptSession(s);
    } else {
      _adoptIdentity(frame.resumeToken);
    }
    _transientError = NetMatchException('diverged',
        'the match log is being replayed (${frame.reason ?? 'reset'})');
    _submitting = false;
    _notify();
    // Belt to the contract's braces: a transport that changed identity WITHOUT
    // carrying its session (which [ResetFrame.session] makes normative) is
    // re-asked for it before anything is replayed, rather than having its new
    // match folded under the old one's parameters.
    if (s == null && frame.resumeToken != null && _identityChanged) {
      unawaited(_reconnectThenReplace());
      return;
    }
    unawaited(_runReplace());
  }

  /// Set by [_adoptIdentity] when the token it was handed was a CHANGE.
  bool _identityChanged = false;

  Future<void> _reconnectThenReplace() async {
    try {
      final fresh = await transport.connect();
      if (_disposed) return;
      _adoptSession(fresh);
    } catch (e) {
      if (_disposed || frozen) return;
      _transientError = e;
      _notify();
      return;
    }
    if (_disposed || frozen) return;
    await _runReplace();
  }

  void _onStatus(TransportStatusEvent e) {
    if (_disposed) return;
    _linkStatus.value = e.status;
    if (e.status == TransportStatus.connected) {
      if (_droppedSinceConnect) {
        _droppedSinceConnect = false;
        // DURABLE REJOIN, gated on the capability: a Firestore match can be
        // re-entered mid-play by re-reading the log, a socket session cannot (it
        // ends with the connection, and its relay sends a ResetFrame instead).
        if (transport.capabilities.rejoinable && _started) {
          _resync('the link returned — rejoining the match');
          return;
        }
      }
    } else {
      _droppedSinceConnect = true;
      // A link that is not carrying frames cannot deliver the answer we were
      // waiting for; open the gate so the player can act again.
      _submitting = false;
      if (e.status == TransportStatus.failed) {
        _transientError = NetMatchException(
            'offline', e.reason ?? 'the connection to the other player failed');
      }
    }
    _notify();
  }

  void _onPresence(bool present) {
    if (_disposed) return;
    _opponentPresent.value = present;
    _notify();
    // The opening roll waits for a witness to exist — one may just have arrived.
    if (!frozen && _started) unawaited(_pumpRolls());
  }

  /// A roll frame must agree with what WE witnessed of it, and (once complete) be
  /// a sound commitment. Returns false (after freezing) when it is not.
  bool _verifyRollDoc(RollFrame roll) {
    final pinned = _pinFailure(roll);
    if (pinned != null) {
      _freeze(pinned);
      return false;
    }
    final done = roll.completed;
    if (done == null) return true;
    try {
      done.verifyCommit();
      return true;
    } on FairDiceCheatException catch (e) {
      _freeze(MatchCheatException(
        'fair-dice',
        'the secret revealed for roll ${roll.n} does not hash to the '
            'commitment published before our entropy was contributed ($e).',
        headline: MatchCheatException.dice,
      ));
      return false;
    } on FormatException catch (e) {
      _freeze(MatchCheatException(
        'malformed-roll',
        'roll ${roll.n} carries a malformed protocol value ($e).',
        headline: MatchCheatException.dice,
      ));
      return false;
    }
  }

  /// Whether [roll] contradicts what this device ITSELF put into it — the check
  /// that makes a relay-and-player peer unable to steer its own dice.
  ///
  /// `verifyCommit` alone only proves a roll frame is SELF-consistent: any
  /// `(commit, entropy, reveal)` triple with `sha256(reveal) == commit` passes it.
  /// A peer that both plays and carries the wire can manufacture such a triple
  /// AFTER the fact — pick the entropy itself, or swap the commitment once it has
  /// seen ours — and choose whichever of the 36 outcomes it likes while every
  /// commitment check still succeeds. What it cannot do is change what WE
  /// contributed, and we remember that:
  ///
  ///  * **the commitment is pinned.** [WitnessSession.verifyReveal] already
  ///    checks the reveal against the commit we SAW, but only if it runs, and it
  ///    is skipped once the roll's event has folded ([_isDueRoll] stops matching)
  ///    — an ordering a hostile peer controls, by sending the roll event ahead of
  ///    the reveal. Checked here instead, on first sighting of every frame, so
  ///    the ordering cannot matter.
  ///  * **the entropy is pinned.** The witness's entropy is the one value the
  ///    roller must not choose; on a roll we witnessed, any entropy other than
  ///    the exact bytes we sent is a fabrication.
  /// The third leg — entropy on a roll we are the witness of but never
  /// contributed to at all — cannot be judged from the frame alone (a roll may
  /// predate this fold), so it lives in [_witnessEntropyFailure] and is checked
  /// when the roll's EVENT is about to fold.
  MatchCheatException? _pinFailure(RollFrame roll) {
    if (roll.roller == _author) return null; // our own roll: we chose the secret
    final w = _witnesses[roll.n];
    if (w == null || w.session.phase == FairDicePhase.fresh) return null;
    if (roll.commit != w.session.commit) {
      return MatchCheatException(
        'roll-commit-substituted',
        'roll ${roll.n} now carries commitment "${roll.commit}" but this device '
            'witnessed it committed to "${w.session.commit}".',
        headline: MatchCheatException.dice,
      );
    }
    final entropy = roll.entropy;
    if (entropy == null) return null;
    // `committed` means we have seen the commit but not produced entropy yet, so
    // there is nothing of ours to compare against — that is the
    // [_witnessEntropyFailure] case.
    if (w.session.phase == FairDicePhase.committed) return null;
    if (entropy == w.session.entropy) return null;
    return MatchCheatException(
      'roll-entropy-substituted',
      'roll ${roll.n} carries entropy "$entropy", which is not the entropy this '
          'device contributed as its witness.',
      headline: MatchCheatException.dice,
    );
  }

  /// Whether the roll behind an about-to-fold roll event carries a witness
  /// entropy that CANNOT be ours — the strongest form of the dice attack.
  ///
  /// [_pinFailure] catches a peer that swaps a value we already put in. This
  /// catches the peer that never let us put one in: it fabricates the entropy
  /// itself and only then shows us the roll, so we are never its witness, every
  /// commitment check still passes, and it has picked its own dice. The proof is
  /// structural — only the NON-roller may contribute entropy, and in a two-player
  /// match the non-roller of the opponent's roll is us.
  ///
  /// Bounded by [_rollFloor], which is the honest ambiguity: a roll that already
  /// existed when this fold first primed may carry OUR entropy from a previous
  /// process (a durable match re-entered) or a previous occupant of the seat (a
  /// LAN room whose earlier guest contributed it), and we have no memory to check
  /// it against. Above the floor there is no such reading.
  MatchCheatException? _witnessEntropyFailure(RollFrame doc) {
    if (doc.entropy == null || doc.roller == _author) return null;
    final floor = _rollFloor;
    if (floor == null || doc.n <= floor) return null;
    final w = _witnesses[doc.n];
    if (w != null &&
        w.session.phase != FairDicePhase.fresh &&
        w.session.phase != FairDicePhase.committed) {
      return null; // ours — and [_pinFailure] has already compared the bytes
    }
    return MatchCheatException(
      'roll-entropy-forged',
      'roll ${doc.n} carries a witness entropy, but this device is its only '
          'possible witness and never contributed one.',
      headline: MatchCheatException.dice,
    );
  }

  /// Ingest as much of [_inbox] as can be validated right now.
  ///
  /// Stops (leaving the rest queued) when the next event is a roll whose frame
  /// has not been seen yet — that frame is what the event is checked against, so
  /// folding without it would mean trusting the opponent's dice. A targeted
  /// fetch is started and the drain resumes when it lands.
  void _drainInbox() {
    _drainLoop();
    _finishReplace();
  }

  void _drainLoop() {
    while (_inbox.isNotEmpty && !_disposed && !frozen) {
      // A replay that has already failed cannot be repaired by folding MORE of
      // the same log on top of the mismatch.
      if (_replacing && _replaceFailure != null) return;
      final ef = _inbox.first;
      if (ef.seq <= _lastSeq) {
        _inbox.removeAt(0);
        continue;
      }
      if (ef.seq > _lastSeq + 1) {
        // A GAP. Nothing incremental closes it — only the whole log can.
        _inbox.clear();
        _resync('missed events (seq ${ef.seq} after $_lastSeq)');
        return;
      }
      final needed = _rollIndexFor(ef.event);
      if (needed != null && !(_rolls[needed]?.isComplete ?? false)) {
        _fetchRoll(needed);
        return;
      }
      _inbox.removeAt(0);
      _ingest(ef);
    }
  }

  /// The roll index a roll-bearing event must be validated against, or null for
  /// every other event. Only valid for the NEXT event to ingest.
  int? _rollIndexFor(GameEvent event) =>
      (event is OpeningRollEvent || event is RollEvent) ? _rollCount + 1 : null;

  void _fetchRoll(int n) {
    if (_fetchingRolls.contains(n)) return;
    _fetchingRolls.add(n);
    unawaited(() async {
      var unblocked = false;
      try {
        final doc = await transport.fetchRoll(n);
        if (_disposed || frozen) return;
        if (doc != null) {
          _rolls[n] = doc;
          if (!_verifyRollDoc(doc)) return;
          unblocked = doc.isComplete;
        }
      } catch (e) {
        if (_disposed || frozen) return;
        _transientError = e;
        _notify();
      } finally {
        _fetchingRolls.remove(n);
      }
      if (_disposed || frozen) return;
      // Re-enter the drain ONLY when this fetch actually unblocked it.
      //
      // Draining unconditionally is a tight loop whenever the roll cannot
      // complete — a peer that appends its RollEvent and never reveals leaves
      // the drain permanently blocked, and each turn of the loop is another
      // BILLED read (thousands a second, which also pins the isolate). The
      // inbound stream is what legitimately delivers a frame as it advances; the
      // backoff below is only a paced backstop, and it never runs faster than
      // the transport's own cadence.
      if (unblocked) {
        _drainInbox();
      } else {
        _armInboxRetry();
      }
    }());
  }

  /// Validate, count and either fold or buffer one contiguous event.
  void _ingest(EventFrame ef) {
    final violation = _validate(ef);
    if (violation != null) {
      _freeze(violation);
      return;
    }
    _lastSeq = ef.seq;
    final event = ef.event;
    if (event is OpeningRollEvent) {
      _openingsIngested++;
      _rollCount++;
    } else if (event is RollEvent) {
      _rollCount++;
    }
    // Our own roll drive is finished the moment its event is in the log.
    final drive = _roller;
    if (drive != null && _rollCount >= drive.n) {
      _roller = null;
      _submitting = false;
    }
    // The log moved: whatever we sent has been answered (the shipped LAN fold's
    // rule, and the backstop that unlatches a gate no await is holding).
    if (ef.author == _author) _submitting = false;
    if (_awaitingNextGame) {
      _buffer.add(ef);
      return;
    }
    _applyEvent(ef);
  }

  /// Everything that can be checked WITHOUT the folded game: who wrote the
  /// event, which seat it claims, and (for a roll) whether its dice are the ones
  /// the commit-reveal frame derives. Returns the violation, or null.
  ///
  /// Rule-engine legality is checked separately, by [_applyEvent] — it needs the
  /// folded game, which is not available for a buffered event.
  MatchCheatException? _validate(EventFrame ef) {
    final authorSide = session.sideOf(ef.author);
    if (authorSide == null) {
      return MatchCheatException('not-a-participant',
          'event ${ef.seq} was written by "${ef.author}", who is not one of '
              'the two players.');
    }
    // ATTRIBUTED TO US, BUT NOT WRITTEN BY US.
    //
    // Every other check in this method reasons about the OPPONENT's events; an
    // event stamped with our own author is normally the echo of something we
    // sent, and the fold treats it as such (it unlatches the gate, and a fold
    // failure on it routes to a resync rather than a freeze — see
    // [_onFoldFailure]). But the author is a value the other end chose: on a LAN
    // the host stamps it, and a modified host can therefore play OUR seat by
    // writing an event as us, with a fold failure that self-heals into a resync
    // instead of accusing anyone. We know precisely what we wrote — see
    // [_ownWrites]/[_ownWriteFloor] — so this is provable rather than merely
    // suspicious.
    final floor = _ownWriteFloor;
    if (ef.author == _author && floor != null && ef.seq >= floor) {
      if (!(_ownWrites[ef.seq]?.contains(_fingerprint(ef.event)) ?? false)) {
        return MatchCheatException(
            'forged-as-us',
            'event ${ef.seq} (${ef.event.runtimeType}) is attributed to this '
                'device, which never wrote it.');
      }
    }
    final event = ef.event;
    final actor = _actorOf(event);
    if (actor != null && actor != authorSide) {
      return MatchCheatException(
          'wrong-author',
          'event ${ef.seq} claims to be $actor\'s but was written by the '
              '$authorSide player.');
    }
    // The ONE match-configuration rule the rules engine cannot see: a [Game]
    // knows nothing about the cubeless flag, which lives in the session's
    // [MatchConfig]. `HostAuthority` used to refuse this submission before it
    // entered the log; with no referee left, the honest peer refuses it on the
    // fold instead — otherwise a hostile client could double in a match both
    // players agreed to play without a cube.
    if (event is DoubleEvent && cubeless) {
      return MatchCheatException(
          'cube-in-cubeless',
          'event ${ef.seq} offers the doubling cube in a match agreed to be '
              'played without it.');
    }
    if (event is OpeningRollEvent && ef.author != session.hostAuthor) {
      return MatchCheatException('opening-not-host',
          'the opening roll of game ${ef.gameNo} must be made by the host.');
    }
    if (event is! OpeningRollEvent && event is! RollEvent) return null;

    final n = _rollCount + 1;
    final doc = _rolls[n];
    final roll = doc?.completed;
    if (doc == null || roll == null) {
      // _drainLoop only ingests once the frame is complete, so this can only be
      // a corrupted local cache; treat it as a protocol failure rather than
      // trusting unverified dice.
      return MatchCheatException(
        'dice-mismatch',
        'event ${ef.seq} carries dice with no completed roll $n behind them.',
        headline: MatchCheatException.dice,
      );
    }
    if (doc.roller != ef.author) {
      return MatchCheatException(
        'roll-author',
        'roll $n was committed by "${doc.roller}" but the resulting event was '
            'written by "${ef.author}".',
        headline: MatchCheatException.dice,
      );
    }
    final forgedEntropy = _witnessEntropyFailure(doc);
    if (forgedEntropy != null) return forgedEntropy;
    try {
      final ok = event is OpeningRollEvent
          ? openingDiceMatchRoll(roll, event)
          : diceMatchRoll(roll, event as RollEvent);
      if (ok) return null;
      return MatchCheatException(
        'dice-mismatch',
        'event ${ef.seq} does not carry the dice roll $n derives.',
        headline: MatchCheatException.dice,
      );
    } on FairDiceCheatException catch (e) {
      return MatchCheatException(
        'fair-dice',
        'the secret revealed for roll $n does not match its commitment ($e).',
        headline: MatchCheatException.dice,
      );
    }
  }

  /// The seat an event acts for, or null for the [OpeningRollEvent] (which
  /// belongs to no seat — see the opening-roller convention).
  static Player? _actorOf(GameEvent e) => switch (e) {
        OpeningRollEvent() => null,
        RollEvent(:final player) => player,
        MoveEvent(:final player) => player,
        DoubleEvent(:final player) => player,
        TakeEvent(:final player) => player,
        DropEvent(:final player) => player,
        ResignOfferEvent(:final player) => player,
        ResignAcceptEvent(:final player) => player,
        ResignDeclineEvent(:final player) => player,
      };

  void _applyEvent(EventFrame ef) {
    _gameNumber = ef.gameNo;
    try {
      _fold(ef);
    } on StateError catch (e) {
      _onFoldFailure(ef, e.message);
      return;
    } on ArgumentError catch (e) {
      _onFoldFailure(ef, '${e.message}');
      return;
    }
    if (!_replacing) _afterFold();
  }

  /// The rules engine refused an event that is already in the log.
  ///
  /// There is no "the server ordered it differently" reading of this any more: if
  /// the OPPONENT wrote it, its client broke the rules and the match freezes. Our
  /// own event failing to fold means our view was behind (someone else's event
  /// landed at that seq first), which a re-read fixes — unless we are already
  /// replaying a freshly fetched log, in which case re-reading would only find
  /// the same thing.
  void _onFoldFailure(EventFrame ef, String detail) {
    if (ef.author != _author) {
      _freeze(MatchCheatException('illegal-event',
          'event ${ef.seq} (${ef.event.runtimeType}) is not legal here: '
              '$detail'));
      return;
    }
    if (_replacing) {
      _replaceFailure =
          NetMatchException('diverged', 'the match log did not replay: $detail');
      return;
    }
    _resync('local state diverged on our own event ${ef.seq}');
  }

  void _fold(EventFrame ef) {
    var event = ef.event;
    if (event is OpeningRollEvent) {
      _game = Game.start(event, isCrawfordGame: _match.isCrawfordNext);
      return;
    }
    // The board the event is about to fold onto — the animation's starting
    // position, knowable only here (several events may fold between two painted
    // frames, so an observer cannot recover it from [state]). See [AppliedMove].
    final preBoard = _game!.state.board;
    event = _canonicalise(event);
    final next = _game!.append(event);
    _game = next;
    // NOT published during a full replace: [lastMove] drives a cosmetic
    // animation, and a rebuild replaying fifty historical moves must snap to the
    // rebuilt position rather than re-play the game.
    if (event is MoveEvent && !_replacing) {
      _lastMove.value = AppliedMove(event, preBoard);
    }
    if (next.state.phase != GamePhase.gameOver) return;
    _foldTail(ef, next);
  }

  /// The ENGINE's rendering of [event], never the submitter's.
  ///
  /// [Game.append] computes the next state from the canonical play but STORES
  /// what it was handed, so without this the peer's own rendering is what reaches
  /// [lastMove] (the animation) and `Game.events` (the log handed to
  /// [MatchPersistence.onGameFinished], and therefore the analysis replay).
  /// `HostAuthority` used to close this by rewriting the entry before it entered
  /// the authoritative log; with the referee gone, the folding peer closes it on
  /// the way in instead.
  ///
  /// Two things a peer can get wrong while still submitting a LEGAL play, both of
  /// which [GameState.canonicalPlay] normalises away:
  ///
  ///  * **false `isHit` flags** — cosmetic to the rules engine (which recomputes
  ///    hits from the board) but not to the history: a replay would draw hits
  ///    that never happened, or miss ones that did;
  ///  * **a non-canonical hop decomposition** — a route that reaches the same
  ///    position through a point the mover's own checker only transits.
  ///    [BoardState.applyMove] is order-dependent there, so replaying the
  ///    submitted route rather than the generator's representative can land on a
  ///    different board.
  ///
  /// Done HERE (at fold time) rather than in [Game.append]: `append` is also the
  /// local/AI and analysis-replay path, where the caller has just taken the move
  /// FROM the generator and a second canonicalisation would be pure cost — and
  /// where an already-canonical event must fold byte-identically. The networked
  /// fold is the only caller whose input is untrusted.
  ///
  /// Returns [event] unchanged for everything that is not a move, and for a move
  /// the engine refuses (so [Game.append] raises the same violation it always
  /// did, and the freeze/resync routing in [_onFoldFailure] is untouched).
  GameEvent _canonicalise(GameEvent event) {
    if (event is! MoveEvent) return event;
    final s = _game!.state;
    if (s.phase != GamePhase.moving || s.turn != event.player) return event;
    final canonical = s.canonicalPlay(event.move);
    if (canonical == null) return event;
    return MoveEvent(event.player, canonical);
  }

  /// The game-over half of [_fold], split out only to keep that method short.
  void _foldTail(EventFrame ef, Game next) {
    _lastFinishedGameNo = ef.gameNo;
    final result = next.state.result!;
    _match = _match.applyResult(result);
    // Persist the JUST-finished game with its COMPLETE event log. This fires at
    // the applyResult moment — before any of the next game's events fold (they
    // buffer while [_awaitingNextGame]) — so [next.events] is the whole game.
    if (ef.gameNo > _persistedThrough) {
      _persistedThrough = ef.gameNo;
      _persist(() => persistence.onGameFinished(
            gameNumber: ef.gameNo,
            isCrawford: next.state.isCrawfordGame,
            events: next.events,
            result: result,
            matchAfter: _match,
          ));
    }
    if (_match.isMatchOver) {
      if (!_matchPersisted) {
        _matchPersisted = true;
        _persist(() => persistence.onMatchFinished(_match));
      }
    } else if (ef.gameNo > _acknowledgedThrough) {
      // Pause for the game-over dialog — unless this is a replay of a game the
      // user already dismissed.
      _awaitingNextGame = true;
    }
  }

  void _afterFold() {
    // A successful fold proves the stream is healthy again: clear any transient
    // read/submit error so it stays a passing banner rather than a sticky gate.
    // A freeze is NOT transient and survives.
    if (!frozen) _transientError = null;
    if (_game != null) _completeReady();
    _markCompleteIfOver();
    _refreshPending();
    _notify();
  }

  /// End-of-match bookkeeping, once. Best effort — the log stays the authority —
  /// so a failure here is swallowed rather than surfaced.
  void _markCompleteIfOver() {
    if (_completionSent || !_match.isMatchOver || _disposed) return;
    _completionSent = true;
    unawaited(() async {
      try {
        await transport.complete();
      } catch (_) {
        // Bookkeeping only: the event log already decides the match.
      }
    }());
  }

  /// Recomputes the local-side pending notifiers from the current game state.
  void _refreshPending() {
    if (_disposed) return;
    final g = _game;
    final active =
        g != null && !frozen && !_match.isMatchOver && !_awaitingNextGame;
    final s = g?.state;
    final side = _session?.assignedSide;
    _pendingMove.value =
        (active && side != null && s!.phase == GamePhase.moving && s.turn == side)
            ? s
            : null;
    _pendingCube.value = (active &&
            side != null &&
            s!.phase == GamePhase.cubeOffered &&
            s.turn == side)
        ? s
        : null;
    _pendingResign.value = (active &&
            side != null &&
            s!.phase == GamePhase.resignOffered &&
            s.turn == side)
        ? (s, s.resignOffer!.value)
        : null;
  }

  // --- resync ----------------------------------------------------------------

  /// The identity of the match the watermarks describe.
  ///
  /// A resume token names the authority that issued it. A DIFFERENT token on the
  /// same controller means we are looking at a different match — the host
  /// restarted and minted a fresh one, or a room-code collision put us on
  /// someone else's. Its games have not been persisted, its dialogs have not been
  /// shown, and its game numbers restart at 1, so every watermark from the old
  /// match is void. Carrying them over is how a second match would silently never
  /// be recorded.
  void _adoptIdentity(String? identity) {
    _identityChanged = false;
    if (identity == null || identity == _matchIdentity) return;
    final hadOne = _matchIdentity != null;
    _matchIdentity = identity;
    if (!hadOne) return; // the first token simply names the match
    _identityChanged = true;
    _persistedThrough = 0;
    _acknowledgedThrough = 0;
    _matchPersisted = false;
    _completionSent = false;
    // A different match has a different log, so what THIS device wrote into the
    // old one says nothing about who wrote the new one's entries — and what we
    // witnessed of the old match's roll 3 says nothing about the new one's.
    _ownWrites.clear();
    _ownWriteFloor = null;
    _witnesses.clear();
    _roller = null;
    _rollFloor = null;
    // A different log is entitled to a fresh set of replay attempts.
    _failedReplays = 0;
  }

  /// Re-read the whole match and rebuild from scratch. The ONLY recovery path:
  /// with nothing to snapshot from, scores and game numbers can only be
  /// re-derived by replaying the log.
  void _resync(String why) {
    if (_disposed || frozen) return;
    if (_failedReplays >= _maxFailedReplays) {
      // See [_failedReplays]: re-reading a log that has refused to replay three
      // times running cannot succeed the fourth, and each attempt costs the whole
      // log. Surface it and stop.
      _transientError = NetMatchException('diverged',
          '$why; the match log has failed to replay $_failedReplays times — '
              'not re-reading it again');
      _submitting = false;
      _notify();
      return;
    }
    _transientError = NetMatchException('diverged', '$why; resyncing');
    _submitting = false;
    _notify();
    // A replace already in flight will fetch the very latest log anyway, so a
    // second request would only cost a round trip.
    if (_resyncing) return;
    _resyncReason = why;
    _resyncAttempts = 0;
    unawaited(_runReplace());
  }

  Future<void> _runReplace() async {
    if (_resyncing) {
      // A ResetFrame arriving mid-replace must not be dropped: the log it points
      // at may be a DIFFERENT one.
      _replaceAgain = true;
      return;
    }
    _resyncing = true;
    try {
      do {
        _replaceAgain = false;
        await _replaceFromLog();
      } while (_replaceAgain && !_disposed && !frozen);
    } finally {
      _resyncing = false;
    }
    if (!_disposed && !frozen) unawaited(_pumpRolls());
  }

  Future<void> _replaceFromLog() async {
    try {
      // Rolls FIRST: the events fetched next are validated against them.
      final rolls = await transport.rollsSince(1);
      final events = await transport.eventsSince(0);
      if (_disposed) return;
      _cancelResyncRetry();
      _rebuild(events, rolls);
    } catch (e) {
      if (_disposed || frozen) return;
      _transientError = e;
      _armResyncRetry();
      _notify();
    }
  }

  /// One retry of a failed replace in flight at a time, bounded.
  ///
  /// A replace can fail transiently and nothing else would wake it — a peer that
  /// is behind AND on turn receives no further frames, ever — so the chain
  /// retries on its own, at the transport's cadence and bounded by
  /// [_maxResyncAttempts] so a dead peer is not hammered.
  void _armResyncRetry() {
    if (_disposed || _resyncRetry != null) return;
    if (++_resyncAttempts >= _maxResyncAttempts) return;
    _resyncRetry = Timer(_retryBeat, () {
      _resyncRetry = null;
      if (_disposed || frozen) return;
      _transientError =
          NetMatchException('diverged', '$_resyncReason; resyncing');
      unawaited(_runReplace());
    });
  }

  void _cancelResyncRetry() {
    _resyncRetry?.cancel();
    _resyncRetry = null;
    _resyncAttempts = 0;
  }

  /// Replay [events] over a clean slate. The persistence/acknowledgement
  /// watermarks survive so a rebuild neither records a game twice nor re-opens a
  /// dialog the user already dismissed.
  void _rebuild(List<EventFrame> events, List<RollFrame> rolls) {
    // Established ONCE per match identity, on the first log we ever see: every
    // roll above it is one whose whole handshake happened while we were folding.
    _rollFloor ??=
        rolls.isEmpty ? 0 : rolls.map((r) => r.n).reduce((a, b) => a > b ? a : b);
    _rolls
      ..clear()
      ..addEntries(rolls.map((r) => MapEntry(r.n, r)));
    for (final roll in rolls) {
      if (!_verifyRollDoc(roll)) return;
    }
    _match = MatchState(matchLength: session.config.length);
    _game = null;
    _gameNumber = 0;
    _lastSeq = 0;
    _rollCount = 0;
    _openingsIngested = 0;
    _lastFinishedGameNo = 0;
    _awaitingNextGame = false;
    _submitting = false;
    _buffer = [];
    // NON-LOSSY: a live frame that arrived while the fetch was in flight is kept
    // and merged by seq rather than thrown away (dropping it would open a gap the
    // next event has to resync out of).
    final queued = List<EventFrame>.from(_inbox);
    _inbox
      ..clear()
      ..addAll(events);
    for (final ef in queued) {
      if (!_inbox.any((e) => e.seq == ef.seq)) _inbox.add(ef);
    }
    _inbox.sort((a, b) => a.seq.compareTo(b.seq));
    _contestedRoll = null;
    _replacing = true;
    _replaceFailure = null;
    _drainInbox();
  }

  /// End a full replace — but ONLY once the inbox has actually drained.
  ///
  /// A replay can stop part-way: a roll frame that has to be fetched leaves the
  /// trailing events queued. Clearing [_replacing] at that point would let those
  /// events fold as if they were LIVE — re-animating history through [lastMove],
  /// and sending a fold failure down the resync branch instead of the
  /// replace-failed one. So the flag survives until the queue is empty (or the
  /// replay has already failed), while the state that HAS folded is still
  /// published so the UI can come up rather than hang on [ready].
  void _finishReplace() {
    if (!_replacing) return;
    if (_inbox.isNotEmpty && _replaceFailure == null && !frozen) {
      if (_game != null) _completeReady();
      _refreshPending();
      _notify();
      return;
    }
    _replacing = false;
    if (frozen) return;
    final failure = _replaceFailure;
    if (failure == null) {
      // The log replayed: whatever the divergence was, it is gone.
      _failedReplays = 0;
      _afterFold();
      return;
    }
    _failedReplays++;
    _transientError = failure;
    if (_game != null) _completeReady();
    _refreshPending();
    _notify();
  }

  // --- roll orchestration ----------------------------------------------------

  /// Advance every roll this device owes a step to — witness duties first (they
  /// unblock the opponent), then our own drive.
  ///
  /// Only one pump runs at a time, but a request that arrives DURING one is
  /// remembered and re-run rather than dropped: the roll frames it was about have
  /// already been consumed from the inbound stream, so dropping it would leave
  /// the protocol waiting for a change that has been and gone.
  Future<void> _pumpRolls() async {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    if (_disposed || frozen || !_started || _session == null) return;
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        await _witnessSteps();
        if (_disposed || frozen) return;
        await _rollerSteps();
      } while (_pumpAgain && !_disposed && !frozen);
    } on FairDiceCheatException catch (e) {
      _freeze(MatchCheatException(
        'fair-dice',
        'the revealed secret does not match the commitment that preceded our '
            'entropy ($e).',
        headline: MatchCheatException.dice,
      ));
      return;
    } on FormatException catch (e) {
      _freeze(MatchCheatException(
        'malformed-roll',
        'a roll frame carries a malformed protocol value ($e).',
        headline: MatchCheatException.dice,
      ));
      return;
    } catch (e) {
      if (_disposed || frozen) return;
      _transientError = e;
      // Re-open the pre-roll gate: a half-finished drive is RESUMED by the next
      // attempt, so the user pressing Roll again is a safe (and the only manual)
      // way out. The timer covers the drives no button can restart.
      _submitting = false;
      _armRollRetry();
      _notify();
    } finally {
      _pumping = false;
      _pumpAgain = false;
    }
    if (!_disposed && !frozen) _notify();
  }

  /// The beat for the controller's OWN self-healing retries.
  ///
  /// The transport's [MatchTransport.inboundCadence] is the natural pace — a
  /// fast-polling transport heals fast, a slow one does not spin — but a PUSH
  /// transport reports zero, and a zero-duration self-rearming timer is a spin.
  /// So it is floored.
  Duration get _retryBeat {
    final cadence = transport.inboundCadence;
    return cadence > _minRetryBeat ? cadence : _minRetryBeat;
  }

  static const Duration _minRetryBeat = Duration(milliseconds: 200);

  /// One paced re-drain in flight at a time, at the transport's own cadence.
  ///
  /// The drain is normally woken by an inbound frame; this only covers a stream
  /// that has stalled, and it is deliberately no faster than the transport so a
  /// roll that never completes costs a bounded trickle of reads rather than a
  /// flood.
  void _armInboxRetry() {
    if (_inboxRetry != null || _disposed) return;
    _inboxRetry = Timer(_retryBeat, () {
      _inboxRetry = null;
      if (_disposed || frozen) return;
      _drainInbox();
    });
  }

  /// One retry in flight at a time. Needed because a stalled drive may produce
  /// no further frames, so nothing else would wake it.
  void _armRollRetry() {
    if (_rollRetry != null || _disposed) return;
    _rollRetry = Timer(_retryBeat, () {
      _rollRetry = null;
      if (_disposed || frozen) return;
      unawaited(_pumpRolls());
    });
  }

  /// True iff no game is currently under way, so the next roll to be made is an
  /// opening roll (the host's by convention).
  bool get _openingIsDue =>
      _openingsIngested == 0 || _lastFinishedGameNo == _openingsIngested;

  /// True iff [roll] is the ONE roll the log says is outstanding right now.
  ///
  /// Two bindings, and the FIRST is the security-critical one:
  ///
  ///  * **index** — a witness answers only roll `_rollCount + 1`. Answering any
  ///    later index is the dice-LOOKAHEAD break: each peer's turn parity is
  ///    predictable, so a hostile client pre-creates the roll frames for its own
  ///    coming turns; if we hand them entropy it can reveal to itself and know
  ///    several of its future rolls before choosing a move or a double. The dice
  ///    stay unbiased and nothing ever folds illegally, so no other check in this
  ///    class would catch it. The strict-sequential index is the same invariant
  ///    [_validate] already enforces, so binding to it cannot deadlock a peer
  ///    that is playing properly.
  ///  * **turn** — the roller must be the side actually due to roll (the host for
  ///    an opening). Defence in depth, and deliberately SKIPPED while the local
  ///    fold is behind the log on purpose (the game-over pause buffers events, a
  ///    replace is mid-replay): there the turn we can see is not the turn the roll
  ///    is for, and refusing would stall a peer that has properly moved on. The
  ///    index bound still holds in those windows.
  bool _isDueRoll(RollFrame roll) {
    if (roll.n != _rollCount + 1) return false;
    if (_awaitingNextGame || _buffer.isNotEmpty || _replacing) return true;
    final rollerSide = session.sideOf(roll.roller);
    if (rollerSide == null) return false;
    if (_openingIsDue) return rollerSide == TransportSession.hostSide;
    final g = _game;
    if (g == null) return true; // nothing folded yet — index bound only
    final s = g.state;
    return s.phase == GamePhase.awaitingRoll && rollerSide == s.turn;
  }

  /// Contribute entropy to (and verify the reveal of) the opponent's DUE roll.
  ///
  /// Answering anything else is the dice-lookahead break — see [_isDueRoll],
  /// which is also why this can never answer more than one frame per pump.
  Future<void> _witnessSteps() async {
    final pending = _rolls.values
        .where((r) => r.roller != _author && _isDueRoll(r))
        .toList()
      ..sort((a, b) => a.n.compareTo(b.n));
    for (final roll in pending) {
      if (_disposed || frozen) return;
      final w = _witnesses.putIfAbsent(roll.n, () {
        final drive = _WitnessDrive(roll.n, rng: rng);
        drive.session.seeCommit(roll.commit);
        return drive;
      });
      if (!w.entropySent) {
        if (roll.entropy != null) {
          // Already contributed (by an earlier attempt of ours).
          w.entropySent = true;
        } else {
          final value = w.session.phase == FairDicePhase.committed
              ? w.session.contributeEntropy()
              : w.session.entropy;
          try {
            await transport.sendEntropy(roll.n, value);
            w.entropySent = true;
          } on TransportRejected catch (e) {
            // Refused: the frame has moved past this phase. Never retryable, so
            // stop trying — the reveal check below still runs.
            w.entropySent = true;
            _transientError = e;
          }
        }
      }
      final reveal = roll.reveal;
      if (!w.verified && reveal != null) {
        w.verified = true;
        if (w.session.phase == FairDicePhase.entropy) {
          w.session.verifyReveal(reveal); // throws FairDiceCheatException
        }
      }
    }
  }

  /// Drive our own roll: create the commitment, wait for entropy, reveal, then
  /// append the derived roll to the event log. Every step is idempotent, so a
  /// failed pump can simply be run again.
  Future<void> _rollerSteps() async {
    _maybeStartOpeningRoll();
    final d = _roller;
    if (d == null || d.refused) return;

    if (!d.committed) {
      final commit = d.session.phase == FairDicePhase.fresh
          ? d.session.makeCommit()
          : d.session.commit;
      try {
        await transport.createRoll(d.n, commit);
        d.committed = true;
      } on TransportRejected catch (e) {
        // Refused on its merits, so an identical retry earns an identical
        // refusal — exactly the reading [_witnessSteps] takes of a refused
        // entropy write, and exactly why [_runSubmit] does not retry one
        // either. Left to the generic handler in [_pumpRolls] this would arm
        // the roll-retry timer and re-attempt the same write every beat, for
        // as long as the screen is open: an unbounded write loop against a
        // METERED backend. So: mark the step done, surface it, stop.
        _rejectRoll(d, e);
        return;
      } on TransportContested {
        final existing = await transport.fetchRoll(d.n);
        if (existing != null) _rolls[existing.n] = existing;
        if (existing != null &&
            existing.roller == _author &&
            existing.commit == commit) {
          d.committed = true; // an earlier attempt of ours did land
        } else {
          // The opponent claimed this index: only the player on turn creates a
          // roll, so our view of the log must be behind. Drop the drive and
          // rebuild — the roll we should be making may not be this one.
          _roller = null;
          _submitting = false;
          _resync('roll ${d.n} was claimed by the opponent');
          return;
        }
      }
      if (_disposed || frozen) return;
    }

    if (d.eventSent) return;
    final doc = _rolls[d.n];
    final entropy = doc?.entropy;
    if (entropy == null) return; // waiting on the witness

    if (d.session.phase == FairDicePhase.committed) {
      d.session.acceptEntropy(entropy);
    }
    d.revealValue ??= d.session.reveal();
    if (!d.revealSent) {
      if (doc!.reveal == null) {
        try {
          await transport.sendReveal(d.n, d.revealValue!);
        } on TransportRejected catch (e) {
          // Same reading as the commit above: deterministic, so not retryable.
          _rejectRoll(d, e);
          return;
        }
      }
      d.revealSent = true;
      if (_disposed || frozen) return;
    }

    final dice = d.opening ? d.session.openingDice : d.session.dice;
    final event = d.opening
        ? OpeningRollEvent(whiteDie: dice.die1, blackDie: dice.die2)
        : RollEvent(localSide, dice.die1, dice.die2);
    try {
      await _sendOwnEvent(
        seq: _lastSeq + 1,
        gameNo: d.gameNo,
        event: event,
      );
      d.eventSent = true;
    } on TransportContested {
      // Someone appended at our seq. Rebuild and let the drive retry from the
      // new tail (or retire, if the resync shows our event already landed).
      _resync('the log moved while appending roll ${d.n}');
    }
  }

  /// A roll write the backend REFUSED.
  ///
  /// [TransportRejected] means the write was judged and turned down — a rules
  /// condition that does not hold, a phase already past — so an identical retry
  /// earns an identical refusal. [_runSubmit] already declines to retry one for
  /// events and [_witnessSteps] for entropy; this is the same reading for the
  /// roller's own two writes, and it matters most here because this is the path
  /// with a TIMER behind it: left to [_pumpRolls]'s generic handler the drive
  /// re-attempts the refused write every [_retryBeat] for as long as the screen
  /// is open, which against a metered backend bills forever for a write that
  /// can never land.
  ///
  /// So the drive stops, the refusal is surfaced, and the pre-roll gate is
  /// re-opened — pressing Roll is a deliberate, bounded retry (see [rollDice]),
  /// which is the only retry a deterministic refusal deserves.
  void _rejectRoll(_RollerDrive d, TransportRejected e) {
    d.refused = true;
    _submitting = false;
    _transientError = NetMatchException('roll-rejected', e.message);
    _notify();
  }

  /// The HOST seat is the protocol roller for EVERY opening roll — nobody is on
  /// turn before one, so the seat cannot decide it. The joiner contributes
  /// entropy, so the roll is no less fair for being host-initiated.
  ///
  /// Started as soon as the previous game's result folds (not when the user
  /// dismisses the dialog): the resulting events simply buffer.
  ///
  /// Gated on [MatchTransport.opponentPresent]: with nobody in the other seat
  /// there is no witness, so the handshake would stall at the commit phase and
  /// hold the fast cadence open for nothing. (Replaces online's
  /// `matchDoc.guestUid == null` check and LAN's `guestConnected`.)
  void _maybeStartOpeningRoll() {
    if (_roller != null || !isHost || !transport.opponentPresent) return;
    if (_match.isMatchOver || _replacing || !_openingIsDue) return;
    final n = _rollCount + 1;
    if (_rolls.containsKey(n)) return; // already claimed (a previous session)
    _roller = _RollerDrive(
      n: n,
      opening: true,
      gameNo: _openingsIngested + 1,
      rng: rng,
    );
  }

  // --- submission ------------------------------------------------------------

  /// Submits a local decision at the log's next free sequence number.
  void _submitDecision(GameEvent event) {
    if (_submitting || _disposed || frozen || _game == null) return;
    final gameNo = _gameNumber;
    _runSubmit(() => _sendOwnEvent(
          seq: _lastSeq + 1,
          gameNo: gameNo,
          event: event,
        ));
  }

  /// [MatchTransport.sendEvent] plus the ledger entry — the ONE way this class
  /// appends, so nothing this device writes can be missing from [_ownWrites].
  Future<void> _sendOwnEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) {
    // Recorded BEFORE the await, and kept even if the write fails: a write that
    // times out may still have landed, and the echo of it must not look forged.
    (_ownWrites[seq] ??= <String>{}).add(_fingerprint(event));
    final floor = _ownWriteFloor;
    if (floor == null || seq < floor) _ownWriteFloor = seq;
    return transport.sendEvent(seq: seq, gameNo: gameNo, event: event);
  }

  /// A comparable rendering of [event] — the wire form, which is what the two
  /// peers actually exchange.
  static String _fingerprint(GameEvent event) => jsonEncode(event.toJson());

  /// Runs a submission with a single retry. A first failure is retried once; a
  /// second failure surfaces [error] and leaves any pending notifier set for a
  /// manual retry. Guards against concurrent/duplicate submits.
  ///
  /// A [TransportContested] is NOT retried: the sequence number is taken, so an
  /// identical retry would fail identically. It means our view of the log is
  /// behind, which only a resync fixes. A [TransportRejected] is not retried
  /// either — the refusal is deterministic.
  ///
  /// On SUCCESS the gate stays LATCHED until the event comes back on `inbound`
  /// and folds (see [_ingest]) — "committed" is not "folded", and re-enabling the
  /// controls on a state the log is about to move past is how a player submits the
  /// same decision twice. [gateTimeout] bounds the wait so a dropped echo cannot
  /// end the match.
  Future<void> _runSubmit(Future<void> Function() op) async {
    if (_submitting || _disposed || frozen) return;
    _submitting = true;
    _notify();
    Object? failure;
    var lostRace = false;
    try {
      await op();
    } on TransportContested catch (e) {
      failure = e;
      lostRace = true;
    } on TransportRejected catch (e) {
      failure = NetMatchException('rejected', e.message);
      lostRace = e.peerLastSeq != null && e.peerLastSeq! > _lastSeq;
    } catch (_) {
      try {
        await op();
      } on TransportContested catch (e) {
        failure = e;
        lostRace = true;
      } on TransportRejected catch (e) {
        failure = NetMatchException('rejected', e.message);
        lostRace = e.peerLastSeq != null && e.peerLastSeq! > _lastSeq;
      } catch (e) {
        failure = e;
      }
    }
    if (_disposed) return;
    // A failure re-opens the gate at once; a success holds it until the log
    // answers (or [gateTimeout] gives up on it).
    if (failure != null) _submitting = false;
    // Clears a prior error on success; set on failure. A freeze outranks both.
    _transientError = failure;
    _refreshPending();
    _notify();
    if (lostRace) _resync('our submission lost the race for a sequence number');
  }

  /// Nothing answered an intent that DID commit.
  ///
  /// A relay can drop the echo of a committed write (over a rate limit, or on a
  /// socket it is about to reap) SILENTLY, and no protocol replays it. So "wait
  /// for the log to answer" is not on its own a terminating condition, and
  /// without this the player's controls would stay dead for the rest of the
  /// match. Re-open the gate and say so; a half-finished roll drive is RESUMED by
  /// the next attempt.
  void _onGateTimeout() {
    if (_disposed || !_submitting) return;
    _submitting = false;
    _transientError = const NetMatchException(
        'offline', 'the other device did not answer — try again');
    _refreshPending();
    _notify();
  }

  // --- helpers ---------------------------------------------------------------

  /// Stop everything, permanently, and say why.
  void _freeze(MatchCheatException violation) {
    if (_cheatError != null) return;
    _cheatError = violation;
    _roller = null;
    _submitting = false;
    _inbox.clear();
    _buffer = [];
    _rollRetry?.cancel();
    _rollRetry = null;
    _inboxRetry?.cancel();
    _inboxRetry = null;
    _resyncRetry?.cancel();
    _resyncRetry = null;
    _completeReady();
    _refreshPending();
    _notify();
  }

  void _completeReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  bool _localActsNow(GameState s) {
    switch (s.phase) {
      case GamePhase.awaitingRoll:
      case GamePhase.moving:
      case GamePhase.cubeOffered:
      case GamePhase.resignOffered:
        return s.turn == localSide;
      case GamePhase.gameOver:
        return false;
    }
  }

  bool _doublingLegal(GameState s) =>
      s.phase == GamePhase.awaitingRoll &&
      !s.isCrawfordGame &&
      (s.cube.owner == null || s.cube.owner == s.turn);

  void _requireLocal(Player side) {
    if (side != localSide) {
      throw StateError('$side is not the local side');
    }
  }

  /// Runs a persistence [hook], chained after any in-flight one, swallowing a
  /// failure into [persistenceError] so the fold is never interrupted by the
  /// storage layer.
  void _persist(Future<void> Function() hook) {
    _persistChain = _persistChain.then((_) async {
      if (_disposed) return;
      try {
        await hook();
      } catch (e) {
        _persistenceError = e;
        _notify();
      }
    });
  }

  /// Tell the transport whether latency matters right now — the ONE pacing lever
  /// the controller has. Sent only on a change, from the one place every state
  /// transition funnels through.
  void _applyPaceHint() {
    if (_disposed || _session == null) return;
    final fast = _diceProtocolInFlight;
    if (_paceFast == fast) return;
    _paceFast = fast;
    transport.setPaceHint(fast: fast);
  }

  void _notify() {
    if (_disposed) return;
    _applyPaceHint();
    notifyListeners();
  }
}
