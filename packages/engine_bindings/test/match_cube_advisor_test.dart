// Tests for MatchCubeAdvisor (dead-cube v1 match-aware cube decisions).
//
// PURE test (not engine-tagged): no native library, no isolate. Expected
// equities are derived BY HAND in comments from the model formula and the
// Kazaross-XG2 table numbers; the numbers themselves are looked up via
// MatchEquityTable (reading the shipped table in a test is fine — we are not
// copying the advisor's own output). Formula-consistency tests recompute the
// expected equities from the same public building blocks and assert the
// advisor agrees, so they cannot silently drift from folklore.
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

const advisor = MatchCubeAdvisor();

/// Gammonless probabilities: win = [w], no gammons or backgammons either way.
Probabilities gammonless(double w) => Probabilities(
      win: w,
      winGammon: 0,
      winBackgammon: 0,
      loseGammon: 0,
      loseBackgammon: 0,
    );

/// Independent re-implementation of the model's value function, used only by
/// the formula-consistency tests. Mirrors the class doc, NOT the advisor code
/// path (kept deliberately separate so a bug in the advisor cannot hide).
double eqAfter(int aRem, int bRem, {bool crawfordPlayed = false}) {
  if (aRem <= 0) return 1.0;
  if (bRem <= 0) return 0.0;
  if (crawfordPlayed) {
    if (bRem == 1) return MatchEquityTable.postCrawford(aRem);
    if (aRem == 1) return 1.0 - MatchEquityTable.postCrawford(bRem);
  }
  return MatchEquityTable.preCrawford(aRem, bRem);
}

/// Independent E(stake) for the gammonful case (mover's perspective).
double eqAtStake({
  required double singleWin,
  required double gammonWin,
  required double bgWin,
  required double singleLose,
  required double gammonLose,
  required double bgLose,
  required int a,
  required int b,
  required int stake,
  bool crawfordPlayed = false,
}) =>
    singleWin * eqAfter(a - stake, b, crawfordPlayed: crawfordPlayed) +
    gammonWin * eqAfter(a - 2 * stake, b, crawfordPlayed: crawfordPlayed) +
    bgWin * eqAfter(a - 3 * stake, b, crawfordPlayed: crawfordPlayed) +
    singleLose * eqAfter(a, b - stake, crawfordPlayed: crawfordPlayed) +
    gammonLose * eqAfter(a, b - 2 * stake, crawfordPlayed: crawfordPlayed) +
    bgLose * eqAfter(a, b - 3 * stake, crawfordPlayed: crawfordPlayed);

