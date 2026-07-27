import 'dart:async';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:online_client/online_client.dart';

import '../data/persistence_hooks.dart';
import '../game/applied_move.dart';
import '../game/match_controller.dart';
import '../game/player_agent.dart';

/// A PROVEN protocol violation by the other client — the one fault an online
/// match never recovers from.
///
/// There is no server in the serverless model, so the honest peer IS the
/// referee: it re-derives every roll from the commit-reveal documents and
/// replays every event through the rules engine. When something does not add
/// up, the match is FROZEN rather than repaired — silently accepting an event
/// the rules engine refuses would be accepting a cheat, and refetching cannot
/// help because the log is exactly what the opponent wrote.
///
/// Distinct from a transient [OnlineException] on purpose: transient faults
/// self-heal on the next successful fold, a freeze never does.
class OnlineCheatException implements Exception {
  const OnlineCheatException(this.code, this.detail, {this.headline = illegal});

  /// The headline used for rule-breaking events (out of turn, wrong author, a
  /// move the engine refuses).
  static const String illegal =
      "Opponent's client sent an illegal move — match frozen.";

  /// The headline used for a broken commit-reveal (tampered reveal, dice that
  /// do not match the roll the two peers agreed on).
  static const String dice =
      "Opponent's client sent tampered dice — match frozen.";

  /// A stable machine code: `not-a-participant`, `wrong-author`,
  /// `opening-not-host`, `roll-author`, `dice-mismatch`, `fair-dice`,
  /// `malformed-roll`, `illegal-event`.
  final String code;

  /// What exactly was violated, appended to [headline].
  final String detail;

  final String headline;

  /// The single line the UI shows.
  String get message => '$headline $detail';

  @override
  String toString() => message;
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

  /// The `rolls/{n}` index this drive owns.
  final int n;

  /// True for a game's opening roll (derived with [openingDiceFrom], written as
  /// an [OpeningRollEvent]).
  final bool opening;

  /// The `gameNo` the resulting event is stamped with.
  final int gameNo;

  final RollerSession session;

  /// The commitment document exists.
  bool committed = false;

  /// The secret has been taken out of the session — held here so a failed
  /// `submitReveal` can be retried (the session is single-use).
  String? revealValue;

  /// The reveal has landed (or was already present).
  bool revealSent = false;

  /// The derived roll has been appended to the event log.
  bool eventSent = false;
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

/// A [MatchController] driven by a Firestore event log, with NO server.
///
/// The `matches/{code}/events` collection IS the game: this controller folds the
/// seq-contiguous events into a [Game]/[MatchState] and appends only the local
/// side's decisions. Everything a Cloud Function used to do now happens here or
/// in `firebase/firestore.rules`.
///
/// ## Dice — the commit-reveal protocol
///
/// Neither peer may pick its own dice, so every roll goes through
/// `matches/{code}/rolls/{n}` (see `fair_dice.dart`):
///
///  * the ROLLER publishes `commit = sha256(secretA)`, waits for the witness's
///    `entropy`, publishes `reveal = secretA`, derives the dice from
///    `sha256(A ‖ B)` and appends the [RollEvent] / [OpeningRollEvent];
///  * the WITNESS sees the commit, contributes `entropy`, verifies the reveal
///    against the commitment, and re-derives the same dice to check that the
///    roller's event carries EXACTLY them.
///
/// Two conventions make the two clients agree without talking:
///
///  * **the roll index** `n` is `1 + (number of roll-bearing events already in
///    the log)` — counting [OpeningRollEvent]s and [RollEvent]s across the whole
///    match. Both peers fold the same log, so both compute the same `n`, and it
///    is recovered for free by a resync (which recounts from the log);
///  * **the opening roller is always the HOST.** Nobody is "on turn" before the
///    opening roll, so the seat cannot decide it; the host creates it, the guest
///    contributes entropy, and fairness holds regardless of who committed.
///
/// A losing race on [MatchApi.createRoll] ([AlreadyExistsException]) means our
/// roll counter is behind the log, so the drive is dropped and the whole log is
/// refetched.
///
/// ## Validation — the honest client is the referee
///
/// Every event authored by the OPPONENT is checked before it folds:
///
///  1. the author must be a participant, and the seat it claims
///     ([MatchDoc.sideOf]: host = white, guest = black) must match the event's
///     player; an [OpeningRollEvent] must come from the host;
///  2. a roll-bearing event must carry exactly the dice its `rolls/{n}` document
///     derives ([diceMatchRoll] / [openingDiceMatchRoll]), and that document's
///     `roller` must be the event's author;
///  3. the rules engine must accept it ([Game.append] throws otherwise).
///
/// Any failure FREEZES the match with an [OnlineCheatException] — see
/// [cheatError]. A freeze stops folding, stops rolling, closes every gate and
/// never self-heals, unlike the transient [error] a poll blip produces.
///
/// ## Divergence and resync
///
/// The only recovery path is a FULL REPLACE: refetch every event and roll and
/// rebuild from scratch (there is no server snapshot to seed scores from — the
/// log is the only truth). Three watermarks survive it so a rebuild does not
/// re-fire history the user already lived through: [_persistedThrough],
/// [_matchPersisted] and [_acknowledgedThrough].
///
/// ## Game-end pause
///
/// The host appends the next game's opening roll as soon as a game ends, but the
/// UI still shows a game-over dialog. A finished game sets [awaitingNextGame] and
/// BUFFERS every later event until [continueToNextGame] drains the queue.
class OnlineMatchController extends ChangeNotifier implements MatchController {
  OnlineMatchController({
    required this.api,
    required this.matchDoc,
    this.persistence = const NoopPersistence(),
    this.pollInterval = const Duration(seconds: 2),
    this.rng,
  })  : localSide = _seatOf(api, matchDoc),
        _match = MatchState(matchLength: matchDoc.length);

