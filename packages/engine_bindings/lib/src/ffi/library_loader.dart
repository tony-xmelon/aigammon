import 'dart:ffi';
import 'dart:io';

/// How the native `aigammon_engine` symbols are located at runtime.
enum LibraryLoadStrategy {
  /// Open a shared library from a filesystem path (`DynamicLibrary.open`).
  ///
  /// Used on Windows, Linux and Android, where the engine ships as a separate
  /// `.dll` / `.so` file resolved by `WildbgFfi.defaultLibraryPath` (which
  /// honours the `$WILDBG_LIB_PATH` override, then repo-relative candidates).
  open,

  /// Resolve symbols already linked into the running process
  /// (`DynamicLibrary.process`).
  ///
  /// Used on iOS (and macOS), where the Rust staticlib `libaigammon_engine.a`
  /// is `-force_load`ed into the Runner binary at link time (see
  /// `app/ios/Flutter/{Debug,Release}.xcconfig`). There is no separate library
  /// file to open — the shim's exported symbols live in the app binary itself.
  process,
}

/// Selects the load strategy from platform flags.
///
/// Pure function: the caller injects the platform booleans, so the decision is
/// unit-testable without touching real FFI. iOS and macOS statically link the
/// engine into the host binary and therefore resolve symbols from the process;
/// every other platform loads a shared library from disk by path.
LibraryLoadStrategy libraryLoadStrategyFor({
  required bool isIOS,
  required bool isMacOS,
}) =>
    (isIOS || isMacOS) ? LibraryLoadStrategy.process : LibraryLoadStrategy.open;

/// Loads the native `aigammon_engine` library for the current platform.
///
/// Applies [libraryLoadStrategyFor] to the real [Platform] flags:
///  - [LibraryLoadStrategy.open] → `DynamicLibrary.open(libraryPath)` (desktop
///    dev + Android; [libraryPath] is the resolved `.dll`/`.so` path).
///  - [LibraryLoadStrategy.process] → `DynamicLibrary.process()` (iOS/macOS;
///    [libraryPath] is ignored — symbols are already in the process).
DynamicLibrary loadEngineLibrary(String libraryPath) {
  final strategy = libraryLoadStrategyFor(
    isIOS: Platform.isIOS,
    isMacOS: Platform.isMacOS,
  );
  switch (strategy) {
    case LibraryLoadStrategy.open:
      return DynamicLibrary.open(libraryPath);
    case LibraryLoadStrategy.process:
      return DynamicLibrary.process();
  }
}
