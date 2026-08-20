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
  ///
  /// **Not every board has one.** A folding case has no wells, and borne-off
  /// checkers leave such a board entirely; an atlas built for one does not
  /// carry this region at all. See [RoiAtlas.hasTrays].
  offWhite(-1),

  /// Black's bear-off tray — the other half of the same well as [offWhite].
  offBlack(-1),

  /// The strip of felt the point triangles do not reach, across both halves
  /// and the bar.
  ///
  /// The dice reader searches the whole playing surface — real dice settle
  /// wherever they stop — but inside this strip it judges what it sees
  /// against the strip's own two measured surfaces rather than the owning
  /// region's, which is the narrower and sharper test; `DiceReader` says why
  /// with numbers.
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

/// How wide this board's trays, bar and columns are, as fractions of its width.
///
/// **The three numbers a board differs from another board by.** Everything else
/// the atlas knows — which quadrant a point is in, how far a triangle reaches,
/// where the midline is — is the same on every backgammon board ever made.
/// These three are not, and the difference is not cosmetic: they decide where
/// every column is, and an error in them accumulates over six columns toward
/// the board's outer edges.
///
/// ## Why this is an input
///
/// [RoiAtlas] used to hard-code one set of these, with a note saying the corpus
/// gate would answer whether boards are close enough. The answer arrived with
/// the first real board: a folding case with **no bear-off wells at all** and a
/// hinge strip for a bar. Borne-off checkers leave that board entirely; hit
/// checkers sit on the hinge. Setting [trayWidth] to zero there moves the
/// outermost point by most of a column, and a checker only clears its column's
/// boundary by about a twentieth of one — so a single set of proportions is not
/// a small error on such a board, it is a total miss.
///
/// ## Where the numbers come from
///
/// **Measured by a person, off the calibration frame, and written into the
/// session.** There is no auto-detection here and none is planned for the MVP:
/// finding the tray seams in a photograph is a harder problem than the one
/// calibration already solves with four dragged corner handles, and the corpus
/// carries the measurement in its sidecars rather than guessing at it. The one
/// thing this type does is make sure the measurement reaches every part of the
/// pipeline, because it is the atlas that everything asks.
///
/// ## The trayless case, in the API
///
/// [trayWidth] may be exactly zero, and then the board **has no
/// [RoiId.offWhite] or [RoiId.offBlack]** — not empty ones, none. See
/// [RoiAtlas.hasTrays] for what that means for callers.
class BoardProportions {
  /// One bear-off tray column at each end of the board. Zero on a board that
  /// has no wells, and then the board has no tray regions at all.
  final double trayWidth;

  /// The bar down the middle — a well on a folding-case board, a full column
  /// on a cased one. Never zero: a board with no bar is not a backgammon
  /// board, and the bar is where hit checkers sit however thin it is.
  final double barWidth;

  const BoardProportions({
    required this.trayWidth,
    required this.barWidth,
  })  : assert(trayWidth >= 0, 'a tray cannot be narrower than nothing'),
        assert(barWidth > 0, 'every board has a bar, however thin'),
        assert(
          2 * trayWidth + barWidth < 1,
          'the trays and the bar leave nothing for the twelve columns',
        );

  /// The proportions the atlas assumed before boards were measured: an eighth
  /// of the width in wells at each end and the same again down the middle.
  /// Every caller that does not say otherwise gets these, so nothing that
  /// worked before this type existed moves by a hair.
  static const BoardProportions standard =
      BoardProportions(trayWidth: 0.08, barWidth: 0.08);

  /// Twelve point columns share what the trays and the bar leave.
  double get columnWidth => (1.0 - 2 * trayWidth - barWidth) / 12.0;

  /// Whether this board has bear-off wells on it at all.
  bool get hasTrays => trayWidth > 0;

  double get leftTrayEnd => trayWidth;
  double get leftHalfStart => trayWidth;
  double get leftHalfEnd => leftHalfStart + 6 * columnWidth;
  double get barStart => leftHalfEnd;
  double get barEnd => barStart + barWidth;
  double get rightHalfStart => barEnd;
  double get rightHalfEnd => rightHalfStart + 6 * columnWidth;
  double get rightTrayStart => rightHalfEnd;

