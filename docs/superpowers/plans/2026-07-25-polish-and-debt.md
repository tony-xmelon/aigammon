# Polish, Debt & Release-Prep Implementation Plan (Plan 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the recorded debt from Plans 1-5 and make the app feel finished: checker animations, a settings screen, an app icon, a stronger cube advisor (cube-life), a score-aware AI resign policy, tap-to-apply hints, a server-side points-vs-cube cross-check, and release wiring for online-enabled Android builds.

**Why these items:** every one is either on a recorded deferred list (plans 2/4/5 + review notes) or a straight UX gap visible in the shipped app. Items requiring the user (keystore signing, Firebase console values, store metadata) are explicitly OUT and listed at the bottom.

**Environment:** as Plans 4-5 (PATH refresh incantation; suites: core 107, bindings 28+17, online_client 37+18, app 148+1skip+E2E; full app suite is slow — targeted runs while iterating, full once per task tail where cheap, full matrix in the final task).

---

### Task 1: Cube-life advisor (Janowski x) upgrade
`packages/engine_bindings`: extend `MatchCubeAdvisor` with a cube-life parameter (`advise(..., {double cubeLife = 0.7})` — 0 = dead (current), 1 = fully live; default 0.7 per Janowski's practical guidance). Implement the standard interpolation: doubled-take equity blends dead-cube equity with the live-cube recube-value model — for MATCH play the pragmatic v1.5: interpolate the take point between dead and live bounds per Janowski's formulas applied to match equities (document the derivation in code as rigorously as Task 2 of Plan 4 did; the reviewer WILL re-derive). Keep `cubeLife: 0` produces byte-identical results to today (regression-pinned against the existing hand-computed tests). Update AiAgent + TutorService call sites to the default 0.7. Extend tests: dead-cube regression, a hand-computed 0.7 case, monotonicity (take point rises with cubeLife), engine-tagged sanity unchanged in direction. Commit.

### Task 2: Score-aware AI resign policy
`app/lib/game/player_agent.dart`: `AiAgent.chooseResignResponse` currently ignores `ctx` (recorded minor). Make it match-aware: accept iff the offered points, folded through the MET (reuse `MatchEquityTable` transitions like the advisor), yield ≥ the equity of playing on approximated by the evaluator's class distribution (document the approximation; keep it simple but genuinely ctx-sensitive: at 1-away, gammon chances are worthless — never decline a single for gammon hopes at 1-away). Tests: the 1-away case flips vs the money-ish case; existing tests updated. Commit.

### Task 3: Tap-to-apply hints + analysis pre-move framing
- Hint rows in the live hint panel become tappable: tapping loads the hop sequence into the BoardView's MoveBuilder (add a `BoardView.applyExternalMove(Move)`-style hook or lift the builder — choose the cleanest mechanism; the user still confirms manually).
- Analysis screen: show the PRE-move position (with dice) when the cursor sits on an assessed move (recorded UX note from Plan 4's review) — add a toggle or show pre-move by default with the played/best move drawn as arrows? v1: pre-move board + textual played/best lines (no arrows). Widget tests for both. Commit.

### Task 4: Checker movement animations
`BoardView`: animate checker travel on state change (both local opponent/AI moves and remote moves): compute hop paths from the applied MoveEvent (the controller's event stream already exposes it — GameScreen tracks event growth for assessment; generalize that hook into an `lastAppliedMove` on MatchController? NO interface change if avoidable: derive the moved hops by diffing preview boards? Cleanest: a lightweight `ValueListenable<MoveEvent?> lastMove` addition to MatchController implemented by both controllers). Implement with an AnimatedBuilder over a single animation controller sequencing hops (~150ms per hop, capped total); skip animations under widget tests (Duration.zero via a flag) except two dedicated animation tests using tester.pump timing. Keep goldens stable (animations idle at rest). Commit.

### Task 5: Settings screen + persistence
`app/lib/screens/settings_screen.dart` + a drift `Settings` table (or shared_preferences — prefer drift, table exists infra): theme mode (system/light/dark), board theme (classic/dark — wire BoardTheme selection), animation speed (off/normal/fast), default match length, default difficulty, tutor defaults override. A `settingsProvider` (Riverpod, loaded at startup) consumed by main.dart (themeMode), NewMatchScreen (defaults), BoardView (theme/animation). Migration: schemaVersion bump with drift migration test (first REAL migration — do it properly: from v1 adds the table; test upgrading a v1 db). Widget + repository tests. Home gains a settings gear. Commit.

### Task 6: App icon + branding pass
Generate a simple, ownable icon programmatically (Dart script under `tool/`: draw with dart:ui — a stylized backgammon point triangle pair + checker over a felt roundrect; render to PNGs at required sizes) → wire via flutter_launcher_icons (dev dep) for Android + Windows. Update app display name ("AIGammon"). Commit the generated assets + config. (No store metadata — user item.)

### Task 7: Server points-vs-cube cross-check (online hardening)
`firebase/functions`: track `cubeValue` in the turnflow summary (double events ×2 it, reset to 1 per new game). In submitEvent result-claim validation: `points` must equal `cubeValue * m` where m ∈ {1,2,3} for move-terminal claims; `points == cubeValue(pre-double)` for drop (careful: drop's stake is the PRE-double value — the doubler offered at cubeValue, decider dropped: points = the CURRENT tracked cubeValue since the tracked value only doubles on TAKE — get the semantics right by mirroring game_state.dart's cube handling: track doubles on TakeEvent, not DoubleEvent); resignAccept: `cubeValue * value-multiplier` — the resign VALUE isn't server-known... it's in the ResignOfferEvent payload (`value` field) — read it from the stored offer event (track `pendingResignValue` in the summary on resignOffer). Reject mismatches (failed-precondition). Emulator tests: legitimate flows still pass (reuse E2E), forged points rejected (new negatives). Commit.

### Task 8: android.yml online defines + final matrix + merge
- `android.yml`: pass `--dart-define=AIGAMMON_FIREBASE_PROJECT=${{ vars.AIGAMMON_FIREBASE_PROJECT }}` + API key from `vars`/secrets IF SET (guard so unset vars produce a build with online not-configured — exactly today's behavior). Document in DEPLOY.md (user adds the two repo variables when ready).
- Full verification matrix (all suites, all emulator suites, desktop build, E2E), README feature refresh, final whole-branch review, merge to master + push, confirm all CI jobs + Android distribution green.

---

## User-required items (explicitly out; report at the end)
- Android release signing keystore; Play Store listing/metadata.
- Firebase production deploy (`firebase/DEPLOY.md`) + repo variables for online-enabled APKs.
- Any paid-plan (Blaze) upgrade for Cloud Functions deploy.

## Plan cut short (2026-07-25): Tasks 6 (app icon) and 7 (server cube cross-check) DEFERRED — superseded in priority by the user's first-version feedback (see plan 7). Task 8 reduced to: version increment (pubspec 1.1.0+2 + CI --build-number=run_number), online dart-define vars wiring, verification, merge.

