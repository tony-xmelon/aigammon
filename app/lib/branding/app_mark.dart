import 'package:flutter/material.dart';

import '../board/board_theme.dart';

/// The AIGammon brand mark: a top-down backgammon board viewport — a walnut
/// frame around tan felt, two OPPOSING rows of alternating crimson/cream points
/// closing on a felt gap, the walnut bar down the middle, and a checker resting
/// on a point in each half.
///
/// The mutual opposition of the two rows across the bar is backgammon's visual
/// signature, and it is what a single row of points cannot convey: one row of
/// triangles hanging off a rail reads as bunting, or — with discs under it — a
/// military decoration. Everything here is a board part in a board position.
///
/// The SAME painter draws the launcher icon (rasterised to PNG by
/// `tool/generate_app_icon.dart`) and the home screen's hero, so the app's
/// identity on the springboard and inside the app cannot drift apart.
///
/// Geometry is expressed in fractions of the board's own box (a unit square) so
/// the mark is resolution independent: it reads at 1024px and at 48px alike.
class AppMarkPainter extends CustomPainter {
  const AppMarkPainter({
    this.theme = BoardTheme.light,
    this.cornerRadiusFraction = 0.22,
    this.contentScale = 1.0,
  });

  /// Board palette the mark borrows its colours from.
  final BoardTheme theme;

  /// Corner rounding of the board's frame, as a fraction of the board's side.
  /// 0 gives the square, full-bleed plate iOS and Windows want (they round it
  /// themselves); ~0.22 suits the in-app hero.
  final double cornerRadiusFraction;

  /// How much of the shortest side the BOARD spans. 1.0 fills the canvas (the
  /// launcher plate and the hero); the Android adaptive foreground shrinks it so
  /// the frame's corners stay inside the launcher's circular safe zone (see
  /// `tool/generate_app_icon.dart` for the arithmetic).
  final double contentScale;

  /// Frame thickness, as a fraction of the board's side. Also the rail depth the
  /// points spring from.
  static const double _frame = 0.075;

  /// Half-width of the bar strip, as a fraction of the board's side.
  static const double _barHalf = 0.032;

  /// Points per row (across BOTH halves — so [_pointsPerRow] / 2 per half).
  /// Four is the most that still reads as separate triangles at 32px; six (a
  /// real half-board) turns into a comb.
  static const int _pointsPerRow = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * contentScale;
    final board = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );

    // The walnut frame: the mark's silhouette, and the only element that has to
    // survive at 32px.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        board,
        Radius.circular(side * cornerRadiusFraction),
      ),
      Paint()..color = theme.barColor,
    );

    canvas.save();
    canvas.translate(board.left, board.top);
    canvas.scale(side);
    _paintPlayingSurface(canvas);
    canvas.restore();
  }

  /// Draws everything inside the frame, in board-box unit coordinates.
  void _paintPlayingSurface(Canvas canvas) {
    const felt = Rect.fromLTRB(_frame, _frame, 1 - _frame, 1 - _frame);
    canvas.drawRRect(
      RRect.fromRectAndRadius(felt, const Radius.circular(0.045)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _lighten(theme.boardColor, 0.10),
            _darken(theme.boardColor, 0.10),
          ],
        ).createShader(felt),
    );

    _paintPoints(canvas);

    // The bar, drawn over the points' bases so it reads as the strip that
    // divides the two halves rather than a gap between them.
    canvas.drawRect(
      const Rect.fromLTRB(0.5 - _barHalf, _frame, 0.5 + _barHalf, 1 - _frame),
      Paint()..color = theme.barColor,
    );

    // One checker per half, seated at the base of a point, diagonally opposed
    // across the bar: the pair says whose men are whose without crowding the
    // felt, and placing them INBOARD (either side of the bar rather than on the
    // outermost points) keeps them clear of the frame's rounded corners, where
    // they read as blobs at 32px.
    //
    // Both stand on a crimson point and rely on the board's inverted-rim rule —
    // ivory disc + espresso rim, ebony disc + cream rim — to hold their
    // silhouettes. Radius is sized to the point so each looks seated on it
    // rather than dropped on top of the board.
    const radius = 0.093;
    _checker(
      canvas,
      Offset(_pointCenterX(2), _frame + radius),
      radius,
      theme.whiteChecker,
      theme.whiteCheckerBorder,
    );
    _checker(
      canvas,
      Offset(_pointCenterX(1), 1 - _frame - radius),
      radius,
      theme.blackChecker,
      theme.blackCheckerBorder,
    );
  }

  /// Width of one point, as a fraction of the board's side. The two halves split
  /// the felt either side of the bar.
  static const double _pointWidth =
      (0.5 - _frame - _barHalf) / (_pointsPerRow / 2);

  /// Left edge of point [i] of a row (0-based, left to right across both
  /// halves), stepping over the bar at the halfway mark.
  static double _pointLeft(int i) =>
      _frame + i * _pointWidth + (i < _pointsPerRow / 2 ? 0 : 2 * _barHalf);

  /// Centre line of point [i] of a row.
  static double _pointCenterX(int i) => _pointLeft(i) + _pointWidth / 2;

  /// The two rows of points: the top row hangs down from the top rail, the
  /// bottom row rises from the bottom rail, and they stop short of each other so
  /// a band of bare felt (the board's middle) separates the tips. Colours
  /// alternate along each row AND invert between rows, so every point faces one
  /// of the other colour — exactly as on a board.
  void _paintPoints(Canvas canvas) {
    const gap = 0.004; // hairline of felt between neighbours
    // Rail to tip: long enough that the two rows close on a narrow band of bare
    // felt. A short point leaves a dead stripe across the middle and the halves
    // stop reading as one board.
    const length = 0.375;
    const outline = 0.008;

    for (var i = 0; i < _pointsPerRow; i++) {
      final l = _pointLeft(i);
      final crimson = i.isEven;

      for (final top in [true, false]) {
        final baseY = top ? _frame : 1 - _frame;
        final tipY = top ? _frame + length : 1 - _frame - length;
        final path = Path()
          ..moveTo(l + gap, baseY)
          ..lineTo(l + _pointWidth - gap, baseY)
          ..lineTo(l + _pointWidth / 2, tipY)
          ..close();
        canvas.drawPath(
          path,
          Paint()
            ..color = (crimson == top) ? theme.pointDark : theme.pointLight,
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = outline
            ..strokeJoin = StrokeJoin.round
            ..color = theme.barColor,
        );
      }
    }
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
