import 'dart:async';
import 'dart:isolate';

import 'package:backgammon_core/backgammon_core.dart';

import 'engine.dart';
import 'isolate_error.dart';
import 'scored_move.dart';

/// Async facade over [Engine], hosted in a dedicated isolate so neural-net
/// inference never blocks the caller (the UI thread in the app).
///
/// Protocol: (id, verb, payload-map) requests; (id, ok/err, payload)
/// replies, matched by id so concurrent calls are safe. If the isolate
/// dies, all pending requests error and the service is dead — the OWNER
/// (app layer) supervises and re-spawns; this class stays dumb on purpose.
class EngineService {
  final Isolate _isolate;
  final SendPort _worker;
  final ReceivePort _fromWorker;

  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;
  bool _dead = false;

  /// Called with an uncaught error from inside the worker isolate.
  ///
  /// Isolate errors reach NEITHER `FlutterError.onError` NOR
  /// `PlatformDispatcher.instance.onError` — they arrive only on a port
  /// registered with [Isolate.addErrorListener], which this class already owns
  /// for its own death handling. Without this hook a native-engine failure is
  /// invisible to the app's diagnostics: callers see `StateError('engine
  /// isolate died')` with the actual cause discarded. The app passes a callback
  /// that writes to its crash log; the package itself stays Flutter-free.
  ///
  /// Never called for a clean exit, and never throws into the caller (a
  /// throwing observer is swallowed).
  final void Function(Object error, StackTrace? stack)? _onIsolateError;

  EngineService._(this._isolate, this._worker, this._fromWorker,
      this._onIsolateError) {
    _fromWorker.listen(_onReply);
  }

