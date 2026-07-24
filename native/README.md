# native/ — vendored wildbg engine and neural nets

This directory vendors the [wildbg](https://github.com/carsten-wenderdel/wildbg)
backgammon engine (as a git submodule) plus the production neural nets used by
AIGammon's engine integration.

> **Never edit `native/wildbg/` directly.** It is a pinned git submodule.
> All AIGammon-specific code lives in sibling crates/shims, never inside the
> submodule tree. To move to a newer engine, bump the submodule pin in a
> dedicated commit.

## `native/wildbg` — the submodule

- **URL:** https://github.com/carsten-wenderdel/wildbg
- **Pinned commit:** `24d26fe0c7c6ddbb277894c2f92c18410198e4a9`
  - _"Implement doubling cube logic using Janowski formulas (#42)"_, 2026-07-24
- **License:** dual **MIT OR Apache-2.0** (`native/wildbg/LICENSE-MIT`,
  `native/wildbg/LICENSE-APACHE`). Workspace `Cargo.toml` declares
  `license = "Apache-2.0 OR MIT"`.
- **Workspace crates:** `engine`, `logic`, `wildbg-c`, `web`, `coach`,
  `benchmarks`. `crates/engine` uses `tract-onnx` (`= 0.23.4`) for inference.

## `native/wildbg-nets/neural-nets` — production neural nets

The wildbg **main** branch ships only weak *demo* nets
(`native/wildbg/neural-nets/contact.onnx` = 126 048 B,
`race.onnx` = 12 992 B). The **production** nets live on the repo's `nets`
branch and are vendored here so the engine can load strong play from disk.

- **Source branch:** `origin/nets`
- **Source commit:** `8c42b06f2ff4868431fc0372b2787e612537317d`
  - _"Copy data/0016/race.onnx and data/0017/contact.onnx from
    https://github.com/carsten-wenderdel/wildbg-training"_, 2025-10-14
  - i.e. contact from wildbg-training generation **0017**, race from
    generation **0016** (the latest generation on that branch).

| File | Size (bytes) | Source git blob |
| --- | --- | --- |
| `neural-nets/contact.onnx` | 751 988 | `fe5596b6d38640a92d2e83837ebdd9c872540320` |
| `neural-nets/race.onnx`    | 732 650 | `09f7db7d7fb678d8837f56afe5dbc1134fccf0b7` |

Extracted binary-exact via
`git cat-file blob origin/nets:neural-nets/<name>.onnx > …` (blob hashes and
byte sizes verified against `git ls-tree -l origin/nets`).

## Net filenames the engine expects

The engine references the fixed relative paths **`neural-nets/contact.onnx`**
and **`neural-nets/race.onnx`**. There are two distinct loading mechanisms:

1. **Compile-time bake (default constructor).**
   `crates/engine/src/onnx.rs` lines 97 & 118 use
   `include_bytes!("../../../neural-nets/race.onnx")` and
   `include_bytes!("../../../neural-nets/contact.onnx")` — resolved relative to
   `crates/engine/src/`, i.e. **`native/wildbg/neural-nets/`** (the submodule's
   own DEMO nets). `CompositeEvaluator::try_default()` →
   `OnnxEvaluator::contact_default()/race_default()` use this path, so a
   default-built engine embeds the *weak demo* nets at compile time.

2. **Runtime path load (parameterized).**
   `crates/engine/src/composite.rs` lines 84 & 94:
   `CompositeEvaluator::from_file_paths(contact_path, race_path)` and
   `…_optimized(…)` → `OnnxEvaluator::from_file_path(…)` /
   `from_file_path_optimized(…)` (`crates/engine/src/onnx.rs` lines 131 & 143)
   load `.onnx` files from arbitrary paths at runtime. wildbg's own coach
   binaries default these args to `"neural-nets/contact.onnx"` /
   `"neural-nets/race.onnx"`.

> **Consequence for the AIGammon shim:** to use the *production* nets vendored
> in `native/wildbg-nets/neural-nets/`, the shim MUST use the runtime path
> loader — build `CompositeEvaluator::from_file_paths(<...>/contact.onnx,
> <...>/race.onnx)` and wrap it with `WildbgApi::with_evaluator(evaluator)`.
> Do **not** call `wildbg_new()` / `WildbgApi::try_default()`, which bake the
> submodule's weak demo nets at compile time.

## Building on Windows

Sanity-build wildbg's C staticlib crate (from `native/wildbg`):

```powershell
cargo build --package wildbg-c --release
```

> **Host toolchain requirement:** Rust `stable-x86_64-pc-windows-gnu` alone is
> NOT enough. Its rustup *self-contained* MinGW ships `dlltool.exe`, `ld.exe`
> and a linker-only `gcc`, but **no GNU assembler (`as.exe`)**, so `dlltool`
> fails with `CreateProcess` while building import libraries (first hit in the
> `getrandom` crate, for `bcryptprimitives.dll`). A full **MinGW-w64** must be
> on PATH — this machine uses WinLibs (winget
> `BrechtSanders.WinLibs.POSIX.UCRT`, GCC 16.1.0). With it,
> `cargo build --package wildbg-c --release` completes (~2.5 min cold). A full
> MSVC Build Tools install would also work for the `-msvc` target.

## Cube advice: money game only

wildbg's `cube_info(position)` implements the Janowski cube formulas (including
too-good-to-double) but takes **no away scores** — its advice assumes a money
game. Only `best_move` is match-aware (via `BgConfig { x_away, o_away }`).
Consequently `engine_bindings`' `CubeAdvice` ignores match context; if the
tutor needs cube advice at a match score (score-dependent take points,
Crawford), a Dart Janowski + match-equity-table adapter must be built then.
Recorded in the engine-integration plan's deferred list.

## Build matrix

| Platform | Script | Status |
|---|---|---|
| Windows x64 | `engine_shim/build-windows.ps1` | Verified (dev machine) |
| Android (arm64-v8a, armeabi-v7a, x86_64) | `engine_shim/build-android.ps1` | Authored — verification deferred to Plan 3 (needs NDK) |
| iOS (device + sim XCFramework) | `engine_shim/build-ios.sh` | Authored — verification deferred to CI/macOS |

Inference is tract-onnx (pure Rust) — mobile builds carry no ONNX Runtime binaries.

