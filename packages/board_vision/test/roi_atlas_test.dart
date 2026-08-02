import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// The atlas is a claim about where things are on a board, so most of these
/// tests are not about arithmetic: they render a board with a checker in a
/// known place, warp it through a camera-like perspective, and check that the
/// ROI the atlas hands back is the one the paint landed in. The renderer's
/// [BoardLayout] and the atlas describe the same unit rectangle from opposite
/// sides — a disagreement between them has to fail here, loudly, rather than
/// show up as a mysterious occupancy bug three tasks later.
void main() {
  group('the board coordinate system', () {
    test('the atlas addresses the rectangle the renderer draws to', () {
      // The contract Task 1 wrote its layout constants down for.
      expect(RoiAtlas.trayWidth, BoardLayout.trayWidth);
      expect(RoiAtlas.barWidth, BoardLayout.barWidth);
      expect(RoiAtlas.columnWidth, closeTo(BoardLayout.columnWidth, 1e-15));
      expect(RoiAtlas.pointLength, BoardLayout.pointLength);

      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      for (var i = 0; i < 24; i++) {
        final (left, right) = BoardLayout.pointSpan(i);
        final b = _bounds(atlas.roi(RoiId.point(i)));
        expect(b.minX, closeTo(left, 1e-12), reason: 'point $i left');
        expect(b.maxX, closeTo(right, 1e-12), reason: 'point $i right');
        final near = BoardLayout.isNearHalf(i);
        expect(b.minY, closeTo(near ? 0.5 : 0.0, 1e-12), reason: 'point $i');
        expect(b.maxY, closeTo(near ? 1.0 : 0.5, 1e-12), reason: 'point $i');
      }

      final bar = _bounds(atlas.roi(RoiId.bar));
      expect(bar.minX, closeTo(BoardLayout.barStart, 1e-12));
      expect(bar.maxX, closeTo(BoardLayout.barEnd, 1e-12));
      final tray = _bounds(atlas.roi(RoiId.offWhite));
      expect(tray.minX, closeTo(BoardLayout.rightTrayStart, 1e-12));
    });

    test('point 0 is the 1-point, bottom right against the tray', () {
      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      final p0 = _bounds(atlas.roi(RoiId.point0));
      expect(p0.maxX, closeTo(RoiAtlas.rightTrayStart, 1e-12));
      expect(p0.maxY, closeTo(1.0, 1e-12));
      // Point 24 (index 23) sits directly above it.
      final p23 = _bounds(atlas.roi(RoiId.point23));
      expect(p23.minX, closeTo(p0.minX, 1e-12));
      expect(p23.minY, closeTo(0.0, 1e-12));
    });

    test('points 5 and 18 flank the bar, 11 and 12 the far left', () {
      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      expect(_bounds(atlas.roi(RoiId.point5)).minX,
          closeTo(RoiAtlas.barEnd, 1e-12));
      expect(_bounds(atlas.roi(RoiId.point18)).minX,
          closeTo(RoiAtlas.barEnd, 1e-12));
      expect(_bounds(atlas.roi(RoiId.point6)).maxX,
          closeTo(RoiAtlas.barStart, 1e-12));
      expect(_bounds(atlas.roi(RoiId.point17)).maxX,
          closeTo(RoiAtlas.barStart, 1e-12));
      final p11 = _bounds(atlas.roi(RoiId.point11));
      final p12 = _bounds(atlas.roi(RoiId.point12));
      expect(p11.minX, closeTo(RoiAtlas.leftHalfStart, 1e-12));
      expect(p12.minX, closeTo(p11.minX, 1e-12));
    });

    test('a point ROI covers its triangle and the headroom past the tip', () {
      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      // A near point: base at the near edge, tip 0.42 in, and the ROI keeps
      // going to the midline because that is as far as a tall stack reaches.
      final near = _bounds(atlas.roi(RoiId.point0));
      expect(near.maxY, closeTo(1.0, 1e-12));
      expect(1 - RoiAtlas.pointLength, greaterThan(near.minY));
      expect(near.minY, closeTo(0.5, 1e-12));

      final far = _bounds(atlas.roi(RoiId.point12));
      expect(far.minY, closeTo(0.0, 1e-12));
      expect(RoiAtlas.pointLength, lessThan(far.maxY));
      expect(far.maxY, closeTo(0.5, 1e-12));
    });

    for (final orientation in BoardOrientation.values) {
      test('every ROI is an axis-aligned rectangle inside the unit square '
          '(${orientation.name})', () {
        final atlas = RoiAtlas.forOrientation(orientation);
        for (final id in RoiId.values) {
          final quad = atlas.roi(id);
          final b = _bounds(quad); // asserts axis-alignment
          expect(b.minX, greaterThanOrEqualTo(-1e-12), reason: '$id');
          expect(b.minY, greaterThanOrEqualTo(-1e-12), reason: '$id');
          expect(b.maxX, lessThanOrEqualTo(1 + 1e-12), reason: '$id');
          expect(b.maxY, lessThanOrEqualTo(1 + 1e-12), reason: '$id');
          expect(b.maxX - b.minX, greaterThan(0.0), reason: '$id');
          expect(b.maxY - b.minY, greaterThan(0.0), reason: '$id');
        }
      });
    }
  });

  group('a rendered checker lands in its own ROI', () {
    // The eight that pin the numbering: both ends of every quadrant, the two
    // points against the bar, and the two stacked above each other on the
    // far left and far right.
    for (final index in <int>[0, 5, 6, 11, 12, 17, 18, 23]) {
      test('one White checker on point $index', () {
        final shot = _shotWith(_points({index: 1}));
        final scores = _scan(shot, 'whiteChecker');
        final target = RoiId.point(index);

        expect(scores[target], greaterThan(0.10),
            reason: 'the checker did not fill its own ROI');
        for (final id in RoiId.values) {
          if (id == target) continue;
          expect(scores[id], lessThan(0.002), reason: '$id caught the checker');
        }
      });
    }

    test('a fifteen-checker stack stays inside its own ROI', () {
      // The tallest a point can get. The renderer compresses the spacing so
      // the stack stops exactly at the midline, which is why the ROI can stop
      // there too — and why the top of the stack shows up in the dice band.
      final shot = _shotWith(_points({0: 15}));
      final scores = _scan(shot, 'whiteChecker');

      expect(scores[RoiId.point0], greaterThan(0.75));
      for (final id in RoiId.values) {
        if (id == RoiId.point0 || id == RoiId.diceZone) continue;
        expect(scores[id], lessThan(0.002), reason: '$id caught the stack');
      }
      expect(scores[RoiId.diceZone], greaterThan(0.015),
          reason: 'the designed headroom overlap disappeared');
    });

    test('the bar and both trays hold what was rendered there', () {
      final shot = _shotWith(BoardState(
        points: List<int>.filled(24, 0),
        whiteBar: 2,
        blackBar: 2,
        whiteOff: 3,
        blackOff: 3,
      ));
      final white = _scan(shot, 'whiteChecker');
      final black = _scan(shot, 'blackChecker');

      // One bar column, both colours: White stacks from the middle toward the
      // near edge, Black toward the far one.
      expect(white[RoiId.bar], greaterThan(0.07));
      expect(black[RoiId.bar], greaterThan(0.07));

      // Both home boards are on the right, so both trays are the right-hand
      // well, split at the midline.
      expect(white[RoiId.offWhite], greaterThan(0.22));
      expect(black[RoiId.offWhite], lessThan(0.002));
      expect(black[RoiId.offBlack], greaterThan(0.22));
      expect(white[RoiId.offBlack], lessThan(0.002));

      for (var i = 0; i < 24; i++) {
        final id = RoiId.point(i);
        expect(white[id], lessThan(0.002), reason: '$id');
        expect(black[id], lessThan(0.002), reason: '$id');
      }

      // Pinned, not accidental: the innermost bar checker of each colour sits
      // in the dice band. Task 4's dice reader has to expect that.
      expect(white[RoiId.diceZone], greaterThan(0.015));
      expect(black[RoiId.diceZone], greaterThan(0.015));
    });
  });

  group('orientation', () {
    test('whiteHomeFar is the near atlas turned half a turn', () {
      final near = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      final far = RoiAtlas.forOrientation(BoardOrientation.whiteHomeFar);
      for (final id in RoiId.values) {
        final n = _bounds(near.roi(id));
        final f = _bounds(far.roi(id));
        expect(f.minX, closeTo(1 - n.maxX, 1e-12), reason: '$id minX');
        expect(f.maxX, closeTo(1 - n.minX, 1e-12), reason: '$id maxX');
        expect(f.minY, closeTo(1 - n.maxY, 1e-12), reason: '$id minY');
        expect(f.maxY, closeTo(1 - n.minY, 1e-12), reason: '$id maxY');
      }
      // Point 0 moves from the bottom-right quadrant to the top-left one:
      // hard against the left tray now, and in the far half.
      final flipped = _bounds(far.roi(RoiId.point0));
      expect(flipped.minX, closeTo(RoiAtlas.trayWidth, 1e-12));
      expect(flipped.maxX,
          closeTo(RoiAtlas.trayWidth + RoiAtlas.columnWidth, 1e-12));
      expect(flipped.minY, closeTo(0.0, 1e-12));
      expect(flipped.maxY, closeTo(RoiAtlas.midline, 1e-12));
    });

    test('the corner order survives the half turn', () {
      final far = RoiAtlas.forOrientation(BoardOrientation.whiteHomeFar);
      for (final id in RoiId.values) {
        final quad = far.roi(id);
        expect(quad.topLeft.x, lessThan(quad.topRight.x), reason: '$id');
        expect(quad.topLeft.y, lessThan(quad.bottomLeft.y), reason: '$id');
        expect(quad.bottomRight.x, closeTo(quad.topRight.x, 1e-12),
            reason: '$id');
      }
    });

    test('a checker on point 0 follows the flip end to end', () {
      final shot = _shotWith(
        _points({0: 1}),
        orientation: BoardOrientation.whiteHomeFar,
      );
      final scores = _scan(shot, 'whiteChecker',
          orientation: BoardOrientation.whiteHomeFar);
      expect(scores[RoiId.point0], greaterThan(0.10));
      for (final id in RoiId.values) {
        if (id == RoiId.point0) continue;
        expect(scores[id], lessThan(0.002), reason: '$id caught the checker');
      }

      // And the wrong atlas finds nothing there, which is what makes the
      // orientation question worth asking the user during setup.
      final wrong = _scan(shot, 'whiteChecker',
          orientation: BoardOrientation.whiteHomeNear);
      expect(wrong[RoiId.point0], lessThan(0.002));
    });
  });

  group('overlaps', () {
    test('the only overlaps are the dice band over the points and the bar',
        () {
      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      final ids = RoiId.values;
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          final area = _overlapArea(atlas.roi(ids[i]), atlas.roi(ids[j]));
          final pair = '${ids[i].name} x ${ids[j].name}';
          if (_overlapsByDesign(ids[i], ids[j])) {
            expect(area, greaterThan(0.0), reason: '$pair lost its overlap');
          } else {
            expect(area, closeTo(0.0, 1e-12), reason: '$pair overlaps');
          }
        }
      }
    });

    test('the dice band is exactly tiled by the headrooms and the bar', () {
      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      final band = atlas.roi(RoiId.diceZone);
      final bandHeight = 1 - 2 * RoiAtlas.pointLength;

      // Each point contributes one column of headroom, half the band tall.
      expect(_overlapArea(band, atlas.roi(RoiId.point0)),
          closeTo(RoiAtlas.columnWidth * bandHeight / 2, 1e-12));
      // The bar contributes its full width over the whole band.
      expect(_overlapArea(band, atlas.roi(RoiId.bar)),
          closeTo(RoiAtlas.barWidth * bandHeight, 1e-12));

      var covered = _overlapArea(band, atlas.roi(RoiId.bar));
      for (var i = 0; i < 24; i++) {
        covered += _overlapArea(band, atlas.roi(RoiId.point(i)));
      }
      expect(covered, closeTo(_area(band), 1e-12),
          reason: 'the band is meant to be exactly the felt the triangles do '
              'not reach, so the headrooms plus the bar must tile it');
    });

    test('both dice fit inside the dice band at any rotation', () {
      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      final band = _bounds(atlas.roi(RoiId.diceZone));
      // A quarter turn is the worst case, and it clears the band's edge by a
      // quarter of a pixel at the renderer's default size. That is a real
      // constraint between dieSide and pointLength, not slack.
      for (final angle in <double>[0.0, math.pi / 6, math.pi / 4, 1.0]) {
        final rendered = renderTopDown(
          board: BoardState.initial(),
          dice: Dice(6, 3),
          diceAngle: angle,
        );
        final w = rendered.image.width, h = rendered.image.height;
        for (final die in rendered.dice) {
          for (final corner in _dieCorners(die)) {
            final x = corner.x / w, y = corner.y / h;
            expect(x, inInclusiveRange(band.minX, band.maxX),
                reason: 'die ${die.value} at $angle');
            expect(y, inInclusiveRange(band.minY, band.maxY),
                reason: 'die ${die.value} at $angle');
          }
        }
      }
    });
  });

  group('RoiId', () {
    test('point(i) is the i-th value and carries the core index', () {
      for (var i = 0; i < 24; i++) {
        expect(RoiId.point(i).pointIndex, i);
        expect(RoiId.values.indexOf(RoiId.point(i)), i);
      }
      expect(RoiId.point(0), RoiId.point0);
      expect(RoiId.point(23), RoiId.point23);
    });

    test('point() rejects an index off the board', () {
      expect(() => RoiId.point(-1), throwsRangeError);
      expect(() => RoiId.point(24), throwsRangeError);
    });

    test('the regions that are not points report no index', () {
      for (final id in <RoiId>[
        RoiId.bar,
        RoiId.offWhite,
        RoiId.offBlack,
        RoiId.diceZone,
      ]) {
        expect(id.pointIndex, -1, reason: id.name);
      }
      expect(RoiId.values, hasLength(28));
    });
  });
}