  /// Spawns the worker isolate and opens the engine inside it. Completes only
  /// after the worker confirms a successful [Engine.open]; throws
  /// [StateError] (with the worker's message) if init fails — e.g. a bad
  /// [netsPath].
  /// [onIsolateError] observes uncaught worker-isolate errors — including the
  /// ones that kill the isolate during startup. See [_onIsolateError].
  static Future<EngineService> spawn({
    String? libraryPath,
    required String netsPath,
    void Function(Object error, StackTrace? stack)? onIsolateError,
  }) async {
    final handshake = ReceivePort();
    final errors = ReceivePort();

    final ready = Completer<SendPort>();

    // The handshake carries ('ready', workerPort) or ('init_error', message).
    // A crash before the worker can send anything surfaces on the error port
    // instead; both feed the single `ready` completer so spawn() never hangs
    // and never leaves a dangling unhandled async error.
    late final StreamSubscription<dynamic> handshakeSub;
    late final StreamSubscription<dynamic> errorSub;
    handshakeSub = handshake.listen((msg) {
      final list = msg as List;
      if (list[0] == 'ready') {
        if (!ready.isCompleted) ready.complete(list[1] as SendPort);
      } else {
        if (!ready.isCompleted) {
          ready.completeError(StateError(list[1] as String));
        }
      }
    });
    errorSub = errors.listen((err) {
      _reportIsolateError(onIsolateError, err);
      if (!ready.isCompleted) {
        final message = (err is List && err.isNotEmpty) ? err[0] : err;
        ready.completeError(
            StateError('engine isolate failed to start: $message'));
      }
    });

    final isolate = await Isolate.spawn(
      _workerMain,
      [handshake.sendPort, libraryPath, netsPath],
      errorsAreFatal: true,
      onError: errors.sendPort,
    );

    try {
      final workerPort = await ready.future;
      // Handshake done. Tear down the transient ports; the persistent
      // `fromWorker` port carries replies from here on.
      await handshakeSub.cancel();
      await errorSub.cancel();
      handshake.close();
      errors.close();

      final fromWorker = ReceivePort();
      workerPort.send(['bind', fromWorker.sendPort]);

      final service =
          EngineService._(isolate, workerPort, fromWorker, onIsolateError);
      final death = ReceivePort();
      isolate.addErrorListener(death.sendPort);
      isolate.addOnExitListener(death.sendPort);
      death.listen((msg) => service._onDeath(msg));
      service._deathPort = death;
      return service;
    } catch (e) {
      // Clean up on init failure so we leak neither ports nor the isolate.
      await handshakeSub.cancel();
      await errorSub.cancel();
      handshake.close();
      errors.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  ReceivePort? _deathPort;

  void _onReply(Object? message) {
    final list = message as List;
    final id = list[0] as int;
    final status = list[1] as String;
    final completer = _pending.remove(id);
    if (completer == null) return; // disposed / already settled
    if (status == 'ok') {
      completer.complete(list[2]);
    } else {
      completer.completeError(StateError(list[2] as String));
    }
  }

  void _onDeath(Object? message) {
    // The one port carries both listeners: an ERROR arrives as
    // [errorString, stackString?], a clean exit as the exit-response (null).
    // Only the former is worth reporting.
    _reportIsolateError(_onIsolateError, message);
    if (_dead) return;
    _dead = true;
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final c in pending) {
      c.completeError(StateError('engine isolate died'));
    }
    _fromWorker.close();
    _deathPort?.close();
  }

  Future<Object?> _call(String verb, Map<String, Object?> payload) {
    if (_dead) {
      throw StateError('EngineService disposed');
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _worker.send([id, verb, payload]);
    return completer.future;
  }

  /// Evaluates [board] from [mover]'s perspective. See [Engine.evaluate].
  Future<Probabilities> evaluate(BoardState board, Player mover) async {
    final r = await _call('evaluate', {
      'board': _encodeBoard(board),
      'mover': _encodePlayer(mover),
    });
    return _decodeProbs(r as List);
  }

  /// The engine's best move for [dice]. See [Engine.bestMove].
  Future<Move> bestMove(BoardState board, Player mover, Dice dice,
      {int xAway = 0, int oAway = 0}) async {
    final r = await _call('bestMove', {
      'board': _encodeBoard(board),
      'mover': _encodePlayer(mover),
      'dice': _encodeDice(dice),
      'xAway': xAway,
      'oAway': oAway,
    });
    return _decodeMove(r as List);
  }

  /// Every legal move scored, best-first. See [Engine.rankMoves].
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    final r = await _call('rankMoves', {
      'board': _encodeBoard(board),
      'mover': _encodePlayer(mover),
      'dice': _encodeDice(dice),
    });
    return _decodeScoredMoves(r as List);
  }

  /// Cube advice for the position. See [Engine.cubeInfo].
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async {
    final r = await _call('cubeInfo', {
      'board': _encodeBoard(board),
      'mover': _encodePlayer(mover),
    });
    return _decodeCube(r as List);
  }

  /// Shuts the service down. Idempotent. Sequence: the 'dispose' message is
  /// queued to the worker, then the isolate is killed with
  /// [Isolate.beforeNextEvent] — which lets the already-queued 'dispose'
  /// message run first, so the worker frees the native Wildbg handle and
  /// closes its port before the isolate is reaped. (An immediate kill would
  /// preempt that message and leak one native engine per dispose/re-spawn
  /// cycle.) All in-flight requests error with
  /// `StateError('EngineService disposed')`; subsequent verb calls throw
  /// synchronously.
  void dispose() {
    if (_dead) return;
    _dead = true;
    try {
      _worker.send(['dispose']);
    } catch (_) {
      // Worker port may already be dead; the kill below still cleans up.
    }
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _fromWorker.close();
    _deathPort?.close();
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final c in pending) {
      c.completeError(StateError('EngineService disposed'));
    }
  }

  // --- Worker isolate entry point -----------------------------------------

  static void _workerMain(List<Object?> args) {
    final handshake = args[0] as SendPort;
    final libraryPath = args[1] as String?;
    final netsPath = args[2] as String;

    final Engine engine;
    try {
      engine = Engine.open(libraryPath: libraryPath, netsPath: netsPath);
    } catch (e) {
      handshake.send(['init_error', e.toString()]);
      return;
    }

    final commands = ReceivePort();
    handshake.send(['ready', commands.sendPort]);

    SendPort? reply;
    commands.listen((message) {
      final list = message as List;
      final head = list[0];

      if (head == 'bind') {
        reply = list[1] as SendPort;
        return;
      }
      if (head == 'dispose') {
        commands.close();
        engine.dispose();
        return;
      }

      // Normal request: [id, verb, payload].
      final id = head as int;
      final verb = list[1] as String;
      final payload = list[2] as Map<String, Object?>;
      final out = reply;
      // Unreachable today: spawn() always sends 'bind' before any verb, so
      // `reply` is set by the time a request arrives. Guarded anyway — a
      // future refactor that emitted a verb pre-bind would otherwise drop the
      // request silently and hang the caller's completer forever.
      if (out == null) return;
      try {
        final result = _dispatch(engine, verb, payload);
        out.send([id, 'ok', result]);
      } catch (e) {
        out.send([id, 'err', e.toString()]);
      }
    });
  }

