import 'dart:math';

import 'package:aigammon_app/game/player_agent.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Canned engine used to drive [AiAgent] without native code.
class FakeEngine implements EngineFacade {
  FakeEngine({
    List<ScoredMove>? ranked,
    CubeAdvice? advice,
    Probabilities? evalProbs,
  })  : ranked = ranked ?? const [],
        advice = advice ?? _defaultAdvice,
        evalProbs = evalProbs ?? _defaultProbs;

  List<ScoredMove> ranked;
  CubeAdvice advice;
  Probabilities evalProbs;

  int rankMovesCalls = 0;
  int cubeInfoCalls = 0;
  int evaluateCalls = 0;
  Player? lastRankMover;
  Player? lastCubeMover;
  Player? lastEvalMover;

  static const _defaultAdvice = CubeAdvice(
    shouldDouble: false,
    shouldAccept: true,
    equityCubeless: 0,
    equityNoDouble: 0,
    equityDoubleTake: 0,
  );

  static const _defaultProbs = Probabilities(
    win: 0.5,
    winGammon: 0,
    winBackgammon: 0,
    loseGammon: 0,
    loseBackgammon: 0,
  );

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async {
    evaluateCalls++;
    lastEvalMover = mover;
    return evalProbs;
  }

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    rankMovesCalls++;
    lastRankMover = mover;
    return ranked;
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async {
    cubeInfoCalls++;
    lastCubeMover = mover;
    return advice;
  }
}

ScoredMove _scored(Move move, double win) => ScoredMove(
      move: move,
      probabilities: Probabilities(
        win: win,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      ),
    );

Probabilities _probs({
  double win = 0.5,
  double winGammon = 0,
  double winBackgammon = 0,
  double loseGammon = 0,
  double loseBackgammon = 0,
}) =>
    Probabilities(
      win: win,
      winGammon: winGammon,
      winBackgammon: winBackgammon,
      loseGammon: loseGammon,
      loseBackgammon: loseBackgammon,
    );

MatchContext _ctx({
  required int moverAway,
  required int opponentAway,
  bool crawfordPlayed = false,
}) =>
    MatchContext(
      moverAway: moverAway,
      opponentAway: opponentAway,
      crawfordPlayed: crawfordPlayed,
    );

GameState _movingState({Dice? dice}) => GameState.testState(
      board: BoardState.initial(),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: dice ?? Dice(3, 1),
    );

GameState _awaitingRollState() => GameState.testState(
      board: BoardState.initial(),
      turn: Player.white,
      phase: GamePhase.awaitingRoll,
    );

/// White has doubled; black is now the decider being asked to take.
GameState _cubeOfferedState() => GameState.testState(
      board: BoardState.initial(),
      turn: Player.black,
      phase: GamePhase.cubeOffered,
    );

/// A [MatchContext] for the human tests, which ignore it.
final _humanCtx = _ctx(moverAway: 3, opponentAway: 3);