// --- the test's own instruments ---------------------------------------------

/// A board with the given `{pointIndex: signedCount}` entries and nothing else.
BoardState _points(Map<int, int> counts) {
  final points = List<int>.filled(24, 0);
  counts.forEach((index, count) => points[index] = count);
  return BoardState(points: points);
}

SyntheticShot _shotWith(
  BoardState board, {
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
}) =>
    renderShot(board: board, orientation: orientation);

/// What fraction of each ROI classifies as [swatch], sampled in board space
/// and mapped into the frame by the production homography — the same path the
/// pipeline will take.
Map<RoiId, double> _scan(
  SyntheticShot shot,
  String swatch, {
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
}) {
  final h = Homography.fromQuad(shot.groundTruthQuad);
  final atlas = RoiAtlas.forOrientation(orientation);
  return <RoiId, double>{
    for (final id in RoiId.values)
      id: _fractionOf(shot, h, atlas.roi(id), swatch),
  };
}

double _fractionOf(
  SyntheticShot shot,
  Homography h,
  BoardQuad roi,
  String swatch, {
  int lattice = 48,
}) {
  final corners = roi.corners;
  var hits = 0, total = 0;
  for (var iy = 0; iy < lattice; iy++) {
    final v = (iy + 0.5) / lattice;
    for (var ix = 0; ix < lattice; ix++) {
      final u = (ix + 0.5) / lattice;
      final weights = <double>[
        (1 - u) * (1 - v),
        u * (1 - v),
        u * v,
        (1 - u) * v,
      ];
      var bx = 0.0, by = 0.0;
      for (var k = 0; k < 4; k++) {
        bx += weights[k] * corners[k].x;
        by += weights[k] * corners[k].y;
      }
      final p = h.mapToImage(Pt(bx, by));
      final x = p.x.round(), y = p.y.round();
      if (x < 0 || y < 0 || x >= shot.frame.width || y >= shot.frame.height) {
        continue;
      }
      total++;
      if (_nearestSwatch(shot.board.palette, shot.frame.pixelAt(x, y)) ==
          swatch) {
        hits++;
      }
    }
  }
  return total == 0 ? 0.0 : hits / total;
}

