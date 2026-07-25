import 'dart:math' as math;
import 'dart:ui';

import 'package:backgammon_core/backgammon_core.dart';

/// Maps board locations (points, bar, bear-off trays, individual checkers) to
/// screen rectangles / offsets and back. Pure geometry: no Flutter widgets,
/// no painting — only `dart:ui` primitives plus [Player] / [CheckerMove] from
/// the core. All coordinates are in the local space of the board widget with
/// origin (0,0) at the top-left corner and extent [size].
///
/// ## Layout (canonical `whiteAtBottom == true`)
///
/// Vertically the widget splits into three horizontal bands: a TOP bear-off
/// tray strip (7% height), the BOARD band (86% height), and a BOTTOM bear-off
/// tray strip (7% height). The board band is full-width and symmetric: a
/// central bar strip (8% width, centred) with six point columns on each side
/// that together fill the remaining 92% — there is NO right-edge tray column,
/// so the leftmost column touches x=0 and the rightmost touches x=width. Within
/// the board band the top and bottom triangle rows take up to 44% each; the
/// middle gap is empty (dice / cube / resting bar).
///
/// ## Aspect independence (portrait phones)
///
/// Nothing here assumes width > height. [BoardView] sizes the board to FILL its
/// slot within clamped aspect bounds, so on a phone the board is TALLER than it
/// is wide. Two metrics adapt so a tall board still reads as a backgammon board
/// rather than a bed of spikes:
///
/// * [checkerRadius] is the smaller of a column-width bound and a point-height
///   bound. On a tall board the columns bind (there are always 12 of them), so
///   the checkers are as wide as a column allows.
/// * the triangle length is capped at `_maxPointRadii` checker radii (eight
///   checker diameters — three more than the five-checker stack a point holds
///   at full spacing). The vertical slack a tall board leaves over goes to the
///   empty middle band, where [diceSide] grows to use it.
///
/// Only the tallest boards (aspect below ~0.67 width : height) reach the cap;
/// on a landscape-ish board every metric is what it was before the board
/// became responsive.
///
/// ```
///        col: 0  1  2  3  4  5 |bar| 6  7  8  9 10 11
///     +-------------------------------------------------+
/// tray|  black's borne-off checkers  ·····   count [N]  |  <- TOP strip (7%)
///     +-------------------------------------------------+
///  top| 12 13 14 15 16 17 | BAR | 18 19 20 21 22 23     |  <- indices 12..23,
///     |  \  \  \  \  \  \  |     |  \  \  \  \  \  \      |     left -> right
///     |   (triangles)      |     |   (triangles)         |
///     |                    |     |                       |  <- middle gap
///     |   (triangles)      |     |   (triangles)         |     (dice/cube)
///     |  /  /  /  /  /  /   |     |  /  /  /  /  /  /      |
///  bot| 11 10  9  8  7  6  |     | 5  4  3  2  1  0       |  <- indices 0..11,
///     +-------------------------------------------------+     right -> left
/// tray|  white's borne-off checkers  ·····   count [N]  |  <- BOTTOM strip (7%)
///     +-------------------------------------------------+
/// ```
///
/// * Bottom row holds indices 0..11 running **right to left**: index 0 is the
///   rightmost bottom slot (White's 1-point, home board), index 11 the far
///   left. The bar splits the row between indices 5 and 6.
/// * Top row holds indices 12..23 running **left to right**: index 12 far left,
///   index 23 rightmost. The bar splits the row between indices 17 and 18.
/// * The bar's lower half (canonically) holds White's captured checkers, the
///   upper half Black's. The BOTTOM tray strip is White's (their checkers bear
///   off toward them, at the bottom); the TOP tray strip is Black's.
///
/// When [whiteAtBottom] is `false` the whole board is rotated 180° about its
/// centre, so a location at canonical `p` renders at `size - p`. The strips
/// swap: White's tray moves to the top, Black's to the bottom.
class BoardGeometry {
  BoardGeometry(this.size, {required this.whiteAtBottom})
      : assert(size.width > 0 && size.height > 0, 'size must be positive');

  final Size size;
  final bool whiteAtBottom;

  // --- Layout fractions (of width / height). ---------------------------------
  static const double _trayFraction = 0.07; // top/bottom bear-off strip height
  static const double _barFraction = 0.08; // central bar strip width
  static const double _pointHeightFraction = 0.44; // MAX triangle band, of band

  /// Checker radius as a fraction of a point column's width: the disc spans 92%
  /// of its column, leaving a hairline between neighbouring stacks. This is the
  /// bound that decides the checker size on a portrait (tall) board, where the
  /// 12 fixed columns — not the height — are the scarce dimension.
  static const double _checkerColumnFill = 0.46;

  /// Longest a triangle may be, in checker radii. A point holds five checkers
  /// at full spacing over exactly 10 radii; 16 leaves three checkers of
  /// headroom above a full stack and stops the tallest board from drawing
  /// 18-radii spikes. Binds only below an aspect of ~0.67 (width : height);
  /// the surplus goes to the middle band, where the dice grow into it.
  static const double _maxPointRadii = 16.0;

