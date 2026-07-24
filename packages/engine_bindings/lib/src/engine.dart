import 'dart:ffi';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:ffi/ffi.dart';

import 'ffi/wildbg_ffi.dart';
import 'position_codec.dart';
import 'scored_move.dart';

/// Synchronous engine facade over the native wildbg library. Blocking —
/// wrap in EngineService (next task) for UI use.
///
/// NOT thread-safe: a single reused pips buffer is shared across calls, so a
/// single [Engine] instance must only be used from one isolate at a time.
class Engine {
  final WildbgFfi _ffi;
  Pointer<Void> _handle;
  bool _disposed = false;

  /// Reused 26-int scratch buffer for pip encoding. The class is explicitly
  /// single-threaded, so one buffer per instance is safe.
  final Pointer<Int32> _pips = calloc<Int32>(26);

  Engine._(this._ffi, this._handle);

  /// Opens the library and initializes with nets from [netsPath] (a
  /// directory containing contact.onnx and race.onnx). Throws StateError
  /// if the engine returns NULL (bad nets path is the usual cause).
  factory Engine.open({String? libraryPath, required String netsPath}) {
    final ffi = WildbgFfi(libraryPath ?? WildbgFfi.defaultLibraryPath());
    final pathPtr = netsPath.toNativeUtf8();
    try {
      final handle = ffi.wildbgNewWithPath(pathPtr);
      if (handle == nullptr) {
        throw StateError(
            'wildbg_new_with_path returned NULL for nets path "$netsPath" '
            '(directory must contain contact.onnx and race.onnx).');
      }
      return Engine._(ffi, handle);
    } finally {
      calloc.free(pathPtr);
    }
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('Engine has been disposed.');
    }
  }

  /// Loads [board] from [mover]'s perspective into the reused pips buffer.
  void _loadPips(BoardState board, Player mover) {
    final encoded = encodePips(board, mover);
    for (var i = 0; i < 26; i++) {
      _pips[i] = encoded[i];
    }
  }

  /// Cubeless win/gammon/backgammon probabilities for [mover] in [board].
  Probabilities evaluate(BoardState board, Player mover) {
    _checkAlive();
    _loadPips(board, mover);
    final c = _ffi.probabilities(_handle, _pips);
    return Probabilities(
      win: c.win,
      winGammon: c.winG,
      winBackgammon: c.winBg,
      loseGammon: c.loseG,
      loseBackgammon: c.loseBg,
    );
  }

  /// Engine's best move in real coordinates; Move.none when detail_count==0.
  Move bestMove(BoardState board, Player mover, Dice dice,
      {int xAway = 0, int oAway = 0}) {
    _checkAlive();
    _loadPips(board, mover);
    final config = calloc<BgConfig>();
    config.ref.xAway = xAway;
    config.ref.oAway = oAway;
    try {
      final cMove =
          _ffi.bestMove(_handle, _pips, dice.die1, dice.die2, config);
      final count = cMove.detailCount;
      if (count == 0) return Move.none;
      final moves = <CheckerMove>[
        for (var i = 0; i < count; i++)
          decodeDetail(cMove.details[i].from, cMove.details[i].to, mover),
      ];
      return Move(moves);
    } finally {
      calloc.free(config);
    }
  }

  /// Every legal move scored by evaluating the resulting position from the
  /// opponent's perspective and inverting; sorted best-first.
  List<ScoredMove> rankMoves(BoardState board, Player mover, Dice dice) {
    _checkAlive();
    final legal = MoveGenerator.legalMoves(board, mover, dice);
    final scored = [
      for (final move in legal)
        ScoredMove(
          move: move,
          probabilities:
              evaluate(board.applyMove(mover, move), mover.opponent).inverted,
        ),
    ]..sort((a, b) => b.equity.compareTo(a.equity));
    return scored;
  }

  CubeAdvice cubeInfo(BoardState board, Player mover) {
    _checkAlive();
    _loadPips(board, mover);
    final c = _ffi.cubeInfo(_handle, _pips);
    return CubeAdvice(
      shouldDouble: c.shouldDouble,
      shouldAccept: c.shouldAccept,
      equityCubeless: c.equityCubeless,
      equityNoDouble: c.equityNoDouble,
      equityDoubleTake: c.equityDoubleTake,
    );
  }

  /// Frees the native handle and scratch buffer. Idempotent; any further
  /// evaluation call throws StateError.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi.wildbgFree(_handle);
    _handle = nullptr;
    calloc.free(_pips);
  }
}
