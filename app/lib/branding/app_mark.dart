import 'package:flutter/material.dart';

import '../board/board_theme.dart';

/// The AIGammon brand mark: two elongated backgammon points (crimson + cream)
/// over a white/ebony checker pair, on warm tan felt.
///
/// The SAME painter draws the launcher icon (rasterised to PNG by
/// `tool/generate_app_icon.dart`) and the home screen's hero, so the app's
/// identity on the springboard and inside the app cannot drift apart.
///
/// Geometry is expressed in fractions of a square "design box" so the mark is
/// resolution independent: it reads at 1024px and at 48px alike. Everything is
/// laid out against [_content], the bounding box the ink actually occupies —
/// the caller centres THAT, not the nominal square, so the mark looks optically
/// centred rather than mathematically centred.
class AppMarkPainter extends CustomPainter {
  const AppMarkPainter({
    this.theme = BoardTheme.light,
    this.background = true,
    this.cornerRadiusFraction = 0.22,
    this.contentScale = 0.78,
  });

  /// Board palette the mark borrows its colours from.
  final BoardTheme theme;

  /// Whether to fill the felt plate behind the motif. False for the Android
  /// adaptive foreground (the launcher supplies the background) and for a mark
  /// drawn over an existing surface.
  final bool background;

  /// Plate corner rounding, as a fraction of the shortest side. Ignored when
  /// [background] is false.
  final double cornerRadiusFraction;

  /// How much of the shortest side the motif's ink spans (its larger dimension).
  /// ~0.78 suits a full-bleed icon plate; ~0.62 keeps the Android adaptive
  /// foreground inside the launcher's circular safe zone.
  final double contentScale;

  /// The motif's ink bounds inside the unit design box. Used to centre by ink
  /// rather than by box.
  static const Rect _content = Rect.fromLTRB(0.08, 0.045, 0.92, 0.863);

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;

    if (background) {
      final plate = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          plate,
          Radius.circular(side * cornerRadiusFraction),
        ),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _lighten(theme.boardColor, 0.10),
              _darken(theme.boardColor, 0.10),
            ],
          ).createShader(plate),
      );
    }

    // Scale the unit design box so its INK spans [contentScale] of the plate,
    // then translate so that ink sits centred.
    final unit = side * contentScale / _content.longestSide;
    final dx = (size.width - _content.width * unit) / 2 - _content.left * unit;
    final dy = (size.height - _content.height * unit) / 2 - _content.top * unit;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(unit);
    _paintMotif(canvas);
    canvas.restore();
  }

  /// Draws the motif in unit coordinates (the 0..1 design box): two opposed
  /// points — crimson hanging from the top, cream rising from the bottom — each
  /// carrying one checker at its base, the way checkers actually stack on a
  /// board. The 180°-rotational symmetry keeps it balanced at any size, and the
  /// checkers land on the opposite colour so both silhouettes stay crisp.
  void _paintMotif(Canvas canvas) {
    const left = 0.08;
    const width = 0.84;
    const pointCount = 3;
    const pointWidth = width / pointCount;
    const baseY = 0.085;
    const apexY = 0.55;

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.010
      ..strokeJoin = StrokeJoin.round
      ..color = theme.barColor;

    // The board's walnut rail. The points grow out of it rather than floating,
    // which is what stops the band reading as bunting.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(left, 0.045, left + width, baseY + 0.01),
        const Radius.circular(0.022),
      ),
      Paint()..color = theme.barColor,
    );

    // A band of four alternating points hanging from the rail — the pattern that
    // says "backgammon" at a glance, and the only one that still reads as a
    // board at 48px.
    for (var i = 0; i < pointCount; i++) {
      final l = left + i * pointWidth;
      final path = Path()
        ..moveTo(l + 0.004, baseY)
        ..lineTo(l + pointWidth - 0.004, baseY)
        ..lineTo(l + pointWidth / 2, apexY)
        ..close();
      canvas.drawPath(
        path,
        Paint()..color = i.isEven ? theme.pointDark : theme.pointLight,
      );
      canvas.drawPath(path, outline);
    }

    // The pair of checkers, straddling the gaps between the point tips so the
    // two bands interlock into one object instead of stacking as two.
    const radius = 0.168;
    const checkerY = 0.695;
    _checker(canvas, const Offset(0.325, checkerY), radius, theme.whiteChecker,
        theme.whiteCheckerBorder);
    _checker(canvas, const Offset(0.675, checkerY), radius, theme.blackChecker,
        theme.blackCheckerBorder);
  }

  /// One checker: a filled disc under an inverted rim — the same silhouette rule
  /// the board itself follows (a light checker wears a dark rim and vice versa),
  /// so each stays legible against the point it sits on.
  void _checker(
    Canvas canvas,
    Offset center,
    double radius,
    Color fill,
    Color rim,
  ) {
    canvas.drawCircle(center, radius, Paint()..color = fill);
    canvas.drawCircle(
      center,
      radius - 0.009,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.018
        ..color = rim,
    );
  }

  static Color _lighten(Color c, double amount) =>
      Color.lerp(c, const Color(0xFFFFFFFF), amount)!;

  static Color _darken(Color c, double amount) =>
      Color.lerp(c, const Color(0xFF000000), amount)!;

  @override
  bool shouldRepaint(AppMarkPainter old) =>
      old.theme != theme ||
      old.background != background ||
      old.cornerRadiusFraction != cornerRadiusFraction ||
      old.contentScale != contentScale;
}

/// The brand mark as a widget — a square [size]-sided plate. Used as the home
/// screen's hero; identical artwork to the launcher icon.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 128, this.theme = BoardTheme.light});

  final double size;
  final BoardTheme theme;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: AppMarkPainter(theme: theme),
        isComplex: true,
      ),
    );
  }
}