  static Object? _dispatch(
      Engine engine, String verb, Map<String, Object?> payload) {
    switch (verb) {
      case 'evaluate':
        final probs = engine.evaluate(
          _decodeBoard(payload['board'] as Map),
          _decodePlayer(payload['mover']),
        );
        return _encodeProbs(probs);
      case 'bestMove':
        final move = engine.bestMove(
          _decodeBoard(payload['board'] as Map),
          _decodePlayer(payload['mover']),
          _decodeDice(payload['dice'] as List),
          xAway: payload['xAway'] as int,
          oAway: payload['oAway'] as int,
        );
        return _encodeMove(move);
      case 'rankMoves':
        final ranked = engine.rankMoves(
          _decodeBoard(payload['board'] as Map),
          _decodePlayer(payload['mover']),
          _decodeDice(payload['dice'] as List),
        );
        return _encodeScoredMoves(ranked);
      case 'cubeInfo':
        final advice = engine.cubeInfo(
          _decodeBoard(payload['board'] as Map),
          _decodePlayer(payload['mover']),
        );
        return _encodeCube(advice);
      default:
        throw StateError('unknown verb "$verb"');
    }
  }
}

/// Hands a decoded isolate error to [observer], if there is one and if the
/// message really is an error (see [decodeIsolateError] — the same port also
/// carries the clean-exit signal). A throwing observer is swallowed: this runs
/// on the crash path, where a second failure helps nobody.
void _reportIsolateError(
    void Function(Object error, StackTrace? stack)? observer, Object? message) {
  if (observer == null) return;
  final decoded = decodeIsolateError(message);
  if (decoded == null) return;
  try {
    observer(decoded.error, decoded.stack);
  } catch (_) {
    // An observer that throws must not compound the failure it was told about.
  }
}

// --- Wire encoding: primitives only, no object sends across the port. -------
// Kept next to the class so the request/reply shape stays obvious.

Map<String, Object?> _encodeBoard(BoardState b) => {
      'points': List<int>.of(b.points),
      'wb': b.whiteBar,
      'bb': b.blackBar,
      'wo': b.whiteOff,
      'bo': b.blackOff,
    };

BoardState _decodeBoard(Map board) => BoardState(
      points: List<int>.from(board['points'] as List),
      whiteBar: board['wb'] as int,
      blackBar: board['bb'] as int,
      whiteOff: board['wo'] as int,
      blackOff: board['bo'] as int,
    );

bool _encodePlayer(Player p) => p == Player.white;
Player _decodePlayer(Object? v) =>
    (v as bool) ? Player.white : Player.black;

List<int> _encodeDice(Dice d) => [d.die1, d.die2];
Dice _decodeDice(List d) => Dice(d[0] as int, d[1] as int);

List<double> _encodeProbs(Probabilities p) => [
      p.win,
      p.winGammon,
      p.winBackgammon,
      p.loseGammon,
      p.loseBackgammon,
    ];

Probabilities _decodeProbs(List p) => Probabilities(
      win: p[0] as double,
      winGammon: p[1] as double,
      winBackgammon: p[2] as double,
      loseGammon: p[3] as double,
      loseBackgammon: p[4] as double,
    );

List<List<Object>> _encodeMove(Move m) => [
      for (final c in m.checkerMoves) [c.from, c.to, c.isHit],
    ];

Move _decodeMove(List triples) => Move([
      for (final t in triples)
        CheckerMove(
          (t as List)[0] as int,
          t[1] as int,
          isHit: t[2] as bool,
        ),
    ]);

List<List<Object>> _encodeScoredMoves(List<ScoredMove> moves) => [
      for (final s in moves)
        [_encodeMove(s.move), _encodeProbs(s.probabilities)],
    ];

List<ScoredMove> _decodeScoredMoves(List raw) => [
      for (final s in raw)
        ScoredMove(
          move: _decodeMove((s as List)[0] as List),
          probabilities: _decodeProbs(s[1] as List),
        ),
    ];

List<Object> _encodeCube(CubeAdvice c) => [
      c.shouldDouble,
      c.shouldAccept,
      c.equityCubeless,
      c.equityNoDouble,
      c.equityDoubleTake,
    ];

CubeAdvice _decodeCube(List c) => CubeAdvice(
      shouldDouble: c[0] as bool,
      shouldAccept: c[1] as bool,
      equityCubeless: c[2] as double,
      equityNoDouble: c[3] as double,
      equityDoubleTake: c[4] as double,
    );
