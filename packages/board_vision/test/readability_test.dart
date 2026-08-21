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

    test('and a room coming back up goes straight to green', () {
      final base = _shot();
      final vision = _vision(base);
      final dim = _shot(lightingGain: 0.1);

      expect(vision.assessReadability(dim.frame, _still).level,
          ReadabilityLevel.red);
      expect(vision.assessReadability(base.frame, _still), _isGreen);
    });

    test('and a lamp turned back down goes straight to green', () {
      final base = _shot(palette: BoardPalette.blueRed);
      final vision = _vision(base);
      final blazing = _shot(palette: BoardPalette.blueRed, lightingGain: 1.6);

      expect(vision.assessReadability(blazing.frame, _still).level,
          ReadabilityLevel.red);
      expect(vision.assessReadability(base.frame, _still), _isGreen);
    });

    // **The two boundaries, bracketed, because the doc had only one of them.**
    // `ReadabilityMonitor.minExposureRatio`'s argument — that the pipeline
    // reads a board down to a fifth of its calibration light, so a light that
    // went red at three tenths would suppress answers that are still right —
    // was measured against the pipeline and is true. What it did not say is
    // that the light goes red at 0.45 anyway on a bed whose ROOM stays lit,
    // through a path with nothing to do with this bound: the corner patches
    // reach outside the playing field, the surround did not dim with the
    // board, and the patch drift is named by the geometry check's light
    // fallback.
    //
    // Both are real conditions. Which one a session is in depends on whether
    // what dimmed was the room or a lamp aimed at the board, so both get
    // pinned from both sides and the doc's table has to match them.
    test('the whole room dimming is red exactly where the bound says', () {
      final base = _shot();
      final vision = _vision(base);

      expect(
        vision.assessReadability(
          _shot(lightingGain: 0.18, roomDimsToo: true).frame,
          _still,
        ),
        _isGreen,
        reason: 'the last green: 0.180 of the calibration light, board and '
            'room together',
      );
      final first = vision.assessReadability(
        _shot(lightingGain: 0.16, roomDimsToo: true).frame,
        _still,
      );
      expect(first.level, ReadabilityLevel.red);
      expect(first.cause, ReadabilityCause.tooDark);
      expect(first.requiresRecalibration, isFalse);
    });

    test('and a board alone going dark is red from 0.46, not from 0.17', () {
      // The path the doc did not describe, and the frames that make the cost
      // of it explicit: at 0.46 the light is red while the board still reads
      // perfectly. Pinned so that nobody can widen or narrow it without the
      // number in the doc moving with it.
      final base = _shot();
      final vision = _vision(base);

      expect(vision.assessReadability(_shot(lightingGain: 0.48).frame, _still),
          _isGreen,
          reason: 'the last green when only the board dims');
      final first =
          vision.assessReadability(_shot(lightingGain: 0.46).frame, _still);
      expect(first.level, ReadabilityLevel.red);
      expect(first.cause, ReadabilityCause.tooDark);
      expect(first.requiresRecalibration, isFalse,
          reason: 'whatever else this is, it must not be a board that moved');
      expect(vision.confirmStartingPosition(_shot(lightingGain: 0.46).frame)
          .discrepancies, isEmpty,
          reason: 'and the cost, stated as a test rather than as a regret: '
              'the pipeline reads this frame perfectly and the light '
              'suppresses it anyway');
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

  group("the light's colour, which is the other half of a stale calibration", () {
    // **The spec names two ways a calibration dies: "geometry moved, colors no
    // longer match".** The second one is what these are about, and it is not
    // the same event as a lamp dimmed. A scalar gain cancels in every ratio the
    // colour model takes — that is the whole design — so a board at six tenths
    // of its light still reads. A lamp CHANGED moves the three channels by
    // three different factors, they do not cancel, and what comes back is a
    // board whose colours have quietly stopped being the ones that were
    // learned.
    //
    // `LightCast` is what lets the bed say that at all; see its doc for where
    // the gains come from. The strength is how much of the lamp change the
    // camera's white balance failed to take out.
    test('a lamp changed rather than dimmed reads red and recalibrates', () {
      // The cast at which reading actually goes wrong, on the palette that
      // shows it most cleanly: at a third of a full tungsten shift the
      // low-contrast wood board clips NOTHING, sits inside every exposure
      // bound, keeps all four corner patches — and `confirmStartingPosition`
      // reports four regions holding the wrong colour. A frame that reads a
      // board wrongly in four places must not be a frame the session answers
      // on.
      final base = _shot(palette: BoardPalette.lowContrastWood);
      final warmed = _shot(
        palette: BoardPalette.lowContrastWood,
        cast: LightCast.tungsten(0.30),
      );
      final vision = _vision(base);
      final fingerprint = CalibrationFingerprint.fromFrame(
        warmed.frame,
        _calibration(base).geometry,
      );

      expect(fingerprint.clippedFraction, 0,
          reason: 'the premise: this is a change of colour, not of level — '
              'nothing here is tooBright');
      expect(vision.confirmStartingPosition(warmed.frame).discrepancies,
          hasLength(4),
          reason: 'and the premise of the premise: the board really has '
              'stopped reading correctly');

      final readability = vision.assessReadability(warmed.frame, _still);
      expect(readability.level, ReadabilityLevel.red);
      expect(readability.cause, ReadabilityCause.calibrationStale);
      expect(readability.requiresRecalibration, isTrue,
          reason: 'the colours are no longer the learned ones, and no amount '
              'of waiting brings the old lamp back — this is invalidating, '
              'not transient');
    });

    test('and a cast the model can still be read through stays green', () {
      // The other side, without which the test above would pass on a check
      // that called every frame stale. Two thirds of the way to the bound is
      // still a light the board reads perfectly.
      final base = _shot(palette: BoardPalette.lowContrastWood);
      final warmed = _shot(
        palette: BoardPalette.lowContrastWood,
        cast: LightCast.tungsten(0.15),
      );

      expect(_vision(base).assessReadability(warmed.frame, _still), _isGreen);
    });

    test('and the boundary between them is bracketed', () {
      // Measured on the wood palette, whose cast drift moves both channels
      // together: 0.16 of a tungsten shift puts the frame at 0.109 and 0.111
      // against `CalibrationFingerprint.maxCastDrift`'s 0.12, and 0.18 puts it
      // at 0.124. The first misread does not arrive until 0.25, so the light
      // goes red with room to spare — the same side of the same argument
      // `maxClippedFraction` is set from, and the same cost: one suppressed
      // answer the next frame supplies, against a phantom checker written into
      // the game state.
      final base = _shot(palette: BoardPalette.lowContrastWood);
      final vision = _vision(base);

      expect(
        vision.assessReadability(
          _shot(
            palette: BoardPalette.lowContrastWood,
            cast: LightCast.tungsten(0.16),
          ).frame,
          _still,
        ),
        _isGreen,
        reason: 'the last cast that stays green',
      );
      final first = vision.assessReadability(
        _shot(
          palette: BoardPalette.lowContrastWood,
          cast: LightCast.tungsten(0.18),
        ).frame,
        _still,
      );
      expect(first.level, ReadabilityLevel.red);
      expect(first.cause, ReadabilityCause.calibrationStale);
    });

    test('and the lamp coming back goes straight to green', () {
      final base = _shot(palette: BoardPalette.lowContrastWood);
      final vision = _vision(base);
      final warmed = _shot(
        palette: BoardPalette.lowContrastWood,
        cast: LightCast.tungsten(0.30),
      );

      expect(vision.assessReadability(warmed.frame, _still).level,
          ReadabilityLevel.red);
      expect(vision.assessReadability(base.frame, _still), _isGreen);
    });

    test('a thing lying on the board is still named as one, not as a lamp', () {
      // **Why the colour check is asked LAST**, and it is measured rather than
      // reasoned. The cast is a board-WIDE statistic, so anything big enough to
      // move the board's average colour moves it: on the blue-red palette a
      // skin-coloured arm across the far edge takes the cast to 0.129 and
      // 0.137 against a bound of 0.12 — past it, on a board where nothing has
      // changed but what is lying on the felt.
      //
      // The occlusion check has already spoken by then, and it is right. Move
      // the colour check above it and this frame sends a user with an arm over
      // their board to re-drag its corners, which is the one thing the spec
      // asks this module never to do.
      final base = _shot(palette: BoardPalette.blueRed);
      final covered = _shot(
        palette: BoardPalette.blueRed,
        occluder: const BoardOccluder(
          center: Pt(0.5, 0.06),
          radiusX: 0.62,
          radiusY: 0.16,
        ),
      );
      final calibration = _calibration(base);
      final fingerprint =
          CalibrationFingerprint.fromFrame(covered.frame, calibration.geometry);

      expect(calibration.fingerprint.castMatches(fingerprint), isFalse,
          reason: 'the premise: an arm on a blue board moves the cast past the '
              'bound all on its own');
      final readability =
          BoardVision(calibration).assessReadability(covered.frame, _still);
      expect(readability.cause, ReadabilityCause.occluded);
      expect(readability.requiresRecalibration, isFalse);
    });

    test('but in the dice band, which nothing watches, it cannot', () {
      // **The measured cost of the two blindnesses meeting**, pinned so that it
      // cannot change without somebody noticing. `_coveredRegions` leaves the
      // dice band out by construction — a die IS unrecognizable there, and
      // counting it would call every roll a hand — so a thing lying across the
      // band is the one occluder the check above cannot veto. On the blue-red
      // palette an ellipse 0.60 of the board wide lying there moves the cast to
      // 0.119 and 0.139, and the frame comes back as a lamp that changed.
      //
      // On the other two palettes the same object moves the cast a tenth as
      // far (0.014/0.031 and 0.019/0.014) and nothing fires, so this is a fact
      // about a blue board under a skin-coloured arm rather than about the
      // check. It is recorded rather than tuned away: the alternative reading
      // of that frame is the one shipped before this test existed, which
      // answered on it.
      final base = _shot(palette: BoardPalette.blueRed);
      final covered = _shot(
        palette: BoardPalette.blueRed,
        occluder: const BoardOccluder(
          center: Pt(0.5, 0.5),
          radiusX: 0.30,
          radiusY: 0.10,
        ),
      );

      expect(
        _vision(base).assessReadability(covered.frame, _still).cause,
        ReadabilityCause.calibrationStale,
        reason: 'and if this ever becomes `occluded`, the doc on '
            '`ReadabilityMonitor._coveredRegions` is the thing to rewrite',
      );
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

    test('and focus catching up goes straight back to green', () {
      final base = _shot();
      final vision = _vision(base);
      final blurred = _shot(blurSigma: 8);

      expect(vision.assessReadability(blurred.frame, _still).level,
          ReadabilityLevel.amber);
      expect(vision.assessReadability(base.frame, _still), _isGreen);
    });
  });

  group('what the order the checks run in actually costs', () {
    // **The doc said this the wrong way round until a reviewer asked for the
    // frames.** It claimed that something covering most of the board's corners
    // reads `calibrationStale` rather than `occluded` — the conservative error.
    // Swept over 28 occluder sizes on all three palettes, `calibrationStale`
    // never came back once, and what does happen is these three. They are
    // pinned because a doc nobody can falsify is a doc that drifts.
    test('a near-total cover is named blur, because a flat fill has no edges',
        () {
      // The Laplacian dies long before the geometry is reached: an ellipse 0.9
      // of the board across leaves 0.030 of the calibration frame's contrast
      // on the classic palette, 0.022 on the blue-red and 0.091 on the wood,
      // against `minSharpnessRatio`'s 0.23.
      final base = _shot();
      final swallowed = _shot(
        occluder: const BoardOccluder(
          center: Pt(0.5, 0.5),
          radiusX: 0.9,
          radiusY: 0.9,
        ),
      );
      final readability = _vision(base).assessReadability(swallowed.frame, _still);

      expect(readability.cause, ReadabilityCause.blur);
      expect(readability.requiresRecalibration, isFalse,
          reason: 'and whatever it is called, it must not be a recalibration');
    });

    test('a large pale one is named by the light, not by the geometry', () {
      // Nothing clips — skin is not white — but a band over half the board
      // lifts the board's own mean luma to 1.380 of its calibration value,
      // past `CalibrationFingerprint.maxExposureRatio`'s 1.3. The patches go
      // with it, and the fallback names the light.
      final base = _shot();
      final flooded = _shot(
        occluder: const BoardOccluder(
          center: Pt(0.5, 0.06),
          radiusX: 1.0,
          radiusY: 0.5,
        ),
      );
      final readability = _vision(base).assessReadability(flooded.frame, _still);

      expect(readability.cause, ReadabilityCause.tooBright);
      expect(readability.requiresRecalibration, isFalse);
    });

    test('and an arm across two corners reads GREEN, which is the real cost',
        () {
      // `geometryMatches` needs more than half the patches moved and an arm
      // across the far edge moves two of four, so the frame falls through to
      // the occlusion check — which on this palette finds no single region
      // covered enough to count. The session answers on a frame with an arm
      // lying across the top of the board. That is the honest cost of the
      // ordering: not a misnamed recalibration, an unnamed occlusion.
      final base = _shot();
      final arm = _shot(
        occluder: const BoardOccluder(
          center: Pt(0.5, 0.06),
          radiusX: 0.62,
          radiusY: 0.16,
        ),
      );

      expect(_vision(base).assessReadability(arm.frame, _still), _isGreen);
      expect(
        _vision(_shot(palette: BoardPalette.blueRed)).assessReadability(
          _shot(
            palette: BoardPalette.blueRed,
            occluder: const BoardOccluder(
              center: Pt(0.5, 0.06),
              radiusX: 0.62,
              radiusY: 0.16,
            ),
          ).frame,
          _still,
        ).cause,
        ReadabilityCause.occluded,
        reason: 'and on a board whose colours are far from skin the same arm '
            'IS caught, so this is a fact about the palette rather than about '
            'the check',
      );
    });

    test('and nothing at all is watching the dice band', () {
      // **The blindness `_coveredRegions` documents, pinned rather than only
      // explained.** The band is left out of the occlusion walk by
      // construction — a die there is unrecognizable BY DESIGN, and counting
      // it would call every roll a hand over the board — so an ellipse 0.60 of
      // the board wide lying across the middle is invisible to the one check
      // that could see it, and the frame reads green.
      //
      // This test exists so that the limitation cannot change silently in
      // either direction: if a later idea catches it, this fails and the doc
      // on `ReadabilityMonitor._coveredRegions` gets rewritten rather than
      // quietly becoming untrue.
      final base = _shot();
      final band = _shot(
        occluder: const BoardOccluder(
          center: Pt(0.5, 0.5),
          radiusX: 0.30,
          radiusY: 0.10,
        ),
      );

      expect(_vision(base).assessReadability(band.frame, _still), _isGreen);
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
      // **Exactly, not merely under a bound.** The doc's table adds up to this
      // number, row by row — 576 lattice + 6,480 sharpness + 324 corner cells
      // + 432 occlusion — and a bound of "under a hundredth" would pass just
      // as happily on 12,000 reads. The claim in the doc is the exact figure,
      // so the exact figure is what is asserted.
      expect(counted.reads, 7812);
    });

    test('and a folding case costs 292 more, not 324', () {
      // The seams add four patches of nine cells at nine reads each — 324 —
      // but a folding board has no bear-off wells, so the occlusion walk makes
      // 26 regions instead of 28 and gives 32 of them back. Both numbers are in
      // the doc and both are here, because their difference is the sort of
      // thing that gets quietly rounded.
      final flat = _shot();
      final flatCount = _CountingFrame(flat.frame);
      _vision(flat).assessReadability(flatCount, _still);

      final folding = renderFoldingShot(
        board: BoardState.initial(),
        spine: SpineWear.worn,
      );
      final foldingCount = _CountingFrame(folding.frame);
      BoardVision(_foldingCalibration(folding))
          .assessReadability(foldingCount, _still);

      expect(foldingCount.reads - flatCount.reads, 292);
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
  LightCast cast = LightCast.neutral,
  BoardQuad quad = kCameraQuad,
  BoardOccluder occluder = BoardOccluder.none,
  double blurSigma = 0,
  bool roomDimsToo = false,
}) =>
    renderShot(
      board: board ?? BoardState.initial(),
      palette: palette,
      lightingGain: lightingGain,
      cast: cast,
      quad: quad,
      occluder: occluder,
      backgroundColor:
          roomDimsToo ? _dimmed(kBackdropColor, lightingGain) : kBackdropColor,
      degradation: ShotDegradation(
        noise: kCorpusDegradation.noise,
        blurSigma: blurSigma > 0 ? blurSigma : kCorpusDegradation.blurSigma,
        seed: kCorpusDegradation.seed,
      ),
    );

/// The room around the board, dimmed by the same factor as the board.
///
/// The bed's `lightingGain` is documented as the light falling on the PLAYING
/// FIELD, and [kBackdropColor] deliberately does not move with it — so the
/// default render is a lamp aimed at the board being turned down while the room
/// stays lit. Both happen; which one a frame is decides where the readability
/// light goes red, and `ReadabilityMonitor.minExposureRatio`'s doc carries the
/// two numbers. Nothing new is needed to draw the other one: `renderShot`
/// already takes the backdrop as a parameter.
int _dimmed(int color, double gain) {
  int channel(int shift) =>
      (((color >> shift) & 0xFF) * gain).round().clamp(0, 255);
  return (channel(16) << 16) | (channel(8) << 8) | channel(0);
}

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
