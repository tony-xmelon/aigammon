import 'dart:math' as math;

import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// The camera viewpoint these tests solve for: the far edge shorter than the
/// near one and the whole board rolled a little, so nothing here can pass by
/// quietly assuming an axis-aligned board.
const BoardQuad _cameraQuad = BoardQuad(
  topLeft: Pt(214, 163),
  topRight: Pt(1094, 141),
  bottomRight: Pt(1196, 787),
  bottomLeft: Pt(92, 821),
);

void main() {
  group('Homography.fromQuad', () {
    test('takes the quad corners to the unit square corners', () {
      final h = Homography.fromQuad(_cameraQuad);
      const unit = <Pt>[Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)];
      for (var i = 0; i < 4; i++) {
        final got = h.mapToBoard(_cameraQuad.corners[i]);
        expect(got.x, closeTo(unit[i].x, 1e-12), reason: 'corner $i x');
        expect(got.y, closeTo(unit[i].y, 1e-12), reason: 'corner $i y');
      }
    });

    test('an axis-aligned rectangle maps like a scale and a translate', () {
      // No projective term at all: board = ((x - 100) / 400, (y - 50) / 300).
      const rect = BoardQuad(
        topLeft: Pt(100, 50),
        topRight: Pt(500, 50),
        bottomRight: Pt(500, 350),
        bottomLeft: Pt(100, 350),
      );
      final h = Homography.fromQuad(rect);
      for (final p in const <Pt>[
        Pt(100, 50),
        Pt(300, 200),
        Pt(500, 350),
        Pt(140, 320),
        Pt(477, 61),
      ]) {
        final board = h.mapToBoard(p);
        expect(board.x, closeTo((p.x - 100) / 400, 1e-12), reason: '$p x');
        expect(board.y, closeTo((p.y - 50) / 300, 1e-12), reason: '$p y');
        final image = h.mapToImage(board);
        expect(image.x, closeTo(p.x, 1e-9), reason: '$p back x');
        expect(image.y, closeTo(p.y, 1e-9), reason: '$p back y');
      }
    });

    test('round-trips interior points through both directions', () {
      final h = Homography.fromQuad(_cameraQuad);
      final rng = math.Random(4242);
      for (var i = 0; i < 16; i++) {
        final board = Pt(rng.nextDouble(), rng.nextDouble());
        final there = h.mapToBoard(h.mapToImage(board));
        expect(there.x, closeTo(board.x, 1e-9), reason: 'board $board x');
        expect(there.y, closeTo(board.y, 1e-9), reason: 'board $board y');

        // And the other way, from a pixel known to sit inside the quad.
        final u = rng.nextDouble(), v = rng.nextDouble();
        final pixel = _insideQuad(_cameraQuad, u, v);
        final back = h.mapToImage(h.mapToBoard(pixel));
        expect(back.x, closeTo(pixel.x, 1e-6), reason: 'image $pixel x');
        expect(back.y, closeTo(pixel.y, 1e-6), reason: 'image $pixel y');
      }
    });

    test('agrees with the independently solved map in the test-bed', () {
      // The renderer carries its own minimal solver, written the other way
      // round (unit square -> image, Gauss-Jordan on an augmented matrix).
      // Two independent implementations agreeing is the point of keeping it.
      final reference = PlaneHomography.fromQuads(
        BoardQuad.rect(1, 1),
        _cameraQuad,
      );
      final h = Homography.fromQuad(_cameraQuad);
      final rng = math.Random(7);
      for (var i = 0; i < 16; i++) {
        final board = Pt(rng.nextDouble(), rng.nextDouble());
        final mine = h.mapToImage(board);
        final theirs = reference.map(board);
        expect(mine.x, closeTo(theirs.x, 1e-6), reason: 'board $board x');
        expect(mine.y, closeTo(theirs.y, 1e-6), reason: 'board $board y');

        final recovered = h.mapToBoard(theirs);
        expect(recovered.x, closeTo(board.x, 1e-9), reason: 'back $board x');
        expect(recovered.y, closeTo(board.y, 1e-9), reason: 'back $board y');
      }
    });

    test('keeps straight lines straight through the perspective', () {
      // Three collinear pixels stay collinear in board space — the property
      // that makes a homography the right model for a flat board.
      final h = Homography.fromQuad(_cameraQuad);
      final a = h.mapToBoard(const Pt(300, 300));
      final b = h.mapToBoard(const Pt(600, 420));
      final c = h.mapToBoard(const Pt(900, 540));
      final cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
      expect(cross, closeTo(0, 1e-12));
    });

    test('rejects three collinear corners', () {
      expect(
        () => Homography.fromQuad(const BoardQuad(
          topLeft: Pt(0, 0),
          topRight: Pt(10, 10),
          bottomRight: Pt(20, 20),
          bottomLeft: Pt(0, 30),
        )),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects four collinear corners', () {
      expect(
        () => Homography.fromQuad(const BoardQuad(
          topLeft: Pt(0, 0),
          topRight: Pt(10, 10),
          bottomRight: Pt(20, 20),
          bottomLeft: Pt(30, 30),
        )),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a duplicated corner', () {
      expect(
        () => Homography.fromQuad(const BoardQuad(
          topLeft: Pt(100, 100),
          topRight: Pt(100, 100),
          bottomRight: Pt(400, 380),
          bottomLeft: Pt(90, 400),
        )),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects four coincident corners', () {
      expect(
        () => Homography.fromQuad(const BoardQuad(
          topLeft: Pt(5, 5),
          topRight: Pt(5, 5),
          bottomRight: Pt(5, 5),
          bottomLeft: Pt(5, 5),
        )),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a corner that is not a finite number', () {
      expect(
        () => Homography.fromQuad(const BoardQuad(
          topLeft: Pt(0, 0),
          topRight: Pt(double.nan, 0),
          bottomRight: Pt(400, 380),
          bottomLeft: Pt(0, 400),
        )),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('survives a strongly foreshortened quad', () {
      // A far edge a fifth of the near one — steeper than any seating the
      // calibration flow will accept, and still well inside double precision.
      const steep = BoardQuad(
        topLeft: Pt(560, 200),
        topRight: Pt(720, 200),
        bottomRight: Pt(1240, 900),
        bottomLeft: Pt(40, 900),
      );
      final h = Homography.fromQuad(steep);
      final rng = math.Random(11);
      for (var i = 0; i < 8; i++) {
        final board = Pt(rng.nextDouble(), rng.nextDouble());
        final back = h.mapToBoard(h.mapToImage(board));
        expect(back.x, closeTo(board.x, 1e-9), reason: '$board x');
        expect(back.y, closeTo(board.y, 1e-9), reason: '$board y');
      }
    });

    test('a pixel on the horizon never throws — it maps far outside the '
        'unit square', () {
      // The class doc makes this a binding contract: mapToBoard never throws,
      // and callers on a hot loop reject by RANGE (exactly on the horizon the
      // division by zero is non-finite; within rounding of it the result is
      // finite but astronomically outside [0,1] — range rejection covers
      // both). Pin it, so a future guard that throws fails here rather than
      // surprising Tasks 3-9.
      //
      // The quad's left and right edges are images of the board's parallel
      // x=0 / x=1 lines, so their image-plane intersection is a VANISHING
      // POINT — a point on the horizon — computable here with plain line
      // math, no access to the matrix.
      final perspective = BoardQuad(
        topLeft: Pt(300, 100),
        topRight: Pt(900, 140),
        bottomRight: Pt(1100, 800),
        bottomLeft: Pt(100, 760),
      );
      final h = Homography.fromQuad(perspective);
      final vanish = _intersect(
        const Pt(300, 100), const Pt(100, 760), // left edge, extended
        const Pt(900, 140), const Pt(1100, 800), // right edge, extended
      );
      final mapped = h.mapToBoard(vanish);
      const wayOutside = 1e3;
      final rejectable = !mapped.x.isFinite ||
          !mapped.y.isFinite ||
          mapped.x.abs() > wayOutside ||
          mapped.y.abs() > wayOutside;
      expect(rejectable, isTrue,
          reason: 'a horizon pixel must map non-finite or far outside the '
              'unit square, got $mapped');
    });
  });
}

/// Image-plane intersection of lines (a1,a2) and (b1,b2).
Pt _intersect(Pt a1, Pt a2, Pt b1, Pt b2) {
  final d1x = a2.x - a1.x, d1y = a2.y - a1.y;
  final d2x = b2.x - b1.x, d2y = b2.y - b1.y;
  final denom = d1x * d2y - d1y * d2x;
  final t = ((b1.x - a1.x) * d2y - (b1.y - a1.y) * d2x) / denom;
  return Pt(a1.x + t * d1x, a1.y + t * d1y);
}

/// A pixel guaranteed to lie inside [quad], by bilinear blend of its corners.
Pt _insideQuad(BoardQuad quad, double u, double v) {
  final c = quad.corners;
  final w = <double>[
    (1 - u) * (1 - v),
    u * (1 - v),
    u * v,
    (1 - u) * v,
  ];
  var x = 0.0, y = 0.0;
  for (var i = 0; i < 4; i++) {
    x += w[i] * c[i].x;
    y += w[i] * c[i].y;
  }
  return Pt(x, y);
}
