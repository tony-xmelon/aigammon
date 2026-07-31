import 'dart:async';

import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

const _probs = Probabilities(
  win: 0.5,
  winGammon: 0,
  winBackgammon: 0,
  loseGammon: 0,
  loseBackgammon: 0,
);

const _advice = CubeAdvice(
  shouldDouble: false,
  shouldAccept: true,
  equityCubeless: 0,
  equityNoDouble: 0,
  equityDoubleTake: 0,
);

/// A fake engine standing in for a real [EngineService] adapter.
///
/// [dieOnNextCall] makes the next verb call throw the isolate-death StateError,
/// simulating a crashed isolate. [failWith] makes it throw an arbitrary error.
class FakeEngine implements EngineApi {
  FakeEngine(this.id);
  final int id;

  bool dieOnNextCall = false;
  Object? failWith;
  int rankMovesCalls = 0;
  bool disposed = false;

  void _maybeThrow() {
    if (dieOnNextCall) {
      dieOnNextCall = false;
      throw StateError('engine isolate died while handling request');
    }
    final f = failWith;
    if (f != null) {
      failWith = null;
      throw f;
    }
  }

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    rankMovesCalls++;
    _maybeThrow();
    return const [];
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async {
    _maybeThrow();
    return _advice;
  }

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async {
    _maybeThrow();
    return _probs;
  }

  @override
  Future<Move> bestMove(BoardState board, Player mover, Dice dice,
      {int xAway = 0, int oAway = 0}) async {
    _maybeThrow();
    return Move.none;
  }

  @override
  void dispose() => disposed = true;
}

/// Builds a spawner returning a fresh [FakeEngine] each call, recording them.
class SpawnRecorder {
  final List<FakeEngine> spawned = [];
  int get count => spawned.length;

  Future<EngineApi> spawn() async {
    final engine = FakeEngine(spawned.length);
    spawned.add(engine);
    return engine;
  }
}

final _board = BoardState.initial();

void main() {
  group('EngineManager.withEngine', () {
    test('spawns lazily on first use and reuses on the second', () async {
      final rec = SpawnRecorder();
      final manager = EngineManager(spawner: rec.spawn);

      expect(rec.count, 0, reason: 'no spawn until first use');

      await manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));
      expect(rec.count, 1);

      await manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));
      expect(rec.count, 1, reason: 'second call reuses the live engine');
    });

    test('re-spawns once and retries when the isolate dies', () async {
      final rec = SpawnRecorder();
      final manager = EngineManager(spawner: rec.spawn);

      await manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));
      expect(rec.count, 1);
      final first = rec.spawned[0];
      first.dieOnNextCall = true;

      // The call fails once (isolate death), triggers a re-spawn, then succeeds.
      final result = await manager
          .withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));

      expect(result, isEmpty);
      expect(rec.count, 2, reason: 'exactly one re-spawn');
      expect(first.disposed, isTrue, reason: 'dead engine is disposed');
      // The retry ran on the new engine.
      expect(rec.spawned[1].rankMovesCalls, 1);
    });

    test('re-spawns once and retries when a call times out', () async {
      final rec = SpawnRecorder();
      final manager = EngineManager(spawner: rec.spawn);

      await manager
          .withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));
      final first = rec.spawned[0];
      // A wedged isolate: EngineService gave up waiting for a reply.
      first.failWith = TimeoutException('engine "rankMoves" did not reply');

      final result = await manager
          .withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));

      expect(result, isEmpty);
      expect(rec.count, 2, reason: 'exactly one re-spawn');
      expect(first.disposed, isTrue,
          reason: 'the wedged engine is disposed, which kills its isolate');
      expect(rec.spawned[1].rankMovesCalls, 1);
    });

    test('rethrows when calls time out twice in one call (single retry)',
        () async {
      final spawned = <FakeEngine>[];
      final manager = EngineManager(spawner: () async {
        final e = FakeEngine(spawned.length)
          ..failWith = TimeoutException('did not reply');
        spawned.add(e);
        return e;
      });

      await expectLater(
        manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1))),
        throwsA(isA<TimeoutException>()),
      );
      expect(spawned.length, 2, reason: 'one spawn + one re-spawn, no loop');
    });

    test('rethrows non-death errors without re-spawning', () async {
      final rec = SpawnRecorder();
      final manager = EngineManager(spawner: rec.spawn);

      await manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));
      rec.spawned[0].failWith = StateError('unknown verb "frobnicate"');

      await expectLater(
        manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1))),
        throwsA(isA<StateError>()),
      );
      expect(rec.count, 1, reason: 'non-death error must not re-spawn');
    });

    test('rethrows when the isolate dies twice in one call (single retry)',
        () async {
      final rec = SpawnRecorder();
      // A spawner whose engines always die on their first call.
      final manager = EngineManager(spawner: () async {
        final rec0 = FakeEngine(rec.spawned.length)..dieOnNextCall = true;
        rec.spawned.add(rec0);
        return rec0;
      });

      await expectLater(
        manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1))),
        throwsA(isA<StateError>()),
      );
      // One initial spawn + exactly one re-spawn = 2 engines; no infinite loop.
      expect(rec.spawned.length, 2);
    });

    test('after disposeManager, withEngine throws and the engine is disposed',
        () async {
      final rec = SpawnRecorder();
      final manager = EngineManager(spawner: rec.spawn);

      await manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));
      expect(rec.spawned[0].disposed, isFalse);

      await manager.disposeManager();
      expect(rec.spawned[0].disposed, isTrue);

      await expectLater(
        manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1))),
        throwsA(isA<StateError>()),
      );
    });

    test('disposeManager is idempotent', () async {
      final rec = SpawnRecorder();
      final manager = EngineManager(spawner: rec.spawn);
      await manager.withEngine((e) => e.rankMoves(_board, Player.white, Dice(3, 1)));

      await manager.disposeManager();
      await manager.disposeManager(); // no throw, no double-dispose harm
      expect(rec.spawned[0].disposed, isTrue);
    });
  });

  group('ManagedEngineFacade', () {
    test('routes rankMoves/cubeInfo through the manager', () async {
      final rec = SpawnRecorder();
      final manager = EngineManager(spawner: rec.spawn);
      final facade = ManagedEngineFacade(manager);

      final ranked = await facade.rankMoves(_board, Player.white, Dice(6, 5));
      expect(ranked, isEmpty);
      final advice = await facade.cubeInfo(_board, Player.white);
      expect(advice.shouldAccept, isTrue);
      expect(rec.count, 1, reason: 'both calls share one lazily-spawned engine');
    });
  });
}
