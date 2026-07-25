import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';

import '../game/player_agent.dart';
import 'move_assessment.dart';

/// Pure move/cube-assessment logic for the live tutor and post-game analysis.
///
/// It consults an [EngineFacade] for move rankings and cubeless evaluations and
/// a [MatchCubeAdvisor] for match-aware cube advice, then turns those into
/// [MoveAssessment] / [CubeAssessment] verdicts. It holds no UI state; Task 6
/// wires the toggle and display.
class TutorService {
  // The advisor is stored in a private field; the public named parameter keeps
  // the `advisor` name for callers, so an initializing formal is not possible.
  TutorService(this._engine, {MatchCubeAdvisor advisor = const MatchCubeAdvisor()})
      // ignore: prefer_initializing_formals
      : _advisor = advisor;

  final EngineFacade _engine;
  final MatchCubeAdvisor _advisor;

  /// Ranked candidate plays for [state], best first. Empty when [state] is not
  /// in the moving phase or the player has no legal play (a dance).
  Future<List<ScoredMove>> hint(GameState state) async {
    if (state.phase != GamePhase.moving) return const [];
    if (state.legalMoves.isEmpty) return const [];
    return _engine.rankMoves(state.board, state.turn, state.dice!);
  }

  /// Assesses [played] against the best available play.
  ///
  /// [before] MUST be the moving-phase state the move was played FROM.
  /// Resolution of [played] within the ranking:
  ///  1. by hop multiset ([Move.sameAs]);
  ///  2. failing that (a transit-equivalent decomposition the generator deduped
  ///     away), by applying [played] to `before.board` and matching the
  ///     resulting board against each ranked move's applied board.
  ///
  /// On a dance (no legal play) the result is `equityLoss 0`, [MoveMark.best],
  /// and `best = Move.none`.
  Future<MoveAssessment> assess(GameState before, Move played) async {
    if (before.legalMoves.isEmpty) {
      return MoveAssessment(
        played: played,
        best: Move.none,
        equityLoss: 0,
        ranked: const [],
      );
    }

    final ranked =
        await _engine.rankMoves(before.board, before.turn, before.dice!);
    if (ranked.isEmpty) {
      return MoveAssessment(
        played: played,
        best: Move.none,
        equityLoss: 0,
        ranked: const [],
      );
    }

    final best = ranked.first;
    final playedScored = _resolvePlayed(before, played, ranked);

    // Equity is from the mover's perspective (higher is better), so the loss is
    // best minus played; a resolved play at the top gives 0 (clamped against
    // float fuzz). An unresolvable submission is treated as no loss rather than
    // fabricating a penalty.
    final rawLoss =
        playedScored == null ? 0.0 : best.equity - playedScored.equity;

    return MoveAssessment(
      played: played,
      best: best.move,
      equityLoss: rawLoss < 0 ? 0 : rawLoss,
      ranked: ranked,
    );
  }

  /// Locates [played] within [ranked]: first by hop multiset, then by
  /// position equivalence (the applied-board fallback). Returns null when
  /// neither matches.
  ScoredMove? _resolvePlayed(
      GameState before, Move played, List<ScoredMove> ranked) {
    for (final sm in ranked) {
      if (sm.move.sameAs(played)) return sm;
    }
    final resulting = before.board.applyMove(before.turn, played);
    for (final sm in ranked) {
      if (before.board.applyMove(before.turn, sm.move) == resulting) {
        return sm;
      }
    }
    return null;
  }

  /// Assesses the pre-roll cube decision at [state] for the on-turn player.
  ///
  /// [ctx] is built from the on-turn player's (`state.turn`'s) perspective, as
  /// for [AiAgent.considerDouble]. [playerDoubled] is what the player did (or
  /// is considering): `true` = offered the cube, `false` = rolled on.
  Future<CubeAssessment> assessCube(GameState state, MatchContext ctx,
      {required bool playerDoubled}) async {
    final probs = await _engine.evaluate(state.board, state.turn);
    final advice = _advisor.advise(
      probs: probs,
      moverAway: ctx.moverAway,
      opponentAway: ctx.opponentAway,
      cubeValue: state.cube.value,
      crawfordPlayed: ctx.crawfordPlayed,
    );
    return CubeAssessment(actionWasDouble: playerDoubled, advice: advice);
  }

  /// Advises the DECIDER facing a double at [state] (a [GamePhase.cubeOffered]
  /// state whose `state.turn` is the decider being asked to take or pass).
  ///
  /// [deciderCtx] is anchored to the decider (`state.turn`), exactly as
  /// [GameController.contextFor] produces for `state.turn`. The advisor reasons
  /// from the DOUBLER's perspective, so — mirroring [AiAgent.chooseCubeResponse]
  /// — the position is evaluated for the doubler (`state.turn.opponent`) and the
  /// aways are inverted (the doubler's away is [MatchContext.opponentAway], the
  /// decider's is [MatchContext.moverAway]).
  ///
  /// The returned assessment's `advice.shouldTake` is the DECIDER's correct
  /// response; `actionWasDouble` is `true` (the doubler did offer the cube).
  Future<CubeAssessment> assessCubeResponse(
      GameState state, MatchContext deciderCtx) async {
    final doubler = state.turn.opponent;
    final probs = await _engine.evaluate(state.board, doubler);
    final advice = _advisor.advise(
      probs: probs,
      moverAway: deciderCtx.opponentAway,
      opponentAway: deciderCtx.moverAway,
      cubeValue: state.cube.value,
      crawfordPlayed: deciderCtx.crawfordPlayed,
    );
    return CubeAssessment(actionWasDouble: true, advice: advice);
  }
}
