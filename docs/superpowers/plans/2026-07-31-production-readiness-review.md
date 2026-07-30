# Production Readiness Review Implementation Plan (Plan 18)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Full code review across all six packages + CI/CD + Firebase + docs. Fix genuine production blockers, real correctness/perf bugs, and maintainability debt; leave documented trade-offs alone. Ship as v0.13.0.

**Method:** Five parallel read-only audits already completed (core+AI, networking, app UI/state, release infra, CI/CD+docs+Firebase). This plan organizes their ~60 findings into priority-ordered tasks. Each task follows the established pattern: implementer + spec/quality reviewer, full suites, then whole-branch review before merge.

**Scope discipline:** many findings are trivial doc fixes or already-accepted trade-offs explicitly noted by the auditors as "no action needed" — those are folded into the doc-cleanup task, not given individual ceremony. Do NOT use this plan as license to rewrite working, well-tested code beyond what a finding actually justifies.

---

### Task 1: Production blockers — signing, crash visibility, CI safety net
- **Release signing** (`app/android/app/build.gradle.kts`): generate an upload keystore, base64 into a new repo secret, `key.properties` step in `android.yml`, real signing config. Delete the stale scaffold TODOs.
- **Crash/error observability**: `FlutterError.onError` + `PlatformDispatcher.instance.onError` in `main.dart` at minimum (rolling on-device log + share-diagnostics affordance); isolate errors from `EngineService` need an explicit `Isolate.addErrorListener` since they don't reach the zone handlers. Decide inline whether to add `firebase_crashlytics` now or defer (note: adds a plugin + NDK symbol upload for the Rust `.so` — reasonable to defer to a follow-up if the on-device-log MVP covers the immediate gap; the audit's "minimum viable" framing applies).
- **Release build symbols**: `--obfuscate --split-debug-info=<dir>` in both `android.yml`/`ios.yml` release builds; upload the symbols directory as a build artifact keyed by run number.
- **CI hardening**: `permissions: contents: read` at workflow level on all three workflows; `concurrency: {group, cancel-in-progress: true}`; `timeout-minutes` per job. Pin `wzieba/Firebase-Distribution-Github-Action` to a commit SHA (not `@v1`). Gate `android.yml`/`ios.yml` distribution on `ci.yml` passing (`workflow_run` or equivalent) — a broken master must not reach testers.
- Tests: exercise what's testable (the manifest/signing-config presence can be asserted the way `android_manifest_test.dart` already does for permissions — extend that pattern).
- **Commit(s):** logical grouping per sub-area.

### Task 2: Live correctness bugs
- **`canonicalPlay` order-dependent corruption** (`packages/backgammon_core/lib/src/game_state.dart:289`): the transit-decomposition fallback applies the submitted hop order to `applyMove` before normalizing — same corruption class as the P3/P13 fixes, reachable from remote peers/persisted logs. Normalize before applying (or compare via `legalVariants` decompositions). Add the reversed-transit-chain regression case.
- **Roller's own `TransportRejected` retried forever** (`app/lib/net/net_match_controller.dart` `_rollerSteps`, `createRoll`/`sendReveal`): mirror `_witnessSteps`' correct `TransportRejected` handling — mark done, surface, stop. This is a live infinite-write loop against a metered backend.
- **Firestore rules: events/rolls writable after match completion** (`firebase/firestore.rules`): add `matchOf(code).status == 'active'` to both `create` rules; add the missing participant-write tests for waiting/completed matches (currently unspecified, not just untested). Correct `DEPLOY.md`'s "most expensive thing" claim once fixed.
- **Connect() errors swallowed silently** (`app/lib/screens/online_screen.dart`, `lan_screen.dart`): read `controller.error` on the bail path and surface it — currently the spinner just stops with nothing shown.
- **`_launching` never cleared on LAN host bail path** (`lan_screen.dart`): same "stuck forever" class already fixed twice live; close this one before it bites too.
- **Guest transport adopts a session from a formally-rejected welcome** (`packages/lan_play/lib/src/socket_transport.dart` `connect()`): must fail with `TransportRejected` instead of silently priming from an empty mirror.
- **`MatchRelay` unbounded roll documents + silently-dropped oversized welcome** (`packages/lan_play/lib/src/match_relay.dart`, `guest_client.dart`): bound `n` to a sane window, cap the roll map, refuse/truncate at encode time rather than letting the peer's decoder drop it with no diagnosis.
- **`FirestoreTransport.connect()`'s unbounded flat-2s guest-seat poll** (`packages/online_client/lib/src/firestore_transport.dart`): add the same backoff+ceiling `online_screen.dart`'s lobby wait already has, or make a filled seat a precondition.
- Tests: failing-first for every item above, per this project's established discipline.
- **Commit(s):** one per bug, or tight logical groups.

