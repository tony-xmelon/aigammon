import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'corpus/capture_plan.dart';
import 'corpus/corpus_io.dart';
import 'synthetic/board_renderer.dart';

/// *Does the physical board hold what the game says it holds?*
///
/// The other half of the state-primed pair. Task 7's matcher asks which of a
/// handful of legal plays produced a **change**; this one asks whether a single
/// frame agrees with a **position** — the query behind placement verification
/// ("you were asked to put a man on the 8; is it there?") and behind drift
/// recovery ("we have come apart somewhere; where?").
///
/// ## Why the prior changes the question
///
/// A blind count has to decide between K and K±1 and it decides by rounding, so
/// its answer flips at half a checker. Verification is handed K and only has to
/// decide whether the measurement is CONSISTENT with it, which is a wider
/// window — see [BoardVerifier.stackTolerance] for the two bounds that window
/// sits between. Everything the blind reader gets right, verification agrees
/// with; the band between half a checker and the tolerance is what the prior
/// buys, and 'the prior earns its keep' below is that band measured.
///
/// ## The bar on a worn hinge is the acceptance case
///
/// The real corpus's 066 has a Black checker standing on a thirty-year-old
/// rubbed hinge. Blind occupancy reads **nothing** there — the run is a third
/// of a checker and `StackMetrics.holdsAnything` refuses it, correctly, because
/// asked blind it cannot tell that run from the rim-and-shadow an EMPTY point
/// produces on the same board. Asked "is there one Black man on the bar?" the
/// same evidence answers yes. And asked the same question of a bar with nothing
/// on it, it answers no — that pair is the whole test, and both halves are
/// below on real photographs.
void main() {
  group('a board that is what the game says', () {
    for (final plan in _beds) {
      test('${plan.name}: verifies clean, near half and far', () {
        final bed = _bedOf(plan);
        for (final board in _positions) {
          final result = bed.verify(board, board);
          expect(result.agrees, isTrue,
              reason: '${plan.name}: ${result.message}');
          expect(result.discrepancies, isEmpty);
        }
      });
    }

    test('every region of the board was actually asked about', () {
      // A verifier that quietly skipped regions would verify clean for the
      // wrong reason, and the whole file would be measuring nothing.
      final bed = _bedOf(_beds.first);
      final result = bed.verify(BoardState.initial(), BoardState.initial());
      expect(
        result.regions.map((r) => r.region).toSet(),
        containsAll(<RoiId>[for (var i = 0; i < 24; i++) RoiId.point(i)]),
      );
      expect(result.regions.map((r) => r.region), contains(RoiId.bar));
      expect(result.regions.map((r) => r.region),
          isNot(contains(RoiId.diceZone)),
          reason: 'the dice band is not a region a game is played on');
      // The bar is asked once per colour: its two stacks grow away from each
      // other from the midline and neither can be read off the other's profile.
      expect(
        result.regions.where((r) => r.region == RoiId.bar).length,
        2,
      );
    });
  });

  group('one checker in the wrong place', () {
    test('names exactly the two regions it is wrong about', () {
      final bed = _bedOf(_beds.first);
      final expected = BoardState.initial();
      final legal =
          MoveGenerator.legalMoves(expected, Player.white, Dice(6, 5));
      final played = legal.first;
      expect(played.checkerMoves, hasLength(2));
      // The board in front of the camera has had a play made on it that the
      // game does not know about — which is exactly the drift the recovery
      // path exists for.
      final onTheTable = expected.applyMove(Player.white, played);

      final result = bed.verify(onTheTable, expected);
      expect(result.agrees, isFalse, reason: result.message);
      final wrong = result.discrepancies.map((d) => d.region).toSet();
      final touched = <RoiId>{
        for (final hop in played.checkerMoves) ...<RoiId>[
          RoiId.point(hop.from),
          RoiId.point(hop.to),
        ],
      };
      expect(wrong, touched,
          reason: 'the wrong regions were named: '
              '${result.discrepancies.map((d) => d.message).join('; ')}');
    });

    test('a checker left where the game says nothing is a discrepancy of its '
        'own kind', () {
      final bed = _bedOf(_beds.first);
      final expected = BoardState.initial();
      // A stray man on the 5-point: the point the game says is bare.
      final onTheTable = BoardState(points: <int>[
        for (final (i, c) in expected.points.indexed)
          switch (i) { 4 => c + 1, 5 => c - 1, _ => c },
      ]);
      final result = bed.verify(onTheTable, expected);
      final stray = result.discrepancies
          .firstWhere((d) => d.region == RoiId.point(4));
      expect(stray.kind, DiscrepancyKind.unexpectedlyOccupied);
      expect(stray.observedColour, CheckerColor.white);
    });
  });

  group('the query a session asks after dictating a move', () {
    // **The whole board is not the question.** A session that has just said
    // "13/8, 8/6" and watched a hand move knows exactly which regions were
    // touched, and those are the ones the placement query is about. The
    // user's decision at the gate follow-up (2026-08-21) is that placement
    // verification is scored on that set — see `PerceptionTargets`.
    test('the regions a play touches are the ones its hops name', () {
      final play = Move(<CheckerMove>[
        const CheckerMove(CheckerMove.bar, 20, isHit: true),
        const CheckerMove(5, CheckerMove.off),
      ]);
      expect(
        regionsTouchedBy(play, Player.white).toSet(),
        <TouchedRegion>{
          // Entering from the bar touches the mover's own end of it...
          (region: RoiId.bar, side: CheckerColor.white),
          // ...the point entered...
          (region: RoiId.point(20), side: null),
          // ...and, because that entry hit, the OTHER player's end of the bar,
          // which is where the man it hit is now standing.
          (region: RoiId.bar, side: CheckerColor.black),
          (region: RoiId.point(5), side: null),
          (region: RoiId.offWhite, side: CheckerColor.white),
        },
      );
    });

    test('an intermediate landing point counts as touched', () {
      // `13/11 11/6` and `13/8 8/6` leave the same position and a settled
      // frame cannot tell them apart — but a hand went through the middle
      // point, and the session that dictated the play knows which one. It is
      // asked about, because a checker left standing there is exactly the
      // placement error this query exists to catch.
      final play = Move(<CheckerMove>[
        const CheckerMove(12, 10),
        const CheckerMove(10, 5),
      ]);
      expect(
        regionsTouchedBy(play, Player.white).map((t) => t.region).toSet(),
        <RoiId>{RoiId.point(12), RoiId.point(10), RoiId.point(5)},
      );
    });

    test('a board wrong somewhere the play never went still verifies the '
        'placement', () {
      final bed = _bedOf(_beds.first);
      // The frame holds the starting position; the game is told a lie about
      // the 8-point, which no play below goes anywhere near.
      final lie = BoardState(points: <int>[
        for (final (i, c) in BoardState.initial().points.indexed)
          i == 7 ? c - 1 : c,
      ]);
      final result = bed.verify(BoardState.initial(), lie);
      expect(result.agrees, isFalse,
          reason: 'the whole-board sweep must still see the lie');

      final elsewhere = Move(<CheckerMove>[const CheckerMove(12, 8)]);
      expect(
        result.agreesOn(regionsTouchedBy(elsewhere, Player.white)),
        isTrue,
        reason: result.message,
      );
      // And the same frame, asked about a play that DID go there.
      final through = Move(<CheckerMove>[const CheckerMove(7, 3)]);
      expect(result.agreesOn(regionsTouchedBy(through, Player.white)), isFalse);
      expect(
        result.discrepanciesOn(regionsTouchedBy(through, Player.white))
            .map((d) => d.region),
        <RoiId>[RoiId.point(7)],
      );
    });

    test('a region this board does not have cannot fail a placement', () {
      // A folding case has no bear-off wells, so a play that bore a man off
      // touches a region nothing in the picture can speak about. Consuming
      // `BoardDiscrepancies.unobservable`'s philosophy exactly: not a
      // contradiction, so not a failed placement.
      final bed = _bedOf(_foldingBed);
      final board = BoardState.initial();
      final result = bed.verify(board, board);
      final bearOff = Move(<CheckerMove>[
        const CheckerMove(5, CheckerMove.off),
      ]);
      expect(
        result.forRegion(RoiId.offWhite, side: CheckerColor.white)?.verdict,
        RegionVerdict.unobservable,
      );
      expect(result.agreesOn(regionsTouchedBy(bearOff, Player.white)), isTrue,
          reason: result.message);
    });
  });

  group('the prior earns its keep', () {
    test('a four-stack is not a five-stack, and the verifier says which '
        'region', () {
      // The plan's own case. One checker fewer than the game expects, on a
      // point that holds nothing else — the shape of a dictated move the user
      // half-made.
      final bed = _bedOf(_beds.first);
      final expected = _stackOf(3, 5);
      final onTheTable = _stackOf(3, 4);
      final result = bed.verify(onTheTable, expected);
      expect(result.agrees, isFalse, reason: result.message);
      expect(result.discrepancies.single.region, RoiId.point(3));
      expect(result.discrepancies.single.kind, DiscrepancyKind.wrongCount);
      expect(result.discrepancies.single.expected, 5);

      // And the five-stack itself verifies clean, or the test above would pass
      // on a verifier that simply disagreed with everything.
      expect(bed.verify(expected, expected).agrees, isTrue);
    });

    test('a stack a blind count gets WRONG still verifies against the count '
        'the game holds', () {
      // **The band the prior buys, measured.** This bed is calibrated under a
      // lamp gradient and read with the stacks left a hand's width in — two of
      // the known hard cases at once — and on it a SIX-stack measures 5.48
      // checkers and a genuine five-stack 5.38.
      //
      // Blind, those are the same answer: five, both times. A blind reader has
      // to round and rounding is exactly where the difference lives, so it
      // cannot tell six checkers from five here and reports the six-stack
      // wrongly. Handed the game's own six, the residual rounding threw away is
      // enough — 0.52 of a checker, inside [BoardVerifier.stackTolerance] — and
      // the region verifies clean.
      //
      // This is the whole argument for a state-primed query in one region.
      final bed = _bedOf(_overflowBed);
      final six = _stackOf(20, 6);
      final blind = bed.blindCountAt(six, RoiId.point(20));
      expect(blind, 5,
          reason: 'the bed no longer reproduces the case this test is about: '
              'a blind count of a six-stack came back $blind, not 5');
      expect(bed.blindCountAt(_stackOf(20, 5), RoiId.point(20)), blind,
          reason: 'a blind count must be unable to tell the two apart, or the '
              'prior is not what is doing the work here');

      final region = bed.verify(six, six).forRegion(RoiId.point(20))!;
      expect(region.verdict, RegionVerdict.agrees, reason: region.message);
      expect(region.observedCount, 5,
          reason: 'the blind reading the resolve UI shows is still the wrong '
              'one — it is the verdict that is right, not the count');
    });
  });

  group('the bar on a worn hinge', () {
    test('the real corpus keyframe 066 verifies its Black checker', () {
      // **The acceptance test.** A real Black man standing on a real worn
      // spine, photographed. Blind occupancy reads the bar as empty; the
      // verifier is handed "one Black on the bar" and has to agree.
      final session = _realSession();
      final shot = session.shot('066');
      expect(shot.board.blackBar, 1,
          reason: 'the corpus moved under this test');

      final result = session.verify('066', shot.board);
      final bar = result.regions.singleWhere(
        (r) => r.region == RoiId.bar && r.side == CheckerColor.black,
      );
      stdout.writeln('\n  066 BAR, verbatim:\n    ${bar.message}\n'
          '    verdict ${bar.verdict.name}'
          '${bar.kind == null ? '' : ' (${bar.kind!.name})'}, '
          'height ${bar.observedHeight.toStringAsFixed(2)}, '
          'reach ${bar.reach.toStringAsFixed(4)}\n');
      expect(bar.verdict, RegionVerdict.agrees,
          reason: 'the flagship case: ${bar.message}');
    });

    test('and a bar with nothing on it does NOT verify one', () {
      // The other half, on the same board and the same hinge: 070's bar is
      // bare. The object walk finding nothing IS a contradiction, and a
      // verifier that agreed here would be agreeing with anything.
      final session = _realSession();
      expect(session.shot('070').board.blackBar, 0);
      final claim = BoardState(
        points: session.shot('070').board.points,
        blackBar: 1,
        whiteOff: session.shot('070').board.whiteOff,
      );
      final result = session.verify('070', claim);
      final bar = result.regions.singleWhere(
        (r) => r.region == RoiId.bar && r.side == CheckerColor.black,
      );
      expect(bar.verdict, RegionVerdict.disagrees, reason: bar.message);
      expect(bar.kind, DiscrepancyKind.unexpectedlyEmpty);
    });

    test('the same pair on a synthetic worn spine', () {
      // The bed's own version, so the case fails a test rather than a
      // photograph when somebody changes the walk. See [SpineWear.worn].
      final bed = _bedOf(_wornSpineBed);
      final withBlack = _oneOnTheBar(white: false);
      expect(bed.verify(withBlack, withBlack).agrees, isTrue,
          reason: bed.verify(withBlack, withBlack).message);

      final bare = BoardState.initial();
      final result = bed.verify(bare, withBlack);
      final bar = result.regions.singleWhere(
        (r) => r.region == RoiId.bar && r.side == CheckerColor.black,
      );
      expect(bar.verdict, RegionVerdict.disagrees);
      expect(bar.kind, DiscrepancyKind.unexpectedlyEmpty);
    });
  });

  group('regions this board does not have', () {
    test('a trayless board reports its trays unobservable, never agreed', () {
      // Consuming `PlayMatch.unobservable`'s philosophy: a folding case has no
      // bear-off wells, so a borne-off checker leaves the board and nothing in
      // the picture can confirm or contradict it. Reported, never scored.
      final bed = _bedOf(_foldingBed);
      final expected = BoardState(
        points: <int>[
          for (final (i, c) in BoardState.initial().points.indexed)
            i == 5 ? c - 2 : c,
        ],
        whiteOff: 2,
      );
      final result = bed.verify(expected, expected);
      expect(result.unobservable.map((r) => r.region),
          contains(RoiId.offWhite));
      final tray = result.unobservable
          .firstWhere((r) => r.region == RoiId.offWhite);
      expect(tray.verdict, RegionVerdict.unobservable);
      expect(tray.agrees, isFalse,
          reason: 'an unobservable region is not evidence that the board is '
              'right — it is the absence of evidence either way');
      expect(result.discrepancies.map((d) => d.region),
          isNot(contains(RoiId.offWhite)),
          reason: 'and it must not contradict either');
      expect(result.agrees, isTrue, reason: result.message);
    });

    test('a board WITH wells has its trays verified like any other region',
        () {
      final bed = _bedOf(_beds.first);
      final expected = BoardState(
        points: <int>[
          for (final (i, c) in BoardState.initial().points.indexed)
            i == 5 ? c - 2 : c,
        ],
        whiteOff: 2,
      );
      final result = bed.verify(expected, expected);
      expect(result.unobservable, isEmpty);
      expect(result.agrees, isTrue, reason: result.message);
    });
  });

  group('the order the resolve screen reads in', () {
    test('a colour that flipped outranks a tall stack that read short', () {
      // **Colour beats count, and the ordering is where that claim is
      // spent.** `BoardDiscrepancies.discrepancies` is sorted strongest first
      // because that is what a resolve screen shows at the top and what a
      // spoken correction names first — so if a colour contradiction (0.954
      // measured) ever sorted below a tall-stack count miss (the far-half
      // undercount, and the weakest evidence there is), the user would be sent
      // to the wrong region first every time both were present.
      //
      // This is also the test that catches the confidence being taken from the
      // wrong side of a colour flip: `readFor` on a colour a region does NOT
      // hold returns an empty reading whose own confidence collapses as the
      // other colour fills the region, so weighing the contradiction by it
      // would make the clearest colour flips the least confident findings on
      // the board.
      final bed = _bedOf(_beds.first);
      final expected = BoardState(points: <int>[
        for (var i = 0; i < 24; i++)
          switch (i) { 3 => 2, 20 => 5, 23 => -5, _ => 0 },
      ]);
      // The 4-point has changed hands, and the 21-point is two men short —
      // far enough out to be the strongest kind of count contradiction there
      // is, so that colour has something worth outranking.
      final onTheTable = BoardState(points: <int>[
        for (var i = 0; i < 24; i++)
          switch (i) { 3 => -2, 20 => 3, 23 => -5, _ => 0 },
      ]);
      final result = bed.verify(onTheTable, expected);
      expect(result.discrepancies.map((d) => d.region),
          <RoiId>[RoiId.point(3), RoiId.point(20)],
          reason: result.discrepancies
              .map((d) => '${d.message} @${d.confidence}')
              .join('; '));
      expect(result.discrepancies.first.kind, DiscrepancyKind.wrongColour);
      expect(result.discrepancies.last.kind, DiscrepancyKind.wrongCount);
    });

    test('and every contradiction is discounted by how well it was measured',
        () {
      // The other half of what a confidence here is: a **kind** of evidence,
      // worth what the corpus measured that kind to be, times the **reading**
      // it came out of. A five-stack is a reading the occupancy reader
      // distrusts by design — the doubt grows with the stack — so a
      // contradiction found on one cannot be worth the full weight of its kind.
      //
      // Without that factor a contradiction on the one region nobody trusts
      // would outrank one on a region measured cleanly, which is the hole
      // `PlayMatcher.minEvidence` exists to close on the other query.
      final bed = _bedOf(_beds.first);
      final result = bed.verify(_stackOf(20, 3), _stackOf(20, 5));
      final count = result.discrepancies
          .singleWhere((d) => d.kind == DiscrepancyKind.wrongCount);
      expect(count.confidence, lessThan(BoardVerifier.tallStackFarMiss),
          reason: 'a five-stack the reader half-trusts produced a '
              'contradiction worth the full weight of its kind: $count');
      expect(count.confidence, greaterThan(0));
    });
  });

  group('what the drift report suggests', () {
    test('a tall stack reading short is the camera, not the board', () {
      // The measured far-half undercount: on the real corpus a five-stack
      // reads 1.6 checkers short on average and a six-stack four. A count-only
      // miss on a tall stack is therefore the instrument, and the report has to
      // say so rather than sending the user to move a checker that is already
      // right.
      final bed = _bedOf(_beds.first);
      final expected = _stackOf(3, 5);
      final onTheTable = _stackOf(3, 4);
      final report = bed.drift(onTheTable, expected);
      expect(report.agrees, isFalse);
      final finding = report.findings
          .firstWhere((f) => f.region.region == RoiId.point(3));
      expect(finding.resolution, DriftResolution.trustTheGame);
      expect(finding.suggestion, contains('camera'));
    });

    test('a colour that flipped on a short stack is the board', () {
      final bed = _bedOf(_beds.first);
      final expected = _stackOf(3, 2);
      final onTheTable = _stackOf(3, -2);
      final report = bed.drift(onTheTable, expected);
      final finding = report.findings
          .firstWhere((f) => f.region.region == RoiId.point(3));
      expect(finding.region.kind, DiscrepancyKind.wrongColour);
      expect(finding.resolution, DriftResolution.moveTheCheckers);
    });

    test('a man standing where the game says nothing is the board', () {
      final bed = _bedOf(_beds.first);
      final expected = BoardState.initial();
      final onTheTable = BoardState(points: <int>[
        for (final (i, c) in expected.points.indexed)
          switch (i) { 4 => c + 1, 5 => c - 1, _ => c },
      ]);
      final report = bed.drift(onTheTable, expected);
      final finding = report.findings
          .firstWhere((f) => f.region.region == RoiId.point(4));
      expect(finding.resolution, DriftResolution.moveTheCheckers);
    });

    test('and a region the board does not have is nobody\'s to resolve', () {
      final bed = _bedOf(_foldingBed);
      final expected = BoardState(
        points: <int>[
          for (final (i, c) in BoardState.initial().points.indexed)
            i == 5 ? c - 2 : c,
        ],
        whiteOff: 2,
      );
      final report = bed.drift(expected, expected);
      expect(report.agrees, isTrue);
      final tray = report.findings
          .firstWhere((f) => f.region.region == RoiId.offWhite);
      expect(tray.resolution, DriftResolution.cannotBeSeen);
    });
  });

  group('the hard cases, doubled up at corpus grade', () {
    for (final plan in _hardBeds) {
      test('${plan.name}: a correct board still verifies clean', () {
        final bed = _bedOf(plan);
        final result = bed.verify(BoardState.initial(), BoardState.initial());
        expect(result.agrees, isTrue,
            reason: '${plan.name}: ${result.message}');
      });
    }

    test('a lamp down the table hides four Black stacks, and the verifier '
        'says so rather than agreeing', () {
      // **The case that must NOT verify clean**, and the one that decided how
      // a missing stack is routed. `checkersUnderLamp` paints the gradient
      // measured off the real frame's 19-point, and on the classic palette —
      // the bed's only near-black checker — four of the starting position's
      // Black stacks leave runs of 0.02 to 0.03 where a checker is 0.09 deep.
      //
      // A verifier that agreed here would be agreeing with a photograph of a
      // board it cannot see, which is the one thing this query must never do.
      // What it says instead is "the camera sees nothing" on exactly those
      // four, and every one of them goes to the user rather than to either
      // side's version of events — because a stack the camera lost and a stack
      // the user never placed look identical from here.
      final bed = _bedOf(_lampBed);
      final result = bed.verify(BoardState.initial(), BoardState.initial());
      expect(result.agrees, isFalse, reason: result.message);
      expect(
        result.discrepancies.map((d) => d.region).toSet(),
        <RoiId>{RoiId.point(0), RoiId.point(11), RoiId.point(16),
            RoiId.point(18)},
        reason: result.message,
      );
      for (final d in result.discrepancies) {
        expect(d.kind, DiscrepancyKind.unexpectedlyEmpty, reason: d.message);
        expect(d.side, CheckerColor.black, reason: d.message);
      }
      final report = bed.drift(BoardState.initial(), BoardState.initial());
      expect(report.needsUser, isTrue);
      for (final f in report.findings) {
        expect(f.resolution, DriftResolution.askTheUser,
            reason: f.suggestion);
      }
    });
  });
}

