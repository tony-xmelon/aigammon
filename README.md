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
- **Match play** to N points with the **doubling cube**, gammon/backgammon
  scoring, and the **Crawford** rule.
- **Tutor mode** — a read-only coaching overlay during play: live **hints**
  (ranked candidate moves), per-move **marks** (best / good / dubious / error /
  blunder) with the **equity loss** versus the engine's best move, and
  **match-aware cube advice** that respects the score via a match-equity table
  (MET) and a Janowski cubeful-equity advisor rather than money-game odds.
- **Match history + post-game analysis** — finished matches are saved and can be
  replayed move by move; a background pass replays the event log through the
  engine to flag **blunders** and summarise cube/checker errors.
- **Local persistence** — matches and their event logs are stored on-device with
  **drift/SQLite**; cached analysis lives alongside them.
- **Online play** over Firebase, **serverless** — **create** a match to get a
  short **invite code**, or **join** an opponent's match by code; the match is
  an append-only Firestore event log both clients fold. Dice come from a
  **commit-reveal handshake** between the two clients, so neither can bias the
  RNG without the other seeing it, and each client re-checks every event the
  other writes with the full rules engine — a proven violation **freezes** the
  match rather than being quietly accepted. The whole backend is one security
  rules file, which runs against the **Firebase Emulator Suite** for offline
  development; a two-client full-match end-to-end test (with adversarial legs)
  verifies it there. Frames arrive over Firestore's **real-time listener**
  (gRPC `Listen`), with the **poll loop kept as a fallback** for a network that
  cannot open the stream. See
  [**Deploying online play**](#deploying-online-play) below.
- **Play Nearby (LAN)** — two devices on the same Wi-Fi, no internet and no
  account: one hosts (UDP discovery beacon + a WebSocket relay), the other joins
  from a discovered list, by typing the room code, or by **scanning the host's
  QR code** (the host shows one; address, port and code travel together, so
  there is nothing to read out loud). It runs the **same** commit-reveal dice
  and the same mutual validation as online play, because both go through one
  **`MatchTransport`** seam and one match controller — the host binds a socket,
  it does not referee the game.
- **Tabletop hot-seat** — two players, one device, passing it between turns.

See [`docs/superpowers/plans/`](docs/superpowers/plans/) for the per-phase plans,
and the
[architecture design](docs/superpowers/specs/2026-07-24-aigammon-architecture-design.md)
for the ORIGINAL v1 design (its networking chapters predate the current
serverless, one-controller architecture — see the banner at the top of that
file).

## Repository layout

| Path | What it is |
|---|---|
| [`app/`](app/) | The Flutter app — UI (`CustomPaint` board), Riverpod state, `GameController`, screens (home, new match, game, history, post-game analysis), the tutor overlay (`app/lib/tutor/`), and drift persistence (`app/lib/data/`). |
| [`packages/backgammon_core`](packages/backgammon_core) | Pure Dart rules engine — zero dependencies. `BoardState`, `GameState`, `MatchState`, move generation, event-sourced game log, gnubg Position IDs. |
| [`packages/engine_bindings`](packages/engine_bindings) | `dart:ffi` bindings + an isolate-hosted `EngineService` over the native library: move ranking, evaluation, difficulty sampling, and match-aware cube advice (`MatchCubeAdvisor` — Janowski cubeful equities over a Kazaross-XG2 match-equity table). |
| [`packages/match_transport`](packages/match_transport) | The `MatchTransport` seam both multiplayer modes run on: the interface and its normative fold/resync contract, the shared wire frames, the commit-reveal fair-dice protocol, an in-memory reference transport, and `transport_contract.dart` — the contract as a reusable suite, run against all three implementations. |
| [`packages/lan_play`](packages/lan_play) | Play Nearby over a LAN — UDP discovery, a WebSocket host server + guest client, the JSON wire protocol, and `SocketTransport` (host and guest halves) over a dumb append-only relay. No game authority anywhere. |
| [`packages/online_client`](packages/online_client) | Firebase-backed online-play client — pure Dart, no Firebase SDK: anonymous auth and direct Firestore documents over REST (match create/join by invite code, append-only event log), plus `FirestoreTransport` on Firestore's **real-time `Listen` gRPC stream with a polling fallback**. Runs against the emulator in tests. |
| [`firebase/`](firebase/) | The online backend, which is **only** Firestore security rules (`firestore.rules`) — no Cloud Functions, free Spark plan — plus their emulator rules-test suite, emulator config, and the deploy guide ([`DEPLOY.md`](firebase/DEPLOY.md)). |
| [`native/wildbg`](native/wildbg) | The vendored [wildbg](https://github.com/carsten-wenderdel/wildbg) engine — a **git submodule**, never edited directly. |
| [`native/engine_shim`](native/engine_shim) | Thin C shim (`cdylib`, `aigammon_engine`) — a verbatim copy of wildbg's `wildbg-c` crate plus a `wildbg_new_with_path` constructor that loads nets from disk at runtime. Windows/Android/iOS build scripts live here. |
| [`native/wildbg-nets`](native/wildbg-nets) | The **production** neural nets (`contact.onnx`, `race.onnx`) from wildbg's `nets` branch. The submodule itself ships only weak demo nets. |
| [`docs/superpowers/`](docs/superpowers/) | Architecture spec and the per-phase implementation plans. |
| [`.github/workflows/`](.github/workflows/) | CI (`ci.yml`), the Android APK workflow (`android.yml`) and the iOS `.app`/IPA workflow (`ios.yml`) — the latter two gated on CI passing, both distributing through Firebase App Distribution. See [`.github/workflows/README.md`](.github/workflows/README.md). |

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
- **NuGet CLI** (`nuget.exe`) on `PATH` — `winget install Microsoft.NuGet`.
  Buddy Mode's `flutter_tts` dependency ships a Windows plugin whose
  `CMakeLists.txt` shells out to NuGet for CppWinRT and hard-fails without it,
  so a desktop build stops at `nuget.exe not found. Please install it.` before
  compiling a line of app code. Nothing on Windows ever *calls* that plugin —
  Buddy Mode is mobile-only and `lib/buddy/speaker.dart` guards it — but
  Flutter offers no way to exclude a plugin from one platform's build, so the
  Windows toolchain has to satisfy it.
  - Buddy Mode's **`record`** dependency (the dice-sound attention hint) is the
    same shape of dependency and needs **nothing extra**: `record_windows`
    builds against the Windows SDK's own Media Foundation headers and calls no
    `find_program`. It does ask for CMake ≥ 3.23, which the CMake bundled with
    Visual Studio 2022 satisfies. Like the voice, the microphone is never
    reached on Windows — `lib/buddy/dice_sound_trigger.dart` guards it — but
    the plugin is still registered and compiled into a desktop build.
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
# Pure Dart rules
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

## Deploying online play

Online play runs on **Firebase's free Spark plan** — Firestore documents,
security rules and anonymous auth, with **no Cloud Functions and no billing
account**. There is no server: dice are agreed by a commit-reveal handshake
between the two clients, and each client validates the other's events with the
full rules engine, freezing the match on a proven violation. Debug builds
default to the **local emulator suite** — no configuration needed; start it from
`firebase/` and `flutter run`. To run the full online test matrix locally:

```powershell
pwsh firebase/run-emulator-tests.ps1
```

Creating the project, enabling anonymous sign-in, deploying the rules
(`firebase deploy --only firestore:rules`), retrieving the Web API key, and
building a production release with the online defines are documented in
[`firebase/DEPLOY.md`](firebase/DEPLOY.md).

## Continuous integration

- **`ci.yml`** (push to `master`, all PRs) runs:
  - **`packages`** (Linux, matrixed over `backgammon_core`, `lan_play`,
    `match_transport`): `dart analyze --fatal-infos` + `dart test` each.
    `lan_play` runs under its `ci` preset, which retries twice — it is the only
    suite here that binds real sockets.
  - **`engine`** (Linux): `cargo fmt --check`, `clippy`, the Rust shim's own
    tests, then the cdylib build followed by `dart test` and
    `dart test -P engine` against the real `.so`.
  - **`app`** (Linux): `flutter analyze` + `flutter test -x golden`.
  - **`goldens`** (Windows): `flutter test --tags golden`. A Windows runner
    because the golden PNGs are Windows-generated and Linux antialiasing drifts
    just enough to need a tolerance that would hide real regressions.
  - **`rules`** (Linux): emulator leg 1 — the `firestore.rules` unit tests
    (mocha, `@firebase/rules-unit-testing`) against a firestore-only emulator.
    Seconds, and FIRST: `online` `needs:` it, so a broken rules file is red
    before four toolchains are installed.
  - **`online`** (Linux): `online_client` analyze + unit tests, then emulator
    legs 2–4 inside one `firebase emulators:exec` — `online_client -P emulator`
    (the REST transport against the real rules), the app's two-client E2E on the
    real-time listener path, and that same E2E once more with the listener
    forced off so the poll fallback is actually exercised.
- **`android.yml`** (`workflow_dispatch`, CI success on `master`):
  cross-compiles the engine for the two device ABIs with `cargo-ndk`, builds
  per-ABI release APKs, and — when the Firebase secrets are configured —
  distributes the `arm64-v8a` one to testers via Firebase App Distribution.
- **`ios.yml`** (`workflow_dispatch`, CI success on `master`): builds the engine
  staticlib for `aarch64-apple-ios`, links it into `Runner`, and uploads an
  unsigned `Runner.app`; when the signing secrets are configured it also builds
  a signed ad-hoc IPA and distributes it to the same testers group.
- Setup instructions for both distribution workflows, and the debug-symbol
  artifacts every release build uploads:
  [`.github/workflows/README.md`](.github/workflows/README.md).

## Releasing

Every release is a merge to `master` that bumps `version:` in `app/pubspec.yaml`
and adds a section to [`CHANGELOG.md`](CHANGELOG.md). From v0.13.0 onward it also
gets an **annotated tag**:

```bash
# on master, at the merge commit
git tag -a v0.13.0 -m "AIGammon v0.13.0 — <one line, the same one the merge used>"
git push origin v0.13.0
```

Annotated (`-a`), not lightweight: an annotated tag is a real object carrying a
tagger, a date and a message, so `git describe` names builds sensibly and the
release's own summary survives independently of the merge commit. The name is
`v` + the exact `pubspec.yaml` version, with no build number — the `+n` suffix is
CI's run counter and changes on every rebuild of the same source.

Releases before v0.13.0 are **not** tagged retroactively. Their merge commits all
carry the version in the subject line (`Merge feature/… (v0.11.0)`), which is
enough to find them, and inventing tags after the fact would put dates on objects
that never had them.

Gating `android.yml` on `pubspec.yaml`'s version matching the tag was considered
and **deferred**: that workflow is already gated on `workflow_run` from CI and
checks out `workflow_run.head_sha`, and a tag-equality check on top of that has
to answer what a `workflow_dispatch` run — which has no tag — should do. It is
worth doing once tagging has actually been in use for a few releases.

## Licensing

The vendored **wildbg** engine (and the `engine_shim` copy of its `wildbg-c`
crate) is dual-licensed **MIT OR Apache-2.0**; **this repository's own license is
not yet chosen — TODO for the owner.**
