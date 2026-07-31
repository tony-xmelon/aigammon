// Direct unit tests for the two public helpers extracted from
// MatchCubeAdvisor: matchEquityAfter (the value function over match scores) and
// matchEquityOfDistribution (the six-bucket outcome fold). Both are shared by
// the advisor's E() and the match-aware AI resign policy.
//
// PURE test: no native library. Expected numbers are looked up from the shipped
// MatchEquityTable (reading the table in a test is fine) and, for the
// distribution helper, reuse the by-hand 5-away/5-away gammonful fixture from
// match_cube_advisor_test.dart (E(1) = 0.534372, E(2) = 0.5762685).
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('matchEquityAfter', () {
    test('terminal scores clamp to 1.0 / 0.0', () {
      // Mover reached 0-away (won) regardless of opponent.
      expect(matchEquityAfter(0, 5, crawfordPlayed: false), 1.0);
      expect(matchEquityAfter(-2, 5, crawfordPlayed: false), 1.0);
      // Opponent reached 0-away (mover lost).
      expect(matchEquityAfter(5, 0, crawfordPlayed: false), 0.0);
      expect(matchEquityAfter(5, -1, crawfordPlayed: false), 0.0);
      // A win check takes precedence when both are non-positive.
      expect(matchEquityAfter(0, 0, crawfordPlayed: false), 1.0);
    });

    test('pre-Crawford reads the preCrawford table', () {
      expect(matchEquityAfter(2, 2, crawfordPlayed: false),
          MatchEquityTable.preCrawford(2, 2));
      expect(matchEquityAfter(2, 2, crawfordPlayed: false), closeTo(0.5, 1e-12));
      expect(matchEquityAfter(1, 2, crawfordPlayed: false),
          closeTo(0.67736, 1e-12));
      expect(matchEquityAfter(14, 15, crawfordPlayed: false),
          closeTo(MatchEquityTable.preCrawford(14, 15), 1e-12));
    });

    test('post-Crawford uses the postCrawford column via the 1-away side', () {
      // Opponent is the 1-away leader; mover trails aRem away -> post(aRem).
      expect(matchEquityAfter(3, 1, crawfordPlayed: true),
          closeTo(MatchEquityTable.postCrawford(3), 1e-12));
      expect(
          matchEquityAfter(3, 1, crawfordPlayed: true), closeTo(0.32264, 1e-12));
      // Mover is the 1-away leader; opponent trails bRem -> 1 - post(bRem).
      expect(matchEquityAfter(1, 3, crawfordPlayed: true),
          closeTo(1.0 - MatchEquityTable.postCrawford(3), 1e-12));
      // Double match point (1-away/1-away) is exactly 0.5 (post(1) == 0.5).
      expect(matchEquityAfter(1, 1, crawfordPlayed: true), closeTo(0.5, 1e-12));
    });

    // An away score above the table's length is REACHABLE from outside: a LAN
    // or online peer names the match length, and nothing between the wire and
    // here re-checks it against the table. Throwing there would take the whole
    // game down, so the helper clamps to the longest row it has — the equity
    // curve is flat out there (25-away/25-away is 0.5 and moving either side
    // further barely shifts it), which makes the clamp a fair reading rather
    // than a lie.
    const beyond = MatchEquityTable.maxAway + 1;

    test('an away score past the table clamps instead of throwing', () {
      expect(matchEquityAfter(beyond, 5, crawfordPlayed: false),
          closeTo(MatchEquityTable.preCrawford(MatchEquityTable.maxAway, 5),
              1e-12));
      expect(matchEquityAfter(5, 1000, crawfordPlayed: false),
          closeTo(MatchEquityTable.preCrawford(5, MatchEquityTable.maxAway),
              1e-12));
      // Both sides past the end: still the table's far corner, still 0.5.
      expect(matchEquityAfter(beyond, beyond, crawfordPlayed: false),
          closeTo(0.5, 1e-12));
    });

    test('the post-Crawford column clamps too', () {
      expect(matchEquityAfter(beyond, 1, crawfordPlayed: true),
          closeTo(MatchEquityTable.postCrawford(MatchEquityTable.maxAway),
              1e-12));
      expect(matchEquityAfter(1, beyond, crawfordPlayed: true),
          closeTo(
              1.0 - MatchEquityTable.postCrawford(MatchEquityTable.maxAway),
              1e-12));
    });

    test('a clamped equity still reads as a probability', () {
      final e = matchEquityAfter(500, 500, crawfordPlayed: false);
      expect(e, inInclusiveRange(0.0, 1.0));
      expect(e.isNaN, isFalse);
    });
  });

  group('MatchCubeAdvisor with an out-of-range match length', () {
    test('advises without throwing at an away score past the table', () {
      const advisor = MatchCubeAdvisor();
      final advice = advisor.advise(
        probs: Probabilities(
          win: 0.7,
          winGammon: 0,
          winBackgammon: 0,
          loseGammon: 0,
          loseBackgammon: 0,
        ),
        moverAway: 99,
        opponentAway: 99,
        cubeValue: 1,
      );
      expect(advice.equityNoDouble, inInclusiveRange(0.0, 1.0));
      expect(advice.equityDoubleTake, inInclusiveRange(0.0, 1.0));
      expect(advice.equityDoubleDrop, inInclusiveRange(0.0, 1.0));
    });
  });

  group('matchEquityOfDistribution', () {
    // Reuse the by-hand 5-away/5-away gammonful fixture: win 0.6, winGammon 0.3,
    // winBackgammon 0.05, loseGammon 0.1, loseBackgammon 0.0 (cumulative).
    // From match_cube_advisor_test.dart: E(1) = 0.534372, E(2) = 0.5762685.
    const probs = Probabilities(
      win: 0.6,
      winGammon: 0.3,
      winBackgammon: 0.05,
      loseGammon: 0.1,
      loseBackgammon: 0.0,
    );

    test('stake 1 matches the hand-computed E(1)', () {
      final e1 = matchEquityOfDistribution(probs,
          moverAway: 5, opponentAway: 5, stake: 1, crawfordPlayed: false);
      // Independent recomputation from exclusive buckets and table values.
      final expected = 0.3 * MatchEquityTable.preCrawford(4, 5) +
          0.25 * MatchEquityTable.preCrawford(3, 5) +
          0.05 * MatchEquityTable.preCrawford(2, 5) +
          0.3 * MatchEquityTable.preCrawford(5, 4) +
          0.1 * MatchEquityTable.preCrawford(5, 3);
      expect(e1, closeTo(expected, 1e-12));
      expect(e1, closeTo(0.534372, 1e-6));
    });

    test('stake 2 matches the hand-computed E(2) (score transitions double)',
        () {
      final e2 = matchEquityOfDistribution(probs,
          moverAway: 5, opponentAway: 5, stake: 2, crawfordPlayed: false);
      final expected = 0.3 * MatchEquityTable.preCrawford(3, 5) +
          0.25 * MatchEquityTable.preCrawford(1, 5) +
          0.05 * 1.0 + // bg win at stake 2: 5 - 6 = -1 away -> mover wins match
          0.3 * MatchEquityTable.preCrawford(5, 3) +
          0.1 * MatchEquityTable.preCrawford(5, 1);
      expect(e2, closeTo(expected, 1e-12));
      expect(e2, closeTo(0.5762685, 1e-6));
    });

    test('gammonless single-win reduces to the two-outcome average', () {
      const g = Probabilities(
        win: 0.7,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      );
      final e = matchEquityOfDistribution(g,
          moverAway: 5, opponentAway: 5, stake: 1, crawfordPlayed: false);
      final expected = 0.7 * MatchEquityTable.preCrawford(4, 5) +
          0.3 * MatchEquityTable.preCrawford(5, 4);
      expect(e, closeTo(expected, 1e-12));
    });
  });
}
