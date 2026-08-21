import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// **Calibration is a session-long contract, and this is the instrument that
/// keeps it one.**
///
/// The spec's sentence is that every stable frame — not every query — runs
/// cheap validity checks, so that a nudged board, a lamp switched off or a hand
/// left over the felt is caught the moment it happens rather than the next time
/// Buddy needs an answer. What the checks have to produce is a level, a NAMED
/// cause, and one bit that the session routes on: whether the calibration
/// itself is dead (re-drag the corners) or the frame is merely unusable for a
/// moment (wait).
///
/// Getting that bit wrong is the failure this file exists to prevent, in both
/// directions. Call a hand over the board `calibrationStale` and the user is
/// sent to re-calibrate several times a turn; call a board that slid
/// `occluded` and the session goes on reading columns that are no longer there.
///
/// ## What each case is drawn with
///
/// Everything here is the synthetic bed, because every condition has to be
/// *produced* to be tested and the real corpus was filmed under one fixed
/// light with hands clear — acts 3 and 4 of the filming plan, the light change
/// and the sabotage, are not shot yet. What the real corpus does say is in
/// `corpus_harness_test.dart`, where all ten of its frames are run through this
/// module and floored.
void main() {
  group('a frame with nothing wrong with it', () {
    test('reads green, names no cause, and lets answers through', () {
      final shot = _shot();
      final readability = _vision(shot).assessReadability(shot.frame, _still);

      expect(readability.level, ReadabilityLevel.green);
      expect(readability.cause, isNull);
      expect(readability.requiresRecalibration, isFalse);
      expect(readability.answersSuppressed, isFalse);
    });

    test('and so does the same board with the men moved', () {
      // The one thing that changes on every stable frame of a real session is
      // the position. If play itself read as a change, the light would be red
      // for the whole game.
      final base = _shot();
      final vision = _vision(base);
      final points = List<int>.from(BoardState.initial().points);
      points[12] -= 1;
      points[7] += 1;
      points[11] += 1;
      points[16] -= 1;
      final played = _shot(board: BoardState(points: points));

      expect(vision.assessReadability(played.frame, _still).level,
          ReadabilityLevel.green);
    });

    test('a folding case reads green through its own geometry', () {
      final shot = renderFoldingShot(
        board: BoardState.initial(),
        spine: SpineWear.worn,
      );
      final vision = BoardVision(_foldingCalibration(shot));

      expect(vision.assessReadability(shot.frame, _still).level,
          ReadabilityLevel.green);
    });
  });

  group('the board moved', () {
    test('reads red, names the calibration, and routes to recalibration', () {
      final base = _shot();
      final moved = _shot(quad: _slid(kCameraQuad, 62, 41));
      final readability =
          _vision(base).assessReadability(moved.frame, _still);

      expect(readability.level, ReadabilityLevel.red);
      expect(readability.cause, ReadabilityCause.calibrationStale);
      expect(readability.requiresRecalibration, isTrue);
      expect(readability.answersSuppressed, isTrue);
    });

    test('and a board back where it was reads green again', () {
      // Recovery, which is the half of the contract that makes the other half
      // usable: play resumes where it paused rather than after a ceremony.
      final base = _shot();
      final vision = _vision(base);
      final moved = _shot(quad: _slid(kCameraQuad, 62, 41));

      expect(vision.assessReadability(moved.frame, _still).level,
          ReadabilityLevel.red);
      expect(vision.assessReadability(base.frame, _still).level,
          ReadabilityLevel.green);
    });
  });

  group("a folding case's tent relaxing", () {
    // **The blindness this task was asked to close.** A case standing open is
    // tented, and the spine settles flatter over a session — a leaf nudged, a
    // table knocked, the case simply relaxing. The four OUTER corners do not
    // move when that happens: they are on the table. Everything between them
    // does, the hinge strip's own plane most of all, and a check that watches
    // only the corners sees nothing at all.
    //
    // The bed says so exactly. At a ridge relaxed from 0.050 to 0.040 of the
    // board's width, the four corner patches drift 0.056, 0.090, 0.138 and
    // 0.156 — two of four past the bound, which is what the check allows the
    // game's own men to spoil — while the four hinge-seam patches drift 0.350,
    // 0.398, 0.537 and 0.608. Six of eight, and the check fires; four of four,
    // and it does not.
    FoldingShot relaxedTo(double ridge) => renderFoldingShot(
          board: BoardState.initial(),
          spine: SpineWear.worn,
          view: FoldingView(
            ridgeHeight: ridge,
            eye: kFoldingTent.eye,
            target: kFoldingTent.target,
            focal: kFoldingTent.focal,
          ),
        );

    test('reads red and routes to recalibration, corners or no corners', () {
      final base = renderFoldingShot(
        board: BoardState.initial(),
        spine: SpineWear.worn,
      );
      final vision = BoardVision(_foldingCalibration(base));
      final readability =
          vision.assessReadability(relaxedTo(0.040).frame, _still);

      expect(readability.level, ReadabilityLevel.red);
      expect(readability.cause, ReadabilityCause.calibrationStale);
      expect(readability.requiresRecalibration, isTrue);
    });

    test('and the four corners alone would have let it through', () {
      // The mutation, pinned rather than only performed: strip the hinge seams
      // out of the fingerprint and the same frame is a frame in which nothing
      // has changed. That is what the check did before this task, and it is
      // the reason the plan carried the fix here.
      final base = renderFoldingShot(
        board: BoardState.initial(),
        spine: SpineWear.worn,
      );
      final calibration = _foldingCalibration(base);
      final relaxed = CalibrationFingerprint.fromFrame(
        relaxedTo(0.040).frame,
        calibration.geometry,
      );

      expect(calibration.fingerprint.geometryMatches(relaxed), isFalse,
          reason: 'the whole fingerprint has to see the tent');
      expect(
        calibration.fingerprint.cornersOnly.geometryMatches(relaxed.cornersOnly),
        isTrue,
        reason: 'and the four outer corners on their own have to miss it, or '
            'this test is not pinning the blindness it claims to',
      );
    });

    test('a plain board keeps the four-corner behaviour', () {
      // Nothing above may cost a board that does not fold: it has no seams,
      // its fingerprint carries none, and the check is the four corners it
      // always was.
      final shot = _shot();
      final calibration = _calibration(shot);

      expect(calibration.fingerprint.seamPatches, isEmpty);
      expect(calibration.fingerprint.cornersOnly.cornerPatches,
          calibration.fingerprint.cornerPatches);
    });
  });

  group('a hand over the board', () {
    test('reads amber, names occlusion, and does NOT recalibrate', () {
      final base = _shot();
      final covered = _shot(occluder: BoardOccluder.hand);
      final readability = _vision(base).assessReadability(covered.frame, _still);

      expect(readability.cause, ReadabilityCause.occluded);
      expect(readability.level, ReadabilityLevel.amber);
      expect(readability.requiresRecalibration, isFalse,
          reason: 'the spec is explicit that transient causes — a hand over '
              'the board, brief motion — do not route to recalibration');
      expect(readability.answersSuppressed, isTrue);
    });

    test('but on a board the colour of a hand it cannot be seen at all', () {
      // **A pinned limitation, not an oversight.** `lowContrastWood` is the
      // palette built to be hard — felt, frame, points and checkers all in one
      // wood family — and a hand sits 1.8 spreads from its felt, which is
      // inside what the model calls "the board". Colour is the only instrument
      // the occlusion check has, so on that board it has nothing to say.
      //
      // This is here so the limitation cannot quietly change in either
      // direction: if a later idea catches it, this test fails and the doc on
      // `ReadabilityMonitor.minCoveredRegions` gets rewritten rather than
      // silently becoming untrue.
      final base = _shot(palette: BoardPalette.lowContrastWood);
      final covered = _shot(
        palette: BoardPalette.lowContrastWood,
        occluder: BoardOccluder.hand,
      );

      expect(_vision(base).assessReadability(covered.frame, _still), _isGreen);
    });

    test('and lifting it goes straight back to green', () {
      final base = _shot();
      final vision = _vision(base);
      final covered = _shot(occluder: BoardOccluder.hand);

      expect(vision.assessReadability(covered.frame, _still).level,
          ReadabilityLevel.amber);
      expect(vision.assessReadability(base.frame, _still).level,
          ReadabilityLevel.green);
    });
  });

  group('the light', () {
    test('a dim room reads red and names the dark', () {
      final base = _shot();
      final dim = _shot(lightingGain: 0.1);
      final readability = _vision(base).assessReadability(dim.frame, _still);

      expect(readability.level, ReadabilityLevel.red);
      expect(readability.cause, ReadabilityCause.tooDark);
      expect(readability.requiresRecalibration, isFalse,
          reason: 'a lamp switched off is a readability problem that clears '
              'on its own — sending the user to re-drag corners in the dark '
              'would fix nothing');
    });

    test('a drift the colour model can absorb stays green', () {
      // **The seam `ColorModel.renormalized` exists for.** A board at six
      // tenths of its calibration light is outside
      // `CalibrationFingerprint.maxExposureRatio` — the fingerprint says the
      // scene changed — and every query still reads it correctly, because a
      // global scale cancels in a ratio. So this must NOT be red, and it must
      // not be `calibrationStale`: nothing moved.
      final base = _shot();
      final dimmer = _shot(lightingGain: 0.6);
      final calibration = _calibration(base);
      final fingerprint =
          CalibrationFingerprint.fromFrame(dimmer.frame, calibration.geometry);

      expect(calibration.fingerprint.exposureMatches(fingerprint), isFalse,
          reason: 'the premise of this test is a light change the fingerprint '
              'notices');
      expect(BoardVision(calibration).assessReadability(dimmer.frame, _still),
          _isGreen);
    });

    test('a board washing out at the top of the range reads red', () {
      // The one condition no colour model can work around: the sensor threw
      // the difference away. `CalibrationFingerprint.clippedFraction` is the
      // number Task 3 recorded for this, and this is where it is raised.
      final base = _shot(palette: BoardPalette.blueRed);
      final blazing =
          _shot(palette: BoardPalette.blueRed, lightingGain: 1.6);
      final readability = _vision(base).assessReadability(blazing.frame, _still);

      expect(readability.level, ReadabilityLevel.red);
      expect(readability.cause, ReadabilityCause.tooBright);
      expect(readability.requiresRecalibration, isFalse);
    });

    test('the dark is named before the geometry, on the same frame', () {
      // Ordering, and it is not cosmetic. The corner patches are an
      // APPEARANCE comparison, so a light that moved far enough moves them
      // whether or not anything else did — measured on the bed at three tenths
      // of the calibration light, where nothing has moved and the patches
      // drift past their bound. Naming the geometry there would send a user
      // whose board is exactly where they left it to re-drag its corners.
      final base = _shot();
      final dim = _shot(lightingGain: 0.3);
      final calibration = _calibration(base);
      final fingerprint =
          CalibrationFingerprint.fromFrame(dim.frame, calibration.geometry);

      expect(calibration.fingerprint.geometryMatches(fingerprint), isFalse,
          reason: 'the premise: at this light the patch comparison is lying');
      final readability =
          BoardVision(calibration).assessReadability(dim.frame, _still);
      expect(readability.cause, ReadabilityCause.tooDark);
      expect(readability.requiresRecalibration, isFalse);
    });
  });

  group('sharpness', () {
    test('a blurred frame reads amber and names the blur', () {
      final base = _shot();
      final blurred = _shot(blurSigma: 8);
      final readability =
          _vision(base).assessReadability(blurred.frame, _still);

      expect(readability.cause, ReadabilityCause.blur);
      expect(readability.level, ReadabilityLevel.amber);
      expect(readability.requiresRecalibration, isFalse);
    });

    test('and the blur a lens actually has does not', () {
      // The bound is measured against what still READS, not against what looks
      // soft: every palette reads its own starting position back correctly at
      // four sigma of blur, and the first misreads arrive at six.
      final base = _shot();
      expect(_vision(base).assessReadability(_shot(blurSigma: 4).frame, _still),
          _isGreen);
    });
  });

  group('the gyro', () {
    test('a phone in motion reads amber before a pixel is looked at', () {
      // Gyro history is the cheapest and the most authoritative of the
      // checks — a moving phone cannot produce a readable frame, and no amount
      // of measuring the picture is going to change that answer. So it is
      // asked first, and this pins that it costs nothing.
      final shot = _shot();
      final counted = _CountingFrame(shot.frame);
      final readability = _vision(shot)
          .assessReadability(counted, const MotionHint(deviceStill: false));

      expect(readability.cause, ReadabilityCause.motion);
      expect(readability.level, ReadabilityLevel.amber);
      expect(readability.requiresRecalibration, isFalse);
      expect(counted.reads, 0,
          reason: 'the gyro settles this one on its own');
    });

    test('and the phone coming to rest goes back to green', () {
      final shot = _shot();
      final vision = _vision(shot);

      expect(
          vision.assessReadability(
              shot.frame, const MotionHint(deviceStill: false)).level,
          ReadabilityLevel.amber);
      expect(vision.assessReadability(shot.frame, _still), _isGreen);
    });
  });

  group('the board in the picture', () {
    test('a frame the calibrated board does not fit in reads red', () {
      // A session's frames all come through one camera at one size, so this
      // fires on the thing that actually goes wrong: a preview handed over at
      // a different size or crop from the one that was calibrated. Left
      // unnamed, the fingerprint would go on comparing patches that
      // `FrameSampler` had quietly clamped to the picture's border, and the
      // answer would be a geometry verdict about pixels that are not the
      // board.
      final base = _shot();
      final cropped = _cropped(base.frame, kFrameWidth - 220);
      final readability = _vision(base).assessReadability(cropped, _still);

      expect(readability.level, ReadabilityLevel.red);
      expect(readability.cause, ReadabilityCause.boardOutOfFrame);
      expect(readability.requiresRecalibration, isFalse,
          reason: 'a frame that cannot show the board cannot say whether the '
              'calibration is still true — that verdict waits for a frame '
              'that can');
    });
  });

  group('what it costs, every stable frame, for the whole session', () {
    test('under a hundredth of the picture is looked at', () {
      // The doc comment says what the shape of the cost is; this is what makes
      // that claim falsifiable. The whole design of the check — patches and
      // statistics rather than a re-read of the board — turns on it.
      final shot = _shot();
      final counted = _CountingFrame(shot.frame);
      _vision(shot).assessReadability(counted, _still);

      final pixels = shot.frame.width * shot.frame.height;
      expect(counted.reads, lessThan(pixels * 0.01),
          reason: '${counted.reads} reads over $pixels pixels');
      expect(counted.reads, greaterThan(0));
    });
  });
}