void main() {
  group('LocalHumanAgent', () {
    test('chooseMove completes when submitMove is called', () async {
      final agent = LocalHumanAgent();
      final future = agent.chooseMove(_movingState());
      final move = Move([const CheckerMove(23, 20)]);
      agent.submitMove(move);
      expect(await future, same(move));
      agent.dispose();
    });

    test('all four verbs round-trip request -> submit', () async {
      final agent = LocalHumanAgent();

      final moveF = agent.chooseMove(_movingState());
      final move = Move([const CheckerMove(23, 20)]);
      agent.submitMove(move);
      expect(await moveF, same(move));

      final doubleF = agent.considerDouble(_awaitingRollState(), _humanCtx);
      agent.submitDoubleDecision(true);
      expect(await doubleF, isTrue);

      final cubeF = agent.chooseCubeResponse(_awaitingRollState(), _humanCtx);
      agent.submitCubeResponse(CubeAction.drop);
      expect(await cubeF, CubeAction.drop);

      final resignF = agent.chooseResignResponse(
          _awaitingRollState(), ResignValue.gammon, _humanCtx);
      agent.submitResignResponse(false);
      expect(await resignF, isFalse);

      agent.dispose();
    });

    test('submit without a pending request throws StateError', () {
      final agent = LocalHumanAgent();
      expect(() => agent.submitMove(Move([const CheckerMove(23, 20)])),
          throwsStateError);
      expect(() => agent.submitDoubleDecision(true), throwsStateError);
      expect(() => agent.submitCubeResponse(CubeAction.take), throwsStateError);
      expect(() => agent.submitResignResponse(true), throwsStateError);
      agent.dispose();
    });

    test('a second concurrent request of the same kind throws StateError', () {
      final agent = LocalHumanAgent();

      agent.chooseMove(_movingState());
      expect(() => agent.chooseMove(_movingState()), throwsStateError);

      agent.considerDouble(_awaitingRollState(), _humanCtx);
      expect(() => agent.considerDouble(_awaitingRollState(), _humanCtx),
          throwsStateError);

      agent.chooseCubeResponse(_awaitingRollState(), _humanCtx);
      expect(() => agent.chooseCubeResponse(_awaitingRollState(), _humanCtx),
          throwsStateError);

      agent.chooseResignResponse(
          _awaitingRollState(), ResignValue.single, _humanCtx);
      expect(
          () => agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.single, _humanCtx),
          throwsStateError);

      agent.dispose();
    });

    test('pendingMoveRequest notifier is set on request and null after submit',
        () async {
      final agent = LocalHumanAgent();
      expect(agent.pendingMoveRequest.value, isNull);

      final state = _movingState();
      final future = agent.chooseMove(state);
      expect(agent.pendingMoveRequest.value, same(state));

      agent.submitMove(Move([const CheckerMove(23, 20)]));
      await future;
      expect(agent.pendingMoveRequest.value, isNull);
      agent.dispose();
    });

    test('pendingResignRequest carries the state and value', () async {
      final agent = LocalHumanAgent();
      final state = _awaitingRollState();
      final future =
          agent.chooseResignResponse(state, ResignValue.backgammon, _humanCtx);
      expect(agent.pendingResignRequest.value, isNotNull);
      expect(agent.pendingResignRequest.value!.$1, same(state));
      expect(agent.pendingResignRequest.value!.$2, ResignValue.backgammon);

      agent.submitResignResponse(true);
      expect(await future, isTrue);
      expect(agent.pendingResignRequest.value, isNull);
      agent.dispose();
    });

    test('dispose clears notifiers', () {
      final agent = LocalHumanAgent();
      agent.chooseMove(_movingState());
      expect(agent.pendingMoveRequest.value, isNotNull);
      agent.dispose();
      expect(agent.pendingMoveRequest.value, isNull);
    });
  });

  group('AiAgent', () {
    test('expert picks the top-ranked move', () async {
      final top = Move([const CheckerMove(23, 20)]);
      final other = Move([const CheckerMove(12, 9)]);
      final engine = FakeEngine(ranked: [
        _scored(top, 0.9),
        _scored(other, 0.4),
      ]);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));

      final chosen = await agent.chooseMove(_movingState());
      expect(chosen, same(top));
      expect(engine.rankMovesCalls, 1);
    });

    test('empty ranked list yields Move.none', () async {
      final engine = FakeEngine(ranked: const []);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      final chosen = await agent.chooseMove(_movingState());
      expect(chosen, same(Move.none));
    });

    test('missing dice throws StateError', () async {
      final engine = FakeEngine(ranked: const []);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(() => agent.chooseMove(_awaitingRollState()), throwsStateError);
    });

    test('considerDouble doubles when the advisor says so (2a/2a, w=0.6)',
        () async {
      // At 2-away/2-away, cube 1, a gammonless 0.6 win doubles (take point is
      // beaten). Evaluated from the mover (state.turn == white).
      final engine = FakeEngine(evalProbs: _probs(win: 0.6));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.considerDouble(
              _awaitingRollState(), _ctx(moverAway: 2, opponentAway: 2)),
          isTrue);
      expect(engine.lastEvalMover, Player.white,
          reason: 'evaluated from the mover (state.turn)');
    });

    test('considerDouble holds when the advisor says so (2a/2a, w=0.5)',
        () async {
      final engine = FakeEngine(evalProbs: _probs(win: 0.5));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.considerDouble(
              _awaitingRollState(), _ctx(moverAway: 2, opponentAway: 2)),
          isFalse);
    });

    test('chooseCubeResponse evaluates the doubler and inverts the aways',
        () async {
      // cubeOffered: turn = black (decider), doubler = white. ctx is anchored
      // to the DECIDER: moverAway = decider (2), opponentAway = doubler (5).
      // The advisor must be fed the DOUBLER's perspective, so the agent
      // inverts the aways. probs (win 0.75, gammonless, doubler's view) is
      // chosen so the correct orientation (doubler 5-away, taker 2-away where the
      // recube is worthless) says TAKE while the inverted-by-mistake orientation
      // (taker 5-away) says DROP — pinning the fix. NB: 0.75 (was 0.61 under the
      // dead-cube model) keeps the contrast alive at the new cubeLife 0.7
      // default, where the livelier cube would otherwise make the 5-away taker
      // in the swapped orientation take too.
      const advisor = MatchCubeAdvisor();
      final probs = _probs(win: 0.75);
      final correct = advisor.advise(
          probs: probs, moverAway: 5, opponentAway: 2, cubeValue: 1);
      final swapped = advisor.advise(
          probs: probs, moverAway: 2, opponentAway: 5, cubeValue: 1);
      expect(correct.shouldTake, isTrue);
      expect(swapped.shouldTake, isFalse,
          reason: 'sanity: the orientation genuinely changes the decision');

      final engine = FakeEngine(evalProbs: probs);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      final state = _cubeOfferedState();
      expect(state.turn, Player.black);

      final action = await agent.chooseCubeResponse(
          state, _ctx(moverAway: 2, opponentAway: 5));

      expect(engine.lastEvalMover, Player.white,
          reason: 'must query the doubler (white), not the decider (black)');
      expect(action, CubeAction.take,
          reason: 'doubler is 5-away: taking is correct here');
    });

    // Match-equity-based resign policy. The AI is the ACCEPTOR (state.turn ==
    // white); it accepts unless PLAYING ON at the current cube stake beats
    // banking the offered points by more than the 0.005 hysteresis margin.
    // Expected equities below are cross-checked against the public helpers
    // (matchEquityAfter / matchEquityOfDistribution) so the fixtures cannot
    // silently drift from the shipped Kazaross-XG2 table.

    test('1-away acceptor accepts ANY resignation, even a likely gammon (flip)',
        () async {
      // Acceptor is 1-away, single offered (cube 1): banking 1 point wins the
      // match, so eqAccept = matchEquityAfter(1 - 1, 5) = 1.0 and nothing can
      // beat it. The OLD heuristic would DECLINE (winGammon 0.9 > 0.25); the
      // match-aware policy ACCEPTS. This is the headline behaviour flip.
      final engine = FakeEngine(
          evalProbs: _probs(win: 0.99, winGammon: 0.9, winBackgammon: 0.5));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(_awaitingRollState(),
              ResignValue.single, _ctx(moverAway: 1, opponentAway: 5)),
          isTrue);
      expect(engine.lastEvalMover, Player.white,
          reason: 'evaluated from the acceptor (state.turn)');
    });

    test('long match: declines a single when a gammon is very likely', () async {
      // 15-away/15-away, cube 1, single offered (banks 1 point).
      //   eqAccept  = matchEquityAfter(15 - 1, 15) = preCrawford(14,15) = 0.54075
      //   probs win 0.95, winGammon 0.5 -> single 0.45 / gammon 0.5, loseSingle 0.05
      //   eqPlayOn  = 0.45*pre(14,15) + 0.5*pre(13,15) + 0.05*pre(15,14)
      //             = 0.45*0.54075 + 0.5*0.582545 + 0.05*0.45925 = 0.5575725
      //   0.5575725 > 0.54075 + 0.005 -> DECLINE (playing on wins more points).
      final probs = _probs(win: 0.95, winGammon: 0.5);
      final ctx = _ctx(moverAway: 15, opponentAway: 15);
      final eqAccept = matchEquityAfter(14, 15, crawfordPlayed: false);
      final eqPlayOn = matchEquityOfDistribution(probs,
          moverAway: 15, opponentAway: 15, stake: 1, crawfordPlayed: false);
      expect(eqPlayOn, greaterThan(eqAccept + 0.005),
          reason: 'fixture must genuinely clear the hysteresis band');

      final engine = FakeEngine(evalProbs: probs);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.single, ctx),
          isFalse);
    });

    test('long match: declines a gammon offer when a backgammon is likely',
        () async {
      // 15a/15a, cube 1, gammon offered (banks 2): eqAccept = pre(13,15) = 0.582545.
      //   probs win 0.99 wg 0.9 wbg 0.6 -> single 0.09 / gammon 0.3 / bg 0.6,
      //     loseSingle 0.01.
      //   eqPlayOn = 0.09*pre(14,15) + 0.3*pre(13,15) + 0.6*pre(12,15)
      //            + 0.01*pre(15,14)
      //            = 0.09*0.54075 + 0.3*0.582545 + 0.6*0.625259 + 0.01*0.45925
      //            = 0.6031789  > 0.582545 + 0.005 -> DECLINE.
      final probs = _probs(win: 0.99, winGammon: 0.9, winBackgammon: 0.6);
      final ctx = _ctx(moverAway: 15, opponentAway: 15);
      final eqAccept = matchEquityAfter(13, 15, crawfordPlayed: false);
      final eqPlayOn = matchEquityOfDistribution(probs,
          moverAway: 15, opponentAway: 15, stake: 1, crawfordPlayed: false);
      expect(eqPlayOn, greaterThan(eqAccept + 0.005),
          reason: 'fixture must genuinely clear the hysteresis band');

      final engine = FakeEngine(evalProbs: probs);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.gammon, ctx),
          isFalse);
    });

    test('backgammon offer is accepted — there is no bigger class to chase',
        () async {
      // Same strong distribution, but a BACKGAMMON is offered (banks 3). At the
      // cube-1 stake the acceptor can win at most 3 points, so playing on cannot
      // out-bank the offer (and carries real downside):
      //   eqAccept = pre(12,15) = 0.625259 > eqPlayOn (0.6031789) -> ACCEPT.
      final probs = _probs(win: 0.99, winGammon: 0.9, winBackgammon: 0.6);
      final ctx = _ctx(moverAway: 15, opponentAway: 15);
      final eqAccept = matchEquityAfter(12, 15, crawfordPlayed: false);
      final eqPlayOn = matchEquityOfDistribution(probs,
          moverAway: 15, opponentAway: 15, stake: 1, crawfordPlayed: false);
      expect(eqPlayOn, lessThan(eqAccept),
          reason: 'banking the max class beats playing on');

      final engine = FakeEngine(evalProbs: probs);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.backgammon, ctx),
          isTrue);
    });

    test('hysteresis: a hair-thin play-on edge still accepts', () async {
      // 15a/15a, single offered. eqAccept = pre(14,15) = 0.54075.
      //   probs win 0.99 wg 0.05 -> single 0.94 / gammon 0.05, loseSingle 0.01.
      //   eqPlayOn = 0.94*pre(14,15) + 0.05*pre(13,15) + 0.01*pre(15,14)
      //            = 0.94*0.54075 + 0.05*0.582545 + 0.01*0.45925 = 0.5420248
      //   eqPlayOn > eqAccept (would DECLINE without hysteresis), but the surplus
      //   0.00127 < 0.005, so the policy leans to ACCEPT.
      final probs = _probs(win: 0.99, winGammon: 0.05);
      final ctx = _ctx(moverAway: 15, opponentAway: 15);
      final eqAccept = matchEquityAfter(14, 15, crawfordPlayed: false);
      final eqPlayOn = matchEquityOfDistribution(probs,
          moverAway: 15, opponentAway: 15, stake: 1, crawfordPlayed: false);
      expect(eqPlayOn, greaterThan(eqAccept),
          reason: 'play-on is genuinely (barely) ahead');
      expect(eqPlayOn, lessThan(eqAccept + 0.005),
          reason: 'but inside the hysteresis band');

      final engine = FakeEngine(evalProbs: probs);
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.single, ctx),
          isTrue);
    });
  });
}
