/// A synthetic backgammon board, drawn top-down and then thrown through a
/// perspective warp into a [Frame] — the perception test-bed.
///
/// **Test-only.** Nothing under `lib/` may import this file or `package:image`
/// (see the pubspec's note on why `image` is a dev dependency). Every colour
/// constant in this package lives HERE, in the palettes below: the no-colour-
/// constants rule the spec puts on the pipeline is about the pipeline, and the
/// only way to prove a pipeline learns a board's colours is to hand it boards
/// whose colours it was never told.
///
/// Why a renderer at all: the corpus of real photographs is Task 6, and the
/// geometry, colour and occupancy work that has to be correct before those
/// photographs are worth shooting is Tasks 2–5. Synthetic shots give those
/// tasks ground truth by construction — the renderer *knows* where it put
/// every checker and which pips it painted — and they stay useful afterwards
/// as the fast, deterministic half of the harness.
///
/// The drawing is factored one element per function on purpose: later tasks
/// extend it with degradation (blur, noise, occlusion, glare) and with more
/// palettes, and those want to hook single elements rather than one long
/// paint routine.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:image/image.dart' as img;

/// Default top-down render size. 3:2, which is close to a real board's
/// playing field once the two trays are included.
const int kTopDownWidth = 900;
const int kTopDownHeight = 600;

/// Default warped-frame size — a plausible camera preview.
const int kFrameWidth = 1280;
const int kFrameHeight = 960;

/// The default "phone propped at the side of the table" viewpoint: the far
/// edge is shorter than the near one and the board is slightly rolled, so
/// nothing downstream can accidentally succeed by assuming an axis-aligned
/// board.
const BoardQuad kCameraQuad = BoardQuad(
  topLeft: Pt(190, 170),
  topRight: Pt(1120, 150),
  bottomRight: Pt(1210, 800),
  bottomLeft: Pt(80, 830),
);

/// A steeper viewpoint than [kCameraQuad]: the far edge is a little under
/// three fifths of the near one, against [kCameraQuad]'s four fifths.
///
/// [kCameraQuad] turns out to be a gentle view — Task 4's reviewer measured its
/// foreshortening at 21%, which is a phone standing tall beside the table
/// rather than one propped against a mug, and it makes the far half of the
/// board easier to read than a session normally will. The corpus uses these
/// three instead, and reports its per-half scores separately so that the
/// difference is visible rather than averaged away.
const BoardQuad kCorpusSteepQuad = BoardQuad(
  topLeft: Pt(300, 180),
  topRight: Pt(980, 165),
  bottomRight: Pt(1215, 835),
  bottomLeft: Pt(65, 855),
);

/// Lower still, and rolled: the phone leaning on something, not held. Its far
/// edge is 0.58 of its near one, against [kCameraQuad]'s 0.82.
///
/// Steepness turned out **not** to be what limits the pipeline. Walking the
/// viewpoint down at a blurrier setting produced scattered failures that read
/// exactly like a foreshortening limit; at the corpus's own sharpness the same
/// boards read from very nearly table level. `test/degradation_test.dart`
/// records the correction, which matters for what a user gets told: "hold the
/// phone higher" would fix nothing.
const BoardQuad kCorpusLowQuad = BoardQuad(
  topLeft: Pt(298, 200),
  topRight: Pt(982, 140),
  bottomRight: Pt(1230, 820),
  bottomLeft: Pt(50, 880),
);

/// The camera off to one side of the table rather than at the end of it, so
/// one vertical edge of the board is far shorter than the other — a different
/// distortion from foreshortening, and the one that stretches the ROI atlas's
/// fixed proportions hardest.
const BoardQuad kCorpusOffAxisQuad = BoardQuad(
  topLeft: Pt(150, 215),
  topRight: Pt(1055, 120),
  bottomRight: Pt(1180, 905),
  bottomLeft: Pt(105, 700),
);

/// The viewpoints the corpus shoots from.
const List<BoardQuad> kCorpusQuads = <BoardQuad>[
  kCorpusSteepQuad,
  kCorpusLowQuad,
  kCorpusOffAxisQuad,
];

/// What the corpus does to every synthetic shot. See [ShotDegradation] for why
/// a corpus of clean renders scores nothing, and `test/degradation_test.dart`
/// for the assertion that these particular numbers are enough to matter.
/// Measured, not chosen, and the measurements are the most valuable thing in
/// this file. `test/degradation_test.dart` pins each of them.
///
/// **Blur is what the pipeline cannot take, and it is the dice that go first.**
/// Reading a settled pair across a grid of three viewpoints, three palettes,
/// both seatings and four sub-pixel offsets of the corners — 24 to 72 cells,
/// each a full calibrate-then-read:
///
/// | blur sigma | pairs read |
/// |---|---|
/// | 0.3 – 0.6 | 72 / 72 |
/// | 0.8 | 20 / 24 |
/// | 1.0 | 12 / 24 |
/// | 1.1 | 10 / 24 |
///
/// Note the shape as much as the numbers: at 0.8 the failures are **ragged**,
/// deciding on nothing more than where the board's corners fall between two
/// pixels — the same board, the same light, the same dice, read or not read
/// depending on half a pixel. Calibration itself survives to about 1.8 sigma,
/// so this is the dice reader alone, and it is by a distance the tightest
/// limit anywhere in the pipeline. The spec already names dice as the
/// sub-problem most likely to need the ML escape hatch; this is that
/// prediction with a number against it, taken before a single photograph
/// exists. A hand-held phone over a table will not always be sharper than one
/// sigma.
///
/// **Grain** matters much less: 24/24 at 3 levels, 16/24 at 4, where the
/// classic palette's near-black checkers stop calibrating — its Black is
/// painted at 20/18/15 and the colour model's feature is a per-channel log
/// ratio, so ±4 levels on a value of 18 is a quarter of a log unit.
///
/// The corpus therefore runs at **0.5 sigma and 2 levels**, inside the region
/// measured stable rather than on the edge of it, so that what the harness
/// scores is accuracy and not a coin toss. The committed corpus adds one more
/// degradation on top — JPEG at quality 95 — for which see the corpus
/// generator.
///
/// ## The JPEG is closer to a cliff than the blur is, and it was not known
///
/// Found while building the folding bed, and recorded here because it is about
/// the corpus encoder rather than about folding boards. At the corpus's own
/// steep viewpoints, quality-95 JPEG puts the **classic palette's far-half
/// black stack** on a knife edge — the 19-point, five near-black checkers
/// (20/18/15) on an oxblood triangle, in the half the perspective renders
/// smallest. Calibrated with `renderShot` and `BoardVision.calibrate`, nothing
/// folding involved:
///
/// | quad | degradation | raw | JPEG q95 |
/// |---|---|---|---|
/// | kCorpusSteepQuad | none | passes | ragged |
/// | kCorpusSteepQuad | kCorpusDegradation | passes | ragged |
/// | kCorpusLowQuad | none | passes | ragged |
/// | kCorpusLowQuad | kCorpusDegradation | passes | ragged |
///
/// **Ragged** is the word for it. Every raw frame calibrates; whether the same
/// frame calibrates after a JPEG round trip flips on changes with no business
/// deciding it — a bar width of 0.07 against 0.08, a tray of 0.02 against
/// 0.05. It is the same shape as the blur raggedness above, at a knob nobody
/// was watching, and the committed corpus does not catch it because its six
/// sessions happen to land on the passing side.
///
/// Not fixed here — it is a sampler-and-colour question, not a geometry one,
/// and the honest place to answer it is the real corpus with real photographs
/// of dark checkers. What it changes today is one thing: a fixture that has to
/// go through the corpus encoder at a steep viewpoint should not be shot on
/// the classic palette, or it is measuring this rather than what it meant to.
const ShotDegradation kCorpusDegradation = ShotDegradation(
  noise: 2,
  blurSigma: 0.5,
  quadJitter: 0.8,
  seed: 4242,
);

/// What surrounds the board in a warped frame — "the room", not the board.
/// Unlike the board itself this is NOT scaled by `lightingGain`; the gain
/// models the light falling on the playing field, which is what the
/// readability checks measure.
const int kBackdropColor = 0x101418;

/// The board's layout in **board space**: the playing field as the unit
/// rectangle (0,0)–(1,1), x rightward and y from the far edge to the near one.
///
/// The renderer's contract with Task 2's ROI atlas: both read the SAME
/// [BoardProportions], so a disagreement about where the columns are is not
/// expressible — and where the two do their own arithmetic on those widths,
/// the atlas tests check them against each other for a trayless board as well
/// as a standard one. Under [BoardOrientation.whiteHomeNear] the standard
/// diagram applies: points 1–6 bottom-right, 7–12 bottom-left, 13–18 top-left,
/// 19–24 top-right, with point 1 at the far right and point 12 at the far left.
///
/// **Why this is an instance and not a bag of constants.** The tray, bar and
/// column widths stopped being constants when a real board turned out to have
/// no trays at all (see [BoardProportions]). So the renderer takes them the
/// same way the atlas does, and [standard] is the board it draws when nothing
/// says otherwise. What is left static here is what genuinely does not vary
/// between boards: how far a triangle reaches, how big a checker is next to
/// its column, how big a die is.
class BoardLayout {
  /// The board being drawn.
  final BoardProportions proportions;

  const BoardLayout({this.proportions = BoardProportions.standard});

  /// The ordinary cased board, with wells at both ends.
  static const BoardLayout standard = BoardLayout();

  /// How far a point triangle reaches from its own edge, as a fraction of the
  /// board's height. What is left in the middle is the dice band.
  static const double pointLength = 0.42;

  /// Checker radius as a fraction of [columnWidth] — just under half, so
  /// neighbouring stacks keep a visible gap.
  static const double checkerRadiusFraction = 0.46;

  /// The moulded well in a checker's face, as a fraction of its radius —
  /// painted only when a [StackPlacement] asks for one through `faceGain`.
  ///
  /// Seven tenths, which is roughly what the real board's checkers show and
  /// what it takes to matter: the ring left around a well this size thins to
  /// about a third of the column across the middle of the disc, which is just
  /// under [RoiSampler.minRowCoverage]. Narrower and no row ever breaks; wider
  /// and the checker stops being one.
  ///
  /// The words said "two thirds" against this 0.70 until a reviewer noticed.
  /// **The number is the one that stayed**: every committed synthetic JPEG was
  /// drawn at 0.70, the re-render guard in `corpus_harness_test.dart` compares
  /// bytes, and moving a rendering constant to match a rounded description
  /// would regenerate thirty-three photographs to fix a sentence.
  static const double checkerFaceFraction = 0.70;

  /// Gap between a checker's edge and the board edge it stacks from, in
  /// fractions of the board height.
  static const double stackEdgeMargin = 1.0 / 300.0;

  /// Die side as a fraction of the board width, and the two dice centres
  /// along it. Both sit on the vertical midline, inside the right half.
  static const double dieSide = 0.075;
  static const double firstDieCentreX = 0.65;
  static const double secondDieCentreX = 0.78;

  /// Pip radius as a fraction of the die's side.
  static const double pipRadiusFraction = 0.08;