// --- the bed ---------------------------------------------------------------

const MotionHint _still = MotionHint(deviceStill: true);

final Matcher _isGreen = predicate<Readability>(
  (r) => r.level == ReadabilityLevel.green,
  'green',
);

SyntheticShot _shot({
  BoardState? board,
  BoardPalette palette = BoardPalette.classic,
  double lightingGain = 1.0,
  BoardQuad quad = kCameraQuad,
  BoardOccluder occluder = BoardOccluder.none,
  double blurSigma = 0,
}) =>
    renderShot(
      board: board ?? BoardState.initial(),
      palette: palette,
      lightingGain: lightingGain,
      quad: quad,
      occluder: occluder,
      degradation: ShotDegradation(
        noise: kCorpusDegradation.noise,
        blurSigma: blurSigma > 0 ? blurSigma : kCorpusDegradation.blurSigma,
        seed: kCorpusDegradation.seed,
      ),
    );

BoardCalibration _calibration(SyntheticShot shot) {
  final result = BoardVision.calibrate(
    frame: shot.frame,
    corners: shot.groundTruthQuad,
    orientation: BoardOrientation.whiteHomeNear,
  );
  expect(result.ok, isTrue, reason: result.message);
  return result.calibration!;
}

BoardCalibration _foldingCalibration(FoldingShot shot) {
  final result = BoardVision.calibrateFolding(
    frame: shot.frame,
    corners: shot.groundTruthCorners,
    orientation: BoardOrientation.whiteHomeNear,
  );
  expect(result.ok, isTrue, reason: result.message);
  return result.calibration!;
}

BoardVision _vision(SyntheticShot shot) => BoardVision(_calibration(shot));

BoardQuad _slid(BoardQuad quad, double dx, double dy) =>
    BoardQuad.fromCorners(<Pt>[
      for (final c in quad.corners) Pt(c.x + dx, c.y + dy),
    ]);

/// The same picture with its right-hand columns cut off — a preview handed
/// over narrower than the one the session calibrated on.
Frame _cropped(Frame frame, int width) {
  final rgb = Uint8List(width * frame.height * 3);
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < width; x++) {
      final from = frame.offsetOf(x, y), to = (y * width + x) * 3;
      rgb[to] = frame.rgb[from];
      rgb[to + 1] = frame.rgb[from + 1];
      rgb[to + 2] = frame.rgb[from + 2];
    }
  }
  return Frame(rgb, width, frame.height);
}

/// A frame that remembers how much of itself was looked at.
class _CountingFrame extends Frame {
  int reads = 0;

  _CountingFrame(Frame frame) : super(frame.rgb, frame.width, frame.height);

  @override
  (int, int, int) pixelAt(int x, int y) {
    reads++;
    return super.pixelAt(x, y);
  }
}
