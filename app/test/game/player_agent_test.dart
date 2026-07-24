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
  })  : ranked = ranked ?? const [],
        advice = advice ?? _defaultAdvice;

  List<ScoredMove> ranked;
  CubeAdvice advice;

  int rankMovesCalls = 0;
  int cubeInfoCalls = 0;

  static const _defaultAdvice = CubeAdvice(
    shouldDouble: false,
    shouldAccept: true,
    equityCubeless: 0,
    equityNoDouble: 0,
    equityDoubleTake: 0,
  );

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    rankMovesCalls++;
    return ranked;
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async {
    cubeInfoCalls++;
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

CubeAdvice _adviceWith({bool shouldDouble = false, bool shouldAccept = true}) =>
    CubeAdvice(
      shouldDouble: shouldDouble,
      shouldAccept: shouldAccept,
      equityCubeless: 0,
      equityNoDouble: 0,
      equityDoubleTake: 0,
    );

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

      final doubleF = agent.considerDouble(_awaitingRollState());
      agent.submitDoubleDecision(true);
      expect(await doubleF, isTrue);

      final cubeF = agent.chooseCubeResponse(_awaitingRollState());
      agent.submitCubeResponse(CubeAction.drop);
      expect(await cubeF, CubeAction.drop);

      final resignF =
          agent.chooseResignResponse(_awaitingRollState(), ResignValue.gammon);
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
      final future = agent.chooseResignResponse(state, ResignValue.backgammon);
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

    test('considerDouble reflects engine advice', () async {
      final doublingEngine =
          FakeEngine(advice: _adviceWith(shouldDouble: true));
      final holdEngine = FakeEngine(advice: _adviceWith(shouldDouble: false));

      expect(
          await AiAgent(doublingEngine, Difficulty.expert, Random(1))
              .considerDouble(_awaitingRollState()),
          isTrue);
      expect(
          await AiAgent(holdEngine, Difficulty.expert, Random(1))
              .considerDouble(_awaitingRollState()),
          isFalse);
    });

    test('chooseCubeResponse takes when advice says accept', () async {
      final engine = FakeEngine(advice: _adviceWith(shouldAccept: true));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(await agent.chooseCubeResponse(_awaitingRollState()),
          CubeAction.take);
    });

    test('chooseCubeResponse drops when advice says reject', () async {
      final engine = FakeEngine(advice: _adviceWith(shouldAccept: false));
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(await agent.chooseCubeResponse(_awaitingRollState()),
          CubeAction.drop);
    });

    test('chooseResignResponse always accepts (v1 policy)', () async {
      final engine = FakeEngine();
      final agent = AiAgent(engine, Difficulty.expert, Random(1));
      expect(
          await agent.chooseResignResponse(
              _awaitingRollState(), ResignValue.single),
          isTrue);
    });
  });
}
