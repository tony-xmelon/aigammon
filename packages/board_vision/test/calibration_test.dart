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
      final now = CalibrationFingerprint.fromFrame(dim.frame, calibration.h);
      final exposure = now.meanLuma / calibration.fingerprint.meanLuma;
      expect(exposure, closeTo(0.6, 0.02));

      _expectEveryCheckerReadsBack(
        dim,
        calibration.colors.renormalized(exposure),
      );
    });

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
        final (left, right) = BoardLayout.pointSpan(i);
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
        calibration.h,
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
          CalibrationFingerprint.fromFrame(nudged.frame, calibration.h);

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
            Homography.fromQuad(quad),
          ).clippedFraction;

      expect(clipped(1.0), lessThan(0.01));
      expect(clipped(1.4), greaterThan(0.15));
    });

    test('a darkened room does not match, though the geometry still does', () {
      final shot = renderShot(board: BoardState.initial());
      final calibration = _calibrate(shot);

      final dim = renderShot(board: BoardState.initial(), lightingGain: 0.6);
      final after = CalibrationFingerprint.fromFrame(dim.frame, calibration.h);

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
