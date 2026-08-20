import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// The board that made [FoldingBoardGeometry] exist: a folding case whose two
/// leaves are **not coplanar**.
///
/// `trayless_board_test.dart` already reads a folding board's *proportions* —
/// no wells, a hinge for a bar. This is the other half of the same board, and
/// it is a geometry problem rather than a widths problem. A case standing open
/// on a table is tented: the spine in the middle stands proud of the leaves,
/// which is exactly where the hinge strip is and exactly where hit checkers
/// sit. Two planes and a ridge, not one plane.
///
/// The measurement that forced this, taken off the first real calibration
/// frame: fit ONE homography to the four outer corners and the two halves
/// rectify to column pitches **13% apart** — physically impossible for two
/// identical leaves. Rectify each leaf under its own quad and the pitch is
/// uniform to within 5%, the stacks sit dead centre in their columns, and the
/// triangles run flush to the leaf edges. Every gate in the pipeline refused
/// the single-plane fit, across a sweep of 21 (trayWidth, barWidth) pairs;
/// none of them was the answer, because the answer was not a width.
///
/// Folding cases are probably the most common board in a home, so this is a
/// product problem rather than a corpus curiosity.
void main() {
  group('the bed itself', () {
    test('a tented render is genuinely not one plane, and a flat one is', () {
      // The guard on everything below. If the renderer produced three quads
      // that happened to share a plane, every folding test here would pass on
      // a pipeline that had learned nothing — and the mismatch test, which
      // asserts a REFUSAL, would be the one that quietly stopped meaning
      // anything. So the bed is measured the same way the real frame was.
      expect(_singlePlanePitchSkew(kFoldingTent), greaterThan(0.10),
          reason: 'the tent has to reproduce the real board\'s diagnostic: a '
              'single-homography fit rectifying the two halves to column '
              'pitches about 13% apart');
      expect(_singlePlanePitchSkew(kFoldingTent.flat), lessThan(0.01),
          reason: 'and the same measurement on a board lying flat has to come '
              'out at nothing, or it is measuring the camera rather than the '
              'tent');
    });
  });

  group('a tented folding board, calibrated as two leaves and a hinge', () {
    test('calibrates, and confirms as the starting position', () {
      final shot = renderFoldingShot(board: BoardState.initial());
      final result = BoardVision.calibrateFolding(
        frame: shot.frame,
        corners: shot.groundTruthCorners,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isTrue, reason: result.message);

      final calibration = result.calibration!;
      expect(calibration.geometry, isA<FoldingBoardGeometry>());
      // The proportions are DERIVED on this board rather than measured: a
      // folding case has no wells, and the hinge's width is what the eight
      // tapped points already say.
      expect(calibration.proportions.trayWidth, 0);
      expect(calibration.proportions.hasTrays, isFalse);
      expect(calibration.atlas.proportions, calibration.proportions,
          reason: 'the atlas a calibration hands out has to be the one its '
              'colours were learned through');

      final confirmed =
          BoardVision(calibration).confirmStartingPosition(shot.frame);
      expect(confirmed.agrees, isTrue, reason: confirmed.message);
    });

    test('counts the outer columns and the two against the hinge', () {
      // The outer columns are what a width error moves most; the two against
      // the hinge are what a PLANE error moves most, since they sit where the
      // leaves stop agreeing with each other. Both, or the test only covers
      // half the failure.
      final shot = renderFoldingShot(board: BoardState.initial());
      final reader =
          BoardVision(_calibrate(shot)).occupancyIn(shot.frame);
      final start = BoardState.initial();

      for (final index in <int>[0, 11, 12, 23, 5, 18]) {
        final signed = start.points[index];
        final reading = reader.read(RoiId.point(index));
        expect(
          reading.color,
          signed > 0 ? CheckerColor.white : CheckerColor.black,
          reason: 'point ${index + 1} holds $signed, read $reading',
        );
        expect(reading.count, signed.abs(),
            reason: 'point ${index + 1} holds ${signed.abs()}, read $reading');
      }
    });

    for (final inset in <double>[0.03, 0.04, 0.07]) {
      test('stacks left $inset in are counted, or the frame is refused', () {
        // **The worst reading this pipeline can produce, and it was here.**
        // On this board with the stacks left a hand's width in, one of the
        // eight labelled stacks measured a run of a SINGLE row out of 120 —
        // reach 0.004 where its twins reach 0.45. Least squares regressed
        // through it anyway, the pitch collapsed from 0.087 to 0.039,
        // `StackMetrics.minPitch` is 0.02 so nothing fired, and every count on
        // the board was then divided by less than half the truth: the
        // five-stacks read 8, the short ones read 1. Calibration said yes and
        // `confirm` agreed, so nothing anywhere told the user a word.
        //
        // The same defect, on the first real folding photograph, put ten of
        // twenty-four points wrong on the frame a whole session calibrates
        // from — see `occupancy_test`'s 'a stack that failed to measure is not
        // data', which carries that frame's eight pairs.
        //
        // Both outcomes are acceptable and the geometry decides which: either
        // the failed stack is excluded and the surviving ones give a pitch
        // that counts the board correctly, or too few survive and calibration
        // refuses. What is not acceptable is a confident wrong number.
        final shot = renderFoldingShot(
          board: BoardState.initial(),
          stackPlacement: StackPlacement(edgeInset: inset),
        );
        final result = BoardVision.calibrateFolding(
          frame: shot.frame,
          corners: shot.groundTruthCorners,
          orientation: BoardOrientation.whiteHomeNear,
        );
        if (!result.ok) {
          expect(result.message, isNotEmpty);
          return;
        }
        final vision = BoardVision(result.calibration!);
        final reader = vision.occupancyIn(shot.frame);
        final start = BoardState.initial();
        for (var i = 0; i < 24; i++) {
          expect(reader.read(RoiId.point(i)).count, start.points[i].abs(),
              reason: 'point ${i + 1} holds ${start.points[i].abs()} with '
                  'every stack $inset in from its edge, and calibration was '
                  'happy: ${result.calibration!.stacks}');
        }
      });
    }

    test('a checker on the hinge strip reads as a checker on the bar', () {
      // Where a hit checker physically goes on this board — there is no well,
      // so it sits on the raised spine. That strip has its own plane, and this
      // is the assertion that the strip is mapped rather than guessed at from
      // either leaf.
      final start = renderFoldingShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final points = List<int>.of(BoardState.initial().points);
      points[0] += 1; // one of Black's two off the 1-point...
      final hit = renderFoldingShot(
        board: BoardState(points: points, blackBar: 1), // ...onto the hinge.
      );
      final reader = vision.occupancyIn(hit.frame);

      final onBar = reader.readFor(RoiId.bar, CheckerColor.black);
      expect(onBar.color, CheckerColor.black, reason: '$onBar');
      expect(onBar.count, 1, reason: '$onBar');
      expect(reader.readFor(RoiId.bar, CheckerColor.white).count, 0);
    });

    test('reads a pair of dice lying one on each leaf', () {
      // The dice band crosses the hinge, so the two dice are read through two
      // different planes in one pass. Nothing in the dice reader knows that —
      // it walks a lattice in board space, and each cell routes itself.
      final start = renderFoldingShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final rolled = renderFoldingShot(
        board: BoardState.initial(),
        dicePlacements: const <DicePlacement>[
          DicePlacement(face: 5, center: Pt(0.20, 0.5)),
          DicePlacement(face: 2, center: Pt(0.75, 0.5)),
        ],
      );
      final reading = vision.readDice(rolled.frame);
      expect(reading, isNotNull, reason: 'no pair found across the hinge');
      expect(
        <int>[reading!.first.face, reading.second.face]..sort(),
        <int>[2, 5],
      );
    });
  });

  group('the mismatch: a tented board read as one plane', () {
    // The point of the whole change, and the thing that actually happened with
    // the real frame. If the geometry were decorative these would pass green
    // with it ignored.

    test('refuses the tented board through the ordinary planar path', () {
      final shot = renderFoldingShot(board: BoardState.initial());
      final outer = _outerQuadOf(shot.groundTruthCorners);

      for (final (name, proportions) in <(String, BoardProportions?)>[
        // What a user who has not measured anything gets.
        ('the standard widths', null),
        // And what a user who measured the widths correctly but never
        // suspected the tent gets — which is the interesting one, because the
        // widths are RIGHT here and the calibration must still be refused.
        ('the folding board\'s own widths', shot.proportions),
      ]) {
        final result = BoardVision.calibrate(
          frame: shot.frame,
          corners: outer,
          orientation: BoardOrientation.whiteHomeNear,
          proportions: proportions ?? BoardProportions.standard,
        );
        expect(result.ok, isFalse,
            reason: 'one plane through the outer corners reads this board '
                'most of a column out of true on $name and must not hand over '
                'a calibration that does it: ${result.message}');
        expect(result.problem, isNotNull);

        // Loudly, and in words a user can act on.
        expect(result.message, isNotEmpty);
        expect(result.message, endsWith('.'));
        expect(result.message.split(' ').length, greaterThan(6));
        for (final leak in <String>['RoiId', 'Homography', 'null']) {
          expect(result.message, isNot(contains(leak)));
        }
      }
    });

    test('and refuses a best-fit planar sweep of every plausible width', () {
      // The sweep that was actually run against the real frame, in miniature.
      // No (trayWidth, barWidth) pair rescues a single plane, because the
      // problem is not a width — and a test that only tried ONE wrong pair
      // could not tell those two failures apart.
      final shot = renderFoldingShot(board: BoardState.initial());
      final outer = _outerQuadOf(shot.groundTruthCorners);
      final succeeded = <String>[];

      for (final tray in <double>[0, 0.02, 0.04, 0.06, 0.08]) {
        for (final bar in <double>[0.03, 0.05, 0.07, 0.09]) {
          final result = BoardVision.calibrate(
            frame: shot.frame,
            corners: outer,
            orientation: BoardOrientation.whiteHomeNear,
            proportions: BoardProportions(trayWidth: tray, barWidth: bar),
          );
          if (result.ok) succeeded.add('tray $tray / bar $bar');
        }
      }
      expect(succeeded, isEmpty,
          reason: 'a single plane must not be rescuable by any width: '
              '${succeeded.join(", ")}');
    });

    test('while the same frame calibrates as a folding board, which is what '
        'makes the refusals above mean something', () {
      // The control. Without it the group would pass on a pipeline that
      // refused every board it was ever shown.
      final shot = renderFoldingShot(board: BoardState.initial());
      final result = BoardVision.calibrateFolding(
        frame: shot.frame,
        corners: shot.groundTruthCorners,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isTrue, reason: result.message);
    });
  });

  group('a spine worn the way a real one is', () {
    // The one thing the first real folding frame refused on, once its corners
    // were right: 24 of 24 columns read back correctly and the BAR came back
    // holding a checker that was not there. Its hinge is a ridge worn by
    // decades of use — a near-black crack down the middle where the leaves
    // meet, a pale rubbed crown either side of it, untouched wood on the
    // flanks — and 168 of the band's 400 calibration samples classified as
    // checkers, 115 of them White. See [SpineWear].
    //
    // The fix is the principle the whole calibration design already rests on,
    // pushed one step further: the starting position labels the bar EMPTY, so
    // a checker-coloured sample there is not a checker. It is a surface nobody
    // has modelled yet, and it belongs in the bar's background.

    test('needs more surfaces than a clean one — which is what makes the rest '
        'of this group mean anything', () {
      // The guard. If the worn bed happened to be readable with the two
      // surfaces every region gets, the tests below would pass on a pipeline
      // that had learned nothing, and the refusal they replace would never
      // have been reproduced at all.
      final clean = _calibrate(renderFoldingShot(board: BoardState.initial()));
      final worn = _calibrate(renderFoldingShot(
        board: BoardState.initial(),
        spine: SpineWear.worn,
      ));
      expect(clean.colors.backgroundOf(RoiId.bar).modes, hasLength(1),
          reason: 'a spine straight out of the shop is one piece of wood, and '
              'one surface is all the bar should need for it');
      expect(worn.colors.backgroundOf(RoiId.bar).modes.length, greaterThan(2),
          reason: 'a worn spine has more surfaces than the two a region is '
              'given, and the bar has to have LEARNED the extra ones rather '
              'than reporting them as checkers');
    });

    test('calibrates, and confirms as the starting position', () {
      for (final palette in BoardPalette.all) {
        final shot = renderFoldingShot(
          board: BoardState.initial(),
          palette: palette,
          spine: SpineWear.worn,
        );
        final result = BoardVision.calibrateFolding(
          frame: shot.frame,
          corners: shot.groundTruthCorners,
          orientation: BoardOrientation.whiteHomeNear,
        );
        expect(result.ok, isTrue,
            reason: '${palette.name}: ${result.message}');
        final confirmed = BoardVision(result.calibration!)
            .confirmStartingPosition(shot.frame);
        expect(confirmed.agrees, isTrue,
            reason: '${palette.name}: ${confirmed.message}');
      }
    });

    test('and a checker standing ON the worn spine still reads as one, either '
        'colour', () {
      // The risk the fix has to be engineered against, said out loud: absorb
      // the pale crown into the bar's background carelessly and a cream
      // checker sitting on that crown mid-game becomes invisible — which is
      // worse than the refusal it cured, because it is silent. Both colours,
      // and the pale one especially: it is the one whose colour the wear is
      // closest to.
      final start = renderFoldingShot(
        board: BoardState.initial(),
        spine: SpineWear.worn,
      );
      final vision = BoardVision(_calibrate(start));

      for (final (colour, state) in <(CheckerColor, BoardState)>[
        (CheckerColor.white, _oneOnTheBar(white: true)),
        (CheckerColor.black, _oneOnTheBar(white: false)),
      ]) {
        final hit = renderFoldingShot(board: state, spine: SpineWear.worn);
        final reading =
            vision.occupancyIn(hit.frame).readFor(RoiId.bar, colour);
        expect(reading.color, colour, reason: '${colour.name}: $reading');
        expect(reading.count, 1, reason: '${colour.name}: $reading');

        // And the start-position check has to see it too, since that is the
        // screen a user would be looking at.
        final confirmed = vision.confirmStartingPosition(hit.frame);
        expect(confirmed.agrees, isFalse, reason: colour.name);
        expect(
          confirmed.discrepancies
              .firstWhere((d) => d.region == RoiId.bar)
              .observed,
          colour,
          reason: '${colour.name}: ${confirmed.message}',
        );
      }
    });
  });

  group('a folding board lying flat', () {
    test('calibrates through the folding path too — it is just two coplanar '
        'leaves', () {
      // No special case anywhere: a flat folding board is three quads that
      // happen to share a plane, and the routing does not care. Worth pinning
      // because the alternative design — detect the tent, branch — would have
      // needed one.
      final shot = renderFoldingShot(
        board: BoardState.initial(),
        view: kFoldingTent.flat,
      );
      final result = BoardVision.calibrateFolding(
        frame: shot.frame,
        corners: shot.groundTruthCorners,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(
        BoardVision(result.calibration!)
            .confirmStartingPosition(shot.frame)
            .agrees,
        isTrue,
      );
    });
  });

  group('FoldingBoardGeometry, on its own', () {
    final corners = foldingCornersOf(
      kFoldingTent,
      barWidth: kFoldingBarWidth,
      aspect: kTopDownHeight / kTopDownWidth,
      principal: const Pt(kFrameWidth / 2, kFrameHeight / 2),
    );

    test('derives the board it is, rather than being told', () {
      final geometry = FoldingBoardGeometry(corners);
      expect(geometry.proportions.trayWidth, 0,
          reason: 'a folding case has no bear-off wells at all');
      expect(
        geometry.proportions.barWidth,
        closeTo(corners.rightLeafStart - corners.leftLeafEnd, 1e-12),
        reason: 'the bar IS the strip between the leaves',
      );
      // The convention, stated as an assertion: two leaves of equal width
      // flanking the bar. It is what makes each leaf's six columns exact
      // sixths of that leaf whatever the strip's width turns out to be.
      expect(corners.leftLeafEnd,
          closeTo(1 - corners.rightLeafStart, 1e-12));
      expect(geometry.proportions.barStart, closeTo(corners.leftLeafEnd, 1e-12));
      expect(
        geometry.proportions.barEnd,
        closeTo(corners.rightLeafStart, 1e-12),
      );
    });

    test('routes each band to its own plane, and joins up at the seams', () {
      final geometry = FoldingBoardGeometry(corners);
      // Continuity is not decoration: the checker patch on the point against
      // the hinge straddles nothing, but the dice band's lattice walks
      // straight across both seams, and a jump there would read as an edge —
      // which is to say, as a die.
      for (final seam in <double>[
        corners.leftLeafEnd,
        corners.rightLeafStart,
      ]) {
        for (final y in <double>[0.0, 0.37, 1.0]) {
          final before = geometry.imagePointOf(Pt(seam - 1e-9, y));
          final after = geometry.imagePointOf(Pt(seam + 1e-9, y));
          expect((before.x - after.x).abs(), lessThan(1e-4),
              reason: 'x jumps across the seam at $seam, y $y');
          expect((before.y - after.y).abs(), lessThan(1e-4),
              reason: 'y jumps across the seam at $seam, y $y');
        }
      }
    });

    test('puts board space\'s own corners on the board\'s outer corners', () {
      final geometry = FoldingBoardGeometry(corners);
      for (final (board, image) in <(Pt, Pt)>[
        (const Pt(0, 0), corners.topLeft),
        (const Pt(1, 0), corners.topRight),
        (const Pt(1, 1), corners.bottomRight),
        (const Pt(0, 1), corners.bottomLeft),
      ]) {
        final got = geometry.imagePointOf(board);
        expect(got.x, closeTo(image.x, 1e-6));
        expect(got.y, closeTo(image.y, 1e-6));
      }
      // And the four hinge junctions on the hinge junctions, which is what
      // makes the bar region the hinge strip and nothing else.
      for (final (x, y, image) in <(double, double, Pt)>[
        (corners.leftLeafEnd, 0, corners.hingeFarLeft),
        (corners.rightLeafStart, 0, corners.hingeFarRight),
        (corners.leftLeafEnd, 1, corners.hingeNearLeft),
        (corners.rightLeafStart, 1, corners.hingeNearRight),
      ]) {
        final got = geometry.imagePointOf(Pt(x, y));
        expect(got.x, closeTo(image.x, 1e-6));
        expect(got.y, closeTo(image.y, 1e-6));
      }
    });

    test('refuses eight points that are not a board', () {
      // Data from outside the program — eight taps on a screen — so being told
      // which point is wrong beats three homographies full of infinities.
      expect(
        () => FoldingBoardGeometry(FoldingCorners(
          topLeft: corners.topLeft,
          topRight: corners.topRight,
          bottomRight: corners.bottomRight,
          bottomLeft: corners.bottomLeft,
          // The hinge tapped the wrong way round: its right edge left of its
          // left one, which is a strip of negative width.
          hingeFarLeft: corners.hingeFarRight,
          hingeFarRight: corners.hingeFarLeft,
          hingeNearLeft: corners.hingeNearRight,
          hingeNearRight: corners.hingeNearLeft,
        )),
        throwsArgumentError,
      );
      expect(
        () => FoldingBoardGeometry(FoldingCorners(
          topLeft: corners.topLeft,
          topRight: corners.topRight,
          bottomRight: corners.bottomRight,
          bottomLeft: corners.bottomLeft,
          hingeFarLeft: const Pt(double.nan, 0),
          hingeFarRight: corners.hingeFarRight,
          hingeNearLeft: corners.hingeNearLeft,
          hingeNearRight: corners.hingeNearRight,
        )),
        throwsArgumentError,
      );
    });

    test('calibration turns those refusals into a sentence, not a crash', () {
      final shot = renderFoldingShot(board: BoardState.initial());
      final result = BoardVision.calibrateFolding(
        frame: shot.frame,
        corners: FoldingCorners(
          topLeft: shot.groundTruthCorners.topLeft,
          topRight: shot.groundTruthCorners.topRight,
          bottomRight: shot.groundTruthCorners.bottomRight,
          bottomLeft: shot.groundTruthCorners.bottomLeft,
          hingeFarLeft: shot.groundTruthCorners.hingeFarRight,
          hingeFarRight: shot.groundTruthCorners.hingeFarLeft,
          hingeNearLeft: shot.groundTruthCorners.hingeNearRight,
          hingeNearRight: shot.groundTruthCorners.hingeNearLeft,
        ),
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isFalse);
      expect(result.problem, CalibrationProblem.cornersNotABoard);
      expect(result.message, endsWith('.'));
    });
  });
}

/// The four outer corners alone — what a person would tap if nobody had told
/// them the board folds.
BoardQuad _outerQuadOf(FoldingCorners corners) => BoardQuad(
      topLeft: corners.topLeft,
      topRight: corners.topRight,
      bottomRight: corners.bottomRight,
      bottomLeft: corners.bottomLeft,
    );

/// How far apart the two halves' column pitches come out when ONE homography
/// is fitted through the four outer corners.
///
/// The real frame's diagnostic, reproduced as a number. Rectify the board
/// under a single plane and ask where the hinge junctions land in board space:
/// on a genuinely flat board they land symmetrically about the middle and the
/// two halves get the same pitch. On a tented one they do not, and the
/// difference is what makes mid-board columns miss by half a column.
double _singlePlanePitchSkew(FoldingView view) {
  final corners = foldingCornersOf(
    view,
    barWidth: kFoldingBarWidth,
    aspect: kTopDownHeight / kTopDownWidth,
    principal: const Pt(kFrameWidth / 2, kFrameHeight / 2),
  );
  final h = Homography.fromQuad(_outerQuadOf(corners));
  final leftEnd = (h.mapToBoard(corners.hingeFarLeft).x +
          h.mapToBoard(corners.hingeNearLeft).x) /
      2;
  final rightStart = (h.mapToBoard(corners.hingeFarRight).x +
          h.mapToBoard(corners.hingeNearRight).x) /
      2;
  // Six columns share each half, so the pitch is the half over six — and the
  // six cancels out of the ratio, which is why it is not written.
  final left = leftEnd, right = 1 - rightStart;
  return (left - right).abs() / (left > right ? left : right);
}

/// The starting position with one checker lifted onto the hinge, which is
/// where a hit checker physically goes on a board with no bar well.
BoardState _oneOnTheBar({required bool white}) {
  final points = List<int>.of(BoardState.initial().points);
  if (white) {
    points[5] -= 1; // one White off the 6-point...
    return BoardState(points: points, whiteBar: 1);
  }
  points[0] += 1; // ...or one Black off the 1-point.
  return BoardState(points: points, blackBar: 1);
}

BoardCalibration _calibrate(FoldingShot shot) {
  final result = BoardVision.calibrateFolding(
    frame: shot.frame,
    corners: shot.groundTruthCorners,
    orientation: shot.board.orientation,
  );
  expect(result.ok, isTrue, reason: result.message);
  return result.calibration!;
}
