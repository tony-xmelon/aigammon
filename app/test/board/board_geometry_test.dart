import 'dart:ui';

import 'package:aigammon_app/board/board_geometry.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(800, 600);

  Matcher offsetCloseTo(Offset o, double eps) => predicate<Offset>(
        (a) => (a.dx - o.dx).abs() < eps && (a.dy - o.dy).abs() < eps,
        'within $eps of $o',
      );

  for (final whiteAtBottom in [true, false]) {
    group('orientation whiteAtBottom=$whiteAtBottom', () {
      final g = BoardGeometry(size, whiteAtBottom: whiteAtBottom);

      test('round-trips every point centre back to its index', () {
        for (var i = 0; i < 24; i++) {
          expect(g.locationAt(g.pointRect(i).center), i,
              reason: 'point $i');
        }
      });

      test('bar centres map to CheckerMove.bar', () {
        expect(g.locationAt(g.barRect(Player.white).center), CheckerMove.bar);
        expect(g.locationAt(g.barRect(Player.black).center), CheckerMove.bar);
      });

      test('off-tray centres map to CheckerMove.off', () {
        expect(g.locationAt(g.offRect(Player.white).center), CheckerMove.off);
        expect(g.locationAt(g.offRect(Player.black).center), CheckerMove.off);
      });

      test('the middle band and outside return null', () {
        // A point-column x at the vertical centre falls in the empty gap.
        expect(g.locationAt(Offset(size.width * 0.1, size.height / 2)), isNull);
        expect(g.locationAt(const Offset(-1, -1)), isNull);
        expect(
            g.locationAt(Offset(size.width + 1, size.height + 1)), isNull);
      });

      test('five checkers stack inside the point rect', () {
        for (var i = 0; i < 24; i++) {
          final rect = g.pointRect(i);
          final r = g.checkerRadius;
          for (var s = 0; s < 5; s++) {
            final c = g.checkerCenter(i, s);
            expect(rect.inflate(0.5).contains(c), isTrue,
                reason: 'point $i checker $s centre inside');
            // Full disc inside the rect (bounded band).
            expect(c.dy - r, greaterThanOrEqualTo(rect.top - 0.5));
            expect(c.dy + r, lessThanOrEqualTo(rect.bottom + 0.5));
          }
        }
      });

      test('eight checkers still all fit (compressed)', () {
        for (var i = 0; i < 24; i++) {
          final rect = g.pointRect(i);
          final r = g.checkerRadius;
          for (var s = 0; s < 8; s++) {
            final c = g.checkerCenter(i, s);
            expect(c.dy - r, greaterThanOrEqualTo(rect.top - 0.5),
                reason: 'point $i checker $s top');
            expect(c.dy + r, lessThanOrEqualTo(rect.bottom + 0.5),
                reason: 'point $i checker $s bottom');
          }
        }
      });

      test('checker stacks grow monotonically away from the base', () {
        for (final i in [0, 12]) {
          final d0 = g.checkerCenter(i, 0).dy;
          final d1 = g.checkerCenter(i, 1).dy;
          final increasing = d1 > d0; // direction depends on orientation
          double prev = d0;
          for (var s = 1; s < 10; s++) {
            final d = g.checkerCenter(i, s).dy;
            if (increasing) {
              expect(d, greaterThan(prev - 0.001), reason: 'point $i step $s');
            } else {
              expect(d, lessThan(prev + 0.001), reason: 'point $i step $s');
            }
            prev = d;
          }
        }
      });
    });
  }

  test('flipping orientation is a 180° rotation about the centre', () {
    final bottom = BoardGeometry(size, whiteAtBottom: true);
    final top = BoardGeometry(size, whiteAtBottom: false);
    final centre = Offset(size.width, size.height);
    for (var i = 0; i < 24; i++) {
      final expected = centre - bottom.pointRect(i).center;
      expect(top.pointRect(i).center, offsetCloseTo(expected, 1e-6),
          reason: 'point $i rotated');
    }
  });

  test('point 0 sits bottom-right, point 12 sits top-left (white bottom)', () {
    final g = BoardGeometry(size, whiteAtBottom: true);
    final p0 = g.pointRect(0).center;
    expect(p0.dx, greaterThan(size.width / 2));
    expect(p0.dy, greaterThan(size.height / 2));
    final p12 = g.pointRect(12).center;
    expect(p12.dx, lessThan(size.width / 2));
    expect(p12.dy, lessThan(size.height / 2));
  });
}
