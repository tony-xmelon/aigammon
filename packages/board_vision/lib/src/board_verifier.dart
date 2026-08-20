import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';

import 'calibration.dart';
import 'color_model.dart';
import 'frame.dart';
import 'occupancy.dart';
import 'roi_atlas.dart';
import 'roi_sampler.dart';

/// What one region had to say about what the game expects of it.
enum RegionVerdict {
  /// Nothing in the picture contradicts the expectation.
  ///
  /// Deliberately not "the region was confirmed". Verification is a
  /// contradiction test — see [BoardVerifier] — and on a region the reader can
  /// barely measure, "nothing contradicts it" is the strongest true thing that
  /// can be said.
  agrees,

  /// Something in the picture contradicts it. [RegionVerification.kind] says
  /// what, and [RegionVerification.confidence] how much the contradiction is
  /// worth.
  disagrees,

  /// This board has no such region, so nothing in the picture could speak
  /// either way. In practice a bear-off tray on a folding case.
  unobservable,
}

/// The four ways a region can contradict what the game says is on it.
///
/// They are separated because they fail for different reasons, carry different
/// confidence, and route differently in [DriftReport] — a colour that flipped
/// is almost always the board, and a tall stack reading short is almost always
/// the camera.
enum DiscrepancyKind {
  /// The other player's checkers are standing there.
  ///
  /// The strongest contradiction there is: per-region colour comes back right
  /// 0.954 of the time on the real corpus against 0.784 for colour and count
  /// together.
  wrongColour,

  /// The game says the region is bare and something is standing in it.
  unexpectedlyOccupied,

  /// The game says men are standing there and **nothing is**.
  ///
  /// The judgement is made on the measured run rather than on the count, and
  /// that is the whole of the 066 case: a run of a third of a checker on a worn
  /// hinge is not enough for a blind count to call a checker, and it is
  /// conclusive evidence that the region is not bare. Only a region where the
  /// walk finds no run at all reaches this.
  unexpectedlyEmpty,

  /// The right colour, standing to the wrong height.
  wrongCount,
}

/// What one region of one frame said about one expectation.
///
/// The unit the "camera says / game says" resolve UI is built from: it carries
/// both sides of the comparison, the raw sub-checker measurement behind them,
/// and how much the verdict is worth.
class RegionVerification {
  final RoiId region;

  /// Whose queue this is about.
  ///
  /// The bar is the reason this exists: its two colours stack away from each
  /// other from the midline, so each has its own axis and its own expectation,
  /// and a single verdict for the region would have to average two
  /// measurements that share nothing. A point holds one queue, so its side is
  /// the colour the game puts there — or [CheckerColor.none] on a point the
  /// game says is bare, where the question is about the region rather than
  /// about either player's men.
  final CheckerColor side;

  /// The point as White numbers it, or null for the bar and the trays.
  final int? pointNumber;

  /// How many men of [side] the game says are there.
  final int expected;

  /// Whichever colour the frame read, or [CheckerColor.none].
  final CheckerColor observedColour;

  /// What a blind count of this region would have said — the "camera says"
  /// half of the resolve UI, and **not** what the verdict is computed from.
  /// See [BoardVerifier] for why the two differ.
  final int observedCount;

  /// How many checkers the measured run divides into, before any rounding.
  ///
  /// The number the verdict is actually computed from, and the reason
  /// verification can be right where a blind count is wrong: rounding throws
  /// away exactly the fraction a prior can use.
  final double observedHeight;

  /// How far the run of [side]-coloured rows at the region's origin reached,
  /// in board-space units. Zero means **nothing is standing there**, which is
  /// a different statement from "the count came out zero".
  final double reach;

  final RegionVerdict verdict;

  /// What kind of contradiction, when [verdict] is [RegionVerdict.disagrees].
  final DiscrepancyKind? kind;

