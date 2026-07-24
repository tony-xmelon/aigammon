import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// dart:ffi struct/function bindings for the native `aigammon_engine` library
/// (a thin C shim over wildbg). Internal to the package — not exported from the
/// barrel. Use the high-level [Engine] facade instead.

// ---------------------------------------------------------------------------
// Structs (layout mirrors native/engine_shim/src/lib.rs, all #[repr(C)]).
// ---------------------------------------------------------------------------

/// `CProbabilities` — cumulative wildbg win/gammon/bg probabilities.
final class CProbabilities extends Struct {
  @Float()
  external double win;
  @Float()
  external double winG;
  @Float()
  external double winBg;
  @Float()
  external double loseG;
  @Float()
  external double loseBg;
}

/// `CMoveDetail` — one hop; {from,to} = {-1,-1} for unused slots.
/// from ∈ 1-25 (25 = bar), to ∈ 0-24 (0 = off).
final class CMoveDetail extends Struct {
  @Int32()
  external int from;
  @Int32()
  external int to;
}

/// `CMove` — up to four hops plus a count (0 = no legal move).
final class CMove extends Struct {
  @Array(4)
  external Array<CMoveDetail> details;
  @Int32()
  external int detailCount;
}

/// `BgConfig` — match score context; 0/0 = money game.
final class BgConfig extends Struct {
  @Uint32()
  external int xAway;
  @Uint32()
  external int oAway;
}

/// `CCubeInfo` — cube advice + Janowski equities. The two bools sit at offsets
/// 0/1 with 2 bytes of padding before the floats at offsets 4/8/12; Dart's
/// Struct inserts that padding automatically from the field order + alignment.
final class CCubeInfo extends Struct {
  @Bool()
  external bool shouldDouble;
  @Bool()
  external bool shouldAccept;
  @Float()
  external double equityCubeless;
  @Float()
  external double equityNoDouble;
  @Float()
  external double equityDoubleTake;
}

// ---------------------------------------------------------------------------
// Native function signatures.
// ---------------------------------------------------------------------------

typedef _WildbgNewWithPathNative = Pointer<Void> Function(Pointer<Utf8>);
typedef WildbgNewWithPathDart = Pointer<Void> Function(Pointer<Utf8>);

typedef _WildbgFreeNative = Void Function(Pointer<Void>);
typedef WildbgFreeDart = void Function(Pointer<Void>);

typedef _ProbabilitiesNative = CProbabilities Function(
    Pointer<Void>, Pointer<Int32>);
typedef ProbabilitiesDart = CProbabilities Function(
    Pointer<Void>, Pointer<Int32>);

typedef _BestMoveNative = CMove Function(
    Pointer<Void>, Pointer<Int32>, Uint32, Uint32, Pointer<BgConfig>);
typedef BestMoveDart = CMove Function(
    Pointer<Void>, Pointer<Int32>, int, int, Pointer<BgConfig>);

typedef _CubeInfoNative = CCubeInfo Function(Pointer<Void>, Pointer<Int32>);
typedef CubeInfoDart = CCubeInfo Function(Pointer<Void>, Pointer<Int32>);

/// Loads and exposes the native `aigammon_engine` exports.
class WildbgFfi {
  final DynamicLibrary _lib;

  late final WildbgNewWithPathDart wildbgNewWithPath;
  late final WildbgFreeDart wildbgFree;
  late final ProbabilitiesDart probabilities;
  late final BestMoveDart bestMove;
  late final CubeInfoDart cubeInfo;

  WildbgFfi(String libraryPath) : _lib = DynamicLibrary.open(libraryPath) {
    wildbgNewWithPath =
        _lib.lookupFunction<_WildbgNewWithPathNative, WildbgNewWithPathDart>(
            'wildbg_new_with_path');
    wildbgFree = _lib
        .lookupFunction<_WildbgFreeNative, WildbgFreeDart>('wildbg_free');
    probabilities =
        _lib.lookupFunction<_ProbabilitiesNative, ProbabilitiesDart>(
            'probabilities');
    bestMove =
        _lib.lookupFunction<_BestMoveNative, BestMoveDart>('best_move');
    cubeInfo =
        _lib.lookupFunction<_CubeInfoNative, CubeInfoDart>('cube_info');
  }

  /// Resolves the native library path.
  ///
  /// Resolution order:
  ///  1. The `$WILDBG_LIB_PATH` environment variable, if set (used verbatim).
  ///  2. `native/<os>/<libname>` relative to [Directory.current] — the case
  ///     when tests/tools run from the package directory.
  ///  3. `packages/engine_bindings/native/<os>/<libname>` relative to
  ///     [Directory.current] — the case when running from the repo root.
  ///
  /// The first candidate that exists on disk wins; if none exist, candidate 2
  /// is returned so [DynamicLibrary.open] surfaces a clear error.
  static String defaultLibraryPath() {
    final override = Platform.environment['WILDBG_LIB_PATH'];
    if (override != null && override.isNotEmpty) return override;

    final String osDir;
    final String libName;
    if (Platform.isWindows) {
      osDir = 'windows';
      libName = 'aigammon_engine.dll';
    } else if (Platform.isMacOS) {
      osDir = 'macos';
      libName = 'libaigammon_engine.dylib';
    } else {
      osDir = 'linux';
      libName = 'libaigammon_engine.so';
    }

    final relative = 'native/$osDir/$libName';
    final candidates = <String>[
      relative,
      'packages/engine_bindings/$relative',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return candidates.first;
  }
}
