import 'dart:math' as math;

import 'geometry_types.dart';
import 'homography.dart';
import 'roi_atlas.dart';

/// Where a board-space point was photographed — the one seam between board
/// space and pixels.
///
/// ## Why this exists rather than a bare [Homography]
///
/// Everything downstream of calibration addresses the board as the unit square
/// the ROI atlas describes: the colour model, the sampler, occupancy, the dice
/// reader, the start-position check and the fingerprint all say "board space"
/// and never "pixels". Exactly one arrow crosses that line — *which pixel is
/// this board-space point?* — and until now that arrow was a homography,
/// because a flat board photographed by a pinhole is a homography and nothing
/// else.
///
/// A folding-case board is not flat. Its two leaves hinge, and a case standing
/// on a table sits very slightly tented: measured on the first real board, a
/// single homography fitted to the four outer corners rectifies the two halves
/// to column pitches 13% apart, which is physically impossible for two
/// identical leaves and is the signature of the tent. Each leaf on its own
/// rectifies cleanly. So the map is not one projective map, it is one *per
/// plane* — and the seam has to be the map, not the matrix.
///
/// Everything on the other side of the seam is unchanged by that, which is the
/// whole point of putting the abstraction here: the atlas still describes one
/// unit square, the colour model still learns one board, occupancy still walks
/// one stack axis. Only this one call knows how many planes the board has.
abstract interface class BoardGeometry {
  /// Which pixel the board-space point [boardPoint] was photographed at.
  ///
  /// NEVER throws, including for points a projective map sends to infinity:
  /// the result is non-finite there, and callers on a hot sampling loop reject
  /// by range instead. See [Homography] for why.
  Pt imagePointOf(Pt boardPoint);
}

/// A board that is flat, which is every board but a folding case: one
/// [Homography] over the whole playing field.
///
/// Behaviourally this is the bare homography it wraps and nothing else — it
/// exists so that the flat board and the folding one are the same kind of
/// thing to every consumer.
class PlanarBoardGeometry implements BoardGeometry {
  /// The map this geometry is. Exposed because a caller that genuinely wants
  /// the inverse — image pixels back into board space — can only have one on a
  /// board with a single plane, and asking for it should not be indirect.
  final Homography homography;

  const PlanarBoardGeometry(this.homography);

  /// The geometry of a board whose playing field has [corners] in the frame.
  ///
  /// Throws [ArgumentError] on four corners that do not define a projective
  /// map, exactly as [Homography.fromQuad] does.
  factory PlanarBoardGeometry.fromQuad(BoardQuad corners) =>
      PlanarBoardGeometry(Homography.fromQuad(corners));

  @override
  Pt imagePointOf(Pt boardPoint) => homography.mapToImage(boardPoint);

  @override
  String toString() => 'PlanarBoardGeometry($homography)';
}

/// The eight points a folding-case board is calibrated from.
///
/// Four outer corners, exactly as an ordinary board's [BoardQuad] — plus the
/// four places the hinge strip meets the board's far and near edges. On a
/// folding case those four are visible seams a person can put a fingertip on,
/// which is what makes eight taps a reasonable thing to ask for; the strip
/// between them is the raised spine, and it is the bar.
///
/// ## What is derived from them
///
/// **The board's proportions, rather than being measured a second time.** A
/// folding case has no bear-off wells — borne-off checkers leave it — so
/// [BoardProportions.trayWidth] is zero, and the bar's width is the width of
/// the strip these points already delimit. There is nothing left for a person
/// to measure and nothing to sweep.
///
/// ## The convention: two equal leaves flanking the bar
///
/// In board space the strip is centred: the left leaf is `[0, leftLeafEnd)`,
/// the strip `[leftLeafEnd, rightLeafStart]`, the right leaf
/// `(rightLeafStart, 1]`, with `leftLeafEnd == 1 - rightLeafStart`. That is
/// what a folding case is — one case, folded in half — and it has a
/// consequence worth stating, because it is why the derived bar width does not
/// have to be exact: **each leaf's six point columns are exact sixths of that
/// leaf, whatever the strip's width comes out as.** A tenth of a percent of
/// error in the strip moves no column at all; it only names the strip, and the
/// strip routes to its own plane in one piece either way.
///
/// The width itself is the mean of what the far edge and the near edge say,
/// each measured as a signed fraction along its own edge. The two disagree
/// under perspective — on the first real board, 6.7% at the far edge and 7.5%
/// at the near one — and averaging them is honest precisely because of the
/// paragraph above.
class FoldingCorners {
  /// The playing field's outer corners, clockwise from the top left as the
  /// frame shows them — the same four an ordinary board is calibrated from.
  final Pt topLeft;
  final Pt topRight;
  final Pt bottomRight;
  final Pt bottomLeft;

  /// Where the hinge strip meets the board's far edge: the left leaf ends at
  /// [hingeFarLeft] and the right leaf begins at [hingeFarRight].
  final Pt hingeFarLeft;
  final Pt hingeFarRight;

