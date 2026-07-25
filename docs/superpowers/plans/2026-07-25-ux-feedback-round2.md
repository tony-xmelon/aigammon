# UX Feedback Round 2 Implementation Plan (Plan 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address the v0.3.0 feedback: trackable opponent animations, a visible scrollable move history with scores, drag enabled by default, and a legibility-first contrast overhaul.

**Verbatim feedback (2026-07-25):**
1. "opponent animation is way too fast, impossible to track dice nor chips"
2. "still missing the moves history, only last move score shown. show the full history and scores, scrollable" (the ⋮ Game record panel shipped but is undiscoverable and score-less — the user sees only the tutor's last-move chip)
3. "did not see the dragging of chips, did you implement it?" (implemented, default OFF — wrong default)
4. "need to improve contrast, red triangles too dark to see, black chips barely visible on the brown board, consider all combinations"

**Environment:** as Plan 7 (suites: core 118, bindings 39+17, online 37+18, app 236+1skip+E2E).

---

### Task 1: Animation pacing overhaul (F1)
`game_screen.dart` + `board_view.dart` + `app_settings.dart`:
- Re-tune to TRACKABLE: dice beat lengthens (cycle ~6 frames × 140ms ≈ 850ms), then a **settle pause ~500ms with the real dice shown BEFORE the move animation starts** (the user must be able to read the roll); checker hops slow to ~350ms each with an inter-hop pause ~120ms; REMOVE the 600ms total cap (a 4-hop double takes ~1.9s — that's the point).
- `animationSpeed` presets remapped: `off` (all instant), `normal` (the new trackable timings), `fast` (roughly the OLD timings ÷1.5). Settings labels unchanged. The plumbing: replace the single `hopDuration` getter with an `AnimationTimings` value object (hop, interHop, diceFrame, diceSettlePause) derived from the preset — thread through GameScreen/BoardView. Roll beat and move animation must SEQUENCE (move anim waits for beat+pause: GameScreen already tracks both — coordinate via a shared "presentation queue": simplest robust = BoardView delays starting a move animation while GameScreen signals dice presentation in progress; pick a clean mechanism, document).
- Tests: timings-per-preset unit tests; sequencing test (move overlay does not appear until beat+pause elapsed — pump timeline); existing zero-duration harnesses unaffected.

### Task 2: Visible move history with scores (F2)
- Replace the lone assessment chip area with a **persistent, collapsible history strip** above the action bar (fixed collapsed height to preserve F6's no-jumping: collapsed = one line showing the LAST entry; tap/swipe expands to a ~40%-height scrollable panel — expansion overlays the board (in-tree sheet) rather than reflowing it).
- Content: the Plan-7 `buildGameRecord` lines MERGED with tutor assessments — each human move line gains its mark + equity loss ("2. W 6-2: 24/18 13/11 · Error −0.061", colored dot per mark); cube/resign lines as-is. Works tutor-off too (record without scores). Auto-scroll to newest, manual scroll respected.
- The ⋮ "Game record" menu entry now toggles the same panel (one implementation). The transient assessment chip stays as the collapsed-line content source (chip logic folds into the strip).
- Tests: collapsed line shows the last entry + score; expand → full scrollable list with scores on human moves; tutor-off shows plain record; no layout shift of the board on expand (overlay assertion).

### Task 3: Drag by default + discoverability (F3)
- `enableDrag` default flips to **true** (schema default change — v3 column default is false: migrate v3→v4? A column default change for NEW rows only needs the Dart-side default + a one-time UPDATE for existing rows that never touched the toggle... simplest honest approach: schema v4 migration flipping `enable_drag` to true ONLY IF the settings row still has every gameplay column at its old default (heuristic: flip unconditionally — the toggle shipped hours ago to testers; acceptable; document). Update AppSettings.defaults + settings tests.
- First-game hint: a one-time dismissible tooltip/snack on the first interactive turn: "Tip: drag checkers or tap them — change in Settings". Store `dragHintShown` flag in settings (part of v4).
- Tests: migration v3→v4 flips + new-install default true; hint shows once.

### Task 4: Contrast overhaul (F4)
`board_theme.dart` (+ goldens): rework BOTH palettes for legibility. Systematic approach:
- Build a contrast test (`board_contrast_test.dart`): compute WCAG-ish relative-luminance contrast ratios for every combination: {white checker, black checker} × {board felt, dark point, light point, bar, tray strips} in BOTH themes; assert every checker/surface pair ≥ 1.8:1 on fill AND every checker has a rim whose contrast vs the surface ≥ 3:1 (the rim is what defines the silhouette — bump `checkerBorder` widths/colors as needed: give BLACK checkers a light rim and WHITE checkers a dark rim, per-theme).
- Palette direction (light theme): lighten the felt (warmer tan), brighten the dark points (the "red" — richer crimson clearly distinct from felt), keep cream points; dark theme: raise point/felt separation similarly. Iterate until the contrast test passes AND the goldens LOOK right (regenerate, READ the PNGs, describe, iterate).
- Tests: the contrast matrix test (permanent regression guard); goldens.

### Task 5: Verify, review, merge, ship v0.4.0
Full matrix, whole-branch review vs the 4 feedback items, merge → push (auto-distributes), bump version 0.4.0+4, memory update, feedback→resolution report.
