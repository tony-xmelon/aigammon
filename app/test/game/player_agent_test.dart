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

    test('chooseResignResponse declines a single when a gammon is likely',
        () async {
      final engine = FakeEngine(evalProbs: _probs(win: 0.9, winGammon: 0.3));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.single, _humanCtx),
          isFalse);
      expect(engine.lastEvalMover, Player.white,
          reason: 'evaluated from the acceptor (state.turn)');
    });

    test('chooseResignResponse accepts a single when a gammon is unlikely',
        () async {
      final engine = FakeEngine(evalProbs: _probs(win: 0.9, winGammon: 0.1));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.single, _humanCtx),
          isTrue);
    });

    test('chooseResignResponse declines a gammon when a backgammon is likely',
        () async {
      final engine = FakeEngine(
          evalProbs: _probs(win: 0.95, winGammon: 0.6, winBackgammon: 0.3));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.gammon, _humanCtx),
          isFalse);
    });

    test('chooseResignResponse accepts a gammon when a backgammon is unlikely',
        () async {
      final engine = FakeEngine(
          evalProbs: _probs(win: 0.95, winGammon: 0.6, winBackgammon: 0.05));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.gammon, _humanCtx),
          isTrue);
    });

    test('chooseResignResponse always accepts a backgammon offer', () async {
      final engine = FakeEngine(
          evalProbs: _probs(win: 0.99, winGammon: 0.9, winBackgammon: 0.8));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.backgammon, _humanCtx),
          isTrue);
    });
  });
}