  /// Horizontal span of point [index] (0-based, matching `BoardState.points`)
  /// in board space, as `(left, right)`.
  (double, double) pointSpan(int index) {
    if (index < 0 || index > 23) {
      throw RangeError.range(index, 0, 23, 'index', 'point index');
    }
    final columnWidth = proportions.columnWidth;
    final double left;
    if (index <= 5) {
      // Points 1–6: bottom right, point 1 hard against the right tray.
      left = proportions.rightHalfEnd - (index + 1) * columnWidth;
    } else if (index <= 11) {
      // Points 7–12: bottom left, point 7 against the bar.
      left = proportions.leftHalfEnd - (index - 6 + 1) * columnWidth;
    } else if (index <= 17) {
      // Points 13–18: top left, point 13 above point 12.
      left = proportions.leftHalfStart + (index - 12) * columnWidth;
    } else {
      // Points 19–24: top right, point 19 against the bar.
      left = proportions.rightHalfStart + (index - 18) * columnWidth;
    }
    return (left, left + columnWidth);
  }

  /// Whether point [index] is on the half nearest the camera (points 1–12),
  /// where the perspective is kindest. Accuracy is tracked per half.
  static bool isNearHalf(int index) => index <= 11;
}

/// Where a stack actually sits on its point, as opposed to where a tidy
/// renderer would put it.
///
/// Every render before this one seated the outermost checker of every stack
/// hard against its own board edge and dead in the middle of its column,
/// because that is what a drawing program does. It is not what a person does.
/// Measured on the first real board's calibration frame: not one of the eight
/// starting stacks was flush, the gaps differed from point to point, and one
/// stack sat far enough off its column's centre to half-miss a patch taken at
/// the centre. That is the whole reason the checker patch had to become a
/// checker finder, so the bed has to be able to express it.
///
/// [flush] is the default everywhere, so every render that does not ask for
/// this draws exactly the bytes it drew before.
class StackPlacement {
  /// How far the first checker's edge sits from the board edge it stacks
  /// from, as a fraction of the board's height — which is also board space's
  /// own `y` unit, so an inset of 0.06 here is 0.06 in everything the
  /// pipeline measures. Added to the hair of clearance
  /// [BoardLayout.stackEdgeMargin] always leaves.
  final double edgeInset;

  /// How far the stack sits from the middle of its column, as a fraction of
  /// the column's width. Positive is toward increasing x, whichever board
  /// edge the stack belongs to.
  final double centerOffset;

  /// How much brighter the checker at the TOP of this stack is than the one at
  /// its foot — a plain multiplier on the checkers' own colour, applied
  /// per checker across the stack's own extent.
  ///
  /// **A window beside the table is what this is.** It lives on a placement
  /// because it is the same kind of fact: something about how one particular
  /// stack sits, which the bed already routes per point through
  /// `pointPlacements`. Nothing else in the renderer can express it — the
  /// board-wide `lightingGain` moves the whole frame together and so cancels
  /// in every ratio the pipeline takes, which is the entire point of the
  /// pipeline being built on ratios. A gradient down a single stack does not
  /// cancel, and it is the one lighting shape the bed could not draw.
  ///
  /// Measured on the first real folding frame: down the black five-stack on
  /// the 19-point, luma runs 32 at the foot to 67 at the top. See
  /// [checkersUnderLamp] for what that is worth as a test.
  final double lampGain;

  /// How different the **moulded face** of each checker in this stack is from
  /// its rim — a plain multiplier on the checker's own colour, painted as an
  /// inner disc of [BoardLayout.checkerFaceFraction] of the radius.
  ///
  /// **A real checker is a disc with a moulded well in it.**
  /// `ShotDegradation`'s own doc lists that among the things the bed does not
  /// draw and the photographs are for; this is the part of it that turned out
  /// to matter. A flat drawn disc covers its rows generously and tapers to
  /// nothing only where two discs touch — one or two rows — which is why the
  /// bed has never needed a gap policy worth arguing about. A disc with a well
  /// covers only its RING, and the ring is thinnest across the middle of the
  /// checker, so the coverage the sampler measures dips **once per checker, in
  /// the middle of it**, and a stack's profile arrives in pieces.
  ///
  /// One everywhere is the default, so every render that does not ask for a
  /// moulded face draws exactly the bytes it drew before.
  ///
  /// ## The size is measured, in two ways that agree
  ///
  /// The well is [BoardLayout.checkerFaceFraction] of the radius, which leaves
  /// a ring around it. Across a row through the middle of the disc that ring is
  /// at its thinnest — about a third of the column — so the coverage there
  /// lands at **0.32**, just under [RoiSampler.minRowCoverage], and climbs back
  /// over it a little way either side. Two numbers come out of that geometry
  /// and both match the real frame:
  ///
  /// * **how deep the dip is.** Real profiles dip to 0.2–0.3 coverage in the
  ///   middle of a checker rather than to nothing, which is what a ring around
  ///   a well looks like and is not what any gap between discs looks like;
  /// * **how wide it is.** Across the real corpus's ten frames the interior
  ///   gaps of labelled stacks run 1–2 rows (195 of them), 3–6 rows (46), then
  ///   **7–8 rows (18)**, with a thin tail of 9 and over where stacks actually
  ///   end. A well of this size dips for about 0.7 of a checker's radius, which
  ///   on a point's 120-row profile is **seven rows**.
  final double faceGain;

  const StackPlacement({
    this.edgeInset = 0,
    this.centerOffset = 0,
    this.lampGain = 1,
    this.faceGain = 1,
  });

  /// Hard against the edge, dead centre: what every render did before this
  /// type existed, and what every one still does unless told otherwise.
  static const StackPlacement flush = StackPlacement();

  @override
  String toString() => 'StackPlacement(inset $edgeInset, '
      'offset $centerOffset, lamp $lampGain, face $faceGain)';
}

/// Every stack lit the way the real frame's 19-point is: a window at one end
/// of the table, so the top of a stack is twice the brightness of its foot.
///
/// **This exists because a fix passed 368 tests and refused the real board.**
/// The walk holds a block by colour with brightness taken out, which cannot
/// tell a dark board from a dark checker of the same wood — so a brightness
/// bound was added alongside it, tuned to the drift down the real frame's
/// WHITE two-stack (0.196 of a log unit). The bed had no gradient down any
/// stack, so nothing here could disagree, and the whole suite passed. The real
/// frame refused, naming the 19-point: a log ratio of brightness is not
/// scale-free across checker colours, and the same window over that frame's
/// BLACK stack moves it three times as far — 0.63 rather than 0.196.
///
/// So the number that matters is the ratio, and it has to fall inside the
/// window the hold test looks through — `RoiSampler.checkerHoldDepth`, which
/// is 0.07 of the board. Across that window on the black five-stacks this puts
/// **0.31 to 0.45** of a log unit, against the 0.30 the refused bound allowed
/// and the real frame's 0.63. The colour is unchanged throughout, because
/// every channel moves by the same factor.
///
/// **What it is measured to do, and where it stops.**
///
/// * It bites where the real frame did. With the refused bound put back, the
///   blind walk down both black five-stacks settles at 0.03 to 0.05 instead of
///   at the first step: it stops holding partway up the shadowed foot checker
///   and starts the stack in the wrong place. That is the regression, and it
///   is what `calibration_test`'s 'a stack lit up its own length' pins.
/// * It does not bite at the whole-board level. Calibration and confirmation
///   pass either way here — the bed's board survives what the finder does not,
///   so the assertion has to be on the finder. On the real frame the same
///   fault went all the way to a refusal, because a real stack's shadow is
///   twice as deep as anything this bed can paint without over-exposing (2.4
///   tips the classic board into `boardOverExposed`).
/// * It is a classic-palette instrument. The other two palettes' dark
///   checkers are not dark — blue-red's are red and the wood board's are a
///   mid brown — so the same multiplier pushes them across their own boards'
///   surfaces and they stop being separable for reasons that have nothing to
///   do with the hold test. Near-black paint is the case, and classic is the
///   bed's only near-black.
const StackPlacement checkersUnderLamp = StackPlacement(lampGain: 2.1);

/// How far back a hand may leave this board's stacks and still have the whole
/// pipeline read them — **measured, and not one number**.
///
/// It lives here, with the palettes, because that is what it belongs to: what
/// limits it is which two colours a board happens to put next to each other
/// and how hard they are lit, not anything about how a stack is placed. Two
/// test files ask the question and neither may hold its own copy of the
/// answer.
///
/// Measured over the whole palette matrix, stacks all at one inset,
/// calibrated and confirmed and every point counted back:
///
/// * **classic 0.09 in ordinary light** (gains 0.6 and 1.0) — this is the
///   finder's own ceiling, `checkerSearchNear + checkerHoldDepth`, so on this
///   board nothing but the walk's reach limits how a hand may leave the men.
/// * **classic 0.03 at gain 1.4** — lit 40% over, its cream points climb
///   toward its white checkers and it joins the hard cases.
/// * **low-contrast wood 0.03 at every gain.** A board made of one wood: its
///   dark point paint and the dark checker standing on it differ by 0.019 in
///   colour once brightness is taken out, against a hold tolerance of 0.08,
///   so a block that starts on the board holds straight through the checker
///   in front of it and the board's own paint is learned as a checker colour.
///   `RoiSampler.checkerHoldTolerance` carries why a brightness bound cannot
///   rescue this and what the real frame said about trying.
/// * **blue-red 0.03**, and its limit is a third thing again. The finder is
///   not what gives out — at every inset up to 0.07 it settles on the right
///   checker of the right colour, and a model learned from a TIDY blue-red
///   board reads all 24 samples of every one of those patches correctly. What
///   gives out is what the model LEARNS from an inset frame: a stack sitting
///   back uncovers the base of its own triangle, and this is the palette
///   whose pale points sit closest to its white checkers (0.28 in the model's
///   feature space, against 0.70 for felt — see
///   `Calibrator.checkerExclusionRadius`). Enough of that paint joins the
///   region's background and the white five-stack on the 13-point then reads
///   as bare. Not monotonic in the inset — 0.04 refuses and 0.05 does not —
///   which is what a limit looks like when it is really about how much
///   triangle is showing.
///
/// So one palette in ordinary light gets the walk's whole reach and everything
/// else gets a third of it, for three unrelated reasons, none of which is the
/// walk. Every one of them is a colour-model limit wearing a placement limit's
/// clothes, and the colour model is where the money would have to be spent.
double insetCeilingOf(BoardPalette palette, double gain) =>
    palette == BoardPalette.classic && gain <= 1.0 ? 0.09 : 0.03;

/// The eight stacks the starting position puts out, at insets a hand might
/// leave — the SHAPE of a hand's carelessness, scaled to what [palette] can
/// take.
///
/// The shape is the thing being tested: insets differ from stack to stack, so
/// no single offset fixes them, which is why the finder is a search. The deep
/// ones are deliberately on the short stacks — a five-stack inset that far
/// would have to compress to stay off the midline, which is a different
/// measurement (the pitch) getting harder rather than this one.
Map<int, StackPlacement> handPlacedStacks(BoardPalette palette, double gain) {
  const shape = <int, double>{
    0: 0.08,
    5: 0.04,
    7: 0.09,
    11: 0.02,
    12: 0.06,
    16: 0.075,
    18: 0.03,
    23: 0.08,
  };
  final scale = insetCeilingOf(palette, gain) / 0.09;
  return <int, StackPlacement>{
    for (final entry in shape.entries)
      entry.key: StackPlacement(edgeInset: entry.value * scale),
  };
}