  /// The same two seams on the board's near edge.
  final Pt hingeNearLeft;
  final Pt hingeNearRight;

  const FoldingCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
    required this.hingeFarLeft,
    required this.hingeFarRight,
    required this.hingeNearLeft,
    required this.hingeNearRight,
  });

  /// The four outer corners alone.
  BoardQuad get outer => BoardQuad(
        topLeft: topLeft,
        topRight: topRight,
        bottomRight: bottomRight,
        bottomLeft: bottomLeft,
      );

  /// The left leaf's own quad: outer corner, hinge seam, hinge seam, outer
  /// corner — clockwise from its top left, as [BoardQuad] promises.
  BoardQuad get leftLeaf => BoardQuad(
        topLeft: topLeft,
        topRight: hingeFarLeft,
        bottomRight: hingeNearLeft,
        bottomLeft: bottomLeft,
      );

  /// The raised strip between the leaves.
  ///
  /// **An approximation, and a deliberate one.** The spine of a folding case
  /// is a ridge, not a plane: it has a crown across its width. Modelling it as
  /// its own quad puts a plane through its four visible corners, which is
  /// wrong by whatever the crown rises in the middle — a millimetre or two on
  /// a strip a couple of centimetres wide. That is enough to matter for fine
  /// geometry and nowhere near enough to matter for what is actually asked of
  /// this region: a checker on the bar is read for presence, colour and count,
  /// by walking a profile outward from the middle, and a millimetre of crown
  /// moves no run's end by a fraction of a checker. What the strip's own plane
  /// buys — and what treating it as part of either leaf does not — is that the
  /// strip lands on the strip at all, instead of half a strip away.
  BoardQuad get hinge => BoardQuad(
        topLeft: hingeFarLeft,
        topRight: hingeFarRight,
        bottomRight: hingeNearRight,
        bottomLeft: hingeNearLeft,
      );

  /// The right leaf's own quad.
  BoardQuad get rightLeaf => BoardQuad(
        topLeft: hingeFarRight,
        topRight: topRight,
        bottomRight: bottomRight,
        bottomLeft: hingeNearRight,
      );

  /// Board space's x where the left leaf stops and the hinge strip starts.
  double get leftLeafEnd => (1 - barWidth) / 2;

  /// And where the strip stops and the right leaf starts.
  double get rightLeafStart => (1 + barWidth) / 2;

  /// The hinge strip's width as a fraction of the playing field — see the
  /// class doc for how it is derived and why its exact value moves no column.
  double get barWidth {
    final far = _fractionAlong(topLeft, topRight, hingeFarLeft, hingeFarRight,
        'far');
    final near = _fractionAlong(
        bottomLeft, bottomRight, hingeNearLeft, hingeNearRight, 'near');
    final width = (far + near) / 2;
    if (width <= 0 || width >= 1) {
      throw ArgumentError.value(
        width,
        'corners',
        'the hinge strip works out $width of the board wide, which is not a '
            'strip. Check that the four hinge points are in the order the '
            'names say: left seam then right seam, on each edge',
      );
    }
    return width;
  }

  /// This board, as the atlas describes boards: no wells, and a bar the width
  /// of the hinge strip.
  BoardProportions get proportions =>
      BoardProportions(trayWidth: 0, barWidth: barWidth);

  /// How much of the edge `a`–`b` the segment `p`–`q` covers, signed, with the
  /// checks that a value type built from eight taps on a screen needs.
  static double _fractionAlong(Pt a, Pt b, Pt p, Pt q, String edge) {
    for (final point in <Pt>[a, b, p, q]) {
      if (!point.x.isFinite || !point.y.isFinite) {
        throw ArgumentError.value(
            point, 'corners', 'the $edge edge has a point that is not finite');
      }
    }
    final dx = b.x - a.x, dy = b.y - a.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) {
      throw ArgumentError.value(a, 'corners',
          "the board's $edge edge has no length: its two corners coincide");
    }
    double along(Pt point) =>
        ((point.x - a.x) * dx + (point.y - a.y) * dy) / (length * length);
    final start = along(p), end = along(q);
    if (start < 0 || end > 1 || end <= start) {
      throw ArgumentError.value(
        <Pt>[p, q],
        'corners',
        'the hinge seams on the $edge edge sit at $start and $end along it, '
            'which is not a strip between the two corners. They have to be in '
            "order — the left seam, then the right — and on the board's edge",
      );
    }
    return end - start;
  }

  @override
  String toString() => 'FoldingCorners(outer $outer, hinge far $hingeFarLeft '
      '$hingeFarRight, near $hingeNearLeft $hingeNearRight)';
}

