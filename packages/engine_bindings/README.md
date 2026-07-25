# engine_bindings

Dart FFI bindings and an isolate-hosted `EngineService` over the wildbg-based
`aigammon_engine` native library. The package loads a thin C shim
(`native/engine_shim`, a verbatim copy of wildbg's `wildbg-c` crate plus one
added `wildbg_new_with_path` constructor) via `dart:ffi`, wraps it in a
synchronous `Engine` facade, and exposes an async `EngineService` that runs all
neural-net inference in a dedicated isolate so it never blocks the caller (the
app's UI thread). Move ranking, best-move selection, cubeless win/gammon/bg
probabilities, and Janowski doubling-cube advice all come straight from wildbg's
tract-onnx evaluator loaded with the production nets vendored under `native/`.

## Building the native library

### Windows DLL

```powershell
native/engine_shim/build-windows.ps1
```

This runs `cargo build --release` in the shim crate and copies
`aigammon_engine.dll` to `packages/engine_bindings/native/windows/`.

**Toolchain:** the default Rust toolchain here is `stable-x86_64-pc-windows-gnu`.
Rust alone is not sufficient — its self-contained MinGW ships `dlltool`/`ld`/a
linker-only `gcc` but **no GNU assembler (`as.exe`)**, so `dlltool` fails while
building import libraries (first hit in the `getrandom` crate). A full
**MinGW-w64** must be on `PATH` (this machine uses WinLibs, winget
`BrechtSanders.WinLibs.POSIX.UCRT`, GCC 16.1.0). See `native/README.md` for the
full toolchain note.

### Mobile (deferred verification)

Two scripts stage mobile artifacts into `packages/engine_bindings/native/`:

| Platform | Script | Status |
|---|---|---|
| Android (`arm64-v8a`, `armeabi-v7a`, `x86_64`) | `native/engine_shim/build-android.ps1` | **Authored — verification deferred.** Android is verified in Plan 3 once the NDK lands. Needs `cargo install cargo-ndk`, the three Android rustup targets, and `$env:ANDROID_NDK_HOME`. Stages `.so` files into `native/android/jniLibs`. |
| iOS (device + simulator XCFramework) | `native/engine_shim/build-ios.sh` | **Authored — verification deferred to CI/macOS.** macOS only. Needs Xcode CLT and the two `aarch64-apple-ios` / `-sim` rustup targets. Builds `aigammon_engine.xcframework` into `native/ios`. |

Inference is tract-onnx (pure Rust), so mobile builds carry **no ONNX Runtime
binaries** — the engine is a single self-contained static/shared library per ABI.

## Library resolution

The load *strategy* is picked per platform by `libraryLoadStrategyFor` (pure,
unit-tested) in `lib/src/ffi/library_loader.dart`:

- **Windows / Linux / Android** → `DynamicLibrary.open(path)`, where `path` comes
  from `WildbgFfi.defaultLibraryPath()` (below). The engine is a separate
  `.dll` / `.so`.
- **iOS / macOS** → `DynamicLibrary.process()`. The Rust staticlib
  `libaigammon_engine.a` is `-force_load`ed into the host binary (see
  `app/ios/Flutter/*.xcconfig` and the "iOS" section of `native/README.md`), so
  there is no file to open — the shim symbols already live in the process, and
  the resolved path is ignored.

`WildbgFfi.defaultLibraryPath()` (in `lib/src/ffi/wildbg_ffi.dart`) supplies the
`open` path, resolved in this order; the first candidate that exists on disk wins:

1. The `$WILDBG_LIB_PATH` environment variable, if set and non-empty — used
   verbatim (the override for staging/CI or a hand-placed build).
2. `native/<os>/<libname>` relative to the current directory — the case when
   tests/tools run from the package directory.
3. `packages/engine_bindings/native/<os>/<libname>` relative to the current
   directory — the case when running from the repo root.

`<os>/<libname>` is `windows/aigammon_engine.dll`, `macos/libaigammon_engine.dylib`,
or `linux/libaigammon_engine.so`. If none of the candidates exist, candidate 2 is
returned so `DynamicLibrary.open` surfaces a clear "file not found" error.

## The nets contract

`Engine.open` / `EngineService.spawn` take a required `netsPath`: a **directory
that contains `contact.onnx` and `race.onnx` directly** (not inside a
`neural-nets/` subdirectory). In this repo that directory is
`native/wildbg-nets/neural-nets`. The shim's `wildbg_new_with_path` appends
`/contact.onnx` and `/race.onnx` to the path you pass and loads them at runtime
via `CompositeEvaluator::from_file_paths_optimized`. A bad path makes the
constructor return `NULL`, which surfaces as a `StateError`.

**The `wildbg_new()` trap:** wildbg's default constructor `wildbg_new()`
`include_bytes!`-bakes the submodule's **weak demo nets** into the binary at
compile time (`native/wildbg/neural-nets/`, ~126 KB contact vs. the ~752 KB
production net). This package therefore **never** calls `wildbg_new()` — the FFI
layer only binds `wildbg_new_with_path`, so the strong production nets are always
loaded from disk at runtime.

## Running tests

- `dart test` — the default suite (11 tests): pure-logic tests (codec,
  difficulty sampling, service wiring) that need **no** native library or nets.
- `dart test -P engine` — the `engine` profile (16 tests): end-to-end tests that
  load the real DLL and production nets. Requires the Windows DLL built
  (`build-windows.ps1`) and the vendored nets present under `native/`.

## Public API

Exported from `package:engine_bindings/engine_bindings.dart`:

- **`Engine`** (`src/engine.dart`) — synchronous, blocking facade over the FFI.
  `Engine.open({libraryPath, required netsPath})`; `evaluate`, `bestMove`,
  `rankMoves`, `cubeInfo`, `dispose`. Not thread-safe (one reused pip buffer per
  instance); use from a single isolate.
- **`EngineService`** (`src/engine_service.dart`) — async facade hosting an
  `Engine` in a dedicated isolate so inference never blocks the caller.
  `EngineService.spawn({libraryPath, required netsPath})` returns a `Future`;
  mirrors the `Engine` methods (`evaluate`/`bestMove`/`rankMoves`/`cubeInfo`) as
  `Future`s matched by request id, plus `dispose`. Ownership note: if the isolate
  dies, all pending calls error and the service is dead — the app layer supervises
  and re-spawns.
- **`rankMoves`** — 0-ply ranking: every legal move is evaluated by scoring the
  resulting position from the opponent's perspective and inverting, sorted
  best-first as `List<ScoredMove>`.
- **`CubeAdvice`** (`src/scored_move.dart`) — wildbg's Janowski-formula cube
  advice: `shouldDouble` (includes too-good-to-double logic in wildbg's
  `CubeInfo`), `shouldAccept`, and the `equityCubeless` / `equityNoDouble` /
  `equityDoubleTake` equities.
- **`pickMove` / `Difficulty`** (`src/difficulty.dart`) — one engine serves all
  strengths. `Difficulty.expert` always plays the top-ranked move; `easy`,
  `medium`, `hard` sample among moves within an `equityWindow` of the best,
  weighted by `exp(-equityLoss / temperature)`.
- **Position codec** (`src/position_codec.dart`) — `encodePips` maps a
  `BoardState` to wildbg's 26-int pip array from the mover's perspective
  (index 0 = opponent bar, 1-24 = pips moving 24→1, index 25 = mover bar);
  `decodeDetail` maps a wildbg move detail back to a real-coordinate
  `CheckerMove`.
- **`Probabilities` / `ScoredMove`** (`src/scored_move.dart`) — cumulative
  wildbg semantics (`win` includes gammon+bg wins; `winGammon` includes bg wins),
  with cubeless `equity` in [-3, 3] and an `inverted` view.

## Licensing

The native library is built from the vendored **wildbg** engine, dual-licensed
**MIT OR Apache-2.0**. wildbg is pinned as a git submodule at the SHA recorded in
`native/README.md` (currently `24d26fe`, the Janowski doubling-cube commit). The
`engine_shim` crate is a verbatim copy of wildbg's `wildbg-c` source plus the
added runtime-net constructor and inherits the same dual license.
