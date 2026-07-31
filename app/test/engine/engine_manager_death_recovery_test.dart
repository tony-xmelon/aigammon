// End-to-end recovery test: a REAL [EngineService] isolate (no native engine —
// the transport's test-only `workerEntry` hook stands in for one) dies, and the
// app's [EngineManager] has to notice and re-spawn.
//
// `engine_provider_test.dart` covers the manager's policy against a fake engine
// that throws on demand. This file covers the seam between the two: the exact
// STRING the service throws has to be one the manager recognises as a death.
// The fake cannot catch a mismatch there, because the fake is the thing that
// chooses the string.
//
// Both orderings matter, and they used to behave differently:
//
//  * the death lands WHILE a call is in flight — the pending completer is
//    failed with 'engine isolate died', which the manager has always matched;
//  * the death is already OBSERVED when the next call is made — this is the
//    normal case in practice (a crash is rarely simultaneous with a request),
//    and it used to throw 'EngineService disposed', which the manager did NOT
//    match: it rethrew without dropping, leaving the dead service cached and
//    every later engine call in the session failing the same way.
import 'dart:async';
import 'dart:isolate';

import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

const _reply = <double>[0.6, 0.2, 0.05, 0.1, 0.01];

/// Handshakes, answers every verb, never dies.
void healthyWorker(List<Object?> args) {
  final handshake = args[0] as SendPort;
  final commands = ReceivePort();
  handshake.send(['ready', commands.sendPort]);
  SendPort? reply;
  commands.listen((message) {
    final list = message as List;
    if (list[0] == 'bind') {
      reply = list[1] as SendPort;
      return;
    }
    if (list[0] == 'dispose') {
      commands.close();
      return;
    }
    reply?.send([list[0], 'ok', _reply]);
  });
}

/// Answers the first verb, then dies a few milliseconds later — so the death is
/// observed BEFORE the next call is issued.
void diesBetweenCallsWorker(List<Object?> args) {
  final handshake = args[0] as SendPort;
  final commands = ReceivePort();
  handshake.send(['ready', commands.sendPort]);
  SendPort? reply;
  commands.listen((message) {
    final list = message as List;
    if (list[0] == 'bind') {
      reply = list[1] as SendPort;
      return;
    }
    if (list[0] == 'dispose') {
      commands.close();
      return;
    }
    reply?.send([list[0], 'ok', _reply]);
    Timer(const Duration(milliseconds: 5), () {
      throw StateError('the worker crashed between calls');
    });
  });
}

/// Dies on its first verb without replying: the death races the in-flight call.
void diesOnRequestWorker(List<Object?> args) {
  final handshake = args[0] as SendPort;
  final commands = ReceivePort();
  handshake.send(['ready', commands.sendPort]);
  commands.listen((message) {
    final list = message as List;
    if (list[0] == 'bind') return;
    if (list[0] == 'dispose') {
      commands.close();
      return;
    }
    throw StateError('the worker crashed handling the request');
  });
}

/// Adapts a real [EngineService] to the manager's [EngineApi] seam — the same
/// pass-through the production spawner uses, which is private to the provider.
class _ServiceApi implements EngineApi {
  _ServiceApi(this._service);
  final EngineService _service;

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) =>
      _service.evaluate(board, mover);

  @override
  Future<Move> bestMove(BoardState board, Player mover, Dice dice,
          {int xAway = 0, int oAway = 0}) =>
      _service.bestMove(board, mover, dice, xAway: xAway, oAway: oAway);

  @override
  Future<List<ScoredMove>> rankMoves(
          BoardState board, Player mover, Dice dice) =>
      _service.rankMoves(board, mover, dice);

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) =>
      _service.cubeInfo(board, mover);

  @override
  void dispose() => _service.dispose();
}

/// Spawns a real service per call: the doomed [first] worker once, then healthy
/// ones, so a successful retry proves the manager re-spawned rather than
/// papered over the failure.
class _Spawner {
  _Spawner(this.first);
  final void Function(List<Object?>) first;
  int count = 0;

  Future<EngineApi> spawn() async {
    final entry = count == 0 ? first : healthyWorker;
    count++;
    final service = await EngineService.spawn(
      netsPath: 'unused',
      workerEntry: entry,
      // Long on purpose: if recovery only happens because a call TIMED OUT,
      // this test takes 20s and fails its elapsed-time bound, rather than
      // passing and hiding the fact that the death itself went unnoticed.
      callTimeout: const Duration(seconds: 20),
    );
    return _ServiceApi(service);
  }
}

final _board = BoardState.initial();

void main() {
  test('recovers when the death is observed BEFORE the next call', () async {
    final spawner = _Spawner(diesBetweenCallsWorker);
    final manager = EngineManager(spawner: spawner.spawn);
    addTearDown(manager.disposeManager);

    final first = await manager.withEngine((e) => e.evaluate(_board, Player.white));
    expect(first.win, closeTo(0.6, 1e-9));
    expect(spawner.count, 1);

    // The gap: _onDeath runs and is fully observed while nothing is in flight.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final started = DateTime.now();
    final second =
        await manager.withEngine((e) => e.evaluate(_board, Player.white));
    expect(second.win, closeTo(0.6, 1e-9),
        reason: 'the manager must drop the dead engine and re-spawn');
    expect(spawner.count, 2, reason: 'exactly one re-spawn');
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)),
        reason: 'recovery must come from the death signal, not the timeout');

    // And the session is not poisoned: the next call reuses the new engine.
    final third =
        await manager.withEngine((e) => e.evaluate(_board, Player.white));
    expect(third.win, closeTo(0.6, 1e-9));
    expect(spawner.count, 2);
  });

  test('recovers when the death races the in-flight call', () async {
    final spawner = _Spawner(diesOnRequestWorker);
    final manager = EngineManager(spawner: spawner.spawn);
    addTearDown(manager.disposeManager);

    final started = DateTime.now();
    final probs =
        await manager.withEngine((e) => e.evaluate(_board, Player.white));

    expect(probs.win, closeTo(0.6, 1e-9));
    expect(spawner.count, 2, reason: 'exactly one re-spawn');
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
  });
}
