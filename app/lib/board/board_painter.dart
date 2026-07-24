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
  });

  final BoardState board;
  final BoardGeometry geometry;
  final BoardTheme theme;
  final Dice? dice;
  final CubeState? cube;
  final Set<int> highlightedSources;
  final Set<int> highlightedDestinations;
  final int? selectedSource;

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
        _drawChecker(canvas, geometry.checkerCenter(i, s), isWhite);
      }
      if (n > 5) {
        _drawCountLabel(canvas, geometry.checkerCenter(i, n - 1), n, isWhite);
      }
    }
  }

  void _paintBarCheckers(Canvas canvas) {
    for (final player in Player.values) {
      final n = board.barFor(player);
      final isWhite = player == Player.white;
      for (var s = 0; s < n; s++) {
        _drawChecker(canvas, geometry.barCheckerCenter(player, s), isWhite);
      }
      if (n > 5) {
        _drawCountLabel(
            canvas, geometry.barCheckerCenter(player, n - 1), n, isWhite);
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
    _drawText(
      canvas,
      '$count',
      center,
      geometry.checkerRadius * 1.05,
      isWhite ? theme.blackChecker : theme.whiteChecker,
      bold: true,
    );
  }

  // --- Bear-off trays --------------------------------------------------------

  void _paintOffTrays(Canvas canvas) {
    for (final player in Player.values) {
      final n = board.offFor(player);
      if (n == 0) continue;
      final tray = geometry.offRect(player);
      final isWhite = player == Player.white;
      // Whether the tray's outer edge (where checkers pile from) is at bottom.
      final fillFromBottom =
          geometry.whiteAtBottom ? isWhite : !isWhite;
      final slabH = tray.height / 15; // up to 15 borne off
      final inset = tray.width * 0.12;
      final paint = Paint()
        ..color = isWhite ? theme.whiteChecker : theme.blackChecker;
      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = slabH * 0.18
        ..color = theme.checkerBorder;
      for (var s = 0; s < n; s++) {
        final top = fillFromBottom
            ? tray.bottom - (s + 1) * slabH
            : tray.top + s * slabH;
        final slab = Rect.fromLTWH(
          tray.left + inset,
          top + slabH * 0.12,
          tray.width - inset * 2,
          slabH * 0.76,
        );
        final rr = RRect.fromRectXY(slab, slabH * 0.2, slabH * 0.2);
        canvas.drawRRect(rr, paint);
        canvas.drawRRect(rr, border);
      }
      _drawText(
        canvas,
        '$n',
        tray.center,
        tray.width * 0.42,
        theme.textColor,
        bold: true,
      );
    }
  }

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
    final barCx =
        (geometry.barRect(Player.white).left +
                geometry.barRect(Player.white).right) /
            2;
    final Offset center;
    if (c.owner == null) {
      center = Offset(barCx, size().height / 2);
    } else {
      center = Offset(barCx, geometry.offRect(c.owner!).center.dy);
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

  @override
  bool shouldRepaint(BoardPainter old) {
    return old.board != board ||
        old.geometry.size != geometry.size ||
        old.geometry.whiteAtBottom != geometry.whiteAtBottom ||
        !identical(old.theme, theme) ||
        old.dice != dice ||
        old.cube != cube ||
        old.selectedSource != selectedSource ||
        !setEquals(old.highlightedSources, highlightedSources) ||
        !setEquals(old.highlightedDestinations, highlightedDestinations);
  }
}
