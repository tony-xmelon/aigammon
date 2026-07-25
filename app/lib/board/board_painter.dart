import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/widgets.dart';

import 'board_geometry.dart';
import 'board_theme.dart';

/// Renders a [BoardState] (plus optional dice, cube, and interaction
/// highlights) using a [BoardGeometry] for placement and a [BoardTheme] for
/// colours. Purely declarative: give it inputs, it paints; [shouldRepaint]
/// compares every input so it only repaints on a real change.
class BoardPainter extends CustomPainter {
  BoardPainter({
    required this.board,
    required this.geometry,
    required this.theme,
    this.dice,
    this.cube,
    this.highlightedSources = const {},
    this.highlightedDestinations = const {},
    this.combinedDestinations = const {},
    this.selectedCheckerLocation,
    this.movingPlayer,
    this.hiddenChecker,
    this.overlayChecker,
  });

  final BoardState board;
  final BoardGeometry geometry;
  final BoardTheme theme;
  final Dice? dice;
  final CubeState? cube;

  /// Selectable (but not-yet-picked-up) sources: each renders as a subtle ring
  /// around its TOP CHECKER (point index 0..23, or [CheckerMove.bar]).
  final Set<int> highlightedSources;

  /// Legal destinations for the picked-up source: each renders as a uniform
  /// highlight on the target TRIANGLE (point index 0..23, or [CheckerMove.off]
  /// for the bear-off strip).
  final Set<int> highlightedDestinations;

  /// Landing points of COMBINED (multi-hop, same-checker) moves for the
  /// picked-up source: each renders as a DIMMER (reduced-opacity) variant of the
  /// destination highlight, so a tap there enters the whole chain. Disjoint from
  /// [highlightedDestinations] (the caller subtracts the direct set); if a point
  /// appears in both, the bright direct highlight wins. Empty by default, in
  /// which case painting is byte-identical to the un-extended path.
  final Set<int> combinedDestinations;

  /// The picked-up source whose TOP CHECKER wears the bright selection ring:
  /// a point index 0..23, or [CheckerMove.bar]. `null` when nothing is picked
  /// up. Anchoring the highlight to the checker (not the triangle) means a
  /// beaten checker resting on the bar highlights just like any other.
  final int? selectedCheckerLocation;

  /// The side to move, used only to resolve WHICH bar half a bar source/selection
  /// refers to (both players may have checkers on the bar at once). Required for
  /// a bar ring to render; ignored for point sources.
  final Player? movingPlayer;

  /// A single checker to SUPPRESS while it travels as [overlayChecker] during a
  /// move animation: the [stackIndex]-th checker at [location] (a point index
  /// 0..23, or [CheckerMove.bar]) belonging to [isWhite]. `null` when nothing is
  /// hidden — in which case painting is byte-identical to the un-extended path.
  final ({int location, int stackIndex, bool isWhite})? hiddenChecker;