  /// How much this verdict is worth, from 0 to 1.
  ///
  /// **Not a probability**, the same stance [RegionOccupancy.confidence] and
  /// [PlayMatch.confidence] take. It is always the same product: what this
  /// **kind** of evidence is worth on this pipeline — see
  /// [BoardVerifier.colourContradiction] and its neighbours, every one of them
  /// a corpus measurement — times what the **reading** that produced it was
  /// worth. On an agreement the kind is worth one, so it is the reading alone,
  /// which is what tells a caller that a region agreed because it was measured
  /// well rather than because nothing could be measured at all.
  ///
  /// The reading is the one of whatever the camera actually saw. On a colour
  /// contradiction that is the colour that IS there rather than the one the
  /// game expected — see the note in `BoardVerifier._verifyRegion`, because
  /// getting it from the other side inverts the ordering of the whole resolve
  /// screen.
  final double confidence;

  const RegionVerification({
    required this.region,
    required this.side,
    required this.pointNumber,
    required this.expected,
    required this.observedColour,
    required this.observedCount,
    required this.observedHeight,
    required this.reach,
    required this.verdict,
    required this.kind,
    required this.confidence,
  });

  /// Whether the picture positively failed to contradict the game.
  ///
  /// False for [RegionVerdict.unobservable], and that is the point: a region
  /// this board does not have has not agreed with anything. See
  /// [BoardDiscrepancies.unobservable].
  bool get agrees => verdict == RegionVerdict.agrees;

  bool get disagrees => verdict == RegionVerdict.disagrees;

  /// The sentence the side-by-side resolve UI puts under this region.
  ///
  /// A disagreement always names what the camera saw before what the game
  /// holds, because the screen it feeds is that comparison in that order and a
  /// sentence that swapped them would read as the opposite claim.
  ///
  /// An agreement says **nothing contradicts it** rather than "the camera
  /// confirms it", and the difference is not pedantry — it is what the verdict
  /// actually means. On 066 the camera sees nothing on the bar and the region
  /// still agrees that a Black man is standing there, because the run it
  /// measured is consistent with one and inconsistent with none. A sentence
  /// claiming the camera had confirmed it would be a sentence the picture does
  /// not support.
  String get message {
    final where = describeRegion(region);
    return switch (verdict) {
      RegionVerdict.unobservable => expected == 0
          ? '$where is not on this board'
          : '$where is not on this board — the ${_theGameSays()} the game '
              'says are there cannot be seen either way',
      RegionVerdict.agrees => '$where: nothing contradicts ${_theGameSays()}',
      RegionVerdict.disagrees =>
        '$where: the camera sees ${_cameraSees()}, the game says '
            '${_theGameSays()}',
    };
  }

  String _cameraSees() => observedColour == CheckerColor.none ||
          observedCount == 0
      ? 'nothing'
      : '${_side(observedColour)} $observedCount';

  String _theGameSays() =>
      expected == 0 ? 'that it is empty' : '${_side(side)} $expected';

  static String _side(CheckerColor colour) =>
      colour == CheckerColor.white ? 'White' : 'Black';

  @override
  String toString() => 'RegionVerification(${verdict.name}'
      '${kind == null ? '' : '/${kind!.name}'} @'
      '${confidence.toStringAsFixed(2)}: $message)';
}

/// Everything one frame had to say about one expected position.
class BoardDiscrepancies {
  /// The position this was checked against.
  final BoardState expected;

  /// Every region asked, in White's point order and then the bar and trays.
  final List<RegionVerification> regions;

  /// The ones that contradict [expected], **strongest contradiction first** —
  /// which is the order the resolve UI wants, and the order a spoken
  /// correction wants ("the checker from 13 should be on 8, not 7" names the
  /// thing the camera is surest about).
  final List<RegionVerification> discrepancies;

  /// The ones this board has no way to speak about.
  ///
  /// Consuming [PlayMatch.unobservable]'s philosophy exactly: a folding case
  /// has no bear-off wells, a borne-off checker leaves the board altogether,
  /// and there is nothing in the picture to count. Such a region **cannot
  /// contradict** the game, so it is not a discrepancy; it is equally **not
  /// evidence that the board is right**, so it is not an agreement either. A
  /// caller that wants to know whether a bear-off really happened has to get
  /// it from the point that lost a man, which is what the play matcher does.
  final List<RegionVerification> unobservable;

