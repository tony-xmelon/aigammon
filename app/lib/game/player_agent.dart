import 'dart:async';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/foundation.dart';

/// A player's response to an opponent's double.
enum CubeAction { take, drop }

/// A decision-maker for one side of a game. The [GameController] (Plan 3
/// Task 4) drives a match by asking the on-turn agent for its choices and
/// applying the results to the [GameState].
///
/// Every method is async so the same interface serves a human (who answers
/// via UI callbacks) and the AI (which awaits the engine isolate).
abstract interface class PlayerAgent {
  /// The move to play for the current roll. Returns [Move.none] to pass when
  /// there is no legal play.
  Future<Move> chooseMove(GameState state);

  /// Whether to offer a double. Called only when doubling is legal for the
  /// on-turn player.
  Future<bool> considerDouble(GameState state);

  /// The response to an opponent's double.
  Future<CubeAction> chooseCubeResponse(GameState state);

  /// The response to an opponent's resignation offer. `true` accepts.
  Future<bool> chooseResignResponse(GameState state, ResignValue value);

  /// Releases any resources. No-op by default.
  void dispose() {}
}

/// A human agent whose decisions arrive from the UI. Each `choose*` returns a
/// future the UI later completes by calling the matching `submit*` method.
///
/// The `pending*Request` notifiers let the UI observe when a decision is
/// needed: each is set to the requesting state when a `choose*` is called and
/// reset to `null` once the corresponding `submit*` completes it.
class LocalHumanAgent implements PlayerAgent {
  final ValueNotifier<GameState?> pendingMoveRequest = ValueNotifier(null);
  final ValueNotifier<GameState?> pendingDoubleRequest = ValueNotifier(null);
  final ValueNotifier<GameState?> pendingCubeRequest = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> pendingResignRequest =
      ValueNotifier(null);

  Completer<Move>? _moveCompleter;
  Completer<bool>? _doubleCompleter;
  Completer<CubeAction>? _cubeCompleter;
  Completer<bool>? _resignCompleter;

  @override
  Future<Move> chooseMove(GameState state) {
    if (_moveCompleter != null) {
      throw StateError('a move request is already pending');
    }
    final completer = Completer<Move>();
    _moveCompleter = completer;
    pendingMoveRequest.value = state;
    return completer.future;
  }

  @override
  Future<bool> considerDouble(GameState state) {
    if (_doubleCompleter != null) {
      throw StateError('a double request is already pending');
    }
    final completer = Completer<bool>();
    _doubleCompleter = completer;
    pendingDoubleRequest.value = state;
    return completer.future;
  }

  @override
  Future<CubeAction> chooseCubeResponse(GameState state) {
    if (_cubeCompleter != null) {
      throw StateError('a cube response is already pending');
    }
    final completer = Completer<CubeAction>();
    _cubeCompleter = completer;
    pendingCubeRequest.value = state;
    return completer.future;
  }

  @override
  Future<bool> chooseResignResponse(GameState state, ResignValue value) {
    if (_resignCompleter != null) {
      throw StateError('a resign response is already pending');
    }
    final completer = Completer<bool>();
    _resignCompleter = completer;
    pendingResignRequest.value = (state, value);
    return completer.future;
  }

  /// Completes the pending [chooseMove]. Throws [StateError] if none pending.
  void submitMove(Move move) {
    final completer = _moveCompleter;
    if (completer == null) {
      throw StateError('no move request is pending');
    }
    _moveCompleter = null;
    pendingMoveRequest.value = null;
    completer.complete(move);
  }

  /// Completes the pending [considerDouble]. Throws [StateError] if none.
  void submitDoubleDecision(bool offer) {
    final completer = _doubleCompleter;
    if (completer == null) {
      throw StateError('no double request is pending');
    }
    _doubleCompleter = null;
    pendingDoubleRequest.value = null;
    completer.complete(offer);
  }

