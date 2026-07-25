import 'dart:ui';

import 'package:aigammon_app/board/board_geometry.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(800, 600);

  /// A phone-portrait board: what [BoardView] hands the geometry on a 390pt
  /// phone — the slot's full width at the tallest allowed aspect (0.62). Every
  /// invariant below must hold on a board TALLER than it is wide.
  const portrait = Size(374, 603);

  /// A SQUARE board (aspect 1.0), the regime BETWEEN the two above: past ~1.07
  /// the point band sets the checker size (as at 800x600), below ~0.67 the
  /// triangle cap kicks in (as in portrait). A square board sits in neither, so
  /// it pins the boundaries — the checker is column-bound but the triangles are
  /// still the full 44% band.
  const square = Size(700, 700);

  Matcher offsetCloseTo(Offset o, double eps) => predicate<Offset>(
        (a) => (a.dx - o.dx).abs() < eps && (a.dy - o.dy).abs() < eps,
        'within $eps of $o',
      );

  /// The invariants EVERY board must satisfy whatever its shape — registered
  /// once per (size, orientation) pair below.
  void boardInvariants(Size boardSize, bool whiteAtBottom) {
    group('${boardSize.width.toInt()}x${boardSize.height.toInt()} '
        'orientation whiteAtBottom=$whiteAtBottom', () {
      final g = BoardGeometry(boardSize, whiteAtBottom: whiteAtBottom);

      test('round-trips every point centre back to its index', () {
        for (var i = 0; i < 24; i++) {
          expect(g.locationAt(g.pointRect(i).center), i, reason: 'point $i');
        }
      });

      test('bar centres map to CheckerMove.bar', () {
        expect(g.locationAt(g.barRect(Player.white).center), CheckerMove.bar);
        expect(g.locationAt(g.barRect(Player.black).center), CheckerMove.bar);
      });

      test('off-tray (strip) centres map to CheckerMove.off', () {
        expect(g.locationAt(g.offRect(Player.white).center), CheckerMove.off);
        expect(g.locationAt(g.offRect(Player.black).center), CheckerMove.off);
      });

      test('both tray strips (top and bottom) map to off', () {
        // Any x across a strip resolves to the (unambiguous) bear-off.
        for (final frac in [0.05, 0.5, 0.95]) {
          expect(g.locationAt(Offset(boardSize.width * frac, boardSize.height * 0.01)),
              CheckerMove.off);
          expect(g.locationAt(Offset(boardSize.width * frac, boardSize.height * 0.99)),
              CheckerMove.off);
        }
      });

      test('the middle gap and outside return null', () {
        // A point-column x at the vertical centre falls in the empty gap.
        expect(g.locationAt(Offset(boardSize.width * 0.1, boardSize.height / 2)), isNull);
        expect(g.locationAt(const Offset(-1, -1)), isNull);
        expect(g.locationAt(Offset(boardSize.width + 1, boardSize.height + 1)), isNull);
      });

      test('dice pairs sit clear of the bar and every point', () {
        final barUnion = g
            .barRect(Player.white)
            .expandToInclude(g.barRect(Player.black));
        for (final mover in Player.values) {
          final moverRect = g.diceRect(mover, mover: mover);
          final waiterRect = g.diceRect(mover.opponent, mover: mover);
          for (final r in [moverRect, waiterRect]) {
            // Inside the board bounds.
            expect(r.left, greaterThanOrEqualTo(-0.5));
            expect(r.right, lessThanOrEqualTo(boardSize.width + 0.5));
            // Clear of the central bar strip.
            expect(r.overlaps(barUnion), isFalse, reason: 'dice overlap bar');
            // Clear of every triangle — dice live in the empty middle gap.
            for (var i = 0; i < 24; i++) {
              expect(r.overlaps(g.pointRect(i)), isFalse,
                  reason: 'dice overlap point $i');
            }
          }
          // The mover and waiter pairs never collide.
          expect(moverRect.overlaps(waiterRect), isFalse,
              reason: 'the two dice pairs overlap');
        }
      });

      test('five checkers stack inside the point rect at full spacing', () {
        for (var i = 0; i < 24; i++) {
          final rect = g.pointRect(i);
          final r = g.checkerRadius;
          for (var s = 0; s < 5; s++) {
            final c = g.checkerCenter(i, s, 5);
            expect(rect.inflate(0.5).contains(c), isTrue,
                reason: 'point $i checker $s centre inside');
            // Full disc inside the rect (bounded band).
            expect(c.dy - r, greaterThanOrEqualTo(rect.top - 0.5));
            expect(c.dy + r, lessThanOrEqualTo(rect.bottom + 0.5));
          }
        }
      });

      test('fifteen checkers still all fit (compressed)', () {
        for (var i = 0; i < 24; i++) {
          final rect = g.pointRect(i);
          final r = g.checkerRadius;
          for (var s = 0; s < 15; s++) {
            final c = g.checkerCenter(i, s, 15);
            expect(c.dy - r, greaterThanOrEqualTo(rect.top - 0.5),
                reason: 'point $i checker $s top');
            expect(c.dy + r, lessThanOrEqualTo(rect.bottom + 0.5),
                reason: 'point $i checker $s bottom');
          }
        }
      });

      test('checker stacks grow monotonically away from the base', () {
        for (final i in [0, 12]) {
          final d0 = g.checkerCenter(i, 0, 10).dy;
          final d1 = g.checkerCenter(i, 1, 10).dy;
          final increasing = d1 > d0; // direction depends on orientation
          double prev = d0;
          for (var s = 1; s < 10; s++) {
            final d = g.checkerCenter(i, s, 10).dy;
            if (increasing) {
              expect(d, greaterThan(prev - 0.001), reason: 'point $i step $s');
            } else {
              expect(d, lessThan(prev + 0.001), reason: 'point $i step $s');
            }
            prev = d;
          }
        }
      });

      test('first five checkers never overlap; the sixth compresses', () {
        final twoR = g.checkerRadius * 2;
        for (final i in [0, 5, 12, 23]) {
          // Count <= 5: consecutive centres are a full diameter apart.
          for (var count = 2; count <= 5; count++) {
            for (var s = 0; s + 1 < count; s++) {
              final gap = (g.checkerCenter(i, s + 1, count) -
                      g.checkerCenter(i, s, count))
                  .distance;
              expect(gap, greaterThanOrEqualTo(twoR - 1e-6),
                  reason: 'point $i count $count gap $s');
            }
          }
          // Count 6 (and up): the stack compresses below a full diameter.
          final gap6 =
              (g.checkerCenter(i, 1, 6) - g.checkerCenter(i, 0, 6)).distance;
          expect(gap6, lessThan(twoR),
              reason: 'point $i six-stack should compress');
        }
      });

      test('a checker fits its column and a five-stack fits its point', () {
        final colWidth = boardSize.width * (1 - 0.08) / 12;
        expect(g.checkerRadius * 2, lessThanOrEqualTo(colWidth),
            reason: 'checkers must not spill into the neighbouring column');
        // Ten radii of travel: five checkers at full spacing.
        expect(g.pointRect(0).height,
            greaterThanOrEqualTo(g.checkerRadius * 10 - 1e-6),
            reason: 'a point must hold five checkers unsqueezed');
        // The bar strip is wide enough for a beaten checker to rest on.
        expect(g.checkerRadius * 2,
            lessThanOrEqualTo(g.barRect(Player.white).width),
            reason: 'a checker must fit the bar');
      });
    });
  }

  for (final boardSize in [size, square, portrait]) {
    for (final whiteAtBottom in [true, false]) {
      boardInvariants(boardSize, whiteAtBottom);
    }
  }

  test('a square board is the middle regime: column-bound, triangles uncapped',
      () {
    final g = BoardGeometry(square, whiteAtBottom: true);
    final colWidth = square.width * (1 - 0.08) / 12;
    expect(g.checkerRadius, closeTo(colWidth * 0.46, 1e-6),
        reason: 'below an aspect of ~1.07 the column sets the checker size');
    expect(g.pointRect(0).height, closeTo(square.height * 0.86 * 0.44, 1e-6),
        reason: 'above an aspect of ~0.67 the triangle cap does not bind');
  });

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

  test('the mover dice sit right of the bar, the waiter left (white bottom)',
      () {
    final g = BoardGeometry(size, whiteAtBottom: true);
    for (final mover in Player.values) {
      final moverRect = g.diceRect(mover, mover: mover);
      final waiterRect = g.diceRect(mover.opponent, mover: mover);
      expect(moverRect.center.dx, greaterThan(size.width / 2),
          reason: 'mover pair in the right half');
      expect(waiterRect.center.dx, lessThan(size.width / 2),
          reason: 'waiter pair mirrored in the left half');
      // Vertically both sit in the empty middle band (near centre).
      expect(moverRect.center.dy, closeTo(size.height / 2, 1e-6));
      expect(waiterRect.center.dy, closeTo(size.height / 2, 1e-6));
    }
  });

  test('the board fills the full width symmetrically (no side tray)', () {
    final g = BoardGeometry(size, whiteAtBottom: true);
    // Leftmost columns touch x=0; rightmost columns touch x=width. Left and
    // right margins are equal (both ~0) — the symmetric full-width board.
    expect(g.pointRect(11).left, closeTo(0, 1e-6), reason: 'bottom-left col');
    expect(g.pointRect(12).left, closeTo(0, 1e-6), reason: 'top-left col');
    expect(g.pointRect(0).right, closeTo(size.width, 1e-6),
        reason: 'bottom-right col');
    expect(g.pointRect(23).right, closeTo(size.width, 1e-6),
        reason: 'top-right col');
    // pointRect(0) mirrors pointRect(11) about the vertical centre line.
    final leftMargin = g.pointRect(11).left;
    final rightMargin = size.width - g.pointRect(0).right;
    expect(leftMargin, closeTo(rightMargin, 1e-6));
  });

  test('bear-off trays are full-width top/bottom strips, orientation-aware', () {
    final bottom = BoardGeometry(size, whiteAtBottom: true);
    // White (local bottom) bears off toward the BOTTOM strip; Black the TOP.
    final whiteTray = bottom.offRect(Player.white);
    final blackTray = bottom.offRect(Player.black);
    expect(whiteTray.width, closeTo(size.width, 1e-6));
    expect(blackTray.width, closeTo(size.width, 1e-6));
    expect(whiteTray.top, greaterThan(size.height / 2), reason: 'white bottom');
    expect(blackTray.bottom, lessThan(size.height / 2), reason: 'black top');
    // The strips do not overlap the point bands (they sit outside the board).
    expect(whiteTray.top, greaterThanOrEqualTo(bottom.pointRect(0).bottom - 1));

    // Flipping swaps the sides: White's tray moves to the top.
    final top = BoardGeometry(size, whiteAtBottom: false);
    expect(top.offRect(Player.white).bottom, lessThan(size.height / 2));
    expect(top.offRect(Player.black).top, greaterThan(size.height / 2));
  });

  // --- Portrait (tall board) adaptation ---------------------------------------

  group('portrait board', () {
    final tall = BoardGeometry(portrait, whiteAtBottom: true);
    final wide = BoardGeometry(size, whiteAtBottom: true);

    test('the checker is sized by the COLUMN, not the height', () {
      // On a tall board a 12th of the width is the scarce dimension: the disc
      // fills its column (92% of it) instead of a tenth of the point band.
      final colWidth = portrait.width * (1 - 0.08) / 12;
      expect(tall.checkerRadius, closeTo(colWidth * 0.46, 1e-6));
      // The 800x600 board is the other regime: the point band binds there.
      final wideCol = size.width * (1 - 0.08) / 12;
      expect(wide.checkerRadius, lessThan(wideCol * 0.46));
    });

    test('triangles are capped, so the middle band grows instead of spikes',
        () {
      final band = portrait.height * 0.86;
      final pointHeight = tall.pointRect(0).height;
      // Capped well under the 44%-of-band a landscape board would take.
      expect(pointHeight, lessThan(band * 0.44));
      expect(pointHeight, closeTo(tall.checkerRadius * 16, 1e-6));
      // The surplus lands in the empty middle band, which stays comfortably
      // taller than a die.
      final middle = band - 2 * pointHeight;
      expect(middle, greaterThan(tall.diceSide));
      // The landscape board is NOT capped: it keeps the full 44% band.
      expect(wide.pointRect(0).height, closeTo(size.height * 0.86 * 0.44, 1e-6));
    });

    test('dice grow with the middle band and stay clear of it', () {
      // Bigger than the historical 2.2 radii — the roomier band pays for it.
      expect(tall.diceSide, greaterThan(tall.checkerRadius * 2.2));
      expect(tall.diceSide, lessThanOrEqualTo(tall.checkerRadius * 3.2 + 1e-9));
      // The whole PAIR clears the bar and the right edge.
      final pair = tall.diceRect(Player.white, mover: Player.white);
      expect(pair.left, greaterThan(tall.barRect(Player.white).right));
      expect(pair.right, lessThan(portrait.width));
      // The landscape board's narrow band still binds first (unchanged look).
      expect(wide.diceSide, closeTo(wide.checkerRadius * 2.2, 1.0));
    });

    test('the board is taller than it is wide and still round-trips', () {
      expect(portrait.height, greaterThan(portrait.width));
      for (var i = 0; i < 24; i++) {
        expect(tall.locationAt(tall.pointRect(i).center), i, reason: 'point $i');
      }
      expect(tall.locationAt(tall.barRect(Player.white).center),
          CheckerMove.bar);
      expect(tall.locationAt(tall.offRect(Player.white).center),
          CheckerMove.off);
    });
  });
}
