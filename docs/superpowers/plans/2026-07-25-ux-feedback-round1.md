# UX Feedback Round 1 Implementation Plan (Plan 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address every item of the user's first-version feedback (verbatim list archived below). Ordered so quick wins ship first; each task commits independently so partial completion still merges.

**Feedback→task map:** (F1) board not full-width/asymmetric + trays right → T2; (F2) chips overlap after 2nd, want 5 clean → T2; (F3) Undo/Confirm overlaid on board, rearrange buttons, Double/Resign anti-fat-finger → T1; (F4) selection UX overhaul (bar-chip highlight missing, inconsistent highlight colors, highlight the CHIP, tiny tap targets, drag option, combined-move taps) → T3+T4; (F5) everything-optional settings → T5; (F6) board jumps vertically with buttons/labels → T1/T2 (fixed-height zones); (F7) opponent play instantaneous → partially shipped (move animations in v0.2.0); add dice-roll beat + pacing → T6; (F8) full game move history → T7; (F9) header too high, single row → T1; (F10) borne-off count overlaid unreadable → T2 (outlined text); (F11) bear-off with higher die "not possible" → T8 (investigate: engine rule is overshoot-only-from-highest — determine bug vs rule-confusion, fix or surface in UI); (F12) no summary/analysis after match or in history → T9 (match-end analysis entry + verify history flow + persist ONLINE matches); (F13) setup selector checkmark squeezes text → T1; (F14) version increment → SHIPPED (v0.2.0, CI build numbers).

**Environment:** as Plan 6. Suites at start: core 107, bindings 39+17, online_client 37+18, app 166+1skip+E2E. App full suite slow — targeted runs; full once per task tail only when cheap.

---

### Task 1: Quick wins — controls, header, setup selectors
- `new_match_screen.dart` + `settings_screen.dart` + any SegmentedButton: `showSelectedIcon: false` everywhere (F13).
- `game_screen.dart` header → ONE row (F9): score compactly ("W 2–3 B · to 5" + Crawford badge + cube chip + thinking dot), overflow-safe.
- Buttons (F3): remove the BoardView bottom-overlay (Undo/Confirm/Pass) — BoardView gains callbacks/state exposure so GAME SCREEN renders them in a FIXED-HEIGHT bottom action bar (reserve the height always → kills vertical board jumping from the bar, F6-partial): layout [Undo] [Confirm/Roll/Pass context button] as the primary right-side cluster; Double + Resign move to the header row's overflow menu (⋮) with confirm-dialogs? NO — Double is a deliberate act: put Double and Resign as smaller buttons in the header row (away from the bottom where thumbs rest), Resign behind the ⋮ menu. Hint button stays bottom-left when tutor on. All still test-driven (update game_screen/board_view tests: the overlay assertions move to the action bar).
Commit per logical chunk; suites `flutter test test/screens test/board` + analyze.

### Task 2: Board layout rework + stacking + count readability
`board_geometry.dart` (breaking layout change — update ALL dependent tests + goldens):
- Full-width symmetric board (F1): drop the right off-tray column; the board's 12 columns + bar span the full width. Borne-off trays become HORIZONTAL strips ABOVE and BELOW the board (opponent's tray top, local player's bottom — orientation-aware), sized as a fixed fraction (~7% height each). `offRect(player)` maps to these strips; `locationAt` updated (off = tap the strip).
- The widget's total aspect changes: BoardView wraps board+trays in one fixed AspectRatio so the overall widget height is CONSTANT (F6: no reflow when HUD elements change — combined with Task 1's fixed bars, the board never moves).
- Stacking (F2): first 5 checkers FULL diameter no overlap; 6+ compress the whole stack to fit (recompute `checkerCenter`; point rect height accommodates 5 diameters — verify geometry proportions still look right at 4:3-ish overall).
- Borne-off counts + >5 stack labels: white-outlined text (paint stroke + fill) for readability anywhere (F10).
- Regenerate goldens (`--update-goldens`), visually VERIFY the two PNGs yourself (Read them — describe what you see; symmetric full-width board, trays top/bottom), commit goldens. Update geometry round-trip tests (24 points + bar + off-strips both orientations), stacking tests (5 no-overlap: assert consecutive centers differ by ≥ 2r for stacks ≤5).

### Task 3: Selection & tap-reliability overhaul
`board_view.dart` + `board_painter.dart` (F4 core):
- Selected CHECKER highlight: ring/glow around the top checker of the selected source (painter gains `selectedChecker: (location, stackIndex)`), NOT a triangle fill. Destinations keep triangle highlights but with ONE uniform overlay color from the theme (same alpha composite over light/dark points — new theme field, delete the per-point-color variance, F4b). Bar selection: the bar checker gets the same ring (F4a).
- Tap targets (F4d): `locationAt` gains a forgiveness radius — a tap within checkerRadius*1.5 of a selectable source's top-checker center OR anywhere in the point column selects it; destination taps accept the whole triangle + off-strip. Sources with no legal moves DON'T steal taps (tap→nearest SELECTABLE thing within tolerance; else clear). The Task-1 removal of the board overlay eliminates the button-steals-tap problem.
- Tests: selection paints the ring not the source triangle (probe painter fields); uniform color (theme assertion); bar selection ring; forgiving taps (tap slightly off-center still selects); non-selectable points don't grab.

