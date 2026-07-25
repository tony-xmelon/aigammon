// Pixel-level checks of the highlight rendering. These render the painter and
// COMPARE renders produced in the SAME run, so they are platform-independent
// (any antialiasing drift cancels between the two renders) — unlike the
// golden-file comparisons, they are NOT tagged `golden` and run on CI.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_theme.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 600);

Widget _harness(BoardPainter painter) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: _size.width,
          height: _size.height,
          child: RepaintBoundary(
            child: CustomPaint(size: _size, painter: painter),
          ),
        ),
      ),
    );

/// A rendered frame's raw RGBA pixels, addressable by coordinate.
class _Pixels {
  _Pixels(this.width, this.height, this._data);
  final int width;
  final int height;
  final ByteData _data;

  Color at(Offset p) => atXY(p.dx.round(), p.dy.round());

  Color atXY(int x, int y) {
    final o = (y * width + x) * 4;
    return Color.fromARGB(
      _data.getUint8(o + 3),
      _data.getUint8(o),
      _data.getUint8(o + 1),
      _data.getUint8(o + 2),
    );
  }
}

Future<_Pixels> _render(WidgetTester t, BoardPainter painter) async {
  await t.pumpWidget(_harness(painter));
  await t.pump();
  late _Pixels pixels;
  await t.runAsync(() async {
    final boundary =
        t.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary));
    final image = await boundary.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    pixels = _Pixels(image.width, image.height, data);
    image.dispose();
  });
  return pixels;
}

/// Counts pixels that differ between [a] and [b] inside a square window of
/// half-width [radius] centred on [center] (clipped to the image bounds).
int _diffCount(_Pixels a, _Pixels b, Offset center, double radius) {
  final x0 = (center.dx - radius).floor().clamp(0, a.width - 1);
  final x1 = (center.dx + radius).ceil().clamp(0, a.width - 1);
  final y0 = (center.dy - radius).floor().clamp(0, a.height - 1);
  final y1 = (center.dy + radius).ceil().clamp(0, a.height - 1);
  var n = 0;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      if (a.atXY(x, y) != b.atXY(x, y)) n++;
    }
  }
  return n;
}