/// Something lying on the board that is not the board — a hand reaching in, a
/// sleeve, a phone put down on the felt.
///
/// **The bed had no way to draw the one thing that happens most.** Every other
/// knob here degrades the *picture* of the board — grain, blur, a wandered quad,
/// less light. None of them can express a chunk of the board simply not being
/// visible, which is what a hand does several times a turn and what the
/// readability stack has to name as [ReadabilityCause.occluded] rather than as
/// a board that moved. So this is the same kind of addition
/// [StackPlacement.faceGain] was: a physically-motivated shape the photographs
/// have and the drawings did not.
///
/// ## What it draws, and why in the top-down render
///
/// A filled ellipse in **board space** — the same unit square the atlas
/// describes — painted into the top-down image before the lighting gain, so it
/// is lit by the same room the board is. That puts the thing flat ON the board
/// rather than hovering above it, which is a real simplification: a hovering
/// hand would project to a slightly different outline through the tent of a
/// folding case. It is the right simplification because what the readability
/// check measures is *a patch of the board that is not the board*, and that is
/// the same patch either way.
///
/// ## The colour is a hand's, not a board's — and it is written down here
///
/// A palette is a board; a hand is not, and deriving one from the other would
/// be inventing physics. So [kSkin] sits with the palettes, in the one file
/// this package keeps colour constants in, and says what it is: a warm mid-tone
/// that returns much more red than blue, which is what skin does under room
/// light and what none of the three boards' felts do.
///
/// **It is not separable on every board, and that is the honest result rather
/// than a gap to paper over.** On `BoardPalette.lowContrastWood` — the palette
/// built to be hard, whose every surface is in the wood family — a hand sits
/// 1.8 spreads from the felt, well inside what the model calls "the board".
/// A hand on a board the colour of a hand cannot be found by colour, and the
/// readability check says so out loud rather than pretending otherwise. On the
/// other two it is 9.3 and 14.8 spreads out, far past
/// `ColorModel.maxClassDistance`.
class BoardOccluder {
  /// Centre of the ellipse, in board space as the top-down render draws it.
  final Pt center;

  /// Half-width and half-height, in board-space units.
  final double radiusX;
  final double radiusY;

  /// What the thing is, in sensor levels — see [kSkin].
  final int color;

  const BoardOccluder({
    required this.center,
    required this.radiusX,
    required this.radiusY,
    this.color = kSkin,
  });

  /// Nothing on the board, which is what every render draws unless told
  /// otherwise — so every picture drawn before this type existed still draws
  /// exactly the same bytes.
  static const BoardOccluder none =
      BoardOccluder(center: Pt(0, 0), radiusX: 0, radiusY: 0);

  /// A hand reaching in over the near-right quadrant to move a checker.
  ///
  /// **The size is what a hand is**, not what a detector wants. A palm and
  /// fingers span roughly a fifth of a 50 cm board's width and reach a third of
  /// the way up it from the near edge, which is this ellipse: about a
  /// twentieth of the playing field, over parts of three of the near half's
  /// point columns and the felt between them.
  ///
  /// It leaves all four outer corners and both hinge seams untouched, and that
  /// is the point of where it sits rather than an accident of it: a hand is not
  /// a board that moved, and the check has to be able to tell them apart. A
  /// hand ON a corner is the case colour cannot separate from a slide, and the
  /// readability module documents it as such.
  static const BoardOccluder hand = BoardOccluder(
    center: Pt(0.68, 0.78),
    radiusX: 0.10,
    radiusY: 0.17,
  );

  bool get isNothing => radiusX <= 0 || radiusY <= 0;

  @override
  String toString() => isNothing
      ? 'BoardOccluder(none)'
      : 'BoardOccluder(${radiusX}x$radiusY at $center)';
}

/// A hand, in the same sensor levels the palettes are written in.
///
/// Mid-toned and warm — `(200, 148, 120)`, a red channel two thirds again its
/// blue — which is the one thing every human hand under room light has in
/// common and the reason a hand is not mistakable for felt on most boards. It
/// lives beside the palettes because this file is where every colour constant
/// in the package lives, and because a hand is a fact about hands rather than
/// something a board could tell you.
const int kSkin = 0xC89478;

/// How worn a folding case's spine is — the raised hinge strip that such a
/// board uses for a bar.
///
/// **A real board said this was needed.** The first real folding calibration
/// frame's hinge is not one colour. It is a ridge, and a ridge that has been
/// rubbed by thirty years of checkers being swept off it: a dark seam down the
/// very middle where the two leaves meet, a pale crown either side of the seam
/// where the wood has worn, and the untouched wood on the flanks. Measured over
/// the bar band's four hundred calibration samples, its brightness runs from 0
/// to 206 — three surfaces, not one.
///
/// That matters because the pipeline models a region's surfaces with
/// two-means, i.e. with two. The dark seam is the furthest thing from the
/// wood, so it takes one mode; the wood takes the other; and the pale crown is
/// left over. Forty-two percent of that band came back classified as checkers
/// — 29% White on the crowns, 13% Black in the shadows — and calibration
/// refused a board that was set up perfectly.
///
/// Every colour here is derived from the palette's own family, because a spine
/// is made of the board's own wood: the crown is that wood rubbed toward the
/// colour of a pale checker — which is precisely why it is dangerous, and
/// exactly what the real board's is — and the seam is that wood in shadow.
class SpineWear {
  /// How far the crowns have been rubbed toward the colour of the board's own
  /// pale checkers, 0 to 1.
  final double paleness;

  /// How wide each crown is, as a fraction of the hinge strip's width.
  final double crownWidth;

  /// How wide the dark seam down the middle is, in the same units.
  final double seamWidth;

  /// How deep the seam's shadow is, 0 (none) to 1 (black).
  final double seamShade;

  const SpineWear({
    required this.paleness,
    required this.crownWidth,
    required this.seamWidth,
    required this.seamShade,
  });

  /// A spine straight out of the shop: one flat colour, which is what every
  /// folding render drew before this type existed and what they all still draw
  /// unless told otherwise.
  static const SpineWear none =
      SpineWear(paleness: 0, crownWidth: 0, seamWidth: 0, seamShade: 0);

  /// A spine worn the way the first real board's is.
  ///
  /// The shape matters more than the exact numbers, and it is the shape the
  /// photograph has: a **minority** pale stripe either side of a near-black
  /// crack, with the untouched wood the majority. That is what defeats a
  /// two-surface model — the crack is the furthest thing from the wood, so it
  /// takes the second mode, and the stripe is left with nowhere to go.
  ///
  /// [paleness] is set so the crown lands about a spread and a half from the
  /// White cloud, which is where the photograph's does (1.40 measured). Every
  /// combination of `crownWidth` 0.07–0.17 and `paleness` 0.35–0.55 produces
  /// the same refusal on all three palettes, so nothing here is balanced on a
  /// knife edge.
  static const SpineWear worn = SpineWear(
    paleness: 0.45,
    crownWidth: 0.12,
    seamWidth: 0.06,
    seamShade: 0.9,
  );

  bool get isNothing =>
      (paleness <= 0 || crownWidth <= 0) && (seamShade <= 0 || seamWidth <= 0);

  @override
  String toString() => isNothing
      ? 'SpineWear(none)'
      : 'SpineWear(crowns $crownWidth at $paleness, seam $seamWidth at '
          '$seamShade)';
}

/// One physical board's colours: felt, frame, both point colours, both
/// checker colours, and the dice.
///
/// Three of them ship so that no test can pass by knowing what a backgammon
/// board "looks like". The pipeline learns these from the start position
/// during calibration and is never told them.
class BoardPalette {
  final String name;

  /// The playing surface between the triangles.
  final int felt;

  /// The wood: surround, bar and tray wells.
  final int frame;

  final int pointLight;
  final int pointDark;
  final int whiteChecker;
  final int blackChecker;
  final int dieBody;
  final int diePip;

  const BoardPalette({
    required this.name,
    required this.felt,
    required this.frame,
    required this.pointLight,
    required this.pointDark,
    required this.whiteChecker,
    required this.blackChecker,
    required this.dieBody,
    required this.diePip,
  });

  /// Brown board, cream and oxblood points, white and black checkers.
  static const BoardPalette classic = BoardPalette(
    name: 'classic',
    felt: 0x6E4A2A,
    frame: 0x4A3018,
    pointLight: 0xE0CBA0,
    pointDark: 0x8E2B1C,
    whiteChecker: 0xF5F3EC,
    blackChecker: 0x14120F,
    dieBody: 0xB9C9D6,
    diePip: 0x1A2A38,
  );

  /// Blue board with red and white checkers — the checker pair carries no
  /// luminance ordering hint, so anything that quietly assumes "White is the
  /// bright one" fails here.
  static const BoardPalette blueRed = BoardPalette(
    name: 'blue-red',
    felt: 0x1B3A6B,
    frame: 0x0C1A30,
    pointLight: 0xBFD3E8,
    pointDark: 0x2E6DB4,
    whiteChecker: 0xF2F2F0,
    blackChecker: 0xB4231E,
    dieBody: 0xF0D25A,
    diePip: 0x2B2410,
  );

  /// Everything in one wood family: the deliberately hard board. Its felt and
  /// dark points are barely 21 units apart in RGB, which is roughly the floor
  /// at which a relative colour model can still separate them.
  static const BoardPalette lowContrastWood = BoardPalette(
    name: 'low-contrast wood',
    felt: 0xA88B62,
    frame: 0x8A7048,
    pointLight: 0xC4AC84,
    pointDark: 0x9C8055,
    whiteChecker: 0xD8C8AA,
    blackChecker: 0x6B563A,
    dieBody: 0xE7E0CE,
    diePip: 0x4A3A24,
  );

  static const List<BoardPalette> all = <BoardPalette>[
    classic,
    blueRed,
    lowContrastWood,
  ];

  int checkerColor(Player player) =>
      player == Player.white ? whiteChecker : blackChecker;

  /// Every colour this palette can paint, by name. The nearest of these to a
  /// sampled pixel is the renderer's own notion of "what is at this spot".
  Map<String, int> get swatches => <String, int>{
        'felt': felt,
        'frame': frame,
        'pointLight': pointLight,
        'pointDark': pointDark,
        'whiteChecker': whiteChecker,
        'blackChecker': blackChecker,
        'dieBody': dieBody,
        'diePip': diePip,
      };

  @override
  String toString() => 'BoardPalette($name)';
}

/// The COLOUR of the light on the board, as against how much of it there is.
///
/// **The one lighting change the bed could not draw, and the pipeline's whole
/// premise turns on the difference.** `lightingGain` is a single scalar over
/// all three channels — a dimmer switch — and a scalar is exactly what
/// `ColorModel`'s per-channel log ratio was built to divide back out: turn it
/// down and every feature in the model is unmoved, which is why a board at six
/// tenths of its calibration light still reads. A lamp *changed* rather than
/// dimmed does not do that. Its three channels move by three different
/// factors, the factors do not cancel in a ratio taken against a reference
/// measured under the old lamp, and what the model reads back is a board whose
/// colours have quietly stopped being the ones it learned.
///
/// So this is the same kind of addition [StackPlacement.faceGain] and
/// [BoardOccluder] were: a physically-motivated shape the photographs have and
/// the drawings did not. It is what `ReadabilityMonitor`'s colour-validity
/// check is measured against, and without it that check could not be tested at
/// all.
///
/// ## What the numbers are, and where they come from
///
/// [tungsten] is Planck's law, evaluated twice. A blackbody's spectral radiance
/// is `B(λ,T) ∝ λ^-5 / (exp(hc/λkT) - 1)`, and the ratio of two temperatures at
/// one wavelength drops the `λ^-5` entirely. Taken at the three channels'
/// nominal centres — 610, 550 and 465 nm — for a 2700 K household lamp against
/// the 6500 K daylight a camera is balanced for:
///
/// | λ | B(2700)/B(6500) | over green |
/// |---|---|---|
/// | 610 nm | 5.894e-3 | 1.7306 |
/// | 550 nm | 3.406e-3 | 1 |
/// | 465 nm | 1.221e-3 | 0.3585 |
///
/// Those are then divided by their own BT.601 luma (1.1453), so that the cast
/// **holds the brightness of a neutral grey** and moves only its colour. That
/// is not a tidying-up: it is what a camera does. Auto-exposure meters the
/// scene and pulls the overall level back where it was, so what actually
/// reaches the pipeline from a lamp swapped mid-session is a frame of the same
/// brightness in a different colour — and keeping the two knobs independent is
/// what lets a test say which of them a verdict came from.
///
/// ## Why a strength rather than a temperature
///
/// A camera's white balance is not all-or-nothing. It adapts, and how far it
/// gets before a frame is grabbed is what decides how much cast survives into
/// the picture — so the honest parameter is *how much of the lamp change the
/// white balance failed to take out*, which is [tungsten]'s argument. It
/// interpolates in log space, because gains multiply: strength a half is the
/// square root of the full lamp, not half way along a line between the two.
class LightCast {
  /// Per-channel multipliers on the board's own paint, applied with the
  /// [lightingGain] and before the sensor.
  final double red;
  final double green;
  final double blue;