  /// The seat this device plays, from the match document. Host = white.
  static Player _seatOf(MatchApi api, MatchDoc doc) {
    final side = doc.sideOf(api.uid);
    if (side == null) {
      throw ArgumentError.value(doc.code, 'matchDoc',
          'this user (${api.uid}) is not a participant in the match');
    }
    return side;
  }

  /// The transport: auth + direct Firestore documents. No callables.
  final MatchApi api;

  /// The match document, which carries the invite code (the match id), the
  /// seats and the match options. Immutable for the controller's lifetime —
  /// only `status` ever changes server-side, and completion is derived locally.
  final MatchDoc matchDoc;

  /// The seat whose decisions are submitted; the other side is the opponent's.
  final Player localSide;

  /// Persistence seam invoked as the match progresses. Defaults to a no-op so
  /// play works with persistence off; a failing hook is non-fatal (see
  /// [_persist]).
  final MatchPersistence persistence;

  /// The RESTING cadence at which the poll stream fetches new events and roll
  /// documents — used whenever no dice handshake is in flight. See
  /// [currentPollInterval] for the fast window.
  final Duration pollInterval;

  /// The cadence used while a commit-reveal roll is in flight.
  ///
  /// Capped at [pollInterval] so a caller that asks for a SLOWER-than-500ms
  /// resting cadence is not silently sped up, and so the emulator E2E's
  /// `AIGAMMON_E2E_POLL_MS` knob keeps overriding both intervals with one
  /// number.
  Duration get fastPollInterval =>
      pollInterval < _fastPoll ? pollInterval : _fastPoll;

  static const Duration _fastPoll = Duration(milliseconds: 500);

  /// The interval the poll loop is using RIGHT NOW.
  ///
  /// A roll is three document writes that alternate between the two peers
  /// (commit → entropy → reveal), and each peer only learns of the other's step
  /// by polling — so at the resting 2s cadence a single roll burns about three
  /// poll latencies, roughly six seconds of dead time per turn. Polling fast
  /// for exactly as long as a handshake is outstanding removes that.
  ///
  /// READ BUDGET (the Spark free tier allows 50K document reads a day): this is
  /// close to free, because the fast window is bounded by PROTOCOL STEPS rather
  /// than by wall time. The peers need the same ~3 cycles to observe the same 3
  /// phase changes whether each cycle is 500ms or 2s; polling faster mostly
  /// shortens the window rather than adding cycles to it. The extra reads are
  /// only the cycles a peer spends waiting on the OTHER peer's app being slow,
  /// and those windows are seconds long — a match's daily read cost barely
  /// moves, while every turn loses ~4.5s of staring at nothing.
  Duration get currentPollInterval =>
      _diceProtocolInFlight ? fastPollInterval : pollInterval;

