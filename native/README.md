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

> **`app/assets/nets/{contact,race}.onnx` are byte-identical copies of these**
> files (the Flutter app bundles them as assets, since tract loads nets from
> real filesystem paths). Keep them in sync when bumping the nets; a CI check
> could hash-verify the copies against these sources later.

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

## iOS (static linking into the Runner)

iOS forbids `dlopen`ing a dylib from an arbitrary path, so — unlike Windows
(`.dll`) and Android (`.so`), which the Dart loader opens by path — the engine is
linked **statically** into the app binary and its symbols are resolved at runtime
via `DynamicLibrary.process()` (see `libraryLoadStrategyFor` in
`packages/engine_bindings/lib/src/ffi/library_loader.dart`).

**Bundle id.** The iOS `PRODUCT_BUNDLE_IDENTIFIER` is **`com.xmelon.aigammon`**,
which deliberately diverges from the Android `applicationId`
(`com.xmelon.aigammon_app`): Apple's `CFBundleIdentifier` charset excludes
underscores, so the Android id would break signing / App Store submission. iOS and
Android are registered as separate apps in Firebase, so the ids need not match.

**Staticlib target.** The shim's `Cargo.toml` already declares
`crate-type = ["cdylib", "staticlib"]`, so the staticlib is a first-class build
target. CI builds it for the device ABI:

```bash
rustup target add aarch64-apple-ios
cargo build --release --target aarch64-apple-ios   # in native/engine_shim
# → target/aarch64-apple-ios/release/libaigammon_engine.a
```

(`native/engine_shim/build-ios.sh` additionally builds the simulator ABI and
packages an `.xcframework`; the CI device build above is all the `-force_load`
integration needs.)

**Where CI stages the `.a`.** The iOS CI workflow (`.github/workflows/ios.yml`,
authored in the next task) copies that `libaigammon_engine.a` to
**`app/ios/Frameworks/libaigammon_engine.a`**. That directory is kept in the tree
by a `.gitkeep`; the `.a` itself is a build artifact and is git-ignored
(`app/ios/Frameworks/.gitignore`), never committed.

**Why `-force_load`.** `app/ios/Flutter/Debug.xcconfig` and `Release.xcconfig`
each append:

```
OTHER_LDFLAGS = $(inherited) -force_load $(PROJECT_DIR)/Frameworks/libaigammon_engine.a
```

(`$(PROJECT_DIR)` resolves to `app/ios/`, so this is exactly the staged path.)
The engine's exported symbols — `wildbg_new_with_path`, `best_move`,
`probabilities`, `cube_info`, `wildbg_free` — are referenced **only** through
`dart:ffi` symbol lookups at runtime, never from Swift/ObjC or C at link time. To
the linker they look unused, so ordinary linking + dead-code stripping would drop
them and `DynamicLibrary.process().lookup(...)` would fail at launch.
`-force_load` forces every object file of the staticlib into the binary,
guaranteeing all shim symbols survive. (`-all_load` would work too but pulls in
every static library; `-force_load` scopes it to just ours.)

**Troubleshooting a CI link failure.** wildbg/tract-onnx is pure Rust with no C++
dependency, so no `-lc++` is needed and none is set. **If the CI link step fails
with undefined C++ symbols** (e.g. `std::__1::...`, `___cxa_*`, or `operator new`),
the first fix to try is adding `-lc++` (and, if a symbol like `res_9_init` shows
up, `-lresolv`) to the same `OTHER_LDFLAGS` line. libSystem is linked
automatically and needs no flag.

**Deployment target.** The scaffold's `IPHONEOS_DEPLOYMENT_TARGET` is Flutter's
default `13.0`, which is fine for the Rust staticlib (`aarch64-apple-ios`
defaults below that) — left unchanged.


---

## Nearby (LAN) play — platform notes

Nearby play (`packages/lan_play`) is pure `dart:io`: an `HttpServer` upgraded to
a WebSocket for the match, and a `RawDatagramSocket` on UDP **47777** for
discovery. No plugin is involved in the networking itself — only
`network_info_plus`, and only to display the host's Wi-Fi address.

### Android

**No manifest change is needed for the LAN feature.**

- `INTERNET` is what binding a socket and connecting to one requires, and it is
  already present: Flutter's tooling merges it in from
  `android/app/src/{debug,profile}/AndroidManifest.xml` for those variants, and
  the Play-published release variant gets it from the merged manifest of the
  plugins the app already depends on. If a future release build ever fails to
  open a socket, add `<uses-permission android:name="android.permission.INTERNET"/>`
  to `android/app/src/main/AndroidManifest.xml` — that is the single fix.
- **UDP broadcast needs no permission at all.** `CHANGE_WIFI_MULTICAST_STATE`
  (and a `WifiManager.MulticastLock`) is required only for **multicast** and for
  receiving *subnet-directed* broadcasts on some older devices; AIGammon's
  prober sends to `255.255.255.255` as well, which is delivered without a lock,
  and its beacon binds the wildcard address. Nothing here needs
  `ACCESS_FINE_LOCATION` either — that is a Wi-Fi *scanning* permission, and the
  app never scans.
- `network_info_plus` merges in `ACCESS_WIFI_STATE` on its own. `getWifiIP()`
  needs no runtime prompt (only `getWifiName()` would, and it is not used).

### iOS

- **`NSLocalNetworkUsageDescription` is set** in `app/ios/Runner/Info.plist`.
  Since iOS 14 the *first* local-network access raises a system prompt carrying
  that string; denying it makes both discovery and the direct TCP connection
  fail, so the copy has to be honest about what the feature does.
- **The multicast-entitlement caveat.** Apple gates *broadcast and multicast*
  traffic behind the special-request entitlement
  `com.apple.developer.networking.multicast`. Without it an iOS build can still
  **receive** the answers to its own probes in most configurations, but
  **sending** to `255.255.255.255` may be silently dropped — so automatic
  discovery is Android-first by design and must be treated as best-effort on
  iOS.
  - **The fallback is always available and always works:** the JOIN tab's
    "Enter address" form takes the `IP:port` the HOST tab displays plus the room
    code, and that is a plain outbound TCP connection — no entitlement, no
    broadcast, nothing to request.
  - To enable reliable discovery on iOS later: request the multicast entitlement
    from Apple (a manual form, granted per Team ID), add
    `com.apple.developer.networking.multicast` to `Runner.entitlements`, and add
    `_aigammon._tcp` to `NSBonjourServices` if the discovery mechanism is ever
    switched from raw UDP to Bonjour/`NSNetService` (which is the better path on
    iOS, and needs no multicast entitlement).
- Nothing about the LAN feature affects the FFI/static-linking setup documented
  above.

### Desktop

Windows raises a firewall prompt the first time the host binds its port. Tests
never trigger it: every socket test in `packages/lan_play` binds loopback, and
the discovery tests probe a loopback target rather than a broadcast address.