  /// A checker to draw on top of everything at [center] during a move animation
  /// (the travelling piece). `null` when idle.
  final ({Offset center, bool isWhite})? overlayChecker;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);
    _paintTriangles(canvas);
    _paintOffDestination(canvas);
    _paintBar(canvas);
    _paintPointCheckers(canvas);
    _paintBarCheckers(canvas);
    _paintOffTrays(canvas);
    // Selection rings ride ABOVE the checkers so they read as haloes, never
    // hidden behind the discs.
    _paintSelectionRings(canvas);
    if (dice != null) _paintDice(canvas, size);
    if (cube != null) _paintCube(canvas);
    // The travelling checker rides above every static checker/tray.
    final overlay = overlayChecker;
    if (overlay != null) _drawChecker(canvas, overlay.center, overlay.isWhite);
  }

  /// Whether the [s]-th checker of [isWhite] at point/bar [location] is the one
  /// currently hidden (lifted into the travelling [overlayChecker]).
  bool _isHidden(int location, int s, bool isWhite) {
    final h = hiddenChecker;
    return h != null &&
        h.location == location &&
        h.stackIndex == s &&
        h.isWhite == isWhite;
  }

  // --- Board furniture -------------------------------------------------------

  void _paintBackground(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = theme.boardColor);
    final border = math.min(size.width, size.height) * 0.012;
    canvas.drawRect(
      rect.deflate(border / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = border
        ..color = theme.barColor,
    );
  }

  void _paintTriangles(Canvas canvas) {
    for (var i = 0; i < 24; i++) {
      final rect = geometry.pointRect(i);
      final baseAtBottom =
          geometry.whiteAtBottom ? i < 12 : i >= 12;
      final baseY = baseAtBottom ? rect.bottom : rect.top;
      final apexY = baseAtBottom ? rect.top : rect.bottom;
      final path = Path()
        ..moveTo(rect.left, baseY)
        ..lineTo(rect.right, baseY)
        ..lineTo(rect.center.dx, apexY)
        ..close();
      final color = i.isEven ? theme.pointDark : theme.pointLight;
      canvas.drawPath(path, Paint()..color = color);

      // A direct destination wins over a combined landing when both apply.
      if (highlightedDestinations.contains(i)) {
        _paintDestinationTriangle(canvas, path);
      } else if (combinedDestinations.contains(i)) {
        _paintCombinedTriangle(canvas, path);
      }
    }
  }

  /// Paints a destination highlight whose resulting pixels do NOT depend on the
  /// underlying point colour: an OPAQUE uniform fill (which fully neutralises the
  /// dark/light point beneath) topped by an opaque edge ring. Because the fill
  /// is opaque, a highlighted destination is pixel-identical over both point
  /// colours — the user's "different colours on white and red" complaint.
  void _paintDestinationTriangle(Canvas canvas, Path path) {
    canvas.drawPath(path, Paint()..color = theme.highlightDestinationFill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.checkerRadius * 0.22
        ..color = theme.highlightDestination,
    );
  }

  /// Combined-move landing: a DIMMER variant of the direct destination
  /// highlight — the same green fill + ring at reduced opacity — so it reads as
  /// "reachable by playing both dice with this checker" without competing with
  /// the bright single-hop targets.
  void _paintCombinedTriangle(Canvas canvas, Path path) {
    canvas.drawPath(
        path,
        Paint()
          ..color = theme.highlightDestinationFill.withValues(alpha: 0.42));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.checkerRadius * 0.18
        ..color = theme.highlightDestination.withValues(alpha: 0.55),
    );
  }

  /// Highlights the moving player's bear-off strip when `off` is a destination,
  /// using the SAME opaque fill + ring as the triangle destinations so it reads
  /// uniformly. No-op unless [movingPlayer] is known.
  void _paintOffDestination(Canvas canvas) {
    final player = movingPlayer;
    if (player == null) return;
    final direct = highlightedDestinations.contains(CheckerMove.off);
    final combined = !direct && combinedDestinations.contains(CheckerMove.off);
    if (!direct && !combined) return;
    final tray = geometry.offRect(player);
    final fillAlpha = combined ? 0.42 : 1.0;
    final ringAlpha = combined ? 0.55 : 1.0;
    canvas.drawRect(tray,
        Paint()..color = theme.highlightDestinationFill.withValues(alpha: fillAlpha));
    canvas.drawRect(
      tray.deflate(geometry.checkerRadius * 0.11),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.checkerRadius * (combined ? 0.18 : 0.22)
        ..color = theme.highlightDestination.withValues(alpha: ringAlpha),
    );
  }

  // --- Selection rings (checker-anchored) ------------------------------------

  /// Draws the checker-anchored selection haloes ABOVE all checkers: a subtle
  /// ring on every selectable source's top checker, and a bright glowing ring on
  /// the picked-up source's top checker.
  void _paintSelectionRings(Canvas canvas) {
    for (final loc in highlightedSources) {
      final c = _topCheckerCenter(loc);
      if (c != null) _drawSourceRing(canvas, c);
    }
    final sel = selectedCheckerLocation;
    if (sel != null) {
      final c = _topCheckerCenter(sel);
      if (c != null) _drawSelectedRing(canvas, c);
    }
  }

  /// Centre of the TOP checker resting at [location] (a point index 0..23 or
  /// [CheckerMove.bar]) on the current [board]. `null` when the location holds
  /// no checker, or when a bar location is queried without a [movingPlayer].
  Offset? _topCheckerCenter(int location) {
    if (location == CheckerMove.bar) {
      final player = movingPlayer;
      if (player == null) return null;
      final n = board.barFor(player);
      if (n == 0) return null;
      return geometry.barCheckerCenter(player, n - 1, n);
    }
    if (location < 0 || location >= 24) return null;
    final count = board.points[location].abs();
    if (count == 0) return null;
    return geometry.checkerCenter(location, count - 1, count);
  }

  /// Subtle halo on a selectable-but-unpicked source's top checker.
  void _drawSourceRing(Canvas canvas, Offset center) {
    final r = geometry.checkerRadius;
    canvas.drawCircle(
      center,
      r * 1.06,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.13
        ..color = theme.highlightSource,
    );
  }

  /// Bright glowing halo on the picked-up source's top checker.
  void _drawSelectedRing(Canvas canvas, Offset center) {
    final r = geometry.checkerRadius;
    // Soft outer glow.
    canvas.drawCircle(
      center,
      r * 1.24,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.46
        ..color = theme.selectedOutline.withValues(alpha: 0.30),
    );
    // Crisp bright ring.
    canvas.drawCircle(
      center,
      r * 1.14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.22
        ..color = theme.selectedOutline,
    );
  }

  void _paintBar(Canvas canvas) {
    final rect = geometry.barRect(Player.white).expandToInclude(
          geometry.barRect(Player.black),
        );
    canvas.drawRect(rect, Paint()..color = theme.barColor);
  }

  // --- Checkers --------------------------------------------------------------

  void _paintPointCheckers(Canvas canvas) {
    for (var i = 0; i < 24; i++) {
      final count = board.points[i];
      if (count == 0) continue;
      final isWhite = count > 0;
      final n = count.abs();
      for (var s = 0; s < n; s++) {
        if (_isHidden(i, s, isWhite)) continue;
        _drawChecker(canvas, geometry.checkerCenter(i, s, n), isWhite);
      }
      if (n > 5) {
        _drawCountLabel(canvas, geometry.checkerCenter(i, n - 1, n), n, isWhite);
      }
    }
  }

  void _paintBarCheckers(Canvas canvas) {
    for (final player in Player.values) {
      final n = board.barFor(player);
      final isWhite = player == Player.white;
      for (var s = 0; s < n; s++) {
        if (_isHidden(CheckerMove.bar, s, isWhite)) continue;
        _drawChecker(canvas, geometry.barCheckerCenter(player, s, n), isWhite);
      }
      if (n > 5) {
        _drawCountLabel(
            canvas, geometry.barCheckerCenter(player, n - 1, n), n, isWhite);
      }
    }
  }

  void _drawChecker(Canvas canvas, Offset center, bool isWhite) {
    final r = geometry.checkerRadius;
    canvas.drawCircle(
      center,
      r,
      Paint()..color = isWhite ? theme.whiteChecker : theme.blackChecker,
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.12
        ..color = theme.checkerBorder,
    );
    // Inner ring for a little depth.
    canvas.drawCircle(
      center,
      r * 0.62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.08
        ..color = theme.checkerBorder.withValues(alpha: 0.35),
    );
  }

  void _drawCountLabel(Canvas canvas, Offset center, int count, bool isWhite) {
    _outlinedText(
      canvas,
      '$count',
      center,
      geometry.checkerRadius * 1.05,
      isWhite ? theme.blackChecker : theme.whiteChecker,
      isWhite ? theme.whiteChecker : theme.blackChecker,
      bold: true,
    );
  }

  // --- Bear-off trays --------------------------------------------------------

  /// Draws a player's borne-off checkers as a horizontal row of discs from the
  /// tray strip's leading (left) edge, with an outlined count at the trailing
  /// (right) end. Discs compress horizontally if 15 would overflow the row.
  void _paintOffTrays(Canvas canvas) {
    for (final player in Player.values) {
      final n = board.offFor(player);
      if (n == 0) continue;
      final tray = geometry.offRect(player);
      final isWhite = player == Player.white;
      final r = tray.height * 0.38;
      final cy = tray.center.dy;
      final pad = tray.height * 0.28;
      // Reserve a slot at the trailing end for the count text.
      final textW = tray.height * 1.1;
      final rowLeft = tray.left + pad + r;
      final rowRight = tray.right - pad - textW - r;
      final avail = math.max(0.0, rowRight - rowLeft);
      final step = n > 1 ? math.min(_off2r(r), avail / (n - 1)) : 0.0;
      final disc = Paint()
        ..color = isWhite ? theme.whiteChecker : theme.blackChecker;
      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.14
        ..color = theme.checkerBorder;
      for (var s = 0; s < n; s++) {
        final c = Offset(rowLeft + step * s, cy);
        canvas.drawCircle(c, r, disc);
        canvas.drawCircle(c, r, border);
      }
      // Outlined count at the trailing end: light fill, contrasting outline so
      // it reads clearly whether it sits over felt or over a disc.
      _outlinedText(
        canvas,
        '$n',
        Offset(tray.right - pad - textW / 2, cy),
        tray.height * 0.62,
        theme.whiteChecker,
        theme.blackChecker,
        bold: true,
      );
    }
  }

  /// Full-diameter spacing for the tray discs.
  double _off2r(double r) => r * 2;

  // --- Dice ------------------------------------------------------------------

  void _paintDice(Canvas canvas, Size size) {
    final d = dice!;
    final side = geometry.checkerRadius * 2.2;
    final gap = side * 0.5;
    // Centre the pair in the right half's middle band.
    final cx = size.width * 0.71;
    final cy = size.height / 2;
    final firstCentre = Offset(cx - (side + gap) / 2, cy);
    final secondCentre = Offset(cx + (side + gap) / 2, cy);
    _drawDie(canvas, firstCentre, side, d.die1);
    _drawDie(canvas, secondCentre, side, d.die2);
  }

  void _drawDie(Canvas canvas, Offset center, double side, int value) {
    final rect = Rect.fromCenter(center: center, width: side, height: side);
    final rr = RRect.fromRectXY(rect, side * 0.18, side * 0.18);
    canvas.drawRRect(rr, Paint()..color = theme.diceColor);
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.05
        ..color = theme.dicePipColor.withValues(alpha: 0.6),
    );
    final pipR = side * 0.09;
    final pipPaint = Paint()..color = theme.dicePipColor;
    // 3x3 grid coordinates.
    final l = center.dx - side * 0.26;
    final m = center.dx;
    final rgt = center.dx + side * 0.26;
    final t = center.dy - side * 0.26;
    final mid = center.dy;
    final b = center.dy + side * 0.26;
    final pips = <Offset>[
      if (value.isOdd) Offset(m, mid), // centre pip for 1,3,5
      if (value >= 2) ...[Offset(l, t), Offset(rgt, b)],
      if (value >= 4) ...[Offset(rgt, t), Offset(l, b)],
      if (value == 6) ...[Offset(l, mid), Offset(rgt, mid)],
    ];
    for (final p in pips) {
      canvas.drawCircle(p, pipR, pipPaint);
    }
  }

  // --- Doubling cube ---------------------------------------------------------

  void _paintCube(Canvas canvas) {
    final c = cube!;
    final side = geometry.checkerRadius * 2.1;
    final barRect = geometry.barRect(Player.white);
    final barCx = (barRect.left + barRect.right) / 2;
    final midY = size().height / 2;
    final Offset center;
    if (c.owner == null) {
      center = Offset(barCx, midY);
    } else {
      // Nudge the owned cube along the bar toward its owner's half so ownership
      // reads at a glance (bottom half = local-bottom player), staying clear of
      // the resting bar checkers that pile from the outer ends.
      final ownerAtBottom = geometry.barRect(c.owner!).center.dy > midY;
      center = Offset(barCx, midY + (ownerAtBottom ? side : -side));
    }
    final rect = Rect.fromCenter(center: center, width: side, height: side);
    final rr = RRect.fromRectXY(rect, side * 0.18, side * 0.18);
    canvas.drawRRect(rr, Paint()..color = theme.cubeColor);
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side * 0.05
        ..color = theme.dicePipColor.withValues(alpha: 0.6),
    );
    _drawText(canvas, '${c.value}', center, side * 0.5, theme.dicePipColor,
        bold: true);
  }

  Size size() => geometry.size;

  // --- Text helper -----------------------------------------------------------

  void _drawText(Canvas canvas, String text, Offset center, double fontSize,
      Color color,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      center - Offset(tp.width / 2, tp.height / 2),
    );
  }

  /// Draws [text] centred at [center] with a [fill] over a contrasting [outline]
  /// stroke, so the glyphs stay legible over checkers or felt. Painted twice:
  /// the stroke pass first, the fill on top.
  void _outlinedText(Canvas canvas, String text, Offset center, double fontSize,
      Color fill, Color outline,
      {bool bold = false}) {
    final weight = bold ? FontWeight.bold : FontWeight.normal;
    final strokeWidth = math.max(1.0, fontSize * 0.14);
    final stroke = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..color = outline,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final fillTp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: fill, fontSize: fontSize, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final origin = center - Offset(fillTp.width / 2, fillTp.height / 2);
    stroke.paint(canvas, origin);
    fillTp.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(BoardPainter old) {
    return old.board != board ||
        old.geometry.size != geometry.size ||
        old.geometry.whiteAtBottom != geometry.whiteAtBottom ||
        !identical(old.theme, theme) ||
        old.dice != dice ||
        old.cube != cube ||
        old.selectedCheckerLocation != selectedCheckerLocation ||
        old.movingPlayer != movingPlayer ||
        old.hiddenChecker != hiddenChecker ||
        old.overlayChecker != overlayChecker ||
        !setEquals(old.highlightedSources, highlightedSources) ||
        !setEquals(old.highlightedDestinations, highlightedDestinations) ||
        !setEquals(old.combinedDestinations, combinedDestinations);
  }
}
