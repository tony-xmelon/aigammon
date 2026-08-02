import 'geometry_types.dart';

/// One addressable region of a backgammon board.
///
/// The twenty-four points are indexed exactly as `BoardState.points` in
/// `backgammon_core`: [point0] is `points[0]`, which is **White's 1-point** —
/// the point numbered 1 in the usual diagram, in the corner of White's home
/// board. Points count up the way White's checkers move down, so [point23] is
/// White's 24-point (Black's 1-point).
///
/// The cube is not here on purpose: the spec keeps it a verbal ritual and
/// never looks at it.
enum RoiId {
  // Points 1-6, White's home board: bottom right under whiteHomeNear, with
  // point 1 hard against the tray and point 6 against the bar.
  point0(0), point1(1), point2(2), point3(3), point4(4), point5(5),
  // Points 7-12, bottom left: point 7 against the bar, point 12 at the edge.
  point6(6), point7(7), point8(8), point9(9), point10(10), point11(11),
  // Points 13-18, top left: point 13 directly above point 12.
  point12(12), point13(13), point14(14), point15(15), point16(16), point17(17),
  // Points 19-24, top right: point 24 directly above point 1.
  point18(18), point19(19), point20(20), point21(21), point22(22), point23(23),

  /// The bar, one region for both colours. White's checkers stack from the
  /// middle toward the near edge and Black's toward the far one, so the
  /// region spans the board's full height and occupancy separates them.
  bar(-1),

  /// White's bear-off tray. Both trays are the same well split at the
  /// midline — the RIGHT-hand well under `whiteHomeNear`, rotated to the
  /// left-hand one under `whiteHomeFar` like every other region — and
  /// White's half is whichever the atlas's orientation puts it at.
  offWhite(-1),

  /// Black's bear-off tray — the other half of the same well as [offWhite].
  offBlack(-1),

  /// The strip of felt the point triangles do not reach, across both halves
  /// and the bar. Where settled dice are looked for.
  diceZone(-1);

  const RoiId(this.pointIndex);

  /// The `BoardState.points` index this region is, or `-1` for the bar, the
  /// trays and the dice zone.
  final int pointIndex;

  /// The region of `BoardState.points[index]`.
  static RoiId point(int index) {
    if (index < 0 || index > 23) {
      throw RangeError.range(index, 0, 23, 'index', 'point index');
    }
    return values[index];
  }
}

