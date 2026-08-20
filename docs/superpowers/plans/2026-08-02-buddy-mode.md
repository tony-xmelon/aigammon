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

**As implemented (before the photographs), part three:** the same frame broke a third assumption, and this one was not geometry — it was **where a checker is**. The patch that learns this board's checker colours was a fixed window 0.02–0.045 deep taken from the board's own edge, which assumes the outermost checker sits flush against it. Not one of the real frame's eight starting stacks did. Measured with the folding geometry already correct: six of the eight windows landed on bare wood, both learned checker distributions converged on wood, and `checkerColoursNotSeparable` refused a frame a person reads at a glance. The gaps differ from stack to stack, so no deeper window fixes it. `RoiSampler.checkerPatch` is therefore `RoiSampler.findChecker`: it walks the column inward, scores each candidate patch for **coherence** (a checker's face is one colour; a patch across the edge between checker and board is not) and takes the first coherent block whose colour **holds** deeper than any gap could — no colour constants, which is what lets it run at the bootstrap before anything about the board is known. It tries ±0.15 of a column width either side of centre for a stack that is not quite in the middle of its own column, and takes its colour from inside the block rather than off the checker's leading edge, where a disc is at its narrowest. Once colours exist, confirmation passes them in and the walk stops at the first block that reads as a checker, because a lone checker on a point that should be empty does not hold for two checkers' depth.

Four numbers came off the photograph rather than the bed, and each was wrong in a way flat paint could not show: a two-stack on the **far** half projects into 0.09 of the board along its column (real checkers stand above the felt, so at a shallow angle the far one hides behind the near one), which sets the hold depth at 0.07 and the search window at 0.10; "the same surface" must be judged on colour with **brightness taken out**, because the same white stack runs (166,157,136) at its foot to (198,193,164) at its top under a window; a pedestal under the log ratio, because two levels of grain on a channel value of fifteen is otherwise an eighth of a log unit of "different colour"; and a checker must have a **body**, because the shadow in the seam between the felt and the far rim is a coherent near-black line that six empty points and the bar read as Black. Two of the bed's pinned degradation limits moved with the change and were re-measured, not relaxed: grain 4 → 6 levels and blur 1.8 → 7 sigma, both because the old patch was sampling the boundary between a checker and the board under it and the walk refuses to. Stacks that are not flush also broke two things beside the patch, both fixed here: a covered region whose visible surface splits near-evenly between felt and triangle paint produced a reference colour the board does not have anywhere and could not then recognise its own checkers, so such a region borrows the board's reference; and the reach walk started at the board's edge, so an inset stack measured **zero**, the pitch regression had nothing to fit, and occupancy counted one checker on stacks of five — a run is now measured from where it starts. (`test/calibration_test.dart`'s 'stacks a person placed, not a renderer', `test/occupancy_test.dart`, mutation-verified against the fixed window.)

**Carry into the gate conversation, found on the real frame while doing the above:** three things the photographs will ask about again.