/// A folding-case board: two leaf planes and the raised strip between them.
///
/// ## Why one homography is not enough, measured
///
/// A case standing open on a table is very slightly **tented** — the spine in
/// the middle stands proud of the two leaves. On the first real board this was
/// not a subtlety. Fit one homography through the four outer corners, rectify,
/// and the two halves come out with column pitches 102.5 px and 90 px per
/// column at a 1200 px width: 13% apart, which is impossible for two identical
/// leaves and is the tent's signature. Mid-board columns land up to half a
/// column out, the colour model's checker patches sample bare wood, and
/// separability collapses. A sweep of 21 (tray width, bar width) pairs failed
/// every one — because the error is not a width. Rectify each leaf under its
/// OWN quad and the pitch is uniform to within 5%, stacks sit centred in their
/// columns, and the triangles run flush to the leaf edges.
///
/// ## How a point finds its plane
///
/// Board space is unchanged: still the unit square the ROI atlas describes,
/// still one atlas, still one colour model, still one stack axis per region.
/// All that changes is this class's answer to *which pixel is that*:
///
/// * x below [leftLeafEnd] is on the left leaf. Its leaf-local coordinate is
///   `x / leftLeafEnd` — the leaf rescaled to its own unit square — and the
///   leaf's own homography takes it to the picture.
/// * x above [rightLeafStart] is on the right leaf, rescaled the same way.
/// * everything between, which is exactly the atlas's bar band, is on the
///   hinge strip and goes through the strip's own map.
///
/// The three agree at the seams by construction — the leaf quads and the strip
/// quad share their edges — so a lattice walking across board space (the dice
/// band's, most importantly, which spans both leaves and the strip) sees a
/// continuous picture with no step at the joins.
///
/// [Homography] itself is untouched by any of this: this class composes three
/// of them.
class FoldingBoardGeometry implements BoardGeometry {
  /// The eight points this was built from, kept so a caller can ask what was
  /// tapped without the geometry having to answer in matrices.
  final FoldingCorners corners;

  /// This board as the atlas describes boards, derived from [corners]: no
  /// bear-off wells, and a bar the width of the hinge strip.
  ///
  /// Whoever builds an atlas for a folding calibration must use THIS, or the
  /// atlas's bar band and the geometry's hinge band would be different
  /// rectangles and the strip would be read half off the strip.
  final BoardProportions proportions;

  /// The two board-space x at which the routing changes plane. Equal to
  /// [BoardProportions.barStart] and [BoardProportions.barEnd] of
  /// [proportions], which is the invariant that keeps the atlas and the
  /// geometry describing the same board.
  final double leftLeafEnd;
  final double rightLeafStart;

  final Homography _left;
  final Homography _hinge;
  final Homography _right;

  /// Reciprocals of the three bands' board-space widths, so the hot path
  /// multiplies instead of dividing.
  final double _leftScale;
  final double _hingeScale;
  final double _rightScale;

  /// Builds the geometry of the board whose eight points are [corners].
  ///
  /// Throws [ArgumentError] when those eight points are not a folding board —
  /// a hinge seam off the edge it belongs to, the two seams in the wrong
  /// order, a leaf whose four corners do not define a projective map, a
  /// coordinate that is not finite. Data from eight taps on a screen is data
  /// from outside the program, and being told which point is wrong beats three
  /// homographies full of infinities.
  factory FoldingBoardGeometry(FoldingCorners corners) {
    final proportions = corners.proportions;
    final leftLeafEnd = proportions.barStart;
    final rightLeafStart = proportions.barEnd;
    return FoldingBoardGeometry._(
      corners,
      proportions,
      leftLeafEnd,
      rightLeafStart,
      Homography.fromQuad(corners.leftLeaf),
      Homography.fromQuad(corners.hinge),
      Homography.fromQuad(corners.rightLeaf),
      1 / leftLeafEnd,
      1 / (rightLeafStart - leftLeafEnd),
      1 / (1 - rightLeafStart),
    );
  }

  const FoldingBoardGeometry._(
    this.corners,
    this.proportions,
    this.leftLeafEnd,
    this.rightLeafStart,
    this._left,
    this._hinge,
    this._right,
    this._leftScale,
    this._hingeScale,
    this._rightScale,
  );

  @override
  Pt imagePointOf(Pt boardPoint) {
    final x = boardPoint.x;
    // Ordered so that the two leaves — which are almost all of the board, and
    // all of the sampling — are decided in one comparison each.
    if (x < leftLeafEnd) {
      return _left.mapToImage(Pt(x * _leftScale, boardPoint.y));
    }
    if (x > rightLeafStart) {
      return _right.mapToImage(
        Pt((x - rightLeafStart) * _rightScale, boardPoint.y),
      );
    }
    return _hinge.mapToImage(
      Pt((x - leftLeafEnd) * _hingeScale, boardPoint.y),
    );
  }

  @override
  String toString() => 'FoldingBoardGeometry(leaves to '
      '${leftLeafEnd.toStringAsFixed(4)} and from '
      '${rightLeafStart.toStringAsFixed(4)})';
}