  /// Completes the pending [chooseCubeResponse]. Throws [StateError] if none.
  void submitCubeResponse(CubeAction action) {
    final completer = _cubeCompleter;
    if (completer == null) {
      throw StateError('no cube response is pending');
    }
    _cubeCompleter = null;
    pendingCubeRequest.value = null;
    completer.complete(action);
  }

  /// Completes the pending [chooseResignResponse]. Throws [StateError] if none.
  void submitResignResponse(bool accept) {
    final completer = _resignCompleter;
    if (completer == null) {
      throw StateError('no resign response is pending');
    }
    _resignCompleter = null;
    pendingResignRequest.value = null;
    completer.complete(accept);
  }

  /// Clears the request notifiers. Any pending decision futures are abandoned
  /// (never completed) — the [GameController] owns cancellation of an
  /// in-flight turn, so this agent does not complete or error them here.
  @override
  void dispose() {
    _moveCompleter = null;
    _doubleCompleter = null;
    _cubeCompleter = null;
    _resignCompleter = null;
    pendingMoveRequest.value = null;
    pendingDoubleRequest.value = null;
    pendingCubeRequest.value = null;
    pendingResignRequest.value = null;
    pendingMoveRequest.dispose();
    pendingDoubleRequest.dispose();
    pendingCubeRequest.dispose();
    pendingResignRequest.dispose();
  }
}

/// The engine operations [AiAgent] needs, narrowed to an interface so the
/// agent is testable without the native engine. [EngineServiceFacade] wraps a
/// real [EngineService] in production.
abstract interface class EngineFacade {
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice);
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover);
}

/// Adapts a real [EngineService] to [EngineFacade].
class EngineServiceFacade implements EngineFacade {
  EngineServiceFacade(this._service);
  final EngineService _service;

  @override
  Future<List<ScoredMove>> rankMoves(
          BoardState board, Player mover, Dice dice) =>
      _service.rankMoves(board, mover, dice);

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) =>
      _service.cubeInfo(board, mover);
}

/// An AI agent that consults the engine and samples a move according to
/// [difficulty].
class AiAgent implements PlayerAgent {
  AiAgent(this._engine, this.difficulty, [Random? rng])
      : _rng = rng ?? Random();

  final EngineFacade _engine;
  final Difficulty difficulty;
  final Random _rng;

  @override
  Future<Move> chooseMove(GameState state) async {
    final dice = state.dice;
    if (dice == null) {
      throw StateError('chooseMove requires dice to be rolled');
    }
    final ranked = await _engine.rankMoves(state.board, state.turn, dice);
    if (ranked.isEmpty) return Move.none;
    return pickMove(ranked, difficulty, _rng).move;
  }

  /// Uses the engine's money-game cube advice. Match-score-aware cube
  /// decisions are a deferred concern (see [CubeAdvice]); money advice is an
  /// acceptable approximation for the bot.
  @override
  Future<bool> considerDouble(GameState state) async {
    final advice = await _engine.cubeInfo(state.board, state.turn);
    return advice.shouldDouble;
  }

  /// In [GamePhase.cubeOffered] `state.turn` is the decider; the doubler
  /// (`state.turn.opponent`) is the on-roll player `x`. wildbg's cube_info is
  /// evaluated with `x` on roll and its `shouldAccept` is advice for `x`'s
  /// OPPONENT (= the decider) to take (native/wildbg/.../cube.rs:24). So we
  /// pass the doubler and read shouldAccept directly.
  @override
  Future<CubeAction> chooseCubeResponse(GameState state) async {
    final advice = await _engine.cubeInfo(state.board, state.turn.opponent);
    return advice.shouldAccept ? CubeAction.take : CubeAction.drop;
  }

  @override
  Future<bool> chooseResignResponse(GameState state, ResignValue value) async {
    // TODO(plan4): decline resignations that undervalue the position (needs
    // equity threshold vs ResignValue).
    return true;
  }

  @override
  void dispose() {}
}
