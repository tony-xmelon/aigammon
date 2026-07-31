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

/// Completes the handshake, answers `evaluate`, and then dies a few
/// milliseconds later — long enough after the reply that the death is OBSERVED
/// before the caller's next request is issued.
void diesLaterWorker(List<Object?> args) {
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
  Timer(const Duration(milliseconds: 5), () {
    throw StateError('worker died a moment after the handshake');
  });
}

/// Completes the handshake and then EXITS CLEANLY — no error, just a worker
/// that stops existing. Nothing but the exit signal can reveal this, and the
/// exit almost certainly happens before `spawn()` resumes.
void quietlyExitingWorker(List<Object?> args) {
  final handshake = args[0] as SendPort;
  final commands = ReceivePort();
  handshake.send(['ready', commands.sendPort]);
  commands.close();
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

  // The supervisor (the app's EngineManager) decides whether to drop and
  // re-spawn by MATCHING THE MESSAGE of the StateError. A death that is already
  // observed by the time the next call is made must therefore still say
  // "died" — saying "disposed" instead makes the supervisor rethrow without
  // dropping, and the dead service stays cached for the rest of the session.
  test('a call made AFTER the death is observed still reports a death',
      () async {
    final service = await EngineService.spawn(
      netsPath: 'unused',
      workerEntry: diesLaterWorker,
      callTimeout: const Duration(seconds: 20),
    );
    addTearDown(service.dispose);

    // One good round trip, so the failure below cannot be a startup problem.
    await service.evaluate(BoardState.initial(), Player.white);
    // Long enough that _onDeath has certainly run before the next call.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await expectLater(
      service.evaluate(BoardState.initial(), Player.white),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('isolate died'))),
    );
  });

  // The error half of the death port is registered BY the spawn. The clean-exit
  // half used to be added afterwards, from the constructor — and the Dart SDK
  // is explicit that an exit listener requested after the isolate has already
  // terminated never fires. A worker that exits in that gap was therefore
  // invisible: the service believed it was alive and every call waited out the
  // full timeout.
  //
  // Honesty about what this test is: a GUARD, not a reproduction. It passed
  // before the fix as well, because the gap is a race and this worker loses it
  // — the parent almost always finishes the constructor before the VM reports
  // the exit. Nothing available from outside `spawn()` can widen that window,
  // so the fix is justified by the SDK contract rather than by a red bar, and
  // this test's job is to notice if the clean-exit signal ever stops arriving
  // at all.
  test('a clean exit right after the handshake still reaches the service',
      () async {
    final service = await EngineService.spawn(
      netsPath: 'unused',
      workerEntry: quietlyExitingWorker,
      // Short enough to keep the test quick, long enough that a timeout is
      // clearly distinguishable from the death signal by elapsed time.
      callTimeout: const Duration(seconds: 2),
    );
    addTearDown(service.dispose);

    final started = DateTime.now();
    await expectLater(
      service.evaluate(BoardState.initial(), Player.white),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('isolate died'))),
    );
    expect(DateTime.now().difference(started),
        lessThan(const Duration(milliseconds: 500)),
        reason: 'the exit signal must fail the call, not the timeout');
  });

  test('a call after a deliberate dispose() reports a disposal, not a death',
      () async {
    final service =
        await EngineService.spawn(netsPath: 'unused', workerEntry: echoWorker);
    service.dispose();

    await expectLater(
      service.evaluate(BoardState.initial(), Player.white),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('disposed'))),
    );
  });
}