// --- the beds ---------------------------------------------------------------

typedef _BedPlan = ({
  String name,
  BoardPalette palette,
  BoardQuad quad,
  BoardProportions proportions,
  bool folding,
  SpineWear spine,
  StackPlacement calibrationPlacement,
  StackPlacement readPlacement,
  ShotDegradation degradation,
});

_BedPlan _plan({
  required String name,
  BoardPalette palette = BoardPalette.classic,
  BoardQuad quad = kCorpusSteepQuad,
  BoardProportions proportions = BoardProportions.standard,
  bool folding = false,
  SpineWear spine = SpineWear.none,
  StackPlacement calibrationPlacement = StackPlacement.flush,
  StackPlacement? readPlacement,
  ShotDegradation degradation = _corpusGrade,
}) =>
    (
      name: name,
      palette: palette,
      quad: quad,
      proportions: proportions,
      folding: folding,
      spine: spine,
      calibrationPlacement: calibrationPlacement,
      readPlacement: readPlacement ?? calibrationPlacement,
      degradation: degradation,
    );

/// The two beds the clean matrix runs on: two palettes, two viewpoints.
final List<_BedPlan> _beds = <_BedPlan>[
  _plan(name: 'classic, steep'),
  _plan(
    name: 'low-contrast wood, low and rolled',
    palette: BoardPalette.lowContrastWood,
    quad: kCorpusLowQuad,
  ),
];

