# Changelog

All notable changes to AIGammon are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is the one in `app/pubspec.yaml`; the `+n` build number after it is
set by CI from the workflow run number and is not tracked here.

> **Seeded retroactively.** Releases 0.1.0 through 0.12.0 predate this file and
> were reconstructed from the merge commits and version bumps in `git log`. They
> are summaries of what each release was *about*, not exhaustive lists — the
> commit history is the record of record for anything older than the Unreleased
> section. No git tags exist for them either; see "Releasing" in the README for
> the tagging convention that starts with the next release.

## [0.13.0] — 2026-08-01

Production readiness: crash visibility, Firebase telemetry, a sweep of live
correctness/performance/robustness bugs found by a full-codebase review, and a
`game_screen.dart` split — verified with a full test matrix, the whole Firebase
emulator pipeline, and a security-lensed review of every trust-boundary change.

### Added

- Real Android release signing, obfuscated builds with uploaded debug symbols,
  and an on-device crash log (Settings → Diagnostics) that survives even a
  release build with no network.
- Firebase Analytics, Performance Monitoring and Crashlytics — guarded to
  mobile only, Windows/Linux/macOS never attempt Firebase init. Crashlytics is
  an additional sink alongside the on-device log, not a replacement.
- A "Send feedback" button that opens a pre-filled GitHub issue.
- Golden image comparisons now run in CI, on a Windows runner (they previously
  ran nowhere automated).
- `cargo fmt --check`, `clippy` and `cargo test` run in the `engine` CI job; the
  Rust shim's unit tests and its production-net smoke test had never run outside
  a developer's machine.
- Firestore security rules run as their own fast CI job, ahead of the emulator
  E2E legs.
- Board accessibility: the board announces whose turn it is and what the roll is,
  banners are live regions, and the score sheet's mark dot has a text label.
- Screen-reader-friendly semantics and the tutor setting are honoured in LAN and
  online play.

### Changed

- Android release builds ship **per-ABI APKs** (`arm64-v8a`, `armeabi-v7a`)
  instead of one universal APK, and no longer cross-compile the emulator-only
  `x86_64` ABI at all.
- The ML Kit barcode model used by the QR-join scanner is unbundled from the APK
  and fetched by Play services on first use.
- `ndkVersion` is pinned literally in `app/android/app/build.gradle.kts` to the
  revision CI installs.
- `firebase-tools` is pinned to a major.minor in CI instead of tracking `latest`.

### Fixed

- Numerous correctness, performance and robustness fixes from the production
  readiness review — bounded engine calls, a wedged-worker path that is counted
  rather than wished away, roll-write and seat-wait backoff, relay log bounds,
  and Firestore write-channel closure at match end.
- `firebase/DEPLOY.md` priced the lobby poll wait in cycles where it meant reads,
  understating it twofold.
- iOS CI no longer prints the signing team id, provisioning profile name or
  profile UUID into the build log.

### Removed

- `firebase/smoke.js`, dead emulator scaffolding from the first online-play plan.

## [0.12.0] — 2026-07-30

### Added

- Join a nearby game by scanning the host's QR code (Play Nearby).

## [0.11.3] — 2026-07-30

### Fixed

- A guest that received frames before its board was open dropped them; the join
  could stall on "connecting".

## [0.11.2] — 2026-07-30

### Fixed

- LAN join deadlock and a guest-roll stall, both found in live two-device
  testing.

## [0.11.1] — 2026-07-30

Test release: all suites and the emulator pipeline verified green against the
production Firebase project.

## [0.11.0] — 2026-07-30

### Changed

- LAN and online play unified onto **one trust model, one match controller and
  two transports** (sockets, Firestore). The separate host-authority path is
  gone.
- Firestore online play moved from polling to **real-time listeners**, with the
  poll loop kept as the documented fallback.

## [0.10.0] — 2026-07-27

### Added

- **Serverless online play** on Firebase's free Spark plan: Firestore documents,
  security rules and anonymous auth, with no Cloud Functions and no billing
  account. Dice are agreed by a commit-reveal handshake between the two clients,
  and each client validates the other's events with the full rules engine,
  freezing the match on a proven violation.

## [0.9.0] — 2026-07-26

### Added

- **Play Nearby**: LAN multiplayer over sockets with host discovery.
- Tabletop hot-seat mode.

## [0.8.0] — 2026-07-26

### Changed

- Dice presentation rework, cubeless-match UI, header consolidation, a
  pass-device setting, auto-pass on a dance, and a discoverable surrender flow
  (UX round 6).

## [0.7.1] — 2026-07-26

### Fixed

- Move-entry decompositions, the roller-pair dice beat, a gesture dead zone, the
  bear-off offer filter, and a highlight glow that misled.

## [0.7.0] — 2026-07-26

### Changed

- The score sheet became a permanent two-column panel (UX round 5).

## [0.6.1] — 2026-07-26

### Fixed

- Double-tap safety, a roll guard, and banner hit-testing (UX round 4).

## [0.6.0] — 2026-07-26

### Changed

- Hands-on UX review round plus production polish.

## [0.5.0] — 2026-07-25

### Added

- **iOS pipeline**: the engine is built as a staticlib and linked into `Runner`,
  with a CI path to an unsigned `.app` and a secret-gated signed IPA.
- UX round 3.

## [0.4.0] — 2026-07-25

### Changed

- UX feedback round 2: animation pacing, a history strip with scores, drag-to-move
  on by default, and a contrast overhaul.

## [0.3.0] — 2026-07-25

### Added

- UX round 1: full-width board with bear-off trays, checker-anchored selection,
  drag-to-move and combined-move taps, an in-game move history panel, an opponent
  dice-roll beat, gameplay option toggles including cubeless matches, and online
  match history with a post-match analysis entry point.

## [0.2.0] — 2026-07-25

### Added

- **Tutor**: live move assessment, move marks and a cube-advice overlay, on a
  match-equity table (Kazaross-XG2) and a Janowski cube-life model.
- **Persistence**: Drift-backed match and event-log storage, post-game analysis,
  match history and a replay screen.
- Match-aware AI cube decisions and an equity-based resign policy.
- Checker movement animations, tap-to-apply hints, and a settings screen.

## [0.1.0] — 2026-07-24

### Added

- First playable build: the pure-Dart `backgammon_core` rules engine, the
  vendored **wildbg** neural-net engine behind a Rust C-ABI shim and Dart FFI
  bindings, and a Flutter app playing a full match against the AI.
- Android CI with Firebase App Distribution.
