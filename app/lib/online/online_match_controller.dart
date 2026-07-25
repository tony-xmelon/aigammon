import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:online_client/online_client.dart';

import '../game/match_controller.dart';
import '../game/player_agent.dart';

/// A [MatchController] driven by a remote event stream instead of local agents.
///
/// The Firestore event log IS the game. This controller FOLDS the ordered
/// [RemoteEvent]s the server assigns into a [Game]/[MatchState], and submits
/// only the LOCAL side's decisions back through the [MatchApi]. Every dice roll
/// (opening and turn) is server-authoritative and arrives as an event; the
/// controller never rolls locally.
///
/// ## Folding
///
/// * [_game] is `null` until the first `openingRoll` of the current game has
///   been folded. Each `openingRoll` STARTS a fresh [Game]; every other event
///   is appended via [Game.append], which validates it against the state
///   machine.
/// * [_match] is seeded from [initialSnapshot] and advanced LOCALLY via
///   [MatchState.applyResult] whenever a terminal event ends a game — exactly
///   as [GameController] does. It is re-seeded from a fresh [MatchApi.fetchMatch]
///   only on a divergence rebuild.
/// * [_lastSeq] tracks the last folded sequence number. Events are accepted
///   only when contiguous (`seq == _lastSeq + 1`); duplicates and out-of-order
///   deliveries are ignored. Server sequence numbers are contiguous, so this
///   never drops a legitimate event.
///
/// ## Divergence
///
/// If appending an event throws — the local fold disagrees with the server's
/// ordering — the controller REFETCHES the whole log ([MatchApi.fetchEventsSince]
/// from `-1`) plus a fresh snapshot, rebuilds from scratch, and surfaces a
/// transient [error] that clears once the rebuild succeeds.
///
/// ## Local decisions
///
/// Only the local side's choices are submitted. Pre-roll verbs ([rollDice] /
/// [offerDouble] / [offerResign]) fire while [awaitingHumanTurn]; in-game
/// decisions surface through the `pending*Of(localSide)` notifiers and are
/// answered via the `submit*` verbs. A terminal decision (the move that bears
/// off the 15th checker, a drop, an accepted resignation) carries a
/// [GameResultClaim] the server folds into scores. Every submission is retried
/// once on failure; a double failure surfaces [error] and leaves the pending
/// notifier set so the user can retry.
///
/// ## Game-end pause
///
/// The server auto-appends the next game's `openingRoll` the instant a game
/// ends, but the UI still shows a game-over dialog. When a game ends (and the
/// match is not over) the controller sets [awaitingNextGame] and BUFFERS every
/// later event until [continueToNextGame] drains the queue.
class OnlineMatchController extends ChangeNotifier implements MatchController {
  OnlineMatchController({
    required this.api,
    required this.matchId,
    required this.localSide,
    required MatchSnapshot initialSnapshot,
    this.pollInterval = const Duration(seconds: 2),
  }) : _match = MatchState(
          matchLength: initialSnapshot.matchLength,
          whiteScore: initialSnapshot.whiteScore,
          blackScore: initialSnapshot.blackScore,
          crawfordPlayed: initialSnapshot.crawfordPlayed,
        );

  /// The remote transport folded into local game state.
  final MatchApi api;

  /// The match this controller drives.
  final String matchId;

  /// The seat whose decisions are submitted; all others are remote.
  final Player localSide;

  /// How often the poll stream fetches new events.
  final Duration pollInterval;

  Game? _game;
  MatchState _match;

  /// The last folded sequence number; events must be contiguous with it.
  int _lastSeq = -1;

  bool _awaitingNextGame = false;
  bool _submitting = false;
  bool _started = false;
  bool _disposed = false;
  Object? _error;

  /// Completes the first time a game folds (so [state]/[game] become safe to
  /// read), or when the controller is disposed before that happens. See [ready].
  final Completer<void> _ready = Completer<void>();

  StreamSubscription<RemoteEvent>? _sub;

  /// Events received while paused between games, applied on [continueToNextGame].
  List<RemoteEvent> _buffer = [];

  // Pending-decision notifiers for the LOCAL side.
  final ValueNotifier<GameState?> _pendingMove = ValueNotifier(null);
  final ValueNotifier<GameState?> _pendingCube = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> _pendingResign =
      ValueNotifier(null);

  // Constant null-valued notifiers returned for the non-local (remote) side.
  final ValueNotifier<GameState?> _nullState = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> _nullResign =
      ValueNotifier(null);

  /// The last folded move, published for the animation layer. Set in [_fold]
  /// when a [MoveEvent] folds, BEFORE [_afterFold] notifies — so a subscriber
  /// still sees the pre-move [state].
  final ValueNotifier<MoveEvent?> _lastMove = ValueNotifier<MoveEvent?>(null);