  BoardDiscrepancies({
    required this.expected,
    required List<RegionVerification> regions,
  })  : regions = List<RegionVerification>.unmodifiable(regions),
        discrepancies = List<RegionVerification>.unmodifiable(
          regions.where((r) => r.disagrees).toList()
            ..sort((a, b) => b.confidence.compareTo(a.confidence)),
        ),
        unobservable = List<RegionVerification>.unmodifiable(
          regions
              .where((r) => r.verdict == RegionVerdict.unobservable)
              .toList(),
        );

  /// Whether the board in the picture is the board the game holds, as far as
  /// this frame can say.
  ///
  /// **Nothing contradicted it** is what this means, and the difference
  /// matters on a board with unobservable regions: a position with two men
  /// borne off a folding case agrees here on the strength of the point that
  /// lost them, because the tray that would have confirmed it does not exist.
  bool get agrees => discrepancies.isEmpty;

  /// What [region] said, for the given [side] — the bar has one entry per
  /// colour and everything else exactly one.
  RegionVerification? forRegion(RoiId region, {CheckerColor? side}) {
    for (final r in regions) {
      if (r.region != region) continue;
      if (side != null && r.side != side) continue;
      return r;
    }
    return null;
  }

  /// A sentence for the user, naming the offenders. Written to be shown as it
  /// stands, like [ConfirmResult.message].
  String get message {
    if (agrees) {
      final blind = unobservable.where((r) => r.expected > 0).length;
      return blind == 0
          ? 'The board is what the game says it is.'
          : 'The board is what the game says it is, as far as it can be seen '
              '— $blind ${blind == 1 ? 'region is' : 'regions are'} not on '
              'this board at all.';
    }
    final named = discrepancies.take(2).map((d) => d.message).join('; ');
    final rest = discrepancies.length - 2;
    return 'The board and the game have come apart: $named'
        '${rest > 0 ? ' (and $rest more)' : ''}.';
  }

  @override
  String toString() => 'BoardDiscrepancies($message)';
}

