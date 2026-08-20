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
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
  double diceAngle = 0.0,
  List<DicePlacement>? dicePlacements,
  BoardProportions proportions = BoardProportions.standard,
  bool starInlays = false,
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
  if (starInlays) _drawStarInlays(image, palette, layout);
  final checkers = _drawCheckers(image, board, palette, layout);
  final drawnDice = _drawDice(
    image,
    dicePlacements ?? _defaultPlacements(dice, diceAngle),
    palette,
  );
  _applyLightingGain(image, lightingGain);

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
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
  double diceAngle = 0.0,
  List<DicePlacement>? dicePlacements,
  BoardProportions proportions = BoardProportions.standard,
  bool starInlays = false,
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
    orientation: orientation,
    diceAngle: diceAngle,
    dicePlacements: dicePlacements,
    proportions: proportions,
    starInlays: starInlays,
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
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
  List<DicePlacement>? dicePlacements,
  double barWidth = kFoldingBarWidth,
  bool starInlays = false,
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
    orientation: orientation,
    dicePlacements: dicePlacements,
    proportions: proportions,
    starInlays: starInlays,
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
List<CheckerSpot> _drawCheckers(
  img.Image image,
  BoardState board,
  BoardPalette palette,
  BoardLayout layout,
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
    spots.addAll(_drawCheckerStack(
      image: image,
      palette: palette,
      owner: owner,
      area: SpotArea.point,
      pointIndex: i,
      centerX: (left + right) / 2 * w,
      fromNearEdge: BoardLayout.isNearHalf(i),
      count: count,
      radius: radius,
      firstOffset: edgeOffset,
      lastOffsetLimit: midlineOffset,
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
}) {
  final h = image.height;
  final travel = lastOffsetLimit - firstOffset;
  final step = count > 1
      ? (travel.sign) * math.min(2 * radius, travel.abs() / (count - 1))
      : 0.0;

  final color = _color(palette.checkerColor(owner));
  final spots = <CheckerSpot>[];
  for (var k = 0; k < count; k++) {
    final offset = firstOffset + k * step;
    final center = Pt(centerX, fromNearEdge ? h - 1 - offset : offset);
    img.fillCircle(
      image,
      x: center.x.round(),
      y: center.y.round(),
      radius: radius.round(),
      color: color,
    );
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
) {
  final w = image.width, h = image.height;
  final side = BoardLayout.dieSide * w;
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
void _applyLightingGain(img.Image image, double gain) {
  if (gain == 1.0) return;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      image.setPixelRgb(
        x,
        y,
        (p.r * gain).round().clamp(0, 255),
        (p.g * gain).round().clamp(0, 255),
        (p.b * gain).round().clamp(0, 255),
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
