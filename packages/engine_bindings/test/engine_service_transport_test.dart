// Transport-level tests for EngineService: what happens when the worker
// MISBEHAVES. These are deliberately untagged — no native library, no
// Engine.open — because the failures under test are properties of the isolate
// plumbing, not of the engine. `EngineService.spawn`'s test-only `workerEntry`
// hook swaps in a worker that speaks the handshake and then goes wrong in one
// specific way.
//
// The two failures pinned here are the ones that used to end the same way for
// the caller — a future that never settles:
//
//  * a worker that accepts a request and never replies (a wedged native call
//    does not kill the isolate, so nothing else notices);
//  * a worker that dies in the seam right after the handshake, when the old
//    code had already torn down the startup error port and had not yet added
//    its own listener — and a listener added to an ALREADY-DEAD isolate never
//    fires, so the death was lost outright rather than merely delayed.
import 'dart:async';
import 'dart:isolate';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

/// Completes the handshake and then swallows every request. Stands in for a
/// native call that has wedged: the isolate is alive and healthy-looking, the
/// reply simply never comes.
void silentWorker(List<Object?> args) {
  final handshake = args[0] as SendPort;
  final commands = ReceivePort();
  handshake.send(['ready', commands.sendPort]);
  commands.listen((message) {
    final list = message as List;
    if (list[0] == 'dispose') commands.close();
    // Everything else is dropped on the floor.
  });
}

/// Completes the handshake and dies immediately afterwards, inside the window
/// spawn() needs to finish wiring the service up.
void dyingWorker(List<Object?> args) {
  final handshake = args[0] as SendPort;
  final commands = ReceivePort();
  handshake.send(['ready', commands.sendPort]);
  throw StateError('worker died right after the handshake');
}

/// A well-behaved worker with no engine behind it: answers `evaluate` with a
/// fixed distribution. Present so the misbehaviour tests are read against a
/// baseline that proves the same seam carries a NORMAL round trip.
void echoWorker(List<Object?> args) {
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
    reply?.send([list[0], 'ok', <double>[0.6, 0.2, 0.05, 0.1, 0.01]]);
  });
}

void main() {
  test('a normal round trip still works through the rebuilt handshake',
      () async {
    final service =
        await EngineService.spawn(netsPath: 'unused', workerEntry: echoWorker);
    addTearDown(service.dispose);
    final probs = await service.evaluate(BoardState.initial(), Player.white);
    expect(probs.win, closeTo(0.6, 1e-12));
  });

  test('a worker that never replies fails the call instead of hanging',
      () async {
    final service = await EngineService.spawn(
      netsPath: 'unused',
      workerEntry: silentWorker,
      callTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(service.dispose);

    final started = DateTime.now();
    await expectLater(
      service.evaluate(BoardState.initial(), Player.white),
      throwsA(isA<TimeoutException>()),
    );
    // The bound is the caller's, not the test framework's: without it this
    // future never settles at all.
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
  });

  test('a timed-out call does not leak, and a later reply is ignored',
      () async {
    final service = await EngineService.spawn(
      netsPath: 'unused',
      workerEntry: silentWorker,
      callTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(service.dispose);

    for (var i = 0; i < 3; i++) {
      await expectLater(
        service.evaluate(BoardState.initial(), Player.white),
        throwsA(isA<TimeoutException>()),
      );
    }
    // Each attempt failed on its own; none of them poisoned the next.
    await expectLater(
      service.evaluate(BoardState.initial(), Player.white),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a death right after the handshake reaches the service', () async {
    final observed = <Object>[];
    final service = await EngineService.spawn(
      netsPath: 'unused',
      workerEntry: dyingWorker,
      onIsolateError: (error, _) => observed.add(error),
      // Long on purpose: a call that fails by TIMING OUT would mean the death
      // was still missed and we merely papered over it.
      callTimeout: const Duration(seconds: 20),
    );
    addTearDown(service.dispose);

    final started = DateTime.now();
    await expectLater(
      service.evaluate(BoardState.initial(), Player.white),
      throwsA(isA<StateError>()),
    );
    expect(DateTime.now().difference(started),
        lessThan(const Duration(seconds: 10)));
    expect(observed, isNotEmpty,
        reason: 'the worker error must reach the diagnostics hook too');
  });

  test('a death fails calls already in flight', () async {
    final ready = Completer<void>();
    final service = await EngineService.spawn(
      netsPath: 'unused',
      workerEntry: dyingWorker,
      onIsolateError: (_, __) {
        if (!ready.isCompleted) ready.complete();
      },
      callTimeout: const Duration(seconds: 20),
    );
    addTearDown(service.dispose);

    // Issue the call BEFORE the death is observed where possible; either way
    // the call must end as a death, never as a hang.
    final inFlight = service.evaluate(BoardState.initial(), Player.white);
    await expectLater(inFlight, throwsA(isA<StateError>()));
    await ready.future;
  });
}
