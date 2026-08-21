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

**As implemented, part four: the corpus has a plan of its own, because it was filmed rather than shot.** It arrived by `FILMING.md`'s one-video route, not by `CHECKLIST.md`'s thirty-three staged photographs, so `capture_plan.dart` gained the mirror of `buildCapturePlan`: `buildRealSession` says what *was* filmed where the other says what to go and film, and `prepare_corpus --plan filmed` prepares it through exactly the same downsample, encoder and sidecar writer — a corpus prepared by some private script beside the tool is a corpus nobody can re-prepare. Ten windows out of one twelve-minute game: a calibration hold, seven positions off the transcribed turn ledger, two end-game keyframes. **The seven positions are not typed in.** The ledger is held in the transcript's own notation and replayed through `backgammon_core` when the session is built, so a mis-transcribed turn throws out of `buildRealSession` naming itself, and the board in each sidecar is the replay's own output — the same ground-truth-by-construction the seeded playouts get, from a game that actually happened. The two keyframes carry a board and no log (the last stretch had hands in it and a hit nobody could attribute to a turn); `events: null` needed no schema change, and the one arithmetic that can be held over a hand-read position — fifteen checkers a side — is pinned. Turns 9–15 are deliberately **excluded**: contaminated windows and an unattributable hit, and a sidecar that guessed would be worse than a shorter corpus. Dice stay in the sidecars for the four rolls a person could read off a zoom (4-2, 6-4, 6-5, 6-3) and are absent from the other six, because claiming a roll nobody could call is inventing ground truth. **(CORRECTION III, 2026-08-23: absent is not the same as not there. Nine of the ten windows have dice somewhere in them; only 001, the calibration hold, is genuinely dice-free. The sidecar now says which with `diceInFrame`, and the metric that was scoring the difference has been rescoped.)** **(Superseded 2026-08-21 and restored 2026-08-22 — the turn ledger was wrong on five turns, nothing ever left the board, and the corpus is once again seven replayed positions and two end-game keyframes, exactly as described here. One dice sidecar changed: 010's pair is 6-4, derived from the play rather than read off a die this camera cannot see the top of. See the three CORRECTION notes at the end of Task 8.)**

**As measured, and it stopped the corpus for a day: a corner set is a property of ONE image at ONE size, and does not survive being scaled onto another.** The session's eight points came from the machine sweep recorded above, run on the **full-resolution, lossless** calibration frame, and they are right there — reproduced at `7401fc3`: separation **7.102**, `confirmStartingPosition` agrees, **24/24** colours right and **21/24** counts exact, the three misses being the 12-, 17- and 19-point tall stacks read short. Scale those same eight points by the downsample factor onto the committed ≤1280 px frame and calibration **refuses** — `checkersNotInStartingPosition`, offending exactly those same three points, now reading empty rather than merely short. It is not the JPEG and it is not chroma. Measured on the one lossless frame available: a quality-95 4:4:4 re-encode at full size fails; a lossless resize to 1280 with no encoder involved at all fails; 1280 as PNG, and 1280 at quality 100, fail identically. Every step of the corpus's own committed representation costs those three stacks the pixels they were surviving on, which is the far-half counting problem already recorded above with a resolution dependence now attached to it.

What that is **not** is a structural refusal of the board. Re-running the transcript's own 784-set near-corner sweep in the prepared image's pixels — the same search, scaled, and the control reproduces the recorded **26** at full resolution exactly — finds **79** sets that calibrate *and* confirm at 1280, and their exact counts run from **13/24 to 23/24** (median 19) around the full-res set's own 21/24. The accepting region did not shrink; it **moved**. Which is the sharpest form yet of the corner-tap finding: the taps are a needle, the needle belongs to one image at one size, and `prepare_corpus`'s own instruction — read them off the **prepared** jpeg, never the original — is load-bearing rather than a convenience. It also sharpens what Task 12's calibration UI owes the user, since the app taps corners on a preview and reads frames at whatever size the camera delivers.

**How the committed corners were chosen, and the disclosure that goes with them.** Re-sweeping on the prepared frame is legitimate because it is *what the product does*: in the shipped app the corners always come from a human dragging handles until the calibration gate accepts (Task 12's whole loop), so sweeping-to-acceptance on the frame that is scored simulates that loop faithfully. What would not be legitimate is choosing among the accepting sets **by the count scores the corpus then reports** — that is selecting on the dependent variable. So the choice was made **count-blind**, by a rule stated before the scoreboard was produced: among the sets that calibrate *and* confirm, take the one at the smallest summed Euclidean distance from the transcript's reference points over the two swept near corners, breaking ties on separation (calibration-internal, count-free) and then sweep order. Selected: near-left **(120, 970)**, near-right **(1646, 961)** in raw-frame terms — **15.0 raw px** from the reference points (10.0 px in prepared pixels), separation 6.430, **rank 1 within the swept 784-set grid**. The other six of the eight points are the reference points, scaled.

That rank is **grid-relative, and only that**. An independent review swept a different 625-set grid over the same frame, found **90** accepting sets, and found one strictly closer to the reference points than the committed choice — near-left (120, 965), near-right (1636, 951), at **10.0 raw px** against this one's 15.0. So "nearest accepting set" is true of the grid that was searched and not of the continuous space, and the note above should be read as "nearest within the stated grid" wherever it appears. The committed set **stays as it is**: re-selecting now, with the scoreboard already in hand, would reintroduce exactly the dependence on the dependent variable that the count-blind rule was built to avoid. The reviewer's independent grid also reproduces the corner-luck finding qualitatively — 90 accepting sets, exact counts spanning 15/24 to 23/24, median 21 — which is the part that actually matters, since it is the spread and not the winner that the gate has to price in.

**What corner luck is worth, which is a Task 12 finding in its own right.** Across all 79 accepting sets — every one of which calibrates *and* passes start-position confirmation, so a user would see a green light on any of them — exact counts on the calibration frame range from **13/24 to 23/24, median 19/24**. That is a ten-checker spread in what the board is read to hold, entirely within the region the calibration gate accepts. Confirmation checks colour at the foot of a stack and is satisfied by all of them; counting is not, and the gap between the two is the same one recorded above, now with a magnitude. A calibration UI that stops at "accepted" is leaving most of that on the table; showing the derived columns over the live frame is what lets a person land in the good part of the region rather than merely the accepting part. The count-blind rule drew a set scoring 22/24 — sixteenth-best of the 79, and above the full-res original's 21/24 — which nothing selected on and which should be read as the luck it is.

**The disclosure line for the gate report:** the committed corners are machine-derived via the calibration-accept loop on the very frame the corpus scores, and are the member of that accepting region nearest the transcript's reference points within the swept grid, under a distance rule stated before the scoreboard was produced. Two things that phrasing is careful about. Those reference points are **session notes, not artifacts** — they came from machine sweeps refined against human reads of zoomed crops, which is why the far corners are non-integer, so calling them a human measurement of where the board is would overstate them. And the corners are not an independent measurement of the board at all: they are a search result on the scored frame. The 13–23 spread above is the honest error bar around every occupancy number below, and it is wider than most of the differences anyone will be tempted to read into those numbers.

**Two limits of this corpus, stated rather than left to be discovered.** The real corpus has **no picture-bytes guard**: the synthetic one is re-rendered from its own recipe and compared byte for byte, and nothing equivalent is possible for a photograph, so a frame replaced on disk would be caught only by the scores moving. And the committed floors are **one-sided by construction** — they catch a regression and are silent about an improvement, so a luckier re-tap of the corners would raise every occupancy number with nothing saying that the pipeline had not changed. Both are consequences of the disclosure above rather than separate problems, and both are reasons the gate should read the spread and not the point estimate.

**As measured (Task 6): the real scoreboard, ten frames, one session.** Committed at `test/corpus/real`, 3.5 MB of the 25 MB budget, nothing skipped.

| metric | measured | spec | gap |
|---|---|---|---|
| calibration | **1.000** (1/1) | 0.950 | +0.050 |
| start position confirmed | **1.000** (1/1) | — | (watched) |
| dice pair read | **0.000** (0/4) | 0.980 | **−0.980** |
| no dice read as no dice | ~~**1.000** (6/6)~~ **1.000** (1/1) | 1.000 | +0.000 |
| region colour and count | **0.784** (189/241) | — | (watched) |
| region colour alone | **0.954** (230/241) | — | (watched) |

Sliced: counts run 0.800 on the near half against 0.775 on the far, colour 0.942 near against 0.975 far. **(The dice-absence denominator was rescoped on 2026-08-23 — five of those six frames have dice lying in them and were being counted as frames with none. Same floor, same perfect score, a set that now matches the row's own sentence. See CORRECTION III.)** **The dice number is four refusals, not four misreads** — the reader found no pair at all on any of the four frames that have one, which is the behaviour the design asks for and is why the metric now reports found/right/refused rather than one rate. This board's dice are 0.021 of it across; band-location and tilt work is queued. Every real target that is not the dice one **passes**, which is outcome (b) territory rather than (c). These rates are pinned in `corpus_harness_test.dart` as floors so the real corpus cannot silently get worse, with the spec printed beside them every run.

**The bar shot, verbatim, because it is the flagship and the answer is the finding.** 066 has a Black checker standing on the worn hinge ridge — the object-versus-surface case in the wild, on the one board whose empty bar already reads like checkers. The machine says:

> `066 bar: expected black x1, read none x0 (reach 0.025 = 1.28 checkers)`

So it **found the object and could not name its colour**. The reach walk measured a run 1.28 checkers deep standing on the strip — the body is there, and `_settleEmptyRegions` has not swallowed it — but the classifier returned `none`, so the count collapsed to zero. That is a much narrower problem than the one the spine work was afraid of (a ridge that reads as checkers everywhere): presence is being detected on a surface the colour model was deliberately taught to treat as empty, and what is missing is the step that resolves a detected body against the two checker clouds rather than against the region's own settled surfaces. It belongs with the far-half counting work, not with the geometry.

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

**As implemented (Task 7): the signature could not be one frame, and Phase 1 is
why.** The plan pinned `matchLegalPlay(Frame, BoardState before, Player, List<Move>)`
— read the board now, compare against what each candidate would produce. Task 6
measured why that cannot be the instrument: this board's per-region colour comes
back at 0.954 and colour-with-count at 0.784, and the counting misses are not
scattered — a tall stack on the far half reads short because of the seat the
phone is in, so it reads short in *every* frame of the session. An absolute
comparison pays that bias on every region of every candidate; a difference
between two frames of one session subtracts it from itself. So the settled frame
from **before** the play is a required named argument (`beforeFrame:`) and the
positional signature is otherwise exactly the plan's. The session already holds
that frame — it is the one the previous query ran on. **The proof that the
difference is the right instrument is the pair of numbers themselves: 0.784
per-region counting supports 1.000 play identification on the same ten frames.**

**As measured (Task 7): synthetic 64/64, real 6/6.** Sixty-four seeded turns from
two `backgammon_core` playouts (32 each, no dance in either), rendered before and
after at the corpus's own grade across two palettes and two viewpoints: **top-1
100%**, every one above threshold, including 29 hits, 30 checkers coming in off
the bar and 7 rolls of doubles. Bear-offs get their own beds (a random opening
never reaches one), on a board with wells and on a folding case without. On the
**real corpus**, the six windows of the filmed game that are genuinely one turn
apart — 001→003, 003→005, 005→008, 008→010, 010→013, 018→020, against the actual
legal-move lists (7 to 18 candidates, 11.7 mean) — score **6/6, all six above
`PlayMatcher.minConfidence`**, so a session would have acted on all six rather
than prompting. Both are pinned as floors in `corpus_harness_test.dart` beside
the others, and the second needs its own: being right and being acted on are
different things, and any of the matcher's confidence constants can move
without disturbing the ranking at all. Measured — `noiseTolerance` 2.0 → 0.8
leaves identification at 6/6 and the entire synthetic suite green while pushing
**four of the six** under the threshold, which is a hands-free turn becoming
four taps. **Six is a small denominator and both floors are ratchets, not
claims of perfection**. Which pairs qualify is derived from the sidecars' own event logs
rather than typed in, and the three that do not (013→018 spans two turns because
turn 6's window never came; the two end-game keyframes carry no log) are named in
the scoreboard rather than dropped. **(Superseded 2026-08-21 and restored 2026-08-22:
018→020 retired when those two shots became board-only and came back when
measurement showed nothing had left the board, so it is **six pairs** again,
reading 6/6 identified and 4/6 acted on, with the three unpaired neighbours
named. The four numbers about the matcher's constants were measured over the
original six and are kept as measured. See the three CORRECTION notes at the end
of Task 8.)**

**The plan's ambiguity example does not arrive from the door the plan expected —
and then it arrived from the corpus.** `MoveGenerator.legalMoves` **already
dedupes by resulting position**, so 13/9-via-the-10 and 13/9-via-the-12 are one
entry there and a matcher fed that list never sees the tie. It is
`legalVariants`' decompositions that carry it — the door a session takes when it
wants to name the transit a user's hand actually used — and that is what the
ambiguity-honesty test feeds it. Then the real corpus produced the case
unprompted: **turn 3 of the filmed game is `W 5-2: 13/8 8/6`**, which is what the
player's hand did, and that hop multiset is not in `legalMoves` at all — the
generator lists `13/11 11/6` for the same position. So the harness scores
**positions, not hop multisets**: that is what the game itself means (`GameState.play`
folds any decomposition through `canonicalPlay`) and the only thing two settled
frames can possibly say. Scored by hops, the pipeline would have been marked
wrong on a play it identified correctly. Note also that `Move.sameAs` is *not*
this equivalence — it is order-insensitive over hops and says nothing about
transits — so the matcher folds re-orderings with `sameAs` (the same play written
twice is not an ambiguity) and ties by resulting board. **(The corpus half of
this is withdrawn, 2026-08-21 and again 2026-08-22: turn 3 is one man on a 2-1,
so the filmed game never produced the case and the signal reads 0 of 6. The rule
about scoring positions rather than hop multisets is unchanged and is carried by
`play_matcher_test.dart`'s fixtures. See the three CORRECTION notes at the end of
Task 8.)**

**Other things the task turned up, each measured.** (a) A folding case has no
bear-off wells, so a bear-off is **count-by-absence** — the point that lost a man
— and `PlayMatch.unobservable` names the tray that could not confirm it rather
than scoring a region the board does not have. (b) `PlayMatcher.minConfidence`
does **not** separate the right play from the runners-up and no threshold could:
on the synthetic bed the winner is 1.000 and the best rival (a legal play
differing by one hop, on regions the reader was unsure of) reaches 0.562, while
the real corpus's worst correct answer is 0.542 — overlapping bands, so telling
two *legal* plays apart is the ranking's job. What the threshold separates is
diffs no legal play produced, and four of those were measured separately: one
checker moved backwards to a point no roll reaches scores **0.243**, a whole
legal play run in reverse along its own four regions **0.281** (the hardest —
right about every region and amount, wrong only about direction, and the case
that pins the deltas being signed), the wrong player's move **0.162**, an
untouched board **0.217**. (c) The two frames are read in
their own light each; the pair survives a **35% exposure swing** between them at
no cost at all and loses the play at 56%, where the classic palette's white
checkers start clipping — a colour-model limit `occupancy_test` already pins.
(d) `PlayMatch.instability` — change on regions no candidate claims — is the
unmodelled-event signal the design asked for: it cannot reorder candidates, it
lowers the whole list together, and on the real corpus it runs 0.00 to 2.93.
(e) **A submitted hop order is never applied.** `BoardState.applyMove` is
order-dependent for a hit and documents itself as safe only for an
assumed-legal play — `GameState.canonicalPlay` exists in `backgammon_core` for
exactly that reason — and this matcher applies candidates to work out what each
would have left behind, from an arbitrary `List<Move>`. Measured on a Black
blot on White's 11-point: `13/11* 11/6` written the other way round applies to a
board with a phantom second Black checker on the 11 and nobody on the bar, and
that board scored **0.540 and came back plausible at rank 1**. Nothing in the
app produces such an order today (neither `legalMoves` nor `legalVariants`
does), but a replayed log, a remote peer or hops reassembled from a tap-by-tap
correction all can. `PlayMatcher._settle` now tries the order given and falls
back to the hop multiset's permutations (at most 24, only ever reached by input
already wrong); a multiset no order can play is not a candidate at all and is
dropped rather than ranked against an invented board. (f) The two frames must
share a **calibration epoch** — recalibrate between them and the difference is
noise shaped like a play, silently. A `Frame` is bytes and carries no
provenance, so nothing here can check it: Task 9's drift path owns invalidating
any held before-frame, and the precondition is stated on the API. Likewise
`isAmbiguous` is position-equality only and **not** a near-margin signal (real
top-to-runner-up margins run 0.179–0.608 with rivals reaching 0.444, every one
of them with `isAmbiguous` false), and `unobservable` deliberately does not
lower the confidence — the verifier must read the field, not the number.

### Task 8: Expected-board verification, stack verify, drift recovery

**Files:**
- Create: `packages/board_vision/lib/src/board_verifier.dart` (`verifyExpectedBoard(Frame, BoardState expected) -> BoardDiscrepancies` — per-ROI agree/disagree with confidence; stack heights checked by edge-periodicity against the expected K and calibration's checker diameter)
- Create: `packages/board_vision/lib/src/drift.dart` (`DriftReport` = discrepancy set + suggested resolutions, consumed by the app's side-by-side resolve UI)
- Test: `packages/board_vision/test/board_verifier_test.dart`

- [x] Steps: failing tests (correct board verifies clean at both halves; one misplaced checker names exactly the two wrong ROIs; 5-stack vs 4-stack distinguished with the prior) → implement → harness gains placement-verify + resync scoring → green → commit `feat(vision): expected-board verification and drift reporting`.

**As implemented (Task 8): verification is a contradiction test, and that is
where the prior's value comes from.** A blind count is a length over a pitch and
must choose between K and K±1 by **rounding**, so its answer flips at half a
checker and everything finer is discarded. Handed K, the query is only whether
the picture says otherwise — a wider question with a wider window, and the width
is the whole mechanism. `BoardVerifier.stackTolerance` is **0.75**, pinned
between two bounds and by a mutation from each side: *above 0.5*, the boundary a
blind count's rounding sits on, so verification agrees on a strict superset of
the regions a blind count gets right; *below 1.0*, because catching a man put on
the 7 instead of the 8 is the query's entire job. Set it to 0.5 and 'a stack a
blind count gets WRONG still verifies' goes red; set it to 1.0 and the 5-vs-4
test does. Measured cost of the window: on a bed calibrated under a lamp
gradient and read with the stacks left a hand's width in, a four-stack measures
4.37, so a man missing from a five-stack *there* is 0.63 out and inside it. At
the corpus's own grade the same residuals run under 0.05.

**As measured (Task 8): the prior is worth fifteen regions on real photographs
and costs none.** Compared **like for like** — the 240 point-reads both rows
score, on the same ten frames and the same sidecars — verification is
**203/240 = 0.846** against a blind count's **189/240 = 0.787**. Fifteen regions
rescued, zero lost, counted one `(region, side)` at a time inside a single pass
so that every mark is the two instruments answering about the identical read.
On the synthetic corpus, **713/720 = 0.990** against **695/720 = 0.965**,
eighteen rescued and none lost. Both pinned exactly, not bounded:
`greaterThan(0)` would pass on one rescued region out of eighteen, which is the
difference between a query that earns its complexity and one that does not.

**The two per-region rows' totals are NOT the comparison, and saying so is part
of the finding.** `regionVerified` asks both ends of the bar on every shot,
because a man left on the bar is exactly the drift the query exists to find;
`regionOccupancy` scores a bar side only where the game puts men on it. On the
real corpus that is 260 reads against 241, and the nineteen extra are bare-bar
agreements — free marks worth about a point. Reported as 0.858 vs 0.784 the
verifier looks better than it is, which is why the harness now prints the
like-for-like pair under both corpora and the tests pin that pair rather than
the totals.

**The 066 bar is the acceptance case and it agrees.** Blind occupancy reads the
worn hinge as empty — run 0.025 where a checker on that board is 0.087 deep, so
`StackMetrics.holdsAnything` refuses it, *correctly*, because asked blind it
cannot tell that run from the rim-and-shadow nine bare points of the same session
produce (0.021 to 0.042). Asked whether one Black man is standing there, the same
run divides into **1.28** checkers through the calibration's own fitted line and
the region agrees. Asked of 070's bare bar — run exactly zero — it disagrees.
**Calling a region bare takes both instruments and each half is holding up a
case the other gets wrong** — measured by deleting each in turn. The *line*
keeps 066: a run under `holdsAnything`'s floor that this board's own fit makes
1.28 checkers of, so the run test alone calls the bar bare with a Black man
standing on it. The *run* keeps a genuine lone checker: one man measures
**about** one checker and "about" straddles one, so `height < 1` alone calls
real single men bare — delete the run test and a White man standing alone on the
4-point comes back as "the camera sees nothing", on both palettes at once. Drop
either half and a test goes red, and the two failures are in opposite
directions.

**The two whole-board rates MISS the spec, and the reason is arithmetic rather
than perception.** Placement verification **0/6** and full-board resync **0/10**
on the real corpus; resync **22/30** on the synthetic one (placement is unaskable
there — no two shots are one turn apart). Both are floored at what they measured
and the gap is printed on every run, exactly as the dice are. These are the only
two targets in the spec's table whose denominator is a **whole board** rather
than one answer — twenty-six regions on a folding case and twenty-eight on a
cased one, the bar counted twice because its two colours stack away from each
other. On the synthetic corpus (all cased): 0.9869 per region, twenty-eight in a
row, is **0.691** if the misses were independent; the measured **0.733** is a
little better because they are not — one bad shot tends to lose several regions
together. Either way the ceiling is nowhere near 0.90, and reaching it per board
would need per-region accuracy of **0.9962** (0.9960 over the real board's
twenty-six). That is not a threshold anybody chose; it is what 0.90 costs. Every
one of the synthetic corpus's eight failing shots fails on a region a blind count
also gets wrong — a three-stack lost under a lamp, a phantom stack, a man lost on
the bar — so the verifier is not what is missing. On the real corpus it is the
far-half undercount arriving where it **cannot be differenced away**: the 12- and
19-points' Black five-stacks read as two and three in every single window, which
is precisely the bias Task 7's matcher subtracts from itself to score 6/6. Two
things for the gate: whether ≥0.95/≥0.90 *per whole board* is the right shape of
promise at all, and that the query a session actually needs after dictating a
move is **narrower** than the API's whole-board sweep — the regions that moved
are known, and `BoardDiscrepancies.regions` already carries them one at a time.

**USER DECISION (gate follow-up, 2026-08-21): the two rows are reshaped, and the
real fix is scheduled.** The gate asked exactly the two questions above and the
user answered both. Neither threshold moved — they are still **0.95** and
**0.90** — and neither was allowed to drift down to meet a measurement. What
moved is what an attempt is:

- **Placement verification** is scored on **the regions the play touches**, one
  attempt per dictated turn. That is the query a session actually makes: Buddy
  says "13/8, 8/6", a hand goes to three regions, and those are the ones the
  claim is about. `regionsTouchedBy(Move, Player)` derives the set from the
  play's own hops — both ends of every hop, so an intermediate landing point is
  asked about even though the position does not record it, plus the other
  player's end of the bar on a hit — and `BoardDiscrepancies.agreesOn` answers
  about exactly those.
- **Full-board resync** targets **≥0.90 per region**. Per whole board the number
  was arithmetic rather than a promise (the paragraph above), and what the
  side-by-side resolve screen consumes is the region list anyway.
- Both **whole-board rates stay in the report as watched rows** — `placement
  verified (board)` and `full-board resync (board)` — floored at what they
  measure and promised nothing. A demoted row that disappeared would be
  indistinguishable from a row that was hidden.

**What the reshape is worth on its own, measured on the day it landed: 2/6.**
Placement verification on the real corpus goes 0/6 boards → **2/6 turns**, and
per-region resync is unchanged at **0.858** (the reshape renames the row that
was already being counted; it does not move the number). The four turns it does
not buy fail on three regions for three different reasons — the 23-point reads
three men for two on 003→005, the 6-point four for five on 005→008, the
12-point two for six on 008→010 and again on 018→020 — and those are the
far-half tall-stack cases below. The synthetic corpus, whose per-region rate is
0.986, now meets every spec target it can ask. **The reshape is bookkeeping and
was recorded as bookkeeping**; the perception work is what the rest depends on.

**As measured (the far-half tall-stack undercount, 2026-08-21): the gap a stack
may have inside it is a CHECKER'S, not a region's.** The chronic misses were
instrumented before anything was changed — every stack the sidecars label, on
all ten real frames, dumped as truth against measured run, implied count, and
the raw row-coverage profile behind them. Four mechanisms came out, and they are
not one problem:

| what | where | what the profile shows |
|---|---|---|
| **run fragmentation** | the 12-point's Black 5/6-stack, every window | the stack is all there — its covered rows span 0.34–0.46 — but the run stops at a gap partway up and measures 0.07–0.10, so it counts **2** |
| **backlight truncation** | the 19-point's Black five-stack | the top of the stack is not classified at all; the covered rows simply end at 0.225 where five men reach 0.35 |
| **rim contamination** | the 23-point, every window | the run starts at row **zero** on the far half, where the board's own rim and the shadow in its seam classify as Black; half a pitch of that turns two men into **3** |
| **the photograph is not the ledger** | the 6-point, from 008 on | the White stack measures 61 rows in 008 and 42 in 018, on the same column through the same calibration that measured 80 rows for five men in 001. The crops confirm it: four discs in 008, three in 018, against a ledger that says five |

**The fourth row was read the wrong way round twice, and the two corrections at
the end of this task are what it turned into.** "The photograph is not the
ledger" was recorded as a limit on the corpus; the photograph was right and the
*ledger* was wrong — on two turns by the first correction's reckoning, on five by
the second's. The difference between four discs in 008 and three in 018 is **not**
a checker that left the board, which is what the first correction concluded: it
is turns 3, 5 and 7 having moved men the transcript put elsewhere. The
measurement stands exactly as taken — it is the interpretation that moved, and
then moved again.

**The "one pitch per half?" open question is answered, and the answer is no.**
Fitting reach against labelled height separately per half, over all 109 labelled
stacks of the session, gives **0.0676 near against 0.0640 far** — a five percent
difference — while the residual scatter about either line is **0.5 checkers**.
A per-half pitch would buy nothing measurable and would spend a calibration
degree of freedom to do it.

**The dominant fixable mechanism is fragmentation, and the bound was wrong for a
nameable reason.** `maxProfileGap` was six ROWS, and a row is a hundred and
twentieth of the *region*, which has nothing to do with a checker: on this board
six rows is 0.29 of a checker, on another board it is something else. The
question the bound has to answer is physical — *could a checker be hiding in this
gap?* — so it is now [`checkerMinBody`], this package's own measured answer to
how shallow a real checker can look, converted to rows per profile. On a point
that is **8 rows**. Measured over every labelled stack of the session, the
interior gaps run **1–2 rows (195), 3–6 (46), 7–8 (18)**, then a thin tail of 9
and over where stacks actually end: the old bound sat inside that distribution
and cut eighteen genuine stacks in half.

**Red-first, on a bed that models the mechanism.** `StackPlacement.faceGain`
paints the moulded well a real checker has and a drawn one does not — the thing
`ShotDegradation`'s own doc lists as what the photographs are for. A row through
a welled disc only crosses the ring around it, so coverage dips **once per
checker, in the middle of it**, which is both the shape (0.2–0.3, not zero) and
the size (seven rows) the real profiles show. On that bed a five-stack reads
**four**; with the bound derived it reads five and the board verifies clean.
Mutation-verified in both directions: put the flat six back and the bed's
five-stack drops to four (reach 0.375 = 4.39 checkers) and the derivation test
goes red.

**What it moved, honestly, on the real corpus:**

| row | reshape only | with the fix |
|---|---|---|
| placement verified (touched) | 2/6 | **3/6** |
| resync, per region | 223/260 = 0.858 | **230/260 = 0.885** |
| the like-for-like point slice | 203/240 = 0.846 | **210/240 = 0.875** |
| rescued from a blind count / lost to it | 15 / 0 | **22 / 0** |
| region colour and count (blind) | 189/241 | 189/241 |
| region colour alone | 230/241 = 0.954 | **228/241 = 0.946** |
| placement (whole board), full-board resync | 0/6, 0/10 | 0/6, 0/10 |

**And what it cost, which is two regions and is named.** The 12-point's five men
now measure at calibration where they used to collapse, so the fitted pitch is
regressed over **seven** of the eight labelled stacks instead of six and comes
out 0.0831 against 0.0868 — four percent, well inside the ±5% scatter the three
surviving five-stacks show among themselves. `holdsAnything`'s floor is half a
pitch, so it moves with it, and on the 23-point of shots 001 and 003 a run of
0.0417 — the rim again — lands **exactly** on the new floor and reads as a
phantom Black man. That is the error running in the direction
`ColorModel.classify` deliberately breaks ties in: a checker that appears
contradicts the expected state and gets asked about, where one that vanishes
does not. The synthetic corpus pays one region of the same kind (a lone White
man under a lamp reading as two, 712/720 against 713). Both floors were
re-measured deliberately, in this commit, rather than left to be discovered.

**What is left is not a reach-measurement problem, and the numbers say so.** The
23-point's over-count is the board's own rim inside the region the corners
define — the plan already measured that corner luck alone spans 13/24 to 23/24
exact counts, and this is that error wearing a stack's clothes. The 19-point's
truncation is the colour model losing the top of a backlit near-black stack,
which the brightness-bound dead end above already priced. And the 6-point is not
a perception failure at all: **the photograph and the ledger disagree**, so no
estimator can score it. Together those are the ceiling on this corpus — 5/6
placements at best, and the honest way past it is more photographs rather than
more thresholds. **(Wrong, and corrected the next day: the ledger was the thing
that disagreed with itself. The 6-point is fixed and the cap is lifted. ~~What
the cell was really hiding was an 8-point undercount~~ — wrong again, and
corrected the day after by measurement: the 8-point holds two men throughout and
always did. What the cell was hiding is that this board's rim eats the man at a
point's base — the wide end against the near rim. (Called the *tip* until
CORRECTION III on 2026-08-23; the tip is the midline end and nothing happens
there.) See the three CORRECTION notes at the end of this task.)**

**Other things the task turned up, each measured.** (a) **"A whole stack does not
vanish into a misread" is false**, and the bed proved it: `checkersUnderLamp` on
the classic palette — the only near-black checker the bed has — loses **four
whole Black stacks at once**, runs of 0.02–0.03 where a checker is 0.09 deep. So
an absence routes to `askTheUser` at every stack height rather than to the user's
hands, and the lamp bed is a test that asserts the verifier does *not* verify
clean. (b) **A colour contradiction must be weighed by the reading of the colour
that IS there.** `readFor` on a colour a region does not hold returns an *empty*
reading whose confidence collapses as the other colour fills the region, so
taking the weight from that side makes the clearest colour flips the least
confident findings on the board and inverts the resolve screen's whole ordering.
Caught by mutation, pinned by 'a colour that flipped outranks a tall stack that
read short'. (c) Every confidence here is one product — what this **kind** of
evidence is worth on this pipeline (colour 0.954, presence 0.9, absence 0.8,
count 0.9/0.6/0.3 by stack height) times what the **reading** was worth — the
same discounting `PlayMatcher.minEvidence` exists for, and floored at the same
0.25 for the same reason. (d) A trayless board's bear-off wells are reported
`unobservable`: not a contradiction and **not an agreement**, consuming
`PlayMatch.unobservable`'s philosophy exactly. Report them as agreements and two
tests go red. (e) The real session's eighteen single-checker expectations have
exactly **one** with no run of its own colour, and that one has the opponent's
man standing on it — so it is a colour contradiction before it is ever an
absence. A blind count loses far more lone men than that; the run underneath
them is still there to be measured, which is the 066 mechanism at large. (f) The
harness's new rows are shown to be able to fail: the `playedSomethingElse`
fixture now reddens **three** targets at once (play-ID, placement, resync — three
instruments agreeing about one planted lie), while `wrongRoll` leaves both board
queries at 1.0, since dice lie in a band no game is played on.

**CORRECTION (2026-08-21): the photograph was right and the ledger was wrong,
and a checker had left the board.** ⚠️ **Half of this note is itself superseded —
see CORRECTION II below.** Its first half stands (the photograph was right and
the ledger was wrong); every specific turn it names, the checker it says left the
board, and every number in its table were overturned by measurement the following
day. Kept whole rather than edited, because a correction that quietly re-wrote
itself would be the third thing this episode has to apologise for. Read it as
what was believed on 2026-08-21.

The reshape work above recorded a mechanism
it called *"the photograph is not the ledger"* — the 6-point measuring 61 rows in
008 and 42 in 018 through the same calibration that measures 80 rows for five men
in 001 — and priced it as a **cap on the corpus**: "nothing this package can do
scores that last one", 5/6 placements at best. The reviewer of that work would
not let the cell go and flagged it as a transcription doubt rather than a
perception limit. A zoom re-audit of the raw frames settled it, and the reviewer
was right on both counts:

- **Turn 3 was `W 3-2: 13/8`, one man** — not `W 5-2: 13/8 8/6`. The 8-point
  holds three at 008 and the 6-point four (unchanged from turn 1); the dice lying
  in 006/007 show a clear 3 with the partner blurred, and 5-3, 4-3 and 4-1 are
  each refuted on the frames, which leaves 3-2. The phantom second hop was a
  machine delta on the session's **worst cell** — the very cell every later
  sidecar was then scored against. A one-man 13/8 can run via the 10 or the 11
  and no photograph can say which, so the ledger records the transit
  `canonicalPlay` folds both to (`13/11 11/8`) rather than claiming to know.
- **Turn 8 was `B 5-3: 12/17 17/20*`** — not `B 5-2: 12/17 10/12`. Black stands
  on the 20 at 020 and White's freshly entered man is on the hinge.
- **And during turn 7 a White checker left the 6-point and did not arrive
  anywhere.** It is lying at the near rim, roughly where the 9- and 10-points
  meet, outside every region the atlas has; the 6-point holds three from 018 on
  where the ledger says four. This is **the first real sloppy play the corpus has
  caught** — the exact drift scenario the verifier exists for, arriving as a fact
  about a filmed game rather than as a planted fixture. No sequence of legal
  events reaches those two frames, so **018 and 020 became board-only shots**
  (`events: null`, an explicit position — the pattern 066 and 070 already use),
  with the stray carried as `off`. That is pragmatic rather than true, and it is
  harmless for the reason it is honest: a folding case has no wells, the verifier
  reports its trays `unobservable`, and the stray genuinely sits outside every
  region.

**The matcher row retires from six pairs to five, and that is a denominator
change rather than a failure.** 018→020 was one of the six windows genuinely one
turn apart; two hand-read boards with no log between them are not a pair, and the
harness derives which pairs qualify from the sidecars' own event logs, so the
retirement needed no code and no list to be edited. There is no certified roll
behind it either — a 3 lies visible at 020 with its partner hidden behind the man
on the bar. This supersedes the structural description in Task 6 ("seven
positions off the transcribed turn ledger, two end-game keyframes" → **five
positions and four board-only shots**) and the six-pair rows in Tasks 7 and 8.

**What it moved, honestly. Every row re-measured in the same commit; the old
numbers are kept beside the new ones because a floor that quietly changed shape
is a floor nobody can audit.**

| row | before (as committed 2026-08-20) | after the correction | why it moved |
|---|---|---|---|
| calibration, start confirmed | 1/1, 1/1 | 1/1, 1/1 | 001's truth is the starting position and did not change |
| dice pair read, no dice read as no dice | 0/4, 6/6 | 0/4, 6/6 | the four human-read rolls are untouched |
| legal-play identification | 6/6 | **5/5** | 018→020 retired; the five that remain are all still right |
| legal play acted on | 6/6 | **5/5** | same pair, same five above `minConfidence` |
| legal-play candidates | 11.7 mean (7–18) | 14.0 mean (7–21) | turn 3 is a 3-2, which the engine offers more plays for, and the retired pair leaves the set |
| the transit was not the listed one | 1 of 6 | **0 of 5** | turn 3's phantom hop was the only one; see below |
| region colour and count | 189/241 = 0.784 | **192/242 = 0.793** | 018 gains its 6- and 8-points outright; 008/010/013 each trade a 6-point miss for an 8-point one; 020 trades three fixed cells for three new ones and gains a bar read |
| region colour alone | 228/241 = 0.946 | **228/242 = 0.942** | identical successes over one more attempt — White's man on 020's bar, which the reader does not see on the hinge |
| resync, per region | 230/260 = 0.885 | **231/260 = 0.888** | 018 gains two regions, 020 loses one net |
| the like-for-like point slice (verified / blind) | 210/240, 189/240 | **212/240, 192/240** | both instruments had been scored against the same wrong cells |
| rescued from a blind count / lost to it | 22 / 0 | **21 / 0** | one "rescue" was the prior defending a wrong expectation |
| placement verified (touched) | 3/6 = 0.500 | **1/5 = 0.200** | see below — this is the one that fell |
| placement verified (board), full-board resync | 0/6, 0/10 | 0/5, 0/10 | unchanged in kind |

**The placement row fell and nothing about perception got worse — which is the
point of measuring it this way.** Three things happened at once: 018→020
**retired**, and it was one of the three that passed; 005→008 **still fails but on
a different region**, because the 6-point's "four men for five" was the ledger and
with the ledger right the same frame contradicts the corrected 8-point instead
(three claimed, 2.19 checkers measured); and 010→013 **turned from pass to fail**
on that same 8-point, where truth moved a man the reader does not see. So a
genuine near-half undercount had been sitting behind a transcription error, and
correcting the error is what exposed it. The floor moved **down**, by measurement,
in the same commit — a floor that had been quietly flattered is now a floor over
what this pipeline actually does.

**What the correction takes away, and it should be said rather than quietly
dropped: the plan's ambiguity-honesty case in the wild.** Task 7 recorded that
"turn 3 of the filmed game is `W 5-2: 13/8 8/6`", a hop multiset
`MoveGenerator.legalMoves` does not list at all, as the corpus producing the
ambiguity case unprompted. That evidence is withdrawn — the turn was one man on a
3-2 — and the signal now reads zero. **The rule it was quoted for is unchanged**:
the harness scores positions and not hop multisets because that is what
`GameState.play` means and the only thing two settled frames can say. It is now
supported by `play_matcher_test.dart`'s fixtures alone, and pretending otherwise
would be citing evidence that no longer exists.

**And the cap the last note put on this session is lifted.** "Nothing this
package can do scores that last one; it is a corpus finding, and it caps this
session at 5/6" was true of a wrong ledger. The three mechanisms that remain —
the 23-point's rim contamination, the 1-point's lone man at a run of 0.0125, and
the 8-point's 2.19-checkers-for-three — are all counting problems this package
could in principle fix, and 5/5 placements is arithmetically available on this
session again.

**CORRECTION II (2026-08-22): the correction above was a person reading zooms,
and it was wrong about five of the eight turns. Nothing ever left the board.**
The reviewer of that work re-measured the committed JPEGs instead of looking at
them — cream/dark pixel mass and stack-top row per point column, through this
session's own calibration, with 001 as the control — and overturned its central
claim. Re-measuring every cell the same way, cross-checked against a disc count
on the 1920-wide source frames and against fifteen men a side, overturned most of
the rest. The corrected ledger replays as **eight legal turns**, every play in
`MoveGenerator.legalMoves`'s own list, reproducing all seven photographed
positions exactly.

**What the instruments say.** Four of them, and each cell below is pinned by at
least two:

- **mask mass**: cream and dark pixel counts inside each point's region, at
  luma ≥165 / sat ≤0.25 for cream and a two-tier dark rule (the second tier
  exists because a checker at the rim catches the window's own light and comes
  back a desaturated blue-grey — 88,98,109 against the same frame's stacked men
  at 52,55,57, with the warm wood between them at 169,137,116);
- **stack top**: the far end, in board-y, of the run from the point's own edge.
  A column's pitch is constant, so this counts men: the 8-point tops out at
  0.783 with three and 0.87 with two, the 6-point at 0.658 / 0.742 / 0.817 for
  five / four / three;
- **blob centroid**, inverted through the geometry, which says *which column* a
  checker is on;
- **the pipeline's own reader**, as a second opinion with no shared code path.

| claim (2026-08-21) | what the pixels say |
|---|---|
| the 8-point holds **three** from turn 1, and the corpus was hiding a genuine 8-point undercount | **two**, from turn 1 to the end. 001 measures 5527 cream px topping at board y 0.783; every later window 3227–3468 px at 0.87. The pipeline reads white x2 on all seven (reach ≈0.113). **The undercount never existed — perception was right about that cell and the ledger was wrong** |
| a White checker **left the board** during turn 7 and lies at the near rim | nothing ever left it. The cream shape appearing at the rim from **008** is a White man standing at the **10-point's base** (~~tip~~ — see CORRECTION III), three quarters behind the case's raised rim: blob centroid inverts to board x 0.166 at 008 and 0.178 at 010, against the 10-point's centre of 0.194 (one systematic top-face displacement), and by 013 it is a clean two-checker stack, 3852 px topping at 0.867. Fifteen White men are on points in every window |
| turn 3 was `W 3-2: 13/8` | **`W 2-1: 13/10`**, one man. The 13-point drops 5→4 (disc count) and the 10-point gains its first man. Three pips with the 12-point blocked can only be the 2 then the 1, and every die value was playable from that position, so no die went unused |
| turn 4 was `B 6-5: 1/7 7/12` | **`B 6-4: 1/11`**, one man. The 12-point's stack top does not move until 018 (0.592 through 013, 0.500 after); a separate Black crescent appears at the **11-point's base** at 010 and is gone at 020. Ten pips with the 6-point blocked cannot be 5-5 |
| turn 5 was `W 5-1: 13/8 8/7` | **`W 6-3: 13/7 13/10`**, two men. The 13-point drops 4→2, the 10-point rises 1→2, and the 7-point gains the blot turn 6 then hits. This is the roll lying on the felt in 013's own frame, which the ledger had been reading as the *next* turn's |
| turn 8 was `B 5-3: 12/17 17/20*` | **`B 6-3: 11/14 14/20*`**, one man from the 11-point. Destination and hit stand. ~~The 6 is the die visible beside the man on the hinge~~ — **the ROLL is inferred, not forced**: nine pips, and 5-4 reaches the same board with the same hit (the 15- and 16-points are both open at 018). See CORRECTION III |

**The T7 adjudication, since it is the one that decides whether the game was
played legally at all.** The question was whether 018 shows `bar/20 6/2`
(4-point 2, 2-point 1) or a two-pip `6/4` (4-point 3, 2-point 0):

| cell | 013 | 018 | verdict |
|---|---|---|---|
| 4-point, cream mass | 3150 px | **5138 px** | +1988 ≈ one checker at this column's ~1700 px/man |
| 4-point, stack top | 0.892 | **0.808** | one pitch (0.080) higher |
| 4-point, pipeline | white x2, reach 0.0958 | **white x3, reach 0.1750** | agrees, independently |
| 2-point, cream mass | 0 | **0** | empty, as in every window including 001 |
| 6-point | 4 (0.742) | **3 (0.816)** | one man left it |
| 8-point | 2 (0.875) | **2 (0.872)** | did not move |

So **turn 7 is `W 5-2: bar/20 6/4`** — a legal turn, not a sloppy one. The
2026-08-21 note's "first real sloppy play the corpus has caught" is withdrawn
entirely: this corpus has caught no sloppy play, and the drift the verifier
exists for remains a planted fixture rather than a filmed fact.

**The 020 adjudication.** Every cell pinned by at least one quantitative
instrument, so the shot stays: 20-point **Black 1** (dark run 0.108 against the
0.033 bare-wood baseline and the 23-point's 0.192 for two — the harness's
"camera sees Black 2" is the reader over-counting, not the sidecar being wrong),
10-point **White 2** (3861 px, top 0.867, two discs at full res), 12-point
**Black 6** (top 0.500), 17-point 2, 19-point 4, 23-point 2, 24-point White 2
(all confirmed on a far-right crop), White **on the bar** (the man is
unmistakable on the hinge at full res), 4-point 3 and 6-point 3 per the table
above. Turn 8's roll is `6-3` **by inference and not by construction** — nine pips by
one man, and 5-4 reaches the identical board with the identical hit, so the 6
visible beside the bar man is what chooses between them rather than what proves
one. (Corrected in CORRECTION III, which also finds that 6 to be on the face
that die shows the camera rather than on its top.) The PAIR 018→020 is certified
by the boards either side of it, which is what the matcher row needs; the roll
is not.

**010's dice are 6-4, not 6-5, and this is the one sidecar fact that changed by
derivation rather than by reading.** This camera sits low enough that a settled
die shows its front face and not its top: neither of 010's dice can be read from
this frame, and the 2026-08-21 zoom read them 6-5. A ten-pip one-man play out of
the 1-point with the 6-point blocked four deep cannot have been thrown any other
way, so 6-4 it is — the same ground-truth-by-construction the boards get,
applied to the felt. The other three (4-2, 6-4, 6-3) each match the turn they
were thrown for, which is now checked in `capture_plan_test.dart`.

**The structure, third and last time.** ~~Seven positions and two keyframes~~
→ ~~five positions and four board-only shots~~ → **seven replayed positions and
two end-game keyframes**, which is where Task 6 started. 018 and 020 are back in
the replay. The matcher row is **six pairs** again — 001→003, 003→005, 005→008,
008→010, 010→013, 018→020 — with three unpaired neighbours named (013→018 spans
two turns, and the two keyframes carry no log). No new schema and no annotation
mechanism: the event log the sidecars already carry reaches every shot but the
last two, so there was nothing left for an annotation to say.

**What it moved. Every row re-measured in the same commit, old numbers kept.**

| row | before (2026-08-21) | after (2026-08-22) | why it moved |
|---|---|---|---|
| calibration, start confirmed | 1/1, 1/1 | 1/1, 1/1 | 001 is the starting position and never moved |
| dice pair read, no dice read as no dice | 0/4, 6/6 | 0/4, 6/6 | four rolls claimed either way; only 010's value changed |
| legal-play identification | 5/5 | **6/6** | 018→020 is a pair again, and it is identified right |
| legal play acted on | 5/5 | **4/6** | the two turns with a rim-hidden man in the difference come back under `minConfidence` — right, but not confidently. ~~the two turns that land a man on a point's tip~~: true of 005→008 (White arrives at the 10-point's **base**), not of 018→020, where what is hidden is the man **leaving** the 11-point's base and the White man **arriving on the hinge**. Under the old truth those men were on cells the camera sees well |
| the transit was not the listed one | 0 of 5 | **0 of 6** | turns 4 and 8 are one-man runs whose road no photograph can name, so the ledger records the generator's own representative |
| region colour and count | 192/242 = 0.793 | **195/242 = 0.806** | three cells the old ledger had wrong |
| region colour alone | 228/242 = 0.942 | **222/242 = 0.917** | six regions moved onto point **bases**, against the near rim, where the reader sees *nothing* |
| resync, per region | 231/260 = 0.888 | **233/260 = 0.896** | net of the two above |
| the like-for-like point slice (verified / blind) | 212/240, 192/240 | **214/240, 195/240** | both instruments gain, as a truth fix should make them |
| rescued from a blind count / lost to it | 21 / 0 | **20 / 0** | one rescue was the prior defending a wrong expectation |
| placement verified (touched) | 1/5 = 0.200 | **1/6 = 0.167** | a sixth attempt, and it fails on the bar |
| placement verified (board), full-board resync | 0/5, 0/10 | 0/6, 0/10 | unchanged in kind |

**And the finding the whole episode was hiding: this board's rim eats the man at
a point's BASE.** (~~a point's tip~~ — the base is the wide end, against the near
edge, and the tip is the midline end where none of this happens. Corrected in
CORRECTION III.) Four of the five placements that miss are the same mechanism —
the folding case's rim stands proud of the felt, so the checker at the near end
of a near-half point is three quarters behind it and the reader returns
*nothing* there, not a short count. The 10-point's arriving man (005→008,
010→013), the 1-point's last Black man (008→010) and White's man on the hinge
(018→020) are all that. The fifth is the 23-point's rim over-count, unchanged.
None of this was visible while the ledger had those men on cells the camera
happens to see well, which is the real lesson: **a corpus scored against a wrong
ground truth does not merely score wrongly, it hides the mechanism that would
have explained the score.** Two of the floors went down and the pipeline was not
touched.

**CORRECTION III (2026-08-23): the correction above never re-audited the two
keyframes, and they were hiding four men between them.** (It did not finish the
job either — see CORRECTION IV.) CORRECTION II's
instruments — cream/dark mask mass per point column on the full-resolution
frames, stack-top row, blob centroid inverted through the calibration, the
pipeline's own reader as a second opinion, fifteen men a side — were run over
the seven **replayed positions** and stopped there. 066 and 070 carry a board
and no log, they had been read off zooms by a person, and nobody pointed the
instruments at them. Pointed at them, they say each frame is hiding **two White
men at the base of a near-half point**, exactly the mechanism CORRECTION II had
just named, and that the difference had been written down as `whiteOff: 2`. Both
boards were therefore illegal: thirteen men on points and two borne off a game
that has borne nothing off.

| cell | sidecar (v3) | measured | instrument |
|---|---|---|---|
| 066, 1-point | empty | **White 1** | 1666 cream px against 0–380 in every earlier window; blob centroid inverts to board x 0.962 against the point's centre of 0.961 |
| 066, 7-point | White 1 | **White 2** | 8243 px topping at board y 0.864 — the two-man signature (the 8-point reads 8420–8923 for two, 12337–14122 for three), not the one-man 1696 the same column shows at 013 |
| 070, 1-point | empty | **White 1** | 1512 px, a compact blob at board y 0.92–0.97 |
| 070, 7-point | White 2 | **White 3** | 12771 px topping at 0.765, one whole pitch above 066's |
| both, Black cells | — | ~~unchanged~~ | audited the same way; the dark mass in the 1-point column at 018/020/066/070 sits at v ≥ 1.045, i.e. on the rim beyond the board's near edge, and is not a man. **The near-half claim stands; the far half did not — two pairs of Black cells were transposed, and CORRECTION IV finds them** |

**The pipeline was right about the 7-points and the ground truth was wrong** —
the same shape as the 8-point on 2026-08-22, found the same way. The harness had
been printing `066: the 7-point: the camera sees White 2, the game says White 1`
and `070: … White 3, the game says White 2` on every run since Task 8, and it
was read as the reader over-counting. Corrected White boards: 066 = 1(1) 4(3)
5(2) 6(2) 7(2) 8(3) 9(1) 24(1), with 066's Black cells and its man on the bar
unchanged; 070 = 1(1) 4(3) 5(2) 6(2) 7(3) 8(2) 9(1) 22(1). Fifteen a side,
`whiteOff: 0`, and **nothing in this session ever leaves the board**. The corpus
loses the only position it had with men off it — the trayless bear-off path is
covered by `corpus_harness_test.dart`'s folding-case fixture instead — and a
corroboration falls out of the pair: White's cells still differ by exactly the
three pips of a 2-1 (8/7, 24/22), because the correction adds the same two men
to both frames.

| row | before (2026-08-22) | after (2026-08-23) | why it moved |
|---|---|---|---|
| calibration, start confirmed | 1/1, 1/1 | 1/1, 1/1 | 001 is untouched |
| dice pair read | 0/4 | 0/4 | 008 was read at magnification and not certified — see below |
| no dice read as no dice | ~~6/6~~ | **1/1**, and the row is renamed `no dice in frame, none read` | five of the old six have dice lying in them; the row was scoring the wrong set — see below |
| region colour and count | 195/242 = 0.806 | **195/242 = 0.806** | two rim-hidden men lost, the two 7-point cells gained; identical rate, different composition |
| region colour alone | 222/242 = 0.917 | **220/242 = 0.909** | the two 1-points, which the reader sees nothing of |
| resync, per region | 233/260 = 0.896 | **235/260 = 0.904** | the two 7-point contradictions disappear, and the state-primed read keeps the two 1-points — **this row clears its 0.90 target for the first time**, by a truth fix rather than a pipeline change |
| the like-for-like point slice (verified / blind) | 214/240, 195/240 | **216/240, 195/240** | the verifier gains, the blind count does not |
| rescued from a blind count / lost to it | 20 / 0 | **22 / 0** | the two new rescues are exactly the rim-hidden men |
| legal-play identification, acted on | 6/6, 4/6 | 6/6, 4/6 | the keyframes are in no pair |
| placement verified (touched), (board), full-board resync | 1/6, 0/6, 0/10 | 1/6, 0/6, 0/10 | unchanged in kind |

**Second finding: `diceAbsence` was paying the reader for failing to see real
dice.** The row reads *"no dice read as no dice"* and its denominator was every
shot with no certified roll — six of the ten windows, and **five of those six
have settled dice lying in them**. A reader that started seeing this board's
dice would have gone red on the one row it had just got right. Only 001 is
genuinely dice-free, which is not luck: it is the calibration hold, and a die
present at calibration is learned as one of the board's own surfaces. So the
sidecar gains an additive `diceInFrame` (explicit on all ten filmed shots,
absent from every generated one, where absent means "dice in frame exactly when
a roll is claimed" and the renderer guarantees it), the fork in `_scoreDice` is
on that, and there are now three outcomes rather than two: the absence row
(**1/1**), the pair row (**0/4**), and *dice in frame with no certified roll*,
scored on **neither** and named in the notes. A corpus with no answer to check a
reading against must not claim the reading was right. `diceDerived` marks the
one value that was derived rather than read (010's 6-4).

**What the dice actually show, read at full magnification on 2026-08-23.** How
much of a die's top this camera sees depends on **where the die lands**, which
is the scoped version of a claim this batch made too broadly (~~"this camera
sits low enough that a die shows its front face and not its top"~~ — true of the
far half, false near the middle):

- **008's note was wrong twice over.** ~~"No dice on the felt: the next roll is
  mid-throw."~~ Two settled dice lie in the far half at board (0.218, 0.234) and
  (0.251, 0.279) — absent at t=66.5, in those exact positions at t=76.5 **and**
  t=84.5, gone by t=94.5, so they are turn 3's own roll left where it fell.
  Read blind: each die is ~21 px across and presents a top face 7–8 px deep in
  which no pip pattern can be counted; what is legible is the near-facing
  **side** of each — a clean diagonal pair on one, five blobs on the other that
  read as a 3 and a 2 across two faces. A side face is not a roll, so 008 stays
  uncertified. (Recorded because it is uncomfortable: if those side reads are
  right, neither die can have a 2 on top, and the ledger's 2-1 for turn 3 is
  fixed by the **board** — one man, 13/10, three pips with the 12-point blocked
  — rather than by the felt. A four-pixel pip does not outweigh that arithmetic,
  and nothing was changed on the strength of it. **That tension is now in 008's
  own sidecar note as well as here** (2026-08-24): the note recorded both
  readings and let them sit side by side without saying they disagree, which is
  a thing a reader has to notice for themselves or not at all.)
- **018's dice are settled too**, and one of them carries a top face this camera
  can read: the die at board (0.398, 0.514), in the middle band, shows a clean
  **5**. Its partner is unreadable, and half a pair is not a roll. (~~the most
  legible top face in the session~~ — withdrawn 2026-08-24 as a superlative with
  no measurement beside it. 020's die at board (0.858, 0.405) reads its top just
  as cleanly, and no two tops in this session have ever been compared.)
- **020's second die does have a readable top**, at board (0.858, 0.405): a
  single centred pip, a **1**, with a diagonal pair on its near side. The other
  die's "clear 6" is on the face it shows **the camera**, not on its top. A 1
  cannot belong to turn 8's nine-pip one-man play, so that pair is most likely
  the next roll — and it certainly does not corroborate 6-3.
- **010's pair stays derived**, and the front faces are consistent with it
  without settling it: a clean 5 on one (so its top is neither 2 nor 5) and a
  diagonal run of three, possibly four, on the other (which excludes 3 and 4
  either way). Tops of 4 and 6 fit.

**Third finding: the mechanism's name pointed at the wrong end of the point.**
The invisible man stands at a point's **base** — the wide end, against the near
edge, where `StackAxis.forRegion` puts the stack's origin and where the harness
prints `reach 0.000`. Every note in this batch called it the **tip**, which is
the midline end and is where nothing happens. `targets.dart` had it right
throughout ("the man at the near end of a near-half point"). Renamed in
`capture_plan.dart`, `corpus_harness_test.dart` and this document; struck
through rather than deleted wherever it appeared, because a wrong word that is
quietly replaced is a wrong word nobody can learn from. The related phrasing
"the two turns whose play lands a man on a point's tip" was wrong about more
than the word: 005→008 does land a man on the 10-point's base, but 018→020 hides
the man **leaving** the 11-point's base and the White man **arriving on the
hinge**, and its destination is read (over-read, at Black 2 for Black 1).

**Fourth: turn 8's roll is inferred rather than forced**, and the note that said
"by construction" was claiming more than the evidence carries. 11→20 is nine
pips by one man; at 018 the 15- and 16-points are both open, so **5-4 reaches
the identical board with the identical hit**. 3-3 is excluded (a fourth 3 would
have to appear somewhere and does not). 6-3 is chosen for the 6 beside the man
on the hinge, which the reading above weakens further. The notation slip
~~`11/17 17/20*`~~ is corrected to the committed `11/14 14/20*`.

**What this episode is, said plainly.** Three corrections in three days, and the
third is not a new kind of error: it is the *same* error, in the two shots the
second correction never looked at. The lesson CORRECTION II drew — that a corpus
scored against wrong ground truth hides the mechanism that would explain the
score — applies to the auditor as well as to the transcriber. The two keyframes
were the weakest ground truth in the corpus by their own description, and they
were the last cells anyone measured. **The corpus's own arithmetic could not
catch it**: fifteen-a-side counts a man written off as a man, so `checkerCount`
passed on the wrong boards exactly as it passes on the right ones. What caught
it was pointing the instruments at every cell, which is now what "re-audited"
has to mean.

**CORRECTION IV (2026-08-24): the keyframes' Black cells were transposed, two
pairs of them, and every guard this corpus has was blind to it by construction.**
CORRECTION III put four White men back on the board and wrote that the Black
cells were "audited the same way" and unchanged. The near-half half of that is
true. The far half was not audited cell by cell, and it carried two
**adjacent-column swaps** — the right number of men written into the column next
door.

| cell | sidecar (v4) | measured | instrument |
|---|---|---|---|
| 070, 17-point | Black 1 | **Black 2** | rectified through the committed calibration on the atlas's own column bounds: two discs in the 17 column, one in the 18, on this frame and on 066 alike. The dark run down the 17-point reaches twice as deep as the 18-point's — 0.128 against 0.064 of board depth at 070, 0.136 against 0.072 at 066, where the pair is already committed 2 and 1 |
| 070, 18-point | Black 2 | **Black 1** | the same measurement, read the other way. Disc centroids sit at board x 0.365 and 0.429 against column centres of 0.351 and 0.429, so the columns are not in doubt; and the two frames' dark masks over that band overlap at **IoU 0.78**, which is to say nothing moved there between 066 and 070 |
| 066, 19-point | Black 3 | **Black 2** | per-checker dark mass across points 19–23. The corrected 2/3/2/1/2 reads **1403 / 1393 / 1459 / 1219 / 1314** px per checker — 16% spread over five cells, 0.7% between the two in dispute. The sidecar's 3/2 reads **935 against 2090**, a factor of 2.2 apart on adjacent cells of one board |
| 066, 20-point | Black 2 | **Black 3** | the same arithmetic; and the stack depths agree — 0.172 and 0.256 of board depth against 0.180 for the two-man 21- and 23-points and 0.092 for the one-man 22 |

**Why three audits missed it, said plainly: a transposition is invisible to
everything except looking at the cell.** Fifteen a side counts the same fifteen —
no man leaves the board, so `checkerCount` passes on the swapped board exactly as
it passes on the right one, which is the same blindness CORRECTION III named and
a *different* instance of it. `region colour alone` cannot see it either: the
cells are Black before and Black after, so that row does not move by a single
read (220/242, unchanged, and the row is doing what it says). And the reader's
own disagreement prints do not flag it, because the reader disagrees at those
cells under either truth — it reads Black 3 at 066's 19-point and Black 4 at the
20-point, so swapping the two expectations swaps which line is printed and not
whether one is.

**The reader's far-half readings at these cells stay honest perception misses.**
Nothing here says the pipeline was right and the truth wrong, which is what
CORRECTION II and III both found; this time the truth was wrong *and* the reader
is still wrong. It reads **Black 4 on 066's 20-point where the board holds
three**, and it over-reads 070's 18-point at two for one. Those are now scored
against the correct cells rather than against transposed ones, which is the only
thing that changed about them: the far half of this board over-reads tall stacks,
and it did so before this correction and does so after.

| row | before (2026-08-23) | after (2026-08-24) | why it moved |
|---|---|---|---|
| calibration, start confirmed | 1/1, 1/1 | 1/1, 1/1 | 001 is untouched |
| dice pair read, no dice in frame none read | 0/4, 1/1 | 0/4, 1/1 | no dice claim changed |
| region colour and count | ~~195/242 = 0.806~~ | **194/242 = 0.802** | 070's 17-point becomes a hit (the reader had been reading Black 2 there all along); 066's 19-point and 070's 18-point become misses, the corrected count at each being one under the reader's. 066's 20-point misses either way. One gained, two lost |
| region colour alone | 220/242 = 0.909 | 220/242 = 0.909 | **unchanged, and that is the row working**: a transposed pair is Black on both cells before and after |
| resync, per region | ~~235/260 = 0.904~~ | **237/260 = 0.912** | 066's 20-point and 070's 17-point stop being contradictions. The target is still met and by more — +0.012 clear of 0.90 where it was +0.004 |
| full-board resync (board) | ~~0/10~~ | **1/10** | **070 now resyncs as a whole board, the first in this corpus to do so.** Its only whole-board disagreement was the 17-point, and the 17-point was the transposition. The floor moves up with it |
| the like-for-like point slice (verified / blind) | ~~216/240, 195/240~~ | **218/240, 194/240** | the verifier gains two, the blind count loses one |
| rescued from a blind count / lost to it | ~~22 / 0~~ | **25 / 0** | 066's 19- and 20-points and 070's 18-point: the blind count over-reads each and the prior declines to follow |
| legal-play identification, acted on | 6/6, 4/6 | 6/6, 4/6 | the keyframes are in no pair |
| placement verified (touched), (board) | 1/6, 0/6 | 1/6, 0/6 | same reason |

**The lesson, and it is not the one from three days ago.** CORRECTION III's was
that the auditor must point the instruments at *every* cell, not only at the ones
a previous correction was about. This one is narrower and sharper: **conservation
is not verification.** Every check this corpus had that could run without looking
at a photograph — fifteen a side, legal replay, reader-disagreement prints — is
satisfied by a board with two columns swapped, because a swap conserves
everything they count. The only thing that finds it is measuring the cell. Four
corrections in four days, and the corpus is now measured cell by cell in both
halves of both keyframes rather than in the half a previous correction happened
to be looking at.

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

- [x] Steps: failing tests (moved-board frame → red + `calibrationStale` + `requiresRecalibration`; hand-over-board render → `occluded`, transient; dim render → `tooDark`; recovery to green when the condition clears) → implement (fingerprint from Task 3) → green → commit `feat(vision): continuous readability with recalibration routing`.

**As implemented (Task 9): a seventh cause, a reshaped geometry rule, and a shape the plan did not sketch.**

- **`tooBright` is the seventh cause, and it was already owed.** The plan lists six. Task 3 left a note on `CalibrationFingerprint.clippedFraction` saying in as many words that it is "the readability cause Task 9 has to raise, and this is the number that raises it" — a board lit 40% over its calibration clips a quarter of itself, and pale points and white checkers clip to the *same* white, which no colour model can undo. The plan's vocabulary had nowhere to put that. Folding it into `tooDark` would tell a user under a desk lamp that the room is too dark, so it got a name. `ReadabilityMonitor.maxClippedFraction` is `Calibrator.maxClippedFraction` rather than a number of its own, deliberately: two thresholds for one physical fact drift apart.
- **`geometryMatches` went from one RMS to a majority of patches, and the REAL corpus is the whole of the case.** The old rule averaged every cell of every corner, and an average cannot tell one patch that went completely wrong from every patch going slightly wrong — only the second is a board that moved. What spoils one patch at a time is play itself, since a corner patch reaches onto four of the board's busiest points. **Measured cost of the change:** sensitivity at the small end, and it is direction-dependent — swept over the eight axis and diagonal directions on the classic palette, a slide under a 1280-px frame fires in 3 of 8 directions at 5 px, 4 of 8 at 10, 5 of 8 at 15 and **8 of 8 at 20** (three or four patches out in every direction there). Straight along +x is the slowest cell of that table — silent at 5, 10 and 15 px, firing at 20 with three of four out (0.120, 0.453, 0.125, 0.185) — and this note twice described that one cell as though it were the whole table, first as "20 px no longer fires" and then as "20 px fires in six of the seven directions, only +x stays quiet". Both wrong; `readability_test.dart` now pins the cell from both sides. **Measured benefit:** on the ten real frames the old rule called six a board that had moved (010, 013, 018, 020 falsely, plus 066/070), at RMS 0.133–0.326 against a bound of 0.12 — and the first four are frames the pipeline reads correctly and identifies every play from. On the **synthetic** corpus the old rule fires on none of the thirty and both rules read 30/30; the worst single patch there is 0.152 but the worst old-rule RMS is 0.100. So the synthetic spike is what raised the worry and the real corpus is what proves the failure. (The commit message for `feat(vision): continuous readability with recalibration routing` says the synthetic corpus went "29 to 30 frames" under the change. It did not — it read 30/30 both ways. Corrected here because a commit message cannot be.)
- **The shipped shape is a class, not the free function the sketch shows.** `ReadabilityMonitor(calibration).assess(frame, motion)`, reached through `BoardVision.assessReadability(frame, motion)` — the same door every other query in the package uses. The monitor holds the calibration because every one of its bounds is a comparison against that calibration's own fingerprint, and a free function would have taken it as a parameter on every frame of the session.

**As implemented (Task 9, review round): the colour half of a stale calibration, and the bed knob it needed.**

- **"Colors no longer match" was in the spec, in the doc, and not in the code.** `assess` never consulted colour validity: the only route to `requiresRecalibration` was a geometry failure. A change of illuminant COLOUR leaves luma-normalised patches matching, so a frame whose cast had drifted well past `CalibrationFingerprint.maxCastDrift` — with `confirmStartingPosition` reporting four regions holding the wrong colour, and nothing clipped — read **green**. `CalibrationFingerprint.castMatches` is now split out of `exposureMatches` (one signal, one place) and `assess` asks it.
- **The bed could not draw the condition, so it grew a knob.** `LightCast` in `board_renderer.dart` is per-channel gains derived from Planck's law at 610/550/465 nm for a 2700 K lamp against a 6500 K white balance, normalized to hold a neutral grey's brightness so that "how much light" and "what colour" stay independent knobs. Existing renders are byte-identical (the corpus re-render guard checks it), because a neutral cast multiplies every channel by exactly 1.0.
- **The check is asked LAST, after occlusion, and that ordering is measured.** The cast is a board-wide statistic, so anything large enough to change the board's average colour moves it: on the blue-red palette a skin-coloured arm across the far edge takes the cast to 0.128/0.138 against a bound of 0.12 with nothing changed but what is lying on the felt. Asked before occlusion, that frame sends a user with an arm over their board to re-drag its corners. The one occluder that still slips through is one lying across the **dice band**, which the occlusion walk skips by construction — pinned as a test rather than tuned away.
- **Where the bound sits, measured per palette** (strength of a full tungsten shift, swept):

  | palette | last cast inside `maxCastDrift` | first outside | first `confirmStartingPosition` misread |
  |---|---|---|---|
  | classic | 0.15 (dR 0.115) | 0.16 (dR 0.122) | 0.25, two points |
  | blue-red | 0.08 (dB 0.117) | 0.10 (dB 0.143) | 0.40, one point |
  | low-contrast wood | 0.16 (dR 0.109, dB 0.111) | 0.18 (dR 0.124) | 0.25, two points |

  So the light goes red well before reading breaks on every palette — the same side of the same argument `maxClippedFraction` is set from: going red early costs one suppressed answer the next frame supplies, going red late costs a phantom checker in the authoritative game state.
- **And the exposure story was corrected rather than defended.** `minExposureRatio`'s doc argued 0.17 against what the pipeline still reads. Shipped behaviour goes red at **about a half** when only the board's light drops, because the corner patches reach outside the playing field and the room did not dim with the board. Both boundaries are real, both are now in the doc's table, and both are bracketed by tests (last-green and first-red pinned on each palette). The suppression cost between them is stated as a test: `confirmStartingPosition` is clean on the frame the light calls too dark.

**As implemented (Task 9, record round): what the same commit's tests already disproved.**

- **The occluder sweep was never re-run after the cast check was added under it.** The doc said `calibrationStale` "never came back once" over 28 occluder sizes on three palettes — true of the check as it stood, false of the commit that shipped its replacement, and disproved by that commit's own dice-band test. Re-run: **18 of the 84 come back `calibrationStale`, all of them on blue-red**, and all of them through `castMatches` rather than `geometryMatches` (checked per cell). They are the wide bands; classic is green on 26 of 28 with two `tooBright`, wood green on all 28. The pinned dice-band frame is one of the eighteen.
- **Past a strong enough cast the routing bit inverts, and it is recorded rather than fixed.** Above the strength where the cast has also moved the luma-normalised corner patches (or driven clipping past `maxClippedFraction`), `geometryMatches` gives out, `exposureMatches` fails with it — it consults the cast — and the light fallback names `tooDark`/`tooBright` on the luma ratio alone. Measured: classic routes to recalibration over 0.175–0.250 and is `tooBright` from 0.275; blue-red over 0.100–0.425, then `tooDark`; wood over 0.175–0.425, then `tooBright`. So a lamp swapped outright reads red + `tooBright` + `requiresRecalibration` **false** on all three palettes, with 4 to 16 misreads, and dimming does not clear it (`tooBright`, then `tooDark`, all the way down). **The obvious fix — consulting the cast inside the light branches — measured worse and was rejected:** clipping moves the measured cast on its own under a NEUTRAL lamp (wood's red ratio drifts 0.054 at 1.6 of its calibration light and **0.162 at 2.0**, past `maxCastDrift`'s 0.12), so that fix would send a board under a blazing white lamp to re-drag its corners. Both ends of the regime are now pinned. On a strict reading, the spec's "colors no longer match → recalibrate" clause is therefore satisfied inside the cast band and knowingly unmet above it — carried as a named open limitation (safe: red, answers suppressed, no state touched), not as a completed clause.
- **The on-board-cells alternative is recorded as rejected.** Restricting the patch comparison to the four cells of each corner that lie wholly on the playing field would remove the `tooDark`-when-only-the-board-dims cost — and it misses slides: on wood a 15-px slide fires in six of eight directions on the whole patch and two of eight on the inner cells, and two are still missed at 20 px. It would also invalidate every figure `maxPatchDrift` is derived from, all whole-patch.
- **Precision drift in the new figures, corrected against re-measurement:** the near-total-cover contrast ratios are 0.029/0.021/0.087 (not 0.030/0.022/0.091), the pale-band luma ratios 1.381/1.507 (not 1.380/1.504), and the far-edge arm's cast 0.128/0.138 (not 0.129/0.137). The `minExposureRatio` table's cells are now the true adjacent boundaries in commanded gain, with which quantity they are in said out loud, and all six are bracketed by tests rather than two.

**Carry into Task 9, found in Task 6's geometry work:** `CalibrationFingerprint.geometryMatches` compares the four **outer** corner patches and nothing else, so it is blind to the one way a folding case goes stale without moving. A case standing open on a table is tented, and the tent is what `FoldingBoardGeometry` was built for: the spine settles flatter over a session — a leaf nudged, a table knocked, the case simply relaxing — and the middle of the board moves while all four corners sit exactly where they were. Every column near the hinge shifts, the hinge strip's own plane is wrong, and the fingerprint says nothing has changed. Measured, in the geometry that made the folding path exist: a tent angle wrong enough to matter puts mid-board columns half a column out and collapses separability, which is the same failure a moved board causes and the same routing (`requiresRecalibration`) — it just is not currently detected. Task 9 needs a patch on the **hinge seams** as well as the corners on a board calibrated through `calibrateFolding`: those four points are exactly where a tent change shows and exactly where a slide does not. Cheap, since the eight points are already in the calibration.

## Phase 3 — The mode ships (Tasks 10–15)

### Task 10: App plumbing — camera frames, TTS, sensors, permissions

**Files:**
- Modify: `app/pubspec.yaml` (add `camera`, `flutter_tts`, `sensors_plus`, `board_vision` path dep — current stable versions, each with a rationale comment like existing deps)
- Create: `app/lib/buddy/camera_frame_source.dart` (camera image stream → `Frame.fromYuv420` in a worker isolate; exposes stable-frame callbacks gated on `sensors_plus` gyro + inter-frame diff)
- Create: `app/lib/buddy/speaker.dart` (`BuddySpeaker` over `flutter_tts`: speak-and-mirror API, phrasing modes `terse|friendly`, mobile-only guard following `firebase_observability.dart`'s pattern, injectable fake)
- Modify: `app/android/app/src/main/AndroidManifest.xml` (`RECORD_AUDIO`), `app/ios/Runner/Info.plist` (`NSMicrophoneUsageDescription`); extend `app/test/android_manifest_test.dart` for the new permission (same pattern as CAMERA)
- Test: `app/test/buddy/speaker_test.dart`, manifest tests

- [x] Steps: failing tests (speaker formats terse "13/8, 24/22" and friendly "Move one checker from 13 to 8..." from a `Move`; desktop no-ops — zero channel traffic, mirroring `desktop_guard_test.dart`'s technique; manifest assertions) → implement → `flutter analyze`/`flutter test` green → commit `feat(app): buddy plumbing — camera frames, speaker, sensors, permissions`.

**As implemented (Task 10): one line rendered twice, one hop said once, and a toolchain note that was this task's own fault.**

- **A spoken line and a written line are not the same characters, so `BuddyLine` carries both.** The spec requires every spoken line mirrored on screen — accessibility, and the noisy room the mode is designed for — and the plan's sketch has one string. A transcript wants the notation the score sheet already uses, `13/8*`; a platform TTS engine handed that says "thirteen eighths, asterisk". So `BuddyLine{text, speech}`, identical content, `speech` defaulting to `text` for the many lines (dice, objections, cube talk) that are already prose. `BuddyPhrasing.describePlay` returns the pair, which is also what lets a play be worded with no speaker in the room.
- **Doubles are grouped, which means the spoken form deliberately diverges from `Move.toString`.** Ungrouped, a doubles play is `24/20 24/20 13/9 13/9` — what the score sheet shows and what the core prints. Hearing the same hop four times is miserable, and reads as a stutter in the transcript, and **one roll in six is doubles**, so it is not an edge case. `_GroupedHop` folds identical `(from, to)` pairs into `24/20(2)` / "24 to 20 twice", the standard written notation and the thing a player actually says. Hits mark the group if ANY member hit — the written convention `13/8*(2)`, one blot hit and the second checker landing on the point already made. First-appearance order is kept, so the played order still reads left to right.
- **The stability bit and the `MotionHint` were split, and they are not the same question.** A frame is admitted for a perception query on gyro-still **AND** scene-quiet; the `MotionHint` handed to `assessReadability` carries **the gyro alone**. Folding them together was the obvious economy and it produces a lie: a hand moving over a phone that never budged would raise `ReadabilityCause.motion` and tell the user to hold the phone still, when the phone is the one thing in the picture behaving. Pinned from both sides in `camera_frame_source_test.dart`.
- **The README's toolchain section grew a NuGet prerequisite, one task ahead of the docs task, because this task is what broke it.** `flutter_tts` ships a Windows plugin whose `CMakeLists.txt` shells out to `nuget.exe` for CppWinRT and hard-fails without it, so adding the dependency stopped `flutter run -d windows` — a documented dev target — at `nuget.exe not found`. Flutter has no way to exclude a plugin from one platform's build. Bisected at the time: the Windows build is clean with `flutter_tts` removed, and `camera` and `sensors_plus` are innocent.
- **Two files the plan did not list.** `app/test/ios_info_plist_test.dart` is new, and is the iOS half of the manifest guard the plan only asked for on Android: iOS fails later and harder than Android — a binary that touches a privacy-sensitive API with no usage string is terminated by the OS and rejected by Review, and neither failure is reachable from a Windows dev machine or from `flutter test`. And `camera_platform_interface` is a new dev-dependency, because `CameraImage.fromPlatformInterface` is the only way to build a `CameraImage` in a test — the plugin exposes no other constructor.

**As implemented (Task 10, review round): the range iOS actually sends, and three constants that were not load-bearing enough.**

- **iOS delivers studio-range YUV and the decoder assumed full range — a Task-1 doc claim that only became load-bearing here.** `Frame.fromYuv420`'s doc had said since Task 1 that iOS delivers `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`. It does not, and cannot: `camera_avfoundation`'s `getPixelFormat` maps `yuv420` to `…BiPlanarVideoRange` with no API to ask for the other one (and maps both `unknown` and `bgra8888` to `kCVPixelFormatType_32BGRA`, which is why a null `imageFormatGroup` is the wrong answer on every iPhone rather than a neutral one). Android's `YUV_420_888` is forwarded as the sensor made it, full range by convention. So the two platforms genuinely disagree and neither lets the app choose — which makes it a parameter, `Frame.fromYuv420(videoRange:)`, defaulting false so every existing byte-exact expectation still holds untouched.
  - **Measured, on one 8x2 picture written out in both conventions:** decoded as full range, the studio copy's worst per-byte deviation from the true picture is **20 levels**; through the new parameter it is **1** (the round trip's own byte quantization, not the matrix). Contrast collapses from 255 levels to **219 — a 14.1% loss of margin**, taken in exactly the dim rooms the readability checks exist for. And the consequence with a name in this package: `CalibrationFingerprint.clippedFraction` counts channels **at 255**, and nothing in a crushed decode can reach 255 — the same frame holds four clipped bytes decoded correctly and **zero** decoded naively, so `ReadabilityCause.tooBright` was structurally dead on iOS. A board under a blazing lamp would have reported itself perfectly lit.
  - **The studio path is the INTEGRATED BT.601 matrix, not expand-then-convert.** `255/219` folded into the luma term and `255/224` into the three chroma terms, clamped once at the end on RGB — the standard's own conversion. Clamping the expanded Y' before the matrix (the other option) throws away the footroom and headroom studio range exists to carry, *before* chroma has had its say: a bright pixel whose chroma pulls green down would come out ~17 levels dark. Both ranges live in a 256-entry lookup table the default fills with the identity, so the inner loop's arithmetic is unchanged and neither convention pays for the other.
  - **The corpus never goes near it.** `prepare_corpus` decodes JPEGs and the synthetic renderer draws RGB directly; `fromYuv420` has exactly two callers, the app and its tests. Verified by the whole board_vision suite passing byte-identically.
- **`kBuddyImageFormat` was wired to nothing, which is the quietest of the failures here.** A controller built with any other format does not fail at `start()`: it fails once per frame, forever, inside a `catch` that only prints under `kDebugMode` — so a release build shows a live preview and produces zero `ObservedFrame`s with nothing anywhere saying why. Now `CameraFrameSource.start` calls `checkBuddyImageFormat` before it touches a plugin (a throw, not an assert: an assert is compiled out of exactly the build where this is invisible), and a run of `kConversionFailureLimit` = 5 failed conversions — 1.25s at `kObservationInterval` — raises a `FrameConversionFault` on `FrameGate.faults`. Once per episode, not once per frame, and on its own stream rather than as an error on `frames`, so a listener that only wants frames need not write an `onError`. What a session *does* about it is Task 11's and Task 13's; what this file owes them is that the condition is observable at all.
- **`BuddySpeaker` set `_configured` before awaiting `configure()`, which quietly voided the guarantee the whole queue exists for.** `configure` is the only place `awaitSpeakCompletion(true)` is applied — the switch that makes `speak` complete when the utterance *ends*. Latch first and one transient failure (a channel not up at the session's first line, swallowed by the same `catch` that swallows a failed utterance) is never retried: every later line goes out through an unconfigured engine that returns immediately, the queue stops serializing, and Buddy talks over itself for the rest of the match with nothing thrown and nothing logged outside debug mode. The flag now latches only on success.
- **Corrections to the record, since a commit message cannot be edited.** The header comment in `camera_frame_source.dart` said "the five constants below" and the commit message repeated it; there are **seven**, of which four are marked provisional, one says out loud that it is a budget rather than a measurement, and two are derived from noise arithmetic that needs no device. Fixed in the file, recorded here for the message.
- **The Windows plugin registration is now a fact about every desktop build, not just Buddy Mode's.** `app/windows/flutter/generated_plugins.cmake` and `generated_plugin_registrant.cc` register `flutter_tts` as of Task 10, so the NuGet prerequisite above is **mandatory for any `flutter run -d windows` on this repo from here on** — including one by someone who never touches Buddy Mode. The review could not re-verify the bisection that identified `flutter_tts` as the culprit (it needs the Windows build, and removing the package to prove it is a destructive experiment on a shared tree); the original measurement stands as recorded, unre-run.

### Task 11: BuddySession, dice-from-perception, OpponentPolicy

**Files:**
- Create: `app/lib/buddy/buddy_dice_roller.dart` — implements the existing `DiceRoller` interface; `rollDice()` returns a Future completed by perception (`readDice`) or manual entry, for BOTH sides (physical dice everywhere, per design).
- Create: `app/lib/buddy/perception_human_agent.dart` — implements `PlayerAgent`; the human's `Move` arrives from `matchLegalPlay` (unique match), the candidate picker (ambiguous), or tap-fallback — never from board taps.
- Create: `app/lib/buddy/buddy_session.dart` — owns calibration state, the frame/query scheduler (which query runs on the next stable frame is derived from `GameController` phase), placement verification for Buddy's dictated moves (loop until `verifyExpectedBoard` is clean, escalate to belief mirror), illegal/incomplete-play objection flow, readability→pause→recalibration routing (play resumes where paused; game state untouched — spec requirement), cube verbal flow.
- Create: `app/lib/buddy/buddy_policy.dart` — the spec's `BuddyPolicy` interface + `OpponentPolicy` speaking through `BuddySpeaker`.
- Create: `app/test/buddy/fake_vision.dart` (scriptable `BoardVision` fake, house fake style)
- Test: `app/test/buddy/buddy_session_test.dart`

- [x] Step 1: Failing session tests with `FakeVision` + `ScriptedDiceRoller`-style scripts: full short game end-to-end (dice read → human play observed → buddy dictates → placement wrong once, corrected, verified); ambiguous play → candidate list surfaces, pick folds correctly; illegal play → objection spoken, state unchanged until board fixed; readability red mid-turn → queries pause, resume cleanly; `requiresRecalibration` → session enters recalibrating state without touching the game; cube: Buddy doubles by voice, user answer folds; game end recorded through the standard persistence path (assert a History row, reusing `test_database.dart` helpers).
- [x] Step 2: Implement; green. Commit `feat(buddy): session orchestration, perception-fed agents, opponent policy`.

**As implemented (Task 11): the roll a synchronous seam cannot wait for, a second agent the plan did not name, and the one line `board_vision` was missing.**

- **`DiceRoller.roll()` is synchronous, and no amount of session design changes that — so Buddy's side parks on the pre-roll gate too.** The plan asks for a roller whose `rollDice()` "returns a Future completed by perception", but `GameController._rollFor` calls `roll()` inline and cannot await a camera. The human side already has a suspension point (the controller PARKS on `awaitingHumanTurn` until a verb fires); the AI side has none — `considerDouble` is skipped whenever doubling is illegal, and the roll follows in the same synchronous breath. Three ways out, and the one taken is the one that touches no shared code: **`BuddyOpponentAgent`**, a `PlayerAgent` wrapping the real engine agent whose only difference is `wantsDoublePrompts == false`, so the controller parks on Buddy's pre-roll exactly as on a human's. The session then owns both moments — read the dice off the board, arm `BuddyDiceRoller`, call the controller's verb — and `roll()`/`rollOpening()` hand back what was armed, throwing rather than inventing a roll if the invariant is ever broken. It is also the truer model: in Buddy Mode a human hand throws for both sides, so both pre-rolls *are* externally gated. The rejected alternative was widening `DiceRoller.roll()` to `FutureOr<Dice>` and awaiting it in the controller — mechanical, but it puts a new suspension point into the digital game's turn loop for a mode the digital game does not have. The plan named only `perception_human_agent.dart`; this second agent lives in that file, which is why the commit message says "agents".
- **The `GameController` is null until the opening throw has been read.** A controller rolls its opening in its own constructor, so a session that built one before the dice were on the table would have to invent that roll — in a mode whose entire premise is that the dice are real. So `BuddySession.controller` is nullable, the session starts in `awaitingDice` for the opening throw, and the second and later games arm their opening before `continueToNextGame()` (the one gate the session controls on that path). Equal opening dice are re-thrown, out loud, the way two people at a board do it. **Which physical die is whose remains unanswerable from a frame** — `_openingWinner` takes `die1` as White's — and the honest fix is the seat the calibration already knows plus the two board-space centres `DiceReading` already carries; that is Task 12's flow to wire, and the pad is open on the opening throw like every other.
- **The policy's signatures moved, in three places, and each one is a type the spec assumed existed.** `onDiceRead` carries a `double?` rather than a `Confidence` — no such type was ever built, `DiceReading` reports a plain double, and `null` now means the roll was **typed** rather than read, which a policy words differently. `onCubeAction` carries `(Player actor, BuddyCubeAction action)` rather than the spec's bare `CubeAction`, because this app's `CubeAction` is take-or-drop and has no value for **the double itself** — the event the whole verbal negotiation turns on. And `onOpeningRerolled` is a tenth method: two equal opening dice are not a roll that happened, and folding them into `onDiceRead` would report a turn nobody is about to take.
- **Placement verification outranks whatever the controller wants next, and that ordering is the whole of the dictate-then-place loop.** Buddy's move lands in the authoritative state the moment the engine returns it, so the controller is already asking for the user's roll while the man is still in the user's hand. The session's scheduler therefore checks the pending placement **before** it reads the controller's phase; the dictated move's expected board and touched regions come from `lastMove` rather than from the agent (the agent returns the move *before* it is applied, when the expected position does not exist yet), and `regionsTouchedBy` is the denominator, per Task 8's reshape.
- **A calibration outage drops the before-frame, and a play made during one has to be typed.** `matchLegalPlay` requires both frames from one calibration epoch and cannot check it, so `requiresRecalibration` clears the held frame; the first clean frame after the new calibration only **re-anchors**, and the play question resumes on the one after that. A play the user made while the light was out is therefore unrecoverable by differencing — the tap fallback and the belief mirror are what cover it, which is what they are for. A red that does *not* invalidate the calibration keeps the frame and simply suspends, and the game state is untouched by either.
- **One package touch: `Readability.stated`.** `Readability`'s only constructor was private, so nothing outside `board_vision` could build one — which makes a scriptable `BoardVision` fake impossible, and with it every session test of the spec's pause/recalibrate routing. Added as an additive named constructor that reads no pixels and consults no calibration (`ReadabilityMonitor` remains the only thing that decides what a *frame* is worth), documented with why it exists and what it may not be used for. No behaviour changed; `board_vision`'s 521 tests and `--fatal-infos` are green.
- **Not covered by a test of its own: the dance.** `Move.none` is auto-passed and announced when the legal-move list comes back empty — the digital game's behaviour, mirrored — but the session builds its controller from the standard starting position and cannot be handed a position with men stuck on the bar, so the path is only exercised where the full-game test happens to hit it. A Task 13 screen test that can seed a position is the place for it.

**As implemented (Task 11, review round): a cube verb announced only once it happened, and two escalations that were behaving correctly unobserved.**

- **Every cube verb is announced AFTER the controller has taken it, never before.** `offerDouble` and `answerDouble` both called `policy.onCubeAction` first, so a verb the controller refuses — a Double mid-move, an answer with nothing pending, both of which throw — left "You double." / "You drop." standing in the transcript with the cube exactly where it was. That is not a stale log line in this mode: the transcript is the user's record of the match and the cube on the table is theirs to turn, so a spoken verb that did not happen **instructs a physical action the game will disagree with for the rest of the match**. Pinned from the refused side (it still throws, and the transcript and the policy record both stay clean) and the successful side (announced exactly once). `_considerBuddyDouble` was swapped to the same order, where its own guard already made the throw unreachable — one ordering for all three cube verbs is what keeps it that way.
- **The belief-mirror escalation was correct and completely unobserved: `kPlacementAttemptsBeforeMirror` mutated to 99 and `_needsBeliefMirror = true` mutated to `false` BOTH survived the full suite.** Now pinned frame by frame — two failed placement checks leave the flag down and the corrective loop running, the third raises it, the query keeps running while it is up (the mirror is an escalation, not a surrender), the correction is *said* once rather than once per frame, nothing about the authoritative state moves through any of it, and a board that catches up brings the mirror back down. Both mutations are red now.
- **Buddy's copy of the controller's private `_doublingLegal` is pinned against the authority rather than merely documented as a copy.** The copy stays — it is the house pattern, and four others precede it — but its two failure directions are not symmetric. Permissive drift always met the controller's throw; **restrictive drift met nothing**: Buddy would simply stop offering the cube, with no exception, no log line, and a strictly worse match. Five states now compare "did Buddy consult the engine" against "does the controller take the verb" on one and the same state: centred cube, a cube Buddy owns, one the user owns, the Crawford game, and a cubeless match. The owned-cube case earned its place by measurement — dropping `|| s.cube.owner == s.turn` (the redouble) survived the first cut of this group, which is exactly the silent mode the guard exists for.
- **`BuddyDiceRoller.cancel`'s doc named a caller it does not have, and the truth turned out to be load-bearing.** It said "the calibration died under it"; `_enterRecalibration` never calls it and `dispose` is the only thing that does. **The doc was fixed rather than the code, because the code is right and the alternative is a deadlock**: cancelling on an outage completes nothing, so `_requestRoll`'s in-flight flag would never clear and the session would never ask for another roll again. What makes the surviving request correct rather than merely harmless is that `_requestRoll` re-reads where the game has got to *after* its await — pinned now from both ends: a roll asked for before an outage is answered after it exactly once, and the pad still answers while the light is out.
- **`'6-3'` / `'6 3'` was spelled inline at three sites; `BuddyPhrasing.describeDice` holds it now.** Static, because unlike a play a roll has nothing for terse and friendly to disagree about, and a static says that out loud rather than letting a future edit drift into a disagreement. The spoken output is byte-identical — and is now pinned that way through the real `OpponentPolicy`, both channels, which nothing did before this round.
- **`Readability.stated`'s second doc bullet described code that does not exist** — a session holding a red because the user asked to recalibrate. There is no such verb, and `BuddySession` constructs no `Readability` at all. Rewritten as what it is: an anticipated Task-12 caller, with today's entire traffic being the test fake.
- **Two paths that worked and had no tests now have them.** The spec's tap-to-enter play fallback (a typed play folds as the user's own, is acknowledged exactly as a seen one is, and is refused when no play is being waited for) and the user-doubles-Buddy flow (offer → the engine takes → cube 2, owned by the taker → the policy records `offered` then `taken`).
- **Recorded, not fixed: manual dice entry stays live through a readability outage, and that is spec-compliant rather than a leak.** The pad answers the USER, not the camera, so a user who types a roll while the light is out advances the game, and the session stays parked in `calibrating` until a calibration arrives. **Task 13 owes this an explicit UI decision**: the pad's reachability while the indicator is red has to be something the screen chooses out loud, not something it inherits from this file.
- **Recorded, not fixed: `ObservedFrame` lives in `camera_frame_source.dart`,** the plugin-owning file, so `buddy_session.dart` transitively imports `camera` and `sensors_plus` for the sake of one small data class. The seam holds in practice — the whole session suite runs on a Windows desktop with no camera and no sensors — but it is a tidy candidate for Task 13/15: the type is three fields and a `Frame`, and belongs somewhere no plugin does.

### Task 12: Calibration UI + Buddy setup screen

**Files:**
- Create: `app/lib/screens/buddy/buddy_setup_screen.dart` (reuses the match-setup option widgets: length, cubeless, difficulty, Buddy's color; plus seat side and phrasing)
- Create: `app/lib/screens/buddy/calibration_screen.dart` (camera preview, draggable corner handles seeded by auto-detect when confident, orientation confirm, belief-vs-board confirmation over the preview; in-context camera permission ask; the SAME screen serves mid-session recalibration with corners pre-seeded)
- Test: `app/test/screens/buddy/calibration_screen_test.dart` (fake frame source + fake vision; drive: drag corners → confirm → calibration produced; recalibration entry pre-seeds corners)

- [x] Steps: failing widget tests → implement → green → commit `feat(buddy): setup and guided calibration screens`.

**As implemented (Task 12): eight handles instead of four, a seat that decides the opening throw, and the one thing calibration was supposed to measure and does not.**

*App suite 914+7skip → 939+7skip; `flutter analyze --fatal-infos` clean; `packages/` untouched — no API gap forced a change.*

- **The flow is five steps, not four, and the extra one is the dice.** `aiming → corners → seat → capturing → confirming`. The plan's outline began at the corners; `aiming` is a checklist in front of it, and it exists for the finding that cost the most: **a die left on the felt during calibration is learned as part of the board's surface**, and the dice reader looks for what the board does not account for — so that die, and every die like it, is invisible for the rest of the session. The step says so in those words rather than asking for tidiness. It also carries the other two preconditions (men in the starting position, whole field in frame) and the board-type question below. `aiming` is reachable from `corners` by Back on the recalibration path too, deliberately: mid-match the dice ARE on the table, and a recalibration needs the same sentence.

- **The corner step answers the corner-spread finding with two overlays and a loupe, and none of them is a confidence number.** The 79-accepting-set sweep says that "accepted" spans 13/24 to 23/24 exact counts, that the accepting sets are scattered rather than a plateau, and that separation is a *poor* guide to a good tap. So the screen shows the one thing a person can act on: **the twenty-four derived point columns and the bar, drawn live over the preview from the handles as they move** (`BoardHandles.outlines`, re-derived every frame through a real `PlanarBoardGeometry`/`FoldingBoardGeometry` and a real `RoiAtlas`). A column line that misses its own stack is visible instantly; a corner 3% out is not. Alongside it: a `RawMagnifier` that lifts above the handle under the finger — the measured first-pass error on the real board was 10–40 px onto the wooden rim, and a fingertip is wider than that — and a caption that names the **felt boundary, not the rim**, in as many words. No separation figure is shown anywhere.

- **DEVIATION, required: eight handles, and a board-type question.** The plan's sketch says four. The user's own board is a folding case, `calibrateFolding` needs all eight `FoldingCorners`, and no four corners describe a tented case. `BoardHandles` therefore carries `outer` (4) plus `hinge` (0 or 4, in `[farLeft, farRight, nearRight, nearLeft]` ring order), and `RealBoardLearner` dispatches on `isFolding`. **The choice is a segmented control on the aim step, not auto-detection** — finding the seam in a photograph is a harder problem than the one four dragged handles already solve, `board_vision` exposes no seam detector, and the consequence of the choice (four more handles) is immediate and visible, so the user can see they picked wrong. The hinge handles are seeded at **7% of each edge either side of its middle** (`_kSeedBarWidth`), which is where the first real board's strip measured (6.7% far, 7.5% near), so the user nudges rather than hunts.

- **DEVIATION: the user confirms a SEAT, not an orientation, and the confirmed seat comes back out.** `BoardOrientation.whiteHomeNear` is not a question a person can answer; "which half is your home board" is. `CalibrationRequest` therefore carries `(userSide, seat)` and derives `orientation` through the new `orientationFor(userSide, seat)` in `buddy_session.dart`; `CalibrationOutcome` carries `seat` back, and `BuddySetupScreen` reconciles it into the `BuddySetup` it hands on (`setup.copyWith(seat: outcome.seat)`). One truth, decided on the screen where a person is looking at their own board.

- **The confirmation step is the safety net, and it is a picture rather than a verdict.** `confirmStartingPosition`'s own documentation says it checks colours and not counts, and the corner sweep found placements that pass it while counting ten checkers wrong — so the step draws **the thirty men of the starting position through the new geometry, over the live preview** (`BeliefPainter`), with `ConfirmResult.message` under it and the offending regions ringed. It re-runs on every stable frame, so a user who moves a checker sees the answer follow the board. **"Start over" returns to the corners with the handles intact** — the spec's cheap restart and the fast path of nudging, one and the same code path as the mid-session recalibration entry.

- **`CalibrationResult.message` is shown verbatim, as that class asks.** Every refusal lands back on the corners with them where they were, with the sentence above the caption — including `regionUnreadable`'s "something may be resting on it", which is the vision layer's own way of saying a die (or a phone, or a hand) is on the felt.

- **The seat now decides the opening throw, and the mechanism is the dice ORDER rather than a label.** Task 11 left `_openingWinner` taking `die1` as White's. The fix is not where it looked: `GameController` records an opening as `OpeningRollEvent(whiteDie: dice.die1, blackDie: dice.die2)` and `firstPlayer` follows from that, so **which face is submitted first decides the first turn, the game record and every spoken line at once**. `BuddySession._asOpening` now reorders the throw before `_roller.submit`: each player throws their single die on their own side, `DiceReading` carries both board-space centres, board space's `y` runs far→near as the camera sees it, so the die with the larger `y` is the near-seated player's. `_openingWinner` reverts to the plain face comparison — one rule, so the transcript and the game cannot disagree. **It refuses rather than guesses when both dice are on one half** (or level, or the roll was typed) and falls back to the pre-seat convention; the dice band is only `y ∈ [0.42, 0.58]`, so this is a narrow discrimination that Task 15's on-device protocol is where it gets tested against real throws. Four tests in the "opening" group pin both seats, the refusal and the typed path, asserting the `OpeningRollEvent` rather than `state.turn` — the controller races ahead and Buddy has already played by the time a frame settles.

- **`BuddySession.seat` is REQUIRED, not defaulted.** A silent default for the fact that decides who moves first is exactly the kind of quiet wrong answer this mode cannot afford. The only existing caller is the test harness.

- **Two seams, both shaped like the QR scanner's.** `BuddyCamera` (open / frames / preview / close, with a sealed `CameraReady | CameraUnavailable`) and `BoardLearner` (`learn` + `visionFor`, because `BoardVision.calibrate` is a static over a photograph and the confirm step needs the new vision's answer to be scriptable). Both behind providers, both overridden in the widget tests. `PhoneBuddyCamera` is the untested plugin edge and owns ONE `CameraController` for the preview AND the frames — two on one camera is a platform error on both OSes — and calls **`checkBuddyImageFormat` at the point the controller is built**, outside the `CameraException` catch, so a wrong format is loud rather than dressed up as "the camera could not be started". `availableCameras()` is caught broadly, because a desktop with no implementation raises `MissingPluginException` and "there is no camera here" is the same answer either way.

- **Handles are normalized to the frame, never pixels, and become pixels exactly once.** The corpus finding that the accepting corner region *moves* between image sizes rather than merely shrinking is why: the preview a finger drags on and the `Frame` perception reads are two pictures of one scene at two sizes, so `BoardHandles.quadIn`/`foldingIn` convert against the very frame about to be calibrated and nothing else.

- **DEVIATION, recorded and NOT fixed: `dieSide` is carried, not measured.** `BoardCalibration.dieSide`'s own doc names Task 12 as the place calibration would watch the first roll and measure the dice ("two blobs in a band that was empty a second ago are dice by construction"). It is not built here and could not be: `DiceReader`'s blob gates are all derived FROM `dieSide`, so finding an unknown-sized die needs a size-agnostic finder in `board_vision`, which is a perception change and not a screen. `CalibrationRequest.dieSide` threads the value with `BoardCalibration.defaultDieSide` as the default and says all of this at the field. Until it exists, a board whose dice differ from the bed's (the first real one's were **0.021** against a default of 0.075) reads no dice at all and the manual pad carries every roll — which is what the Phase-1 gate already decided ships.

- **Reuse, as asked.** `_Section` and the length/difficulty/cubeless controls were lifted out of `new_match_screen.dart` into `app/lib/screens/setup_options.dart` (`SetupSection`, `MatchLengthOptions`, `DifficultyOptions`, `CubelessSwitch`, `difficultyLabel`) and both screens now build from them, so the two setup forms cannot drift apart in wording or in what lengths they offer. `TapWhenDisabled` explains the corner step's Next button when four handles have crossed into something that is not a board — a state one drag can reach, and therefore an answer rather than an error (`BoardHandles.geometry` returns null and the overlay simply stops).

- **Not done here, deliberately.** No `AnalyticsScreenView` wrapper: `AnalyticsScreens` has no Buddy entry and Task 14 owns Buddy telemetry, so adding one now would be a merge conflict with a plan step. No home entry and no route registration (Task 13). No spinner on the capture step either — an indeterminate `CircularProgressIndicator` animates forever and would wedge every `pumpAndSettle` in the file; the sentence is the affordance, because it says what to do with the wait.

- **The Task 12 review round (2 Medium, 7 Low, all reviewer-measured, all fixed).** *App suite 939+7skip → 952+7skip; `flutter analyze --fatal-infos` clean; `packages/` still untouched.*

  - **A dragged handle was dropping deltas, and the loupe is exactly why it mattered.** The move callback added each `onPanUpdate` delta to the handle position captured when the frame was BUILT, so every move arriving between two builds rebased on the same stale value and only the last survived. Measured on a widget test: three ten-pixel moves with no pump between them landed the handle **ten** pixels along, not thirty. On a phone the handle lags the finger by the ratio of touch rate to frame rate and stops short — on the one screen whose subject is placing a point to within a few pixels. Accumulating against `_handles.all[i]` fixes it; the new test asserts the FULL sum rather than "it moved somewhat".
  - **The opening seat needed room, not just a side.** `_asOpening` compared each die's board-space `y` against a bare 0.5, attributing dice at 0.4999 and 0.5001 to two different people with exactly the confidence it attributes the two ends of the band — and the band is only `y ∈ [0.42, 0.58]`, 0.08 per seat, so near-midline centres are the shape of a throw that bounced rather than an edge case. Each die now has to be **`kOpeningSeatMargin` = 0.02** clear of `RoiAtlas.midline` on its own side. Marked **Provisional** in `camera_frame_source.dart`'s house style with the arithmetic that produced it: ten cells of `DiceReader`'s own 80-cell band lattice below it, and under a third of where a thrown die comes to rest above it. Two session tests stand either side of the number. The hardcoded 0.5 is `RoiAtlas.midline` now.
  - **`BeliefPainter` was inventing its pitch.** It stacked the thirty men at `RoiAtlas.midline / 5.5` and ignored the origin, while the calibration it was handed carried the `StackMetrics` fitted from this board's own eight labelled stacks (legal range 0.02–0.15; the first real board measured 0.0874). The one overlay whose whole job is to be disagreed with was drawing a nominal board's men over a real board's felt. Now `origin + (k + 0.5) * pitch`, the arithmetic occupancy counts backwards with. The nominal survives only for a fit outside `StackMetrics`'s bounds — **unreachable through `BoardVision.calibrate`**, whose `wellConditioned` gate refuses exactly that, and kept because `BoardLearner` is a seam. Deliberately not clamped at the midline: a stack drawn spilling into the far half is a pitch that cannot be right, and this is the step where a person is asked to spot that.
  - **Both `shouldRepaint`s compared something other than what they meant.** `BeliefPainter`'s compared the SIZE of the flagged set, so point5 becoming point7 kept the old red rings under a fresh sentence — the picture marking one point while the caption names another. `BoardOutlinePainter`'s compared two freshly-built lists by identity, which is always true and therefore says nothing. Both compare contents now, and the outline's rings as well as its handles: the seat step changes the derived columns without moving a handle.
  - **Four claims the suite asserted around rather than at**, now pinned: the belief re-runs once per SETTLED frame and not at all on an unsettled one; the flagged regions reach `BeliefPainter.offending` and not just the message; `dieSide` survives the whole way from `CalibrationRequest` to `learn` (tested at the real board's 0.021, not the bed's 0.075); and `buddySide` is a control someone taps, which turns the board over.
  - **`CalibrationRequest.orientation` and `BuddySetup.orientation` are gone.** Both were production-dead, and the first was a trap for a future caller: it returned the PRE-confirmation seat's frame from the very screen whose seat step exists because that seat can be wrong. The frame is `orientationFor(userSide, seat)`, computed where the CONFIRMED seat is; the test that went through the getter asks `orientationFor` itself now.
  - **One `FakeBuddyCamera` and one `FakeBoardLearner`, in `test/buddy/fake_calibration_seams.dart`.** They had been written twice in different shapes across the two screen suites — one recorded `dieSide` and could be scripted to refuse, the other could not. A double written twice drifts, and the half that drifts is whichever a fix was not applied to.
  - **A handle can be placed without a finger now.** Arrow keys move a focused handle by `CalibrationHandle.nudgeStep` (one logical pixel — the *last* pixel, since a drag does the coarse work), and the same four moves are custom semantic actions, which is how TalkBack and VoiceOver offer them. The keys are claimed rather than passed on, because `WidgetsApp`'s own shortcuts would read an arrow as directional focus traversal and hand the next press to a different corner. Focus lights the ring; the loupe stays a drag affordance, since nothing covers a handle being nudged.
  - **RECORDED, NOT FIXED — the preview↔frame mapping, which is Task 15's first on-device item.** Every overlay maps normalized frame coordinates straight onto the preview box, which is right only if the displayed preview is the whole sensor frame, same way up, unmirrored, unletterboxed. `CameraPreview`'s own `AspectRatio` is squelched by `Positioned.fill` (stretch, not letterbox) and no rotation handling exists anywhere in the mode. It cannot be verified without a phone, and its failure mode is silent. Stated in full at `_CalibrationScreenState._preview`, again at `PhoneBuddyCamera.preview`, and added to Task 15 Step 3 as the item that runs before anything else is measured.

- **`app/test/buddy/fake_vision.dart` grew, per the task's leave.** `FakeVision(calibration:)` (the session's scenarios still get the throwing getter), `willConfirm` + a scripted `confirmStartingPosition` — which was an `UnimplementedError` reading "calibration is Task 12, not the session", and now is — `startPositionAgrees`/`startPositionDisagrees`, `diceAcrossTheBoard(near:far:)`, and `fakeCalibration()`, which builds a REAL `PlanarBoardGeometry` (pure arithmetic, no photograph needed) with the smallest colour model and stack pitch their constructors accept. `diceShowing`'s two dice are now documented as deliberately level in `y`: an opening the seat cannot resolve is a case the tests need to be able to name. *(Review round: `diceEitherSideOfTheMidline(near:far:clearance:)`, which `diceAcrossTheBoard` is now expressed through, so a test can stand either side of `kOpeningSeatMargin`; and `fakeCalibration(stacks:)`, because the belief overlay draws THROUGH the stack fit and a painter that quietly used a nominal pitch would look right on every fake calibration that happened to carry one.)*

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
- [ ] Step 3: **USER-GATED:** the manual on-device protocol on the user's devices against a real board — this is the MVP's true acceptance test. **Its FIRST item, before anything else is measured, is the preview↔frame mapping** (raised by the Task 12 review, and unverifiable without a phone): every overlay on the calibration screen maps normalized frame coordinates straight onto the preview box, which is only right if the displayed preview shows the whole sensor frame, the same way up, unmirrored and unletterboxed. `CameraPreview`'s own `AspectRatio` is deliberately squelched by `Positioned.fill`, and **no rotation or mirroring handling exists anywhere in Buddy Mode**. If sensor and preview disagree, every handle is in the wrong coordinate frame and the failure is SILENT — the outline looks plausible, the calibration may succeed, and the columns are simply wrong. The check: put a handle on a real corner of the felt, in **both orientations**, and look at whether it stays on that corner; portrait is expected to fail loudly (a preview turned on its side), landscape is the natural aiming and is the one that matters. The assumption is stated in full at `_CalibrationScreenState._preview` and again at `PhoneBuddyCamera.preview`. Second item, and for the same reason: where two real opening dice come to rest relative to the midline, against `kOpeningSeatMargin`.
- [ ] Step 4: Version bump both files, CHANGELOG, merge, push, tag `v0.14.0` per README's Releasing section. Update memory.

---

## Self-review notes

- Spec coverage: modes seam (T11), opponent loop (T11/T13), calibration + continuous re-validation (T3/T9/T12), color-agnosticism (T3 + the no-color-literals test), state-primed queries (T7/T8), readability (T9/T13), TTS/phrasing (T10), mic-as-optional (T14), fallbacks (T11/T13), corpus-as-tests (T5/T6), gate (T6), History/analytics (T11/T14), permissions (T10), version discipline (T15). Voice input, coach modes, cube perception: out of scope per spec.
- Type consistency: `Frame`/`Pt`/`BoardQuad`/`BoardCalibration`/`Readability` pinned in Tasks 1–3 and referenced identically after; `BoardState`/`Move`/`Dice` come from `backgammon_core` everywhere.
- The one deliberate deviation from bite-sized orthodoxy: perception algorithm internals (Tasks 3–4, 7–8) specify contracts + test matrices rather than full literal code — the algorithms are exploratory by nature (that is what the corpus harness and the gate are for), and prescribing pixel math line-by-line here would be fiction. Every OTHER binding surface (types, APIs, thresholds, file layout, test cases) is exact.

> **GATE DECISION (2026-08-02, user):** Outcome (b) — proceed. Geometry,
> calibration and colour proven on the real corpus; counts workable with
> the corner-spread caveat; dice ship as tap-to-enter while the queued
> band-location/tilt work continues. Phase 2 (Tasks 7-9) authorized.
