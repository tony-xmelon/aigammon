import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// Why the synthetic bed needs to be made worse on purpose.
///
/// Task 4's reviewer proved that the perfect scores the flat renderer produces
/// are an arithmetic identity rather than a measurement. The renderer paints in
/// exact colour with no grain; the warp is exact; a checker's pitch in board
/// space comes out an exact multiple of the sampler's row depth. So the length
/// occupancy measures divides into a whole number of checkers **exactly**, and
/// `floor()` in place of `round()` passes the entire 336-cell matrix. A suite
/// that a wrong line of arithmetic cannot fail is not scoring anything.
///
/// These knobs break that identity, and this file is where they are held to it:
/// noise moves the classification of the rows at a checker's rim, blur smears
/// the rim itself, and a sub-pixel jitter of the four corners moves where every
/// board-space sample lands between pixels. The bar is deliberately two-sided —
/// **the residuals must be real** (the mutant dies) **and the answers must
/// still be right** (the targets hold). Either alone is easy and worthless.
void main() {
  group('degradation does something', () {
    final clean = renderShot(board: BoardState.initial());

    test('noise moves pixels, by no more than it was asked to', () {
      final noisy = renderShot(
        board: BoardState.initial(),
        degradation: const ShotDegradation(noise: 6, seed: 1),
      );
      var moved = 0, worst = 0;
      for (var i = 0; i < clean.frame.rgb.length; i++) {
        final d = (noisy.frame.rgb[i] - clean.frame.rgb[i]).abs();
        if (d > 0) moved++;
        if (d > worst) worst = d;
      }
      expect(moved / clean.frame.rgb.length, greaterThan(0.5),
          reason: 'noise that touches almost nothing is not noise');
      expect(worst, lessThanOrEqualTo(6),
          reason: 'noise must stay inside the amplitude asked for');
    });

    test('the same seed is the same frame, a different seed is not', () {
      Frame at(int seed) => renderShot(
            board: BoardState.initial(),
            degradation: ShotDegradation(noise: 6, seed: seed),
          ).frame;
      expect(at(3).rgb, at(3).rgb);
      expect(at(3).rgb, isNot(at(4).rgb));
    });

    test('blur takes the edges off', () {
      final blurred = renderShot(
        board: BoardState.initial(),
        degradation: const ShotDegradation(blurSigma: 1.5),
      );
      expect(_edgeEnergy(blurred.frame), lessThan(_edgeEnergy(clean.frame) / 2),
          reason: 'a blurred frame has less high-frequency energy');
    });

    test('jitter moves the corners, and the picture goes with them', () {
      const asked = kCameraQuad;
      final shot = renderShot(
        board: BoardState.initial(),
        degradation: const ShotDegradation(quadJitter: 0.8, seed: 5),
      );
      final got = shot.groundTruthQuad;
      for (var i = 0; i < 4; i++) {
        final a = asked.corners[i], g = got.corners[i];
        final moved = math.sqrt(
          (a.x - g.x) * (a.x - g.x) + (a.y - g.y) * (a.y - g.y),
        );
        expect(moved, greaterThan(0.0));
        expect(moved, lessThanOrEqualTo(0.8 * math.sqrt2 + 1e-9));
      }
      // The ground truth is the quad the frame was ACTUALLY warped onto, not
      // the one that was asked for — otherwise every corpus sidecar would
      // carry a lie and calibration would be handed corners the picture does
      // not have.
      final corner = shot.toFrame(const Pt(0, 0));
      expect(corner.x, closeTo(got.topLeft.x, 1e-9));
      expect(corner.y, closeTo(got.topLeft.y, 1e-9));
    });

    test('no degradation is the frame the renderer always drew', () {
      final same = renderShot(
        board: BoardState.initial(),
        degradation: ShotDegradation.none,
      );
      expect(same.frame.rgb, clean.frame.rgb);
      expect(same.groundTruthQuad, clean.groundTruthQuad);
    });
  });

  group('the arithmetic identity is broken', () {
    // One shot, three palettes' worth of confidence is the harness's job; this
    // is about the bed, so one representative board is enough and the corpus
    // covers the rest.
    final shot = renderShot(
      board: BoardState.initial(),
      degradation: kCorpusDegradation,
      quad: kCorpusSteepQuad,
    );
    final calibration = BoardVision.calibrate(
      frame: shot.frame,
      corners: shot.groundTruthQuad,
      orientation: BoardOrientation.whiteHomeNear,
    );

    test('a degraded board still calibrates', () {
      expect(calibration.ok, isTrue, reason: calibration.message);
    });

    test('the measured stack lengths carry real residuals', () {
      final vision = BoardVision(calibration.calibration!);
      final occupancy = vision.occupancyIn(shot.frame);
      final stacks = calibration.calibration!.stacks;

      var worstResidual = 0.0;
      var flooringWouldDiffer = 0;
      final start = BoardState.initial();
      for (var i = 0; i < 24; i++) {
        if (start.points[i] == 0) continue;
        final reading = occupancy.read(RoiId.point(i));
        final height = stacks.heightOf(reading.reach);
        final residual = (height - height.roundToDouble()).abs();
        if (residual > worstResidual) worstResidual = residual;
        // The mutant Task 4's suite could not kill: `floor()` where the code
        // says `round()`. On a noiseless bed every height is a whole number and
        // the two agree everywhere; here they must not.
        if (math.max(1, height.floor()) != reading.count) flooringWouldDiffer++;
      }

      expect(worstResidual, greaterThan(0.02),
          reason: 'a bed with no residuals scores nothing: the lengths divided '
              'into whole checkers exactly, so the rounding was never asked a '
              'question');
      expect(flooringWouldDiffer, greaterThan(0),
          reason: 'flooring instead of rounding must now change an answer — '
              'otherwise this corpus cannot fail a wrong line of arithmetic');
    });

    test('and every count is still right', () {
      final vision = BoardVision(calibration.calibration!);
      final occupancy = vision.occupancyIn(shot.frame);
      final start = BoardState.initial();
      for (var i = 0; i < 24; i++) {
        final expected = start.points[i];
        final reading = occupancy.read(RoiId.point(i));
        expect(reading.count, expected.abs(), reason: 'point ${i + 1}');
        expect(
          reading.color,
          expected == 0
              ? CheckerColor.none
              : expected > 0
                  ? CheckerColor.white
                  : CheckerColor.black,
          reason: 'point ${i + 1}',
        );
      }
    });

    test('all three boards calibrate at the corpus level', () {
      for (final palette in BoardPalette.all) {
        final shot = renderShot(
          board: BoardState.initial(),
          palette: palette,
          degradation: kCorpusDegradation,
          quad: kCorpusSteepQuad,
        );
        final result = BoardVision.calibrate(
          frame: shot.frame,
          corners: shot.groundTruthQuad,
          orientation: BoardOrientation.whiteHomeNear,
        );
        expect(result.ok, isTrue, reason: '${palette.name}: ${result.message}');
      }
    });

    test('and the dice still read through the grain', () {
      // Calibrated from the dice-free frame above and read on a later one,
      // which is how a session works and how the corpus is organised: the
      // board's colours are learned once, at the start, with nothing on the
      // felt that the game did not put there.
      final withDice = renderShot(
        board: BoardState.initial(),
        dice: Dice(5, 2),
        degradation: kCorpusDegradation,
        quad: kCorpusSteepQuad,
      );
      final reading =
          BoardVision(calibration.calibration!).readDice(withDice.frame);
      expect(reading, isNotNull);
      expect(<int>[reading!.first.face, reading.second.face]..sort(), [2, 5]);
    });
  });

  /// Where the corpus's degradation level came from, and why it is not higher.
  ///
  /// Both of these are **findings for the Task 6 gate**, pinned here so they
  /// are numbers rather than recollections. Neither is a bug to fix inside this
  /// task: the plan puts algorithm renegotiation at the gate, with photographs
  /// in hand. When either limit moves — a feature space that holds up in the
  /// shadows, a stack measure that survives a smeared foot — these tests fail,
  /// which is the point of writing them down.
  group('where the bed stops being usable', () {
    /// The corpus baseline with exactly one knob turned up.
    CalibrationResult calibrateWith(
      BoardPalette palette, {
      double? noise,
      double? blurSigma,
    }) {
      final shot = renderShot(
        board: BoardState.initial(),
        palette: palette,
        quad: kCorpusSteepQuad,
        degradation: ShotDegradation(
          noise: noise ?? kCorpusDegradation.noise,
          blurSigma: blurSigma ?? kCorpusDegradation.blurSigma,
          quadJitter: kCorpusDegradation.quadJitter,
          seed: kCorpusDegradation.seed,
        ),
      );
      return BoardVision.calibrate(
        frame: shot.frame,
        corners: shot.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
      );
    }

    test('grain of four levels loses the classic board\'s black checkers', () {
      // The classic palette paints Black at 20/18/15. The colour model's
      // feature is a per-channel log ratio, so ±4 levels on a value of 18 is
      // about a quarter of a log unit — nearly two of the model's own minimum
      // spreads, from grain a photograph of a dark checker in ordinary light
      // would carry. The stack reads bare and calibration tells the user their
      // board is set up wrongly, which is the wrong sentence to show someone
      // whose board is right.
      //
      // Worth naming precisely because it predicts a real failure: dark
      // checkers in shadow are the corpus's hardest cell before a single
      // photograph has been taken.
      final result = calibrateWith(BoardPalette.classic, noise: 4);
      expect(result.ok, isFalse);
      expect(result.problem, CalibrationProblem.checkersNotInStartingPosition);

      // And the same board is fine at the level the corpus actually uses.
      expect(calibrateWith(BoardPalette.classic).ok, isTrue);
    });

    test('blur past about 1.8 sigma smears the foot of every stack', () {
      expect(calibrateWith(BoardPalette.classic, blurSigma: 1.8).ok, isFalse,
          reason: 'a 1.8-sigma blur at this frame size spreads the boundary '
              'between a checker and the board under it over about ten pixels');
      expect(calibrateWith(BoardPalette.classic).ok, isTrue);
    });

    test('one sigma of blur and the dice cannot be found at all', () {
      // The tightest limit anywhere in the pipeline, and the most consequential
      // thing this file records. Calibration survives 1.8 sigma; the dice
      // reader stops finding dice between 1.0 and 1.1, on two of three boards
      // at once. Its first gate looks for what the board does not account for
      // and its second asks whether that thing is square, and a blur that
      // leaves a checker perfectly countable has already rounded a die's
      // corners past the squareness threshold.
      //
      // A hand-held phone at arm's length over a table will not always be
      // sharper than one sigma. This is the measurement behind the spec's bet
      // that dice are where the ML escape hatch gets spent, taken before a
      // single photograph exists — and it is why the corpus runs at 0.8.
      for (final sigma in <double>[1.0, 1.1]) {
        final results = <String, bool>{};
        for (final palette in BoardPalette.all) {
          final bare = renderShot(
            board: BoardState.initial(),
            palette: palette,
            quad: kCorpusSteepQuad,
            degradation: ShotDegradation(
              noise: kCorpusDegradation.noise,
              blurSigma: sigma,
              quadJitter: kCorpusDegradation.quadJitter,
              seed: kCorpusDegradation.seed,
            ),
          );
          final calibrated = BoardVision.calibrate(
            frame: bare.frame,
            corners: bare.groundTruthQuad,
            orientation: BoardOrientation.whiteHomeNear,
          );
          expect(calibrated.ok, isTrue,
              reason: 'calibration is not what fails here');
          final withDice = renderShot(
            board: BoardState.initial(),
            palette: palette,
            dice: Dice(5, 2),
            quad: kCorpusSteepQuad,
            degradation: ShotDegradation(
              noise: kCorpusDegradation.noise,
              blurSigma: sigma,
              quadJitter: kCorpusDegradation.quadJitter,
              seed: kCorpusDegradation.seed,
            ),
          );
          results[palette.name] =
              BoardVision(calibrated.calibration!).readDice(withDice.frame) !=
                  null;
        }
        if (sigma == 1.0) {
          expect(results.values, everyElement(isTrue),
              reason: 'one sigma is still inside the envelope: $results');
        } else {
          expect(results.values.where((read) => read).length, lessThan(3),
              reason: 'at 1.1 sigma the reader loses boards: $results');
        }
      }
    });

    test('and the viewpoint cannot go much past half foreshortening', () {
      // The other envelope wall, and the one that decides where the corpus's
      // camera may stand. Measured across the three boards: dice read at a far
      // edge 0.55 of the near one, and stop between 0.5 and 0.45 — a phone
      // very nearly flat on the table. The corpus's steepest viewpoint is
      // 0.58, so it sits inside this rather than on it.
      final flat = _quadAtForeshortening(0.45);
      var read = 0;
      for (final palette in BoardPalette.all) {
        final bare = renderShot(
          board: BoardState.initial(),
          palette: palette,
          quad: flat,
          degradation: kCorpusDegradation,
        );
        final calibrated = BoardVision.calibrate(
          frame: bare.frame,
          corners: bare.groundTruthQuad,
          orientation: BoardOrientation.whiteHomeNear,
        );
        if (!calibrated.ok) continue;
        final withDice = renderShot(
          board: BoardState.initial(),
          palette: palette,
          dice: Dice(5, 2),
          quad: flat,
          degradation: kCorpusDegradation,
        );
        if (BoardVision(calibrated.calibration!).readDice(withDice.frame) !=
            null) {
          read++;
        }
      }
      expect(read, lessThan(3),
          reason: 'at 0.45 foreshortening at least one board loses its dice');
    });
  });
}