  /// True while a `rolls/{n}` handshake is outstanding for EITHER side: from
  /// the moment a drive of ours exists (its commitment is written immediately
  /// after) or a roll document we have not folded yet is seen, until that
  /// roll's event folds and pushes [_rollCount] past it.
  ///
  /// A drive that stalls (a peer that walks away mid-handshake) therefore holds
  /// the fast window open until the user leaves the match. That costs a few
  /// hundred extra reads an hour at worst, which is the cheaper side of the
  /// trade against making a live handshake feel slow.
  bool get _diceProtocolInFlight {
    if (frozen || _match.isMatchOver) return false;
    if (_roller != null) return true;
    for (final n in _rolls.keys) {
      if (n > _rollCount) return true;
    }
    return false;
  }

  /// Injected only by tests, to make protocol secrets reproducible. NEVER
  /// non-null in production — a predictable secret is a predictable roll, and a
  /// predictable roll is a riggable one.
  @visibleForTesting
  final Random? rng;

  /// The match id: the invite code, which is the document id.
  String get matchId => matchDoc.code;

  /// True when this device created the match (and so plays white AND is the
  /// protocol roller for every opening roll).
  bool get isHost => api.uid == matchDoc.hostUid;

  String get _uid => api.uid;

  Game? _game;
  MatchState _match;

  /// The 1-based number of the current game within the match. `0` until the
  /// first event folds.
  int _gameNumber = 0;

  /// The last INGESTED sequence number; events must be contiguous with it.
  int _lastSeq = -1;

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

  /// Whether `status: 'complete'` has been written to the match document.
  bool _completionSent = false;

  bool _awaitingNextGame = false;
  bool _submitting = false;
  bool _started = false;
  bool _disposed = false;
  bool _replacing = false;
  bool _resyncing = false;

  /// A transient fault (poll blip, failed submission). Cleared by the next
  /// successful fold.
  Object? _transientError;

  /// A proven protocol violation. Never cleared — see [OnlineCheatException].
  OnlineCheatException? _cheatError;

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

  StreamSubscription<MatchPoll>? _sub;

  /// Events fetched but not yet ingested. Normally drained to empty on arrival;
  /// an entry stays only while its `rolls/{n}` document is still being fetched
  /// (validation cannot run without it).
  final List<RemoteEvent> _inbox = [];

  /// Events ingested while paused between games, folded on [continueToNextGame].
  List<RemoteEvent> _buffer = [];

  /// Every roll document seen, by index. The validation side reads it to
  /// re-derive what a roll event was REQUIRED to say.
  final Map<int, RollDoc> _rolls = {};

  /// Roll indices with a `fetchRoll` in flight (see [_drainInbox]).
  final Set<int> _fetchingRolls = {};

  _RollerDrive? _roller;
  final Map<int, _WitnessDrive> _witnesses = {};

  bool _pumping = false;

  /// A pump was requested while one was running; see [_pumpRolls].
  bool _pumpAgain = false;
  Timer? _rollRetry;

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

  /// Completes once the controller [isReady] (the first game has folded), or
  /// when it is disposed beforehand. Callers should `await` this, then check
  /// [isReady] — a disposed-before-ready controller completes the future but
  /// leaves [isReady] `false`, so the caller can bail without reading [state].
  Future<void> get ready => _ready.future;

  /// The proven protocol violation that froze this match, or `null`.
  ///
  /// While non-null the controller is inert: nothing folds, no roll advances,
  /// every gate is shut, and [error] keeps reporting this. The UI should show
  /// [OnlineCheatException.message] prominently — the match cannot continue.
  OnlineCheatException? get cheatError => _cheatError;

  /// True while the match is frozen by a [cheatError].
  bool get frozen => _cheatError != null;

  /// The most recently folded move (for the animation layer), or `null`.
  @override
  ValueListenable<AppliedMove?> get lastMove => _lastMove;

