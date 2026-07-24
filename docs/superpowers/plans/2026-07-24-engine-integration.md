# Engine Integration (wildbg via FFI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed the wildbg neural-net backgammon engine behind a typed async Dart API (`EngineService`) so the app can evaluate positions, rank moves for the AI opponent and tutor mode, and get cube advice — all offline.

**Architecture:** wildbg (Rust, MIT/Apache-2.0) is vendored as a git submodule. Our own small Rust `cdylib` crate (`aigammon_engine`) wraps wildbg's Rust API and exports a C ABI — mirroring wildbg's own `wildbg-c` crate but adding a path-based constructor (needed on mobile) and building a dynamic library (needed by `dart:ffi`). A new Dart package `packages/engine_bindings` holds the FFI structs/bindings, a position codec between `backgammon_core`'s board model and wildbg's 26-int pip array, a synchronous `Engine`, and an isolate-hosted `EngineService`. Move ranking is computed Dart-side (evaluate each legal move's resulting position; negate the opponent's equity) — this powers the AI, difficulty levels, and tutor with one primitive. Match-awareness comes from wildbg's `best_move` (`BgConfig { x_away, o_away }`); `cube_info` takes NO away scores and is money-game only (correction recorded post-implementation — see the deferred list).

**Tech Stack:** Rust (stable, windows-gnu toolchain on this machine), wildbg (tract-onnx inference — pure Rust, no ONNX Runtime binary), Dart `ffi` package, `package:test` with an `engine` tag for integration tests that need the built DLL + neural nets.

**Platform scope:** This machine is Windows-only. In-scope and verified here: the Windows x64 DLL (used by all Dart integration tests and later by Flutter desktop dev). Authored but deliberately NOT verified here: Android build script (needs NDK — verified in Plan 3) and iOS build doc (needs macOS — CI). This is recorded in Task 12.

**Verified facts from the scoping spike (2026-07-24):**
- wildbg repo: `https://github.com/carsten-wenderdel/wildbg`, dual MIT/Apache-2.0. Workspace crates include `engine`, `logic`, `wildbg-c`, `web`, `coach`.
- `crates/engine` depends on `tract-onnx` (pure Rust ONNX inference).
- `crates/wildbg-c` exports: `wildbg_new() -> *mut Wildbg`, `wildbg_free(*mut Wildbg)`, `best_move(*const Wildbg, &[c_int; 26] pips, c_uint die1, c_uint die2, &BgConfig) -> CMove`, `probabilities(&Wildbg, &[c_int; 26]) -> CProbabilities`, `cube_info(&Wildbg, &[c_int; 26]) -> CCubeInfo`.
- `BgConfig { x_away: c_uint, o_away: c_uint }` — 0/0 means money game.
- `CProbabilities { win, win_g, win_bg, lose_g, lose_bg: c_float }` — `win` includes gammons/backgammons; `win_g` includes backgammons (cumulative semantics).
- `CMove { details: [CMoveDetail; 4], detail_count: c_int }`, `CMoveDetail { from: c_int /* 1-25, 25=bar */, to: c_int /* 0-24, 0=off */ }`.
- Pips array: index 0 = opponent's bar (negative count), 1-24 = points from the MOVER's perspective (mover positive, moving 24→1), index 25 = mover's bar. Documented starting array: `{0, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2, 0}`.
- `wildbg_new()` resolves neural nets internally (via `WildbgApi::try_default()`); returns NULL on failure. Production-strength `.onnx` nets are NOT on the main branch — they live on the repo's `nets` branch / `wildbg-training` repo; main-branch nets are weak demo nets.
- The exact `CCubeInfo` field list and the `WildbgApi` constructor signatures were not fetched — Tasks 4 and 7 read them from the VENDORED SOURCE (authoritative, local) and mirror them. This is a read-the-local-file step, not an unknown.

**Prerequisites:** Dart SDK 3.12.2 installed (PATH refresh trick: `$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')`). No Rust yet (Task 2 installs it). Repo root: `E:\Users\anton\Documents\Claude\AIGammon`.

---

### Task 1: Plan-1 carry-forward fixes in backgammon_core

Final review of Plan 1 required these before sync/diffing code builds on the package.

**Files:**
- Modify: `packages/backgammon_core/lib/src/game_state.dart`
- Modify: `packages/backgammon_core/lib/src/game_events.dart`
- Modify: `packages/backgammon_core/lib/src/move.dart`
- Test: `packages/backgammon_core/test/carry_forward_test.dart`

- [ ] **Step 1: Write the failing test**

`test/carry_forward_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('GameResult value equality', () {
    const a = GameResult(
        winner: Player.white, points: 2, outcome: GameOutcome.gammon);
    const b = GameResult(
        winner: Player.white, points: 2, outcome: GameOutcome.gammon);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
        a,
        isNot(const GameResult(
            winner: Player.white, points: 2, outcome: GameOutcome.single)));
  });

  test('ResignOffer value equality', () {
    const a = ResignOffer(by: Player.white, value: ResignValue.gammon);
    expect(a, const ResignOffer(by: Player.white, value: ResignValue.gammon));
    expect(a,
        isNot(const ResignOffer(by: Player.black, value: ResignValue.gammon)));
  });

  test('GameState value equality', () {
    GameState fresh() =>
        GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));
    expect(fresh(), fresh());
    expect(fresh().hashCode, fresh().hashCode);
    final moved =
        fresh().play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]));
    expect(moved, isNot(fresh()));
    // Same events replayed produce equal states:
    expect(fresh().play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        moved);
  });

  test('opening-roll ties are a FormatException at the JSON boundary', () {
    expect(
        () => GameEvent.fromJson(
            {'type': 'openingRoll', 'whiteDie': 2, 'blackDie': 2}),
        throwsFormatException);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `packages/backgammon_core`): `dart test test/carry_forward_test.dart`
Expected: FAIL — equality assertions fail (identity semantics), tie test throws nothing.

- [ ] **Step 3: Implement**

In `lib/src/game_state.dart`:

Add to `GameResult`:
```dart
  @override
  bool operator ==(Object other) =>
      other is GameResult &&
      other.winner == winner &&
      other.points == points &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(winner, points, outcome);
```

Add to `ResignOffer`:
```dart
  @override
  bool operator ==(Object other) =>
      other is ResignOffer && other.by == by && other.value == value;

  @override
  int get hashCode => Object.hash(by, value);