/// Does the physical board hold the position the game says it does?
///
/// ## Why this is not a reading
///
/// The obvious shape is: read the board, compare it with [BoardState]. Phase 1
/// measured why that is the wrong instrument, and the measurement is on the
/// real corpus: per-region colour comes back at 0.954, colour **and count**
/// together at 0.784, and the counting misses are not scattered. A blind count
/// is a length divided by a pitch, and it has to decide between K and K±1 by
/// **rounding** — so its answer flips at half a checker, and everything finer
/// than that it throws away.
///
/// Verification is handed K. It never has to produce a number; it only has to
/// decide whether the measurement **contradicts** the one it was given. That is
/// a wider question with a wider answer, and the width is exactly
/// [stackTolerance]: everything a blind count gets right, this agrees with, and
/// the band from half a checker out to the tolerance is what the prior buys.
///
/// ## Contradiction, not confirmation
///
/// Every verdict here is the answer to "is there anything in this picture that
/// says otherwise?", and [RegionVerdict.agrees] means no. That asymmetry is
/// deliberate and it is what makes the query usable on a board the camera reads
/// poorly: a region the reader can barely measure cannot contradict anything,
/// so it agrees — with a low [RegionVerification.confidence] saying why.
///
/// The one thing that must never happen is the reverse — a contradiction
/// invented out of a measurement that was never made. So the two "nothing is
/// there" tests are asked of the **run**, which was measured, rather than of
/// the count, which was extrapolated:
///
/// * a region whose run is **exactly zero** has nothing standing in it. On the
///   real corpus that is true of every bare bar in the session;
/// * a region with any run at all has something standing in it, whatever the
///   count came to.
///
/// **That is the 066 case, and it is why this class exists.** The real corpus's
/// keyframe 066 has a Black man on a thirty-year-old rubbed hinge. Its run
/// measures 0.025 of the board where a checker on that board is 0.087 deep, so
/// `StackMetrics.holdsAnything` refuses it and blind occupancy reports the bar
/// empty — correctly, because asked blind it cannot tell that run from the rim
/// and shadow an EMPTY point produces on the same frame (measured: runs of
/// 0.021 to 0.042 on nine bare points of the same session). Asked instead "is
/// there one Black man on the bar?", the same run divides into **1.28**
/// checkers through the calibration's own fitted line, well inside
/// [stackTolerance] of the one the game expects, and the region agrees. Asked
/// the same question of 070's bare bar — run exactly zero — it disagrees.
///
/// ## The calibration epoch is a precondition
///
/// [frame] must have been taken under the **same calibration epoch** as
/// [calibration]: the same corners, the same learned colours, the same board in
/// the same place. Every region is located by the calibration's geometry and
/// classified against its colours, so a frame from before a recalibration is
/// being measured with an instrument that no longer describes it — regions read
/// from slightly the wrong place, and the disagreements that produces look
/// exactly like a board somebody moved checkers on.
///
/// Nothing here can check that, because a [Frame] is bytes and carries no
/// provenance. The session owns it: Task 9's readability path invalidates any
/// held frame the moment calibration is invalidated. The same precondition
/// [PlayMatcher] states, for the same reason and with one frame instead of two.
///
/// ## One instance per use
///
/// Constructing one of these reads nothing; [verify] reads every region the
/// expectation touches — **twenty-six** on a folding case and **twenty-eight**
/// on a board with wells, the bar counted twice because its two colours stack
/// away from each other and neither can be read off the other's profile.
/// A session verifying the same frame against more than one candidate position
/// should hold one of these and call [verify] repeatedly rather than going
/// through the `BoardVision.verifyExpectedBoard` convenience, which rebuilds
/// the reader every time.
class BoardVerifier {
  /// The board this is reading, and the colours it learned.
  final BoardCalibration calibration;

  final Frame frame;

  final OccupancyReader _reader;
  final RoiSampler _sampler;
  final ColorModel _colors;

  BoardVerifier(this.calibration, this.frame)
      : _reader = OccupancyReader(calibration, frame),
        _sampler = RoiSampler(frame, calibration.geometry, calibration.atlas),
        _colors = calibration.colorsIn(frame);

  /// How far the measured stack height may sit from the expected one, in
  /// checkers, before the region is called wrong.
  ///
  /// **Two bounds, and the whole value of the prior lives between them.**
  ///
  /// *Above a half*, because a half is where a blind count's answer flips. A
  /// region whose measurement lands 0.6 of a checker from K is a region a blind
  /// count reports as K±1 and gets wrong; this window keeps it. So verification
  /// agrees on a strict **superset** of the regions a blind count gets right,
  /// by construction rather than by luck, and the band from 0.5 to here is the
  /// entire mechanism by which a state-primed query out-performs an open one.
  ///
  /// *Below a whole one*, because a checker misplaced by one is the thing this
  /// query exists to catch. Placement verification asks "you were told to put a
  /// man on the 8" — and a window that reached a whole checker would accept the
  /// board that did not.
  ///
  /// Three quarters sits between them with room on both sides. What it costs is
  /// measured: on a bed calibrated under a lamp gradient and read with the
  /// stacks left a hand's width in — two hard cases at once — a four-stack
  /// measures 4.37, so a man missing from a five-stack *on that bed* is 0.63
  /// out and falls inside this window. On the corpus's own grade the same
  /// residuals run under 0.05 and a missing man is a clean 1.00 out.
  ///
  /// Provisional, like every threshold in this package, and a knob rather than
  /// a promise — see [PerceptionTargets] for that distinction.
  static const double stackTolerance = 0.75;

  /// What a colour contradiction is worth: the measured per-region colour
  /// accuracy on the real corpus, and the strongest single piece of evidence
  /// the pipeline has. The same 0.954 [PlayMatcher.colourWeight] is built on.
  static const double colourContradiction = 0.954;

