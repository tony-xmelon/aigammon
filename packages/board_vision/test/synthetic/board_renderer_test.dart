import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'board_renderer.dart';

/// The renderer is test infrastructure, but Phase 1–2 accuracy work is scored
/// against it long before a real photograph exists — so it gets tests of its
/// own, and they check the two things every later suite will rely on: that a
/// checker really is painted where the renderer says it is (through the
/// perspective warp, not just in the top-down source), and that a die really
/// carries the pips it claims.
void main() {
  group('BoardLayout', () {
    test('the twelve columns, two trays and the bar tile the unit width', () {
      expect(
        BoardLayout.trayWidth * 2 +
            BoardLayout.barWidth +
            BoardLayout.columnWidth * 12,
        closeTo(1.0, 1e-12),
      );
    });

    test('point 1 sits bottom right and point 24 directly above it', () {
      final p1 = BoardLayout.pointSpan(0);
      final p24 = BoardLayout.pointSpan(23);
      expect(p1.$2, closeTo(BoardLayout.rightHalfEnd, 1e-12));
      expect(p1.$1, closeTo(p24.$1, 1e-12));
      expect(BoardLayout.isNearHalf(0), isTrue);
      expect(BoardLayout.isNearHalf(23), isFalse);
    });

    test('point 12 sits bottom left and point 13 directly above it', () {
      final p12 = BoardLayout.pointSpan(11);
      final p13 = BoardLayout.pointSpan(12);
      expect(p12.$1, closeTo(BoardLayout.leftHalfStart, 1e-12));
      expect(p12.$1, closeTo(p13.$1, 1e-12));
    });

    test('points 6 and 7 flank the bar', () {
      expect(BoardLayout.pointSpan(5).$1, closeTo(BoardLayout.barEnd, 1e-12));
      expect(BoardLayout.pointSpan(6).$2, closeTo(BoardLayout.barStart, 1e-12));
    });
  });

  group('BoardPalette', () {
    test('ships at least three boards to score perception against', () {
      expect(BoardPalette.all.length, greaterThanOrEqualTo(3));
      expect(
        BoardPalette.all.map((p) => p.name),
        containsAll(<String>['classic', 'blue-red', 'low-contrast wood']),
      );
    });

    for (final palette in BoardPalette.all) {
      test('${palette.name} keeps its swatches mutually distinguishable', () {
        // Not a style rule: a palette whose felt and point colours collide
        // exactly would make the classification assertions below vacuous.
        // 18 is the floor; "low-contrast wood" deliberately sits near it,
        // which is the whole point of shipping it.
        final swatches = palette.swatches.entries.toList();
        for (var i = 0; i < swatches.length; i++) {
          for (var j = i + 1; j < swatches.length; j++) {
            final d = _distance(
              _unpack(swatches[i].value),
              _unpack(swatches[j].value),
            );
            expect(
              d,
              greaterThanOrEqualTo(18.0),
              reason: '${swatches[i].key} and ${swatches[j].key} are $d apart',
            );
          }
        }
      });
    }
  });

  group('PlaneHomography', () {
    test('maps each source corner onto its destination corner', () {
      const dst = BoardQuad(
        topLeft: Pt(37, 11),
        topRight: Pt(410, 40),
        bottomRight: Pt(380, 290),
        bottomLeft: Pt(20, 260),
      );
      final h = PlaneHomography.fromQuads(BoardQuad.rect(100, 80), dst);
      final src = BoardQuad.rect(100, 80).corners;
      for (var i = 0; i < 4; i++) {
        final got = h.map(src[i]);
        expect(got.x, closeTo(dst.corners[i].x, 1e-9));
        expect(got.y, closeTo(dst.corners[i].y, 1e-9));
      }
    });

    test('inverted undoes map for interior points', () {
      const dst = BoardQuad(
        topLeft: Pt(37, 11),
        topRight: Pt(410, 40),
        bottomRight: Pt(380, 290),
        bottomLeft: Pt(20, 260),
      );
      final h = PlaneHomography.fromQuads(BoardQuad.rect(100, 80), dst);
      final inv = h.inverted;
      final rng = math.Random(4242);
      for (var i = 0; i < 20; i++) {
        final p = Pt(rng.nextDouble() * 100, rng.nextDouble() * 80);
        final back = inv.map(h.map(p));
        expect(back.x, closeTo(p.x, 1e-9));
        expect(back.y, closeTo(p.y, 1e-9));
      }
    });

    test('rejects a degenerate quad', () {
      expect(
        () => PlaneHomography.fromQuads(
          BoardQuad.rect(100, 80),
          const BoardQuad(
            topLeft: Pt(0, 0),
            topRight: Pt(10, 10),
            bottomRight: Pt(20, 20),
            bottomLeft: Pt(30, 30),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('renderTopDown', () {
    test('draws one spot per checker on the board, bar and trays', () {
      final board = BoardState(
        points: const [
          -2, 0, 0, 3, 0, 5, //
          0, 3, 0, 0, 0, -5, //
          2, 0, 0, 0, -3, 0, //
          -4, 0, 0, 0, 0, 0, //
        ],
        blackBar: 1,
        whiteOff: 2,
      );
      final rendered = renderTopDown(board: board);

      expect(
        rendered.checkers.where((c) => c.owner == Player.white).length,
        15,
      );
      expect(
        rendered.checkers.where((c) => c.owner == Player.black).length,
        15,
      );
      for (var i = 0; i < 24; i++) {
        final onPoint = rendered.checkers
            .where((c) => c.area == SpotArea.point && c.pointIndex == i);
        expect(onPoint.length, board.points[i].abs(), reason: 'point ${i + 1}');
      }
      expect(
        rendered.checkers
            .where((c) => c.area == SpotArea.bar && c.owner == Player.black)
            .length,
        1,
      );
      expect(
        rendered.checkers
            .where((c) => c.area == SpotArea.off && c.owner == Player.white)
            .length,
        2,
      );
    });

    test('places the start position in the standard quadrants', () {
      final rendered = renderTopDown(board: BoardState.initial());
      final w = rendered.image.width, h = rendered.image.height;
      Pt centreOf(int pointIndex) => rendered.checkers
          .firstWhere(
              (c) => c.area == SpotArea.point && c.pointIndex == pointIndex)
          .center;

      // Point 1 (2 black): near half, right of the bar.
      expect(centreOf(0).x, greaterThan(w * 0.5));
      expect(centreOf(0).y, greaterThan(h * 0.5));
      // Point 12 (5 black): near half, left of the bar.
      expect(centreOf(11).x, lessThan(w * 0.5));
      expect(centreOf(11).y, greaterThan(h * 0.5));
      // Point 13 (5 white): far half, left of the bar.
      expect(centreOf(12).x, lessThan(w * 0.5));
      expect(centreOf(12).y, lessThan(h * 0.5));
      // Point 24 (2 white): far half, right of the bar.
      expect(centreOf(23).x, greaterThan(w * 0.5));
      expect(centreOf(23).y, lessThan(h * 0.5));
    });

    test('whiteHomeFar is the same board seen from the other seat', () {
      final near = renderTopDown(board: BoardState.initial());
      final far = renderTopDown(
        board: BoardState.initial(),
        orientation: BoardOrientation.whiteHomeFar,
      );
      final w = near.image.width, h = near.image.height;
      Pt centreOf(RenderedBoard r, int i) => r.checkers
          .firstWhere((c) => c.area == SpotArea.point && c.pointIndex == i)
          .center;

      final n = centreOf(near, 0);
      final f = centreOf(far, 0);
      expect(f.x, closeTo(w - 1 - n.x, 1.5));
      expect(f.y, closeTo(h - 1 - n.y, 1.5));
    });

    test('no stack crosses the middle of the board, however tall', () {
      // 15 on facing points and a loaded bar is the worst case for the
      // stacking rule; before the spacing was expressed as a travel between
      // two explicit offsets, a multi-checker BAR stack had zero travel and
      // drew every checker on top of the last.
      final crowded = BoardState(
        points: const [
          12, 0, 0, 0, 0, 0, //
          0, 0, 0, 0, 0, 0, //
          0, 0, 0, 0, 0, 0, //
          0, 0, 0, 0, 0, -12, //
        ],
        whiteBar: 3,
        blackBar: 3,
      );
      final rendered = renderTopDown(board: crowded);
      final mid = rendered.image.height / 2;

      for (final c in rendered.checkers) {
        final near = c.area == SpotArea.bar
            ? c.owner == Player.white
            : c.area == SpotArea.off
                ? c.owner == Player.white
                : BoardLayout.isNearHalf(c.pointIndex);
        if (near) {
          expect(c.center.y - c.radius, greaterThanOrEqualTo(mid - 2),
              reason: '$c crossed the midline');
        } else {
          expect(c.center.y + c.radius, lessThanOrEqualTo(mid + 2),
              reason: '$c crossed the midline');
        }
      }

      // And no two checkers of a stack share a position.
      for (final side in <Player>[Player.white, Player.black]) {
        final bar = rendered.checkers
            .where((c) => c.area == SpotArea.bar && c.owner == side)
            .toList();
        expect(bar, hasLength(3));
        final ys = bar.map((c) => c.center.y).toSet();
        expect(ys, hasLength(3), reason: 'bar checkers piled up: $bar');
      }
    });

    test('pointSpan rejects an index off the board', () {
      expect(() => BoardLayout.pointSpan(-1), throwsRangeError);
      expect(() => BoardLayout.pointSpan(24), throwsRangeError);
    });

    test('lightingGain scales the rendered image toward black', () {
      final bright = renderTopDown(board: BoardState.initial());
      final dim =
          renderTopDown(board: BoardState.initial(), lightingGain: 0.5);
      final spot = bright.checkers
          .firstWhere((c) => c.owner == Player.white && c.area == SpotArea.point)
          .center;
      final x = spot.x.round(), y = spot.y.round();
      final (br, bg, bb) = topDownPixel(bright, x, y);
      final (dr, dg, db) = topDownPixel(dim, x, y);
      expect(dr, closeTo(br * 0.5, 1));
      expect(dg, closeTo(bg * 0.5, 1));
      expect(db, closeTo(bb * 0.5, 1));
    });
  });

  group('warpToQuad', () {
    test('warping onto the source rectangle reproduces the source', () {
      final rendered = renderTopDown(board: BoardState.initial());
      final src = rendered.image;
      final warped = warpToQuad(
        src,
        BoardQuad.rect(src.width.toDouble(), src.height.toDouble()),
        outWidth: src.width,
        outHeight: src.height,
      );
      expect(warped.frame.width, src.width);
      expect(warped.frame.height, src.height);
      for (final p in <Pt>[
        const Pt(0, 0),
        Pt(src.width - 1, 0),
        Pt(0, src.height - 1),
        Pt(src.width - 1, src.height - 1),
        Pt(src.width / 3, src.height / 4),
        Pt(src.width * 0.77, src.height * 0.62),
      ]) {
        final x = p.x.round(), y = p.y.round();
        final expected = topDownPixel(rendered, x, y);
        final got = warped.frame.pixelAt(x, y);
        // A tolerance of 1 for the bilinear tap landing a hair off an exact
        // integer coordinate; the mapping itself is the identity.
        expect(got.$1, closeTo(expected.$1, 1), reason: 'red at $x,$y');
        expect(got.$2, closeTo(expected.$2, 1), reason: 'green at $x,$y');
        expect(got.$3, closeTo(expected.$3, 1), reason: 'blue at $x,$y');
      }
    });

    test('fills everything outside the quad with the backdrop', () {
      final rendered = renderTopDown(board: BoardState.initial());
      final warped = warpToQuad(
        rendered.image,
        const BoardQuad(
          topLeft: Pt(200, 200),
          topRight: Pt(400, 200),
          bottomRight: Pt(400, 340),
          bottomLeft: Pt(200, 340),
        ),
        outWidth: 640,
        outHeight: 480,
        backgroundColor: 0x102030,
      );
      expect(warped.frame.pixelAt(5, 5), (0x10, 0x20, 0x30));
      expect(warped.frame.pixelAt(630, 470), (0x10, 0x20, 0x30));
      expect(warped.groundTruthQuad.topLeft, const Pt(200, 200));
    });
  });

  group('renderShot', () {
    for (final palette in BoardPalette.all) {
      test('every checker centre survives the warp as its own colour '
          '(${palette.name})', () {
        final shot = renderShot(
          board: BoardState.initial(),
          palette: palette,
        );
        expect(shot.board.checkers, hasLength(30));

        for (final spot in shot.board.checkers) {
          final p = shot.toFrame(spot.center);
          final x = p.x.round(), y = p.y.round();
          expect(x, inInclusiveRange(0, shot.frame.width - 1));
          expect(y, inInclusiveRange(0, shot.frame.height - 1));
          final swatch = _nearestSwatch(palette, shot.frame.pixelAt(x, y));
          expect(
            swatch,
            spot.owner == Player.white ? 'whiteChecker' : 'blackChecker',
            reason: 'checker ${spot.indexInStack} on ${spot.area.name} '
                '${spot.pointIndex} sampled at $x,$y',
          );
        }
      });
    }

    test('the ground-truth quad is the quad the frame was warped onto', () {
      const quad = BoardQuad(
        topLeft: Pt(120, 90),
        topRight: Pt(900, 70),
        bottomRight: Pt(980, 620),
        bottomLeft: Pt(60, 650),
      );
      final shot = renderShot(
        board: BoardState.initial(),
        quad: quad,
        outWidth: 1024,
        outHeight: 768,
      );
      expect(shot.groundTruthQuad, quad);
      expect(shot.frame.width, 1024);
      expect(shot.frame.height, 768);
    });
  });

  group('dice', () {
    test('a 6-3 renders six pips on the first die and three on the second',
        () {
      final shot = renderShot(
        board: BoardState.initial(),
        dice: Dice(6, 3),
      );
      expect(shot.board.dice, hasLength(2));
      expect(shot.board.dice.map((d) => d.value), [6, 3]);
      expect(_countPipBlobs(shot, shot.board.dice[0]), 6);
      expect(_countPipBlobs(shot, shot.board.dice[1]), 3);
    });

    test('every face value renders its own pip count', () {
      for (var a = 1; a <= 6; a++) {
        final b = 7 - a;
        final shot = renderShot(board: BoardState.initial(), dice: Dice(a, b));
        expect(_countPipBlobs(shot, shot.board.dice[0]), a, reason: 'die $a');
        expect(_countPipBlobs(shot, shot.board.dice[1]), b, reason: 'die $b');
      }
    });

    test('no dice are drawn when none are given', () {
      final shot = renderShot(board: BoardState.initial());
      expect(shot.board.dice, isEmpty);
    });

    test('placements put any number of dice anywhere, at any angle', () {
      // The dice reader has to FIND dice, not be handed them in the one spot
      // the default path always uses — and it has to answer "not two dice" for
      // one and for three. Board space in, top-down pixels out.
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: <DicePlacement>[
          DicePlacement(face: 4, center: const Pt(0.30, 0.47)),
          DicePlacement(
            face: 2,
            center: const Pt(0.62, 0.53),
            angle: math.pi / 4,
          ),
          DicePlacement(face: 6, center: const Pt(0.80, 0.50)),
        ],
      );

      expect(shot.board.dice, hasLength(3));
      expect(shot.board.dice.map((d) => d.value), <int>[4, 2, 6]);
      final w = shot.board.image.width, h = shot.board.image.height;
      expect(shot.board.dice[0].center.x, closeTo(0.30 * w, 1));
      expect(shot.board.dice[0].center.y, closeTo(0.47 * h, 1));
      expect(shot.board.dice[1].angle, closeTo(math.pi / 4, 1e-9));
      for (final die in shot.board.dice) {
        expect(_countPipBlobs(shot, die), die.value, reason: '$die');
      }
    });

    test('the dice land in the right half, clear of the start position', () {
      final shot = renderShot(board: BoardState.initial(), dice: Dice(5, 2));
      final w = shot.board.image.width;
      for (final die in shot.board.dice) {
        expect(die.center.x, greaterThan(w * BoardLayout.rightHalfStart));
        expect(die.center.x, lessThan(w * BoardLayout.rightHalfEnd));
      }
      // Never overlapping a checker the renderer drew.
      for (final die in shot.board.dice) {
        for (final c in shot.board.checkers) {
          final dx = (die.center.x - c.center.x).abs();
          final dy = (die.center.y - c.center.y).abs();
          expect(
            dx < die.side / 2 + c.radius && dy < die.side / 2 + c.radius,
            isFalse,
            reason: 'die at ${die.center} overlaps a checker at ${c.center}',
          );
        }
      }
    });
  });
}

(int, int, int) _unpack(int rgb) =>
    ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

double _distance((int, int, int) a, (int, int, int) b) {
  final dr = (a.$1 - b.$1).toDouble();
  final dg = (a.$2 - b.$2).toDouble();
  final db = (a.$3 - b.$3).toDouble();
  return math.sqrt(dr * dr + dg * dg + db * db);
}

/// Names the palette swatch a sampled pixel is closest to, which is the
/// "classifies to its palette colour" check the plan asks Task 1 for.
String _nearestSwatch(BoardPalette palette, (int, int, int) pixel) {
  var best = '';
  var bestDistance = double.infinity;
  palette.swatches.forEach((name, rgb) {
    final d = _distance(_unpack(rgb), pixel);
    if (d < bestDistance) {
      bestDistance = d;
      best = name;
    }
  });
  return best;
}

double _luma(int r, int g, int b) => 0.299 * r + 0.587 * g + 0.114 * b;

/// Crude connected-component count of dark blobs inside one die's face, run
/// on the WARPED frame so the count exercises the perspective sampling too.
///
/// Deliberately naive — this is the test's own yardstick, not a candidate for
/// the pip reader in `lib/`. The die's interior is found by inverse-mapping
/// each frame pixel back into top-down space, so the region is exact rather
/// than a bounding-box approximation, and only the middle 86% of the face is
/// considered so the body/felt boundary can never register as a blob.
int _countPipBlobs(SyntheticShot shot, DieSpot die) {
  final inv = shot.topDownToFrame.inverted;
  final half = die.side / 2;
  final inner = half * 0.86;
  final cos = math.cos(die.angle), sin = math.sin(die.angle);

  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (final (dx, dy) in <(double, double)>[
    (-half, -half),
    (half, -half),
    (half, half),
    (-half, half),
  ]) {
    final corner = shot.toFrame(Pt(
      die.center.x + dx * cos - dy * sin,
      die.center.y + dx * sin + dy * cos,
    ));
    minX = math.min(minX, corner.x);
    maxX = math.max(maxX, corner.x);
    minY = math.min(minY, corner.y);
    maxY = math.max(maxY, corner.y);
  }
  final x0 = minX.floor().clamp(0, shot.frame.width - 1);
  final x1 = maxX.ceil().clamp(0, shot.frame.width - 1);
  final y0 = minY.floor().clamp(0, shot.frame.height - 1);
  final y1 = maxY.ceil().clamp(0, shot.frame.height - 1);

  final palette = shot.board.palette;
  final bodyRgb = _unpack(palette.dieBody);
  final pipRgb = _unpack(palette.diePip);
  final threshold = (_luma(bodyRgb.$1, bodyRgb.$2, bodyRgb.$3) +
          _luma(pipRgb.$1, pipRgb.$2, pipRgb.$3)) /
      2;

  final w = x1 - x0 + 1, h = y1 - y0 + 1;
  final dark = List<bool>.filled(w * h, false);
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final s = inv.map(Pt(x.toDouble(), y.toDouble()));
      final dx = s.x - die.center.x, dy = s.y - die.center.y;
      final lx = dx * cos + dy * sin, ly = -dx * sin + dy * cos;
      if (lx.abs() > inner || ly.abs() > inner) continue;
      final px = shot.frame.pixelAt(x, y);
      if (_luma(px.$1, px.$2, px.$3) < threshold) {
        dark[(y - y0) * w + (x - x0)] = true;
      }
    }
  }

  var blobs = 0;
  for (var i = 0; i < dark.length; i++) {
    if (!dark[i]) continue;
    var size = 0;
    final stack = <int>[i];
    dark[i] = false;
    while (stack.isNotEmpty) {
      final k = stack.removeLast();
      size++;
      final kx = k % w, ky = k ~/ w;
      for (final (nx, ny) in <(int, int)>[
        (kx - 1, ky),
        (kx + 1, ky),
        (kx, ky - 1),
        (kx, ky + 1),
      ]) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final n = ny * w + nx;
        if (!dark[n]) continue;
        dark[n] = false;
        stack.add(n);
      }
    }
    // Single stray pixels are sampling noise, not pips.
    if (size >= 8) blobs++;
  }
  return blobs;
}