  /// The two numbers, for a corpus sidecar. Absent in a sidecar means
  /// [standard], so a corpus shot on an ordinary board carries nothing extra.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'trayWidth': trayWidth,
        'barWidth': barWidth,
      };

  /// The reverse, with the checks the constructor's assertions cannot make in
  /// a release build — a sidecar is data from outside the program, and being
  /// told which number is wrong beats a homography full of infinities.
  factory BoardProportions.fromJson(Map<String, dynamic> json) {
    final tray = (json['trayWidth'] as num).toDouble();
    final bar = (json['barWidth'] as num).toDouble();
    if (tray < 0 || !tray.isFinite) {
      throw FormatException('trayWidth must be zero or more, got $tray');
    }
    if (bar <= 0 || !bar.isFinite) {
      throw FormatException('barWidth must be more than zero, got $bar');
    }
    if (2 * tray + bar >= 1) {
      throw FormatException('trayWidth $tray twice over plus barWidth $bar '
          'leaves nothing for the twelve columns');
    }
    return BoardProportions(trayWidth: tray, barWidth: bar);
  }

  @override
  bool operator ==(Object other) =>
      other is BoardProportions &&
      other.trayWidth == trayWidth &&
      other.barWidth == barWidth;

  @override
  int get hashCode => Object.hash(trayWidth, barWidth);

  @override
  String toString() => hasTrays
      ? 'BoardProportions(tray $trayWidth, bar $barWidth)'
      : 'BoardProportions(no trays, bar $barWidth)';
}

/// Where everything is on the board, in board space.
///
/// ## The coordinate system
///
/// **The board is the unit rectangle `(0,0)`–`(1,1)`.** `x` runs left to
/// right and `y` from the board's far edge (0) to its near edge (1), "near"
/// meaning the edge closest to the camera. A [BoardGeometry] is what carries
/// this rectangle into a frame's pixels — one homography for a flat board, two
/// leaves and a hinge for a folding case — and nothing downstream of
/// calibration works in pixels.
///
/// The rectangle is the **whole playing surface including both bear-off
/// trays** — the four corners the user drags onto the board during
/// calibration are the outer corners of the felt-and-wood field, not the
/// corners of the twelve-column area. Left to right it is: tray, six point
/// columns, bar, six point columns, tray, at the widths this atlas's
/// [proportions] give — and on a board with no wells the two trays are simply
/// not there. The synthetic renderer's `BoardLayout` reads the same
/// [BoardProportions] and the atlas tests assert the two agree, for a trayless
/// board as well as a standard one.
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
/// ## Proportions are a calibration input
///
/// The three fractions that decide where the columns are — the tray width, the
/// bar width and the column width they leave — are **not** written down here.
/// They are [BoardProportions], carried by each atlas and measured per session;
/// see that class for why, and for the board that settled the question. Nothing
/// downstream should hard-code them — ask the atlas, which is the one place a
/// session's board is described.
///
/// ## A board may have no trays
///
/// On a folding-case board there is nowhere on the felt for borne-off checkers
/// to go: they leave the board. An atlas built from proportions with a
/// [BoardProportions.trayWidth] of zero therefore **does not have**
/// [RoiId.offWhite] or [RoiId.offBlack]. Not empty regions — absent ones, which
/// is the honest model and the one that cannot be misread:
///
/// * [hasTrays] says whether this board has them;
/// * [has] says whether it has any given region;
/// * [regions] is what to iterate — it yields exactly what this board has, in
///   [RoiId.values] order, and is what every consumer in this package walks
///   instead of the enum;
/// * [roi] **throws** [StateError] for a region the board does not have, rather
///   than handing back a sliver of nothing that would read as empty felt.
class RoiAtlas {
  /// How far a point's triangle reaches from its own edge, as a fraction of
  /// the board's height. What the two rows of tips leave in the middle is the
  /// dice zone. Not a proportion input: this one is the same on every board to
  /// well inside a checker, and the dice band is defined by it rather than
  /// measuring it.
  static const double pointLength = 0.42;

  /// The line no stack crosses, and the seam between the two halves.
  static const double midline = 0.5;

  final BoardOrientation orientation;

  /// This board's widths. Every region below is derived from them.
  final BoardProportions proportions;