  /// What "the game says men are here and nothing is" is worth.
  ///
  /// **Rare, and therefore informative when it fires.** Across the eleven
  /// hundred region-reads of the two corpora — every one of them a board that
  /// is in fact correct — a run of the expected colour came back empty **six**
  /// times, none of them on a photograph. On the real session's eighteen single
  /// checkers exactly one has no run of its own colour, and that one has the
  /// other player's man standing on it, so it is a colour contradiction before
  /// it is ever an absence. **This is the 066 mechanism at large**: a blind
  /// count loses a lone man on a dark point often enough to matter, and the run
  /// underneath it is still there to be measured.
  ///
  /// It sits under [presenceContradiction] for two measured reasons. The
  /// pipeline's own tie-breaking runs toward calling a sample a checker
  /// (`ColorModel.classify`), so losing men is the direction it is more likely
  /// to be wrong in. And when it does go wrong it goes wrong in bulk: all six
  /// of those six are one failure — a lamp down the table on near-black
  /// checkers — taking whole stacks together rather than scattering. That is
  /// also why [DriftReport] sends every absence to the user whatever the stack
  /// height, instead of to either side's version of events.
  static const double absenceContradiction = 0.8;

  /// What "the game says nothing is here and something is" is worth.
  ///
  /// Higher than [absenceContradiction] and the asymmetry is measured:
  /// `ColorModel.classify` breaks ties toward "checker" on purpose, so the
  /// error runs toward inventing men rather than losing them — but a region
  /// that clears both the presence mass AND `StackMetrics.holdsAnything` has
  /// a whole checker's worth of run in it, which felt and shadow do not
  /// produce. One bare point of the two hundred and forty in the real session
  /// reaches it.
  static const double presenceContradiction = 0.9;

  /// The tallest stack a blind count is trusted on — the design's own "trusted
  /// only to two", rounded up by one because three is still comfortably inside
  /// what the corpus measures (real-corpus height error at K=3 runs -0.62 to
  /// +0.34, against -3.24 to +0.21 at K=5).
  static const int shortStack = 3;

  /// What a count contradiction on a short stack is worth. Nearly a colour's,
  /// because on a stack this size the count is nearly as good as the colour.
  static const double shortStackCount = 0.9;

  /// What a count contradiction of **at most one checker** on a tall stack is
  /// worth.
  ///
  /// Low, and measured rather than cautious: on the real corpus a five-stack's
  /// height comes back 1.57 checkers short on average and a six-stack's 4.05,
  /// all of it in the direction the perspective predicts. A tall stack a
  /// checker out is therefore what the instrument does on this board from this
  /// seat, and [DriftReport] routes it to the camera rather than to the user's
  /// hands.
  static const double tallStackNearMiss = 0.3;

  /// The same, out by more than a checker — still the weakest kind of
  /// contradiction there is, but no longer inside the measured bias.
  static const double tallStackFarMiss = 0.6;

  /// Whether the board in [frame] holds [expected], region by region.
  BoardDiscrepancies verify(BoardState expected) {
    final observable = calibration.atlas.regions;
    final out = <RegionVerification>[];

    for (var i = 0; i < 24; i++) {
      final signed = expected.points[i];
      out.add(_verifyRegion(
        region: RoiId.point(i),
        pointNumber: i + 1,
        side: signed == 0
            ? CheckerColor.none
            : signed > 0
                ? CheckerColor.white
                : CheckerColor.black,
        expected: signed.abs(),
        observable: true,
      ));
    }

    // The bar, once per colour: its two stacks grow away from each other from
    // the midline, so neither can be read off the other's profile. Asked even
    // when the game expects nothing there, because a man left on the bar is
    // exactly the kind of drift this query exists to find.
    for (final (side, count) in <(CheckerColor, int)>[
      (CheckerColor.white, expected.whiteBar),
      (CheckerColor.black, expected.blackBar),
    ]) {
      out.add(_verifyRegion(
        region: RoiId.bar,
        pointNumber: null,
        side: side,
        expected: count,
        observable: true,
      ));
    }

    for (final (region, side, count) in <(RoiId, CheckerColor, int)>[
      (RoiId.offWhite, CheckerColor.white, expected.whiteOff),
      (RoiId.offBlack, CheckerColor.black, expected.blackOff),
    ]) {
      out.add(_verifyRegion(
        region: region,
        pointNumber: null,
        side: side,
        expected: count,
        observable: observable.contains(region),
      ));
    }

    return BoardDiscrepancies(expected: expected, regions: out);
  }