  const LightCast({this.red = 1, this.green = 1, this.blue = 1});

  /// The light the board was calibrated under: whatever the palette says, at
  /// the colour the palette says it. Every render that does not ask for a cast
  /// draws exactly the bytes it drew before.
  static const LightCast neutral = LightCast();

  /// A 2700 K lamp against a camera balanced for 6500 K daylight, at
  /// [strength] of full — see the class doc for where the three gains come
  /// from and why they are normalized to hold a grey's brightness.
  ///
  /// Zero is exactly [neutral], so a sweep can start at the calibration light
  /// and produce byte-identical frames there.
  factory LightCast.tungsten(double strength) {
    if (strength == 0) return neutral;
    const full = <double>[1.73063, 1.0, 0.35851];
    final gains = <double>[
      for (final g in full) math.exp(strength * math.log(g)),
    ];
    final luma = 0.299 * gains[0] + 0.587 * gains[1] + 0.114 * gains[2];
    return LightCast(
      red: gains[0] / luma,
      green: gains[1] / luma,
      blue: gains[2] / luma,
    );
  }

  /// Whether this cast leaves every channel exactly as it found it.
  bool get isNeutral => red == 1 && green == 1 && blue == 1;

  @override
  String toString() => 'LightCast(${red.toStringAsFixed(3)}, '
      '${green.toStringAsFixed(3)}, ${blue.toStringAsFixed(3)})';
}

/// Everything a camera adds to a scene that a flat render does not.
///
/// ## Why a perfect render is a bad test bed
///
/// The drawing above is exact: flat colour, no grain, an exact projective warp.
/// One consequence is not obvious and is what this class exists for. A
/// checker's pitch along a stack comes out an exact multiple of the sampler's
/// row depth, so the length occupancy measures divides into a whole number of
/// checkers with no remainder — and `floor()` in place of `round()` passes
/// every cell of the matrix. Task 4's reviewer demonstrated it. A hundred
/// percent scored on a bed like that is arithmetic, not accuracy.
///
/// So the corpus renders the same positions and then spoils them, in the order
/// a camera does:
///
/// * **[blurSigma]** — the lens, which smears the rim of every checker and pip
///   over a few pixels, so where a run of checker-coloured rows stops is a
///   judgement rather than a fact;
/// * **[noise]** — the sensor, which moves the classification of the samples
///   nearest a threshold from frame to frame;
/// * **[quadJitter]** — the board is never *quite* where the corners say, and
///   half a pixel is enough to move every board-space sample to a different
///   spot between pixels.
///
/// ## What this is not
///
/// Not a camera model. The noise is uniform rather than Poisson, the blur is a
/// single isotropic gaussian rather than a lens's varying point spread, and
/// nothing here does glare, motion, rolling shutter, or the way a real checker
/// is a disc with a rim that catches the light. Those are what the plan's Task
/// 6 photographs are for. The job of these three is narrower and worth being
/// exact about: **to stop the answers being exact**, so that the harness's
/// scores measure something an error could change.
class ShotDegradation {
  /// Peak per-channel additive noise, in sensor levels. Uniform in
  /// `[-noise, +noise]`, which is the wrong distribution for a sensor and the
  /// right one for this: it puts the most samples near the extremes, where
  /// classification decisions actually flip.
  final double noise;

  /// Gaussian blur, in output pixels of standard deviation. Applied to the
  /// warped frame, so it blurs the picture rather than the board — which is
  /// what a lens does, and it means the far half of a steep shot is blurred
  /// harder in board-space terms than the near half, again like a lens.
  final double blurSigma;

  /// How far each corner of the warp quad may wander, in output pixels, in x
  /// and y independently. The wandered quad is what the frame is warped onto
  /// AND what is reported as ground truth — a corpus whose sidecar disagreed
  /// with its own picture would be scoring the wrong thing.
  final double quadJitter;

  /// Everything above is deterministic in this. Two shots that want different
  /// grain must differ here; two runs of the same shot must not.
  final int seed;

  const ShotDegradation({
    this.noise = 0,
    this.blurSigma = 0,
    this.quadJitter = 0,
    this.seed = 0,
  });

  /// The flat render, as Tasks 1–4 used it.
  static const ShotDegradation none = ShotDegradation();

  bool get isNothing => noise <= 0 && blurSigma <= 0 && quadJitter <= 0;

  @override
  String toString() => isNothing
      ? 'ShotDegradation(none)'
      : 'ShotDegradation(noise $noise, blur $blurSigma, jitter $quadJitter, '
          'seed $seed)';
}

/// Where a checker lives, for the ground-truth records below.
enum SpotArea { point, bar, off }

/// One drawn checker, in top-down image pixels.
class CheckerSpot {
  final Player owner;
  final SpotArea area;

  /// 0..23 when [area] is [SpotArea.point]; -1 on the bar or in a tray.
  final int pointIndex;

  /// Position within its stack, counting from the board edge.
  final int indexInStack;

  final Pt center;
  final double radius;

  const CheckerSpot({
    required this.owner,
    required this.area,
    required this.pointIndex,
    required this.indexInStack,
    required this.center,
    required this.radius,
  });

  @override
  String toString() => 'CheckerSpot(${owner.name}, ${area.name} '
      '$pointIndex #$indexInStack at $center)';
}

/// One die to draw, said in board space so a test can put it anywhere.
///
/// The default path — pass a [Dice] and let the renderer place them — draws
/// the same two dice in the same spot every time, which is the wrong bed for a
/// reader that has to find dice rather than be handed them. This says exactly
/// where each die goes, at what angle, and how many of them there are: one
/// (a die rolled off the board), three (a die from the next table), or the two
/// a game actually uses, sitting somewhere other than the middle of the right
/// half.
class DicePlacement {
  /// The face showing, 1 to 6.
  final int face;

  /// The die's centre in **board space** — the unit rectangle the ROI atlas
  /// addresses, `(0,0)` at the far left corner and `(1,1)` at the near right.
  final Pt center;

  /// Rotation about [center], radians, clockwise in image coordinates.
  final double angle;

  const DicePlacement({
    required this.face,
    required this.center,
    this.angle = 0.0,
  });

  @override
  String toString() => 'DicePlacement($face at $center, ${angle}rad)';
}

/// One drawn die, in top-down image pixels.
class DieSpot {
  final int value;
  final Pt center;
  final double side;

  /// Rotation about [center], radians, clockwise in image coordinates.
  final double angle;

  const DieSpot({
    required this.value,
    required this.center,
    required this.side,
    required this.angle,
  });

  @override
  String toString() => 'DieSpot($value at $center)';
}

/// A top-down render plus everything the renderer knows about it.
class RenderedBoard {
  final img.Image image;
  final BoardPalette palette;
  final BoardOrientation orientation;

  /// Every checker drawn, in a deterministic order: points 0..23 bottom-up,
  /// then White's bar, Black's bar, White's tray, Black's tray.
  final List<CheckerSpot> checkers;

  /// The two dice, first then second, or empty when none were asked for.
  final List<DieSpot> dice;

  const RenderedBoard({
    required this.image,
    required this.palette,
    required this.orientation,
    required this.checkers,
    required this.dice,
  });
}

/// A warped shot: what a camera would have seen, plus the ground truth.
class SyntheticShot {
  final Frame frame;

  /// The playing field's corners in [frame] — what calibration is supposed to
  /// find, handed over for free.
  final BoardQuad groundTruthQuad;

  final RenderedBoard board;

  /// Maps top-down image pixels to frame pixels. Tests use it to ask "where
  /// did this checker end up?".
  final PlaneHomography topDownToFrame;

  const SyntheticShot({
    required this.frame,
    required this.groundTruthQuad,
    required this.board,
    required this.topDownToFrame,
  });

  Pt toFrame(Pt topDown) => topDownToFrame.map(topDown);
}

/// A plane-to-plane projective map, solved from four point correspondences.
///
/// Local to the test-bed on purpose: Task 2 builds the production homography
/// in `lib/src/homography.dart`, and having the renderer keep its own means
/// the atlas tests are not checking a solver against itself.
class PlaneHomography {
  /// Row-major 3x3.
  final Float64List m;

  PlaneHomography(this.m) {
    if (m.length != 9) {
      throw ArgumentError('a homography is 9 numbers, got ${m.length}');
    }
  }

  /// Solves the map taking [source]'s corners onto [destination]'s, in the
  /// [BoardQuad.corners] order.
  factory PlaneHomography.fromQuads(BoardQuad source, BoardQuad destination) {
    final src = source.corners;
    final dst = destination.corners;

    // Eight equations, eight unknowns (h22 is fixed at 1):
    //   u = (h00 x + h01 y + h02) / (h20 x + h21 y + 1)
    //   v = (h10 x + h11 y + h12) / (h20 x + h21 y + 1)
    // rearranged so each correspondence contributes two linear rows.
    final a = List<List<double>>.generate(8, (_) => List<double>.filled(9, 0));
    for (var i = 0; i < 4; i++) {
      final x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
      a[i * 2] = <double>[x, y, 1, 0, 0, 0, -x * u, -y * u, u];
      a[i * 2 + 1] = <double>[0, 0, 0, x, y, 1, -x * v, -y * v, v];
    }

    final h = _solve(a);
    return PlaneHomography(Float64List.fromList(<double>[
      h[0], h[1], h[2], //
      h[3], h[4], h[5], //
      h[6], h[7], 1.0, //
    ]));
  }

  /// Gaussian elimination with partial pivoting on an n x (n+1) system.
  static List<double> _solve(List<List<double>> a) {
    final n = a.length;
    for (var col = 0; col < n; col++) {
      var pivot = col;
      for (var r = col + 1; r < n; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      if (a[pivot][col].abs() < 1e-12) {
        throw ArgumentError('degenerate quad: the four corners do not define '
            'a projective map');
      }
      final t = a[col];
      a[col] = a[pivot];
      a[pivot] = t;

      final p = a[col][col];
      for (var c = col; c <= n; c++) {
        a[col][c] /= p;
      }
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final f = a[r][col];
        if (f == 0) continue;
        for (var c = col; c <= n; c++) {
          a[r][c] -= f * a[col][c];
        }
      }
    }
    return <double>[for (var r = 0; r < n; r++) a[r][n]];
  }

