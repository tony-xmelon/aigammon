import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// The board that made [BoardProportions] exist, read end to end.
///
/// A folding-case board: **no bear-off wells at all** — wooden rim, six point
/// columns, a hinge strip for a bar, six more columns, rim — so borne-off
/// checkers leave the board entirely and hit checkers sit on the hinge. Every
/// column on it is wider than the atlas used to assume, and the outermost ones
/// sit most of a column away from where it used to look.
///
/// Two things are being tested here, and the second is the important one:
///
/// 1. that the pipeline reads such a board when it is TOLD what shape it is —
///    calibration, confirmation, occupancy on the outermost columns, a checker
///    on the hinge, and a settled pair of dice;
/// 2. that it **refuses** the same board when it is told the wrong shape. That
///    is what makes the proportions load-bearing rather than decorative: a
///    number nothing checks is a number that will be wrong in the field, and
///    the failure would arrive as "your board is set up wrongly" while the user
///    stares at a board that is exactly right.
void main() {
  /// The real board's shape: no wells, and a hinge a fraction of the bar width
  /// the atlas used to assume.
  const trayless = BoardProportions(trayWidth: 0, barWidth: 0.03);

  group('a folding-case board, told what shape it is', () {
    test('calibrates, and confirms as the starting position', () {
      final shot = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
      );
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
        proportions: trayless,
      );
      expect(result.ok, isTrue, reason: result.message);

      final calibration = result.calibration!;
      expect(calibration.proportions, trayless);
      expect(calibration.atlas.proportions, trayless,
          reason: 'the atlas a calibration hands out has to be the one its '
              'colours were learned through');
      expect(calibration.atlas.hasTrays, isFalse);

      final confirmed =
          BoardVision(calibration).confirmStartingPosition(shot.frame);
      expect(confirmed.agrees, isTrue, reason: confirmed.message);
    });

    test('counts the outermost columns, which are the ones a tray-width error '
        'moves most', () {
      // Points 1, 12, 13 and 24 — the four hard against the board's own edges.
      // On this board they reach the edge; on a board with wells they stop a
      // tray's width short. Nothing else in the pipeline moves as far when the
      // proportions are wrong, which is why these four are the ones to count.
      final start = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
      );
      final vision = BoardVision(_calibrate(start, trayless));
      final reader = vision.occupancyIn(start.frame);
      final board = BoardState.initial();

      for (final index in <int>[0, 11, 12, 23]) {
        final signed = board.points[index];
        final reading = reader.read(RoiId.point(index));
        expect(
          reading.color,
          signed > 0 ? CheckerColor.white : CheckerColor.black,
          reason: 'point ${index + 1} holds $signed',
        );
        expect(reading.count, signed.abs(),
            reason: 'point ${index + 1} holds ${signed.abs()}, read '
                '${reading.count}');
      }
    });

    test('a checker on the hinge reads as a checker on the bar', () {
      // Where a hit checker actually goes on this board, confirmed in the
      // footage: there is no well to drop it in, so it sits on the hinge ridge
      // — which is the bar, however narrow the atlas has been told it is.
      final start = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
      );
      final vision = BoardVision(_calibrate(start, trayless));

      final points = List<int>.of(BoardState.initial().points);
      points[0] += 1; // one of Black's two off the 1-point...
      final hit = renderShot(
        board: BoardState(points: points, blackBar: 1), // ...onto the hinge.
        proportions: trayless,
      );
      final reader = vision.occupancyIn(hit.frame);

      final onBar = reader.readFor(RoiId.bar, CheckerColor.black);
      expect(onBar.color, CheckerColor.black);
      expect(onBar.count, 1);
      expect(reader.readFor(RoiId.bar, CheckerColor.white).count, 0);
    });

    test('the settled dice still read in the band', () {
      // The band runs the full width of a trayless board — there being no
      // wells for it to stop at — so this is not the same rectangle the dice
      // reader has been exercised on anywhere else.
      final start = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
      );
      final vision = BoardVision(_calibrate(start, trayless));

      final rolled = renderShot(
        board: BoardState.initial(),
        dice: Dice(6, 3),
        proportions: trayless,
      );
      final reading = vision.readDice(rolled.frame);
      expect(reading, isNotNull, reason: 'no pair found on a trayless board');
      expect(
        <int>[reading!.first.face, reading.second.face]..sort(),
        <int>[3, 6],
      );
    });

    test('there are no trays to read, and asking says so', () {
      final start = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
      );
      final reader =
          BoardVision(_calibrate(start, trayless)).occupancyIn(start.frame);

      // Twenty-four points and the bar, and not a twenty-sixth region that
      // reads "empty" for a well the board does not have.
      final all = reader.readAll();
      expect(all.keys.length, 25);
      expect(all.containsKey(RoiId.offWhite), isFalse);
      expect(all.containsKey(RoiId.offBlack), isFalse);
      expect(all.containsKey(RoiId.bar), isTrue);

      // And a caller who asks anyway is told, rather than handed a zero it
      // would go on to trust.
      expect(() => reader.read(RoiId.offWhite), throwsStateError);
      expect(() => reader.read(RoiId.offBlack), throwsStateError);
    });

    test('confirmation checks the bar but has no trays to check', () {
      // The tray-emptiness half of the start-position check simply does not
      // run here: a checker cannot be left in a well that does not exist. The
      // bar half still does, and still bites.
      final start = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
      );
      final vision = BoardVision(_calibrate(start, trayless));

      final points = List<int>.of(BoardState.initial().points);
      points[0] += 1;
      final stray = renderShot(
        board: BoardState(points: points, blackBar: 1),
        proportions: trayless,
      );
      final result = vision.confirmStartingPosition(stray.frame);
      expect(result.agrees, isFalse);
      expect(result.discrepancies.map((d) => d.region), contains(RoiId.bar));
      expect(
        result.discrepancies.map((d) => d.region),
        isNot(anyElement(
          anyOf(equals(RoiId.offWhite), equals(RoiId.offBlack)),
        )),
      );
    });
  });

  group('told the WRONG shape, it refuses', () {
    // The point of the whole change. If the proportions were decorative, this
    // group would pass green with them ignored — so these are the assertions
    // that make them load-bearing.

    test('a trayless board calibrated as though it had trays', () {
      final shot = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
      );
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
        // Not passing proportions at all: the old behaviour, and what a caller
        // who has not measured their board will get.
      );

      expect(result.ok, isFalse,
          reason: 'the standard atlas reads this board a whole column out and '
              'must not hand over a calibration that does it: ${result.message}');
      expect(result.problem, isNotNull);

      // WHICH gate catches it, measured by turning them off one at a time.
      //
      // Two do, and both are worth having. The per-stack colour check fires
      // first and is what produces the sentence below: the standard atlas's
      // 1-point sits over the paint of this board's 2-point, which is bare, so
      // the "checker" sampled there is triangle paint and lands nearer the
      // wrong distribution. Disable that check and calibration STILL refuses —
      // the read-back gate catches it, exactly as its own doc says it should,
      // because the outermost columns are what a tray-width error moves most
      // and the starting position labels them. Disable both and calibration
      // succeeds on a board it is reading a column out of true, which is the
      // failure this whole change exists to make impossible.
      expect(result.problem, CalibrationProblem.checkersNotInStartingPosition);

      // Loudly, and in words the user can act on — the failure has to be a
      // sentence, not a silent null and not an enum name leaking through.
      expect(result.message, isNotEmpty);
      expect(result.message, endsWith('.'));
      expect(result.message.split(' ').length, greaterThan(6));
      for (final leak in <String>['offWhite', 'offBlack', 'RoiId', 'null']) {
        expect(result.message, isNot(contains(leak)));
      }
      expect(result.offending, isNotEmpty,
          reason: 'the regions that misread are what the screen highlights');
    });

    test('an ordinary board calibrated as though it were a folding case', () {
      // The same mistake the other way round, which a user who measured the
      // wrong board would make.
      final shot = renderShot(board: BoardState.initial());
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
        proportions: trayless,
      );
      expect(result.ok, isFalse, reason: result.message);
      expect(result.message, isNotEmpty);
      expect(result.message, endsWith('.'));
    });

    test('and the same board with the right proportions calibrates, which is '
        'what makes the two above mean something', () {
      // The control. Without it the group above would pass just as well on a
      // pipeline that refused every board it was ever shown.
      for (final (name, proportions) in <(String, BoardProportions)>[
        ('folding case', trayless),
        ('ordinary board', BoardProportions.standard),
      ]) {
        final shot = renderShot(
          board: BoardState.initial(),
          proportions: proportions,
        );
        final result = BoardVision.calibrate(
          frame: shot.frame,
          corners: shot.groundTruthQuad,
          orientation: BoardOrientation.whiteHomeNear,
          proportions: proportions,
        );
        expect(result.ok, isTrue, reason: '$name: ${result.message}');
      }
    });
  });

  group('the star inlay a great many real boards carry', () {
    // The user's board has one mid-field on each half. It is a THIRD surface
    // inside the dice band and inside the headroom of the two middle points of
    // each half, and calibration models a region's surfaces with two-means —
    // i.e. with two. This is the bed for finding out whether that matters.
    test('calibration survives a third surface in the middle of each half',
        () {
      final shot = renderShot(
        board: BoardState.initial(),
        proportions: trayless,
        starInlays: true,
      );
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
        proportions: trayless,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(
        BoardVision(result.calibration!)
            .confirmStartingPosition(shot.frame)
            .agrees,
        isTrue,
      );
    });

    test('and so does an ordinary board with one', () {
      final shot = renderShot(board: BoardState.initial(), starInlays: true);
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isTrue, reason: result.message);
    });
  });
}

BoardCalibration _calibrate(SyntheticShot shot, BoardProportions proportions) {
  final result = BoardVision.calibrate(
    frame: shot.frame,
    corners: shot.groundTruthQuad,
    orientation: shot.board.orientation,
    proportions: proportions,
  );
  expect(result.ok, isTrue, reason: result.message);
  return result.calibration!;
}