void main() {
  testWidgets('destination highlight renders identically over a dark and a '
      'light point', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final g = BoardGeometry(_size, whiteAtBottom: true);
    final empty = BoardState(points: List<int>.filled(24, 0));
    BoardPainter dest(int i) => BoardPainter(
          board: empty,
          geometry: g,
          theme: BoardTheme.light,
          highlightedDestinations: {i},
          movingPlayer: Player.white,
        );

    // Index 6 is a DARK point, index 7 a LIGHT point (i.isEven ? dark : light).
    // Both are empty, so the triangle-centre pixel is pure highlight fill.
    final darkPx = (await _render(t, dest(6))).at(g.pointRect(6).center);
    final lightPx = (await _render(t, dest(7))).at(g.pointRect(7).center);
    expect(darkPx, equals(lightPx),
        reason: 'a highlighted destination must be the same colour on both '
            'point colours');
  });

  for (final wab in [true, false]) {
    testWidgets('bar selection ring paints around the beaten checker '
        '(whiteAtBottom=$wab)', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final g = BoardGeometry(_size, whiteAtBottom: wab);
      final board = BoardState(points: List<int>.filled(24, 0), whiteBar: 1);
      final center = g.barCheckerCenter(Player.white, 0, 1);
      BoardPainter make({required bool selected}) => BoardPainter(
            board: board,
            geometry: g,
            theme: BoardTheme.dark,
            movingPlayer: Player.white,
            selectedCheckerLocation: selected ? CheckerMove.bar : null,
          );

      final plain = await _render(t, make(selected: false));
      final selected = await _render(t, make(selected: true));
      expect(
        _diffCount(plain, selected, center, g.checkerRadius * 1.6),
        greaterThan(0),
        reason: 'selecting the bar checker must draw a visible ring',
      );
    });
  }

  testWidgets('a combined-move landing renders a DIMMER highlight than a '
      'direct destination', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final g = BoardGeometry(_size, whiteAtBottom: true);
    final empty = BoardState(points: List<int>.filled(24, 0));
    BoardPainter make({Set<int> direct = const {}, Set<int> combined = const {}}) =>
        BoardPainter(
          board: empty,
          geometry: g,
          theme: BoardTheme.light,
          highlightedDestinations: direct,
          combinedDestinations: combined,
          movingPlayer: Player.white,
        );

    final plain = await _render(t, make());
    final direct = await _render(t, make(direct: {7}));
    final combined = await _render(t, make(combined: {7}));
    final centre = g.pointRect(7).center;

    // Both variants change the triangle centre from bare felt.
    expect(direct.at(centre), isNot(equals(plain.at(centre))));
    expect(combined.at(centre), isNot(equals(plain.at(centre))));
    // The combined variant is DIMMER: its fill differs from the opaque direct
    // fill (reduced opacity lets the point colour show through).
    expect(combined.at(centre), isNot(equals(direct.at(centre))),
        reason: 'a combined landing must read differently from a direct target');

    // An empty combinedDestinations set is byte-identical to no highlight at all.
    final none = await _render(t, make(combined: const {}));
    expect(_diffCount(plain, none, centre, g.checkerRadius * 2), 0);
  });

  testWidgets('a selectable source draws a checker ring, not a triangle tint',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final g = BoardGeometry(_size, whiteAtBottom: true);
    final pts = List<int>.filled(24, 0);
    pts[6] = 3; // 3 White checkers on a dark point
    final board = BoardState(points: pts);
    BoardPainter make({required bool highlight}) => BoardPainter(
          board: board,
          geometry: g,
          theme: BoardTheme.light,
          movingPlayer: Player.white,
          highlightedSources: highlight ? {6} : const {},
        );

    final plain = await _render(t, make(highlight: false));
    final ring = await _render(t, make(highlight: true));

    // A ring appears on the top checker.
    final top = g.checkerCenter(6, 2, 3);
    expect(_diffCount(plain, ring, top, g.checkerRadius * 1.4), greaterThan(0),
        reason: 'a selectable source must ring its top checker');

    // The BARE triangle near the apex (well above the stack) is untouched — the
    // old full-triangle tint would have changed it.
    final apex = Offset(g.pointRect(6).center.dx, g.pointRect(6).top + 3);
    expect(ring.at(apex), equals(plain.at(apex)),
        reason: 'the source highlight must not tint the whole triangle');
  });

  testWidgets('a bear-off destination fills the whole off strip (rule made '
      'legible)', (t) async {
    // Regression guard for the UX-round-1 bear-off complaint: a selected
    // overshoot bear-off source must light the tray strip so the user sees they
    // CAN bear off with a higher die. The uniform fill spans the full-width
    // strip (Task 2's layout), not a narrow right column.
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final g = BoardGeometry(_size, whiteAtBottom: true);
    final empty = BoardState(points: List<int>.filled(24, 0));
    BoardPainter make({required bool off}) => BoardPainter(
          board: empty,
          geometry: g,
          theme: BoardTheme.light,
          highlightedDestinations: off ? {CheckerMove.off} : const {},
          movingPlayer: Player.white,
        );

    final plain = await _render(t, make(off: false));
    final lit = await _render(t, make(off: true));
    final tray = g.offRect(Player.white);

    // The strip centre and both ends change from bare felt to the fill colour.
    for (final p in [
      tray.center,
      Offset(tray.left + 12, tray.center.dy),
      Offset(tray.right - 12, tray.center.dy),
    ]) {
      expect(lit.at(p), isNot(equals(plain.at(p))),
          reason: 'the off strip must fill across its whole width');
    }
  });
}