  Pt map(Pt p) {
    final w = m[6] * p.x + m[7] * p.y + m[8];
    return Pt(
      (m[0] * p.x + m[1] * p.y + m[2]) / w,
      (m[3] * p.x + m[4] * p.y + m[5]) / w,
    );
  }

  PlaneHomography get inverted {
    final c00 = m[4] * m[8] - m[5] * m[7];
    final c01 = m[5] * m[6] - m[3] * m[8];
    final c02 = m[3] * m[7] - m[4] * m[6];
    final det = m[0] * c00 + m[1] * c01 + m[2] * c02;
    if (det.abs() < 1e-15) {
      throw ArgumentError('singular homography cannot be inverted');
    }
    return PlaneHomography(Float64List.fromList(<double>[
      c00 / det,
      (m[2] * m[7] - m[1] * m[8]) / det,
      (m[1] * m[5] - m[2] * m[4]) / det,
      c01 / det,
      (m[0] * m[8] - m[2] * m[6]) / det,
      (m[2] * m[3] - m[0] * m[5]) / det,
      c02 / det,
      (m[1] * m[6] - m[0] * m[7]) / det,
      (m[0] * m[4] - m[1] * m[3]) / det,
    ]));
  }
}

/// Draws [board] (and [dice], if given) straight down onto a rectangle.
///
/// [proportions] is which board is being drawn. The default is the ordinary
/// cased one; a folding-case board (no bear-off wells, a hinge for a bar) is
/// `BoardProportions(trayWidth: 0, barWidth: 0.03)` and is what makes the
/// trayless half of the pipeline testable at all.
///
/// [starInlays] adds the small decorative inlay a great many real boards carry
/// mid-field on each half — a third surface inside regions the pipeline models
/// with two, which is the point of having it here.
RenderedBoard renderTopDown({
  required BoardState board,
  Dice? dice,
  BoardPalette palette = BoardPalette.classic,
  double lightingGain = 1.0,
  LightCast cast = LightCast.neutral,
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
  double diceAngle = 0.0,
  List<DicePlacement>? dicePlacements,
  double dieSide = BoardLayout.dieSide,
  BoardProportions proportions = BoardProportions.standard,
  bool starInlays = false,
  SpineWear spine = SpineWear.none,
  BoardOccluder occluder = BoardOccluder.none,
  StackPlacement stackPlacement = StackPlacement.flush,
  Map<int, StackPlacement> pointPlacements = const <int, StackPlacement>{},
  int width = kTopDownWidth,
  int height = kTopDownHeight,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('render size must be positive, got ${width}x$height');
  }
  if (lightingGain <= 0) {
    throw ArgumentError('lightingGain must be positive, got $lightingGain');
  }
  if (!proportions.hasTrays && board.whiteOff + board.blackOff > 0) {
    // Not a limitation of the renderer — a limitation of the board. A folding
    // case has nowhere on the felt to put a borne-off checker, which is why
    // its atlas has no tray regions either.
    throw ArgumentError('a board with no bear-off wells has nowhere to draw '
        '${board.whiteOff + board.blackOff} borne-off checkers');
  }

  final layout = BoardLayout(proportions: proportions);
  final image = img.Image(width: width, height: height);
  _drawFrameAndFelt(image, palette, layout);
  _drawPoints(image, palette, layout);
  _drawSpineWear(image, palette, layout, spine);
  if (starInlays) _drawStarInlays(image, palette, layout);
  final checkers = _drawCheckers(
    image,
    board,
    palette,
    layout,
    stackPlacement,
    pointPlacements,
  );
  final drawnDice = _drawDice(
    image,
    dicePlacements ?? _defaultPlacements(dice, diceAngle),
    palette,
    dieSide,
  );
  // Last of the paint and before the light: whatever is lying on the board is
  // between the camera and everything else, so it covers the men and the dice
  // as well as the felt — and the room lights it along with the rest.
  _drawOccluder(image, occluder);
  _applyLight(image, lightingGain, cast);

  if (orientation == BoardOrientation.whiteHomeFar) {
    // The same physical board from the other side of the table.
    return RenderedBoard(
      image: _rotateHalfTurn(image),
      palette: palette,
      orientation: orientation,
      checkers: [
        for (final c in checkers)
          CheckerSpot(
            owner: c.owner,
            area: c.area,
            pointIndex: c.pointIndex,
            indexInStack: c.indexInStack,
            center: _halfTurn(c.center, width, height),
            radius: c.radius,
          ),
      ],
      dice: [
        for (final d in drawnDice)
          DieSpot(
            value: d.value,
            center: _halfTurn(d.center, width, height),
            side: d.side,
            angle: d.angle + math.pi,
          ),
      ],
    );
  }

  return RenderedBoard(
    image: image,
    palette: palette,
    orientation: orientation,
    checkers: checkers,
    dice: drawnDice,
  );
}

/// Perspective-warps [source] so its corners land on [destination], and
/// returns the result as a [Frame] together with that same quad as the ground
/// truth a calibration step is supposed to recover.
///
/// Inverse sampling: every output pixel is mapped back into the source and
/// read bilinearly, so no output pixel is left unwritten however the quad is
/// shaped. Output pixels whose source falls outside the image get
/// [backgroundColor].
({Frame frame, BoardQuad groundTruthQuad}) warpToQuad(
  img.Image source,
  BoardQuad destination, {
  required int outWidth,
  required int outHeight,
  int backgroundColor = kBackdropColor,
}) {
  if (outWidth <= 0 || outHeight <= 0) {
    throw ArgumentError('output size must be positive, '
        'got ${outWidth}x$outHeight');
  }
  final inverse = PlaneHomography.fromQuads(
    BoardQuad.rect(source.width.toDouble(), source.height.toDouble()),
    destination,
  ).inverted;

  final sw = source.width, sh = source.height;
  final rgb = _filled(outWidth, outHeight, backgroundColor);
  _paintWarp(
    rgb,
    outWidth,
    outHeight,
    _flatten(source),
    sw,
    sh,
    inverse,
    0,
    sw - 1.0,
  );
  return (
    frame: Frame(rgb, outWidth, outHeight),
    groundTruthQuad: destination,
  );
}

/// Flattens an image once: `getPixel` per bilinear tap would be four object
/// reads per output pixel, and a warp is over a million output pixels.
Uint8List _flatten(img.Image source) {
  final sw = source.width, sh = source.height;
  final src = Uint8List(sw * sh * 3);
  var s = 0;
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final p = source.getPixel(x, y);
      src[s++] = p.r.toInt();
      src[s++] = p.g.toInt();
      src[s++] = p.b.toInt();
    }
  }
  return src;
}

Uint8List _filled(int outWidth, int outHeight, int color) {
  final rgb = Uint8List(outWidth * outHeight * 3);
  final r = (color >> 16) & 0xFF, g = (color >> 8) & 0xFF, b = color & 0xFF;
  for (var o = 0; o < rgb.length; o += 3) {
    rgb[o] = r;
    rgb[o + 1] = g;
    rgb[o + 2] = b;
  }
  return rgb;
}

/// Inverse-samples one slab of a source image into an output buffer.
///
/// [minSourceX] and [maxSourceX] bound the slab: output pixels whose source
/// falls outside them are left alone, so several slabs can be painted into one
/// buffer without any of them overwriting a neighbour's pixels. A single-slab
/// warp passes the whole width and paints everything the quad covers.
void _paintWarp(
  Uint8List rgb,
  int outWidth,
  int outHeight,
  Uint8List src,
  int sw,
  int sh,
  PlaneHomography inverse,
  double minSourceX,
  double maxSourceX,
) {
  for (var y = 0; y < outHeight; y++) {
    for (var x = 0; x < outWidth; x++) {
      final p = inverse.map(Pt(x.toDouble(), y.toDouble()));
      if (p.x < minSourceX ||
          p.y < 0 ||
          p.x > maxSourceX ||
          p.y > sh - 1 ||
          p.x.isNaN) {
        continue;
      }
      final x0 = math.min(p.x.floor(), sw - 1), y0 = p.y.floor();
      final x1 = math.min(x0 + 1, sw - 1), y1 = math.min(y0 + 1, sh - 1);
      final fx = p.x - x0, fy = p.y - y0;
      final w00 = (1 - fx) * (1 - fy);
      final w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy;
      final w11 = fx * fy;
      final i00 = (y0 * sw + x0) * 3;
      final i10 = (y0 * sw + x1) * 3;
      final i01 = (y1 * sw + x0) * 3;
      final i11 = (y1 * sw + x1) * 3;
      var o = (y * outWidth + x) * 3;
      for (var c = 0; c < 3; c++) {
        rgb[o++] = (src[i00 + c] * w00 +
                src[i10 + c] * w10 +
                src[i01 + c] * w01 +
                src[i11 + c] * w11)
            .round()
            .clamp(0, 255);
      }
    }
  }
}

/// [renderTopDown] followed by [warpToQuad] — the one call almost every
/// perception test wants.
SyntheticShot renderShot({
  required BoardState board,
  Dice? dice,
  BoardPalette palette = BoardPalette.classic,
  double lightingGain = 1.0,
  LightCast cast = LightCast.neutral,
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
  double diceAngle = 0.0,
  List<DicePlacement>? dicePlacements,
  double dieSide = BoardLayout.dieSide,
  BoardProportions proportions = BoardProportions.standard,
  bool starInlays = false,
  SpineWear spine = SpineWear.none,
  BoardOccluder occluder = BoardOccluder.none,
  StackPlacement stackPlacement = StackPlacement.flush,
  Map<int, StackPlacement> pointPlacements = const <int, StackPlacement>{},
  int topDownWidth = kTopDownWidth,
  int topDownHeight = kTopDownHeight,
  BoardQuad quad = kCameraQuad,
  int outWidth = kFrameWidth,
  int outHeight = kFrameHeight,
  int backgroundColor = kBackdropColor,
  ShotDegradation degradation = ShotDegradation.none,
}) {
  final rendered = renderTopDown(
    board: board,
    dice: dice,
    palette: palette,
    lightingGain: lightingGain,
    cast: cast,
    orientation: orientation,
    diceAngle: diceAngle,
    dicePlacements: dicePlacements,
    dieSide: dieSide,
    proportions: proportions,
    starInlays: starInlays,
    spine: spine,
    occluder: occluder,
    stackPlacement: stackPlacement,
    pointPlacements: pointPlacements,
    width: topDownWidth,
    height: topDownHeight,
  );
  // The jittered quad, not the asked-for one, is the board's real outline from
  // here on: the frame is warped onto it, the ground truth reports it, and the
  // homography a test uses to find a checker is built from it.
  final actualQuad = degradation.quadJitter > 0
      ? jitterQuad(quad, degradation.quadJitter, degradation.seed)
      : quad;
  final warped = warpToQuad(
    rendered.image,
    actualQuad,
    outWidth: outWidth,
    outHeight: outHeight,
    backgroundColor: backgroundColor,
  );
  var frame = warped.frame;
  // Optics before sensor: a real blur cannot smooth away grain that the sensor
  // has not added yet, and doing it the other way round would produce a frame
  // whose noise is spatially correlated for no reason.
  if (degradation.blurSigma > 0) {
    frame = _blurred(frame, degradation.blurSigma);
  }
  if (degradation.noise > 0) {
    frame = _noised(frame, degradation.noise, degradation.seed);
  }
  return SyntheticShot(
    frame: frame,
    groundTruthQuad: warped.groundTruthQuad,
    board: rendered,
    topDownToFrame: PlaneHomography.fromQuads(
      BoardQuad.rect(
        rendered.image.width.toDouble(),
        rendered.image.height.toDouble(),
      ),
      actualQuad,
    ),
  );
}