/// A folding case: no wells, a hinge for a bar. What the real corpus is shot
/// on, and the board that makes a bear-off unobservable.
final _BedPlan _foldingBed = _plan(
  name: 'folding case',
  palette: BoardPalette.lowContrastWood,
  proportions: const BoardProportions(trayWidth: 0, barWidth: 0.03),
);

/// A folding case whose spine is worn the way the real one is.
final _BedPlan _wornSpineBed = _plan(
  name: 'worn spine',
  folding: true,
  spine: SpineWear.worn,
  degradation: ShotDegradation.none,
);

/// Calibrated under a lamp gradient, read with the stacks left a hand's width
/// in — the bed on which a blind count cannot tell six checkers from five.
final _BedPlan _overflowBed = _plan(
  name: 'lamp gradient, stacks left in',
  calibrationPlacement: checkersUnderLamp,
  readPlacement: const StackPlacement(edgeInset: 0.05),
);

/// The known hard cases, each at the corpus's own degradation. The lamp is not
/// here: it is a case the verifier deliberately does NOT pass, and it has its
/// own test.
final List<_BedPlan> _hardBeds = <_BedPlan>[
  _plan(
    name: 'stacks left a hand\'s width in',
    readPlacement: const StackPlacement(edgeInset: 0.04),
  ),
  _plan(name: 'a worn spine', folding: true, spine: SpineWear.worn),
  _plan(
    name: 'the palette whose pale points sit nearest its white checkers',
    palette: BoardPalette.blueRed,
    quad: kCorpusLowQuad,
  ),
];

