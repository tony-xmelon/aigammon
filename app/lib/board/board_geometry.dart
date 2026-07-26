import 'dart:math' as math;
import 'dart:ui';

import 'package:backgammon_core/backgammon_core.dart';

/// Maps board locations (points, bar, bear-off trays, individual checkers) to
/// screen rectangles / offsets and back. Pure geometry: no Flutter widgets,
/// no painting — only `dart:ui` primitives plus [Player] / [CheckerMove] from
/// the core. All coordinates are in the local space of the board widget with
/// origin (0,0) at the top-left corner and extent [size].
///
/// ## The frame rail and the playing FIELD
///
/// The board is painted with a wooden frame rail around its outer edge
/// ([frameThickness], 1.2% of the shorter side). Everything the geometry lays
/// out lives in the [fieldRect] — the board rect deflated by the rail PLUS one
/// rail width of felt margin — so the outermost triangles, checkers, highlight
/// overlays and tray strips all sit visibly INSIDE the rail rather than
/// underneath it. (Before this inset the 12 columns were spread over the full
/// widget width while the rail was painted on top, so the outermost triangles
/// and their checker rims were clipped by the frame.)
///
/// [locationAt] still accepts a tap anywhere on the widget: a tap that lands on
/// the rail (or the felt margin) is clamped into the field, so the inset costs
/// no touch target at the edges.
///
/// ## Layout (canonical `whiteAtBottom == true`)
///
/// Vertically the FIELD splits into three horizontal bands: a TOP bear-off
/// tray strip (7% of the field height), the BOARD band (86%), and a BOTTOM
/// bear-off tray strip (7%). The board band is full-field-width and symmetric:
/// a central bar strip (8% width, centred) with six point columns on each side
/// that together fill the remaining 92% — there is NO right-edge tray column,
/// so the leftmost column touches the field's left edge and the rightmost its
/// right edge. Within the board band the top and bottom triangle rows take up
/// to 44% each; the middle gap is empty (dice / cube / resting bar).
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
/// * the triangle length is capped at `_maxPointRadii` checker radii (nine
///   checker diameters — four more than the five-checker stack a point holds
///   at full spacing). The vertical slack a tall board leaves over goes to the
///   empty middle band, where [diceSide] grows to use it.
///
/// Only tall boards (aspect below ~0.61 width : height) reach the cap; on a
/// landscape-ish board every metric is what it was before the board became
/// responsive. That threshold is a consequence of the cap's own size — see
/// [_maxPointRadii], which derives it.
///
/// ```
///  (everything below is inside fieldRect — the rail is outside it)
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

  // --- Layout fractions (of the FIELD's width / height). ---------------------
  static const double _trayFraction = 0.07; // top/bottom bear-off strip height
  static const double _barFraction = 0.08; // central bar strip width
  static const double _pointHeightFraction = 0.44; // MAX triangle band, of band

  /// Thickness of the painted frame rail, as a fraction of the SHORTER side of
  /// the board. The painter strokes the rail with exactly this width, so the
  /// rail band covers `[0, frameThickness]` inward from each edge.
  static const double _frameFraction = 0.012;

  /// Felt margin left between the rail's inner edge and the playing field, in
  /// rail widths. One rail width reads as a deliberate breathing line: the
  /// outermost triangles clearly stop short of the frame instead of running
  /// under it.
  static const double _fieldMarginRails = 1.0;

  /// Checker radius as a fraction of a point column's width: the disc spans 92%
  /// of its column, leaving a hairline between neighbouring stacks. This is the
  /// bound that decides the checker size on a portrait (tall) board, where the
  /// 12 fixed columns — not the height — are the scarce dimension.
  static const double _checkerColumnFill = 0.46;

  /// Longest a triangle may be, in checker radii. A point holds five checkers
  /// at full spacing over exactly 10 radii; 18 leaves four checkers of headroom
  /// above a full stack and stops the tallest board from drawing endless
  /// spikes. The surplus goes to the middle band, where the dice grow into it.
  ///
  /// Binds only below an aspect of ~0.61 (width : height). That figure follows
  /// from the cap: on a tall board the columns set the checker size, so a
  /// triangle wants `colWidth · 0.46 · 18` of height and may have
  /// `bandHeight · 0.44`; substituting `colWidth = fieldW · 0.92 / 12` and
  /// `bandHeight = fieldH · 0.86` makes the cap bind at a FIELD aspect of
  /// ~0.596, i.e. a board aspect of ~0.61 once the frame inset is added back.
  ///
  /// Sized against [BoardView.minAspect]: at the tallest board that clamp allows
  /// (0.55), 18-radii triangles leave the empty middle band at about a fifth of
  /// the triangle band — ~21% of it, ~18% of the full field height — close to a
  /// real board's proportions. A smaller cap would push more of that surplus
  /// into the middle, which is the "bed of spikes over a wide empty gap" look
  /// this metric exists to avoid.
  static const double _maxPointRadii = 18.0;

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

  /// Thickness of the frame rail painted around the board's outer edge. The
  /// painter reads this so the rail and the field inset can never drift apart.
  double get frameThickness => math.min(_w, _h) * _frameFraction;

  /// How far the playing field is inset from the widget's edge: the rail plus
  /// [_fieldMarginRails] rail widths of visible felt.
  double get _fieldInset => frameThickness * (1 + _fieldMarginRails);

  /// The PLAYING FIELD: the board rect minus the frame rail and its felt
  /// margin. Every point column, the bar, both tray strips and the dice are
  /// laid out inside this rect, so nothing is drawn under the rail.
  Rect get fieldRect => Rect.fromLTRB(
        _fieldInset,
        _fieldInset,
        _w - _fieldInset,
        _h - _fieldInset,
      );

  double get _fLeft => _fieldInset;
  double get _fTop => _fieldInset;
  double get _fRight => _w - _fieldInset;
  double get _fBottom => _h - _fieldInset;
  double get _fw => _fRight - _fLeft;
  double get _fh => _fBottom - _fTop;

  // The board band (between the two tray strips), inside the field.
  double get _trayHeight => _fh * _trayFraction;
  double get _bandTop => _fTop + _trayHeight;
  double get _bandBottom => _fBottom - _trayHeight;
  double get _bandHeight => _bandBottom - _bandTop;

  // Full-FIELD-width, symmetric horizontal layout: 12 columns + a centred bar
  // fill the whole field width (no side tray).
  double get _colWidth => (_fw * (1 - _barFraction)) / 12;
  double get _halfWidth => _colWidth * 6;
  double get _barLeft => _fLeft + _halfWidth;
  double get _barRight => _barLeft + _fw * _barFraction;

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
        (_fRight - _barRight) * _diceHalfFill,
      ));

  /// Bounding rectangle of [player]'s dice PAIR (the two dice plus the gap
  /// between them), centred in the empty middle band.
  ///
  /// ## Anchored per PLAYER, never per mover
  ///
  /// Each pair has ONE home: canonically White's sits in the RIGHT half (between
  /// the bar and the right edge, where dice have always sat) and Black's in the
  /// mirrored LEFT-half position. Because the whole canonical layout is rotated
  /// with the board ([_orient]), the rule a player actually sees is "the pair
  /// belonging to the side at the BOTTOM of the screen is on the right" — stable
  /// for the whole game.
  ///
  /// It used to depend on whose turn it was (the mover's pair took the right
  /// half, the waiter's the left), which meant both pairs SWAPPED sides on every
  /// turn change. With the dice now presented over a beat whose emphasis follows
  /// the presentation rather than `state.turn` (see
  /// [BoardPainter.activeDiceSide]), a turn-driven swap would have moved a pair
  /// mid-tumble — the dice would jump across the board while they rolled. Fixed
  /// homes make the emphasis the ONLY thing that changes, which is both calmer to
  /// watch and much easier to reason about.
  Rect diceRect(Player player) {
    final side = diceSide;
    final gap = side * 0.5;
    final pairWidth = side * 2 + gap;
    // Canonical: White to the right of the bar, Black mirrored to the left
    // (mirrored about the FIELD's centre line, which is also the board's).
    final rightCx = (_barRight + _fRight) / 2;
    final cx =
        player == Player.white ? rightCx : _fLeft + _fRight - rightCx;
    final cy = (_bandTop + _bandBottom) / 2;
    final canonical = Rect.fromCenter(
        center: Offset(cx, cy), width: pairWidth, height: side);
    return _orient(canonical);
  }

  /// Minimum side of a dice TOUCH target, in logical pixels — the platform
  /// accessibility floor. A phone's dice pair is smaller than this, so
  /// [diceTapRect] pads it out.
  static const double minDiceTapTarget = 44;

  /// The generous TAP region for [player]'s dice pair: [diceRect] padded by a
  /// quarter of a die on every side, and at least [minDiceTapTarget] across in
  /// both axes. Used by the pre-roll "tap the dice to roll" affordance, where a
  /// near miss must still roll.
  Rect diceTapRect(Player player) {
    final r = diceRect(player);
    final pad = diceSide * 0.25;
    final dx = math.max(pad, (minDiceTapTarget - r.width) / 2);
    final dy = math.max(pad, (minDiceTapTarget - r.height) / 2);
    return Rect.fromLTRB(r.left - dx, r.top - dy, r.right + dx, r.bottom + dy);
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
    final raw = whiteAtBottom ? p : Offset(_w - p.dx, _h - p.dy);
    if (raw.dx < 0 || raw.dx > _w || raw.dy < 0 || raw.dy > _h) return null;
    // A tap on the frame rail (or its felt margin) is forgiven to the nearest
    // field cell, so insetting the playing field costs no touch target.
    final q = Offset(
      raw.dx.clamp(_fLeft, _fRight),
      raw.dy.clamp(_fTop, _fBottom),
    );

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
      col = ((q.dx - _fLeft) / _colWidth).floor().clamp(0, 5);
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
    final top = isBottomStrip ? _bandBottom : _fTop;
    return Rect.fromLTWH(_fLeft, top, _fw, _trayHeight);
  }

  /// Left edge x of visual column [col] (0..11).
  double _colLeft(int col) => col < 6
      ? _fLeft + col * _colWidth
      : _barRight + (col - 6) * _colWidth;

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
