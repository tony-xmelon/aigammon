import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// Calibration is the one moment perception is handed the truth for free: the
/// checkers are in the starting position, so every occupied point is a set of
/// labelled colour samples and every empty one is a labelled sample of that
/// board's bare surface. Everything downstream — occupancy, play matching,
/// placement verification — leans on what is learned here, so these tests hand
/// [BoardVision.calibrate] boards it has never been told anything about
/// (three palettes, three light levels, both seatings, a steep view) and check
/// that it comes back knowing them.
///
/// The palettes live in the renderer, not here and certainly not in `lib/`:
/// the last group in this file is the guard that keeps it that way.
void main() {
  group('calibration learns the board it is shown', () {
    for (final palette in BoardPalette.all) {
      for (final gain in <double>[0.6, 1.0, 1.4]) {
        // One cell of this matrix cannot work and must not pretend to: lit 40%
        // over its own colours, the blue-red board's pale points and its white
        // checkers both clip to 255, so in the frame they are the same colour
        // and no model can separate what the sensor discarded. Calibration
        // refuses it by name — asserted in 'an over-lit board is refused'.
        if (palette == BoardPalette.blueRed && gain == 1.4) continue;

        test('${palette.name} at gain $gain: two separable checker colours, '
            'and every checker reads back', () {
          final shot = renderShot(
            board: BoardState.initial(),
            palette: palette,
            lightingGain: gain,
          );
          final colors = _calibrate(shot).colors;

          expect(colors.separation,
              greaterThanOrEqualTo(ColorModel.minSeparation),
              reason: 'the two checker colours did not come out apart');
          _expectEveryCheckerReadsBack(shot, colors);
        });
      }
    }

    for (final orientation in BoardOrientation.values) {
      test('the same board from the ${orientation.name} seat', () {
        final shot = renderShot(
          board: BoardState.initial(),
          orientation: orientation,
        );
        final colors = _calibrate(shot, orientation: orientation).colors;
        expect(colors.separation,
            greaterThanOrEqualTo(ColorModel.minSeparation));
        _expectEveryCheckerReadsBack(shot, colors, orientation: orientation);
      });
    }

    test('a steeply foreshortened view still learns the board', () {
      // The far edge is barely half the near one — a phone propped low at the
      // side of the table, which is where the far half's ROIs get small and
      // noisy. Learning has to survive it; the corpus gate decides how far.
      final shot = renderShot(
        board: BoardState.initial(),
        palette: BoardPalette.lowContrastWood,
        quad: _steepQuad,
      );
      final colors = _calibrate(shot).colors;
      expect(colors.separation, greaterThanOrEqualTo(ColorModel.minSeparation));
      _expectEveryCheckerReadsBack(shot, colors);
    });

    test('the dice band learns the two surfaces it has, and no third', () {
      // The band runs across both halves AND the bar, so it has a felt and a
      // wood, and both have to be in its vocabulary — a dice reader asks what
      // the band's surfaces do not account for, and a surface missing from
      // that list turns the whole bar into a foreign object.
      //
      // The third thing it must NOT learn is the rim of the four five-stacks
      // standing in it. Filtering by colour removes a checker and leaves the
      // pixels where its edge blends into the felt, and that blend is a
      // colour the board does not have anywhere. Measured: on two of these
      // three palettes it is within two spreads of a die's body, so a band
      // that has learned it finds no dice at all. The band keeps clear of
      // every occupied column instead.
      final shot = renderShot(board: BoardState.initial());
      final colors = _calibrate(shot).colors;
      final band = colors.backgroundOf(RoiId.diceZone);
      final h = Homography.fromQuad(shot.groundTruthQuad);

      double distanceAt(Pt boardPoint) {
        final p = h.mapToImage(boardPoint);
        final sample = shot.frame.pixelAt(p.x.round(), p.y.round());
        return band.distanceTo(ColorModel.feature(sample, band.color));
      }

      // Felt on the left, the bar's wood, felt on the right.
      for (final x in <double>[0.25, 0.5, 0.75]) {
        expect(distanceAt(Pt(x, RoiAtlas.midline)), lessThan(2.0),
            reason: 'the band does not recognise its own surface at x=$x');
      }

      // And a checker standing in the band is not one of its surfaces.
      final cap = shot.board.checkers.lastWhere(
        (c) => c.pointIndex == 5 && c.area == SpotArea.point,
      );
      final p = shot.toFrame(cap.center);
      final sample = shot.frame.pixelAt(p.x.round(), p.y.round());
      expect(
        band.distanceTo(ColorModel.feature(sample, band.color)),
        greaterThan(4.0),
        reason: 'the band learned a checker as though it were board',
      );
    });

    test('every region gets a background, and the covered ones say so', () {
      final shot = renderShot(board: BoardState.initial());
      final colors = _calibrate(shot).colors;

      for (final id in RoiId.values) {
        final background = colors.backgroundOf(id);
        expect(background.sampleCount, greaterThan(0), reason: '$id');
      }
      // A point the start position leaves empty showed us its whole surface.
      expect(colors.backgroundOf(RoiId.point(3)).fullyMeasured, isTrue);
      expect(colors.backgroundOf(RoiId.bar).fullyMeasured, isTrue);
      // A point with a stack on it never did, and the model records that so
      // Task 4 knows which "empty" readings to trust less.
      for (final index in <int>[0, 5, 7, 11, 12, 16, 18, 23]) {
        expect(colors.backgroundOf(RoiId.point(index)).fullyMeasured, isFalse,
            reason: 'point $index had checkers on it during calibration');
      }
    });
  });

  group('stacks a person placed, not a renderer', () {
    // The failure that made the checker patch into a checker finder, and it
    // came off a photograph rather than out of a design review. Every render
    // before this group seated the outermost checker of every stack flush
    // against its own board edge, and the patch that learns this board's
    // checker colours was a fixed window two to four and a half hundredths
    // deep, measured from that edge.
    //
    // On the first real calibration frame, six of the eight starting stacks
    // were far enough inside their edge that the window fell in front of them
    // and sampled bare board; the two that were not were on the far half,
    // where a shallow camera angle projects a stack the other way. Half the
    // patches read board, both learned checker distributions converged on
    // board, and the separation gate refused the frame — correctly, on a
    // frame that a person can read at a glance.
    //
    // Insets are a hand's work, so they differ from stack to stack: no single
    // offset fixes them, which is why this is a search and not a bigger
    // number. The three renders below are that failure, in the bed.

    /// The eight stacks the starting position puts out, at insets a hand
    /// might leave: a hundredth of the board's height apart at the tightest
    /// and an eighth at the loosest. The deep ones are deliberately on the
    /// short stacks — a five-stack inset that far would have to compress to
    /// stay off the midline, which is a different measurement (the pitch)
    /// getting harder rather than this one.
    const varied = <int, StackPlacement>{
      0: StackPlacement(edgeInset: 0.12),
      5: StackPlacement(edgeInset: 0.04),
      7: StackPlacement(edgeInset: 0.09),
      11: StackPlacement(edgeInset: 0.02),
      12: StackPlacement(edgeInset: 0.06),
      16: StackPlacement(edgeInset: 0.11),
      18: StackPlacement(edgeInset: 0.03),
      23: StackPlacement(edgeInset: 0.08),
    };

    test('every stack sitting the same little way off its edge', () {
      final shot = renderShot(
        board: BoardState.initial(),
        stackPlacement: const StackPlacement(edgeInset: 0.06),
      );
      final calibration = _calibrate(shot);

      expect(calibration.colors.separation,
          greaterThanOrEqualTo(ColorModel.minSeparation),
          reason: 'the two checker colours did not come out apart');
      _expectEveryCheckerReadsBack(shot, calibration.colors);
      final confirmed =
          BoardVision(calibration).confirmStartingPosition(shot.frame);
      expect(confirmed.agrees, isTrue, reason: confirmed.message);
    });

    test('insets that differ from stack to stack, as a hand leaves them', () {
      final shot = renderShot(
        board: BoardState.initial(),
        pointPlacements: varied,
      );
      final calibration = _calibrate(shot);

      expect(calibration.colors.separation,
          greaterThanOrEqualTo(ColorModel.minSeparation));
      _expectEveryCheckerReadsBack(shot, calibration.colors);
      final confirmed =
          BoardVision(calibration).confirmStartingPosition(shot.frame);
      expect(confirmed.agrees, isTrue, reason: confirmed.message);
    });

    test('and stacks pushed off the middle of their columns', () {
      // The other half of what a hand does. A patch taken at the column's
      // centre still catches a stack nudged sideways in the middle of a
      // checker, but not at the leading edge of one, where the disc is at its
      // narrowest — so the finder tries a little either side of centre and
      // keeps the best-scoring position.
      //
      // Read through a model learned from a tidy board, deliberately. A
      // checker is very nearly as wide as its column, so a stack shifted this
      // far overhangs the NEXT column by about a tenth of one, and what that
      // does to the neighbour's learned surface is a different question from
      // the one this test asks — see the plan's Task 9 note. Here the colours
      // are known to be right, and what is under test is whether the walk
      // finds a stack that is not where a renderer would have put it.
      final flush = renderShot(board: BoardState.initial());
      final calibration = _calibrate(flush);

      final shot = renderShot(
        board: BoardState.initial(),
        pointPlacements: <int, StackPlacement>{
          ...varied,
          12: const StackPlacement(edgeInset: 0.06, centerOffset: 0.15),
          0: const StackPlacement(edgeInset: 0.12, centerOffset: -0.15),
        },
      );
      final colors = calibration.colorsIn(shot.frame);
      final sampler = RoiSampler(
        shot.frame,
        PlanarBoardGeometry.fromQuad(shot.groundTruthQuad),
        calibration.atlas,
      );
      final start = BoardState.initial();

      for (final index in varied.keys) {
        final found = sampler.findChecker(index);
        final read = <CheckerColor, int>{};
        for (final sample in found.scan.samples) {
          final c = colors.classifyIn(RoiId.point(index), sample);
          read[c] = (read[c] ?? 0) + 1;
        }
        final expected = start.points[index] > 0
            ? CheckerColor.white
            : CheckerColor.black;
        expect(
          (read[expected] ?? 0) / found.scan.samples.length,
          greaterThan(Calibrator.patchMajority),
          reason: 'point ${index + 1} holds ${start.points[index]}, and the '
              'walk came back with $read from depth ${found.depth} at offset '
              '${found.offset}',
        );
      }

      // And the board still reads as the starting position through it.
      final confirmed =
          BoardVision(calibration).confirmStartingPosition(shot.frame);
      expect(confirmed.agrees, isTrue, reason: confirmed.message);
    });

    test('the finder says how far in it found each stack', () {
      // What it found, not just what colour: the depth is the one number that
      // says how a stack was placed, and the pitch regression is the obvious
      // consumer for it. Asserted here because a finder that returned the
      // right colour from the wrong place would pass everything above.
      final shot = renderShot(
        board: BoardState.initial(),
        pointPlacements: varied,
      );
      final atlas = RoiAtlas.forOrientation(BoardOrientation.whiteHomeNear);
      final sampler = RoiSampler(
        shot.frame,
        PlanarBoardGeometry.fromQuad(shot.groundTruthQuad),
        atlas,
      );

      for (final entry in varied.entries) {
        final found = sampler.findChecker(entry.key);
        expect(found.settled, isTrue,
            reason: 'the walk down point ${entry.key + 1} never settled');
        // Within a checker's own thickness of where the renderer put it: the
        // patch starts at the first depth the disc reads as one colour, which
        // is a little past its leading edge.
        expect(
          found.depth,
          closeTo(entry.value.edgeInset, 0.05),
          reason: 'point ${entry.key + 1} was drawn at an inset of '
              '${entry.value.edgeInset} and found at ${found.depth}',
        );
      }
    });
  });

  group('classification is relative, so the light can change', () {
    test('a model learned in bright light reads a dimmed board', () {
      // A sample is judged against its own region's background, so a room-wide
      // change of gain cancels in the ratio — but only once the reference has
      // been moved to where the light now is, because a background under a
      // stack of checkers can never be re-measured. The exposure the model is
      // re-normalized by is the one number the fingerprint already takes on
      // every stable frame.
      final bright = renderShot(board: BoardState.initial());
      final calibration = _calibrate(bright);

      final dim = renderShot(board: BoardState.initial(), lightingGain: 0.6);
      final exposure = calibration.exposureIn(dim.frame);
      expect(exposure, closeTo(0.6, 0.02));

      _expectEveryCheckerReadsBack(
        dim,
        calibration.colors.renormalized(exposure),
      );
    });

    test('confirmation survives the camera exposing for itself', () {
      // The calibration shot and the confirmation frame are seconds apart on a
      // live preview, and a phone's auto-exposure moves this much between two
      // frames of the same scene without anything else changing. Both gains
      // here sit well inside the fingerprint's drift tolerance, so nothing
      // would flag them — confirmation has to hold on its own, or the user is
      // sent to fix a board that is already correct.
      final calibration = _calibrate(renderShot(board: BoardState.initial()));
      final vision = BoardVision(calibration);

      for (final gain in <double>[0.8, 0.9, 1.15, 1.25]) {
        final shot = renderShot(
          board: BoardState.initial(),
          lightingGain: gain,
        );
        final result = vision.confirmStartingPosition(shot.frame);
        expect(result.agrees, isTrue, reason: 'at gain $gain: ${result.message}');
        expect(result.discrepancies, isEmpty, reason: 'at gain $gain');
      }
    });

    // The reason the reference is per region and not one number for the whole
    // board: a lamp off to one side leaves one end of the board at a fraction
    // of the light on the other, and no single exposure describes both. Run
    // both ways round because they are not the same test — one of them puts
    // the tall five-stacks in the dark end, where a region has least of itself
    // showing to measure a background from. Measured to hold to a ratio of
    // more than three to one; asserted at the gentler ratio a lamp actually
    // makes across half a metre of table.
    for (final (name, near, far) in <(String, double, double)>[
      ('the far side', 1.0, 0.6),
      ('the near side', 0.6, 1.0),
    ]) {
      test('a board with the light falling away toward $name', () {
        final shot = renderShot(board: BoardState.initial());
        final lit = _sideLit(shot.frame, near: near, far: far);
        final result = BoardVision.calibrate(
          frame: lit,
          corners: shot.groundTruthQuad,
          orientation: BoardOrientation.whiteHomeNear,
        );
        expect(result.ok, isTrue, reason: result.message);

        final vision = BoardVision(result.calibration!);
        final confirmed = vision.confirmStartingPosition(lit);
        expect(confirmed.agrees, isTrue, reason: confirmed.message);
        _expectEveryCheckerReadsBack(
          SyntheticShot(
            frame: lit,
            groundTruthQuad: shot.groundTruthQuad,
            board: shot.board,
            topDownToFrame: shot.topDownToFrame,
          ),
          result.calibration!.colors,
        );
      });
    }

    test('the bare board is not a checker', () {
      // Every point the start position leaves empty must read as no checker
      // where its stack would begin — otherwise confirmation and, later,
      // occupancy see a phantom checker on every triangle. The base of a
      // triangle is the hard case on purpose: it is the widest, most
      // saturated part of the point, and on a classic board a cream triangle
      // is very nearly the colour of a white checker.
      final shot = renderShot(board: BoardState.initial());
      final colors = _calibrate(shot).colors;
      final h = Homography.fromQuad(shot.groundTruthQuad);
      final start = BoardState.initial();

      for (var i = 0; i < 24; i++) {
        if (start.points[i] != 0) continue;
        final (left, right) = BoardLayout.standard.pointSpan(i);
        final y = BoardLayout.isNearHalf(i) ? 1 - 0.03 : 0.03;
        final p = h.mapToImage(Pt((left + right) / 2, y));
        final sample = shot.frame.pixelAt(p.x.round(), p.y.round());
        expect(colors.classifyIn(RoiId.point(i), sample), CheckerColor.none,
            reason: 'point $i is empty in the starting position');
      }

      // And the surface each region learned about itself is, by construction,
      // not a checker either.
      for (final id in RoiId.values) {
        expect(colors.classifyIn(id, colors.backgroundOf(id).color),
            CheckerColor.none,
            reason: '$id read its own background as a checker');
      }
    });
  });

  group('calibration refuses what it cannot learn from', () {
    test('corners that are not a quadrilateral', () {
      final shot = renderShot(board: BoardState.initial());
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: const BoardQuad(
          topLeft: Pt(100, 100),
          topRight: Pt(400, 100),
          bottomRight: Pt(700, 100),
          bottomLeft: Pt(100, 500),
        ),
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isFalse);
      expect(result.problem, CalibrationProblem.cornersNotABoard);
      expect(result.message, isNotEmpty);
    });

    test('a board hanging off the side of the picture', () {
      final shot = renderShot(
        board: BoardState.initial(),
        quad: const BoardQuad(
          topLeft: Pt(-300, 150),
          topRight: Pt(900, 130),
          bottomRight: Pt(1000, 820),
          bottomLeft: Pt(-380, 850),
        ),
      );
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isFalse);
      expect(result.problem, CalibrationProblem.boardNotFullyVisible);
      expect(result.offending, isNotEmpty);
      expect(result.message, contains('board'));
    });

    test('checkers that are not in the starting position', () {
      final shot = renderShot(board: _stacksSwapped());
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isFalse);
      expect(result.problem, CalibrationProblem.checkersNotInStartingPosition);
      expect(result.offending,
          anyOf(contains(RoiId.point(7)), contains(RoiId.point(16))));
    });

    test('an over-lit board is refused rather than half-learned', () {
      // Measured, not supposed: on this board at this gain the pale points and
      // the white checkers clip to the same 255, and a model learned from it
      // reads phantom White on half the empty points of the very frame it was
      // learned from. Returning a calibration anyway would push the failure
      // one screen along, where it shows up as "your board is set up wrong" —
      // the user fixing the wrong thing. So calibration reads its own frame
      // back before it hands anything over.
      final shot = renderShot(
        board: BoardState.initial(),
        palette: BoardPalette.blueRed,
        lightingGain: 1.4,
      );
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isFalse);
      expect(result.problem, CalibrationProblem.boardOverExposed);
      expect(result.message.toLowerCase(), contains('light'));
    });

    test('two sets of checkers that look alike', () {
      final shot = renderShot(
        board: BoardState.initial(),
        palette: _indistinguishableCheckers,
      );
      final result = BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(result.ok, isFalse);
      expect(result.problem, CalibrationProblem.checkerColoursNotSeparable);
      expect(result.message, isNotEmpty);
    });
  });

  group('confirming the starting position', () {
    for (final palette in BoardPalette.all) {
      test('a correct start is agreed to on ${palette.name}, from either seat',
          () {
        for (final orientation in BoardOrientation.values) {
          final shot = renderShot(
            board: BoardState.initial(),
            palette: palette,
            orientation: orientation,
          );
          final vision =
              BoardVision(_calibrate(shot, orientation: orientation));
          final result = vision.confirmStartingPosition(shot.frame);
          expect(result.agrees, isTrue,
              reason: '${orientation.name}: ${result.message}');
          expect(result.discrepancies, isEmpty);
        }
      });
    }

    test('two swapped stacks are named', () {
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final swapped = renderShot(board: _stacksSwapped());
      final result = vision.confirmStartingPosition(swapped.frame);

      expect(result.agrees, isFalse);
      expect(_pointNumbersIn(result), containsAll(<int>[8, 17]));
      expect(result.message, contains('8-point'));
      final wrongColour = result.discrepancies
          .firstWhere((d) => d.pointNumber == 8);
      expect(wrongColour.expected, CheckerColor.white);
      expect(wrongColour.observed, CheckerColor.black);
    });

    test('a checker on a point that should be empty is named', () {
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final points = List<int>.of(BoardState.initial().points);
      points[5] -= 1; // one White checker off the 6-point...
      points[3] += 1; // ...and onto the 4-point, which starts empty.
      final moved = renderShot(board: BoardState(points: points));
      final result = vision.confirmStartingPosition(moved.frame);

      expect(result.agrees, isFalse);
      expect(_pointNumbersIn(result), contains(4));
      final extra =
          result.discrepancies.firstWhere((d) => d.pointNumber == 4);
      expect(extra.expected, CheckerColor.none);
      expect(extra.observed, CheckerColor.white);
      expect(extra.message, contains('4-point'));
    });

    test('a checker left on the bar is named', () {
      // The bar is not a point, and a checker sitting there at the start would
      // be folded into the authoritative game state as if the board were
      // correct — from move one, every position after it is wrong. The bar
      // starts empty and confirmation has to say so.
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final points = List<int>.of(BoardState.initial().points);
      points[5] -= 1; // one White off the 6-point and onto the bar, so the
      final stray = renderShot( // 6-point still reads White and only the bar
        board: BoardState(points: points, whiteBar: 1), // is wrong.
      );
      final result = vision.confirmStartingPosition(stray.frame);

      expect(result.agrees, isFalse);
      expect(result.discrepancies.map((d) => d.region), contains(RoiId.bar));
      final onBar =
          result.discrepancies.firstWhere((d) => d.region == RoiId.bar);
      expect(onBar.expected, CheckerColor.none);
      expect(onBar.observed, CheckerColor.white);
      expect(onBar.pointNumber, isNull);
      expect(onBar.message, contains('the bar'));
      expect(result.message, contains('the bar'));
    });

    test('checkers left in a bear-off tray are named in words', () {
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final points = List<int>.of(BoardState.initial().points);
      points[11] += 3; // three of Black's five off the 12-point...
      final stray = renderShot(
        board: BoardState(points: points, blackOff: 3), // ...into its tray.
      );
      final result = vision.confirmStartingPosition(stray.frame);

      expect(result.agrees, isFalse);
      final inTray =
          result.discrepancies.firstWhere((d) => d.region == RoiId.offBlack);
      expect(inTray.observed, CheckerColor.black);
      // Named the way a person would say it, not the way the enum spells it.
      expect(inTray.message, contains('tray'));
      expect(inTray.message, isNot(contains('offBlack')));
    });

    test('a frame the calibration cannot reach across is not called a bad '
        'setup', () {
      // Confirmation looks through the homography calibration solved, so a
      // frame that does not cover it — a camera that changed resolution
      // between the preview and the shot — has to be reported as not seeing
      // the board. Reporting it as a board set up wrongly would send the user
      // to move checkers that are exactly where they belong.
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final smaller = renderShot(
        board: BoardState.initial(),
        outWidth: 640,
        outHeight: 480,
      );
      final result = vision.confirmStartingPosition(smaller.frame);

      expect(result.agrees, isFalse);
      expect(result.message, contains('outside the picture'));
    });

    test('an empty board is not a starting position', () {
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final bare =
          renderShot(board: BoardState(points: List<int>.filled(24, 0)));
      final result = vision.confirmStartingPosition(bare.frame);

      expect(result.agrees, isFalse);
      // Every point the game starts on is empty, and the message says so in
      // words the calibration screen can show as they are.
      expect(result.discrepancies, hasLength(8));
      for (final d in result.discrepancies) {
        expect(d.observed, CheckerColor.none);
      }
      expect(result.message.toLowerCase(), contains('checker'));
    });
  });

  group('the calibration fingerprint', () {
    test('two frames of the same scene match', () {
      final shot = renderShot(board: BoardState.initial());
      final calibration = _calibrate(shot);
      final again = CalibrationFingerprint.fromFrame(
        _withNoise(shot.frame),
        calibration.geometry,
      );

      expect(calibration.fingerprint.matches(again), isTrue);
      expect(calibration.fingerprint.geometryMatches(again), isTrue);
      expect(calibration.fingerprint.exposureMatches(again), isTrue);
    });

    test('a nudged board does not match', () {
      final shot = renderShot(board: BoardState.initial());
      final calibration = _calibrate(shot);

      // The same board, the same light — the phone slid a couple of
      // centimetres. The corner patches are looking at the wrong place now.
      final nudged = renderShot(
        board: BoardState.initial(),
        quad: _shifted(kCameraQuad, 62, 41),
      );
      final after =
          CalibrationFingerprint.fromFrame(nudged.frame, calibration.geometry);

      expect(calibration.fingerprint.geometryMatches(after), isFalse);
      expect(calibration.fingerprint.matches(after), isFalse);
    });

    test('an over-exposed board shows up in the exposure stats', () {
      // Worth pinning because it is the one condition the colour model cannot
      // work around. On a board with pale points, enough light clips the
      // points and the white checkers to the same 255 and no colour model can
      // separate what the sensor threw away — so a bare point can read as a
      // white checker. Task 9's readability has to call that red on this
      // number rather than trust the answers.
      final quad = kCameraQuad;
      double clipped(double gain) => CalibrationFingerprint.fromFrame(
            renderShot(
              board: BoardState.initial(),
              palette: BoardPalette.blueRed,
              lightingGain: gain,
            ).frame,
            PlanarBoardGeometry.fromQuad(quad),
          ).clippedFraction;

      expect(clipped(1.0), lessThan(0.01));
      expect(clipped(1.4), greaterThan(0.15));
    });

    test('a darkened room does not match, though the geometry still does', () {
      final shot = renderShot(board: BoardState.initial());
      final calibration = _calibrate(shot);

      final dim = renderShot(board: BoardState.initial(), lightingGain: 0.6);
      final after =
          CalibrationFingerprint.fromFrame(dim.frame, calibration.geometry);

      expect(calibration.fingerprint.exposureMatches(after), isFalse);
      expect(calibration.fingerprint.matches(after), isFalse);
      // Nothing moved, and Task 9 needs the difference: a lamp switched off is
      // a readability problem, not a reason to make the user re-drag corners.
      expect(calibration.fingerprint.geometryMatches(after), isTrue);
    });
  });

  group('no colour constants in the pipeline', () {
    test('lib/ contains no colour literals', () {
      // The spec's rule, made binding: this board's colours are learned from
      // the start position at calibration and from nowhere else. A hex triple
      // or a `Color(...)` under lib/ means something was hardcoded — the very
      // failure that makes a pipeline work on the author's board and no one
      // else's. Two-digit masks (`& 0xFF`) are byte arithmetic and stay legal;
      // six and eight digit literals are how colours get written down.
      final colourish = RegExp(r'0x[0-9a-fA-F]{6,8}\b');
      final flutterColour = RegExp(r'\bColor\s*\(');
      final offenders = <String>[];

      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        final lines = entry.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (colourish.hasMatch(lines[i]) ||
              flutterColour.hasMatch(lines[i])) {
            offenders.add('${entry.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'colours must be learned, never written down');
    });
  });
}

// --- the test's own instruments ---------------------------------------------

/// A view from low at the side of the table: the far edge is barely half the
/// length of the near one.
const BoardQuad _steepQuad = BoardQuad(
  topLeft: Pt(350, 190),
  topRight: Pt(940, 180),
  bottomRight: Pt(1230, 860),
  bottomLeft: Pt(50, 880),
);

/// A board whose two sets of checkers are within a couple of units of each
/// other — the case calibration has to refuse rather than guess at.
const BoardPalette _indistinguishableCheckers = BoardPalette(
  name: 'indistinguishable checkers',
  felt: 0x6E4A2A,
  frame: 0x4A3018,
  pointLight: 0xE0CBA0,
  pointDark: 0x8E2B1C,
  whiteChecker: 0xC9C4B8,
  blackChecker: 0xC6C1B5,
  dieBody: 0xB9C9D6,
  diePip: 0x1A2A38,
);

/// The starting position with the 8-point's and 17-point's stacks exchanged:
/// three White where three Black belong and the other way round.
BoardState _stacksSwapped() {
  final points = List<int>.of(BoardState.initial().points);
  final held = points[7];
  points[7] = points[16];
  points[16] = held;
  return BoardState(points: points);
}

BoardCalibration _calibrate(
  SyntheticShot shot, {
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
}) {
  final result = BoardVision.calibrate(
    frame: shot.frame,
    corners: shot.groundTruthQuad,
    orientation: orientation,
  );
  expect(result.ok, isTrue, reason: result.message);
  return result.calibration!;
}

/// Every checker the renderer drew on a point, sampled at its own centre and
/// pushed through the model — the strongest form of "it learned this board".
void _expectEveryCheckerReadsBack(
  SyntheticShot shot,
  ColorModel colors, {
  BoardOrientation orientation = BoardOrientation.whiteHomeNear,
}) {
  var checked = 0;
  for (final spot in shot.board.checkers) {
    if (spot.area != SpotArea.point) continue;
    final p = shot.toFrame(spot.center);
    final sample = shot.frame.pixelAt(p.x.round(), p.y.round());
    expect(
      colors.classifyIn(RoiId.point(spot.pointIndex), sample),
      CheckerColor.ofPlayer(spot.owner),
      reason: '$spot',
    );
    checked++;
  }
  expect(checked, 30, reason: 'the starting position has thirty checkers');
}

Set<int> _pointNumbersIn(ConfirmResult result) =>
    result.discrepancies.map((d) => d.pointNumber).whereType<int>().toSet();

/// A lamp off to one side: the light falls away smoothly across the frame,
/// which is the spatial non-uniformity a single global exposure cannot model
/// and a per-region reference can.
Frame _sideLit(Frame frame, {double near = 1.0, double far = 0.6}) {
  final bytes = Uint8List.fromList(frame.rgb);
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      final gain = near + (far - near) * x / (frame.width - 1);
      final i = frame.offsetOf(x, y);
      for (var c = 0; c < 3; c++) {
        bytes[i + c] = (bytes[i + c] * gain).round().clamp(0, 255);
      }
    }
  }
  return Frame(bytes, frame.width, frame.height);
}

/// Sensor noise, so "the same scene" is not the same bytes.
Frame _withNoise(Frame frame, {int amplitude = 4, int seed = 7}) {
  final rng = math.Random(seed);
  final bytes = Uint8List.fromList(frame.rgb);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] =
        (bytes[i] + rng.nextInt(2 * amplitude + 1) - amplitude).clamp(0, 255);
  }
  return Frame(bytes, frame.width, frame.height);
}

BoardQuad _shifted(BoardQuad quad, double dx, double dy) => BoardQuad(
      topLeft: Pt(quad.topLeft.x + dx, quad.topLeft.y + dy),
      topRight: Pt(quad.topRight.x + dx, quad.topRight.y + dy),
      bottomRight: Pt(quad.bottomRight.x + dx, quad.bottomRight.y + dy),
      bottomLeft: Pt(quad.bottomLeft.x + dx, quad.bottomLeft.y + dy),
    );