/// The palette swatch a sampled pixel is closest to.
///
/// The backdrop is a candidate alongside the board's own colours because the
/// warp paints the room around the board, and an ROI that reaches the board's
/// outer edge samples a sliver of it. Under the classic palette that near-black
/// backdrop is nearer a black checker than any felt or wood, so leaving it out
/// would have the trays reporting phantom checkers.
String _nearestSwatch(BoardPalette palette, (int, int, int) pixel) {
  var best = '';
  var bestDistance = double.infinity;
  final candidates = <String, int>{
    ...palette.swatches,
    'backdrop': kBackdropColor,
  };
  candidates.forEach((name, rgb) {
    final dr = ((rgb >> 16) & 0xFF) - pixel.$1;
    final dg = ((rgb >> 8) & 0xFF) - pixel.$2;
    final db = (rgb & 0xFF) - pixel.$3;
    final d = (dr * dr + dg * dg + db * db).toDouble();
    if (d < bestDistance) {
      bestDistance = d;
      best = name;
    }
  });
  return best;
}

typedef _Bounds = ({double minX, double minY, double maxX, double maxY});

/// The rectangle a ROI covers — and a check that it *is* a rectangle, since
/// every disjointness assertion below depends on that.
_Bounds _bounds(BoardQuad quad) {
  expect(quad.topLeft.y, closeTo(quad.topRight.y, 1e-12), reason: '$quad');
  expect(quad.bottomLeft.y, closeTo(quad.bottomRight.y, 1e-12),
      reason: '$quad');
  expect(quad.topLeft.x, closeTo(quad.bottomLeft.x, 1e-12), reason: '$quad');
  expect(quad.topRight.x, closeTo(quad.bottomRight.x, 1e-12), reason: '$quad');
  return (
    minX: math.min(quad.topLeft.x, quad.topRight.x),
    minY: math.min(quad.topLeft.y, quad.bottomLeft.y),
    maxX: math.max(quad.topLeft.x, quad.topRight.x),
    maxY: math.max(quad.topLeft.y, quad.bottomLeft.y),
  );
}