```

Add to `GameState` (BoardState/Dice/CubeState already have value equality):
```dart
  @override
  bool operator ==(Object other) =>
      other is GameState &&
      other.board == board &&
      other.turn == turn &&
      other.phase == phase &&
      other.dice == dice &&
      other.cube == cube &&
      other.isCrawfordGame == isCrawfordGame &&
      other.resignOffer == resignOffer &&
      other.result == result;

  @override
  int get hashCode => Object.hash(
      board, turn, phase, dice, cube, isCrawfordGame, resignOffer, result);
```

In `lib/src/game_events.dart`, inside `GameEvent.fromJson`'s switch, change the `'openingRoll'` arm to validate the tie (the surrounding try/catch already converts the resulting `ArgumentError` into a `FormatException`):
```dart
      'openingRoll' => OpeningRollEvent(
          whiteDie: (json['whiteDie'] as num).toInt(),
          blackDie: (json['blackDie'] as num).toInt())
        ..validate(),
```
(Keep the existing field parsing style if it already uses `(as num).toInt()`.)

In `lib/src/move.dart`, extend the `Move` class doc comment with:
```dart
/// Note: `Move` has no value `==` — identity comparison only. Use [sameAs]
/// for order-insensitive value comparison; do not use `Move` as a Set/Map
/// key expecting value semantics.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/carry_forward_test.dart` then the full suite `dart test` (85+ tests) and `dart analyze`.
Expected: all PASS, analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): value equality for GameState/GameResult/ResignOffer; tie check at JSON boundary"
```

---

### Task 2: Rust toolchain installation

Infrastructure task — no TDD, verification by commands. Nothing to commit.

- [ ] **Step 1: Install rustup**

Run: `winget install --id Rustlang.Rustup --accept-source-agreements --accept-package-agreements --silent`
Then refresh PATH (PowerShell): `$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')`

- [ ] **Step 2: Select a host toolchain that works without Visual Studio**

Check for MSVC: `Get-Command link.exe -ErrorAction SilentlyContinue` and `Get-Command cl.exe -ErrorAction SilentlyContinue`. Unless a full MSVC build environment is present, use the self-contained GNU toolchain:

```powershell
rustup toolchain install stable-x86_64-pc-windows-gnu
rustup default stable-x86_64-pc-windows-gnu
rustc --version
```
Expected: `rustc 1.x.y` prints. (The GNU toolchain bundles a MinGW linker; no VS Build Tools needed.)

- [ ] **Step 3: Prove the toolchain end-to-end**

```powershell
cd $env:TEMP
cargo new rust_smoke --bin
cd rust_smoke
cargo run --release
```
Expected: `Hello, world!`. Delete the smoke project afterwards. If this fails, report BLOCKED with the exact error — do not proceed.

---

### Task 3: Vendor wildbg + production nets + sanity build

**Files:**
- Create: `.gitmodules` + submodule at `native/wildbg`
- Create: `native/wildbg-nets/neural-nets/*.onnx` (downloaded, committed)
- Create: `native/README.md`

- [ ] **Step 1: Add the submodule, pinned**

```bash
git submodule add https://github.com/carsten-wenderdel/wildbg native/wildbg
cd native/wildbg && git rev-parse HEAD && cd ../..
```
Record the pinned SHA in your report and in `native/README.md`.

- [ ] **Step 2: Discover the expected net filenames**

