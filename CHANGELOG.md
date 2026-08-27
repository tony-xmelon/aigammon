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

## [0.14.0] — 2026-08-27

**Buddy Mode**: play on your real board against the engine, with the phone
propped up watching. Its perception core is a new pure-Dart package scored
against a committed corpus of real board photographs, so a perception
regression fails CI exactly like a rules regression. CI has no camera, so the
mode's true acceptance test is a scripted on-device run —
[`docs/buddy-mode-test-protocol.md`](docs/buddy-mode-test-protocol.md).

### Added

- **Buddy Mode** (Android/iOS): a guided calibration teaches Buddy your board —
  drag the handles onto the corners of the felt (four more on the seam for a
  folding case) and confirm the belief it draws over the starting position. It
  learns *your* board's checker, felt and point colours from those thirty
  checkers; **no colour constants exist anywhere in the pipeline**.
- **You type the roll; Buddy reads the play.** The three-tap dice pad is the
  shipping dice path and is always open — the Phase-1 gate settled that
  (outcome (b)), so it is the path rather than a fallback. The camera's dice
  reader is queued rather than shipped, and what it does today is **decline
  rather than misread**: on the real corpus it found no pair on any of the
  four frames carrying a certified roll, and read none of them wrong. This
  board's dice are 0.021 of it across, and the band-location and tilt work
  that would let a die that small be found is scheduled, not done.
- Buddy reads your **plays** off the felt — 6 of 6 play identification on the
  real corpus — and speaks both sides of the table ("You rolled 6-3." … "I
  rolled 5-2 — play 13/8, 24/22."), acknowledges a legal play, **objects to an
  illegal one with the reason**, offers a choice when two plays look the same,
  and names the checker you put in the wrong place until the board matches.
  Every spoken line is mirrored on screen.
- A **readability light** evaluated on every stable frame for the whole
  session, not only when an answer is wanted: it names its cause ("It is too
  dark to read the board", "The board is not where it was when I learned it"),
  speaks the drop to red **once** rather than nagging, and routes a moved board
  or a shifted light straight into recalibration — which reopens on the corners
  with the handles already where they were. The match resumes exactly where it
  paused; a readability outage never touches the game state.
- Cube play by voice ("I double — take or drop?") with the on-screen Double
  button under the digital game's gating rules, Crawford included; dances,
  game and match results announced; the finished match lands in **History**
  with post-game analysis through the standard persistence path.
- Fallbacks are always one tap away: tap the play out on the belief mirror
  when the felt is not read, and the dice pad is live throughout — it is the
  dice path proper rather than a fallback, and it answers the user, so it
  stays open even through a readability outage. Repeated misplacements
  escalate to the mirror with the discrepancy highlighted — the board Buddy
  believes in, at full size, with a ring on each region the play touched and
  the camera disagrees about, and the contradiction named in words. That
  escalation has **two ways out**: *I've fixed it*, which hands the question
  back to the camera, and *Skip this check*, which is the user overruling it —
  the board is right and Buddy cannot see it, which the real corpus says
  happens. A skip is spoken with a caveat ("I'll take your word for it…") and
  counted, because how often it is needed is the field measure of the one
  perception target still short.
- An **optional microphone hint**: Buddy hears the dice land and looks sooner.
  It is an optimization, never a dependency — the mode plays identically with
  the permission refused, and **nothing is recorded**: the audio never leaves
  the device, never reaches a file, and is reduced to one number per 16 ms and
  dropped. Camera and microphone are asked for in context, beside the thing
  they are for.
- Two settings (Settings → Buddy Mode): how Buddy words a play out loud
  (**terse** "13/8, 24/22" or **friendly** "Move one checker from 13 to 8"),
  and whether it listens for the dice.
- [`packages/board_vision`](packages/board_vision) — the perception core, pure
  Dart with no camera and no Flutter so its suite runs in CI: homography and
  the ROI atlas, calibration and colour learning, occupancy and dice reading,
  state-primed legal-play matching, expected-board verification and drift
  recovery, and continuous readability. Its tests score the committed corpus
  against accuracy thresholds.
- Buddy telemetry through the existing analytics seam — sessions started and
  ended, calibration attempts, recalibrations entered, per-fallback counters
  and a readability-red rate — which is what decides where perception effort
  goes after launch.
- Buddy Mode releases the camera when the app goes to the background and takes
  it back on resume, rejoining the match exactly where it was — Android
  reclaims the camera from a backgrounded app, and a phone propped over a board
  for a whole match will be interrupted.
- [`docs/buddy-mode-test-protocol.md`](docs/buddy-mode-test-protocol.md), the
  scripted on-device acceptance run: the eight things that ship as arithmetic
  rather than measurement, then a calibration and a match with twelve
  checkpoints.

### Changed

- Windows desktop builds now need the **NuGet CLI** (`nuget.exe`) on `PATH`.
  Buddy Mode's `flutter_tts` dependency ships a Windows plugin that shells out
  to NuGet and hard-fails without it. Nothing on Windows ever calls it — Buddy
  Mode is mobile-only and guarded — but Flutter offers no way to exclude a
  plugin from one platform's build. See the toolchain section of the README.

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