### Task 3: Performance
- **`chainedDestinationsFor` recomputed from scratch on every drag frame** (`packages/backgammon_core/lib/src/move_builder.dart`): memoize per (prefix, source); the drag-frame call site is `app/lib/board/board_view.dart`.
- **`_syncAssessment` O(n²) replay per move** (`app/lib/screens/game_screen.dart`): keep a running `GameState`/prefix cache instead of `Game.replay`-ing from scratch per assessed move.
- **Doubles search `TODO(perf)`** (`packages/backgammon_core/lib/src/move_generator.dart`): memoize `(dice-remaining, signature)`; replace the string signature with a packed int/`Uint8List` key.
- **`canonicalPlay`'s per-legal-move board allocation** (`game_state.dart`): use the existing packed hop-set key instead of allocating a `BoardState` + sorting strings per comparison.
- **Over-rebuild on every controller notification** (`game_screen.dart`): memoize `buildScoreSheet`/`persistentDice` on `events.length`; scope score sheet + HUD into their own `ListenableBuilder`s.
- Tests: perf-sensitive changes get a correctness regression test (memoization must not change output) — no benchmark harness needed, this project doesn't have one and adding one is out of scope.
- **Commit(s):** one per item.

### Task 4: Robustness / error handling
- **MET bounds unguarded** (`packages/engine_bindings/lib/src/match_cube_advisor.dart`): clamp to `MatchEquityTable.maxAway` in `matchEquityAfter` rather than throwing on a peer-supplied long match length.
- **`EngineService` no reply timeout + isolate-death race window** (`packages/engine_bindings/lib/src/engine_service.dart`): wrap `_call`'s future in a timeout; attach death listeners before transient ports are torn down.
- **Fire-and-forget futures with no error handler** (`game_screen.dart`, `new_match_screen.dart`, `online_screen.dart`, `lan_screen.dart`, `history_screen.dart`): attach `onError`/try-catch at each site named in the audit; `TutorService` gets a try/catch so an engine failure degrades rather than propagating as an unhandled async error.
- **Score sheet re-pins to bottom on rolls, not rows** (`game_screen.dart`): key the auto-scroll guard on `rows.length`, not `events.length`.
- **Stale settings snapshot on drag-hint write-back** (`new_match_screen.dart` + online/LAN twins): re-read before writing, or add a targeted single-column update.
- Tests: failing-first where practical.
- **Commit(s):** small logical groups.

