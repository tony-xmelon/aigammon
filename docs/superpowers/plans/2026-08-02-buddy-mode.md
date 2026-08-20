# Buddy Mode (P19) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Buddy Mode MVP (opponent-on-a-real-board): the camera reads the physical board and dice, the engine plays one side by voice, the user executes its moves, and perception verifies — per `docs/superpowers/specs/2026-08-02-buddy-mode-design.md` (READ THE SPEC FIRST; it is the contract).

**Architecture:** New pure-Dart `packages/board_vision` (frames in → state-primed answers out, zero Flutter/camera deps, Windows-testable against a committed corpus). App layer adds camera/TTS/sensor plumbing, a `BuddySession` orchestrator over the existing `GameController`, and an `OpponentPolicy` commentary layer. Phase 1 is a feasibility spike with a **hard gate**: measured accuracy vs. the spec's targets before Phases 2–3 build on it.

**Tech stack:** Dart (all perception math hand-rolled: 4-point DLT homography, relative color models, blob analysis — no OpenCV/ML deps in MVP), `package:image` (dev-only, corpus decode + synthetic rendering), `camera` + `flutter_tts` + `sensors_plus` in the app (resolve current stable versions at implementation; record them with a comment in pubspec like the existing deps do).

**Conventions that bind every task:** failing test first; `dart analyze --fatal-infos` clean; commit per green step-group with this repo's message style; packages stay pure-Dart; every claim in a report states verified-vs-assumed. The perception thresholds live in ONE file (`packages/board_vision/lib/src/targets.dart`) and the corpus harness asserts them — they are the spec's table, renegotiated only at the Task 6 gate with the user.

---

## Phase 1 — Feasibility spike (Tasks 1–6, ends at a GATE)

### Task 1: `board_vision` scaffold, core types, synthetic board renderer