  /// Fraction of the empty middle band a die may span, and fraction of a
  /// half-board's width the whole dice PAIR may span. Both cap [diceSide] so a
  /// grown die never touches a triangle or the bar.
  static const double _diceBandFill = 0.8;
  static const double _diceHalfFill = 0.36;

  /// Ceiling on [diceSide] in checker radii. Landscape boards are capped by the
  /// (narrow) middle band long before this; a tall board's roomier band lets the
  /// dice grow up to here, so they stay readable on a phone.
  static const double _maxDiceRadii = 3.2;

  double get _w => size.width;
  double get _h => size.height;

  // The board band (between the two tray strips).
  double get _trayHeight => _h * _trayFraction;
  double get _bandTop => _trayHeight;
  double get _bandBottom => _h - _trayHeight;
  double get _bandHeight => _bandBottom - _bandTop;

  // Full-width, symmetric horizontal layout: 12 columns + a centred bar fill
  // the whole width (no side tray).
  double get _colWidth => (_w * (1 - _barFraction)) / 12;
  double get _halfWidth => _colWidth * 6;
  double get _barLeft => _halfWidth;
  double get _barRight => _halfWidth + _w * _barFraction;

  /// The triangle band a point could occupy at most: 44% of the board band, as
  /// on every board before the layout became responsive.
  double get _maxPointHeight => _bandHeight * _pointHeightFraction;

  /// Length of a point triangle. Normally [_maxPointHeight]; on a TALL board
  /// (where the checker size is set by the column width) it is capped at
  /// [_maxPointRadii] radii so the triangles keep a board-like proportion and
  /// the surplus falls to the middle band instead. Never below 10 radii, so a
  /// five-stack always fits at full spacing.
  double get _pointHeight =>
      math.min(_maxPointHeight, checkerRadius * _maxPointRadii);

  /// Height of the EMPTY middle band between the two triangle rows — where the
  /// dice, the cube and the resting bar checkers live. Grows on a tall board.
  double get _middleBand => _bandHeight - 2 * _pointHeight;

  /// Radius of a rendered checker. Bounded so five checkers stack (at full 2r
  /// spacing) within a point's height, and a checker fits within its column.
  /// The column bound is what binds on a portrait board.
  double get checkerRadius =>
      math.min(_colWidth * _checkerColumnFill, _maxPointHeight / 10);

  double get _diameter => checkerRadius * 2;

  // --- Public API ------------------------------------------------------------

  /// Bounding rectangle of the triangle for point [index] (0..23).
  Rect pointRect(int index) {
    assert(index >= 0 && index < 24, 'point index must be 0..23');
    return _orient(_canonicalPointRect(index));
  }

  /// The [player]'s half of the central bar strip (where hit checkers rest).
  Rect barRect(Player player) => _orient(_canonicalBarRect(player));

  /// The [player]'s full-width bear-off tray strip (top or bottom). The
  /// local-bottom player's tray is the BOTTOM strip; the opponent's is the TOP.
  Rect offRect(Player player) => _orient(_canonicalOffRect(player));

  /// Side length of a rendered die. It fills the empty middle band (with a
  /// margin), so a tall board — whose band is roomier — gets visibly larger,
  /// more readable dice, bounded by [_maxDiceRadii] so they never dwarf the
  /// checkers. A landscape board's narrow band binds first, which reproduces
  /// the historical `checkerRadius * 2.2` to within a percent.
  double get diceSide => math.min(
      checkerRadius * _maxDiceRadii,
      math.min(
        _middleBand * _diceBandFill,
        (_w - _barRight) * _diceHalfFill,
      ));

  /// Bounding rectangle of [player]'s dice PAIR (the two dice plus the gap
  /// between them), centred in the empty middle band. The [mover]'s pair sits in
  /// the RIGHT half of the board (between the bar and the right edge, where dice
  /// have always sat); the waiting player's pair sits in the mirrored LEFT-half
  /// position. Orientation-aware: like the checkers, the canonical layout is
  /// rotated with the board on a hot-seat flip.
  Rect diceRect(Player player, {required Player mover}) {
    final side = diceSide;
    final gap = side * 0.5;
    final pairWidth = side * 2 + gap;
    // Canonical: mover to the right of the bar, waiter mirrored to the left.
    final rightCx = (_barRight + _w) / 2;
    final cx = player == mover ? rightCx : _w - rightCx;
    final cy = (_bandTop + _bandBottom) / 2;
    final canonical = Rect.fromCenter(
        center: Offset(cx, cy), width: pairWidth, height: side);
    return _orient(canonical);
  }