  RegionVerification _verifyRegion({
    required RoiId region,
    required int? pointNumber,
    required CheckerColor side,
    required int expected,
    required bool observable,
  }) {
    if (!observable) {
      // This board has no such region. It cannot contradict and it cannot
      // confirm; saying so is the whole of the answer.
      return RegionVerification(
        region: region,
        side: side,
        pointNumber: pointNumber,
        expected: expected,
        observedColour: CheckerColor.none,
        observedCount: 0,
        observedHeight: 0,
        reach: 0,
        verdict: RegionVerdict.unobservable,
        kind: null,
        confidence: 0,
      );
    }

    // What a blind read says — the "camera says" half of the resolve UI, and
    // the instrument for the one question a blind read is exactly right for:
    // is this region bare? Below `holdsAnything` there is no checker, and that
    // threshold was measured against the rim and shadow real boards produce.
    final blind = side == CheckerColor.none
        ? _reader.read(region)
        : _reader.readFor(region, side);

    if (expected == 0) {
      final occupied = blind.count > 0;
      return RegionVerification(
        region: region,
        side: side,
        pointNumber: pointNumber,
        expected: 0,
        observedColour: blind.color,
        observedCount: blind.count,
        observedHeight: calibration.stacks.heightOf(blind.reach),
        reach: blind.reach,
        verdict: occupied ? RegionVerdict.disagrees : RegionVerdict.agrees,
        kind: occupied ? DiscrepancyKind.unexpectedlyOccupied : null,
        confidence: occupied
            ? presenceContradiction * _worth(blind)
            : blind.confidence,
      );
    }

    // Both colours down this region's own axis, in one pass, so the question
    // "is the OTHER colour standing here?" is answered by a measurement rather
    // than by the absence of one.
    final measured = _sampler.measureStack(
      StackAxis.forRegion(calibration.atlas, region, color: side),
      _colors,
    );
    final other = side == CheckerColor.white
        ? CheckerColor.black
        : CheckerColor.white;
    final mine = measured.reachOf(side);
    final theirs = measured.reachOf(other);
    final height = calibration.stacks.heightOf(mine);

    RegionVerification verdict(
      RegionVerdict verdict,
      DiscrepancyKind? kind,
      double confidence, {
      CheckerColor? saw,
      int? sawCount,
    }) =>
        RegionVerification(
          region: region,
          side: side,
          pointNumber: pointNumber,
          expected: expected,
          observedColour: saw ?? blind.color,
          observedCount: sawCount ?? blind.count,
          observedHeight: height,
          reach: mine,
          verdict: verdict,
          kind: kind,
          confidence: confidence.clamp(0.0, 1.0),
        );

    // 1. Colour, which is what the pipeline is best at. A region where the
    //    opponent's men reach further than the mover's own — and reach far
    //    enough to be men at all — is holding the wrong colour, whatever the
    //    counts come to.
    //
    //    Weighed by the reading of the colour that IS there, not by the one
    //    that is not, and the difference is not cosmetic: `readFor` on a colour
    //    the region does not hold returns an EMPTY reading, whose confidence
    //    falls the more of the other colour is present. Taken from that side,
    //    the strongest colour contradictions would carry the lowest confidence
    //    of all and sort to the bottom of the resolve screen — which is the one
    //    place the ordering is load-bearing.
    if (theirs > mine && calibration.stacks.holdsAnything(theirs)) {
      final saw = _reader.readFor(region, other);
      return verdict(
        RegionVerdict.disagrees,
        DiscrepancyKind.wrongColour,
        colourContradiction * _worth(saw),
        saw: other,
        sawCount: math.max(1, saw.count),
      );
    }

    // 2. Presence — is anything standing here at all?
    //
    // **Two instruments, and a region is bare only when BOTH say so.** The RUN
    // is what was measured — how far a queue of this colour's rows reaches from
    // the region's origin, judged against a checker's own depth by
    // `StackMetrics.holdsAnything`. The fitted LINE is what this board's
    // calibration makes of that length. Each half of the conjunction is holding
    // up a case the other half gets wrong, and both were measured by deleting
    // it:
    //
    // * **the run keeps a genuine lone checker.** One man measures *about* one
    //   checker, and "about" straddles one — so `height < 1` on its own calls
    //   real single men bare. Delete the run test and a White man standing
    //   alone on the 4-point of the corpus-grade bed comes back as "the camera
    //   sees nothing", on both palettes at once. Its run is nowhere near
    //   marginal: it clears `holdsAnything` comfortably, which is precisely the
    //   evidence the line was too coarse to keep;
    // * **the line keeps 066.** A run of 0.025 on a worn hinge is under
    //   `holdsAnything`'s floor, and the run test alone therefore calls the bar
    //   bare — with a Black man genuinely standing on it. This board's own
    //   fitted line makes 1.28 checkers of that run, and delete the height test
    //   and the flagship case goes red.
    //
    // So the two disagree in both directions, and a region is empty only where
    // neither can find a checker's worth. Where they part, the region is one
    // the instrument cannot resolve on its own and the honest move is to fall
    // through to the consistency check with the prior rather than to declare it
    // empty.
    //
    // `mine <= 0` is there for a board the conjunction would not cover: a fit
    // whose origin puts a run of nothing at one checker or more. The real
    // board's origin is -0.0857, so its `heightOf(0)` is 0.99 and the height
    // test happens to catch it; that is a property of one fit and not a
    // guarantee, and nothing standing anywhere is not a judgement call.
    final bare = !calibration.stacks.holdsAnything(mine) && height < 1;
    if (mine <= 0 || bare) {
      return verdict(
        RegionVerdict.disagrees,
        DiscrepancyKind.unexpectedlyEmpty,
        absenceContradiction * _worth(blind),
        saw: CheckerColor.none,
        sawCount: 0,
      );
    }

    // 3. Height, against the one the game named. Never against a number this
    //    class worked out for itself.
    final error = height - expected;
    if (error.abs() > stackTolerance) {
      return verdict(
        RegionVerdict.disagrees,
        DiscrepancyKind.wrongCount,
        _countContradiction(expected, error) * _worth(blind),
      );
    }
    return verdict(RegionVerdict.agrees, null, _worth(blind));
  }

  /// How much a contradiction about a count is worth, from the measured error
  /// structure — see [shortStackCount], [tallStackNearMiss] and
  /// [tallStackFarMiss].
  static double _countContradiction(int expected, double error) {
    if (expected <= shortStack) return shortStackCount;
    return error.abs() <= 1 ? tallStackNearMiss : tallStackFarMiss;
  }

  /// How much the reading behind a verdict was worth, floored so that a region
  /// the reader distrusted completely still carries a verdict rather than a
  /// zero.
  ///
  /// The same argument [PlayMatcher.minEvidence] makes: without a floor, a
  /// contradiction found on the one region nobody trusts would be silently
  /// worth nothing, and the resolve UI would rank a real problem last.
  static double _worth(RegionOccupancy reading) =>
      reading.confidence.clamp(minEvidence, 1.0);

  /// The least a region's reading is allowed to count for. [PlayMatcher] uses
  /// the same number for the same reason, and the two are deliberately equal:
  /// a region either instrument distrusts is the same region.
  static const double minEvidence = 0.25;
}
