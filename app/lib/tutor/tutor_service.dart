import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';

import '../diagnostics/crash_log.dart';
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
  ///
  /// [cubeLife] is Janowski's cube-efficiency passed straight to
  /// [MatchCubeAdvisor.advise] (default 0.7). It is plumbed here so a future
  /// settings screen (Plan 7+) can wire a user-tunable cube-life without
  /// touching this API; today callers just take the default.
  Future<CubeAssessment> assessCube(GameState state, MatchContext ctx,
      {required bool playerDoubled, double cubeLife = 0.7}) async {
    final probs = await _engine.evaluate(state.board, state.turn);
    final advice = _advisor.advise(
      probs: probs,
      moverAway: ctx.moverAway,
      opponentAway: ctx.opponentAway,
      cubeValue: state.cube.value,
      crawfordPlayed: ctx.crawfordPlayed,
      cubeLife: cubeLife,
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
  ///
  /// [cubeLife] is Janowski's cube-efficiency passed straight to
  /// [MatchCubeAdvisor.advise] (default 0.7), plumbed for a future settings
  /// hook exactly as in [assessCube].
  Future<CubeAssessment> assessCubeResponse(
      GameState state, MatchContext deciderCtx,
      {double cubeLife = 0.7}) async {
    final doubler = state.turn.opponent;
    final probs = await _engine.evaluate(state.board, doubler);
    final advice = _advisor.advise(
      probs: probs,
      moverAway: deciderCtx.opponentAway,
      opponentAway: deciderCtx.moverAway,
      cubeValue: state.cube.value,
      crawfordPlayed: deciderCtx.crawfordPlayed,
      cubeLife: cubeLife,
    );
    return CubeAssessment(actionWasDouble: true, advice: advice);
  }

  // --- Live-tutor variants ---------------------------------------------------
  //
  // The same four questions, asked from the GAME SCREEN rather than from
  // post-game analysis. The difference is what a failure may cost.
  //
  // Analysis awaits its answers and has a place to put a failure — the screen
  // shows "Failed to analyse game" — so the methods above throw, and must keep
  // throwing. The live tutor has neither: it is fired off mid-move and nobody
  // is waiting, so an engine failure (a dead isolate, a call that timed out)
  // becomes an unhandled async error with the whole game screen behind it. And
  // there is nothing useful to say about it anyway: the tutor is an aid, and a
  // silent one for a turn is a far smaller harm than an error over the board.
  //
  // So these absorb it — the mark, the advice or the hint simply does not
  // appear — and record the cause, which is where a repeating engine failure
  // becomes visible.

  /// [hint] for the live tutor: an empty list rather than a throw.
  ///
  /// Empty already means "nothing to suggest" to the hint panel (a dance, a
  /// state that is not moving), so a failure lands on a path the caller
  /// handles.
  Future<List<ScoredMove>> hintOrNone(GameState state) async {
    try {
      return await hint(state);
    } catch (error, stack) {
      _recordTutorFailure('hint', error, stack);
      return const [];
    }
  }

  /// [assess] for the live tutor: null rather than a throw.
  ///
  /// Null, not a zero-loss assessment: an unanswered move must leave the score
  /// sheet cell blank, never award it the "best play" dot it did not earn.
  Future<MoveAssessment?> assessOrNull(GameState before, Move played) async {
    try {
      return await assess(before, played);
    } catch (error, stack) {
      _recordTutorFailure('assess', error, stack);
      return null;
    }
  }

  /// [assessCube] for the live tutor: null rather than a throw.
  Future<CubeAssessment?> assessCubeOrNull(GameState state, MatchContext ctx,
      {required bool playerDoubled, double cubeLife = 0.7}) async {
    try {
      return await assessCube(state, ctx,
          playerDoubled: playerDoubled, cubeLife: cubeLife);
    } catch (error, stack) {
      _recordTutorFailure('assessCube', error, stack);
      return null;
    }
  }

  /// [assessCubeResponse] for the live tutor: null rather than a throw.
  Future<CubeAssessment?> assessCubeResponseOrNull(
      GameState state, MatchContext deciderCtx,
      {double cubeLife = 0.7}) async {
    try {
      return await assessCubeResponse(state, deciderCtx, cubeLife: cubeLife);
    } catch (error, stack) {
      _recordTutorFailure('assessCubeResponse', error, stack);
      return null;
    }
  }

  void _recordTutorFailure(String verb, Object error, StackTrace stack) {
    CrashLog.instance.record(error, stack: stack, source: 'tutor-$verb');
  }
}