/// A lamp down the table, on the one palette whose dark checkers are nearly
/// black — the case that measures what happens when the camera simply cannot
/// see a stack. See the test that uses it.
final _BedPlan _lampBed =
    _plan(name: 'a lamp down the stacks', readPlacement: checkersUnderLamp);

const ShotDegradation _corpusGrade =
    ShotDegradation(noise: 2, blurSigma: 0.5, seed: 4242);

final Map<String, _Bed> _built = <String, _Bed>{};

_Bed _bedOf(_BedPlan plan) => _built.putIfAbsent(plan.name, () => _Bed(plan));

/// One session on the synthetic bed: calibrated once from the starting
/// position, then asked whether later frames hold what a caller says they do.
class _Bed {
  final _BedPlan plan;
  late final BoardVision vision;
  final Map<BoardState, Frame> _frames = <BoardState, Frame>{};

  _Bed(this.plan) {
    final start = _render(BoardState.initial(), plan.calibrationPlacement);
    final result = plan.folding
        ? BoardVision.calibrateFolding(
            frame: start.$1,
            corners: start.$2!,
            orientation: BoardOrientation.whiteHomeNear,
          )
        : BoardVision.calibrate(
            frame: start.$1,
            corners: start.$3!,
            orientation: BoardOrientation.whiteHomeNear,
            proportions: plan.proportions,
          );
    expect(result.ok, isTrue, reason: '${plan.name}: ${result.message}');
    vision = BoardVision(result.calibration!);
  }

