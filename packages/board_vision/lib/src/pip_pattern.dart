import 'dart:math' as math;

import 'geometry_types.dart';

/// Whether some dark dots stand where a die face's pips stand.
///
/// ## Why counting was not enough
///
/// The dice reader used to read a face by counting the dark dots inside a
/// candidate blob, and the first real footage showed what counting is worth
/// at twenty-two pixels a die: a six whose two pip columns blur together
/// counts three, a die tilted far enough to show two faces counts the union
/// of both faces' pips, and a dot split by grain counts twice. Every one of
/// those wrong counts is a legal-looking face, and two of them make a wrong
/// roll — measured on the footage's stable windows: a true 6 read as 3, a
/// pair of tilted aces read 1-1 at a confidence of 0.32, a true 5-6 offered
/// as smaller faces. A wrong roll is folded into the authoritative game
/// state, which is the one thing the reader exists to prevent.
///
/// A pip pattern is a SHAPE, though, and the shapes are universal: every die
/// ever made puts its pips in the same places. So the face is now read as
/// geometry — the dots must stand where that face's pips stand, at the right
/// distances for a die of this size, at any rotation and either handedness —
/// and dots that stand anywhere else are not a face, whatever they count.
///
/// ## The mechanics
///
/// Positions arrive in the DIE'S OWN FRAME: the unit square, one die side to
/// the unit, both axes — the caller divides its board-space measurements by
/// the die's own extents, which is what makes the test blind to where the
/// die is, how big boards are, and the anisotropy of board space. Faces two
/// to six are matched on their sorted pairwise-distance profile, which no
/// rotation, reflection or translation can move; the profile also fixes the
/// SCALE, so a pattern of the right shape at half the size — a fragment's
/// dots — fails exactly like a wrong shape. The ace has no pairwise distance
/// to its name and is held to the one thing true of every ace instead: its
/// pip stands in the middle of its die.
class PipPattern {
  /// How far a measured pairwise distance may sit from the face's own, in
  /// die sides.
  ///
  /// Two measured pressures set it. From below: the caller's die frame is
  /// only as true as its estimate of a die's height in board units, and that
  /// estimate carries the camera's own foreshortening — on the first real
  /// footage the framed patterns arrive compressed to about 0.74 of a die
  /// frame, which puts a quad's vertical pairs 0.13 from their canonical
  /// 0.5. From above: the closest wrong shapes the footage produced still
  /// have to miss — a merged six's line of three misses its long span by
  /// 0.21, a fragment's two adjacent dots miss the corner-to-corner two by
  /// 0.21, a quad with split extras misses the six by 0.18. So 0.15: real
  /// compression inside, every measured wrong shape outside. The pip
  /// centroid wobble of a blurred twenty-pixel die (under a twentieth of a
  /// side per dot) rides within the same margin.
  static const double tolerance = 0.15;

  /// How far an ace's single pip may stand from its die's middle, in die
  /// sides. A true ace is central by construction; the aces the footage
  /// invented were top-face pips a third of a blob off the middle of a
  /// two-face union.
  static const double aceReach = 0.2;

  /// The face [pips] form, or null when they form none.
  ///
  /// [pips] are pip middles in the die's own frame — the unit square, one
  /// side to the unit.
  static int? faceOf(List<Pt> pips) {
    final face = pips.length;
    if (face < 1 || face > 6) return null;
    if (face == 1) {
      final dx = pips.single.x - 0.5, dy = pips.single.y - 0.5;
      return math.sqrt(dx * dx + dy * dy) <= aceReach ? 1 : null;
    }

    final measured = _sortedDistances(pips);
    final expected = _sortedDistances(_canonical(face));
    for (var i = 0; i < measured.length; i++) {
      if ((measured[i] - expected[i]).abs() > tolerance) return null;
    }
    return face;
  }

  /// Where face [face]'s pips stand, in the unit die frame.
  static List<Pt> _canonical(int face) {
    const center = Pt(0.5, 0.5);
    const diagonal = <Pt>[Pt(0.25, 0.25), Pt(0.75, 0.75)];
    const corners = <Pt>[...diagonal, Pt(0.75, 0.25), Pt(0.25, 0.75)];
    const middles = <Pt>[Pt(0.25, 0.5), Pt(0.75, 0.5)];
    return switch (face) {
      2 => diagonal,
      3 => const <Pt>[...diagonal, center],
      4 => corners,
      5 => const <Pt>[...corners, center],
      _ => const <Pt>[...corners, ...middles],
    };
  }

  static List<double> _sortedDistances(List<Pt> pips) {
    final out = <double>[];
    for (var a = 0; a < pips.length; a++) {
      for (var b = a + 1; b < pips.length; b++) {
        final dx = pips[a].x - pips[b].x, dy = pips[a].y - pips[b].y;
        out.add(math.sqrt(dx * dx + dy * dy));
      }
    }
    return out..sort();
  }
}
