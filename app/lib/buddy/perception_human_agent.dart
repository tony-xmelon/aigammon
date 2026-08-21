import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';

import '../game/player_agent.dart';

/// The user's side of a Buddy session.
///
/// Shaped exactly like `LocalHumanAgent` — every `choose*` parks on a completer
/// the outside world later completes — and different from it in the one way
/// that matters: **the move never comes from a board tap.** It comes from
/// `matchLegalPlay` recognising what the hand did on the physical board, from
/// the candidate picker when two legal plays leave the same position, or from
/// the tap-to-enter fallback when perception cannot say. All three arrive
/// through [submitMove], and `BuddySession` is the only thing that calls it.
///
/// The cube and resignation answers are ordinary UI answers, because that is
/// what the spec makes them: Buddy doubles by voice and the user taps take or
/// drop. Voice input is a later phase.
class PerceptionHumanAgent implements PlayerAgent {
  final ValueNotifier<GameState?> _pendingMove = ValueNotifier(null);
  final ValueNotifier<GameState?> _pendingCube = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> _pendingResign =
      ValueNotifier(null);

  Completer<Move>? _moveCompleter;
  Completer<CubeAction>? _cubeCompleter;
  Completer<bool>? _resignCompleter;
  bool _disposed = false;

  /// The state a play is wanted for, or null. What the session watches to know
  /// that the user's turn has begun.
  ValueListenable<GameState?> get pendingMove => _pendingMove;

  /// The state a take/drop is wanted for, or null.
  ValueListenable<GameState?> get pendingCube => _pendingCube;

  /// The state and offer a resignation answer is wanted for, or null.
  ValueListenable<(GameState, ResignValue)?> get pendingResign =>
      _pendingResign;

  /// A human is never polled for a double each turn: the user doubles with the
  /// on-screen button, which drives the controller's own `offerDouble` verb.
  ///
  /// It has a second consequence here that the digital game does not need, and
  /// it is load-bearing: an agent that answers false makes the controller PARK
  /// on this side's pre-roll instead of rolling for itself, which is the only
  /// moment a session can stop and read a physical roll off the board. See
  /// `BuddyDiceRoller`.
  @override
  bool get wantsDoublePrompts => false;

  @override
  Future<Move> chooseMove(GameState state) {
    if (_moveCompleter != null) {
      throw StateError('a move request is already pending');
    }
    final completer = Completer<Move>();
    _moveCompleter = completer;
    _pendingMove.value = state;
    return completer.future;
  }

  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) =>
      throw StateError('a Buddy session never polls the user for a double — '
          'the Double button drives the controller directly');

  @override
  Future<CubeAction> chooseCubeResponse(GameState state, MatchContext ctx) {
    if (_cubeCompleter != null) {
      throw StateError('a cube response is already pending');
    }
    final completer = Completer<CubeAction>();
    _cubeCompleter = completer;
    _pendingCube.value = state;
    return completer.future;
  }

  @override
  Future<bool> chooseResignResponse(
      GameState state, ResignValue value, MatchContext ctx) {
    if (_resignCompleter != null) {
      throw StateError('a resign response is already pending');
    }
    final completer = Completer<bool>();
    _resignCompleter = completer;
    _pendingResign.value = (state, value);
    return completer.future;
  }

  /// The play the board turned out to hold.
  void submitMove(Move move) {
    final completer = _moveCompleter;
    if (completer == null) {
      throw StateError('no move request is pending');
    }
    _moveCompleter = null;
    _pendingMove.value = null;
    completer.complete(move);
  }

  void submitCubeResponse(CubeAction action) {
    final completer = _cubeCompleter;
    if (completer == null) {
      throw StateError('no cube response is pending');
    }
    _cubeCompleter = null;
    _pendingCube.value = null;
    completer.complete(action);
  }

  void submitResignResponse(bool accept) {
    final completer = _resignCompleter;
    if (completer == null) {
      throw StateError('no resign response is pending');
    }
    _resignCompleter = null;
    _pendingResign.value = null;
    completer.complete(accept);
  }

  /// Clears the notifiers and abandons any pending decision — the controller
  /// owns cancellation of an in-flight turn, exactly as for `LocalHumanAgent`.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _moveCompleter = null;
    _cubeCompleter = null;
    _resignCompleter = null;
    _pendingMove.value = null;
    _pendingCube.value = null;
    _pendingResign.value = null;
    _pendingMove.dispose();
    _pendingCube.dispose();
    _pendingResign.dispose();
  }
}

/// Buddy's side of a Buddy session: the engine, gated by a human hand.
///
/// It decides nothing itself. Every choice is [engine]'s — the ordinary
/// `AiAgent` over the difficulty pipeline, unchanged — and this wrapper exists
/// for one reason: **`wantsDoublePrompts` must be false.**
///
/// In the digital game an AI agent answers true, and the controller therefore
/// asks it about the cube and then rolls for it in the same breath, with no
/// suspension point in between. That is right when the dice are a random
/// number and wrong when they are two cubes of plastic on a table: somebody has
/// to throw them, Buddy announce them, and only then may the game advance. So
/// this side parks on the pre-roll gate like a human's does, and the session
/// runs the cube question ([considerDouble], delegated straight through) and
/// the physical roll in the order a real table does them.
///
/// [onCubeResponse] fires when the engine answers a double the user offered —
/// the session cannot read take-or-drop back out of the state fast enough to
/// narrate it, and a policy has to say "I take" in Buddy's own voice.
class BuddyOpponentAgent implements PlayerAgent {
  BuddyOpponentAgent(this.engine, {this.onCubeResponse});

  /// The real decision-maker. `AiAgent` in production; anything implementing
  /// the interface in a test.
  final PlayerAgent engine;

  final void Function(CubeAction action)? onCubeResponse;

  /// False, and that is the whole point of this class — see the class doc.
  @override
  bool get wantsDoublePrompts => false;

  @override
  Future<Move> chooseMove(GameState state) => engine.chooseMove(state);

  /// Asked by the session at the pre-roll gate rather than by the controller,
  /// because the controller no longer polls this side. Same question, same
  /// answer, one layer up.
  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) =>
      engine.considerDouble(state, ctx);

  @override
  Future<CubeAction> chooseCubeResponse(GameState state, MatchContext ctx) async {
    final action = await engine.chooseCubeResponse(state, ctx);
    onCubeResponse?.call(action);
    return action;
  }

  @override
  Future<bool> chooseResignResponse(
          GameState state, ResignValue value, MatchContext ctx) =>
      engine.chooseResignResponse(state, value, ctx);

  @override
  void dispose() => engine.dispose();
}
