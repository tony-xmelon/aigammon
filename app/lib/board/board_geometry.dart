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
/// Horizontally the width splits into: a left half of 6 point columns, a
/// central bar strip, a right half of 6 point columns, and a bear-off tray
/// column pinned to the right edge. Vertically the top ~42% and bottom ~42%
/// hold the triangles; the middle band is empty (the resting bar / gap).
///
/// ```
/// col:  0  1  2  3  4  5 |bar| 6  7  8  9 10 11 | off
///     +---------------------------------------------+
/// top | 12 13 14 15 16 17| B | 18 19 20 21 22 23| K |   <- indices 12..23,
///     |  \  \  \  \  \  \ | A |  \  \  \  \  \  \ | b |      left->right
///     |   (triangles)     | R |   (triangles)    | l |
///     |                   |   |                  | a |
///     |   (triangles)     |   |   (triangles)    | c |   <- middle gap
///     |  /  /  /  /  /  / |   |  /  /  /  /  /  / | k |
/// bot | 11 10  9  8  7  6 | W | 5  4  3  2  1  0 | W |   <- indices 0..11,
///     +---------------------------------------------+      right->left
/// ```
///
/// * Bottom row holds indices 0..11 running **right to left**: index 0 is the
///   rightmost bottom slot (White's 1-point, home board), index 11 the far
///   left. Bar splits the row between indices 5 and 6.
/// * Top row holds indices 12..23 running **left to right**: index 12 far
///   left, index 23 rightmost. Bar splits the row between indices 17 and 18.
/// * The bar's lower half holds White's captured checkers, the upper half
///   Black's; the bear-off tray's lower half is White's, upper half Black's.
///
/// When [whiteAtBottom] is `false` the whole board is rotated 180° about its
/// centre, so a location at canonical `p` renders at `size - p`.
class BoardGeometry {
  BoardGeometry(this.size, {required this.whiteAtBottom})
      : assert(size.width > 0 && size.height > 0, 'size must be positive');

  final Size size;
  final bool whiteAtBottom;

  // --- Layout fractions (of width / height). ---------------------------------
  static const double _offFraction = 0.08; // bear-off tray column width
  static const double _barFraction = 0.08; // central bar strip width
  static const double _pointHeightFraction = 0.42; // each triangle band height

  double get _w => size.width;
  double get _h => size.height;

  double get _colWidth => (_w * (1 - _offFraction - _barFraction)) / 12;
  double get _halfWidth => _colWidth * 6;
  double get _barLeft => _halfWidth;
  double get _barRight => _halfWidth + _w * _barFraction;
  double get _offLeft => _barRight + _halfWidth;
  double get _offWidth => _w * _offFraction;
  double get _pointHeight => _h * _pointHeightFraction;

  /// Radius of a rendered checker. Bounded so five checkers stack within a
  /// point's height and a checker fits within its column.
  double get checkerRadius =>
      math.min(_pointHeight / 10, _colWidth * 0.46);

  double get _diameter => checkerRadius * 2;

  // --- Public API ------------------------------------------------------------

  /// Bounding rectangle of the triangle for point [index] (0..23).
  Rect pointRect(int index) {
    assert(index >= 0 && index < 24, 'point index must be 0..23');
    return _orient(_canonicalPointRect(index));
  }

  /// The [player]'s half of the central bar strip (where hit checkers rest).
  Rect barRect(Player player) => _orient(_canonicalBarRect(player));

  /// The [player]'s half of the bear-off tray column.
  Rect offRect(Player player) => _orient(_canonicalOffRect(player));

  /// Centre of the [stackPosition]-th checker (0-based, from the point's base)
  /// on point [pointIndex]. Stacks compress smoothly so any count stays within
  /// the point's rectangle.
  Offset checkerCenter(int pointIndex, int stackPosition) {
    assert(pointIndex >= 0 && pointIndex < 24, 'point index must be 0..23');
    final rect = _canonicalPointRect(pointIndex);
    final isBottom = pointIndex < 12;
    final travel = checkerRadius + _stackOffset(stackPosition, _pointHeight);
    final cx = rect.center.dx;
    final cy = isBottom ? _h - travel : travel;
    return _orientPoint(Offset(cx, cy));
  }

  /// Centre of the [stackPosition]-th checker resting on [player]'s bar half.
  Offset barCheckerCenter(Player player, int stackPosition) {
    final cx = (_barLeft + _barRight) / 2;
    final isBottomHalf = player == Player.white; // canonical
    final travel = checkerRadius + _stackOffset(stackPosition, _h / 2);
    final cy = isBottomHalf ? _h - travel : travel;
    return _orientPoint(Offset(cx, cy));
  }

  /// The board location under point [p]: a point index (0..23),
  /// [CheckerMove.bar] (24), [CheckerMove.off] (-1), or `null` for the empty
  /// middle band / outside the board.
  int? locationAt(Offset p) {
    // Rotate the query back into canonical space when board is flipped.
    final q = whiteAtBottom ? p : Offset(_w - p.dx, _h - p.dy);
    if (q.dx < 0 || q.dx > _w || q.dy < 0 || q.dy > _h) return null;

    if (q.dx >= _offLeft) return CheckerMove.off;
    if (q.dx >= _barLeft && q.dx < _barRight) return CheckerMove.bar;

    // A point column: resolve the row, then the visual column.
    final int? isBottomRow = q.dy >= _h - _pointHeight
        ? 1
        : (q.dy <= _pointHeight ? 0 : null);
    if (isBottomRow == null) return null; // middle gap

    final int col;
    if (q.dx < _barLeft) {
      col = (q.dx / _colWidth).floor().clamp(0, 5);
    } else if (q.dx >= _barRight && q.dx < _offLeft) {
      col = 6 + ((q.dx - _barRight) / _colWidth).floor().clamp(0, 5);
    } else {
      return null;
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
    final top = isBottom ? _h - _pointHeight : 0.0;
    return Rect.fromLTWH(left, top, _colWidth, _pointHeight);
  }

  Rect _canonicalBarRect(Player player) {
    final isBottomHalf = player == Player.white;
    final top = isBottomHalf ? _h / 2 : 0.0;
    return Rect.fromLTWH(_barLeft, top, _barRight - _barLeft, _h / 2);
  }

  Rect _canonicalOffRect(Player player) {
    final isBottomHalf = player == Player.white;
    final top = isBottomHalf ? _h / 2 : 0.0;
    return Rect.fromLTWH(_offLeft, top, _offWidth, _h / 2);
  }

  /// Left edge x of visual column [col] (0..11).
  double _colLeft(int col) =>
      col < 6 ? col * _colWidth : _barRight + (col - 6) * _colWidth;

  /// Distance a checker's centre sits from the stack base for [k] (0-based),
  /// within a usable [range] of travel. Grows by a full diameter for the
  /// first gap, then compresses geometrically so the offset is bounded by
  /// `range - diameter`, keeping every checker inside the rectangle.
  double _stackOffset(int k, double range) {
    final usable = range - _diameter;
    if (usable <= 0) return 0;
    final f = 1 - _diameter / usable; // in (0,1); offset(1) == diameter
    return usable * (1 - math.pow(f, k));
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
