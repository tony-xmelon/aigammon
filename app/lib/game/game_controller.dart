import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';

import 'dice_roller.dart';
import 'player_agent.dart';

/// The verb a human on turn invoked at their pre-roll decision point.
enum _HumanAction { roll, offerDouble, offerResign }

/// Drives one MATCH: a sequence of event-sourced [Game]s between two
/// [PlayerAgent]s, to [matchLength] points. Pure Dart apart from
/// [ChangeNotifier]; listeners are notified whenever the observable state
/// (`game`, `match`, `isThinking`, `error`, `awaitingNextGame`) changes.
///
/// ## Turn protocol
///
/// The loop asks the ON-TURN agent for each decision and applies it as an
/// event. Every phase but the pre-roll is fully agent-mediated (moves, cube
/// responses, resignation responses), so a human and the AI share one code
/// path — a [LocalHumanAgent] simply answers via its pending notifiers.
///
/// The one asymmetry is the pre-roll ([GamePhase.awaitingRoll]), because there
/// is no agent method for "roll vs. double vs. resign":
///
/// * An agent with [PlayerAgent.wantsDoublePrompts] `== true` (the AI) is asked
///   [PlayerAgent.considerDouble] when doubling is legal, then rolls.
/// * An agent with `wantsDoublePrompts == false` (a human) does NOT get a
///   per-turn double prompt. Instead the loop PARKS on the human's pre-roll and
///   waits for exactly one of the controller verbs [rollDice], [offerDouble],
///   or [offerResign]. This is the "human turn gate".
///
/// ### v1 human doubling/resignation semantics
///
/// Doubling and resigning by a human are only possible PRE-ROLL, on the human's
/// own turn, while the gate is open (i.e. `state.phase == awaitingRoll` and the
/// human is on turn). The verbs throw [StateError] otherwise. [offerDouble]
/// additionally requires that doubling is currently legal. A resignation offered
/// mid-move is intentionally NOT supported in v1; the UI enables the buttons
/// only while the gate is open.
///
/// ## Cancellation
///
/// [disposeController] flips a cancelled flag and completes an internal signal
/// that every `await` in the loop races (via [Future.any]). A parked agent
/// future is thereby ABANDONED rather than awaited — important because a
/// disposed [LocalHumanAgent] never completes its pending futures. After any
/// await the loop re-checks the flag and unwinds promptly, and no `choose*` is
/// issued afterwards. Agents are disposed exactly once, inside
/// [disposeController].
class GameController extends ChangeNotifier {
  GameController({
    required this.white,
    required this.black,
    required int matchLength,
    DiceRoller? diceRoller,
  })  : _diceRoller = diceRoller ?? DiceRoller(),
        _match = MatchState(matchLength: matchLength) {
    _startNewGame();
  }

  /// The two decision-makers, exposed so the UI can observe a
  /// [LocalHumanAgent]'s pending-request notifiers.
  final PlayerAgent white;
  final PlayerAgent black;
  final DiceRoller _diceRoller;

  late Game _game;
  MatchState _match;
  bool _isThinking = false;
  Object? _error;

  bool _awaitingNextGame = false;
  bool _cancelled = false;
  bool _disposed = false;
  bool _started = false;

  /// Sentinel returned by the cancellation race when cancellation wins.
  static final Object _cancelSentinel = Object();
  final Completer<void> _cancelledCompleter = Completer<void>();

  Completer<void>? _continueGate;
  Completer<void>? _humanTurnGate;
  _HumanAction? _pendingHumanAction;
  ResignValue? _pendingResignValue;

  /// The current game's derived state.
  GameState get state => _game.state;

  /// The running match score.
  MatchState get match => _match;

  /// The current event-sourced game.
  Game get game => _game;

  /// True while an agent decision is in flight (an `await` on a [PlayerAgent]).
  bool get isThinking => _isThinking;

  /// The last error that stopped the loop, or `null` when healthy.
  Object? get error => _error;

  /// True once the match has been decided.
  bool get matchOver => _match.isMatchOver;

  /// True while the loop is paused between games waiting for
  /// [continueToNextGame] (so the UI can show a game-end dialog).
  bool get awaitingNextGame => _awaitingNextGame;

  /// True while the loop is parked on a human's pre-roll, waiting for one of
  /// [rollDice], [offerDouble], or [offerResign]. The UI enables those controls
  /// exactly while this is true.
  bool get awaitingHumanTurn =>
      _humanTurnGate != null && !_humanTurnGate!.isCompleted;

  /// Runs games until the match completes or [disposeController] is called.
  ///
  /// On an agent or engine error the loop records [error], notifies, and stops
  /// without corrupting the match; the caller/UI surfaces it. Safe to await;
  /// completes when the match ends, an error occurs, or the controller is
  /// disposed.
  Future<void> playMatch() async {
    if (_disposed || _cancelled || _started) return;
    _started = true;
    try {
      while (!_cancelled) {
        while (!_cancelled && state.phase != GamePhase.gameOver) {
          await _step();
        }
        if (_cancelled) break;

        _match = _match.applyResult(state.result!);
        _notify();
        if (_match.isMatchOver) break;

        _awaitingNextGame = true;
        _continueGate = Completer<void>();
        _notify();
        await _waitOn(_continueGate!);
        _continueGate = null;
        _awaitingNextGame = false;
        if (_cancelled) break;
        _startNewGame();
      }
    } catch (e) {
      _error = e;
      _notify();
    }
  }