void main() {
  group('MatchCubeAdvisor 2-away/2-away (classic)', () {
    // BY HAND. a = b = 2, cube 1, gammonless win = w.
    //   E(1): win -> (1,2) = preCrawford(1,2) = 0.67736
    //         lose -> (2,1) = preCrawford(2,1) = 0.32264
    //     equityNoDouble  = 0.32264 + w*(0.67736 - 0.32264) = 0.32264 + 0.35472 w
    //   E(2): win -> (0,2) = 1.0 ; lose -> (2,0) = 0.0
    //     equityDoubleTake = w
    //   equityDoubleDrop = eqAfter(1,2) = preCrawford(1,2) = 0.67736
    //
    // shouldDouble: min(w, 0.67736) > 0.32264 + 0.35472 w.
    //   For w in (0.5, 0.67736]: w > 0.32264 + 0.35472 w  <=>  w > 0.5.  TRUE.
    //   For w in (0.67736, 1):   0.67736 > 0.32264+0.35472 w <=> w < 1. TRUE.
    //   => doubling is correct for every w in (0.5, 1).
    // shouldTake: equityDoubleTake <= equityDoubleDrop  <=>  w <= 0.67736.
    const p12 = 0.67736; // preCrawford(1,2)

    test('exact equities match the hand derivation', () {
      const w = 0.60;
      final a = advisor.advise(
          probs: gammonless(w), moverAway: 2, opponentAway: 2, cubeValue: 1);
      expect(a.equityNoDouble, closeTo(0.32264 + 0.35472 * w, 1e-9));
      expect(a.equityDoubleTake, closeTo(w, 1e-9));
      expect(a.equityDoubleDrop, closeTo(p12, 1e-9));
    });

    test('doubling is correct for every winning edge w > 0.5', () {
      for (final w in [0.501, 0.55, 0.60, 0.67736, 0.72, 0.90, 0.99]) {
        final a = advisor.advise(
            probs: gammonless(w), moverAway: 2, opponentAway: 2, cubeValue: 1);
        expect(a.shouldDouble, isTrue, reason: 'should double at w=$w');
      }
    });

    test('take flips exactly at w = preCrawford(1,2) = 0.67736', () {
      final justUnder = advisor.advise(
          probs: gammonless(p12 - 1e-6),
          moverAway: 2,
          opponentAway: 2,
          cubeValue: 1);
      final justOver = advisor.advise(
          probs: gammonless(p12 + 1e-6),
          moverAway: 2,
          opponentAway: 2,
          cubeValue: 1);
      expect(justUnder.shouldTake, isTrue,
          reason: 'w just under 0.67736: opponent still takes');
      expect(justOver.shouldTake, isFalse,
          reason: 'w just over 0.67736: opponent must drop');
    });
  });

  group('MatchCubeAdvisor trailer post-Crawford doubles immediately', () {
    // BY HAND. mover 4-away, opponent 1-away (leader), crawfordPlayed, cube 1,
    // gammonless w = 0.5. Opponent is the permanent 1-away leader, so
    // eqAfter(aRem, 1) = postCrawford(aRem); any mover loss -> opponent 0 -> 0.
    //   post(2)=0.48803, post(3)=0.32264.
    //   E(1): win -> (3,1)=post(3)=0.32264 ; lose -> (4,0)=0
    //         equityNoDouble  = 0.5*0.32264            = 0.16132
    //   E(2): win -> (2,1)=post(2)=0.48803 ; lose -> (4,-1)=0
    //         equityDoubleTake = 0.5*0.48803           = 0.244015
    //   equityDoubleDrop = eqAfter(3,1) = post(3)       = 0.32264
    // shouldDouble: min(0.244015,0.32264)=0.244015 > 0.16132  -> TRUE.
    // shouldTake:   0.244015 <= 0.32264               -> TRUE (leader takes).
    test('4-away vs 1-away post-Crawford: double raises equity', () {
      final a = advisor.advise(
        probs: gammonless(0.5),
        moverAway: 4,
        opponentAway: 1,
        cubeValue: 1,
        crawfordPlayed: true,
      );
      final post2 = MatchEquityTable.postCrawford(2);
      final post3 = MatchEquityTable.postCrawford(3);
      expect(a.equityNoDouble, closeTo(0.5 * post3, 1e-9));
      expect(a.equityDoubleTake, closeTo(0.5 * post2, 1e-9));
      expect(a.equityDoubleDrop, closeTo(post3, 1e-9));
      expect(a.shouldDouble, isTrue);
      // Doubling strictly improves equity (stake doubles; leader-win outcomes
      // stay match-losing for the mover either way).
      expect(a.equityDoubleTake, greaterThan(a.equityNoDouble));
      expect(a.shouldTake, isTrue);
    });
  });

  group('MatchCubeAdvisor money-limit sanity (25-away/25-away)', () {
    // Formula-consistency: recompute equities independently and assert the
    // advisor matches, then check the OPPONENT take point sits in the classic
    // dead-cube ~20-25% band. Deliberately NOT asserting folklore booleans.
    Probabilities p(double w) => gammonless(w);

    test('advisor equities match the independent formula', () {
      for (final w in [0.20, 0.40, 0.51, 0.60, 0.748, 0.85]) {
        final a = advisor.advise(
            probs: p(w), moverAway: 25, opponentAway: 25, cubeValue: 1);
        final nd = eqAtStake(
            singleWin: w,
            gammonWin: 0,
            bgWin: 0,
            singleLose: 1 - w,
            gammonLose: 0,
            bgLose: 0,
            a: 25,
            b: 25,
            stake: 1);
        final dt = eqAtStake(
            singleWin: w,
            gammonWin: 0,
            bgWin: 0,
            singleLose: 1 - w,
            gammonLose: 0,
            bgLose: 0,
            a: 25,
            b: 25,
            stake: 2);
        final dd = eqAfter(24, 25);
        expect(a.equityNoDouble, closeTo(nd, 1e-12), reason: 'nd w=$w');
        expect(a.equityDoubleTake, closeTo(dt, 1e-12), reason: 'dt w=$w');
        expect(a.equityDoubleDrop, closeTo(dd, 1e-12), reason: 'dd w=$w');
        final minDoubled = dt < dd ? dt : dd;
        expect(a.shouldDouble, minDoubled > nd, reason: 'double w=$w');
        expect(a.shouldTake, dt <= dd, reason: 'take w=$w');
      }
    });

    test('opponent take point lies in the classic 18-28% band', () {
      // Scan mover win prob upward; find where the opponent stops taking.
      double? flipW;
      for (var i = 1; i < 1000; i++) {
        final w = i / 1000.0;
        final a = advisor.advise(
            probs: p(w), moverAway: 25, opponentAway: 25, cubeValue: 1);
        if (!a.shouldTake) {
          flipW = w;
          break;
        }
      }
      expect(flipW, isNotNull, reason: 'take must flip somewhere');
      // Opponent's win probability at the flip = 1 - flipW.
      final opponentTakePoint = 1 - flipW!;
      expect(opponentTakePoint, inInclusiveRange(0.18, 0.28),
          reason: 'opponent take point $opponentTakePoint out of band');
    });
  });

  group('MatchCubeAdvisor gammonful hand case (5-away/5-away)', () {
    // BY HAND. w=0.6, wg=0.3, wbg=0.05, lg=0.1, lbg=0.0 (cumulative).
    // lose = 0.4. Exclusive: single 0.3 / gammon 0.25 / bg 0.05 wins;
    //                        single 0.3 / gammon 0.10 / bg 0.00 losses.
    // Table (preCrawford): (4,5)=0.57732 (3,5)=0.64795 (2,5)=0.74359
    //                      (5,4)=0.42268 (5,3)=0.35205 (5,2)=0.25641
    //                      (1,5)=0.84179 (5,1)=0.15821
    // E(1) = .3*.57732 + .25*.64795 + .05*.74359
    //      + .3*.42268 + .1*.35205  + 0*.25641          = 0.534372  (=nd)
    // E(2) = .3*.64795 + .25*.84179 + .05*1.0
    //      + .3*.35205 + .1*.15821  + 0*0.0             = 0.5762685 (=dt)
    // dd   = eqAfter(4,5) = 0.57732
    // doubledEquity = min(0.5762685, 0.57732) = 0.5762685 > 0.534372 -> double.
    // shouldTake = 0.5762685 <= 0.57732 -> TRUE (a whisker of a take).
    test('exact equities and booleans match the hand derivation', () {
      final a = advisor.advise(
        probs: const Probabilities(
          win: 0.6,
          winGammon: 0.3,
          winBackgammon: 0.05,
          loseGammon: 0.1,
          loseBackgammon: 0.0,
        ),
        moverAway: 5,
        opponentAway: 5,
        cubeValue: 1,
      );
      final expectedNd = 0.3 * MatchEquityTable.preCrawford(4, 5) +
          0.25 * MatchEquityTable.preCrawford(3, 5) +
          0.05 * MatchEquityTable.preCrawford(2, 5) +
          0.3 * MatchEquityTable.preCrawford(5, 4) +
          0.1 * MatchEquityTable.preCrawford(5, 3);
      final expectedDt = 0.3 * MatchEquityTable.preCrawford(3, 5) +
          0.25 * MatchEquityTable.preCrawford(1, 5) +
          0.05 * 1.0 +
          0.3 * MatchEquityTable.preCrawford(5, 3) +
          0.1 * MatchEquityTable.preCrawford(5, 1);
      final expectedDd = MatchEquityTable.preCrawford(4, 5);
      expect(a.equityNoDouble, closeTo(expectedNd, 1e-9));
      expect(a.equityNoDouble, closeTo(0.534372, 1e-6));
      expect(a.equityDoubleTake, closeTo(expectedDt, 1e-9));
      expect(a.equityDoubleTake, closeTo(0.5762685, 1e-6));
      expect(a.equityDoubleDrop, closeTo(expectedDd, 1e-9));
      final minDoubled =
          expectedDt < expectedDd ? expectedDt : expectedDd;
      expect(a.shouldDouble, minDoubled > expectedNd);
      expect(a.shouldTake, expectedDt <= expectedDd);
      expect(a.shouldDouble, isTrue);
      expect(a.shouldTake, isTrue);
    });
  });

  group('MatchCubeAdvisor guards and extremes', () {
    test('away < 1 throws ArgumentError', () {
      expect(
          () => advisor.advise(
              probs: gammonless(0.6),
              moverAway: 0,
              opponentAway: 3,
              cubeValue: 1),
          throwsArgumentError);
      expect(
          () => advisor.advise(
              probs: gammonless(0.6),
              moverAway: 3,
              opponentAway: 0,
              cubeValue: 1),
          throwsArgumentError);
      expect(
          () => advisor.advise(
              probs: gammonless(0.6),
              moverAway: 3,
              opponentAway: 3,
              cubeValue: 0),
          throwsArgumentError);
    });

    test('certain win (w=1) gives finite equities, no NaN', () {
      // moverAway=2, cube 2: a single win banks 2 points -> reaches 0 away ->
      // every branch evaluates to a certain 1.0.
      final a = advisor.advise(
          probs: gammonless(1.0),
          moverAway: 2,
          opponentAway: 5,
          cubeValue: 2);
      expect(a.equityNoDouble, closeTo(1.0, 1e-12));
      expect(a.equityDoubleTake, closeTo(1.0, 1e-12));
      expect(a.equityDoubleDrop, closeTo(1.0, 1e-12));
      expect(a.equityNoDouble.isNaN, isFalse);
      // Nothing to gain past a certain win: not a double.
      expect(a.shouldDouble, isFalse);
    });
  });

  group('MatchCubeAdvisor cube-value scaling (7-away/7-away, cube 2)', () {
    // Formula-consistency with a non-unit cube: stakes are 2 (no double) and
    // 4 (double), so score transitions jump by 2/4/6 and 4/8/12 respectively.
    test('advisor equities match the independent 2/4-stake formula', () {
      const w = 0.62, wg = 0.18, wbg = 0.02, lg = 0.12, lbg = 0.01;
      final probs = const Probabilities(
        win: w,
        winGammon: wg,
        winBackgammon: wbg,
        loseGammon: lg,
        loseBackgammon: lbg,
      );
      final a = advisor.advise(
          probs: probs, moverAway: 7, opponentAway: 7, cubeValue: 2);
      final sw = w - wg, gw = wg - wbg, bw = wbg;
      final sl = (1 - w) - lg, gl = lg - lbg, bl = lbg;
      double e(int stake) => eqAtStake(
          singleWin: sw,
          gammonWin: gw,
          bgWin: bw,
          singleLose: sl,
          gammonLose: gl,
          bgLose: bl,
          a: 7,
          b: 7,
          stake: stake);
      final nd = e(2); // no double: stake = cubeValue
      final dt = e(4); // double/take: stake = 2*cubeValue
      final dd = eqAfter(7 - 2, 7); // double/drop: mover banks cubeValue=2
      expect(a.equityNoDouble, closeTo(nd, 1e-12));
      expect(a.equityDoubleTake, closeTo(dt, 1e-12));
      expect(a.equityDoubleDrop, closeTo(dd, 1e-12));
      final minDoubled = dt < dd ? dt : dd;
      expect(a.shouldDouble, minDoubled > nd);
      expect(a.shouldTake, dt <= dd);
    });
  });
}