  Frame frameOf(BoardState board) => _frames.putIfAbsent(
      board, () => _render(board, plan.readPlacement).$1);

  /// What the verifier says about [expected] when the board in front of the
  /// camera is [onTheTable].
  BoardDiscrepancies verify(BoardState onTheTable, BoardState expected) =>
      vision.verifyExpectedBoard(frameOf(onTheTable), expected);

  DriftReport drift(BoardState onTheTable, BoardState expected) =>
      vision.recoverFromDrift(frameOf(onTheTable), expected);

  /// What a BLIND read of [region] says, with no expectation to lean on.
  int blindCountAt(BoardState onTheTable, RoiId region) =>
      vision.occupancyIn(frameOf(onTheTable)).read(region).count;

  (Frame, FoldingCorners?, BoardQuad?) _render(
    BoardState board,
    StackPlacement placement,
  ) {
    if (plan.folding) {
      final shot = renderFoldingShot(
        board: _onFelt(board),
        palette: plan.palette,
        spine: plan.spine,
        stackPlacement: placement,
        degradation: plan.degradation,
      );
      return (shot.frame, shot.groundTruthCorners, null);
    }
    final shot = renderShot(
      board: plan.proportions.hasTrays ? board : _onFelt(board),
      palette: plan.palette,
      proportions: plan.proportions,
      stackPlacement: placement,
      quad: plan.quad,
      degradation: plan.degradation,
    );
    return (shot.frame, null, shot.groundTruthQuad);
  }
}