  // --- observable state ------------------------------------------------------

  /// The current game's derived state.
  ///
  /// Throws [StateError] if read before the first opening roll has been folded;
  /// [playMatch] populates it during its initial catch-up (a real server's log
  /// always contains the opening roll of the active game).
  @override
  GameState get state {
    final g = _game;
    if (g == null) throw StateError('no game has started yet');
    return g.state;
  }

  @override
  MatchState get match => _match;

  /// True once the first opening roll has been folded — i.e. [state] and [game]
  /// are safe to read. The UI must not push the game screen until this is true.
  bool get isReady => _game != null;

  /// Completes once the controller [isReady] (the first game has folded), or
  /// when it is disposed beforehand. Callers should `await` this, then check
  /// [isReady] — a disposed-before-ready controller completes the future but
  /// leaves [isReady] `false`, so the caller can bail without reading [state].
  Future<void> get ready => _ready.future;

  /// Completes [_ready] exactly once. Called after any fold that may have
  /// started the game, and unconditionally on dispose.
  void _completeReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  Game get game {
    final g = _game;
    if (g == null) throw StateError('no game has started yet');
    return g;
  }

  /// The most recently folded move (for the animation layer), or `null`.
  @override
  ValueListenable<MoveEvent?> get lastMove => _lastMove;

  /// True while the controller is waiting on the opponent or the server (i.e.
  /// the match is active but it is NOT the local side's moment to act).
  ///
  /// Deliberately does NOT gate on [error]: a transient poll/submit failure is a
  /// non-fatal banner that must not change whose turn it is. Errors clear on the
  /// next successful fold (see [_afterFold]).
  @override
  bool get isThinking {
    final g = _game;
    if (g == null || _match.isMatchOver || _awaitingNextGame) {
      return false;
    }
    return !_localActsNow(g.state);
  }

  @override
  Object? get error => _error;

  /// Always `null`: the server owns persistence, so there is no local
  /// persistence layer to fail.
  @override
  Object? get persistenceError => null;

  /// Always `false`: the doubling cube is server-mediated online, so the
  /// cubeless option is offline-only (see [MatchController.cubeless]).
  @override
  bool get cubeless => false;

  @override
  bool get matchOver => _match.isMatchOver;

  @override
  bool get awaitingNextGame => _awaitingNextGame;

