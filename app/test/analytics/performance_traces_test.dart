import 'package:aigammon_app/analytics/analytics_events.dart';
import 'package:aigammon_app/analytics/app_analytics.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_observability.dart';

/// A facade that answers instantly, or throws on demand.
class _StubFacade implements EngineFacade {
  _StubFacade({this.throws = false});

  final bool throws;
  int evaluateCalls = 0;
  int rankCalls = 0;
  int cubeCalls = 0;

  static const _probs = Probabilities(
    win: 0.5,
    winGammon: 0.1,
    winBackgammon: 0.01,
    loseGammon: 0.1,
    loseBackgammon: 0.01,
  );

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async {
    evaluateCalls++;
    if (throws) throw StateError('engine exploded');
    return _probs;
  }

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    rankCalls++;
    if (throws) throw StateError('engine exploded');
    return const [];
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async {
    cubeCalls++;
    if (throws) throw StateError('engine exploded');
    return const CubeAdvice(
      shouldDouble: false,
      shouldAccept: true,
      equityCubeless: 0,
      equityNoDouble: 0,
      equityDoubleTake: 0,
    );
  }
}

void main() {
  final board = BoardState.initial();

  group('TracedEngineFacade', () {
    test('traces each verb under its own name, and passes results through',
        () async {
      final perf = RecordingPerformance();
      final inner = _StubFacade();
      final facade = TracedEngineFacade(inner, perf);

      await facade.rankMoves(board, Player.white, Dice(3, 1));
      await facade.evaluate(board, Player.white);
      await facade.cubeInfo(board, Player.white);

      expect(perf.started, [
        PerfTraces.engineRankMoves,
        PerfTraces.engineEvaluate,
        PerfTraces.engineCubeInfo,
      ]);
      // Every trace that started also stopped: an unstopped trace would be
      // reported as an open span forever.
      expect(perf.stopped, perf.started);
      expect((inner.rankCalls, inner.evaluateCalls, inner.cubeCalls), (1, 1, 1));
    });

    test('a throwing call still stops its trace, and the error propagates',
        () async {
      final perf = RecordingPerformance();
      final facade = TracedEngineFacade(_StubFacade(throws: true), perf);

      await expectLater(
        facade.rankMoves(board, Player.white, Dice(3, 1)),
        throwsStateError,
      );

      expect(perf.started, [PerfTraces.engineRankMoves]);
      expect(perf.stopped, [PerfTraces.engineRankMoves]);
    });

    test('the no-op performance sink is a pass-through', () async {
      // What every desktop build and every widget test runs. The decorator must
      // not change the value, the timing, or the error behaviour.
      final inner = _StubFacade();
      final facade = TracedEngineFacade(inner, const NoopPerformance());

      expect(await facade.rankMoves(board, Player.white, Dice(3, 1)),
          isEmpty);
      expect(inner.rankCalls, 1);
    });
  });
}