BoardState _onFelt(BoardState board) => BoardState(
      points: board.points,
      whiteBar: board.whiteBar,
      blackBar: board.blackBar,
    );

// --- positions --------------------------------------------------------------

/// Positions with stacks of every height on both halves.
final List<BoardState> _positions = <BoardState>[
  BoardState.initial(),
  BoardState(points: const <int>[
    4, 3, 2, 1, 0, 5, //  1-6
    0, 0, -2, 0, 0, -5, //  7-12
    5, 0, 0, 0, -3, 0, // 13-18
    -5, 0, 0, 0, 0, 0, // 19-24
  ]),
];

/// A board holding [count] men of one colour on one point and nothing else —
/// the shape of a dictated placement, isolated so nothing else can explain a
/// discrepancy. Negative [count] is Black.
BoardState _stackOf(int index, int count) => BoardState(points: <int>[
      for (var i = 0; i < 24; i++)
        i == index
            ? count
            : i == 23
                ? -5
                : 0,
    ]);

BoardState _oneOnTheBar({required bool white}) {
  final points = List<int>.of(BoardState.initial().points);
  if (white) {
    points[23] -= 1;
  } else {
    points[0] += 1;
  }
  return BoardState(
    points: points,
    whiteBar: white ? 1 : 0,
    blackBar: white ? 0 : 1,
  );
}

// --- the real corpus --------------------------------------------------------

_RealSession? _realCache;

_RealSession _realSession() => _realCache ??= _RealSession();

/// The filmed session, calibrated exactly as the harness calibrates it.
class _RealSession {
  static final Directory directory = Directory('test/corpus/real');
  final List<CorpusShot> shots = loadSidecars(directory);
  late final BoardVision vision;

  _RealSession() {
    final calibration = shots.firstWhere((s) => s.kind == ShotKind.calibration);
    final result = BoardVision.calibrateFolding(
      frame: _frameOf(calibration.id),
      corners: calibration.foldingCorners!,
      orientation: calibration.orientation,
      dieSide: calibration.dieSide ?? BoardCalibration.defaultDieSide,
    );
    expect(result.ok, isTrue, reason: result.message);
    vision = BoardVision(result.calibration!);
  }

  CorpusShot shot(String id) => shots.firstWhere((s) => s.id == id);

  Frame _frameOf(String id) =>
      decodeCorpusImage(imageFileFor(directory, shot(id))!);

  BoardDiscrepancies verify(String id, BoardState expected) =>
      vision.verifyExpectedBoard(_frameOf(id), expected);
}