/// Where everything is on the board, in board space.
///
/// ## The coordinate system
///
/// **The board is the unit rectangle `(0,0)`–`(1,1)`.** `x` runs left to
/// right and `y` from the board's far edge (0) to its near edge (1), "near"
/// meaning the edge closest to the camera. [Homography] is what carries a
/// frame's pixels into this rectangle; nothing downstream of calibration
/// works in pixels.
///
/// The rectangle is the **whole playing surface including both bear-off
/// trays** — the four corners the user drags onto the board during
/// calibration are the outer corners of the felt-and-wood field, not the
/// corners of the twelve-column area. Left to right it is: tray, six point
/// columns, bar, six point columns, tray, at [trayWidth], [columnWidth] and
/// [barWidth]. The synthetic renderer's `BoardLayout` draws to these same
/// fractions and the atlas tests assert the two agree.
///
/// ## Under [BoardOrientation.whiteHomeNear]
///
/// The standard diagram: points 1–6 bottom right, 7–12 bottom left, 13–18 top
/// left, 19–24 top right. [RoiId.point0] (White's 1-point) is therefore the
/// bottom-right column against the right tray, [RoiId.point11] is bottom far
/// left, [RoiId.point12] sits directly above it, and [RoiId.point23] directly
/// above [RoiId.point0]. [RoiId.point5] and [RoiId.point18] flank the bar on
/// its right, [RoiId.point6] and [RoiId.point17] on its left.
///
/// Under [BoardOrientation.whiteHomeFar] — the same physical board seen from
/// the other side of the table — every region is its whiteHomeNear self turned
/// half a turn about the board's centre: `(x, y)` becomes `(1-x, 1-y)`.
///
/// ## What a region covers
///
/// A **point** is its whole column from its own edge to the midline: the
/// triangle, which reaches [pointLength] in, plus the headroom a tall stack
/// spills into. Checkers stacked on a point never cross the midline — past
/// about five they compress instead, exactly as a player does with a tall
/// point — so the half a point sits in is precisely its region and no point
/// can ever bleed into the column facing it.
///
/// The **bar** is its full column, both colours. Each **tray** is half of
/// the bear-off well (the right-hand one under `whiteHomeNear`; rotated with
/// everything else under `whiteHomeFar`). The **dice zone** is the band
/// between the two rows of triangle tips, spanning both halves and the bar.
///
/// ## Overlaps, by design
///
/// Every region is disjoint from every other **except** [RoiId.diceZone],
/// which overlaps each point's headroom and the bar. That is not slack, it is
/// the same felt seen two ways: the band is exactly tiled by the 24 point
/// headrooms plus the bar's slice of it. Two consequences bind later work:
///
/// * a tall point's top checkers are inside the dice zone, and so is the
///   innermost checker of each colour on the bar — a dice reader must reject
///   round blobs sitting in a point column or on the bar rather than assume
///   the zone is empty of checkers;
/// * occupancy for a point must be measured over the whole region, headroom
///   included, or tall stacks read short.
///
/// The well opposite the bear-off one (left-hand under `whiteHomeNear`) is
/// addressed by no region: nothing is ever played there.
///
/// ## The board must not be mirrored
///
/// [BoardOrientation] expresses a half-turn only — there is no
/// `(BoardQuad, orientation)` pair that describes a MIRRORED board, one set
/// up with the home boards to the players' left. The atlas assumes the
/// standard right-handed setup, and the calibration UI (the plan's Task 12)
/// must say so out loud: "set up with your home board to your right", with
/// the start-position confirmation as the backstop that catches a mirrored
/// board before play begins (every point would read as its diagonal twin,
/// which the confirmation renders visibly wrong).
///
/// ## One set of proportions, provisionally
///
/// The fractions below are fixed, so the atlas assumes every board has the
/// same tray-to-column-to-bar proportions. Real boards do not, and the error
/// this causes is worst at the board's outer edges, where it accumulates over
/// six columns: a board whose trays are half again as wide as [trayWidth]
/// narrows every column to match and puts its outermost point more than half
/// a column away from where the atlas looks for it. A checker only clears its
/// column's boundary by about a twentieth of a column, so that is a miss, not
/// a wobble.
///
/// Whether that matters is a question for photographs, not for reasoning:
/// the corpus gate (the plan's Task 6) is where it gets answered, and the
/// answer is either "boards are close enough" or "the tray and bar widths
/// come from calibration too". Nothing downstream should hard-code these
/// numbers — ask the atlas, so there is one place to change.
class RoiAtlas {
  /// One bear-off tray column at each end of the board.
  static const double trayWidth = 0.08;

  /// The bar down the middle.
  static const double barWidth = 0.08;

  /// Twelve point columns share what the trays and the bar leave.
  static const double columnWidth = (1.0 - 2 * trayWidth - barWidth) / 12.0;

  static const double leftTrayEnd = trayWidth;
  static const double leftHalfStart = trayWidth;
  static const double leftHalfEnd = leftHalfStart + 6 * columnWidth;
  static const double barStart = leftHalfEnd;
  static const double barEnd = barStart + barWidth;
  static const double rightHalfStart = barEnd;
  static const double rightHalfEnd = rightHalfStart + 6 * columnWidth;
  static const double rightTrayStart = rightHalfEnd;

  /// How far a point's triangle reaches from its own edge, as a fraction of
  /// the board's height. What the two rows of tips leave in the middle is the
  /// dice zone.
  static const double pointLength = 0.42;

  /// The line no stack crosses, and the seam between the two halves.
  static const double midline = 0.5;

  final BoardOrientation orientation;
  final Map<RoiId, BoardQuad> _regions;