  /// True while waiting on the opponent (the match is active but it is NOT the
  /// local side's moment to act).
  ///
  /// Deliberately does NOT gate on a transient [error]: a poll/submit blip is a
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

  /// Whether this match is played without the doubling cube. Unlike the
  /// callable era (where the cube was server-mediated and the option did not
  /// exist online) the choice now travels in the match document, so both peers
  /// honour the same setting.
  @override
  bool get cubeless => matchDoc.cubeless;

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

  // --- lifecycle -------------------------------------------------------------

  @override
  Future<void> playMatch() async {
    if (_started || _disposed) return;
    _started = true;
    await _replaceFromServer();
    if (_disposed) return;
    _sub = api
        .pollMatch(
          matchId,
          // Asked once per cycle, so the loop tightens the moment a dice
          // handshake starts and relaxes when it folds — see
          // [currentPollInterval].
          interval: () => currentPollInterval,
          afterSeq: _lastSeq,
          // Every roll at or below the count of folded roll events is finished,
          // so the poller never needs to re-read them. Advancing the watermark
          // aggressively is what keeps a long match's read cost flat.
          rollsFrom: _rollCount + 1,
        )
        .listen(_onPoll, onError: _onPollError);
    unawaited(_pumpRolls());
  }

  @override
  void disposeController() {
    if (_disposed) return;
    _disposed = true;
    // Unblock anyone awaiting readiness; [isReady] stays false so they can bail.
    _completeReady();
    _rollRetry?.cancel();
    _rollRetry = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _pendingMove.dispose();
    _pendingCube.dispose();
    _pendingResign.dispose();
    _nullState.dispose();
    _nullResign.dispose();
    _lastMove.dispose();
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
  /// picks the same `rolls/{n}` up where it stopped rather than starting a
  /// second one.
  @override
  void rollDice() {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    final n = _rollCount + 1;
    if (_roller == null) {
      if (_rolls.containsKey(n)) {
        // Someone already claimed this index and it is not a drive of ours —
        // our view of the log is behind. Refetch rather than fight for it.
        _resync('roll $n was already claimed');
        return;
      }
      _roller = _RollerDrive(
          n: n, opening: false, gameNo: _gameNumber, rng: rng);
    }
    _submitting = true;
    _transientError = null;
    _notify();
    unawaited(_pumpRolls());
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

  /// One polling cycle.
  ///
  /// ROLLS ARE PROCESSED FIRST, deliberately: [MatchApi.pollMatch] reads events
  /// before rolls, so a cycle can carry a roll event together with the very roll
  /// document that event has to be validated against. Taking the documents in
  /// first means the validation below always has them.
  void _onPoll(MatchPoll poll) {
    if (_disposed || frozen) return;
    for (final roll in poll.rolls) {
      _rolls[roll.n] = roll;
      if (!_verifyRollDoc(roll)) return;
    }
    _inbox.addAll(poll.events);
    _drainInbox();
    if (_disposed || frozen) return;
    unawaited(_pumpRolls());
  }

  void _onPollError(Object error) {
    if (_disposed || frozen) return;
    _transientError = error;
    _notify();
  }

  /// A completed roll document must be a sound commitment, whoever made it.
  /// Returns false (after freezing) when it is not.
  bool _verifyRollDoc(RollDoc roll) {
    final done = roll.completed;
    if (done == null) return true;
    try {
      done.verifyCommit();
      return true;
    } on FairDiceCheatException catch (e) {
      _freeze(OnlineCheatException(
        'fair-dice',
        'the secret revealed for roll ${roll.n} does not hash to the '
            'commitment published before our entropy was contributed ($e).',
        headline: OnlineCheatException.dice,
      ));
      return false;
    } on FormatException catch (e) {
      _freeze(OnlineCheatException(
        'malformed-roll',
        'roll ${roll.n} carries a malformed protocol value ($e).',
        headline: OnlineCheatException.dice,
      ));
      return false;
    }
  }

  /// Ingest as much of [_inbox] as can be validated right now.
  ///
  /// Stops (leaving the rest queued) when the next event is a roll whose
  /// `rolls/{n}` document has not been seen yet — that document is what the
  /// event is checked against, so folding without it would mean trusting the
  /// opponent's dice. A targeted fetch is started and the drain resumes when it
  /// lands.
  void _drainInbox() {
    while (_inbox.isNotEmpty && !_disposed && !frozen) {
      // A replay that has already failed cannot be repaired by folding MORE of
      // the same log on top of the mismatch.
      if (_replacing && _replaceFailure != null) return;
      final re = _inbox.first;
      if (re.seq <= _lastSeq) {
        _inbox.removeAt(0);
        continue;
      }
      if (re.seq > _lastSeq + 1) {
        // A GAP. Nothing incremental closes it — only the whole log can.
        _inbox.clear();
        _resync('missed events (seq ${re.seq} after $_lastSeq)');
        return;
      }
      final needed = _rollIndexFor(re.event);
      if (needed != null && !(_rolls[needed]?.isComplete ?? false)) {
        _fetchRoll(needed);
        return;
      }
      _inbox.removeAt(0);
      _ingest(re);
    }
  }

  /// The `rolls/{n}` index a roll-bearing event must be validated against, or
  /// null for every other event. Only valid for the NEXT event to ingest.
  int? _rollIndexFor(GameEvent event) =>
      (event is OpeningRollEvent || event is RollEvent) ? _rollCount + 1 : null;

  void _fetchRoll(int n) {
    if (_fetchingRolls.contains(n)) return;
    _fetchingRolls.add(n);
    unawaited(() async {
      try {
        final doc = await api.fetchRoll(matchId, n);
        if (_disposed || frozen) return;
        if (doc != null) {
          _rolls[n] = doc;
          if (!_verifyRollDoc(doc)) return;
        }
      } catch (e) {
        if (_disposed || frozen) return;
        _transientError = e;
        _notify();
      } finally {
        _fetchingRolls.remove(n);
      }
      if (!_disposed && !frozen) _drainInbox();
    }());
  }

  /// Validate, count and either fold or buffer one contiguous event.
  void _ingest(RemoteEvent re) {
    final violation = _validate(re);
    if (violation != null) {
      _freeze(violation);
      return;
    }
    _lastSeq = re.seq;
    final event = re.event;
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
    if (_awaitingNextGame) {
      _buffer.add(re);
      return;
    }
    _applyEvent(re);
  }

  /// Everything that can be checked WITHOUT the folded game: who wrote the
  /// event, which seat it claims, and (for a roll) whether its dice are the ones
  /// the commit-reveal document derives. Returns the violation, or null.
  ///
  /// Rule-engine legality is checked separately, by [_applyEvent] — it needs the
  /// folded game, which is not available for a buffered event.
  OnlineCheatException? _validate(RemoteEvent re) {
    final authorSide = matchDoc.sideOf(re.author);
    if (authorSide == null) {
      return OnlineCheatException('not-a-participant',
          'event ${re.seq} was written by "${re.author}", who is not one of '
              'the two players.');
    }
    final event = re.event;
    final actor = _actorOf(event);
    if (actor != null && actor != authorSide) {
      return OnlineCheatException(
          'wrong-author',
          'event ${re.seq} claims to be $actor\'s but was written by the '
              '$authorSide player.');
    }
    if (event is OpeningRollEvent && re.author != matchDoc.hostUid) {
      return OnlineCheatException('opening-not-host',
          'the opening roll of game ${re.gameNo} must be made by the host.');
    }
    if (event is! OpeningRollEvent && event is! RollEvent) return null;

    final n = _rollCount + 1;
    final doc = _rolls[n];
    final roll = doc?.completed;
    if (doc == null || roll == null) {
      // _drainInbox only ingests once the document is complete, so this can only
      // be a corrupted local cache; treat it as a protocol failure rather than
      // trusting unverified dice.
      return OnlineCheatException(
        'dice-mismatch',
        'event ${re.seq} carries dice with no completed roll $n behind them.',
        headline: OnlineCheatException.dice,
      );
    }
    if (doc.roller != re.author) {
      return OnlineCheatException(
        'roll-author',
        'roll $n was committed by "${doc.roller}" but the resulting event was '
            'written by "${re.author}".',
        headline: OnlineCheatException.dice,
      );
    }
    try {
      final ok = event is OpeningRollEvent
          ? openingDiceMatchRoll(roll, event)
          : diceMatchRoll(roll, event as RollEvent);
      if (ok) return null;
      return OnlineCheatException(
        'dice-mismatch',
        'event ${re.seq} does not carry the dice roll $n derives.',
        headline: OnlineCheatException.dice,
      );
    } on FairDiceCheatException catch (e) {
      return OnlineCheatException(
        'fair-dice',
        'the secret revealed for roll $n does not match its commitment ($e).',
        headline: OnlineCheatException.dice,
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

  void _applyEvent(RemoteEvent re) {
    _gameNumber = re.gameNo;
    try {
      _fold(re);
    } on StateError catch (e) {
      _onFoldFailure(re, e.message);
      return;
    } on ArgumentError catch (e) {
      _onFoldFailure(re, '${e.message}');
      return;
    }
    if (!_replacing) _afterFold();
  }

  /// The rules engine refused an event that is already in the log.
  ///
  /// With no server there is no "the server ordered it differently" reading of
  /// this any more: if the OPPONENT wrote it, its client broke the rules and the
  /// match freezes. Our own event failing to fold means our view was behind
  /// (someone else's event landed at that seq first), which a refetch fixes —
  /// unless we are already replaying a freshly fetched log, in which case
  /// refetching would only find the same thing.
  void _onFoldFailure(RemoteEvent re, String detail) {
    if (re.author != _uid) {
      _freeze(OnlineCheatException('illegal-event',
          'event ${re.seq} (${re.event.runtimeType}) is not legal here: '
              '$detail'));
      return;
    }
    if (_replacing) {
      _replaceFailure = OnlineException(
          'diverged', 'the match log did not replay: $detail');
      return;
    }
    _resync('local state diverged on our own event ${re.seq}');
  }

  void _fold(RemoteEvent re) {
    final event = re.event;
    if (event is OpeningRollEvent) {
      _game = Game.start(event, isCrawfordGame: _match.isCrawfordNext);
      return;
    }
    // The board the event is about to fold onto — the animation's starting
    // position, knowable only here (several events may fold between two painted
    // frames, so an observer cannot recover it from [state]). See [AppliedMove].
    final preBoard = _game!.state.board;
    final next = _game!.append(event);
    _game = next;
    // NOT published during a full replace: [lastMove] drives a cosmetic
    // animation, and a rebuild replaying fifty historical moves must snap to the
    // rebuilt position rather than re-play the game.
    if (event is MoveEvent && !_replacing) {
      _lastMove.value = AppliedMove(event, preBoard);
    }
    if (next.state.phase != GamePhase.gameOver) return;

    _lastFinishedGameNo = re.gameNo;
    final result = next.state.result!;
    _match = _match.applyResult(result);
    // Persist the JUST-finished game with its COMPLETE event log. This fires at
    // the applyResult moment — before any of the next game's events fold (they
    // buffer while [_awaitingNextGame]) — so [next.events] is the whole game.
    if (re.gameNo > _persistedThrough) {
      _persistedThrough = re.gameNo;
      _persist(() => persistence.onGameFinished(
            gameNumber: re.gameNo,
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
    } else if (re.gameNo > _acknowledgedThrough) {
      // Pause for the game-over dialog — unless this is a replay of a game the
      // user already dismissed.
      _awaitingNextGame = true;
    }
  }

  void _afterFold() {
    // A successful fold proves the stream is healthy again: clear any transient
    // poll/submit error so it stays a passing banner rather than a sticky gate.
    // A freeze is NOT transient and survives.
    if (!frozen) _transientError = null;
    if (_game != null) _completeReady();
    _markCompleteIfOver();
    _refreshPending();
    _notify();
  }

  /// Flip the match document to `complete` once, as bookkeeping. Either
  /// participant may do it and the log stays the authority, so a failure here is
  /// swallowed rather than surfaced.
  void _markCompleteIfOver() {
    if (_completionSent || !_match.isMatchOver || _disposed) return;
    _completionSent = true;
    unawaited(() async {
      try {
        await api.completeMatch(matchId);
      } catch (_) {
        // Bookkeeping only: the event log already decides the match.
      }
    }());
  }

  /// Recomputes the local-side pending notifiers from the current game state.
  void _refreshPending() {
    final g = _game;
    final active =
        g != null && !frozen && !_match.isMatchOver && !_awaitingNextGame;
    final s = g?.state;
    _pendingMove.value =
        (active && s!.phase == GamePhase.moving && s.turn == localSide)
            ? s
            : null;
    _pendingCube.value =
        (active && s!.phase == GamePhase.cubeOffered && s.turn == localSide)
            ? s
            : null;
    _pendingResign.value =
        (active && s!.phase == GamePhase.resignOffered && s.turn == localSide)
            ? (s, s.resignOffer!.value)
            : null;
  }

  // --- resync ----------------------------------------------------------------

  /// Refetch the whole match and rebuild from scratch. The ONLY recovery path:
  /// with no server snapshot to seed from, scores and game numbers can only be
  /// re-derived by replaying the log.
  void _resync(String why) {
    if (_disposed || frozen || _resyncing) return;
    _resyncing = true;
    _transientError = OnlineException('diverged', '$why; resyncing');
    _submitting = false;
    _notify();
    unawaited(() async {
      try {
        await _replaceFromServer();
      } finally {
        _resyncing = false;
      }
      if (!_disposed && !frozen) unawaited(_pumpRolls());
    }());
  }

  Future<void> _replaceFromServer() async {
    try {
      // Rolls FIRST: the events fetched next are validated against them.
      final rolls = await api.fetchRollsFrom(matchId, 1);
      final events = await api.fetchEventsSince(matchId, -1);
      if (_disposed) return;
      _rebuild(events, rolls);
    } catch (e) {
      if (_disposed || frozen) return;
      _transientError = e;
      _notify();
    }
  }

  /// Replay [events] over a clean slate. The persistence/acknowledgement
  /// watermarks survive so a rebuild neither records a game twice nor re-opens a
  /// dialog the user already dismissed.
  void _rebuild(List<RemoteEvent> events, List<RollDoc> rolls) {
    _rolls
      ..clear()
      ..addEntries(rolls.map((r) => MapEntry(r.n, r)));
    for (final roll in rolls) {
      if (!_verifyRollDoc(roll)) return;
    }
    _match = MatchState(matchLength: matchDoc.length);
    _game = null;
    _gameNumber = 0;
    _lastSeq = -1;
    _rollCount = 0;
    _openingsIngested = 0;
    _lastFinishedGameNo = 0;
    _awaitingNextGame = false;
    _submitting = false;
    _buffer = [];
    _inbox
      ..clear()
      ..addAll(events);
    _replacing = true;
    _replaceFailure = null;
    _drainInbox();
    _replacing = false;
    if (frozen) return;
    final failure = _replaceFailure;
    if (failure == null) {
      _afterFold();
      return;
    }
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
  /// remembered and re-run rather than dropped: the roll documents it was about
  /// have already been consumed from the poll stream, so dropping it would leave
  /// the protocol waiting for a change that has been and gone.
  Future<void> _pumpRolls() async {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    if (_disposed || frozen || !_started) return;
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        await _witnessSteps();
        if (_disposed || frozen) return;
        await _rollerSteps();
      } while (_pumpAgain && !_disposed && !frozen);
    } on FairDiceCheatException catch (e) {
      _freeze(OnlineCheatException(
        'fair-dice',
        'the revealed secret does not match the commitment that preceded our '
            'entropy ($e).',
        headline: OnlineCheatException.dice,
      ));
      return;
    } on FormatException catch (e) {
      _freeze(OnlineCheatException(
        'malformed-roll',
        'a roll document carries a malformed protocol value ($e).',
        headline: OnlineCheatException.dice,
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

  /// One retry in flight at a time. Needed because a stalled drive may produce
  /// no further document changes, so nothing else would wake it.
  void _armRollRetry() {
    if (_rollRetry != null || _disposed) return;
    _rollRetry = Timer(pollInterval, () {
      _rollRetry = null;
      if (_disposed || frozen) return;
      unawaited(_pumpRolls());
    });
  }

  /// Contribute entropy to (and verify the reveal of) every roll that is not
  /// ours. Fairness does not depend on WHICH rolls we witness, so this is
  /// deliberately unconditional — refusing to answer would only deadlock the
  /// match, and a roll made at the wrong moment is caught when its event folds.
  Future<void> _witnessSteps() async {
    final pending = _rolls.values.where((r) => r.roller != _uid).toList()
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
            await api.submitEntropy(
                code: matchId, n: roll.n, entropy: value);
            w.entropySent = true;
          } on PermissionDeniedException catch (e) {
            // The rules refused: the document has moved past this phase. Never
            // retryable, so stop trying — the reveal check below still runs.
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
    if (d == null) return;

    if (!d.committed) {
      final commit = d.session.phase == FairDicePhase.fresh
          ? d.session.makeCommit()
          : d.session.commit;
      try {
        await api.createRoll(code: matchId, n: d.n, commit: commit);
        d.committed = true;
      } on AlreadyExistsException {
        final existing = await api.fetchRoll(matchId, d.n);
        if (existing != null) _rolls[existing.n] = existing;
        if (existing != null &&
            existing.roller == _uid &&
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
        await api.submitReveal(code: matchId, n: d.n, reveal: d.revealValue!);
      }
      d.revealSent = true;
      if (_disposed || frozen) return;
    }

    final dice = d.opening ? d.session.openingDice : d.session.dice;
    final event = d.opening
        ? OpeningRollEvent(whiteDie: dice.die1, blackDie: dice.die2)
        : RollEvent(localSide, dice.die1, dice.die2);
    try {
      await api.submitEvent(
        code: matchId,
        seq: _lastSeq + 1,
        gameNo: d.gameNo,
        event: event,
      );
      d.eventSent = true;
    } on AlreadyExistsException {
      // Someone appended at our seq. Rebuild and let the drive retry from the
      // new tail (or retire, if the resync shows our event already landed).
      _resync('the log moved while appending roll ${d.n}');
    }
  }

  /// The HOST is the protocol roller for EVERY opening roll — nobody is on turn
  /// before one, so the seat cannot decide it. The guest contributes entropy, so
  /// the roll is no less fair for being host-initiated.
  ///
  /// Started as soon as the previous game's result folds (not when the user
  /// dismisses the dialog): the resulting events simply buffer, exactly as they
  /// did when a Cloud Function appended them.
  void _maybeStartOpeningRoll() {
    if (_roller != null || !isHost || matchDoc.guestUid == null) return;
    if (_match.isMatchOver || _replacing) return;
    // A game is under way (its opening is ingested and it has not finished).
    if (_openingsIngested != 0 && _lastFinishedGameNo != _openingsIngested) {
      return;
    }
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
    _runSubmit(() => api.submitEvent(
          code: matchId,
          seq: _lastSeq + 1,
          gameNo: gameNo,
          event: event,
        ));
  }

  /// Runs a submission with a single retry. A first failure is retried once; a
  /// second failure surfaces [error] and leaves any pending notifier set for a
  /// manual retry. Guards against concurrent/duplicate submits.
  ///
  /// An [AlreadyExistsException] is NOT retried: the sequence number is taken,
  /// so an identical retry would fail identically. It means our view of the log
  /// is behind, which only a resync fixes.
  Future<void> _runSubmit(Future<void> Function() op) async {
    if (_submitting || _disposed || frozen) return;
    _submitting = true;
    _notify();
    Object? failure;
    var lostRace = false;
    try {
      await op();
    } on AlreadyExistsException catch (e) {
      failure = e;
      lostRace = true;
    } catch (_) {
      try {
        await op();
      } on AlreadyExistsException catch (e) {
        failure = e;
        lostRace = true;
      } catch (e) {
        failure = e;
      }
    }
    if (_disposed) return;
    _submitting = false;
    // Clears a prior error on success; set on failure. A freeze outranks both.
    _transientError = failure;
    _refreshPending();
    _notify();
    if (lostRace) _resync('our submission lost the race for a sequence number');
  }

  // --- helpers ---------------------------------------------------------------

  /// Stop everything, permanently, and say why.
  void _freeze(OnlineCheatException violation) {
    if (_cheatError != null) return;
    _cheatError = violation;
    _roller = null;
    _submitting = false;
    _inbox.clear();
    _buffer = [];
    _rollRetry?.cancel();
    _rollRetry = null;
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

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