### Task 4: Drag-to-move + combined-move taps (both toggleable)
- Combined moves (F4f): when a source is selected, `destinationsFor` shows DIRECT one-hop targets (as now) PLUS, when enabled, multi-hop landing spots for the same checker (from MoveBuilder candidates: any legal move whose hops chain from this source — the final landing point; tapping one enters all chained hops at once). Distinct visual (e.g. dimmer glow) for combined targets.
- Drag (F4e): pan gesture from a selectable source lifts the top checker (reuse the animation overlay checker), drop on a legal destination = addHop (or combined chain), else snap back. Toggle-gated.
- Both toggles read from settings (Task 5 adds the fields — do the settings plumbing HERE for these two: add `enableDrag`, `enableCombinedTaps` to AppSettings/schema? Schema v3 — batch ALL new settings fields in Task 5 to avoid two migrations: Task 4 reads from a `BoardInteractionOptions` param with defaults ON for combined, OFF for drag; Task 5 wires persistence).
- Tests: combined tap enters the full chain (canned position); drag lifts/drops/snaps (gesture tests with tester.drag); toggles off → behavior absent.

### Task 5: Options expansion (settings v3)
Schema v3 migration (batch): `showHighlights` (bool, def true), `enableDrag` (bool, def false), `enableCombinedTaps` (bool, def true), `showScoring` (bool, def true — hides the score line when off), `showCube` (bool, def true — hides cube display AND the Double affordance; cube still functions per rules... NO: showCube=false should disable doubling entirely for pure-casual play? That changes game semantics — split: `showCube` hides the DISPLAY only; a separate new-match option "Play without cube" already effectively exists? It doesn't. ADD a per-match `cubeless` option in new-match setup (not settings) that makes the controller never offer doubling (skip considerDouble + hide Double button); document), `showHighlights` gates all board highlight painting. Migration v2→v3 test (pattern from v1→v2). Settings screen sections updated. Wire everything through (BoardView/GameScreen/NewMatch). Tests per toggle.

### Task 6: Opponent turn pacing (dice-roll beat)
(F7 remainder) When a RollEvent lands for a non-local mover (AI/remote), present a brief dice-roll animation: the dice display cycles random faces ~400ms then settles on the real roll; the opponent's move animation (shipped) then plays. Gate on animationSpeed setting (off → instant). Add `lastRoll` listenable? The dice are in state — implement in the HUD/dice painter layer: GameScreen tracks RollEvents (event-growth hook exists) and drives a small controller. Tests: roll beat shows cycling then settles (pump timings); off-setting instant.

### Task 7: Move history panel
(F8) A scrollable game record: every event of the CURRENT game (and past games via a game selector? v1: current game) in standard notation ("3-1: 8/5 6/5", doubles/takes/resigns annotated), newest at bottom, auto-scrolling. Entry point: a "History" toggle button in the header ⋮ menu or a swipe-up panel — pick the simplest solid UX (in-tree bottom sheet over the action bar). Data: fold `controller.game.events` (already exposed). Online + local both work. Tests: panel lists the notation for a scripted game; updates live.

### Task 8: Bear-off higher-die investigation
(F11) Write focused tests reproducing the complaint: positions where the user expects to bear off with a larger die. Cases: (a) checker on 4-point, die 6, NO checker on 5/6 → overshoot IS legal (engine: from==highestPoint) — verify the UI offers it (MoveBuilder sources/destinations + off-strip tap); (b) checker on 4-point AND 6-point, die 6 → rule says bear off from 6 only — the 4-point checker CANNOT use the 6 (user may have hit this legitimate rule); (c) the F2-layout off-tray tap area (was the RIGHT-column tray too small/mis-tapped pre-Task-2?). Fix any genuine defect found (likely candidates: destinationsFor not offering `off`, or the off tap target); if the engine rule is correct and was the confusion, ensure the UI communicates it (highlight the checkers that CAN bear off). Report findings explicitly.

### Task 9: Post-match summary + online history
(F12): (a) Match-end dialog gains a "View analysis" button → AnalysisScreen for the final game (or a match summary screen listing games → analysis; v1: game list). (b) Game-end dialog: "Analyze game" link when tutor on. (c) ONLINE matches: persist to history — OnlineMatchController gains the same `MatchPersistence` hook (RepositoryPersistence works as-is: create the match row on match start in online_screen, record games on fold-terminal). Tests: dialogs expose the links; online match appears in history after completion (fake API driven).

### Task 10: Verification, review, merge, ship
Full matrix (all packages, emulator suites, desktop E2E, windows build), final whole-branch review, merge → push (ships the next build to testers automatically), update memory. Report the feedback→resolution list item by item.

---

## Archived verbatim feedback (2026-07-25)
[The user's full feedback message is archived in the git history of this file and mapped above.]
