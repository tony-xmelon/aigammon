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
