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

/// What surrounds the board in a warped frame — "the room", not the board.
/// Unlike the board itself this is NOT scaled by `lightingGain`; the gain
/// models the light falling on the playing field, which is what the
/// readability checks measure.
const int kBackdropColor = 0x101418;

/// The board's layout in **board space**: the playing field as the unit
/// rectangle (0,0)–(1,1), x rightward and y from the far edge to the near one.
///
/// These fractions are the renderer's contract with Task 2's ROI atlas: the
/// atlas addresses the same unit rectangle, so if the two disagree the ROIs
/// land off the drawn elements and the atlas tests fail loudly — which is the
/// intent. Under [BoardOrientation.whiteHomeNear] the standard diagram
/// applies: points 1–6 bottom-right, 7–12 bottom-left, 13–18 top-left, 19–24
/// top-right, with point 1 at the far right and point 12 at the far left.
class BoardLayout {
  const BoardLayout._();

  /// One bear-off tray column at each end of the board.
  static const double trayWidth = 0.08;

  /// The bar down the middle.
  static const double barWidth = 0.08;

  /// Twelve point columns share what the trays and bar leave.
  static const double columnWidth = (1.0 - 2 * trayWidth - barWidth) / 12.0;

  static const double leftTrayEnd = trayWidth;
  static const double leftHalfStart = trayWidth;
  static const double leftHalfEnd = leftHalfStart + 6 * columnWidth;
  static const double barStart = leftHalfEnd;
  static const double barEnd = barStart + barWidth;
  static const double rightHalfStart = barEnd;
  static const double rightHalfEnd = rightHalfStart + 6 * columnWidth;
  static const double rightTrayStart = rightHalfEnd;

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
  static (double, double) pointSpan(int index) {
    if (index < 0 || index > 23) {
      throw RangeError.range(index, 0, 23, 'index', 'point index');
    }
    final double left;
    if (index <= 5) {
      // Points 1–6: bottom right, point 1 hard against the right tray.
      left = rightHalfEnd - (index + 1) * columnWidth;
    } else if (index <= 11) {
      // Points 7–12: bottom left, point 7 against the bar.
      left = leftHalfEnd - (index - 6 + 1) * columnWidth;
    } else if (index <= 17) {
      // Points 13–18: top left, point 13 above point 12.
      left = leftHalfStart + (index - 12) * columnWidth;
    } else {
      // Points 19–24: top right, point 19 against the bar.
      left = rightHalfStart + (index - 18) * columnWidth;
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
RenderedBoard renderTopDown({
  required BoardState board,
  Dice? dice,
  BoardPalette palette = BoardPalette.classic,
  double lightingGain = 1.0,
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
  double diceAngle = 0.0,
  int width = kTopDownWidth,
  int height = kTopDownHeight,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('render size must be positive, got ${width}x$height');
  }
  if (lightingGain <= 0) {
    throw ArgumentError('lightingGain must be positive, got $lightingGain');
  }

  final image = img.Image(width: width, height: height);
  _drawFrameAndFelt(image, palette);
  _drawPoints(image, palette);
  final checkers = _drawCheckers(image, board, palette);
  final drawnDice = dice == null
      ? const <DieSpot>[]
      : _drawDice(image, dice, palette, diceAngle);
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

  // Flatten the source once: `getPixel` per bilinear tap would be four object
  // reads per output pixel, and a warp is over a million output pixels.
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

  final bgR = (backgroundColor >> 16) & 0xFF;
  final bgG = (backgroundColor >> 8) & 0xFF;
  final bgB = backgroundColor & 0xFF;

  final rgb = Uint8List(outWidth * outHeight * 3);
  var o = 0;
  for (var y = 0; y < outHeight; y++) {
    for (var x = 0; x < outWidth; x++) {
      final p = inverse.map(Pt(x.toDouble(), y.toDouble()));
      if (p.x < 0 || p.y < 0 || p.x > sw - 1 || p.y > sh - 1 || p.x.isNaN) {
        rgb[o++] = bgR;
        rgb[o++] = bgG;
        rgb[o++] = bgB;
        continue;
      }
      final x0 = p.x.floor(), y0 = p.y.floor();
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
  return (
    frame: Frame(rgb, outWidth, outHeight),
    groundTruthQuad: destination,
  );
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
  int topDownWidth = kTopDownWidth,
  int topDownHeight = kTopDownHeight,
  BoardQuad quad = kCameraQuad,
  int outWidth = kFrameWidth,
  int outHeight = kFrameHeight,
  int backgroundColor = kBackdropColor,
}) {
  final rendered = renderTopDown(
    board: board,
    dice: dice,
    palette: palette,
    lightingGain: lightingGain,
    orientation: orientation,
    diceAngle: diceAngle,
    width: topDownWidth,
    height: topDownHeight,
  );
  final warped = warpToQuad(
    rendered.image,
    quad,
    outWidth: outWidth,
    outHeight: outHeight,
    backgroundColor: backgroundColor,
  );
  return SyntheticShot(
    frame: warped.frame,
    groundTruthQuad: warped.groundTruthQuad,
    board: rendered,
    topDownToFrame: PlaneHomography.fromQuads(
      BoardQuad.rect(
        rendered.image.width.toDouble(),
        rendered.image.height.toDouble(),
      ),
      quad,
    ),
  );
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
void _drawFrameAndFelt(img.Image image, BoardPalette palette) {
  final w = image.width, h = image.height;
  img.fill(image, color: _color(palette.frame));
  for (final (start, end) in <(double, double)>[
    (BoardLayout.leftHalfStart, BoardLayout.leftHalfEnd),
    (BoardLayout.rightHalfStart, BoardLayout.rightHalfEnd),
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

void _drawPoints(img.Image image, BoardPalette palette) {
  for (var i = 0; i < 24; i++) {
    _drawPointTriangle(image, i, palette);
  }
}

/// One triangle, pointing inward from its own edge of the board.
void _drawPointTriangle(img.Image image, int index, BoardPalette palette) {
  final w = image.width, h = image.height;
  final (left, right) = BoardLayout.pointSpan(index);
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

/// Every checker on the board, the bar and both trays; returns where they went.
List<CheckerSpot> _drawCheckers(
  img.Image image,
  BoardState board,
  BoardPalette palette,
) {
  final spots = <CheckerSpot>[];
  final w = image.width, h = image.height;
  final radius = BoardLayout.columnWidth * w * BoardLayout.checkerRadiusFraction;

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
    final (left, right) = BoardLayout.pointSpan(i);
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
  final barX = (BoardLayout.barStart + BoardLayout.barEnd) / 2 * w;
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
  final trayX = (BoardLayout.rightTrayStart + 1.0) / 2 * w;
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

/// Both dice, drawn last so they sit on top of whatever they landed near.
List<DieSpot> _drawDice(
  img.Image image,
  Dice dice,
  BoardPalette palette,
  double angle,
) {
  final w = image.width, h = image.height;
  final side = BoardLayout.dieSide * w;
  final spots = <DieSpot>[];
  for (final (value, cx) in <(int, double)>[
    (dice.die1, BoardLayout.firstDieCentreX),
    (dice.die2, BoardLayout.secondDieCentreX),
  ]) {
    final spot = DieSpot(
      value: value,
      center: Pt(cx * w, h / 2),
      side: side,
      angle: angle,
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