### Task 5: Maintainability — dead code, duplication, migration gap
- **Dead/orphaned public API in `backgammon_core`**: delete or re-scope `position_id.dart` (unused in production); decide the fate of the position-free `MoveBuilder(List<Move>)` constructor (test-only today, forces nullable plumbing through the hottest method — either mark it clearly test-only via a separate export or delete and port its tests to `forState`); `isLegalPlay`, `legalVariants` getter, `checkerCount` — same treatment.
- **Bear-off rules implemented twice** (`move_builder.dart` vs `move_generator.dart`'s `_Pos`): hoist a shared predicate both call.
- **Duplicated transport plumbing across 4 `MatchTransport` implementations** (`socket_transport.dart` host+guest, `firestore_transport.dart`, `in_memory_transport.dart`): a `TransportChannels` mixin in `match_transport` carrying the three broadcast controllers + guards + `dispose()` — this is also where `_HostSocketTransport._setStatus`'s missing dedup (vs the other three) gets fixed for free.
- **`test` package as a runtime dependency of `match_transport`**: move `transport_contract.dart` (and `in_memory_transport.dart`/`scripted_dice.dart`, which are exported from the main barrel but are test-only) behind a separate entrypoint or sibling testing package; demote `test` to `dev_dependencies`.
- **Missing v7→v8 drift migration test** (`app/test/data/migration_test.dart`): add the `_v7SettingsDdl` fixture and include it in the upgrade-path sweep — this is the exact path every current install takes.
- **`native/engine_shim`**: `#[cfg(test)]`-gate or delete `wildbg_new` (only remaining caller is a vendored test — port it to `wildbg_new_with_path`); fix the one export not following the file's own `#[unsafe(no_mangle)]`/`# Safety`-doc convention.
- **Placeholder smoke tests** (`backgammon_core/test/smoke_test.dart`, `engine_bindings/test/smoke_test.dart`): delete (`expect(1+1,2)` scaffolding, real suites exist now).
- Tests: this task is mostly deletion/consolidation — existing suites must stay green; add tests only where consolidation could hide a behavior change (the bear-off hoist needs the existing overshoot/double-decomposition cases to still pass identically).
- **Commit(s):** one per sub-area.

### Task 6: `game_screen.dart` split
Per the UI audit's structural recommendation — extract in this order (each is its own commit, verified green before the next):
1. `DicePresenter` (ChangeNotifier) — the dice-beat/presentation state machine.
2. `ScoreSheetPanel` (StatefulWidget) — bundled with the Task 3 score-sheet memoization fix.
3. `GameHud` + badges — pure file move, zero coupling.
4. `game_dialogs.dart` — presentational, parameterized.
5. `HintPanel` + `HintController`.
6. `TutorSync` — bundled with the Task 3 `_syncAssessment` fix (extracting first would just relocate the O(n²) problem).
Keep in `game_screen.dart`: the layout skeleton, `_buildModals`' priority ordering, pass-device/orientation state, the surrender flow (deliberately cross-cut, do not scatter it), action bars, dance auto-pass.
Tests: existing `game_screen_test.dart` suite must stay green throughout — this is a pure refactor, no behavior change, verified by the untouched test suite passing at every step.

### Task 7: Settings/tutor correctness + accessibility
- **LAN/online ignore the tutor setting** (`online_screen.dart`, `lan_screen.dart`): thread `settings.tutorOverride` through like `new_match_screen.dart` does. This is a decision, not just a fix — confirm the product intent (tutor available in networked play regardless of the toggle may have been deliberate for a reason the audit didn't find; if so, make the Settings UI say so instead of changing behavior). Default to honoring the toggle unless a reason to the contrary surfaces.
- **Board has zero accessibility surface** (`app/lib/board/board_view.dart`): add `Semantics` describing checker positions/dice/cube/turn at a reasonable level of detail (this is a `large` item per the audit — scope to a solid baseline: board region has a label describing whose turn and the roll, not necessarily per-checker semantics for v1). Error banner and tap hint get `liveRegion: true`. Score sheet's mark dot gets a text label alongside the color.
- Tests: widget tests asserting the new Semantics nodes exist with sensible labels.
- **Commit(s):** tutor-setting decision as one commit, accessibility as another.

### Task 8: Release/CI polish
- Android: drop `x86_64` from the cross-compile ABI list (emulator-only, no tester device uses it); `--split-per-abi` or app bundle instead of a universal APK; pin `ndkVersion` explicitly in `build.gradle.kts` to match the CI-installed revision; set `dev.steenbakker.mobile_scanner.useUnbundled=true` in `gradle.properties` (measure both APK sizes before/after, report the delta).
- CI: add `cargo test`/`clippy`/`fmt --check` to the `engine` job (cache is already warm); get golden tests running somewhere automated (a Windows CI job, or a pixel-tolerance config for Linux — pick one); add `cache: true` to all `flutter-action` uses, cache for `setup-node`, cache for `dart-lang/setup-dart`; pin `firebase-tools` to a major.minor; add `--retry=2` to the `lan` job only (not others); split the rules-only emulator leg into its own fast job ahead of the E2E legs; consider a `strategy.matrix` for the three identical single-package jobs (`core`/`lan`/`match_transport`).
- Firebase: correct the DEPLOY.md lobby-poll figure (2x error); mask `$TEAM_ID`/profile values before echoing in `ios.yml`; add the missing roll `n` type/range rules tests (parity with the events suite).
- Versioning: add annotated git tags on release merges going forward; add a root `CHANGELOG.md` (Keep-a-Changelog format, seed with a summary from git log for the plans already shipped); consider gating `android.yml` on pubspec-version == tag (optional, note as a follow-up if it adds too much friction now).
- Delete `firebase/smoke.js` (dead scaffolding).
- **Commit(s):** logical groups (Android build config; CI caching/hardening; Firebase docs/rules; versioning).

### Task 9: Documentation sweep
Fold in every trivial doc finding from all five audits in one pass:
- Stale plan-task references in doc comments (`engine.dart`, `scored_move.dart`, `move_generator.dart` — three spots citing closed plan tasks as future work).
- SUPERSEDED banners on `docs/superpowers/plans/2026-07-25-online-play.md` and `2026-07-26-lan-play.md` (matching the existing banner style on the v1 architecture spec).
- `README.md`: Play Nearby description (add QR join), CI job table (six jobs not three, list all four emulator legs), workflows table (add `ios.yml`), app job description (mention `-x golden`).
- `.github/workflows/README.md`: CI row accuracy.
- Dangling doc reference to `_ownsTheVerbs` (no longer exists) in `game_screen.dart`.
- Any other `TBD`/`TODO`/stale-reference the implementer finds while touching these files.
- **Commit:** one, doc-only.

### Task 10: Verify, review, merge, ship v0.13.0
Full matrix (all six packages) + the whole Firebase emulator pipeline (now including the fixed rules) + full `flutter test` + `flutter analyze` everywhere. Whole-branch review with a SECURITY lens on Task 2's fixes specifically (the rules change and the transport fixes touch the trust boundary — confirm no regression against the adversarial test suites built in P15-P17) and a REGRESSION lens on Task 6's split (confirm zero behavior change). Bump version 0.13.0+18. Update memory. Ship + report mapping every finding to its resolution (fixed / deferred-with-reason / accepted-trade-off).