// --- the folding case, which is not one plane -------------------------------

/// A folding-case board standing open on a table, seen by a pinhole camera.
///
/// ## Why the test bed needs a third dimension
///
/// Everything above warps a flat board onto a quad, because a flat board seen
/// by a pinhole IS a homography and a quad says all there is to say. A folding
/// case is not flat. Its two leaves hinge, and a case resting on a table sits
/// slightly tented — the spine in the middle stands higher than the outer
/// edges, which is where the hinge strip is and where hit checkers sit.
///
/// Measured on the first real board's calibration frame: fit one homography to
/// the four outer corners, rectify, and the two halves come out with column
/// pitches **13% apart** — impossible for two identical leaves, and the
/// signature of the tent. Rectify each leaf under its own quad instead and the
/// pitch is uniform to within 5%.
///
/// So the bed models the board in three dimensions and projects it, rather
/// than picking three quads by hand. Hand-picked quads would be a tent someone
/// invented; this one is a tent, and the skew it produces is a consequence
/// rather than a setting. The camera is deliberately **off to one side**: a
/// dead-centre camera sees the two leaves as mirror images and a single
/// homography fits them equally badly, so the skew — the thing the real frame
/// showed — needs an asymmetric viewpoint to appear at all.
///
/// ## The world
///
/// In units of the board's own width: `x` across the playing field (0 at its
/// left edge, 1 at its right), `y` away from the camera (0 at the board's NEAR
/// edge, [BoardLayout] aspect at its far one), `z` up from the table.
class FoldingView {
  /// How far the hinge ridge stands above the leaves' outer edges, as a
  /// fraction of the board's width. Zero is a folding board lying dead flat —
  /// a real case, and one that has to go on working.
  final double ridgeHeight;

  final (double, double, double) eye;
  final (double, double, double) target;

  /// Focal length in output pixels.
  final double focal;

  const FoldingView({
    required this.ridgeHeight,
    required this.eye,
    required this.target,
    required this.focal,
  });

  /// The same viewpoint over a board that is not tented at all.
  FoldingView get flat => FoldingView(
        ridgeHeight: 0,
        eye: eye,
        target: target,
        focal: focal,
      );
}

/// The tent the folding tests run on: a phone leaning low at the near-left
/// corner of the table, and a spine standing 5% of the board's width proud of
/// the leaves.
///
/// Tuned to reproduce the first real frame's diagnostic and its character
/// together, both measured rather than eyeballed:
///
/// | | this view | the real frame |
/// |---|---|---|
/// | single-plane pitch skew | 12.7% | 13% |
/// | far edge over near edge | 0.55 | 0.66 |
/// | shorter side edge over longer | 0.97 | 0.99 |
///
/// The last row is the one that is easy to get wrong. The real phone was very
/// nearly square-on to the board left-to-right — its two side edges are 566 and
/// 569 px — so the skew there is NOT an off-to-one-side camera looking across a
/// flat board. It is the tent. A view that produced the same 13% by leaning
/// hard to one side would be a different phenomenon wearing the same number,
/// and the mismatch test below would then be pinning the wrong thing.
///
/// `test/folding_board_test.dart` asserts the skew, so this constant cannot
/// drift into a board that is only nominally tented.
const FoldingView kFoldingTent = FoldingView(
  ridgeHeight: 0.05,
  eye: (0.25, -0.45, 0.45),
  target: (0.5, 0.33, 0.02),
  focal: 760,
);

/// The hinge strip's width on the rendered folding boards, as a fraction of
/// the playing field. Close to the first real board's, which measures between
/// 6.7% of its far edge and 7.5% of its near one.
const double kFoldingBarWidth = 0.07;

/// A warped shot of a folding board, plus its ground truth.
///
/// The eight points are what a person taps during calibration on such a board:
/// the four outer corners, plus where the hinge strip meets the far and near
/// edges. There is no single [BoardQuad] here on purpose — a folding board
/// does not have one, and offering one would invite exactly the fit that fails.
class FoldingShot {
  final Frame frame;

  /// The eight points, as calibration wants them.
  final FoldingCorners groundTruthCorners;

  final RenderedBoard board;

  /// The proportions this board was drawn with — trayless, with a hinge for a
  /// bar, and the same ones [FoldingCorners] derives for itself.
  final BoardProportions proportions;

  const FoldingShot({
    required this.frame,
    required this.groundTruthCorners,
    required this.board,
    required this.proportions,
  });
}

/// Renders a folding-case board and projects it through [view].
///
/// The top-down render is the same one every other shot uses — the board's
/// paint does not know it is about to be folded. What differs is the warp:
/// the render is cut into three vertical slabs at the hinge, and each is
/// thrown onto its OWN quad, so the output frame carries three planes that do
/// not agree with each other. That is the whole point of the bed.
FoldingShot renderFoldingShot({
  required BoardState board,
  Dice? dice,
  BoardPalette palette = BoardPalette.classic,
  double lightingGain = 1.0,
  LightCast cast = LightCast.neutral,
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
  List<DicePlacement>? dicePlacements,
  double dieSide = BoardLayout.dieSide,
  double barWidth = kFoldingBarWidth,
  bool starInlays = false,
  SpineWear spine = SpineWear.none,
  BoardOccluder occluder = BoardOccluder.none,
  StackPlacement stackPlacement = StackPlacement.flush,
  Map<int, StackPlacement> pointPlacements = const <int, StackPlacement>{},
  int topDownWidth = kTopDownWidth,
  int topDownHeight = kTopDownHeight,
  FoldingView view = kFoldingTent,
  int outWidth = kFrameWidth,
  int outHeight = kFrameHeight,
  int backgroundColor = kBackdropColor,
  ShotDegradation degradation = ShotDegradation.none,
}) {
  final proportions = BoardProportions(trayWidth: 0, barWidth: barWidth);
  final rendered = renderTopDown(
    board: board,
    dice: dice,
    palette: palette,
    lightingGain: lightingGain,
    cast: cast,
    orientation: orientation,
    dicePlacements: dicePlacements,
    dieSide: dieSide,
    proportions: proportions,
    starInlays: starInlays,
    spine: spine,
    occluder: occluder,
    stackPlacement: stackPlacement,
    pointPlacements: pointPlacements,
    width: topDownWidth,
    height: topDownHeight,
  );

  final corners = foldingCornersOf(
    view,
    barWidth: barWidth,
    aspect: topDownHeight / topDownWidth,
    principal: Pt(outWidth / 2, outHeight / 2),
  );

  // The three slabs, in top-down pixels. The cuts are exactly where the atlas
  // puts the bar, which is what makes a checker on the hinge land on the hinge
  // strip's own plane rather than on either leaf.
  final sw = rendered.image.width, sh = rendered.image.height;
  final xLeft = corners.leftLeafEnd * sw;
  final xRight = corners.rightLeafStart * sw;
  final src = _flatten(rendered.image);
  final rgb = _filled(outWidth, outHeight, backgroundColor);
  for (final (x0, x1, destination) in <(double, double, BoardQuad)>[
    (0, xLeft, corners.leftLeaf),
    (xLeft, xRight, corners.hinge),
    (xRight, sw.toDouble(), corners.rightLeaf),
  ]) {
    _paintWarp(
      rgb,
      outWidth,
      outHeight,
      src,
      sw,
      sh,
      PlaneHomography.fromQuads(
        BoardQuad(
          topLeft: Pt(x0, 0),
          topRight: Pt(x1, 0),
          bottomRight: Pt(x1, sh.toDouble()),
          bottomLeft: Pt(x0, sh.toDouble()),
        ),
        destination,
      ).inverted,
      x0,
      x1,
    );
  }

  var frame = Frame(rgb, outWidth, outHeight);
  if (degradation.blurSigma > 0) {
    frame = _blurred(frame, degradation.blurSigma);
  }
  if (degradation.noise > 0) {
    frame = _noised(frame, degradation.noise, degradation.seed);
  }
  return FoldingShot(
    frame: frame,
    groundTruthCorners: corners,
    board: rendered,
    proportions: proportions,
  );
}

/// Where [view] puts the eight points of a board with a [barWidth] hinge.
///
/// The tent's profile: each leaf is a flat plane running from its outer edge
/// on the table up to the ridge, and the strip between them is flat at the
/// ridge's own height. Three planes, meeting along two lines, which is what a
/// folding case actually is.
FoldingCorners foldingCornersOf(
  FoldingView view, {
  required double barWidth,
  required double aspect,
  required Pt principal,
}) {
  final leftLeafEnd = (1 - barWidth) / 2;
  final rightLeafStart = (1 + barWidth) / 2;

  double heightAt(double x) {
    if (x <= leftLeafEnd) return view.ridgeHeight * x / leftLeafEnd;
    if (x >= rightLeafStart) {
      return view.ridgeHeight * (1 - x) / (1 - rightLeafStart);
    }
    return view.ridgeHeight;
  }

  final camera = _Pinhole(view, principal);
  // Board space's y runs far edge to near edge; the world's runs away from the
  // camera, so the far edge is at the larger y.
  Pt at(double x, double boardY) =>
      camera.project(x, (1 - boardY) * aspect, heightAt(x));

  return FoldingCorners(
    topLeft: at(0, 0),
    topRight: at(1, 0),
    bottomRight: at(1, 1),
    bottomLeft: at(0, 1),
    hingeFarLeft: at(leftLeafEnd, 0),
    hingeFarRight: at(rightLeafStart, 0),
    hingeNearLeft: at(leftLeafEnd, 1),
    hingeNearRight: at(rightLeafStart, 1),
  );
}

/// A pinhole camera: look-at rotation, then a perspective divide.
///
/// Image axes are the usual ones — x right, y down, z forward — which with a
/// world whose z is up means the image's "down" is `f x r`.
class _Pinhole {
  final List<double> _rows;
  final (double, double, double) _eye;
  final double _focal;
  final Pt _principal;

  factory _Pinhole(FoldingView view, Pt principal) {
    final f = _normalize((
      view.target.$1 - view.eye.$1,
      view.target.$2 - view.eye.$2,
      view.target.$3 - view.eye.$3,
    ));
    final r = _normalize(_cross(f, (0, 0, 1)));
    final d = _cross(f, r);
    return _Pinhole._(
      <double>[r.$1, r.$2, r.$3, d.$1, d.$2, d.$3, f.$1, f.$2, f.$3],
      view.eye,
      view.focal,
      principal,
    );
  }

  const _Pinhole._(this._rows, this._eye, this._focal, this._principal);

  Pt project(double x, double y, double z) {
    final dx = x - _eye.$1, dy = y - _eye.$2, dz = z - _eye.$3;
    final cx = _rows[0] * dx + _rows[1] * dy + _rows[2] * dz;
    final cy = _rows[3] * dx + _rows[4] * dy + _rows[5] * dz;
    final cz = _rows[6] * dx + _rows[7] * dy + _rows[8] * dz;
    if (cz <= 0) {
      throw ArgumentError('the point ($x, $y, $z) is behind the camera');
    }
    return Pt(
      _principal.x + _focal * cx / cz,
      _principal.y + _focal * cy / cz,
    );
  }
}

(double, double, double) _cross(
  (double, double, double) a,
  (double, double, double) b,
) =>
    (
      a.$2 * b.$3 - a.$3 * b.$2,
      a.$3 * b.$1 - a.$1 * b.$3,
      a.$1 * b.$2 - a.$2 * b.$1,
    );

