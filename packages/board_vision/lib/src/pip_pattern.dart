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
  /// This is a NOISE allowance, not a shape allowance, and the division is
  /// what keeps the test sharp: how far a session's dice drill their pips
  /// from the canon is a fact about the dice — [faceOf]'s `span` carries it,
  /// measured once per session like `BoardCalibration.dieSide` — while this
  /// covers only the centroid wobble of blurred twenty-pixel dots and the
  /// residual error of the die frame's measured aspect. Two measured
  /// pressures set it. From below: with its span given, the first real
  /// footage's true quad sits every sorted distance within 0.072 of its
  /// template. From above: the closest wrong shape has to miss — the same
  /// footage's merged six, a line of three at half the six's own pip span,
  /// misses the span-scaled three on its long run by 0.166; a quad with
  /// split extras misses the six by 0.183 at canonical span; adjacent
  /// fragment pairs miss the two by 0.207. Trying to buy the quad WITHOUT
  /// the span — a wider tolerance over canonical templates — was measured
  /// and refused: the quad's diagonal slot misses canon by 0.213, and any
  /// tolerance past 0.207 reads merged sixes as threes.
  static const double tolerance = 0.15;

  /// How far an ace's single pip may stand from its die's middle, in die
  /// sides. A true ace is central by construction; the aces the footage
  /// invented were top-face pips a third of a blob off the middle of a
  /// two-face union.
  static const double aceReach = 0.2;

  /// The face [pips] form, or null when they form none.
  ///
  /// [pips] are pip middles in the die's own frame — the unit square, one
  /// side to the unit. [span] is how wide this session's dice drill their
  /// pip square, as a share of the canonical one: real dice vary — the
  /// first real footage's hold theirs at about ±0.21 of the side against
  /// the canon's ±0.25, a span of 0.84 — and the variance is a fact about
  /// the DICE, measured once per session the way
  /// `BoardCalibration.dieSide` is, never searched for per blob: a span
  /// left free to fit each candidate would let a merged six's line of
  /// three pick the scale at which it becomes a three.
  static int? faceOf(List<Pt> pips, {double span = 1.0}) {
    final face = pips.length;
    if (face < 1 || face > 6) return null;
    if (face == 1) {
      final dx = pips.single.x - 0.5, dy = pips.single.y - 0.5;
      return math.sqrt(dx * dx + dy * dy) <= aceReach ? 1 : null;
    }

    // Clamped to the range real dice occupy — pip squares run from about
    // three quarters of the canon out to the canon itself — which is also,
    // not by accident, the range where a merged six's line of three stays
    // refusable: its miss against the three shrinks with the span, and
    // under about 0.73 it would slip inside [tolerance]. The two bounds
    // coincide because the tolerance was measured against the same dice.
    final scale = span.clamp(0.78, 1.02);
    final measured = _sortedDistances(pips);
    final expected = _sortedDistances(_canonical(face));
    for (var i = 0; i < measured.length; i++) {
      if ((measured[i] - expected[i] * scale).abs() > tolerance) return null;
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