  /// True while the local side's pre-roll gate is open.
  ///
  /// Does NOT gate on [error]: a transient failure must never lock the pre-roll
  /// controls, or a single network blip would permanently deadlock the loop
  /// (the pre-roll verbs throw when the gate is closed and there is no other
  /// recovery path). The error surfaces as a banner while the controls stay
  /// usable; a retried [rollDice] clears it on success, as does the next fold.
  @override
  bool get awaitingHumanTurn {
    final g = _game;
    if (g == null || _match.isMatchOver || _awaitingNextGame || _submitting) {
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
    await _catchUp();
    if (_disposed) return;
    _sub = api
        .pollEvents(matchId, interval: pollInterval)
        .listen(_onRemoteEvent, onError: _onPollError);
  }

  @override
  void disposeController() {
    if (_disposed) return;
    _disposed = true;
    // Unblock anyone awaiting readiness; [isReady] stays false so they can bail.
    _completeReady();
    _sub?.cancel();
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
    final queued = _buffer;
    _buffer = [];
    for (var i = 0; i < queued.length; i++) {
      // A buffered event may itself end another game and re-pause; hold the
      // remainder back for the next continue.
      if (_awaitingNextGame) {
        _buffer.addAll(queued.sublist(i));
        break;
      }
      _applyEvent(queued[i]);
    }
    _afterFold();
  }

  // --- pre-roll verbs --------------------------------------------------------

  @override
  void rollDice() {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    _runSubmit(() async {
      await api.rollDice(matchId);
    });
  }

  @override
  void offerDouble() {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
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

  // --- folding ---------------------------------------------------------------

  Future<void> _catchUp() async {
    try {
      final events = await api.fetchEventsSince(matchId, _lastSeq);
      for (final re in events) {
        _onRemoteEvent(re);
      }
      // A clean catch-up heals a prior fetch failure even when it returned no
      // events (so nothing folded to clear the error).
      if (_error != null) {
        _error = null;
        _notify();
      }
    } catch (e) {
      _error = e;
      _notify();
    }
  }

  void _onRemoteEvent(RemoteEvent re) {
    if (_disposed) return;
    // Dedupe + out-of-order guard: server seqs are contiguous, so only the very
    // next seq is a real new event; anything else is a replay or a gap.
    if (re.seq != _lastSeq + 1) return;
    _lastSeq = re.seq;
    if (_awaitingNextGame) {
      _buffer.add(re);
      return;
    }
    _applyEvent(re);
  }

  void _applyEvent(RemoteEvent re) {
    try {
      _fold(re);
    } on StateError {
      // Local fold disagrees with the server — rebuild from authoritative state.
      unawaited(_diverge());
      return;
    }
    _afterFold();
  }

  void _fold(RemoteEvent re) {
    final event = re.event;
    if (event is OpeningRollEvent) {
      _game = Game.start(event, isCrawfordGame: _match.isCrawfordNext);
      return;
    }
    final next = _game!.append(event);
    _game = next;
    // Publish the move for the animation layer BEFORE [_afterFold] notifies, so
    // a subscriber (the board) still observes the pre-move [state] as it fires.
    if (event is MoveEvent) _lastMove.value = event;
    if (next.state.phase == GamePhase.gameOver) {
      _match = _match.applyResult(next.state.result!);
      if (!_match.isMatchOver) {
        _awaitingNextGame = true;
      }
    }
  }

  Future<void> _diverge() async {
    _error = const OnlineException('diverged', 'local state diverged; refetching');
    _notify();
    try {
      final events = await api.fetchEventsSince(matchId, -1);
      final snap = await api.fetchMatch(matchId);
      if (_disposed) return;
      _rebuildFrom(events, snap);
      _error = null;
      _notify();
    } catch (e) {
      if (_disposed) return;
      _error = e;
      _notify();
    }
  }

  void _rebuildFrom(List<RemoteEvent> events, MatchSnapshot snap) {
    _match = MatchState(
      matchLength: snap.matchLength,
      whiteScore: snap.whiteScore,
      blackScore: snap.blackScore,
      crawfordPlayed: snap.crawfordPlayed,
    );
    _buffer = [];
    _awaitingNextGame = false;
    _lastSeq = events.isEmpty ? -1 : events.last.seq;

    final currentGameEvents = [
      for (final re in events)
        if (re.gameNo == snap.gameNo) re.event,
    ];
    if (currentGameEvents.isNotEmpty &&
        currentGameEvents.first is OpeningRollEvent) {
      _game = Game.replay(currentGameEvents, isCrawfordGame: snap.isCrawford);
    }
    if (_game != null) _completeReady();
    _refreshPending();
  }

  void _onPollError(Object error) {
    if (_disposed) return;
    _error = error;
    _notify();
  }

  void _afterFold() {
    // A successful fold proves the stream is healthy again: clear any transient
    // poll/submit error so it stays a passing banner rather than a sticky gate.
    _error = null;
    if (_game != null) _completeReady();
    _refreshPending();
    _notify();
  }

  /// Recomputes the local-side pending notifiers from the current game state.
  void _refreshPending() {
    final g = _game;
    final active = g != null && !_match.isMatchOver && !_awaitingNextGame;
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

  // --- submission ------------------------------------------------------------

  /// Submits a local [event], attaching a [GameResultClaim] when it ends the
  /// game (computed by probing the fold on a throwaway [Game.append]).
  void _submitDecision(GameEvent event) {
    if (_submitting || _disposed || _game == null) return;
    GameResultClaim? claim;
    try {
      claim = _claimFor(event);
    } catch (e) {
      _error = e;
      _notify();
      return;
    }
    _runSubmit(() => api.submitEvent(matchId, event, result: claim));
  }

  /// The terminal claim for [event], or `null` when it does not end the game.
  /// Probes the resulting state so points/outcome/winner match backgammon_core
  /// exactly rather than being recomputed by hand.
  GameResultClaim? _claimFor(GameEvent event) {
    final result = _game!.append(event).state.result;
    if (result == null) return null;
    return GameResultClaim(
      winner: result.winner,
      points: result.points,
      outcome: result.outcome,
    );
  }

  /// Runs a submission with a single retry. A first failure is retried once; a
  /// second failure surfaces [error] and leaves any pending notifier set for a
  /// manual retry. Guards against concurrent/duplicate submits.
  Future<void> _runSubmit(Future<void> Function() op) async {
    if (_submitting || _disposed) return;
    _submitting = true;
    _notify();
    Object? failure;
    try {
      await op();
    } catch (_) {
      try {
        await op();
      } catch (e) {
        failure = e;
      }
    }
    if (_disposed) return;
    _submitting = false;
    _error = failure; // clears a prior error on success; set on double failure.
    _notify();
  }

  // --- helpers ---------------------------------------------------------------

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

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
