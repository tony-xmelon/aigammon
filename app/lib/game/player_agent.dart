import 'dart:async';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/foundation.dart';

/// A player's response to an opponent's double.
enum CubeAction { take, drop }

/// The match-score context an agent needs to make match-aware cube and resign
/// decisions. Always built from the perspective of the agent BEING ASKED (the
/// on-turn actor / decider), so [moverAway] is that actor's own away score.
///
/// "Away" = points still needed to win the match (`matchLength - score`).
///
/// The [GameController] constructs this at each call site from its [MatchState]
/// and `state.turn`. Because it is anchored to the actor, an agent that needs
/// the OTHER side's perspective (e.g. [AiAgent.chooseCubeResponse], where the
/// doubler is the actor's opponent) must invert [moverAway]/[opponentAway]
/// itself — see that method.
class MatchContext {
  /// Points the actor being asked still needs to win the match.
  final int moverAway;

  /// Points that actor's opponent still needs to win the match.
  final int opponentAway;

  /// True once the match's Crawford game has already been played (cube live
  /// again, post-Crawford). Threaded to [MatchCubeAdvisor.advise].
  final bool crawfordPlayed;

  const MatchContext({
    required this.moverAway,
    required this.opponentAway,
    required this.crawfordPlayed,
  });
}

/// A decision-maker for one side of a game. The [GameController] (Plan 3
/// Task 4) drives a match by asking the on-turn agent for its choices and
/// applying the results to the [GameState].
///
/// Every method is async so the same interface serves a human (who answers
/// via UI callbacks) and the AI (which awaits the engine isolate).
abstract interface class PlayerAgent {
  /// Whether the [GameController] should ask this agent (via [considerDouble])
  /// whether to double at the start of each of its turns.
  ///
  /// AI agents return `true`: the controller polls them every pre-roll. Humans
  /// return `false`: a human is never prompted with a modal "double?" each turn
  /// and instead drives doubling/resigning through the controller's
  /// `offerDouble`/`offerResign`/`rollDice` verbs. See [GameController].
  bool get wantsDoublePrompts;

  /// The move to play for the current roll. Returns [Move.none] to pass when
  /// there is no legal play.
  Future<Move> chooseMove(GameState state);

  /// Whether to offer a double. Called only when doubling is legal for the
  /// on-turn player. [ctx] is built from the on-turn player's perspective.
  Future<bool> considerDouble(GameState state, MatchContext ctx);

  /// The response to an opponent's double. [ctx] is built from the DECIDER's
  /// (`state.turn`'s) perspective — the actor being asked, not the doubler.
  Future<CubeAction> chooseCubeResponse(GameState state, MatchContext ctx);

  /// The response to an opponent's resignation offer. `true` accepts. [ctx] is
  /// built from the acceptor's (`state.turn`'s) perspective.
  Future<bool> chooseResignResponse(
      GameState state, ResignValue value, MatchContext ctx);

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

  /// A human is never polled for a double each turn; the UI drives doubling and
  /// resigning through the controller's verbs instead.
  @override
  bool get wantsDoublePrompts => false;

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

  /// [ctx] is unused: a human answers via the UI, which sees the match score
  /// directly. It stays in the signature so humans and the AI share one
  /// interface.
  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) {
    if (_doubleCompleter != null) {
      throw StateError('a double request is already pending');
    }
    final completer = Completer<bool>();
    _doubleCompleter = completer;
    pendingDoubleRequest.value = state;
    return completer.future;
  }

  @override
  Future<CubeAction> chooseCubeResponse(GameState state, MatchContext ctx) {
    if (_cubeCompleter != null) {
      throw StateError('a cube response is already pending');
    }
    final completer = Completer<CubeAction>();
    _cubeCompleter = completer;
    pendingCubeRequest.value = state;
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
  /// Cubeless win/gammon/backgammon probabilities from [mover]'s perspective.
  Future<Probabilities> evaluate(BoardState board, Player mover);
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice);
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover);
}