  final Map<RoiId, BoardQuad> _regions;

  const RoiAtlas._(this.orientation, this.proportions, this._regions);

  /// The atlas for a seating and a board.
  ///
  /// The two standard-board atlases are built once and shared, so the common
  /// case costs nothing; anything else is built on the spot. All of them are
  /// immutable.
  factory RoiAtlas.forOrientation(
    BoardOrientation orientation, {
    BoardProportions proportions = BoardProportions.standard,
  }) {
    if (proportions == BoardProportions.standard) {
      return orientation == BoardOrientation.whiteHomeNear ? _near : _far;
    }
    return _build(orientation, proportions);
  }

  static final RoiAtlas _near =
      _build(BoardOrientation.whiteHomeNear, BoardProportions.standard);

  static final RoiAtlas _far =
      _build(BoardOrientation.whiteHomeFar, BoardProportions.standard);

  static RoiAtlas _build(
    BoardOrientation orientation,
    BoardProportions proportions,
  ) {
    final near = _buildNear(proportions);
    return RoiAtlas._(
      orientation,
      proportions,
      orientation == BoardOrientation.whiteHomeNear
          ? near
          : Map<RoiId, BoardQuad>.unmodifiable(<RoiId, BoardQuad>{
              for (final entry in near.entries)
                entry.key: _halfTurn(entry.value),
            }),
    );
  }

  /// Whether this board has bear-off wells, and therefore
  /// [RoiId.offWhite] and [RoiId.offBlack], at all.
  bool get hasTrays => proportions.hasTrays;

  /// Whether this board has [id].
  bool has(RoiId id) => _regions.containsKey(id);

  /// Every region this board has, in [RoiId.values] order.
  ///
  /// What to iterate. Walking [RoiId.values] instead would ask a trayless
  /// board for regions it does not have.
  Iterable<RoiId> get regions => _regions.keys;

  /// The quadrilateral [id] covers, in board space.
  ///
  /// Throws [StateError] when this board does not have [id] — see the class
  /// doc. Always an axis-aligned rectangle today; it is typed as a [BoardQuad]
  /// because callers immediately push it through
  /// [BoardGeometry.imagePointOf], where it stops being one — and on a board
  /// that folds it stops being a quadrilateral at all, since a region crossing
  /// the hinge has its corners on different planes.
  BoardQuad roi(RoiId id) {
    final quad = _regions[id];
    if (quad == null) {
      throw StateError(
        'this board has no ${id.name}: its proportions give it no bear-off '
        'wells, so borne-off checkers leave the board altogether. Ask '
        'hasTrays, or iterate regions, before asking for one.',
      );
    }
    return quad;
  }

  static Map<RoiId, BoardQuad> _buildNear(BoardProportions p) =>
      Map<RoiId, BoardQuad>.unmodifiable(<RoiId, BoardQuad>{
        for (var i = 0; i < 24; i++) RoiId.point(i): _pointRegion(p, i),
        RoiId.bar: _rect(p.barStart, 0, p.barEnd, 1),
        if (p.hasTrays) ...<RoiId, BoardQuad>{
          RoiId.offWhite: _rect(p.rightTrayStart, midline, 1, 1),
          RoiId.offBlack: _rect(p.rightTrayStart, 0, 1, midline),
        },
        RoiId.diceZone: _rect(
          p.leftHalfStart,
          pointLength,
          p.rightHalfEnd,
          1 - pointLength,
        ),
      });

  static BoardQuad _pointRegion(BoardProportions p, int index) {
    final (left, right) = _pointSpan(p, index);
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
  static (double, double) _pointSpan(BoardProportions p, int index) {
    final double left;
    if (index <= 5) {
      left = p.rightHalfEnd - (index + 1) * p.columnWidth;
    } else if (index <= 11) {
      left = p.leftHalfEnd - (index - 5) * p.columnWidth;
    } else if (index <= 17) {
      left = p.leftHalfStart + (index - 12) * p.columnWidth;
    } else {
      left = p.rightHalfStart + (index - 18) * p.columnWidth;
    }
    return (left, left + p.columnWidth);
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
  String toString() => 'RoiAtlas(${orientation.name}, $proportions)';
}