/// A head-on viewpoint whose far edge is [foreshortening] of its near one, so
/// that the envelope can be walked rather than argued about.
BoardQuad _quadAtForeshortening(double foreshortening) {
  const nearY = 850.0, farY = 170.0, cx = 640.0, nearHalf = 590.0;
  final farHalf = nearHalf * foreshortening;
  return BoardQuad(
    topLeft: Pt(cx - farHalf, farY),
    topRight: Pt(cx + farHalf, farY),
    bottomRight: Pt(cx + nearHalf, nearY),
    bottomLeft: Pt(cx - nearHalf, nearY),
  );
}

/// Mean **squared** difference between neighbouring pixels.
///
/// Squared, and it has to be: the plain absolute difference is very nearly
/// conserved by a blur, because one step of height H becomes k steps of H/k and
/// the total is the same H. Squaring makes it H²/k, which is the thing a blur
/// actually destroys — the sharpness of an edge rather than the size of it.
double _edgeEnergy(Frame frame) {
  var sum = 0.0;
  var n = 0;
  for (var y = 0; y < frame.height; y += 3) {
    for (var x = 1; x < frame.width; x += 3) {
      final a = frame.pixelAt(x - 1, y), b = frame.pixelAt(x, y);
      final dr = (a.$1 - b.$1).toDouble();
      final dg = (a.$2 - b.$2).toDouble();
      final db = (a.$3 - b.$3).toDouble();
      sum += dr * dr + dg * dg + db * db;
      n++;
    }
  }
  return n == 0 ? 0.0 : sum / n;
}
