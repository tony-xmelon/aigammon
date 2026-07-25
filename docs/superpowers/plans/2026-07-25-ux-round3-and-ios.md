# UX Feedback Round 3 + iOS Implementation Plan (Plan 9)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address the v0.4.0 feedback: persistent per-player dice pairs, no replay-animation of the user's own moves, and an iOS build pipeline set up for distribution.

**Verbatim feedback (2026-07-25):**
1. "the opponent dice is still not perceivable for a human. let's add a second pair of dice, one white and one black pair, so each dice is constantly visible."
2. "after I move / drag the chips, you replay the move animation. Do not."
3. "let's build the iOS version as well and set it up for distribution"

**Environment:** as Plan 8 (suites: core 118, bindings 39+17, online 37+18, app 300+1skip). Branch: `feature/ux-round3-ios`. No macOS hardware locally — iOS builds validate on GitHub Actions macos runners only.

---

### Task 1: Dual persistent dice pairs (F1)
`board_geometry.dart` + `board_painter.dart` + `board_theme.dart` + `game_screen.dart`/`board_view.dart`:
- TWO dice pairs always on the board: a WHITE pair (white bodies, dark pips) and a BLACK pair (dark bodies, light pips), one per player, each persistently showing that player's most recent roll — so the opponent's roll stays readable for the whole turn, not just during the beat. Before a player's first roll of a game, their pair renders as empty/blank placeholders (dimmed).
- Placement mirrors a real board: mover-side pair in the RIGHT half between bar and home, other pair in the LEFT half (orientation-aware with board flip). Geometry adds `diceRect(Player)`.
- Active-mover emphasis: the current mover's pair full-opacity; the waiting player's pair dimmed (theme-driven dim factor, must still pass legibility eyeballing on goldens). Used-die indication (if present today) stays on the active pair only.
- Roll beat (Plan 8) animates ONLY the roller's pair; the other pair stays static.
- Theme: dice colors per player derived from checker palette (white dice = white checker fill/dark pips, black dice = black checker fill/light pips + rim treatment consistent with Task-4-P8 silhouette rules). Extend `board_contrast_test.dart` with pip-vs-die-body assertions for both pairs on both themes.
- Data: painter needs `whiteDice`/`blackDice` (+ mover) instead of single `dice`; GameScreen tracks last roll PER PLAYER from RollEvents (survives across the turn; reset on new game). `diceOverride` from the beat applies to the roller's pair.
- Tests: painter fields + shouldRepaint; per-player persistence across turns (widget test: after opponent's turn ends, their dice still show the roll); goldens regenerated + visually verified (READ the PNGs).

### Task 2: Never replay the local player's own move (F2)
`game_screen.dart` (`_stagedMove` feed) + `board_view.dart`:
- Root cause: every committed move is fed to BoardView as `externalMove`, which animates it — including moves the user just entered by tap/drag on this very board. The user already SAW their move happen; replaying it is noise.
- Fix: only stage a move for animation when it was NOT entered interactively on this device's board: AI moves and remote (online) opponent moves animate; local human moves (vs-AI human side, BOTH sides in hot-seat) never do. The cleanest signal: GameScreen knows each side's `PlayerAgent` type / interactivity — gate `_stagedMove` on the mover being non-interactive. Verify the hint "tap-to-apply" path (tutor applying a suggested move programmatically) — that one SHOULD still animate (the user did not hand-enter it); preserve by gating on entry-source rather than player identity if needed.
- Tests: widget test — human commits via taps: no move animation runs (probe BoardView overlay/animation state); AI reply still animates; hint-apply still animates; online remote move still animates (fake controller).

### Task 3: iOS project scaffold + engine FFI wiring (F3a)
- `flutter create --platforms=ios .` in `app/` (keeps existing lib/). Set bundle id `com.xmelon.aigammon` (match Android applicationId — verify actual value in `app/android/app/build.gradle.kts` and mirror it).
- Engine linking: iOS forbids runtime-loaded dylibs from arbitrary paths; link `libaigammon_engine.a` statically into the Runner and load symbols via `DynamicLibrary.process()`/`DynamicLibrary.executable()`:
  - `packages/engine_bindings` loader: platform switch — Windows/Android keep `DynamicLibrary.open(...)`; iOS/macOS use `DynamicLibrary.process()`. Unit-testable via a loader-strategy function.
  - Xcode wiring WITHOUT a Mac: hand-author the pieces (they're plain text): add `ios/Flutter/Engine.xcconfig` fragment or edit `Release.xcconfig`/`Debug.xcconfig` with `OTHER_LDFLAGS = $(inherited) -force_load $(PROJECT_DIR)/Frameworks/libaigammon_engine.a` (exact path per CI staging step), ensuring symbols survive dead-code stripping. CI validates.
- Nets: `nets_installer.dart` copies bundled assets to documents — verify path logic is platform-neutral (no Android-isms); nets ship as Flutter assets already, nothing iOS-specific expected.
- Tests: loader-strategy unit test; `flutter analyze` still clean. Real proof is Task 4's CI build.

### Task 4: iOS CI workflow + distribution wiring (F3b)
`.github/workflows/ios.yml`, macos-latest runner:
- Triggers: `workflow_dispatch` + push to `master` + push to `feature/ux-round3-ios` (dev trigger — REMOVE the feature-branch trigger in the final commit before merge).
- Steps: checkout w/ submodules; rustup with `aarch64-apple-ios` target; `cargo build --release --target aarch64-apple-ios` in `native/engine_shim`; stage `libaigammon_engine.a` where the xcconfig expects it; flutter-action stable; `flutter build ios --release --no-codesign --build-number=${{ github.run_number }}` (+ the same online dart-defines pattern as android.yml); package `build/ios/iphoneos/Runner.app` as an artifact zip.
- Distribution (signed IPA) is SECRET-GATED, mirroring android.yml's pattern: when Apple signing secrets exist (`IOS_CERT_P12_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `FIREBASE_IOS_APP_ID`), import cert to a temp keychain, install profile, re-build signed, export IPA, distribute via wzieba Firebase action to `testers`; else print the skip message pointing at docs.
- Iterate on the feature branch until the unsigned build is GREEN (expect several rounds — Xcode/pod quirks; use `gh run watch`, read failure logs, fix, push).
- Docs: `.github/workflows/README.md` + a new "iOS distribution" section in `firebase/DEPLOY.md`: user-required steps — Apple Developer Program enrollment ($99/yr), creating an iOS app in the Firebase console (bundle id must match), certificate + ad-hoc provisioning profile (tester device UDIDs) OR the TestFlight alternative (App Store Connect API key), and exactly which GitHub secrets to add. Be explicit that WITHOUT these secrets CI produces an unsigned .app artifact only — iPhones cannot install it; signing is the user-gated step.

### Task 5: Verify, review, merge, ship v0.5.0
Full local matrix + green iOS AND Android workflows, whole-branch review vs the 3 feedback items, remove the dev branch trigger from ios.yml, bump version 0.5.0+5, merge → push, memory update, feedback→resolution report incl. the explicit "what you must do for iOS distribution" list.