  /// Centre of the [stackPosition]-th checker (0-based, from the point's base)
  /// on point [pointIndex], in a stack of [stackCount] checkers. The first five
  /// sit at full 2r spacing (no overlap); larger stacks compress the whole
  /// stack uniformly so up to 15 stay within the point's height.
  Offset checkerCenter(int pointIndex, int stackPosition, int stackCount) {
    assert(pointIndex >= 0 && pointIndex < 24, 'point index must be 0..23');
    final rect = _canonicalPointRect(pointIndex);
    final isBottom = pointIndex < 12;
    final travel = _stackTravel(stackPosition, stackCount, _pointHeight);
    final cx = rect.center.dx;
    final cy = isBottom ? _bandBottom - travel : _bandTop + travel;
    return _orientPoint(Offset(cx, cy));
  }

  /// Centre of the [stackPosition]-th checker (in a stack of [stackCount])
  /// resting on [player]'s bar half.
  Offset barCheckerCenter(Player player, int stackPosition, int stackCount) {
    final cx = (_barLeft + _barRight) / 2;
    final isBottomHalf = player == Player.white; // canonical
    final half = _bandHeight / 2;
    final travel = _stackTravel(stackPosition, stackCount, half);
    final cy = isBottomHalf ? _bandBottom - travel : _bandTop + travel;
    return _orientPoint(Offset(cx, cy));
  }

  /// The board location under point [p]: a point index (0..23),
  /// [CheckerMove.bar] (24), [CheckerMove.off] (-1), or `null` for the empty
  /// middle gap / outside the board.
  int? locationAt(Offset p) {
    // Rotate the query back into canonical space when the board is flipped.
    final q = whiteAtBottom ? p : Offset(_w - p.dx, _h - p.dy);
    if (q.dx < 0 || q.dx > _w || q.dy < 0 || q.dy > _h) return null;

    // The tray strips (top and bottom) are the bear-off destinations. Bear-off
    // is unambiguous, so either strip maps to `off` regardless of player.
    if (q.dy < _bandTop || q.dy > _bandBottom) return CheckerMove.off;

    // The centred bar strip.
    if (q.dx >= _barLeft && q.dx < _barRight) return CheckerMove.bar;

    // A point column: resolve the row (top / bottom triangle band), then the
    // visual column.
    final topBandBottom = _bandTop + _pointHeight;
    final botBandTop = _bandBottom - _pointHeight;
    final int? isBottomRow =
        q.dy >= botBandTop ? 1 : (q.dy <= topBandBottom ? 0 : null);
    if (isBottomRow == null) return null; // middle gap

    final int col;
    if (q.dx < _barLeft) {
      col = (q.dx / _colWidth).floor().clamp(0, 5);
    } else {
      // q.dx >= _barRight (the bar case returned above).
      col = 6 + ((q.dx - _barRight) / _colWidth).floor().clamp(0, 5);
    }
    return isBottomRow == 1 ? 11 - col : col + 12;
  }

  // --- Canonical (whiteAtBottom) helpers -------------------------------------

  Rect _canonicalPointRect(int index) {
    final int col;
    final bool isBottom;
    if (index < 12) {
      col = 11 - index;
      isBottom = true;
    } else {
      col = index - 12;
      isBottom = false;
    }
    final left = _colLeft(col);
    final top = isBottom ? _bandBottom - _pointHeight : _bandTop;
    return Rect.fromLTWH(left, top, _colWidth, _pointHeight);
  }

  Rect _canonicalBarRect(Player player) {
    final isBottomHalf = player == Player.white;
    final mid = (_bandTop + _bandBottom) / 2;
    final top = isBottomHalf ? mid : _bandTop;
    return Rect.fromLTWH(_barLeft, top, _barRight - _barLeft, _bandHeight / 2);
  }

  Rect _canonicalOffRect(Player player) {
    // White (the canonical bottom player) bears off toward the BOTTOM strip;
    // Black toward the TOP strip.
    final isBottomStrip = player == Player.white;
    final top = isBottomStrip ? _bandBottom : 0.0;
    return Rect.fromLTWH(0, top, _w, _trayHeight);
  }

  /// Left edge x of visual column [col] (0..11).
  double _colLeft(int col) =>
      col < 6 ? col * _colWidth : _barRight + (col - 6) * _colWidth;

  /// Centre distance from the stack base for checker [s] (0-based) in a stack of
  /// [count], within a usable [range] of travel. Checkers sit at full diameter
  /// spacing until that would exceed the range, then the whole stack compresses
  /// uniformly: spacing = min(2r, (range - 2r) / (count - 1)), first centre at r.
  double _stackTravel(int s, int count, double range) {
    final r = checkerRadius;
    if (count <= 1) return r;
    final spacing = math.min(_diameter, (range - _diameter) / (count - 1));
    return r + spacing * s;
  }

  // --- Orientation -----------------------------------------------------------

  Rect _orient(Rect r) => whiteAtBottom
      ? r
      : Rect.fromCenter(
          center: Offset(_w - r.center.dx, _h - r.center.dy),
          width: r.width,
          height: r.height,
        );

  Offset _orientPoint(Offset o) =>
      whiteAtBottom ? o : Offset(_w - o.dx, _h - o.dy);
}