double _area(BoardQuad quad) {
  final b = _bounds(quad);
  return (b.maxX - b.minX) * (b.maxY - b.minY);
}

double _overlapArea(BoardQuad a, BoardQuad b) {
  final x = _bounds(a), y = _bounds(b);
  final w = math.min(x.maxX, y.maxX) - math.max(x.minX, y.minX);
  final h = math.min(x.maxY, y.maxY) - math.max(x.minY, y.minY);
  return w <= 0 || h <= 0 ? 0.0 : w * h;
}

/// The dice band is meant to overlap the points' stack headroom and the bar,
/// and nothing else. Everything not listed here has to be disjoint.
bool _overlapsByDesign(RoiId a, RoiId b) {
  final RoiId other;
  if (a == RoiId.diceZone) {
    other = b;
  } else if (b == RoiId.diceZone) {
    other = a;
  } else {
    return false;
  }
  return other == RoiId.bar || other.pointIndex >= 0;
}

List<Pt> _dieCorners(DieSpot die) {
  final half = die.side / 2;
  final cos = math.cos(die.angle), sin = math.sin(die.angle);
  return <Pt>[
    for (final (dx, dy) in <(double, double)>[
      (-half, -half),
      (half, -half),
      (half, half),
      (-half, half),
    ])
      Pt(
        die.center.x + dx * cos - dy * sin,
        die.center.y + dx * sin + dy * cos,
      ),
  ];
}