**Files:**
- Create: `packages/board_vision/pubspec.yaml` (deps: `backgammon_core` by path; dev: `test`, `lints`, `image`)
- Create: `packages/board_vision/analysis_options.yaml` (mirror `packages/match_transport`'s)
- Create: `packages/board_vision/lib/board_vision.dart` (barrel)
- Create: `packages/board_vision/lib/src/frame.dart`
- Create: `packages/board_vision/lib/src/geometry_types.dart`
- Create: `packages/board_vision/test/synthetic/board_renderer.dart` (test-only util)
- Test: `packages/board_vision/test/frame_test.dart`

Core types (pin these exactly — later tasks and the app depend on them):

```dart
// frame.dart — no dart:ui anywhere in this package.
class Frame {
  final Uint8List rgb; // row-major RGB888, length == width*height*3
  final int width, height;
  Frame(this.rgb, this.width, this.height) { /* assert length */ }
  /// YUV420 planes (as the camera plugin delivers) -> Frame. Pure Dart.
  factory Frame.fromYuv420(...);
}

// geometry_types.dart
class Pt { final double x, y; const Pt(this.x, this.y); }
class BoardQuad { final Pt topLeft, topRight, bottomRight, bottomLeft; }
enum BoardOrientation { whiteHomeNear, whiteHomeFar } // + doc: user's seat fixes it
```

- [ ] Step 1: Failing tests: `Frame` length validation throws on mismatch; `Frame.fromYuv420` converts a hand-computed 4×2 YUV block to known RGB values (assert exact bytes for BT.601 full-range; document the choice).
- [ ] Step 2: Implement `frame.dart`, `geometry_types.dart`; tests green.
- [ ] Step 3: Synthetic renderer (test util, uses `package:image`): draws a top-down board (points, bar, off trays, checkers by per-point counts, two dice with pips) from parameters `{BoardState board, Dice? dice, palette, lightingGain}`, then perspective-warps it by an arbitrary quad and returns a `Frame` + the ground-truth quad. This is the workhorse every Phase 1–2 test uses. Unit test: renderer output round-trips (a rendered checker's center pixel classifies to its palette color).
- [ ] Step 4: `dart analyze --fatal-infos` + `dart test` green; register the package in CI's package matrix (`.github/workflows/ci.yml` — add `board_vision` to the existing `strategy.matrix.package` list; keep per-package cache key pattern).
- [ ] Step 5: Commit `feat(vision): board_vision scaffold — frames, geometry types, synthetic board renderer`.

### Task 2: Homography and the ROI atlas

**Files:**
- Create: `packages/board_vision/lib/src/homography.dart` (4-point DLT solve + 3×3 apply/invert; hand-rolled Gaussian elimination, no deps)
- Create: `packages/board_vision/lib/src/roi_atlas.dart`
- Test: `packages/board_vision/test/homography_test.dart`, `test/roi_atlas_test.dart`

Board coordinate system (pin it): the playing field is the unit rectangle (0,0)–(1,1) with White's home board bottom-right under `whiteHomeNear`. `RoiAtlas.forOrientation(o)` yields quadrilateral ROIs in board space for: 24 points (indexed exactly as `backgammon_core`'s 0–23), `bar`, both `off` trays, and `diceZone` (the central band of both halves). Points are trapezoids covering the triangle plus stack overflow headroom toward the bar.

- [ ] Step 1: Failing tests: DLT recovers a known homography (map 4 corners + 10 random interior points, error < 1e-6); degenerate quad (collinear corners) throws; `mapToBoard(mapToImage(p)) == p`.
- [ ] Step 2: Implement; green.
- [ ] Step 3: Failing tests: ROI atlas — point 0/11/12/23 land where the renderer drew them (render a board with a single checker on each of those points; sample the mapped ROI; assert the checker's pixels dominate); orientation flip mirrors correctly; ROIs are disjoint except designed overlaps (headroom vs diceZone).
- [ ] Step 4: Implement; green. Commit `feat(vision): homography + ROI atlas over a unit-board coordinate system`.

### Task 3: Calibration — color learning from the start position, and confirmation

**Files:**
- Create: `packages/board_vision/lib/src/color_model.dart`
- Create: `packages/board_vision/lib/src/calibration.dart`
- Create: `packages/board_vision/lib/src/board_vision_base.dart` (the `BoardVision` facade; grows over Tasks 3–9)
- Test: `packages/board_vision/test/calibration_test.dart`

Contract:

```dart
class ColorModel { /* two checker distributions (mean+cov in a chroma-ish space),
  per-ROI background stats; classify(sample, roiBackground) -> {white,black,none} */ }
class CalibrationFingerprint { /* corner-patch appearance + exposure stats, for Task 9 */ }
class BoardCalibration { final Homography h; final BoardOrientation orientation;
  final ColorModel colors; final CalibrationFingerprint fingerprint; }
class BoardVision {
  static CalibrationResult calibrate({required Frame frame, required BoardQuad corners,
      required BoardOrientation orientation}); // learns colors FROM the start position
  ConfirmResult confirmStartingPosition(Frame frame); // belief vs standard start
}
```

Classification is **relative** (sample vs. its own ROI's learned background) — the spec's lighting-robustness mechanism. No color constants anywhere; add a test that greps `lib/` for hex color literals and fails if any appear (crude but binding).

- [ ] Step 1: Failing tests: calibrate on a rendered start position learns two separable checker colors for three different palettes (classic brown/white-black, blue board/red-white checkers, low-contrast wood); classify achieves 100% on the renderer's own checkers under `lightingGain` 0.6–1.4.
- [ ] Step 2: Implement color model + calibrate; green.
- [ ] Step 3: Failing test: `confirmStartingPosition` accepts a correct start, rejects a board with two checkers swapped (names the offending points in `ConfirmResult.discrepancies`).
- [ ] Step 4: Implement; green. Commit `feat(vision): calibration learns each board's colors from the known start position`.

### Task 4: Occupancy estimation and dice reading (prototypes)

**Files:**
- Create: `packages/board_vision/lib/src/occupancy.dart` (per-ROI checker-pixel mass → `{count, color, confidence}`; count trusted only ≤ 2 without a prior — document why on the class)
- Create: `packages/board_vision/lib/src/dice_reader.dart` (die-blob candidates in diceZone → per-face pip blobs → `DiceReading?` with confidence; reject when ≠ 2 candidate dice)
- Test: `packages/board_vision/test/occupancy_test.dart`, `test/dice_reader_test.dart`

- [ ] Step 1: Failing occupancy tests on rendered boards: empty/1/2/3/5-stack points at near AND far half, three palettes, gains 0.6–1.4 — assert color always right; count exact ≤2, within ±1 at 3–5 (the prior-based verifier in Task 8 closes the rest).
- [ ] Step 2: Implement; green.
- [ ] Step 3: Failing dice tests: all 21 face pairs rendered at 3 positions/rotations read exactly; one die missing → null (never a guess); confidence drops under gain 0.5.
- [ ] Step 4: Implement; green. Commit `feat(vision): occupancy and dice-pip prototypes`.

### Task 5: Corpus infrastructure — checklist generator, prep tool, threshold harness

**Files:**
- Create: `packages/board_vision/lib/src/targets.dart` — the spec's table as constants (calibration ≥0.95, dice ≥0.98, play-ID ≥0.95, placement-verify ≥0.95, resync ≥0.90) with doc pointing at the spec.
- Create: `packages/board_vision/tool/generate_capture_checklist.dart` — from seed 4242, emits `corpus/CHECKLIST.md` (numbered scripted shots: start position ×3 lighting ×2 boards, 12 seeded mid-game positions via `backgammon_core` random playout, 12 dice throws covering all pip values, 3 deliberate-degradation shots: half-frame board, dim, bumped angle) AND a `NNN.expected.json` sidecar per shot — **ground truth by construction**, no hand labeling.
- Create: `packages/board_vision/tool/prepare_corpus.dart` — takes a directory of photos named per checklist, downsamples to ≤1280px JPEG (`package:image`), writes `test/corpus/real/NNN.jpg` beside its sidecar. Budget ≤25 MB committed; tool prints total and warns over budget.
- Create: `packages/board_vision/test/corpus_harness_test.dart` — walks `test/corpus/{synthetic,real}/`, runs calibrate→confirm→occupancy→dice per shot against its sidecar, prints a per-metric scoreboard, and **asserts `targets.dart` thresholds**. Synthetic corpus (rendered by Task 1's renderer, committed as PNGs by a small generator in `tool/`) keeps the harness meaningful before real photos land.
- Test: harness runs green on the synthetic corpus.

- [ ] Steps: checklist generator (+unit test: deterministic for the seed, sidecars legal per `backgammon_core` replay) → prep tool → synthetic corpus generation + commit of images → harness green → commit `feat(vision): corpus checklist, prep tool, and the threshold harness`.

### Task 6: USER-GATED — real corpus v1 and the go/no-go gate

**Files:** `packages/board_vision/test/corpus/real/*` (new photos+sidecars), `docs/superpowers/plans/2026-08-02-buddy-mode.md` (append the gate record).

- [ ] Step 1: Hand the user `corpus/CHECKLIST.md`; they shoot with a normal camera app on ≥2 boards × ≥3 lighting conditions and drop the files in a folder.
- [ ] Step 2: Run `prepare_corpus`, commit the corpus, run the harness. Iterate obvious quick fixes (≤1 day class) if a metric is near-miss.
**Carry into the gate conversation (measured in Task 5, before any photograph):**

- **Chroma subsampling is a capture artifact, not an algorithm failure.** Phone cameras write JPEG at 4:2:0 — colour at a quarter of the resolution of brightness — and classification here is per-pixel and per-colour. Measured on the synthetic boards: a brown board with cream points and near-black checkers stops calibrating at 4:2:0 quality 95 and is fine at 4:4:4. `prepare_corpus` re-encodes at 4:4:4 and cannot restore what the phone discarded at capture. A dark-checkers-on-warm-board session that refuses to calibrate is the first candidate for this, and reading it as outcome (c) would be wrong.
- **Blur is the pipeline's tightest limit, and it is the dice that hit it first.** Pairs read across viewpoints/palettes/seatings/sub-pixel offsets: 72/72 at 0.3–0.6σ, 20/24 at 0.8σ, 12/24 at 1.0σ, 10/24 at 1.1σ — and the 0.8σ failures are ragged, turning on where the corners fall between two pixels. Calibration survives to ~1.8σ. If the real corpus misses the dice target, sharpness is the first thing to check, and outcome (b) is the expected route.

**As implemented (before the photographs):** the board proportions became a calibration input. `RoiAtlas` hard-coded one set of tray/bar/column widths and its own doc said the corpus gate would settle whether "boards are close enough" — the first real board settled it: a folding case with **no bear-off trays at all** and a hinge strip for a bar, which moves its outermost points most of a column from where the standard atlas looks. So `BoardProportions` is now carried by the atlas, the calibration, the renderer and the sidecar (`proportions`, optional, absent = standard, no schema bump), `prepare_corpus` reads it from `proportions.json` per session, and a trayless board simply **has no** `offWhite`/`offBlack` regions. Measured by hand off the calibration frame — auto-detection is out of scope. Mismatched proportions fail loudly and are mutation-verified to do so (`test/trayless_board_test.dart`).

**As implemented (before the photographs), part two:** the same board turned out to break a second assumption, and this one was geometric. **A folding case is not one plane.** Standing open on a table it sits slightly tented — the spine in the middle stands proud of the two leaves, which is exactly where the hinge strip is and exactly where hit checkers sit. Measured off the first real calibration frame: fit ONE homography through the four outer corners and the two halves rectify to column pitches 102.5 px and 90 px per column at a 1200 px width — **13% apart**, impossible for two identical leaves. Mid-board columns land up to half a column out, the colour model's checker patches sample bare wood, and separability collapses. A sweep of 21 (trayWidth, barWidth) pairs failed every one, because the error is not a width; rectify each leaf under its own quad and the pitch is uniform to within 5%.

So there is now a geometry seam at the one place board space becomes pixels. `BoardGeometry.imagePointOf` is that seam; `PlanarBoardGeometry` is the old single homography behind it, byte-identical; `FoldingBoardGeometry` composes three — left leaf, hinge strip, right leaf — and routes each board-space point by its x, rescaling into the leaf's own unit square. Nothing on the far side of the seam changed: one atlas, one colour model, one stack axis, one dice band, and the dice band crosses the hinge without knowing it does. `BoardVision.calibrateFolding` takes eight points (`FoldingCorners`: four corners plus the four hinge seams) and **derives** the proportions from them — trayWidth 0, barWidth = the strip's width, two equal leaves flanking it, which makes each leaf's six columns exact sixths of that leaf whatever the strip measures. The sidecar gained an optional `foldingCorners` (additive, absent = flat, no schema bump, no key when absent) and `corners.json` takes eight pairs instead of four for such a shot. The hinge strip is approximated by its own planar quad — a ridge has a crown, and that is documented as fine because a checker on the bar is read for presence, colour and count, not fine geometry. Mutation-verified three ways, including that **flattening the tent makes the single-plane path succeed**, which is what pins the mismatch test to the tent rather than to a width (`test/folding_board_test.dart`, `test/synthetic/board_renderer.dart`'s `FoldingView`).

**Carry into the gate conversation, found while building the above:** the corpus's own JPEG is closer to a cliff than the blur is. At `kCorpusSteepQuad` and `kCorpusLowQuad`, quality-95 JPEG puts the classic palette's far-half black stack (the 19-point, five near-black checkers on an oxblood triangle) on a knife edge: every raw frame calibrates, and whether the same frame survives a round trip flips on a bar width of 0.07 against 0.08 or a tray of 0.02 against 0.05. Measured with plain `renderShot`/`BoardVision.calibrate`, no folding involved; the committed corpus misses it because its six sessions land on the passing side. Same shape as the blur raggedness above, at a knob nobody was watching. Not fixed — it is a sampler-and-colour question and the real corpus is the honest place to answer it. If a real session with dark checkers refuses to calibrate, this belongs beside the chroma note as a reason it is **not** outcome (c).

- [ ] Step 3: **GATE.** Present the scoreboard vs `targets.dart` to the user. Outcomes: (a) targets met → proceed; (b) dice under target → proceed with tap-to-enter dice as the shipped default and schedule the micro-classifier as follow-up; (c) geometry/color structurally missed → stop, redesign with the user. Record the outcome and numbers in an "As measured (gate)" note appended to this plan doc.
- [ ] Step 4: Commit `test(vision): real-board corpus v1 + gate record`.

## Phase 2 — Perception to target (Tasks 7–9)

### Task 7: State-primed legal-play matching

**Files:**
- Create: `packages/board_vision/lib/src/play_matcher.dart`
- Test: `packages/board_vision/test/play_matcher_test.dart`

```dart
/// Which legal play happened? Computes expected per-ROI (point/bar/off) count
/// and color deltas for each candidate (hits route through the bar), scores
/// them against observed occupancy changes between `before` and `frame`,
/// returns candidates ranked by fit with confidences.
List<PlayMatch> matchLegalPlay(Frame frame, BoardState before, Player mover,
    List<Move> legalPlays);
```

- [ ] Step 1: Failing tests (rendered before/after pairs): unique identification across 30 seeded turns incl. hits, bar entries, bear-offs, doubles; **ambiguity honesty** — two plays with identical resulting positions (e.g. 13/9 via 13/11 11/9 vs 13/10 10/9 when both intermediate points are empty) must return both above threshold, not a fake unique winner; a physically impossible diff (checker teleported) ranks nothing above threshold.
- [ ] Step 2: Implement; green. Extend the corpus harness with play-ID scoring over the mid-game shots; thresholds asserted.
- [ ] Step 3: Commit `feat(vision): state-primed legal-play matcher`.

### Task 8: Expected-board verification, stack verify, drift recovery

**Files:**
- Create: `packages/board_vision/lib/src/board_verifier.dart` (`verifyExpectedBoard(Frame, BoardState expected) -> BoardDiscrepancies` — per-ROI agree/disagree with confidence; stack heights checked by edge-periodicity against the expected K and calibration's checker diameter)
- Create: `packages/board_vision/lib/src/drift.dart` (`DriftReport` = discrepancy set + suggested resolutions, consumed by the app's side-by-side resolve UI)
- Test: `packages/board_vision/test/board_verifier_test.dart`

- [ ] Steps: failing tests (correct board verifies clean at both halves; one misplaced checker names exactly the two wrong ROIs; 5-stack vs 4-stack distinguished with the prior) → implement → harness gains placement-verify + resync scoring → green → commit `feat(vision): expected-board verification and drift reporting`.

### Task 9: Continuous readability and calibration re-validation

**Files:**
- Create: `packages/board_vision/lib/src/readability.dart`
- Test: `packages/board_vision/test/readability_test.dart`

```dart
enum ReadabilityLevel { green, amber, red }
enum ReadabilityCause { boardOutOfFrame, calibrationStale, motion, blur, tooDark, occluded }
class MotionHint { final bool deviceStill; /* from gyro, injected */ }
/// Runs on EVERY stable frame for the whole session (spec: calibration is a
/// session-long contract). Checks: corner patches still match the
/// fingerprint, exposure within re-normalizable range, sharpness, board
/// fully in frame. Returns level + named cause; `requiresRecalibration`
/// is true when geometry/colors are invalidated (vs. transient causes).
Readability assessReadability(Frame f, MotionHint motion);
```

- [ ] Steps: failing tests (moved-board frame → red + `calibrationStale` + `requiresRecalibration`; hand-over-board render → `occluded`, transient; dim render → `tooDark`; recovery to green when the condition clears) → implement (fingerprint from Task 3) → green → commit `feat(vision): continuous readability with recalibration routing`.

## Phase 3 — The mode ships (Tasks 10–15)

### Task 10: App plumbing — camera frames, TTS, sensors, permissions

**Files:**
- Modify: `app/pubspec.yaml` (add `camera`, `flutter_tts`, `sensors_plus`, `board_vision` path dep — current stable versions, each with a rationale comment like existing deps)
- Create: `app/lib/buddy/camera_frame_source.dart` (camera image stream → `Frame.fromYuv420` in a worker isolate; exposes stable-frame callbacks gated on `sensors_plus` gyro + inter-frame diff)
- Create: `app/lib/buddy/speaker.dart` (`BuddySpeaker` over `flutter_tts`: speak-and-mirror API, phrasing modes `terse|friendly`, mobile-only guard following `firebase_observability.dart`'s pattern, injectable fake)
- Modify: `app/android/app/src/main/AndroidManifest.xml` (`RECORD_AUDIO`), `app/ios/Runner/Info.plist` (`NSMicrophoneUsageDescription`); extend `app/test/android_manifest_test.dart` for the new permission (same pattern as CAMERA)
- Test: `app/test/buddy/speaker_test.dart`, manifest tests

- [ ] Steps: failing tests (speaker formats terse "13/8, 24/22" and friendly "Move one checker from 13 to 8..." from a `Move`; desktop no-ops — zero channel traffic, mirroring `desktop_guard_test.dart`'s technique; manifest assertions) → implement → `flutter analyze`/`flutter test` green → commit `feat(app): buddy plumbing — camera frames, speaker, sensors, permissions`.

### Task 11: BuddySession, dice-from-perception, OpponentPolicy

**Files:**
- Create: `app/lib/buddy/buddy_dice_roller.dart` — implements the existing `DiceRoller` interface; `rollDice()` returns a Future completed by perception (`readDice`) or manual entry, for BOTH sides (physical dice everywhere, per design).
- Create: `app/lib/buddy/perception_human_agent.dart` — implements `PlayerAgent`; the human's `Move` arrives from `matchLegalPlay` (unique match), the candidate picker (ambiguous), or tap-fallback — never from board taps.
- Create: `app/lib/buddy/buddy_session.dart` — owns calibration state, the frame/query scheduler (which query runs on the next stable frame is derived from `GameController` phase), placement verification for Buddy's dictated moves (loop until `verifyExpectedBoard` is clean, escalate to belief mirror), illegal/incomplete-play objection flow, readability→pause→recalibration routing (play resumes where paused; game state untouched — spec requirement), cube verbal flow.
- Create: `app/lib/buddy/buddy_policy.dart` — the spec's `BuddyPolicy` interface + `OpponentPolicy` speaking through `BuddySpeaker`.
- Create: `app/test/buddy/fake_vision.dart` (scriptable `BoardVision` fake, house fake style)
- Test: `app/test/buddy/buddy_session_test.dart`

- [ ] Step 1: Failing session tests with `FakeVision` + `ScriptedDiceRoller`-style scripts: full short game end-to-end (dice read → human play observed → buddy dictates → placement wrong once, corrected, verified); ambiguous play → candidate list surfaces, pick folds correctly; illegal play → objection spoken, state unchanged until board fixed; readability red mid-turn → queries pause, resume cleanly; `requiresRecalibration` → session enters recalibrating state without touching the game; cube: Buddy doubles by voice, user answer folds; game end recorded through the standard persistence path (assert a History row, reusing `test_database.dart` helpers).
- [ ] Step 2: Implement; green. Commit `feat(buddy): session orchestration, perception-fed agents, opponent policy`.

### Task 12: Calibration UI + Buddy setup screen

**Files:**
- Create: `app/lib/screens/buddy/buddy_setup_screen.dart` (reuses the match-setup option widgets: length, cubeless, difficulty, Buddy's color; plus seat side and phrasing)
- Create: `app/lib/screens/buddy/calibration_screen.dart` (camera preview, draggable corner handles seeded by auto-detect when confident, orientation confirm, belief-vs-board confirmation over the preview; in-context camera permission ask; the SAME screen serves mid-session recalibration with corners pre-seeded)
- Test: `app/test/screens/buddy/calibration_screen_test.dart` (fake frame source + fake vision; drive: drag corners → confirm → calibration produced; recalibration entry pre-seeds corners)

- [ ] Steps: failing widget tests → implement → green → commit `feat(buddy): setup and guided calibration screens`.

### Task 13: BuddyGameScreen + home entry

**Files:**
- Create: `app/lib/screens/buddy/buddy_game_screen.dart` — camera preview, belief mirror (render via the existing board painter in a compact slot), readability light naming its cause, spoken-line transcript, manual fallbacks (dice entry pad, tap-correct on the mirror, play-candidate picker), Double button under digital gating (reuse `TapWhenDisabled` + the Crawford explanations from `88aa43b`), pause/recalibrate flow into Task 12's screen.
- Modify: `app/lib/screens/home_screen.dart` — "Play with Buddy" entry, mobile-only (desktop hides it like other mobile-only surfaces).
- Test: `app/test/screens/buddy/buddy_game_screen_test.dart` (fakes end-to-end: a scripted game plays through the screen; red readability shows cause + suppresses; fallbacks reachable), `app/test/screens/home_test.dart` extension.

- [ ] Steps: failing widget tests → implement → green → commit `feat(buddy): the buddy game screen and home entry`.

### Task 14: Mic dice-trigger, analytics, settings

**Files:**
- Create: `app/lib/buddy/dice_sound_trigger.dart` (transient detector on mic amplitude stream; STRICTLY an attention hint — `BuddySession` works identically with it absent/denied; permission asked in context, denial remembered without nagging)
- Modify: `app/lib/analytics/analytics_events.dart` (+ buddy events: session start/complete, calibration attempts, recalibrations, fallback uses, readability-red rate — the spec's field-tuning metrics)
- Modify: `app/lib/screens/settings_screen.dart` + `app/lib/data/` (phrasing setting, drift schema vNext following the established migration pattern + migration test in `app/test/data/migration_test.dart`)
- Test: `app/test/buddy/dice_sound_trigger_test.dart` (synthetic amplitude streams), analytics/settings tests per house pattern

- [ ] Steps: failing tests → implement → green → commit `feat(buddy): mic attention trigger, telemetry, phrasing setting`.

### Task 15: Docs, full verification, ship v0.14.0

**Files:**
- Create: `docs/buddy-mode-test-protocol.md` (the scripted on-device manual match with checkpoints, per spec Testing)
- Modify: `README.md` (mode description), `CHANGELOG.md` (0.14.0 entry), `app/pubspec.yaml` + `app/lib/branding/app_version.dart` (**both** — 0.14.0+N; the drift-guard test enforces the pair, this bit us at 0.13.0)

- [ ] Step 1: Full matrix: `flutter test` (goldens included), `dart test` × all packages (now incl. `board_vision` + its corpus harness), `dart analyze --fatal-infos` × all, `cargo` suite, Firebase emulator pipeline (unchanged code but the ship-gate runs it per house rule).
- [ ] Step 2: Whole-branch review (implementer→reviewer pattern), fix round if needed.
- [ ] Step 3: **USER-GATED:** the manual on-device protocol on the user's devices against a real board — this is the MVP's true acceptance test.
- [ ] Step 4: Version bump both files, CHANGELOG, merge, push, tag `v0.14.0` per README's Releasing section. Update memory.

---

## Self-review notes

- Spec coverage: modes seam (T11), opponent loop (T11/T13), calibration + continuous re-validation (T3/T9/T12), color-agnosticism (T3 + the no-color-literals test), state-primed queries (T7/T8), readability (T9/T13), TTS/phrasing (T10), mic-as-optional (T14), fallbacks (T11/T13), corpus-as-tests (T5/T6), gate (T6), History/analytics (T11/T14), permissions (T10), version discipline (T15). Voice input, coach modes, cube perception: out of scope per spec.
- Type consistency: `Frame`/`Pt`/`BoardQuad`/`BoardCalibration`/`Readability` pinned in Tasks 1–3 and referenced identically after; `BoardState`/`Move`/`Dice` come from `backgammon_core` everywhere.
- The one deliberate deviation from bite-sized orthodoxy: perception algorithm internals (Tasks 3–4, 7–8) specify contracts + test matrices rather than full literal code — the algorithms are exploratory by nature (that is what the corpus harness and the gate are for), and prescribing pixel math line-by-line here would be fiction. Every OTHER binding surface (types, APIs, thresholds, file layout, test cases) is exact.