/// Adapts a real [EngineService] to [EngineFacade].
class EngineServiceFacade implements EngineFacade {
  EngineServiceFacade(this._service);
  final EngineService _service;

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) =>
      _service.evaluate(board, mover);

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
  final MatchCubeAdvisor _advisor = const MatchCubeAdvisor();

  /// The bot evaluates a double at the start of every turn.
  @override
  bool get wantsDoublePrompts => true;

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

  /// Match-aware double decision via [MatchCubeAdvisor]. `state.turn` is the
  /// mover, and [ctx] is built from the mover's perspective, so the advisor's
  /// `moverAway`/`opponentAway` map straight through.
  ///
  /// This retires the old money-only `cubeInfo` path for bot doubling. The
  /// [EngineFacade.cubeInfo] verb is kept (it is separately wired and tested,
  /// and the tutor may use it for money-style display) but is no longer
  /// consulted here.
  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) async {
    final probs = await _engine.evaluate(state.board, state.turn);
    final advice = _advisor.advise(
      probs: probs,
      moverAway: ctx.moverAway,
      opponentAway: ctx.opponentAway,
      cubeValue: state.cube.value,
      crawfordPlayed: ctx.crawfordPlayed,
    );
    return advice.shouldDouble;
  }

  /// Match-aware take/drop via [MatchCubeAdvisor].
  ///
  /// In [GamePhase.cubeOffered] `state.turn` is the DECIDER (this agent); the
  /// DOUBLER is `state.turn.opponent`. The advisor reasons from the doubler's
  /// (mover's) perspective, so we:
  ///  * evaluate the position from the DOUBLER's perspective (preserving the
  ///    prior fix — the engine is queried with the on-roll doubler, not the
  ///    decider), and
  ///  * INVERT the aways: [ctx] is anchored to the decider (`state.turn`), so
  ///    the doubler's away is `ctx.opponentAway` and the decider's is
  ///    `ctx.moverAway`. We pass them swapped into `advise`.
  /// `advice.shouldTake` is then the doubler-opponent's (= this decider's) best
  /// response.
  @override
  Future<CubeAction> chooseCubeResponse(
      GameState state, MatchContext ctx) async {
    final doubler = state.turn.opponent;
    final probs = await _engine.evaluate(state.board, doubler);
    final advice = _advisor.advise(
      probs: probs,
      moverAway: ctx.opponentAway,
      opponentAway: ctx.moverAway,
      cubeValue: state.cube.value,
      crawfordPlayed: ctx.crawfordPlayed,
    );
    return advice.shouldTake ? CubeAction.take : CubeAction.drop;
  }

  /// Match-equity-based resign policy. This agent is the potential ACCEPTOR of
  /// the opponent's resignation; after [GameState.offerResign] `state.turn` is
  /// this decider, so evaluating from `state.turn` gives the acceptor's own
  /// win distribution.
  ///
  /// Accepting banks a FIXED number of points now; playing on continues the game
  /// at the current cube stake with the full range of outcomes (the acceptor may
  /// win a bigger class, but may also win smaller, or even LOSE). We compare the
  /// two in MATCH-EQUITY space using the shared [matchEquityAfter] /
  /// [matchEquityOfDistribution] helpers:
  ///
  ///  * `eqAccept` = [matchEquityAfter] after banking the offered points
  ///    `offeredPoints = cube.value * value.multiplier` — i.e. the match equity
  ///    at score (acceptor `moverAway - offeredPoints`, opponent `opponentAway`).
  ///  * `eqPlayOn` = [matchEquityOfDistribution] over the acceptor's outcome
  ///    distribution at the current cube stake (`cube.value`).
  ///
  /// We DECLINE only when playing on beats accepting by more than a small
  /// hysteresis margin (`eqPlayOn > eqAccept + 0.005`). Declining a resignation
  /// is socially odd unless it is clearly right, so the tie-break leans toward
  /// accepting.
  ///
  /// This is genuinely match-aware and subsumes the old class-likelihood
  /// heuristic. In particular, when the acceptor is 1-away (`moverAway == 1`),
  /// any offer of at least 1 point drives `eqAccept` to 1.0 (the match is won),
  /// so every resignation is accepted regardless of gammon/backgammon prospects.
  @override
  Future<bool> chooseResignResponse(
      GameState state, ResignValue value, MatchContext ctx) async {
    final probs = await _engine.evaluate(state.board, state.turn);
    final offeredPoints = state.cube.value * value.multiplier;
    final eqAccept = matchEquityAfter(
      ctx.moverAway - offeredPoints,
      ctx.opponentAway,
      crawfordPlayed: ctx.crawfordPlayed,
    );
    final eqPlayOn = matchEquityOfDistribution(
      probs,
      moverAway: ctx.moverAway,
      opponentAway: ctx.opponentAway,
      stake: state.cube.value,
      crawfordPlayed: ctx.crawfordPlayed,
    );
    // Decline only when playing on is clearly better; otherwise accept.
    return eqPlayOn <= eqAccept + 0.005;
  }

  @override
  void dispose() {}
}