(double, double, double) _normalize((double, double, double) v) {
  final n = math.sqrt(v.$1 * v.$1 + v.$2 * v.$2 + v.$3 * v.$3);
  if (n == 0) throw ArgumentError('cannot normalize a zero vector');
  return (v.$1 / n, v.$2 / n, v.$3 / n);
}

/// Each corner of [quad] moved by up to [amplitude] pixels in x and y.
///
/// Its own generator, seeded apart from the noise's, so that changing how
/// grainy a shot is does not silently move the board underneath it.
///
/// Public because a whole capture *session* wants one jitter, not one per
/// shot: the board does not move between two photographs taken a few seconds
/// apart, and giving each shot its own wobble would model something that does
/// not happen. The corpus generator jitters a session's quad once and renders
/// every shot in that session onto it.
BoardQuad jitterQuad(BoardQuad quad, double amplitude, int seed) {
  final rng = math.Random(seed);
  double wobble() => (rng.nextDouble() * 2 - 1) * amplitude;
  return BoardQuad.fromCorners(<Pt>[
    for (final c in quad.corners) Pt(c.x + wobble(), c.y + wobble()),
  ]);
}

/// Uniform additive grain, one draw per channel per pixel.
Frame _noised(Frame frame, double amplitude, int seed) {
  // Seeded apart from the jitter's generator: two knobs that shared a stream
  // would move together whenever either was turned.
  final rng = math.Random(seed * 31 + 17);
  final bytes = Uint8List.fromList(frame.rgb);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (bytes[i] + (rng.nextDouble() * 2 - 1) * amplitude)
        .round()
        .clamp(0, 255);
  }
  return Frame(bytes, frame.width, frame.height);
}

/// A separable gaussian blur, edges handled by clamping to the border.
///
/// Separable because the alternative is a two-dimensional kernel over a
/// million-pixel frame for every shot in the corpus, and the corpus is
/// generated from a tool a person waits on.
Frame _blurred(Frame frame, double sigma) {
  final radius = math.max(1, (3 * sigma).ceil());
  final kernel = Float64List(2 * radius + 1);
  var total = 0.0;
  for (var i = -radius; i <= radius; i++) {
    final w = math.exp(-(i * i) / (2 * sigma * sigma));
    kernel[i + radius] = w;
    total += w;
  }
  for (var i = 0; i < kernel.length; i++) {
    kernel[i] /= total;
  }

  final w = frame.width, h = frame.height;
  final horizontal = Uint8List(frame.rgb.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final sx = (x + k).clamp(0, w - 1);
        final i = (y * w + sx) * 3;
        final weight = kernel[k + radius];
        r += frame.rgb[i] * weight;
        g += frame.rgb[i + 1] * weight;
        b += frame.rgb[i + 2] * weight;
      }
      final o = (y * w + x) * 3;
      horizontal[o] = r.round().clamp(0, 255);
      horizontal[o + 1] = g.round().clamp(0, 255);
      horizontal[o + 2] = b.round().clamp(0, 255);
    }
  }

  final out = Uint8List(frame.rgb.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final sy = (y + k).clamp(0, h - 1);
        final i = (sy * w + x) * 3;
        final weight = kernel[k + radius];
        r += horizontal[i] * weight;
        g += horizontal[i + 1] * weight;
        b += horizontal[i + 2] * weight;
      }
      final o = (y * w + x) * 3;
      out[o] = r.round().clamp(0, 255);
      out[o + 1] = g.round().clamp(0, 255);
      out[o + 2] = b.round().clamp(0, 255);
    }
  }
  return Frame(out, w, h);
}

/// Reads one pixel of a top-down render, so tests need no `package:image`.
(int, int, int) topDownPixel(RenderedBoard board, int x, int y) {
  final p = board.image.getPixel(x, y);
  return (p.r.toInt(), p.g.toInt(), p.b.toInt());
}

// --- drawing, one element per function -------------------------------------