Read the vendored source: `native/wildbg/crates/engine/src/` (look for where `try_default` / evaluator construction loads `.onnx` files — search for `"neural-nets"` and `.onnx` in the vendored crates). Record the exact expected relative paths (e.g. `neural-nets/contact.onnx`, `neural-nets/race.onnx` — verify, don't assume).

- [ ] **Step 3: Fetch production nets**

The main branch ships weak demo nets. Fetch the production nets from the repo's `nets` branch (check `https://github.com/carsten-wenderdel/wildbg/tree/nets` — e.g. via `git fetch origin nets` inside the submodule and `git show origin/nets:<path>` to extract files, or raw.githubusercontent.com URLs) into `native/wildbg-nets/neural-nets/` (our own directory — never modify the submodule tree). Record file names + sizes + the source commit in `native/README.md`. If the `nets` branch layout differs from expectations, check the README on that branch / the `wildbg-training` repo and report what you found; escalate NEEDS_CONTEXT only if no production nets are locatable at all.

- [ ] **Step 4: Sanity-build wildbg's own C crate**

```powershell
cd native/wildbg
cargo build --package wildbg-c --release
```
Expected: compiles clean (first build downloads crates; takes minutes). This proves wildbg compiles on this toolchain before we invest in the shim. Record build time.

- [ ] **Step 5: Write `native/README.md`**

Contents: what the submodule is (URL + pinned SHA + license note), where the nets came from (branch/commit, filenames, sizes), the one-line Windows build command, and a warning that `native/wildbg` is never edited directly.

- [ ] **Step 6: Commit**

```bash
git add .gitmodules native/wildbg native/wildbg-nets native/README.md
git commit -m "build(engine): vendor wildbg submodule and production neural nets"
```

---

### Task 4: `aigammon_engine` Rust shim crate (cdylib)

**Files:**
- Create: `native/engine_shim/Cargo.toml`
- Create: `native/engine_shim/src/lib.rs`
- Create: `native/engine_shim/build-windows.ps1`

**Reference implementation:** the vendored `native/wildbg/crates/wildbg-c/src/lib.rs` is the authoritative, local, readable model for every exported function and struct. Mirror it; do not invent.

- [ ] **Step 1: Create the crate**

`native/engine_shim/Cargo.toml` (adjust dependency names/paths to what the vendored `wildbg-c/Cargo.toml` actually uses — it is the ground truth for which wildbg crates the C API needs):
```toml
[package]
name = "aigammon_engine"
version = "0.1.0"
edition = "2021"
publish = false

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
# Mirror the dependency lines from native/wildbg/crates/wildbg-c/Cargo.toml,
# converted to path deps, e.g.:
# engine = { path = "../wildbg/crates/engine" }
# logic = { path = "../wildbg/crates/logic" }
```

- [ ] **Step 2: Implement `src/lib.rs`**

Copy the full contents of the vendored `wildbg-c/src/lib.rs` (preserving its exported functions and structs: `wildbg_new`, `wildbg_free`, `best_move`, `probabilities`, `cube_info`, `CProbabilities`, `CMove`, `CMoveDetail`, `BgConfig`, `CCubeInfo`), then ADD one function:

```rust
/// Like wildbg_new(), but loads neural nets from the given directory
/// (UTF-8 path). Returns NULL on failure. Needed on mobile, where there is
/// no meaningful current working directory.
#[no_mangle]
pub extern "C" fn wildbg_new_with_path(path: *const std::os::raw::c_char) -> *mut Wildbg {
    // Implementation strategy, in order of preference:
    // 1. If the vendored WildbgApi (see how try_default() constructs it in
    //    the vendored source) exposes a constructor taking net paths or a
    //    config, call it with paths derived from `path`.
    // 2. Otherwise: save the current dir, set_current_dir(path),
    //    call the same construction try_default() uses, restore the dir.
    //    Document this fallback with a comment.
    // Return NULL (and eprintln! the error) on any failure, matching
    // wildbg_new()'s behavior.
}
```

Read the vendored source to pick strategy 1 or 2; note which you used in your report. If the vendored `wildbg-c` API surface differs materially from the "Verified facts" list in this plan's header (missing functions, different struct fields), report the delta — mirror the SOURCE, not the plan.

- [ ] **Step 3: Build script**

`native/engine_shim/build-windows.ps1`:
```powershell
# Builds the Windows x64 engine DLL and stages it where engine_bindings looks.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
cargo build --release
$out = Join-Path $PSScriptRoot '..\..\packages\engine_bindings\native\windows'
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'target\release\aigammon_engine.dll') $out -Force
Pop-Location
Write-Host "Staged aigammon_engine.dll -> packages/engine_bindings/native/windows/"
```

- [ ] **Step 4: Build and verify exports**

Run `.\build-windows.ps1`. Expected: `aigammon_engine.dll` staged. Verify the exports exist:
```powershell
# The GNU toolchain ships objdump with mingw; locate it under ~/.rustup
& (Get-ChildItem "$env:USERPROFILE\.rustup" -Recurse -Filter objdump.exe | Select-Object -First 1).FullName -p .\target\release\aigammon_engine.dll | Select-String "wildbg_new|best_move|probabilities|cube_info"
```
Expected: all exported symbols listed (including `wildbg_new_with_path`). If objdump isn't found, any export viewer works; state what you used.

- [ ] **Step 5: Commit**

```bash
git add native/engine_shim
git commit -m "build(engine): aigammon_engine cdylib shim over wildbg with path-based init"
```
Note: `native/engine_shim/target/` and the staged DLL must NOT be committed — add a `native/engine_shim/.gitignore` containing `target/` and add `packages/engine_bindings/native/` to a `.gitignore` inside `packages/engine_bindings` (created next task — for now put the ignore in the shim commit if needed).

---

### Task 5: `engine_bindings` package scaffold

**Files:**
- Create: `packages/engine_bindings/pubspec.yaml`
- Create: `packages/engine_bindings/analysis_options.yaml`
- Create: `packages/engine_bindings/.gitignore`
- Create: `packages/engine_bindings/dart_test.yaml`
- Create: `packages/engine_bindings/lib/engine_bindings.dart`
- Create: `packages/engine_bindings/test/smoke_test.dart`

- [ ] **Step 1: Create files**

`pubspec.yaml`:
```yaml
name: engine_bindings
description: dart:ffi bindings and isolate service for the wildbg engine.
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.4.0

dependencies:
  backgammon_core:
    path: ../backgammon_core
  ffi: ^2.1.0

dev_dependencies:
  lints: ^4.0.0
  test: ^1.25.0
```

`analysis_options.yaml`:
```yaml
include: package:lints/recommended.yaml
```

`.gitignore`:
```
.dart_tool/
pubspec.lock
native/
```

`dart_test.yaml` (integration tests needing the DLL + nets are tagged; excluded from the default run, opted into via preset):
```yaml
tags:
  engine:
exclude_tags: engine
presets:
  engine:
    exclude_tags: []
    include_tags: engine
```
If the test runner's config schema rejects this exact shape (preset override semantics vary by test-package version), achieve the same effect — default `dart test` skips engine-tagged tests, `dart test -P engine` runs only them — and document the working commands in the package README (Task 12). `dart test -t engine` / `-x engine` flags are an acceptable fallback.

`lib/engine_bindings.dart`:
```dart
/// dart:ffi bindings and isolate service for the wildbg engine.
library;
```

`test/smoke_test.dart`:
```dart
import 'package:test/test.dart';

void main() {
  test('package resolves', () {
    expect(1 + 1, 2);
  });
}
```

- [ ] **Step 2: Verify**

Run (from `packages/engine_bindings`): `dart pub get` then `dart test`
Expected: `All tests passed!` (engine-tagged: none yet).

- [ ] **Step 3: Commit**

```bash
git add packages/engine_bindings
git commit -m "feat(bindings): scaffold engine_bindings package"
```

---

### Task 6: Position codec

**Files:**
- Create: `packages/engine_bindings/lib/src/position_codec.dart`
- Modify: `packages/engine_bindings/lib/engine_bindings.dart`
- Test: `packages/engine_bindings/test/position_codec_test.dart`

- [ ] **Step 1: Write the failing test**

`test/position_codec_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  // Golden from wildbg's own C API docs (starting position, mover's view).
  const wildbgStart = [
    0, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, //
    -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2, 0,
  ];

  test('white mover: starting position matches wildbg golden array', () {
    expect(encodePips(BoardState.initial(), Player.white), wildbgStart);
  });

  test('black mover: symmetric start encodes identically', () {
    expect(encodePips(BoardState.initial(), Player.black), wildbgStart);
  });

  test('bars are encoded at indices 25 (mover) and 0 (opponent, negative)',
      () {
    final b = BoardState(
        points: List.filled(24, 0), whiteBar: 2, blackBar: 1);
    final whiteView = encodePips(b, Player.white);
    expect(whiteView[25], 2);
    expect(whiteView[0], -1);
    final blackView = encodePips(b, Player.black);
    expect(blackView[25], 1);
    expect(blackView[0], -2);
  });

  test('asymmetric position mirrors correctly for the black mover', () {
    // Lone white checker on White's 24-point (index 23).
    final pts = List<int>.filled(24, 0);
    pts[23] = 1;
    final b = BoardState(points: pts);
    // White mover: that checker is on wildbg pip 24.
    expect(encodePips(b, Player.white)[24], 1);
    // Black mover: mirrored — the white checker is the OPPONENT on pip 1.
    expect(encodePips(b, Player.black)[1], -1);
  });

  test('decodeDetail maps pips back to CheckerMove for both movers', () {
    // White mover: pip 8 -> 5 is index 7 -> 4.
    expect(decodeDetail(8, 5, Player.white), const CheckerMove(7, 4));
    // Bar entry: from 25; die 3 lands on pip 22 = index 21.
    expect(decodeDetail(25, 22, Player.white),
        const CheckerMove(CheckerMove.bar, 21));
    // Bear-off: to 0.
    expect(decodeDetail(3, 0, Player.white),
        const CheckerMove(2, CheckerMove.off));
    // Black mover: pip p = real index 24 - p.
    expect(decodeDetail(8, 5, Player.black), const CheckerMove(16, 19));
    expect(decodeDetail(25, 22, Player.black),
        const CheckerMove(CheckerMove.bar, 2));
    expect(decodeDetail(3, 0, Player.black),
        const CheckerMove(21, CheckerMove.off));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/position_codec_test.dart`
Expected: FAIL — `encodePips`/`decodeDetail` undefined.

- [ ] **Step 3: Implement**

`lib/src/position_codec.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';

/// Encodes a board as wildbg's 26-int pip array from [mover]'s perspective:
/// index 0 = opponent's bar (negative), 1-24 = pips (mover positive, moving
/// 24 -> 1), index 25 = mover's bar.
List<int> encodePips(BoardState board, Player mover) {
  final n = mover == Player.white ? board : board.mirrored();
  return [
    -n.blackBar,
    ...n.points,
    n.whiteBar,
  ];
}

/// Maps one wildbg move detail (from: 1-25 where 25 = bar; to: 0-24 where
/// 0 = off) back to a [CheckerMove] in real White-perspective coordinates.
/// Hit flags are not reconstructed — BoardState.applyMove recomputes hits.
CheckerMove decodeDetail(int from, int to, Player mover) {
  if (mover == Player.white) {
    return CheckerMove(
      from == 25 ? CheckerMove.bar : from - 1,
      to == 0 ? CheckerMove.off : to - 1,
    );
  }
  return CheckerMove(
    from == 25 ? CheckerMove.bar : 24 - from,
    to == 0 ? CheckerMove.off : 24 - to,
  );
}
```

Append to `lib/engine_bindings.dart`:
```dart
export 'src/position_codec.dart';
```

Sanity note for the implementer: `n.points` after mirroring puts the mover's point `p` at list index `p-1`, so the spread lands points at pip indices 1-24. The mirrored board's `whiteBar` IS the mover's bar by construction of `BoardState.mirrored()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/position_codec_test.dart` then `dart test` + `dart analyze`.
Expected: PASS, clean.

- [ ] **Step 5: Commit**

```bash
git add packages/engine_bindings
git commit -m "feat(bindings): wildbg position codec with golden-array tests"
```

---

### Task 7: FFI bindings and synchronous Engine

**Files:**
- Create: `packages/engine_bindings/lib/src/ffi/wildbg_ffi.dart`
- Create: `packages/engine_bindings/lib/src/engine.dart`
- Create: `packages/engine_bindings/lib/src/scored_move.dart`
- Modify: `packages/engine_bindings/lib/engine_bindings.dart`
- Test: `packages/engine_bindings/test/engine_integration_test.dart` (tagged `engine`)

**Before writing code:** read the vendored `native/wildbg/crates/wildbg-c/src/lib.rs` and mirror struct layouts EXACTLY (field order matters for FFI). In particular, record `CCubeInfo`'s fields — the plan does not assume them. If `CCubeInfo` turns out not to expose usable double/take guidance, note it in your report; the cube-advice API below then wraps whatever it does expose, and the controller decides on a Dart-side Janowski fallback (do not build one unrequested).

- [ ] **Step 1: FFI layer**

`lib/src/ffi/wildbg_ffi.dart` (structure; mirror field order from the vendored source):
```dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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

final class CMoveDetail extends Struct {
  @Int32()
  external int from;
  @Int32()
  external int to;
}

final class CMove extends Struct {
  @Array(4)
  external Array<CMoveDetail> details;
  @Int32()
  external int detailCount;
}

final class BgConfig extends Struct {
  @Uint32()
  external int xAway;
  @Uint32()
  external int oAway;
}

// CCubeInfo: mirror the vendored wildbg-c definition field-for-field here.

typedef _NewWithPathC = Pointer<Void> Function(Pointer<Utf8>);
typedef _NewWithPathDart = Pointer<Void> Function(Pointer<Utf8>);
// ...typedefs for wildbg_new, wildbg_free, probabilities, best_move,
// cube_info, each mirroring the C signatures with Pointer<Int32> for the
// pips array parameter.

/// Raw library binding. Loads the DLL and looks up every export once.
class WildbgFfi {
  final DynamicLibrary _lib;
  // late final fields for each looked-up function...

  WildbgFfi(String libraryPath) : _lib = DynamicLibrary.open(libraryPath) {
    // lookups
  }

  /// Default library location: $WILDBG_LIB_PATH, else
  /// packages/engine_bindings/native/<os>/aigammon_engine.dll (staged by
  /// native/engine_shim/build-windows.ps1).
  static String defaultLibraryPath() {
    final env = Platform.environment['WILDBG_LIB_PATH'];
    if (env != null && env.isNotEmpty) return env;
    final base = 'native';
    if (Platform.isWindows) return '$base/windows/aigammon_engine.dll';
    if (Platform.isLinux) return '$base/linux/libaigammon_engine.so';
    if (Platform.isMacOS) return '$base/macos/libaigammon_engine.dylib';
    throw UnsupportedError('no default engine library path for this OS');
  }
}
```
Write the real lookups/typedefs for all six exports (`wildbg_new`, `wildbg_new_with_path`, `wildbg_free`, `probabilities`, `best_move`, `cube_info`). Pips are passed as `Pointer<Int32>` (allocate 26 ints with `calloc`, free after the call).

- [ ] **Step 2: Domain types + Engine**

`lib/src/scored_move.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';

/// Cubeless evaluation of a position from the perspective of the player who
/// just got it evaluated. All probabilities cumulative (win includes
/// gammons; winGammon includes backgammons) — wildbg semantics.
class Probabilities {
  final double win;
  final double winGammon;
  final double winBackgammon;
  final double loseGammon;
  final double loseBackgammon;

  const Probabilities({
    required this.win,
    required this.winGammon,
    required this.winBackgammon,
    required this.loseGammon,
    required this.loseBackgammon,
  });

  /// Cubeless equity in [-3, 3].
  double get equity =>
      2 * win - 1 + winGammon + winBackgammon - loseGammon - loseBackgammon;

  /// The same position seen by the opponent.
  Probabilities get inverted => Probabilities(
        win: 1 - win,
        winGammon: loseGammon,
        winBackgammon: loseBackgammon,
        loseGammon: winGammon,
        loseBackgammon: winBackgammon,
      );
}

class ScoredMove {
  final Move move;
  final Probabilities probabilities; // mover's perspective, after the move
  double get equity => probabilities.equity;
  const ScoredMove({required this.move, required this.probabilities});
}
```

`lib/src/engine.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';

import 'ffi/wildbg_ffi.dart';
import 'position_codec.dart';
import 'scored_move.dart';

/// Synchronous engine facade. NOT for UI-thread use — wrap in EngineService
/// (Task 8) for async access.
class Engine {
  // Holds WildbgFfi + the Pointer<Void> engine handle.

  /// Throws StateError if the library loads but the engine fails to
  /// initialize (NULL handle) — usually a nets-path problem.
  Engine.open({String? libraryPath, required String netsPath});

  /// Win/gammon/backgammon probabilities for the position with [mover] to
  /// roll (cubeless).
  Probabilities evaluate(BoardState board, Player mover);

  /// The engine's best move, mapped to real coordinates. Returns Move.none
  /// when the engine reports no legal move. xAway/oAway = 0 for money play.
  Move bestMove(BoardState board, Player mover, Dice dice,
      {int xAway = 0, int oAway = 0});

  /// Ranks every legal move by evaluating the resulting position from the
  /// opponent's perspective and negating. Sorted best-first. This powers
  /// the AI opponent, difficulty sampling, and tutor mode.
  List<ScoredMove> rankMoves(BoardState board, Player mover, Dice dice) {
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

  /// Cube advice from wildbg's cube_info, shaped by what the vendored
  /// struct actually exposes (see Task 7 preamble).
  CubeAdvice cubeInfo(BoardState board, Player mover,
      {int xAway = 0, int oAway = 0});

  void dispose(); // wildbg_free
}
```
Define `CubeAdvice` in `scored_move.dart` (rename file stays) with fields mirroring the vendored `CCubeInfo` (plus doc comments explaining semantics as found in the vendored source).

Export the new files from the barrel (do NOT export `src/ffi/wildbg_ffi.dart` — it is internal).

- [ ] **Step 3: Integration test (tagged)**

`test/engine_integration_test.dart`:
```dart
@Tags(['engine'])
library;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  late Engine engine;

  setUpAll(() {
    engine = Engine.open(netsPath: '../../native/wildbg-nets');
    // netsPath must point at the directory CONTAINING neural-nets/ — adjust
    // to whatever Task 4's wildbg_new_with_path expects; document it there.
  });

  tearDownAll(() => engine.dispose());

  test('starting position is roughly even', () {
    final p = engine.evaluate(BoardState.initial(), Player.white);
    expect(p.win, closeTo(0.5, 0.07));
    expect(p.winGammon, lessThan(p.win));
    expect(p.winBackgammon, lessThanOrEqualTo(p.winGammon));
    expect(p.equity, closeTo(0, 0.3));
  });

  test('a winning race is recognized', () {
    // White: 2 checkers on the ace point, 13 off. Black: 15 far away.
    final pts = List<int>.filled(24, 0);
    pts[0] = 2;
    pts[23] = -15;
    final b = BoardState(points: pts, whiteOff: 13);
    final p = engine.evaluate(b, Player.white);
    expect(p.win, greaterThan(0.95));
  });

  test('bestMove returns a legal move', () {
    final best =
        engine.bestMove(BoardState.initial(), Player.white, Dice(3, 1));
    final legal =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(3, 1));
    expect(legal.any((m) => m.sameAs(best)), isTrue,
        reason: 'engine best move must be legal: $best');
  });

  test('rankMoves ranks every legal move, best first', () {
    final ranked =
        engine.rankMoves(BoardState.initial(), Player.white, Dice(3, 1));
    final legal =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(3, 1));
    expect(ranked, hasLength(legal.length));
    for (var i = 1; i < ranked.length; i++) {
      expect(ranked[i - 1].equity, greaterThanOrEqualTo(ranked[i].equity));
    }
    // With production nets, the golden point (8/5 6/5) should rank at or
    // near the top; log it rather than hard-asserting engine strength:
    // ignore: avoid_print
    print('top 3-1 move: ${ranked.first.move} (${ranked.first.equity})');
  });

  test('engine best move agrees with the top-ranked move most simply', () {
    final best =
        engine.bestMove(BoardState.initial(), Player.white, Dice(3, 1));
    final ranked =
        engine.rankMoves(BoardState.initial(), Player.white, Dice(3, 1));
    // Not necessarily identical (engine may search deeper), but the engine
    // pick must be within the top few of our 0-ply ranking.
    final index = ranked.indexWhere((s) => s.move.sameAs(best));
    expect(index, inInclusiveRange(0, 3),
        reason: 'engine pick $best ranked #$index in 0-ply ranking');
  });

  test('cube_info returns sane values on the starting position', () {
    final advice = engine.cubeInfo(BoardState.initial(), Player.white);
    // Field assertions depend on the vendored CCubeInfo — assert every
    // numeric field is finite and every probability-like field is in
    // [0, 1]; assert the obvious semantic (nobody doubles the opening).
    expect(advice, isNotNull);
  });
}
```
Adjust the `cube_info` test to real fields once mirrored. Run with `dart test -P engine` — the default `dart test` run must skip these.

- [ ] **Step 4: Run**

`dart test` → non-engine tests pass, engine-tagged skipped.
`dart test -P engine` → all integration tests pass against the real DLL + nets.
`dart analyze` → clean.
If the engine fails to initialize, debug the nets path handling from Task 4 — do not weaken tests.

- [ ] **Step 5: Commit**

```bash
git add packages/engine_bindings
git commit -m "feat(bindings): FFI bindings, sync Engine, 0-ply move ranking with integration tests"
```

---

### Task 8: EngineService (isolate wrapper)

**Files:**
- Create: `packages/engine_bindings/lib/src/engine_service.dart`
- Modify: `packages/engine_bindings/lib/engine_bindings.dart`
- Test: `packages/engine_bindings/test/engine_service_test.dart` (tagged `engine`)

- [ ] **Step 1: Write the failing test**

`test/engine_service_test.dart`:
```dart
@Tags(['engine'])
library;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  late EngineService service;

  setUpAll(() async {
    service = await EngineService.spawn(netsPath: '../../native/wildbg-nets');
  });

  tearDownAll(() => service.dispose());

  test('evaluate round-trips through the isolate', () async {
    final p = await service.evaluate(BoardState.initial(), Player.white);
    expect(p.win, closeTo(0.5, 0.07));
  });

  test('rankMoves works and concurrent requests do not interleave replies',
      () async {
    final results = await Future.wait([
      service.rankMoves(BoardState.initial(), Player.white, Dice(3, 1)),
      service.rankMoves(BoardState.initial(), Player.white, Dice(6, 5)),
      service.evaluate(BoardState.initial(), Player.black),
    ]);
    final r31 = results[0] as List<ScoredMove>;
    final r65 = results[1] as List<ScoredMove>;
    expect(
        r31.first.move.checkerMoves.every(
            (c) => c.from == CheckerMove.bar || c.from >= 0 && c.from < 24),
        isTrue);
    // 6-5 from the start has distinct legal moves from 3-1; a crossed wire
    // would surface as impossible hop distances.
    expect(r65, isNotEmpty);
    expect(r31.length,
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(3, 1))
            .length);
  });

  test('dispose is idempotent and pending calls after dispose throw',
      () async {
    final s = await EngineService.spawn(netsPath: '../../native/wildbg-nets');
    s.dispose();
    s.dispose();
    expect(() => s.evaluate(BoardState.initial(), Player.white),
        throwsStateError);
  });
}
```

- [ ] **Step 2: Run to verify it fails** (`dart test -P engine test/engine_service_test.dart`) — `EngineService` undefined.

- [ ] **Step 3: Implement**

`lib/src/engine_service.dart`:
```dart
import 'dart:async';
import 'dart:isolate';

import 'package:backgammon_core/backgammon_core.dart';

import 'engine.dart';
import 'scored_move.dart';

/// Async facade over [Engine], hosted in a dedicated isolate so neural-net
/// inference never blocks the caller (the UI thread in the app).
///
/// Protocol: each request is (id, verb, payload); the isolate replies
/// (id, result | error). Requests are matched by id, so concurrent calls
/// are safe. If the isolate dies, all pending requests complete with an
/// error and the service must be re-spawned by the owner (the app layer
/// supervises; see design spec §7).
class EngineService {
  // SendPort to the worker, ReceivePort subscription, Map<int, Completer>,
  // next-id counter, disposed flag, and the Isolate handle.

  static Future<EngineService> spawn(
      {String? libraryPath, required String netsPath});

  Future<Probabilities> evaluate(BoardState board, Player mover);

  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice);

  Future<Move> bestMove(BoardState board, Player mover, Dice dice,
      {int xAway = 0, int oAway = 0});

  Future<CubeAdvice> cubeInfo(BoardState board, Player mover,
      {int xAway = 0, int oAway = 0});

  /// Kills the isolate. Safe to call twice. Subsequent calls to any verb
  /// throw StateError.
  void dispose();
}
```
Implementation requirements (write real code for all of this):
- The isolate entrypoint receives `(SendPort, libraryPath, netsPath)`, opens the `Engine`, sends back its own SendPort, then serves requests in a `ReceivePort` loop. Wrap each request in try/catch and send `(id, 'error', e.toString())` on failure — never let one bad request kill the loop.
- Payloads crossing the isolate boundary must be primitives: encode `BoardState` as `(points, whiteBar, blackBar, whiteOff, blackOff)` lists/ints; `Move` as `[[from, to, isHit], ...]` triples; `Probabilities` as a 5-double list; `ScoredMove` lists as parallel lists. (backgammon_core types are immutable but not `Sendable`-annotated; explicit encoding keeps the contract obvious and version-safe.)
- `dispose()`: kill isolate, close ports, completeError all pending with `StateError('EngineService disposed')`, set flag.
- On isolate exit/error (use `Isolate.addOnExitListener` / `addErrorListener`): completeError all pending with `StateError('engine isolate died: ...')` and mark the service dead (calls then throw). Re-spawn is the OWNER's job — do not auto-restart inside the service (the app layer supervises per the design spec; keeping this class dumb makes its behavior testable).

- [ ] **Step 4: Run** — `dart test -P engine` all green; `dart test` (non-engine) green; `dart analyze` clean.

- [ ] **Step 5: Commit**

```bash
git add packages/engine_bindings
git commit -m "feat(bindings): isolate-hosted EngineService with id-matched async protocol"
```

---

### Task 9: gnubg Position ID export (backgammon_core)

**Files:**
- Create: `packages/backgammon_core/lib/src/position_id.dart`
- Modify: `packages/backgammon_core/lib/backgammon_core.dart`
- Test: `packages/backgammon_core/test/position_id_test.dart`

The gnubg Position ID is the debugging lingua franca of backgammon software; we emit it in logs and test fixtures. Spec reference: the gnubg manual section "A technical description of the Position ID" (`https://www.gnu.org/software/gnubg/manual/html_node/A-technical-description-of-the-Position-ID.html`) — fetch and read it before implementing; it contains a worked example that disambiguates player order and bit packing.

- [ ] **Step 1: Write the failing test**

`test/position_id_test.dart`:
```dart
import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('starting position has the canonical gnubg Position ID', () {
    expect(positionId(BoardState.initial(), Player.white), '4HPwATDgc/ABMA');
    // The start is symmetric, so the ID is the same with black on roll.
    expect(positionId(BoardState.initial(), Player.black), '4HPwATDgc/ABMA');
  });

  test('a checker on the bar changes the ID', () {
    final b = BoardState(
        points: BoardState.initial().points, whiteBar: 1);
    expect(positionId(b, Player.white), isNot('4HPwATDgc/ABMA'));
    expect(positionId(b, Player.white), hasLength(14));
  });

  test('IDs are 14 base64 characters', () {
    final pts = List<int>.filled(24, 0);
    pts[0] = 15;
    pts[23] = -15;
    expect(positionId(BoardState(points: pts), Player.white), hasLength(14));
  });
}
```
ADD one more golden test from the gnubg manual's worked example (whatever position/ID the manual demonstrates) once you have read it — a symmetric-start golden alone cannot catch a swapped player order.

- [ ] **Step 2: Run to verify it fails** — `positionId` undefined.

- [ ] **Step 3: Implement**

`lib/src/position_id.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';

import 'board_state.dart';
import 'player.dart';

/// The gnubg Position ID for [board] with [onRoll] to move: an 80-bit
/// checker encoding, base64-encoded to 14 characters.
///
/// Per the gnubg manual: for each player — starting with the player NOT on
/// roll or the player on roll AS THE MANUAL SPECIFIES (verify against the
/// manual's worked example and fix this comment to state the actual order)
/// — for each of the 25 locations (points 1..24 from that player's own
/// direction of travel, then the bar), append one 1-bit per checker
/// followed by a single 0-bit. Pad to 80 bits. Bits fill each byte least-
/// significant-bit first. Base64 (standard alphabet) of the 10 bytes,
/// without padding, gives 14 characters.
String positionId(BoardState board, Player onRoll) {
  final bytes = Uint8List(10);
  var bit = 0;

  void writeChecker() {
    bytes[bit >> 3] |= 1 << (bit & 7);
    bit++;
  }

  void writePlayer(Player p) {
    // Points 1..24 in p's own numbering: for White, point k is index k-1;
    // for Black, point k is index 24-k. Then the bar.
    for (var k = 1; k <= 24; k++) {
      final i = p == Player.white ? k - 1 : 24 - k;
      final c = board.points[i];
      final count = p == Player.white ? (c > 0 ? c : 0) : (c < 0 ? -c : 0);
      for (var j = 0; j < count; j++) {
        writeChecker();
      }
      bit++; // the terminating 0-bit
    }
    for (var j = 0; j < board.barFor(p); j++) {
      writeChecker();
    }
    bit++;
  }

  // ORDER: verify against the gnubg manual worked example; the manual is
  // authoritative. Adjust these two lines if the example disagrees.
  writePlayer(onRoll.opponent);
  writePlayer(onRoll);

  return base64Encode(bytes).substring(0, 14);
}
```
If the manual's worked example shows the opposite player order or MSB-first bit packing, fix the code to match the manual, update the doc comment, and note it in your report. The starting-position golden must pass either way; the manual example is the disambiguator.

Append to `lib/backgammon_core.dart`:
```dart
export 'src/position_id.dart';
```

- [ ] **Step 4: Run** — all backgammon_core tests + analyzer green.

- [ ] **Step 5: Commit**

```bash
git add packages/backgammon_core
git commit -m "feat(core): gnubg Position ID export"
```

---

### Task 10: Difficulty levels

**Files:**
- Create: `packages/engine_bindings/lib/src/difficulty.dart`
- Modify: `packages/engine_bindings/lib/engine_bindings.dart`
- Test: `packages/engine_bindings/test/difficulty_test.dart` (NOT engine-tagged — pure logic)

- [ ] **Step 1: Write the failing test**

`test/difficulty_test.dart`:
```dart
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

ScoredMove scored(int fromIdx, double equity) => ScoredMove(
      move: Move([CheckerMove(fromIdx, fromIdx - 1)]),
      probabilities: Probabilities(
        // Simplest probabilities yielding the desired equity:
        win: (equity + 1) / 2,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      ),
    );

void main() {
  final ranked = [
    scored(23, 0.20),
    scored(22, 0.15),
    scored(21, 0.00),
    scored(20, -0.40),
  ];

  test('expert always plays the best move', () {
    final rng = Random(1);
    for (var i = 0; i < 50; i++) {
      expect(pickMove(ranked, Difficulty.expert, rng), same(ranked.first));
    }
  });

  test('lower difficulties never pick outside their equity window', () {
    final rng = Random(2);
    for (var i = 0; i < 200; i++) {
      final hard = pickMove(ranked, Difficulty.hard, rng);
      expect(ranked.first.equity - hard.equity,
          lessThanOrEqualTo(Difficulty.hard.equityWindow));
      final easy = pickMove(ranked, Difficulty.easy, rng);
      expect(ranked.first.equity - easy.equity,
          lessThanOrEqualTo(Difficulty.easy.equityWindow));
    }
  });

  test('easy actually varies its play (samples more than one move)', () {
    final rng = Random(3);
    final picks = <int>{};
    for (var i = 0; i < 300; i++) {
      picks.add(ranked.indexOf(pickMove(ranked, Difficulty.easy, rng)));
    }
    expect(picks.length, greaterThan(1));
  });

  test('single candidate is always returned', () {
    final rng = Random(4);
    final only = [scored(5, -1.0)];
    expect(pickMove(only, Difficulty.easy, rng), same(only.first));
  });

  test('empty list throws', () {
    expect(() => pickMove(const [], Difficulty.expert, Random(5)),
        throwsArgumentError);
  });
}
```

- [ ] **Step 2: Run to verify it fails** — `Difficulty`/`pickMove` undefined.

- [ ] **Step 3: Implement**

`lib/src/difficulty.dart`:
```dart
import 'dart:math';

import 'scored_move.dart';

/// AI strength levels. One engine serves all levels: lower levels sample
/// among near-best moves instead of always playing the best (design spec
/// §3). equityWindow caps how far below the best move a pick may be;
/// temperature controls how sharply better moves are preferred.
enum Difficulty {
  easy(equityWindow: 0.250, temperature: 0.080),
  medium(equityWindow: 0.120, temperature: 0.040),
  hard(equityWindow: 0.050, temperature: 0.020),
  expert(equityWindow: 0.0, temperature: 0.0);

  final double equityWindow;
  final double temperature;
  const Difficulty({required this.equityWindow, required this.temperature});
}

/// Picks a move from [ranked] (already sorted best-first) for [level].
/// Expert takes the top move. Others sample among moves within
/// [Difficulty.equityWindow] of the best, weighted by
/// exp(-(equityLoss) / temperature).
ScoredMove pickMove(List<ScoredMove> ranked, Difficulty level, Random rng) {
  if (ranked.isEmpty) {
    throw ArgumentError('ranked must not be empty');
  }
  if (level == Difficulty.expert || ranked.length == 1) {
    return ranked.first;
  }
  final best = ranked.first.equity;
  final candidates = [
    for (final s in ranked)
      if (best - s.equity <= level.equityWindow) s,
  ];
  final weights = [
    for (final s in candidates)
      exp(-(best - s.equity) / level.temperature),
  ];
  final total = weights.reduce((a, b) => a + b);
  var roll = rng.nextDouble() * total;
  for (var i = 0; i < candidates.length; i++) {
    roll -= weights[i];
    if (roll <= 0) return candidates[i];
  }
  return candidates.last;
}
```

Export from the barrel.

- [ ] **Step 4: Run** — difficulty tests + full non-engine suite + analyzer green.

- [ ] **Step 5: Commit**

```bash
git add packages/engine_bindings
git commit -m "feat(bindings): difficulty levels via windowed softmax sampling"
```

---

### Task 11: AI-vs-AI integration test

**Files:**
- Test: `packages/engine_bindings/test/ai_vs_ai_test.dart` (tagged `engine`)

- [ ] **Step 1: Write the test**

`test/ai_vs_ai_test.dart`:
```dart
@Tags(['engine'])
library;

import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('two engine players complete full games legally', () async {
    final service =
        await EngineService.spawn(netsPath: '../../native/wildbg-nets');
    addTearDown(service.dispose);
    final rng = Random(7);
    Dice roll() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);

    final sw = Stopwatch()..start();
    for (var g = 0; g < 3; g++) {
      var opening = roll();
      while (opening.isDouble) {
        opening = roll();
      }
      var state = GameState.opening(
        firstPlayer: opening.die1 > opening.die2 ? Player.white : Player.black,
        openingDice: opening,
      );
      var turns = 0;
      while (state.phase != GamePhase.gameOver) {
        expect(++turns, lessThan(600), reason: 'game $g stuck');
        switch (state.phase) {
          case GamePhase.awaitingRoll:
            state = state.roll(roll());
          case GamePhase.moving:
            final ranked =
                await service.rankMoves(state.board, state.turn, state.dice!);
            final pick = ranked.isEmpty
                ? Move.none
                : pickMove(
                        ranked,
                        state.turn == Player.white
                            ? Difficulty.expert
                            : Difficulty.easy,
                        rng)
                    .move;
            state = state.play(pick); // GameState enforces legality
          case GamePhase.cubeOffered:
          case GamePhase.resignOffered:
          case GamePhase.gameOver:
            fail('unexpected phase ${state.phase}');
        }
      }
      expect(state.result!.points, greaterThan(0));
    }
    sw.stop();
    // ignore: avoid_print
    print('3 AI-vs-AI games in ${sw.elapsedMilliseconds} ms');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
```

- [ ] **Step 2: Run** — `dart test -P engine test/ai_vs_ai_test.dart`. Expected: PASS. Report the printed timing (this is our first end-to-end engine-performance datapoint; if 3 games exceed ~3 minutes, report DONE_WITH_CONCERNS with the number).

- [ ] **Step 3: Commit**

```bash
git add packages/engine_bindings
git commit -m "test(bindings): AI-vs-AI end-to-end games through EngineService"
```

---

### Task 12: Mobile build scripts (authored, verification deferred) + docs

**Files:**
- Create: `native/engine_shim/build-android.ps1`
- Create: `native/engine_shim/build-ios.sh`
- Create: `packages/engine_bindings/README.md`
- Modify: `native/README.md`

- [ ] **Step 1: Android build script**

`native/engine_shim/build-android.ps1`:
```powershell
# Builds aigammon_engine for Android ABIs into Flutter jniLibs layout.
# PREREQUISITES (not present on this machine yet — verified in Plan 3):
#   - Android NDK, with $env:ANDROID_NDK_HOME set
#   - cargo install cargo-ndk
#   - rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$out = Join-Path $PSScriptRoot '..\..\packages\engine_bindings\native\android\jniLibs'
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o $out build --release
Pop-Location
Write-Host "Staged Android .so files -> $out"
```

- [ ] **Step 2: iOS build script**

`native/engine_shim/build-ios.sh`:
```bash
#!/usr/bin/env bash
# Builds an XCFramework for iOS device + simulator. macOS only (CI).
# PREREQUISITES: Xcode CLT; rustup target add aarch64-apple-ios aarch64-apple-ios-sim
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
OUT=../../packages/engine_bindings/native/ios
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libaigammon_engine.a \
  -library target/aarch64-apple-ios-sim/release/libaigammon_engine.a \
  -output "$OUT/aigammon_engine.xcframework"
echo "Staged XCFramework -> $OUT"
```

- [ ] **Step 3: `packages/engine_bindings/README.md`**

Document: what the package is; how to build the Windows DLL (`native/engine_shim/build-windows.ps1`); the `WILDBG_LIB_PATH` override; how to run integration tests (`dart test -P engine`); the nets directory contract (`netsPath` points at the directory containing `neural-nets/`); the mobile build scripts and their DEFERRED-VERIFICATION status ("Android verified in Plan 3 when the NDK lands; iOS on CI/macOS"); wildbg licensing (MIT/Apache-2.0, vendored at the SHA pinned in `native/README.md`).

- [ ] **Step 4: Update `native/README.md`** with a build-matrix table (windows: verified | android: script authored, Plan 3 | ios: script authored, CI) and a line stating tract-onnx keeps mobile builds free of ONNX Runtime binaries.

- [ ] **Step 5: Run the full test suites one last time**

From `packages/backgammon_core`: `dart analyze && dart test`.
From `packages/engine_bindings`: `dart analyze && dart test && dart test -P engine`.
Expected: everything green.

- [ ] **Step 6: Commit**

```bash
git add native packages/engine_bindings/README.md
git commit -m "build(engine): mobile build scripts (deferred verification) and docs"
```

---

## Explicitly deferred (recorded, not forgotten)

- **Android/iOS build verification** — Plan 3 (NDK arrives with the Flutter toolchain) / CI on macOS.
- **gnubg-generated move fixtures** (spec §8 cross-validation) — needs gnubg installed on some machine; the 300-game playout + engine-legality cross-checks (Tasks 7/11) are the current gate.
- **Dart-side Janowski/MET fallback** — RESOLVED during implementation: wildbg's `cube_info` proved Janowski-complete for MONEY play (including too-good-to-double; wildbg pinned commit implements the Janowski formulas) but takes no away scores, so **match-aware cube decisions remain unimplemented**. `best_move` IS match-aware via `BgConfig`. If Plan 3/4's tutor needs cube advice at a match score, build the Dart Janowski + match-equity-table adapter then; until that lands, `CubeAdvice` is money-game only (documented on the class and in `native/README.md`).
- **Flutter desktop/mobile wiring of the DLL/so/xcframework into app bundles** — Plan 3.