  /// Resumes the loop after a game ends. Valid only while [awaitingNextGame].
  void continueToNextGame() {
    final gate = _continueGate;
    if (gate == null || gate.isCompleted) {
      throw StateError('not awaiting the next game');
    }
    gate.complete();
  }

  /// Human pre-roll verb: roll the dice. Valid only while the human turn gate
  /// is open (the human is on turn in [GamePhase.awaitingRoll]).
  void rollDice() => _submitHumanAction(_HumanAction.roll);

  /// Human pre-roll verb: offer a double. Valid only while the human turn gate
  /// is open AND doubling is currently legal.
  void offerDouble() {
    if (!_doublingLegal(state)) {
      throw StateError('doubling is not legal now');
    }
    _submitHumanAction(_HumanAction.offerDouble);
  }

  /// Human pre-roll verb: offer to resign for [value]. Valid only while the
  /// human turn gate is open.
  void offerResign(ResignValue value) {
    _pendingResignValue = value;
    _submitHumanAction(_HumanAction.offerResign);
  }

  /// Idempotent: stops the loop, disposes both agents exactly once, and
  /// disposes this notifier. Safe to call while [playMatch] is in flight — the
  /// parked await is released and unwinds without touching the agents again.
  void disposeController() {
    if (_disposed) return;
    _disposed = true;
    _cancelled = true;
    if (!_cancelledCompleter.isCompleted) _cancelledCompleter.complete();
    white.dispose();
    black.dispose();
    super.dispose();
  }

  // --- internals -----------------------------------------------------------

  void _startNewGame() {
    final opening = _diceRoller.rollOpening();
    _game = Game.start(
      OpeningRollEvent(whiteDie: opening.die1, blackDie: opening.die2),
      isCrawfordGame: _match.isCrawfordNext,
    );
    _notify();
  }

  Future<void> _step() async {
    final s = state;
    final agent = _agentFor(s.turn);
    switch (s.phase) {
      case GamePhase.awaitingRoll:
        await _stepPreRoll(s, agent);
      case GamePhase.moving:
        final move = await _guard(agent.chooseMove(s));
        if (_cancelled) return;
        _append(MoveEvent(s.turn, move as Move));
      case GamePhase.cubeOffered:
        final action = await _guard(agent.chooseCubeResponse(s));
        if (_cancelled) return;
        _append((action as CubeAction) == CubeAction.take
            ? TakeEvent(s.turn)
            : DropEvent(s.turn));
      case GamePhase.resignOffered:
        final accept =
            await _guard(agent.chooseResignResponse(s, s.resignOffer!.value));
        if (_cancelled) return;
        _append((accept as bool)
            ? ResignAcceptEvent(s.turn)
            : ResignDeclineEvent(s.turn));
      case GamePhase.gameOver:
        return;
    }
  }

  Future<void> _stepPreRoll(GameState s, PlayerAgent agent) async {
    if (agent.wantsDoublePrompts) {
      if (_doublingLegal(s)) {
        final wants = await _guard(agent.considerDouble(s));
        if (_cancelled) return;
        if (wants == true) {
          _append(DoubleEvent(s.turn));
          return;
        }
      }
      _rollFor(s.turn);
      return;
    }

    // Human: park on the gate until a verb fires (or cancellation).
    _humanTurnGate = Completer<void>();
    _notify();
    await _waitOn(_humanTurnGate!);
    _humanTurnGate = null;
    if (_cancelled) return;

    final action = _pendingHumanAction;
    _pendingHumanAction = null;
    switch (action) {
      case _HumanAction.roll:
        _rollFor(s.turn);
      case _HumanAction.offerDouble:
        _append(DoubleEvent(s.turn));
      case _HumanAction.offerResign:
        _append(ResignOfferEvent(s.turn, _pendingResignValue!));
        _pendingResignValue = null;
      case null:
        return;
    }
  }

  void _rollFor(Player player) {
    final d = _diceRoller.roll();
    _append(RollEvent(player, d.die1, d.die2));
  }

  bool _doublingLegal(GameState s) =>
      s.phase == GamePhase.awaitingRoll &&
      !s.isCrawfordGame &&
      (s.cube.owner == null || s.cube.owner == s.turn);

  void _submitHumanAction(_HumanAction action) {
    final gate = _humanTurnGate;
    if (gate == null || gate.isCompleted) {
      throw StateError('no human turn is awaiting input');
    }
    _pendingHumanAction = action;
    gate.complete();
  }

  PlayerAgent _agentFor(Player p) => p == Player.white ? white : black;

  /// Awaits [future] with the loop's thinking flag set, racing cancellation so
  /// a never-completing agent future is abandoned on dispose. Returns `null`
  /// when cancellation won; callers must re-check [_cancelled] before using the
  /// result. An agent throwing propagates out (the loop records [error]).
  Future<T?> _guard<T>(Future<T> future) async {
    _setThinking(true);
    try {
      final result = await Future.any<Object?>([future, _cancelSignal()]);
      if (_cancelled || identical(result, _cancelSentinel)) return null;
      return result as T;
    } finally {
      _setThinking(false);
    }
  }

  /// Waits until [gate] completes or cancellation fires, whichever first.
  Future<void> _waitOn(Completer<void> gate) =>
      Future.any<Object?>([gate.future, _cancelSignal()]);

  Future<Object?> _cancelSignal() =>
      _cancelledCompleter.future.then((_) => _cancelSentinel);

  void _append(GameEvent event) {
    _game = _game.append(event);
    _notify();
  }

  void _setThinking(bool value) {
    if (_isThinking == value) return;
    _isThinking = value;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
