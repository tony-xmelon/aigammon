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
    this.selectedSource,
    this.hiddenChecker,
    this.overlayChecker,
  });

  final BoardState board;
  final BoardGeometry geometry;
  final BoardTheme theme;
  final Dice? dice;
  final CubeState? cube;
  final Set<int> highlightedSources;
  final Set<int> highlightedDestinations;
  final int? selectedSource;

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
    _paintBar(canvas);
    _paintPointCheckers(canvas);
    _paintBarCheckers(canvas);
    _paintOffTrays(canvas);
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

      if (highlightedDestinations.contains(i)) {
        canvas.drawPath(path, Paint()..color = theme.highlightDestination);
      }
      if (highlightedSources.contains(i)) {
        canvas.drawPath(path, Paint()..color = theme.highlightSource);
      }
      if (selectedSource == i) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = geometry.checkerRadius * 0.28
            ..color = theme.selectedOutline,
        );
      }
    }
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
        old.selectedSource != selectedSource ||
        old.hiddenChecker != hiddenChecker ||
        old.overlayChecker != overlayChecker ||
        !setEquals(old.highlightedSources, highlightedSources) ||
        !setEquals(old.highlightedDestinations, highlightedDestinations);
  }
}
