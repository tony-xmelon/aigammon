import 'dart:async';
import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../game/player_agent.dart';
import 'nets_installer.dart';

/// The engine verbs [EngineManager] supervises, narrowed to an interface.
///
/// [EngineService] is a concrete class with a private constructor and needs
/// native code to instantiate, so it cannot be faked directly. This interface
/// is the seam: the default spawner wraps a real [EngineService] in an adapter
/// ([_EngineServiceApi]) that satisfies [EngineApi], and tests inject a fake
/// implementation via [EngineManager]'s `spawner`. Mirrors [EngineService]'s
/// verb signatures so the adapter is a pass-through.
abstract interface class EngineApi {
  Future<Probabilities> evaluate(BoardState board, Player mover);
  Future<Move> bestMove(BoardState board, Player mover, Dice dice,
      {int xAway, int oAway});
  Future<List<ScoredMove>> rankMoves(BoardState board, Player mover, Dice dice);
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover);
  void dispose();
}

/// Adapts a concrete [EngineService] to [EngineApi]. Pure pass-through.
class _EngineServiceApi implements EngineApi {
  _EngineServiceApi(this._service);
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

/// Owns the [EngineApi] (engine-isolate) lifecycle for the whole app.
///
/// The [EngineService] isolate can die (a native crash, OOM). When it does, its
/// verb calls throw `StateError('engine isolate died…')` and the service is
/// permanently dead — the OWNER must re-spawn. That owner is this manager:
/// callers go through [withEngine], which lazily spawns on first use and
/// transparently re-spawns once if a call fails because the isolate died.
///
/// Spawning is serialized: concurrent first-callers (or concurrent re-spawns)
/// share a single in-flight spawn future rather than racing two isolates.
class EngineManager {
  /// [spawner] builds a fresh engine; defaults to [_defaultSpawner] which wires
  /// a real [EngineService]. Tests inject a fake to exercise the lifecycle
  /// without native code.
  EngineManager({Future<EngineApi> Function()? spawner})
      : _spawner = spawner ?? _defaultSpawner;

  final Future<EngineApi> Function() _spawner;

  EngineApi? _engine;
  Future<EngineApi>? _spawning;
  bool _disposed = false;

  /// Runs [fn] with a live engine, spawning one on first use.
  ///
  /// If [fn] throws a `StateError` whose message contains `isolate died`, the
  /// dead engine is dropped, a new one is spawned ONCE, and [fn] is retried. A
  /// second death (or any other error) propagates to the caller. Retrying only
  /// on the death signal keeps genuine engine errors (bad input, unknown verb)
  /// visible instead of masking them behind a re-spawn loop.
  Future<T> withEngine<T>(Future<T> Function(EngineApi) fn) async {
    var engine = await _ensureEngine();
    try {
      return await fn(engine);
    } on StateError catch (e) {
      if (!_isIsolateDeath(e)) rethrow;
      // The isolate died mid-call. Drop it and re-spawn exactly once.
      _dropIfCurrent(engine);
      engine = await _ensureEngine();
      return await fn(engine);
    }
  }

  /// Returns the live engine, spawning (or awaiting an in-flight spawn) if
  /// needed. Serialized via [_spawning] so concurrent callers share one spawn.
  Future<EngineApi> _ensureEngine() {
    if (_disposed) {
      throw StateError('EngineManager has been disposed');
    }
    final existing = _engine;
    if (existing != null) return Future.value(existing);

    final inFlight = _spawning;
    if (inFlight != null) return inFlight;

    final spawn = _spawner().then((engine) {
      _spawning = null;
      // A dispose() that raced the spawn must not leave a live engine dangling.
      if (_disposed) {
        engine.dispose();
        throw StateError('EngineManager has been disposed');
      }
      _engine = engine;
      return engine;
    }, onError: (Object e, StackTrace s) {
      _spawning = null;
      throw e;
    });
    _spawning = spawn;
    return spawn;
  }

  /// Drops [engine] as the current one (disposing it) only if it is still the
  /// one we hold — guards against dropping a healthy re-spawned engine when two
  /// deaths interleave.
  void _dropIfCurrent(EngineApi engine) {
    if (identical(_engine, engine)) {
      _engine = null;
      engine.dispose();
    }
  }

  static bool _isIsolateDeath(StateError e) =>
      e.message.contains('isolate died');

  /// Disposes the live engine, if any. Idempotent. Any subsequent [withEngine]
  /// call throws.
  Future<void> disposeManager() async {
    if (_disposed) return;
    _disposed = true;
    // Await any in-flight spawn so we can dispose the engine it produces
    // instead of leaking it; the spawn's own _disposed check also handles this.
    final spawning = _spawning;
    if (spawning != null) {
      try {
        await spawning;
      } catch (_) {
        // Spawn failure is fine here — nothing to dispose.
      }
    }
    _engine?.dispose();
    _engine = null;
  }

  /// Builds a production engine: resolves the native library and nets paths,
  /// spawns an [EngineService] isolate, and adapts it to [EngineApi].
  static Future<EngineApi> _defaultSpawner() async {
    final netsPath = await NetsInstaller.ensureInstalled();
    final service = await EngineService.spawn(
      libraryPath: _resolveLibraryPath(),
      netsPath: netsPath,
    );
    return _EngineServiceApi(service);
  }

  /// Resolves the native shim's path.
  ///
  /// - Android: the bare `libaigammon_engine.so` name; the Android loader finds
  ///   it in the packaged jniLibs.
  /// - Desktop dev: the staged Windows DLL if found by walking up from
  ///   [Directory.current] (the repo has it under
  ///   `packages/engine_bindings/native/windows/`).
  /// - Otherwise: null, letting [EngineService]/[WildbgFfi] apply its own
  ///   default / env-var resolution.
  static String? _resolveLibraryPath() {
    if (Platform.isAndroid) return 'libaigammon_engine.so';
    return _findWindowsDll();
  }

  static const _windowsDllRelative =
      'packages/engine_bindings/native/windows/aigammon_engine.dll';

  static String? _findWindowsDll() {
    var dir = Directory.current;
    for (var i = 0; i <= 4; i++) {
      final candidate = File(p.join(dir.path, _windowsDllRelative));
      if (candidate.existsSync()) return candidate.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }
}

/// The app-wide engine manager. Its lifecycle is tied to the [ProviderScope];
/// disposing the scope disposes the live engine isolate.
final engineManagerProvider = Provider<EngineManager>((ref) {
  final manager = EngineManager();
  ref.onDispose(manager.disposeManager);
  return manager;
});

/// An [EngineFacade] (consumed by [AiAgent]) backed by [EngineManager], so AI
/// engine calls inherit the manager's transparent re-spawn-on-death behaviour.
class ManagedEngineFacade implements EngineFacade {
  ManagedEngineFacade(this._manager);
  final EngineManager _manager;

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) =>
      _manager.withEngine((e) => e.evaluate(board, mover));

  @override
  Future<List<ScoredMove>> rankMoves(
          BoardState board, Player mover, Dice dice) =>
      _manager.withEngine((e) => e.rankMoves(board, mover, dice));

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) =>
      _manager.withEngine((e) => e.cubeInfo(board, mover));
}

/// The [EngineFacade] for wiring an [AiAgent], backed by the managed engine.
final engineFacadeProvider = Provider<EngineFacade>((ref) {
  return ManagedEngineFacade(ref.watch(engineManagerProvider));
});