- ~~**The bar is the last thing on that board that does not read.**~~ **Settled — it was a missing label, not a missing threshold.** With the eight points placed so that all twelve columns land on their stacks, the real frame calibrated and all 24 points read back, and then the bar refused it: the hinge strip is a worn ridge — a near-black crack down the middle, a pale rubbed crown either side, plain wood on the flanks — and 168 of its 400 samples classified as checkers, 115 of them White, against a `minRegionCoverage` of 0.02. Neither of the two exits guessed at above was the answer. The region did not need a bigger threshold and it did not need a hand-written vocabulary: it needed the label the starting position already gives it. **The bar and both trays hold nothing, in every frame calibration is ever handed**, so a sample there that looks like a checker is a surface the model was not given room for, and `Calibrator._settleEmptyRegions` gives it room — splitting what still reads as a checker into further surfaces, and *re-measuring the region's spread* afterwards, which is the half that matters: a region one surface short carries the missing surface's whole distance in its spread (the bed's worn spine came out at (0.15, 0.22, 0.36) against a floor of 0.15), wide enough to reach out and swallow a cream checker standing on that crown. The real frame now calibrates **and confirms** — 6 White and 3 Black strays left of 400, both under the floor. Leaning on the label also meant checking it, and that closed a silent hole predating the spine entirely: a tray with men in it shows two surfaces, its felt and the men, which is exactly what a region has room for, so **both were learned and the calibration was handed over** — one and three checkers in a tray, and one on the bar, all went through. Colour cannot separate the two cases (the real crown sits 1.40 spreads from the White cloud; a genuine black checker in a tray measures 5.41, because a tray's wood reference is not a point's felt); what separates them is that a checker is an **object** — one colour across its face with a body behind it — so `RoiSampler.findChecker` became `findAlong` over any `StackAxis` and the empty regions are walked with it, judged against the eight medians the start position just labelled rather than through the region's own surface. Measured on the real spine: every block down it scatters 20 to 43 sensor levels against a coherence floor of 18, because a block laid across the strip catches the crack and the flanks along with the crown. Mutation-verified both ways on disjoint tests.
- **Corner taps are the biggest single source of error left, and there is no feedback that they are wrong.** On the frame in hand the four outer taps put the near edge on the outer lip of the rim rather than the felt boundary, the near-left corner ~40 px inside the board and the near-right ~240 px inside it — enough that the two outermost near columns did not contain their own stacks at all, which is a failure no sampler can fix. Task 12's calibration UI should show the derived columns over the live frame (the twelve column axes, not just the outline), because a person can see a column that misses its stack instantly and cannot see a corner that is 3% out. **Measured since, and it is worse than "there is no feedback":** a machine sweep of 784 near-corner sets on that one frame found **26** on which calibration and confirmation both agree — 3%. The accepting sets are scattered rather than a plateau, so a person tapping by eye is not making a small error that degrades gracefully; they are hunting for a needle. Two further findings from the sweep, both for Task 12: the board's near edge is **not level in the picture** (near-left ≈ (120, 965), near-right ≈ (1646, 951), hinge-near ≈ 948 on that frame), so a UI that snaps the near handles to one line cannot express a real board; and **separation is a poor guide to a good tap** — the highest-separation accepting set (7.41) counts 19 of 24 columns' colours right, while a lower-separation one (7.10) counts 20 and gets 14 exact against the other's 11. Whatever the UI shows a person, it should not be that number.
- **Counting on the far half is the next measurement to take.** With good corners the same frame counts the near half about right and the far half short (pitch fitted at 0.043 where the near half alone says ~0.09), for the same reason the hold depth had to come down: elevation plus a shallow angle compresses a far stack's footprint. The pitch is currently one number for the whole board; the gate should decide whether it needs to be one per half. **Still open, and now with a number against it:** on the best accepting corner set the frame confirms cleanly and still counts only **14 of 24** points exactly and 20 of 24 within one, with the misses all in the same direction the pitch predicts — five-stacks read short on the far half and long on the near. Confirmation checks colour at the foot of a stack and is satisfied; counting is not, and the gap between the two is exactly this.

**Carry into the gate conversation, found while building the above:** the corpus's own JPEG is closer to a cliff than the blur is. At `kCorpusSteepQuad` and `kCorpusLowQuad`, quality-95 JPEG puts the classic palette's far-half black stack (the 19-point, five near-black checkers on an oxblood triangle) on a knife edge: every raw frame calibrates, and whether the same frame survives a round trip flips on a bar width of 0.07 against 0.08 or a tray of 0.02 against 0.05. Measured with plain `renderShot`/`BoardVision.calibrate`, no folding involved; the committed corpus misses it because its six sessions land on the passing side. Same shape as the blur raggedness above, at a knob nobody was watching. Not fixed — it is a sampler-and-colour question and the real corpus is the honest place to answer it. If a real session with dark checkers refuses to calibrate, this belongs beside the chroma note as a reason it is **not** outcome (c).

**As implemented, part four: the corpus has a plan of its own, because it was filmed rather than shot.** It arrived by `FILMING.md`'s one-video route, not by `CHECKLIST.md`'s thirty-three staged photographs, so `capture_plan.dart` gained the mirror of `buildCapturePlan`: `buildRealSession` says what *was* filmed where the other says what to go and film, and `prepare_corpus --plan filmed` prepares it through exactly the same downsample, encoder and sidecar writer — a corpus prepared by some private script beside the tool is a corpus nobody can re-prepare. Ten windows out of one twelve-minute game: a calibration hold, seven positions off the transcribed turn ledger, two end-game keyframes. **The seven positions are not typed in.** The ledger is held in the transcript's own notation and replayed through `backgammon_core` when the session is built, so a mis-transcribed turn throws out of `buildRealSession` naming itself, and the board in each sidecar is the replay's own output — the same ground-truth-by-construction the seeded playouts get, from a game that actually happened. The two keyframes carry a board and no log (the last stretch had hands in it and a hit nobody could attribute to a turn); `events: null` needed no schema change, and the one arithmetic that can be held over a hand-read position — fifteen checkers a side — is pinned. Turns 9–15 are deliberately **excluded**: contaminated windows and an unattributable hit, and a sidecar that guessed would be worse than a shorter corpus. Dice stay in the sidecars for the four rolls a person could read off a zoom (4-2, 6-4, 6-5, 6-3) and are absent from the other six, because claiming a roll nobody could call is inventing ground truth.

**As measured, and where Task 6 stopped: a corner set is a property of ONE image at ONE size, and does not survive being scaled onto another.** The session's eight points came from the machine sweep recorded above, run on the **full-resolution, lossless** calibration frame, and they are right there — reproduced at `7401fc3`: separation **7.102**, `confirmStartingPosition` agrees, **24/24** colours right and **21/24** counts exact, the three misses being the 12-, 17- and 19-point tall stacks read short. Scale those same eight points by the downsample factor onto the committed ≤1280 px frame and calibration **refuses** — `checkersNotInStartingPosition`, offending exactly those same three points, now reading empty rather than merely short. It is not the JPEG and it is not chroma. Measured on the one lossless frame available: a quality-95 4:4:4 re-encode at full size fails; a lossless resize to 1280 with no encoder involved at all fails; 1280 as PNG, and 1280 at quality 100, fail identically. Every step of the corpus's own committed representation costs those three stacks the pixels they were surviving on, which is the far-half counting problem already recorded above with a resolution dependence now attached to it.

What that is **not** is a structural refusal of the board. Re-running the transcript's own 784-set near-corner sweep in the prepared image's pixels — the same search, scaled, and the control reproduces the recorded **26** at full resolution exactly — finds **79** sets that calibrate *and* confirm at 1280, and the best of them count 24/24 colours and **22/24** exact, better than the full-res set manages. The accepting region did not shrink; it **moved**. Which is the sharpest form yet of the corner-tap finding: the taps are a needle, the needle belongs to one image at one size, and `prepare_corpus`'s own instruction — read them off the **prepared** jpeg, never the original — is load-bearing rather than a convenience. It also sharpens what Task 12's calibration UI owes the user, since the app taps corners on a preview and reads frames at whatever size the camera delivers.

So the corpus is prepared and **not committed**, pending a decision that belongs to the gate rather than to whoever prepares it: re-sweeping the corners on the prepared frame is the documented route, and choosing one of 79 accepting sets by how well it counts is also selecting on the very numbers the gate exists to read honestly. On a corpus of one calibration and ten shots that choice dominates every figure in the scoreboard, so it should be made knowingly and recorded, not made by the preparer.

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

**Carry into Task 9, found in Task 6's geometry work:** `CalibrationFingerprint.geometryMatches` compares the four **outer** corner patches and nothing else, so it is blind to the one way a folding case goes stale without moving. A case standing open on a table is tented, and the tent is what `FoldingBoardGeometry` was built for: the spine settles flatter over a session — a leaf nudged, a table knocked, the case simply relaxing — and the middle of the board moves while all four corners sit exactly where they were. Every column near the hinge shifts, the hinge strip's own plane is wrong, and the fingerprint says nothing has changed. Measured, in the geometry that made the folding path exist: a tent angle wrong enough to matter puts mid-board columns half a column out and collapses separability, which is the same failure a moved board causes and the same routing (`requiresRecalibration`) — it just is not currently detected. Task 9 needs a patch on the **hinge seams** as well as the corners on a board calibrated through `calibrateFolding`: those four points are exactly where a tent change shows and exactly where a slide does not. Cheap, since the eight points are already in the calibration.

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