  const RoiAtlas._(this.orientation, this._regions);

  /// The atlas for a seating. Both are built once and shared; they are
  /// immutable.
  factory RoiAtlas.forOrientation(BoardOrientation orientation) =>
      orientation == BoardOrientation.whiteHomeNear ? _near : _far;

  static final RoiAtlas _near = RoiAtlas._(
    BoardOrientation.whiteHomeNear,
    _buildNear(),
  );

  static final RoiAtlas _far = RoiAtlas._(
    BoardOrientation.whiteHomeFar,
    Map<RoiId, BoardQuad>.unmodifiable(<RoiId, BoardQuad>{
      for (final entry in _buildNear().entries)
        entry.key: _halfTurn(entry.value),
    }),
  );

  /// The quadrilateral [id] covers, in board space.
  ///
  /// Always an axis-aligned rectangle today. It is typed as a [BoardQuad]
  /// because callers immediately push it through [Homography.mapToImage],
  /// where it stops being one.
  BoardQuad roi(RoiId id) => _regions[id]!;

  static Map<RoiId, BoardQuad> _buildNear() =>
      Map<RoiId, BoardQuad>.unmodifiable(<RoiId, BoardQuad>{
        for (var i = 0; i < 24; i++) RoiId.point(i): _pointRegion(i),
        RoiId.bar: _rect(barStart, 0, barEnd, 1),
        RoiId.offWhite: _rect(rightTrayStart, midline, 1, 1),
        RoiId.offBlack: _rect(rightTrayStart, 0, 1, midline),
        RoiId.diceZone: _rect(
          leftHalfStart,
          pointLength,
          rightHalfEnd,
          1 - pointLength,
        ),
      });

  static BoardQuad _pointRegion(int index) {
    final (left, right) = _pointSpan(index);
    return _isNearHalf(index)
        ? _rect(left, midline, right, 1)
        : _rect(left, 0, right, midline);
  }

  /// Horizontal span of point [index] under whiteHomeNear, as `(left, right)`.
  ///
  /// The four runs of six read outward from where each quadrant starts:
  /// points 1–6 back from the right tray, 7–12 back from the bar, 13–18
  /// forward from the left edge, 19–24 forward from the bar. That is the
  /// numbering going round the board, which is why the two bottom runs count
  /// leftward and the two top runs rightward.
  static (double, double) _pointSpan(int index) {
    final double left;
    if (index <= 5) {
      left = rightHalfEnd - (index + 1) * columnWidth;
    } else if (index <= 11) {
      left = leftHalfEnd - (index - 5) * columnWidth;
    } else if (index <= 17) {
      left = leftHalfStart + (index - 12) * columnWidth;
    } else {
      left = rightHalfStart + (index - 18) * columnWidth;
    }
    return (left, left + columnWidth);
  }

  /// Whether point [index] is on the half nearest the camera (points 1–12),
  /// where the perspective is kindest and the accuracy targets are highest.
  static bool _isNearHalf(int index) => index <= 11;

  static BoardQuad _rect(
    double left,
    double top,
    double right,
    double bottom,
  ) =>
      BoardQuad(
        topLeft: Pt(left, top),
        topRight: Pt(right, top),
        bottomRight: Pt(right, bottom),
        bottomLeft: Pt(left, bottom),
      );

  /// The same rectangle seen from the other side of the table. The corners
  /// are re-labelled as well as moved: a half turn sends the top-left corner
  /// to the bottom-right one, and [BoardQuad] promises to hold its corners
  /// clockwise from the top left.
  static BoardQuad _halfTurn(BoardQuad quad) {
    Pt turn(Pt p) => Pt(1 - p.x, 1 - p.y);
    return BoardQuad(
      topLeft: turn(quad.bottomRight),
      topRight: turn(quad.bottomLeft),
      bottomRight: turn(quad.topLeft),
      bottomLeft: turn(quad.topRight),
    );
  }

  @override
  String toString() => 'RoiAtlas(${orientation.name})';
}