img.Color _color(int rgb) =>
    img.ColorRgb8((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

/// The wood — surround, bar and both tray wells — then the felt of the two
/// playing halves on top of it.
///
/// On a board with no wells the felt runs to the picture's own edges and the
/// only wood left is the hinge down the middle, which is exactly what a
/// folding case looks like from above.
void _drawFrameAndFelt(img.Image image, BoardPalette palette,
    BoardLayout layout) {
  final w = image.width, h = image.height;
  final p = layout.proportions;
  img.fill(image, color: _color(palette.frame));
  for (final (start, end) in <(double, double)>[
    (p.leftHalfStart, p.leftHalfEnd),
    (p.rightHalfStart, p.rightHalfEnd),
  ]) {
    img.fillRect(
      image,
      x1: (start * w).round(),
      y1: 0,
      x2: (end * w).round() - 1,
      y2: h - 1,
      color: _color(palette.felt),
    );
  }
}

void _drawPoints(img.Image image, BoardPalette palette, BoardLayout layout) {
  for (var i = 0; i < 24; i++) {
    _drawPointTriangle(image, i, palette, layout);
  }
}

/// One triangle, pointing inward from its own edge of the board.
void _drawPointTriangle(
  img.Image image,
  int index,
  BoardPalette palette,
  BoardLayout layout,
) {
  final w = image.width, h = image.height;
  final (left, right) = layout.pointSpan(index);
  final x1 = left * w, x2 = right * w;
  final tip = BoardLayout.pointLength * h;
  final near = BoardLayout.isNearHalf(index);
  final baseY = near ? h - 1.0 : 0.0;
  final tipY = near ? h - 1.0 - tip : tip;
  img.fillPolygon(
    image,
    vertices: <img.Point>[
      img.Point(x1, baseY),
      img.Point(x2, baseY),
      img.Point((x1 + x2) / 2, tipY),
    ],
    // Alternating so no two neighbouring points share a colour.
    color: _color(index.isEven ? palette.pointDark : palette.pointLight),
  );
}

/// The wear down a folding case's spine: a shadowed seam where the two leaves
/// meet, and a worn crown either side of it. See [SpineWear] for the board
/// this was measured off and why it is three surfaces rather than two.
///
/// Painted over the whole height of the hinge strip, because that is what wear
/// down a spine looks like — a stripe running the length of the ridge, not a
/// blob sitting on it. That difference is the whole point of the bed: a
/// checker standing on the spine is a blob, and calibration has to go on
/// telling the two apart.
void _drawSpineWear(
  img.Image image,
  BoardPalette palette,
  BoardLayout layout,
  SpineWear wear,
) {
  if (wear.isNothing) return;
  final w = image.width, h = image.height;
  final p = layout.proportions;
  final left = p.barStart * w, right = p.barEnd * w;
  final centre = (left + right) / 2;
  final strip = right - left;
  final crown = _blend(palette.frame, palette.whiteChecker, wear.paleness);
  final seam = _scaled(palette.frame, 1 - wear.seamShade);

  for (final (from, to, colour) in <(double, double, int)>[
    (wear.seamWidth / 2, wear.seamWidth / 2 + wear.crownWidth, crown),
    (0, wear.seamWidth / 2, seam),
  ]) {
    for (final sign in <double>[-1, 1]) {
      final a = centre + sign * from * strip;
      final b = centre + sign * to * strip;
      img.fillRect(
        image,
        x1: math.min(a, b).round(),
        y1: 0,
        x2: math.max(a, b).round(),
        y2: h - 1,
        color: _color(colour),
      );
    }
  }
}

/// The ellipse [occluder] describes, filled flat over whatever is under it.
///
/// Flat rather than shaded on purpose: a hand has a shape and a shadow, and
/// neither is what the readability check keys on. What it keys on is that the
/// patch is not one of the board's own surfaces, and a flat fill is the
/// smallest thing that says so — everything else would be detail the bed cannot
/// claim to have measured.
void _drawOccluder(img.Image image, BoardOccluder occluder) {
  if (occluder.isNothing) return;
  final w = image.width, h = image.height;
  final paint = _color(occluder.color);
  final cx = occluder.center.x * w, cy = occluder.center.y * h;
  final rx = occluder.radiusX * w, ry = occluder.radiusY * h;
  final x0 = math.max(0, (cx - rx).floor());
  final x1 = math.min(w - 1, (cx + rx).ceil());
  final y0 = math.max(0, (cy - ry).floor());
  final y1 = math.min(h - 1, (cy + ry).ceil());
  for (var y = y0; y <= y1; y++) {
    final dy = (y - cy) / ry;
    for (var x = x0; x <= x1; x++) {
      final dx = (x - cx) / rx;
      if (dx * dx + dy * dy <= 1) image.setPixel(x, y, paint);
    }
  }
}

/// [a] mixed toward [b], channel by channel.
int _blend(int a, int b, double t) {
  var out = 0;
  for (var shift = 16; shift >= 0; shift -= 8) {
    final ca = (a >> shift) & 0xFF, cb = (b >> shift) & 0xFF;
    out |= (ca + (cb - ca) * t).round().clamp(0, 255) << shift;
  }
  return out;
}

/// [a] with every channel multiplied — the same colour in less light, which is
/// what a shadow on a board's own wood is.
int _scaled(int a, double factor) {
  var out = 0;
  for (var shift = 16; shift >= 0; shift -= 8) {
    out |= (((a >> shift) & 0xFF) * factor).round().clamp(0, 255) << shift;
  }
  return out;
}

/// The decorative inlay a great many real boards carry in the middle of each
/// half — a small star let into the felt, mid-field, one per half.
///
/// Drawn in the palette's own light point colour, which is what an inlay in a
/// contrasting wood looks like and, more to the point, is not the felt and not
/// the bar. That makes it a **third** surface inside the dice band and inside
/// the headroom of the two middle points of each half — and calibration models
/// a region's surfaces with two-means, i.e. with two. Whether that survives is
/// a question worth having a bed for; see the calibration tests.
void _drawStarInlays(img.Image image, BoardPalette palette, BoardLayout layout) {
  final w = image.width, h = image.height;
  final p = layout.proportions;
  const outer = 0.05, inner = 0.019, points = 4;
  for (final (start, end) in <(double, double)>[
    (p.leftHalfStart, p.leftHalfEnd),
    (p.rightHalfStart, p.rightHalfEnd),
  ]) {
    final cx = (start + end) / 2 * w, cy = h / 2;
    final vertices = <img.Point>[];
    for (var i = 0; i < points * 2; i++) {
      final radius = (i.isEven ? outer : inner) * h;
      final angle = i * math.pi / points - math.pi / 2;
      vertices.add(img.Point(
        cx + radius * math.cos(angle),
        cy + radius * math.sin(angle),
      ));
    }
    img.fillPolygon(image, vertices: vertices, color: _color(palette.pointLight));
  }
}

/// Every checker on the board, the bar and both trays; returns where they went.
///
/// [placement] moves every stack on a point; [pointPlacements] overrides it for
/// named points. Neither touches the bar or the trays: what a hand does to a
/// point's stack is what the checker finder had to be built for, and a queue in
/// a well is not that.
List<CheckerSpot> _drawCheckers(
  img.Image image,
  BoardState board,
  BoardPalette palette,
  BoardLayout layout,
  StackPlacement placement,
  Map<int, StackPlacement> pointPlacements,
) {
  final spots = <CheckerSpot>[];
  final w = image.width, h = image.height;
  final p = layout.proportions;
  final radius = p.columnWidth * w * BoardLayout.checkerRadiusFraction;

  // The two offsets every stack lives between, measured from the board edge
  // the stack belongs to. `edgeOffset` seats the first checker against that
  // edge; `midlineOffset` is as far as the last one may reach — the far edge
  // of the last checker stops at the middle of the board, so a tall point can
  // never bleed into the column facing it and the two halves stay
  // independently measurable.
  final edgeOffset = radius + BoardLayout.stackEdgeMargin * h;
  final midlineOffset = h / 2 - radius;

  for (var i = 0; i < 24; i++) {
    final count = board.points[i].abs();
    if (count == 0) continue;
    final owner = board.points[i] > 0 ? Player.white : Player.black;
    final (left, right) = layout.pointSpan(i);
    final seat = pointPlacements[i] ?? placement;
    spots.addAll(_drawCheckerStack(
      image: image,
      palette: palette,
      owner: owner,
      area: SpotArea.point,
      pointIndex: i,
      centerX:
          ((left + right) / 2 + seat.centerOffset * p.columnWidth) * w,
      fromNearEdge: BoardLayout.isNearHalf(i),
      count: count,
      radius: radius,
      firstOffset: edgeOffset + seat.edgeInset * h,
      lastOffsetLimit: midlineOffset,
      lampGain: seat.lampGain,
      faceGain: seat.faceGain,
    ));
  }

  // The bar grows the other way: from the middle of the board OUTWARD toward
  // each player's own edge, White toward the near one and Black toward the
  // far one, so however many checkers are sitting there the two never meet.
  final barX = (p.barStart + p.barEnd) / 2 * w;
  for (final (player, count) in <(Player, int)>[
    (Player.white, board.whiteBar),
    (Player.black, board.blackBar),
  ]) {
    if (count == 0) continue;
    spots.addAll(_drawCheckerStack(
      image: image,
      palette: palette,
      owner: player,
      area: SpotArea.bar,
      pointIndex: -1,
      centerX: barX,
      fromNearEdge: player == Player.white,
      count: count,
      radius: radius,
      firstOffset: midlineOffset,
      lastOffsetLimit: edgeOffset,
    ));
  }

  // Both home boards are on the right, so both trays are the right-hand well:
  // White's borne-off checkers stack from the near edge, Black's from the far.
  // A board with no wells never gets here — renderTopDown refuses a board
  // state with checkers off, because there would be nowhere to draw them.
  final trayX = (p.rightTrayStart + 1.0) / 2 * w;
  for (final (player, count) in <(Player, int)>[
    (Player.white, board.whiteOff),
    (Player.black, board.blackOff),
  ]) {
    if (count == 0) continue;
    spots.addAll(_drawCheckerStack(
      image: image,
      palette: palette,
      owner: player,
      area: SpotArea.off,
      pointIndex: -1,
      centerX: trayX,
      fromNearEdge: player == Player.white,
      count: count,
      radius: radius,
      firstOffset: edgeOffset,
      lastOffsetLimit: midlineOffset,
    ));
  }

  return spots;
}

/// A column of [count] checkers running from [firstOffset] toward
/// [lastOffsetLimit], both measured from the board edge named by
/// [fromNearEdge].
///
/// Spacing is a full diameter until the stack would overshoot the limit, then
/// compresses so it never does — which is what a real player does with a tall
/// point, and it is what keeps the two halves of the board from touching.
List<CheckerSpot> _drawCheckerStack({
  required img.Image image,
  required BoardPalette palette,
  required Player owner,
  required SpotArea area,
  required int pointIndex,
  required double centerX,
  required bool fromNearEdge,
  required int count,
  required double radius,
  required double firstOffset,
  required double lastOffsetLimit,
  double lampGain = 1,
  double faceGain = 1,
}) {
  final h = image.height;
  final travel = lastOffsetLimit - firstOffset;
  final step = count > 1
      ? (travel.sign) * math.min(2 * radius, travel.abs() / (count - 1))
      : 0.0;

  final base = palette.checkerColor(owner);
  final spots = <CheckerSpot>[];
  for (var k = 0; k < count; k++) {
    final offset = firstOffset + k * step;
    final center = Pt(centerX, fromNearEdge ? h - 1 - offset : offset);
    // The rim first, then the well inside it. Drawn as two discs rather than
    // as a ring so that a checker with no well is the same call — down to the
    // rasteriser — that it always was.
    for (final (r, gain) in <(double, double)>[
      (radius, 1.0),
      if (faceGain != 1)
        (radius * BoardLayout.checkerFaceFraction, faceGain),
    ]) {
      final paint = gain == 1 ? base : _scaled(base, gain);
      if (lampGain == 1) {
        img.fillCircle(
          image,
          x: center.x.round(),
          y: center.y.round(),
          radius: r.round(),
          color: _color(paint),
        );
      } else {
        _fillLitCircle(
          image,
          centerX: center.x.round(),
          centerY: center.y.round(),
          radius: r.round(),
          base: paint,
          fromNearEdge: fromNearEdge,
          lampGain: lampGain,
        );
      }
    }
    spots.add(CheckerSpot(
      owner: owner,
      area: area,
      pointIndex: pointIndex,
      indexInStack: k,
      center: center,
      radius: radius,
    ));
  }
  return spots;
}

/// How far in from the board's edge the shadow at the foot of a lit stack
/// lifts, in board-space y — about one checker.
///
/// The shape matters more than the size, and it is the shape the real frame
/// showed: the light does not ramp evenly up a stack, it is BLOCKED at the
/// foot. The near checker sits down in the well of its own point with the rest
/// of the stack in front of it, so it is in shadow; a checker or so further in,
/// the stack is clear of it and everything past that is lit alike. Measured on
/// the real folding frame's 19-point: 32 at the foot, 59 seven hundredths in,
/// 67 beyond that — most of the climb inside the first checker, then flat.
///
/// That the climb happens INSIDE the first checker is the whole reason this is
/// drawn per row rather than per disc. `RoiSampler.checkerHoldDepth` is 0.07
/// and the bed's flat-drawn checkers are deeper than that, so a step painted
/// between one disc and the next falls entirely outside the window the hold
/// test looks through, and a lamp modelled that way is invisible to the
/// instrument it is meant to test. That is not a modelling nicety — a lamp
/// drawn per disc passes with the very brightness bound the real frame
/// refused.
const double kLampShadowReach = 0.10;

/// One checker of a lit stack, shaded row by row.
///
/// Every channel moves by the same factor, so what changes down the disc is
/// the light and not the colour — which is exactly the case the walk's hold
/// test has to survive, since it judges colour with brightness taken out.
void _fillLitCircle(
  img.Image image, {
  required int centerX,
  required int centerY,
  required int radius,
  required int base,
  required bool fromNearEdge,
  required double lampGain,
}) {
  final h = image.height;
  for (var dy = -radius; dy <= radius; dy++) {
    final y = centerY + dy;
    if (y < 0 || y >= h) continue;
    final halfWidth =
        math.sqrt(math.max(0, radius * radius - dy * dy)).round();
    // How far this row is from the board edge the stack grows out of, in
    // board space — the same y the sampler walks in.
    final depth = (fromNearEdge ? h - 1 - y : y) / h;
    final lit =
        1 + (lampGain - 1) * math.min(1.0, depth / kLampShadowReach);
    final color = _color(_scaled(base, lit));
    for (var x = centerX - halfWidth; x <= centerX + halfWidth; x++) {
      if (x < 0 || x >= image.width) continue;
      image.setPixel(x, y, color);
    }
  }
}

/// Where a [Dice] lands when nothing says otherwise: both on the vertical
/// midline, inside the right half, at whatever angle was asked for.
List<DicePlacement> _defaultPlacements(Dice? dice, double angle) {
  if (dice == null) return const <DicePlacement>[];
  return <DicePlacement>[
    for (final (value, cx) in <(int, double)>[
      (dice.die1, BoardLayout.firstDieCentreX),
      (dice.die2, BoardLayout.secondDieCentreX),
    ])
      DicePlacement(face: value, center: Pt(cx, 0.5), angle: angle),
  ];
}

/// The dice, drawn last so they sit on top of whatever they landed near.
List<DieSpot> _drawDice(
  img.Image image,
  List<DicePlacement> placements,
  BoardPalette palette,
  double dieSide,
) {
  final w = image.width, h = image.height;
  final side = dieSide * w;
  final spots = <DieSpot>[];
  for (final placement in placements) {
    final spot = DieSpot(
      value: placement.face,
      center: Pt(placement.center.x * w, placement.center.y * h),
      side: side,
      angle: placement.angle,
    );
    _drawDie(image, spot, palette);
    spots.add(spot);
  }
  return spots;
}

void _drawDie(img.Image image, DieSpot die, BoardPalette palette) {
  final half = die.side / 2;
  final cos = math.cos(die.angle), sin = math.sin(die.angle);
  Pt place(double dx, double dy) => Pt(
        die.center.x + dx * cos - dy * sin,
        die.center.y + dx * sin + dy * cos,
      );

  img.fillPolygon(
    image,
    vertices: <img.Point>[
      for (final (dx, dy) in <(double, double)>[
        (-half, -half),
        (half, -half),
        (half, half),
        (-half, half),
      ])
        () {
          final p = place(dx, dy);
          return img.Point(p.x, p.y);
        }(),
    ],
    color: _color(palette.dieBody),
  );

  final pipRadius = (BoardLayout.pipRadiusFraction * die.side).round();
  final step = die.side / 4;
  for (final (px, py) in _pipOffsets(die.value)) {
    final p = place(px * step, py * step);
    img.fillCircle(
      image,
      x: p.x.round(),
      y: p.y.round(),
      radius: pipRadius,
      color: _color(palette.diePip),
    );
  }
}

/// Pip positions for a face, in units of a quarter of the die's side from its
/// centre — the standard layouts, so a die reads the same as a real one.
List<(double, double)> _pipOffsets(int value) {
  const tl = (-1.0, -1.0), tr = (1.0, -1.0);
  const ml = (-1.0, 0.0), mr = (1.0, 0.0);
  const bl = (-1.0, 1.0), br = (1.0, 1.0);
  const c = (0.0, 0.0);
  switch (value) {
    case 1:
      return const <(double, double)>[c];
    case 2:
      return const <(double, double)>[tl, br];
    case 3:
      return const <(double, double)>[tl, c, br];
    case 4:
      return const <(double, double)>[tl, tr, bl, br];
    case 5:
      return const <(double, double)>[tl, tr, c, bl, br];
    case 6:
      return const <(double, double)>[tl, tr, ml, mr, bl, br];
    default:
      throw ArgumentError('a die face is 1..6, got $value');
  }
}

/// Scales the whole board toward black (or toward clipping) to stand in for
/// a dim room or a bright lamp.
/// How much light there is, and what colour it is, in one pass over the paint.
///
/// The two are separate knobs and one loop: with [cast] neutral every channel
/// is multiplied by exactly `1.0` after the gain, so a render that does not ask
/// for a cast produces the identical bytes it always did — which the corpus
/// re-render guard checks rather than takes on trust.
void _applyLight(img.Image image, double gain, LightCast cast) {
  if (gain == 1.0 && cast.isNeutral) return;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      image.setPixelRgb(
        x,
        y,
        (p.r * gain * cast.red).round().clamp(0, 255),
        (p.g * gain * cast.green).round().clamp(0, 255),
        (p.b * gain * cast.blue).round().clamp(0, 255),
      );
    }
  }
}

img.Image _rotateHalfTurn(img.Image source) {
  final w = source.width, h = source.height;
  final out = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = source.getPixel(x, y);
      out.setPixelRgb(w - 1 - x, h - 1 - y, p.r, p.g, p.b);
    }
  }
  return out;
}

Pt _halfTurn(Pt p, int width, int height) =>
    Pt(width - 1 - p.x, height - 1 - p.y);
