# AIGammon

Cross-platform backgammon built with **Flutter** and driven by a neural-net
engine ([wildbg](https://github.com/carsten-wenderdel/wildbg), vendored, dual
**MIT OR Apache-2.0**).

**Available now (local play):**

- **Play vs computer** at four difficulties (`easy`, `medium`, `hard`,
  `expert`). One engine serves every level: `expert` always plays the
  top-ranked move; lower levels sample among near-best moves with increasing
  randomness.
- **Hot-seat** — two humans on the same device, with a pass-device prompt
  between turns.
- **Match play** to N points with the **doubling cube** (Janowski cube advice
  from the engine), gammon/backgammon scoring, and the **Crawford** rule.

**Coming next:** tutor mode (per-move equity-loss analysis and hints) and online
play over Firebase land in Plans 4 and 5 — see
[`docs/superpowers/plans/`](docs/superpowers/plans/) and the
[architecture design](docs/superpowers/specs/2026-07-24-aigammon-architecture-design.md).

## Repository layout

| Path | What it is |
|---|---|
| [`app/`](app/) | The Flutter app — UI (`CustomPaint` board), Riverpod state, `GameController`, screens (home, new match, game). |
| [`packages/backgammon_core`](packages/backgammon_core) | Pure Dart rules engine — zero dependencies. `BoardState`, `GameState`, `MatchState`, move generation, event-sourced game log, gnubg Position IDs. **107 tests.** |
| [`packages/engine_bindings`](packages/engine_bindings) | `dart:ffi` bindings + an isolate-hosted `EngineService` over the native library: move ranking, evaluation, difficulty sampling, Janowski cube advice. |
| [`native/wildbg`](native/wildbg) | The vendored [wildbg](https://github.com/carsten-wenderdel/wildbg) engine — a **git submodule**, never edited directly. |
| [`native/engine_shim`](native/engine_shim) | Thin C shim (`cdylib`, `aigammon_engine`) — a verbatim copy of wildbg's `wildbg-c` crate plus a `wildbg_new_with_path` constructor that loads nets from disk at runtime. Windows/Android/iOS build scripts live here. |
| [`native/wildbg-nets`](native/wildbg-nets) | The **production** neural nets (`contact.onnx`, `race.onnx`) from wildbg's `nets` branch. The submodule itself ships only weak demo nets. |
| [`docs/superpowers/`](docs/superpowers/) | Architecture spec and the per-phase implementation plans. |
| [`.github/workflows/`](.github/workflows/) | CI (`ci.yml`) and the Android APK / Firebase distribution workflow (`android.yml`). |

See [`native/README.md`](native/README.md) and
[`packages/engine_bindings/README.md`](packages/engine_bindings/README.md) for
the engine, net-loading, and licensing details.

## Getting started (Windows dev)

### 1. Clone with submodules

```powershell
git clone --recurse-submodules https://github.com/tony-xmelon/aigammon
# already cloned without --recurse-submodules?
git submodule update --init --recursive
```

### 2. Toolchain

- **Flutter** (stable channel) with Windows desktop support enabled. Desktop
  builds require **Developer Mode** turned on (Settings → For developers) so
  Flutter can create the symlinks its plugins need.
- **Rust**, `stable-x86_64-pc-windows-gnu` toolchain.
- A **full MinGW-w64** on `PATH` — Rust's self-contained MinGW ships no GNU
  assembler (`as.exe`), so `dlltool` fails when building the engine. This
  machine uses [WinLibs](https://winlibs.com/) (winget
  `BrechtSanders.WinLibs.POSIX.UCRT`). See
  [`native/README.md`](native/README.md) for the full toolchain note. (An MSVC
  Build Tools install with the `-msvc` target is an alternative.)

### 3. Build the engine DLL

```powershell
native/engine_shim/build-windows.ps1
```

This runs `cargo build --release` in the shim crate and stages
`aigammon_engine.dll` into `packages/engine_bindings/native/windows/`.

### 4. Run the tests

```powershell
# Pure Dart rules (107 tests)
cd packages/backgammon_core; dart pub get; dart test

# FFI bindings — unit suite (no native lib) then the engine profile (real DLL + nets)
cd packages/engine_bindings; dart pub get; dart test; dart test -P engine

# Flutter app — widget/unit tests, then desktop integration test (real engine)
cd app; flutter pub get; flutter test
flutter test integration_test -d windows
```

### 5. Run the app

```powershell
cd app
flutter run -d windows
```

## Continuous integration

- **`ci.yml`** (push to `master`, all PRs, Linux): runs the three test suites —
  `backgammon_core` (`dart analyze --fatal-infos` + `dart test`),
  `engine_bindings` (builds the Rust cdylib, then `dart test` + `dart test -P
  engine` against the real `.so`), and the Flutter app (`flutter analyze` +
  `flutter test`).
- **`android.yml`** (`workflow_dispatch`, push to `master`): cross-compiles the
  engine for the Android ABIs with `cargo-ndk`, builds a release APK, and — when
  the Firebase secrets are configured — distributes it to testers via Firebase
  App Distribution. Setup instructions:
  [`.github/workflows/README.md`](.github/workflows/README.md).

## Licensing

The vendored **wildbg** engine (and the `engine_shim` copy of its `wildbg-c`
crate) is dual-licensed **MIT OR Apache-2.0**; **this repository's own license is
not yet chosen — TODO for the owner.**
