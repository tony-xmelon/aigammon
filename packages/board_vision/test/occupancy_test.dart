import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// Occupancy is the first query that has to work on a board nobody set up for
/// it. Calibration got the starting position handed to it; this gets whatever
/// the players left behind, and has to say what colour is on each region and
/// roughly how much of it.
///
/// The matrix below is the plan's: stacks of 0, 1, 2, 3 and 5 on the near half
/// and the far one, across three palettes the pipeline was never told about,
/// under light that has drifted since calibration. Two things are asserted,
/// and they are deliberately different in strength:
///
/// * **the colour is always right** where checkers are present — that is the
///   load-bearing half, because a wrong colour sends a checker to the wrong
///   player and the game state diverges silently;
/// * **the count is exact at 0, 1 and 2, and within one at 3 to 5** — which is
///   what the design asks for, since mid-game counting is always primed by an
///   expected state and blind counts only ever feed diff-matching.
///
/// Every cell also feeds a scoreboard printed at the end, split by half, by
/// palette and by light. The plan wants those splits measured rather than
/// assumed: perspective makes the far half's regions smaller and noisier, and
/// the point of a prototype is to say by how much.
///
/// Light 40% over calibration is the exception, and it is handled as its own
/// subject rather than as a matrix cell — see 'a board lit past what its
/// colours survive'. Both palettes with pale points fail there, one at
/// calibration and one at reading, and both fail because the sensor clipped
/// rather than because anything here could be cleverer.
void main() {
  final scoreboard = _Scoreboard();

  group('occupancy over a board nobody set up for it', () {
    for (final palette in BoardPalette.all) {
      for (final gain in <double>[0.6, 1.0, 1.4]) {
        // Two cells of this matrix are about light the model cannot survive,
        // and they are handled where that is the subject rather than smuggled
        // through here. Blue-red at 1.4 never calibrates at all (its pale
        // points and its white checkers clip to the same 255); classic at 1.4
        // calibrates and then loses its white checkers, which
        // 'a board lit past what its colours survive' measures and pins.
        if (gain == 1.4 && palette != BoardPalette.lowContrastWood) continue;

        test('${palette.name}, light drifted to $gain', () {
          // Calibrated once in even light, as a session is; read later under
          // light that has moved. Nothing re-normalizes on its own — this is
          // the exposure seam the reader has to go through.
          final calibration = _calibrate(
            renderShot(board: BoardState.initial(), palette: palette),
          );
          final vision = BoardVision(calibration);

          for (final stacks in <Map<int, int>>[_boardA, _boardB]) {
            final shot = renderShot(
              board: _boardOf(stacks),
              palette: palette,
              lightingGain: gain,
            );
            final reader = vision.occupancyIn(shot.frame);

            for (var i = 0; i < 24; i++) {
              final signed = stacks[i] ?? 0;
              final expectedCount = signed.abs();
              final expectedColor = signed == 0
                  ? CheckerColor.none
                  : signed > 0
                      ? CheckerColor.white
                      : CheckerColor.black;
              final observed = reader.read(RoiId.point(i));
              scoreboard.record(
                palette: palette.name,
                gain: gain,
                near: BoardLayout.isNearHalf(i),
                expectedCount: expectedCount,
                expectedColor: expectedColor,
                observed: observed,
                where: '${palette.name} gain $gain point ${i + 1}',
              );
            }
          }
        });
      }
    }

    tearDownAll(scoreboard.report);
  });

  // These read the scoreboard the matrix above filled in, which is what keeps
  // a failure from truncating the numbers: a cell that asserted as it went
  // would stop at its first bad region and the splits would never be printed,
  // and the splits are the point of a prototype.
  group('what occupancy promises', () {
    // Every promise test re-pins the EXACT matrix size, not just non-empty:
    // review found that `greaterThan(0)` in one test still let the other two
    // pass alone on an empty scoreboard, and let a future `continue` quietly
    // narrow the matrix while every surviving cell stayed at 100%. If the
    // matrix legitimately changes shape, this number changes with it — in the
    // same commit, on purpose.
    const matrixReadings = 336;

    test('the colour is right wherever checkers are', () {
      expect(scoreboard.readings, matrixReadings,
          reason: 'the full matrix above has to have run first — fewer '
              'readings means cells were skipped and the promises below '
              'cover less than they claim');
      expect(scoreboard.colorWrong, isEmpty,
          reason: 'a wrong colour hands a checker to the wrong player, which '
              'the game state can never recover from');
    });

    test('the count is exact at nothing, one and two', () {
      expect(scoreboard.readings, matrixReadings);
      expect(scoreboard.smallCountWrong, isEmpty,
          reason: 'counts of two and under are the ones the design trusts '
              'without a prior');
    });

    test('the count is within one at three to five', () {
      expect(scoreboard.readings, matrixReadings);
      expect(scoreboard.tallCountWrong, isEmpty);
    });
  });

  group('how far back a stack may sit and still be counted', () {
    // Two ceilings used to disagree by a single step, and the gap between them
    // was the worst kind of gap this pipeline can have: a SILENT one.
    //
    // The walk that finds a checker reaches [RoiSampler.checkerSearchFar]; the
    // walk that measures how far a stack runs would only start a run within
    // that same number of the board's edge — but it measures COVERED ROWS,
    // and the first covered row of a stack lies deeper than the block the
    // finder settled on, because a round checker tapers to nothing at its
    // leading edge and a block is [RoiSampler.checkerPatchDepth] deep. So for
    // one step's width of inset the finder saw a stack the reach walk could
    // not start on. Measured on the bed: at an inset of 0.095 seven of the
    // twenty-four points read ONE checker where five stood, `reach` came back
    // zero, and `confirmStartingPosition` agreed with the board — nothing
    // anywhere said a word.
    //
    // The fix is a derivation rather than a number: the reach walk's lead-in
    // is the finder's ceiling PLUS a block's own depth, which is exactly how
    // much deeper than a block's near end its samples go. Anything the finder
    // can settle on, the reach walk can start on.
    const start = <int>[
      -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, //
      5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2,
    ];

    /// Every inset from flush to well past the ceiling, in half-steps of the
    /// walk — the band that hid is narrower than a whole step.
    const insets = <double>[
      0.02, 0.04, 0.06, 0.08, 0.085, 0.09, 0.095, 0.10, 0.105, 0.11, 0.12,
    ];

    test('a miscount never happens while confirmation is happy', () {
      // The invariant, stated the way a user would state it: if nothing on
      // screen is telling me to fix my board, then what the app believes my
      // board holds is right. Whichever inset the ceiling ends up at, the
      // reading beyond it has to be loud.
      final vision = BoardVision(_calibrate(
        renderShot(board: BoardState.initial()),
      ));

      for (final inset in insets) {
        final shot = renderShot(
          board: BoardState.initial(),
          stackPlacement: StackPlacement(edgeInset: inset),
        );
        if (!vision.confirmStartingPosition(shot.frame).agrees) continue;
        final reader = vision.occupancyIn(shot.frame);
        for (var i = 0; i < 24; i++) {
          expect(reader.read(RoiId.point(i)).count, start[i].abs(),
              reason: 'point ${i + 1} holds ${start[i].abs()} sitting $inset '
                  'in from its edge, and confirmation raised no objection');
        }
      }
    });

    test('a stack the finder can reach is a stack the count can measure', () {
      // The same property from the other side, and the one that says what the
      // ceiling IS rather than only that it is honest. The finder's own reach
      // is the yardstick: where it settles on a checker, the reach walk has to
      // find that checker's run too, so the count comes back exact rather than
      // floored at one.
      final calibration = _calibrate(renderShot(board: BoardState.initial()));
      final vision = BoardVision(calibration);
      var reached = 0.0;

      for (final inset in insets) {
        final shot = renderShot(
          board: BoardState.initial(),
          stackPlacement: StackPlacement(edgeInset: inset),
        );
        final sampler = RoiSampler(
          shot.frame,
          calibration.geometry,
          calibration.atlas,
        );
        final colors = calibration.colorsIn(shot.frame);
        final reader = vision.occupancyIn(shot.frame);
        for (var i = 0; i < 24; i++) {
          if (start[i] == 0) continue;
          final found = sampler.findChecker(i, colors: colors);
          final onChecker = colors.classifyIn(
                RoiId.point(i),
                medianRgb(found.scan.samples),
              ) !=
              CheckerColor.none;
          if (!onChecker) continue;
          reached = inset;
          final reading = reader.read(RoiId.point(i));
          expect(reading.reach, greaterThan(0.0),
              reason: 'the finder settled on a checker at depth '
                  '${found.depth} on point ${i + 1}, sitting $inset in from '
                  'its edge, and the reach walk measured nothing');
          expect(reading.count, start[i].abs(),
              reason: 'point ${i + 1} holds ${start[i].abs()} sitting $inset '
                  'in from its edge, read $reading');
        }
      }
      // And the ceiling is worth having: a hand leaves a stack this far in.
      expect(reached, greaterThanOrEqualTo(0.09),
          reason: 'the finder stopped reaching stacks at $reached');
    });
  });

  group('reading the board, region by region', () {
    test('an untouched starting position counts itself back', () {
      final shot = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(shot));
      final reader = vision.occupancyIn(shot.frame);
      final start = BoardState.initial();

      for (var i = 0; i < 24; i++) {
        final signed = start.points[i];
        final observed = reader.read(RoiId.point(i));
        expect(observed.color, _colorOf(signed), reason: 'point ${i + 1}');
        expect((observed.count - signed.abs()).abs(), lessThanOrEqualTo(1),
            reason: 'point ${i + 1} holds ${signed.abs()}, read '
                '${observed.count}');
      }
      // The bar and both trays start empty, and saying otherwise would put a
      // phantom checker into the authoritative state on move one.
      for (final id in const <RoiId>[
        RoiId.bar,
        RoiId.offWhite,
        RoiId.offBlack,
      ]) {
        expect(reader.read(id).count, 0, reason: '$id starts empty');
      }
    });

    test('the same board read from the other seat', () {
      // Orientation half-turns the atlas but not the frame, so every region a
      // reading names has to come back the same from either side of the table.
      for (final orientation in BoardOrientation.values) {
        final shot = renderShot(
          board: _boardOf(_boardA),
          orientation: orientation,
        );
        final start = renderShot(
          board: BoardState.initial(),
          orientation: orientation,
        );
        final vision =
            BoardVision(_calibrate(start, orientation: orientation));
        final reader = vision.occupancyIn(shot.frame);

        for (final entry in _boardA.entries) {
          final observed = reader.read(RoiId.point(entry.key));
          expect(observed.color, _colorOf(entry.value),
              reason: '${orientation.name}: point ${entry.key + 1}');
        }
      }
    });

    test('checkers on the bar are counted per colour, not lumped', () {
      // The bar holds both colours at once, stacked outward from the middle in
      // opposite directions. Task 7 routes every hit through it, so a reading
      // that could only name one of the two would be useless exactly when it
      // matters.
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final shot = renderShot(
        board: _boardOf(_boardA, whiteBar: 2, blackBar: 1),
      );
      final reader = vision.occupancyIn(shot.frame);

      expect(reader.readFor(RoiId.bar, CheckerColor.white).count, 2);
      expect(reader.readFor(RoiId.bar, CheckerColor.black).count, 1);
    });

    test('borne-off checkers are counted in their own tray', () {
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));

      final shot = renderShot(board: _boardOf(_boardA, whiteOff: 2));
      final reader = vision.occupancyIn(shot.frame);

      final tray = reader.read(RoiId.offWhite);
      expect(tray.color, CheckerColor.white);
      expect(tray.count, 2);
      expect(reader.read(RoiId.offBlack).count, 0);
    });
  });

  group('what a reading admits it does not know', () {
    test('a region calibration never saw bare is trusted less when it reads '
        'empty', () {
      // Nine regions had checkers standing on them while their background was
      // learned, so their idea of "bare board" is borrowed rather than
      // measured. An empty reading there deserves less weight than the same
      // reading on a point that showed calibration its whole surface, and the
      // confidence has to say so or Task 7 will weigh them the same.
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));
      final bare = renderShot(board: _boardOf(const <int, int>{}));
      final reader = vision.occupancyIn(bare.frame);

      final measured = reader.read(RoiId.point(3)); // empty at calibration
      final borrowed = reader.read(RoiId.point(5)); // five White stood here
      expect(measured.count, 0);
      expect(borrowed.count, 0);
      expect(borrowed.confidence, lessThan(measured.confidence));
    });

    test('a tall stack is less confident than a short one', () {
      // The count is a length divided by a pitch, so its error grows with the
      // length. Saying so is the whole reason the design never trusts a blind
      // count above two.
      final start = renderShot(board: BoardState.initial());
      final vision = BoardVision(_calibrate(start));
      final shot = renderShot(board: _boardOf(_boardA));
      final reader = vision.occupancyIn(shot.frame);

      final short = reader.read(RoiId.point(1)); // one checker
      final tall = reader.read(RoiId.point(8)); // five
      expect(short.confidence, greaterThan(tall.confidence));
    });

    test('a die parked on a stack is counted as another checker', () {
      // MEASURED, and a real thing that happens on a real board: a die rolls
      // to a stop against a tall point and comes to rest in that point's
      // headroom, which the atlas hands to the point and to the dice band at
      // once. Occupancy has no idea what a die is — nothing does, there is no
      // learned distribution for one — so on two of the three palettes a die
      // whose body reads as checker-coloured adds a checker to the stack under
      // it. On the third it does not, because that board's dice look nothing
      // like its checkers.
      //
      // Two reasons this is reported rather than fixed. It stays inside the
      // band the design asks for (within one at three to five), and the
      // confidence halves — the measured length lands between two whole
      // checkers, which is exactly what that factor is for. And the session
      // reads the dice from a settled frame BEFORE it asks about checkers, so
      // by the time occupancy is asked, where the dice are is known. Task 7's
      // matcher could subtract them; that is a decision for the gate, with
      // photographs.
      final palette = BoardPalette.lowContrastWood;
      final calibration = _calibrate(
        renderShot(board: BoardState.initial(), palette: palette),
      );
      final vision = BoardVision(calibration);
      const stack = 8; // near half, five White
      final board = _boardOf(const <int, int>{stack: 5, 20: 10, 15: -15});
      final (left, right) = BoardLayout.standard.pointSpan(stack);

      final clean = vision
          .occupancyIn(renderShot(board: board, palette: palette).frame)
          .read(RoiId.point(stack));
      final crowded = vision
          .occupancyIn(renderShot(
            board: board,
            palette: palette,
            dicePlacements: <DicePlacement>[
              DicePlacement(face: 4, center: Pt((left + right) / 2, 0.50)),
              const DicePlacement(face: 3, center: Pt(0.70, 0.50)),
            ],
          ).frame)
          .read(RoiId.point(stack));

      expect(clean.count, 5);
      expect(crowded.color, CheckerColor.white);
      expect(crowded.count, 6);
      expect(crowded.confidence, lessThan(clean.confidence / 1.5),
          reason: 'a count that lands between two checkers has to say so');
    });

    test('a board lit past what its colours survive loses White on its pale '
        'points, and says nothing rather than the wrong thing', () {
      // MEASURED, and left in the open rather than tuned away. Lit 40% over
      // the light it was calibrated under, the classic board's white checkers
      // clip to 255 — they are painted at 245, and 245 x 1.4 is off the top of
      // the sensor. Re-normalizing cannot bring back a number the frame does
      // not contain.
      //
      // What it costs is not uniform, and the pattern says exactly what went
      // wrong. A white checker standing on a DARK triangle still reads: its
      // reference did not clip, so the ratio still tells the two apart. A
      // white checker on a PALE triangle does not: the paint clips to the same
      // 255 the checker does, the difference between them stops existing in
      // the frame, and the point's own surface wins. That is the same physical
      // story that makes the blue-red board refuse calibration outright at
      // this gain — pale paint and white checkers converging — seen one point
      // at a time instead of all at once.
      //
      // Two things worth pinning about the failure:
      //
      // * it degrades to NOTHING, never to Black. A checker Buddy cannot see
      //   contradicts the expected state and gets asked about; a checker
      //   handed to the wrong player does not, and the game diverges in
      //   silence. The colour model's `maxClassDistance` is what keeps the
      //   failure on the safe side.
      // * the session can see it coming without reading a single checker —
      //   but only by the right instrument. The clipped fraction is three
      //   times what the calibrator calls over-exposed, while the
      //   fingerprint's exposure-drift check MISSES this frame, and the reason
      //   is worth knowing: mean board luma moves with where the checkers are
      //   as well as with the light. The same thirty checkers rearranged move
      //   it by about 3% (measured: 95.3 at the start position, 92.6 here),
      //   which is enough to slide a frame lit 40% over back under a limit of
      //   30%. Task 9 must not lean on the luma ratio alone for
      //   over-exposure; clipping is the signal that does not lie.
      //
      // The fix, if the corpus says real cameras do this often enough to
      // matter, is censored classification: a channel pinned at 255 is a lower
      // bound, not a measurement, and a class whose expected value sits above
      // it is not contradicted by one. That belongs in the colour model, at
      // the Task 6 gate, with photographs to justify it.
      final calibration =
          _calibrate(renderShot(board: BoardState.initial()));
      final shot = renderShot(board: _boardOf(_boardA), lightingGain: 1.4);
      final reader = BoardVision(calibration).occupancyIn(shot.frame);

      final lost = <int>[], survived = <int>[];
      for (final entry in _boardA.entries) {
        final observed = reader.read(RoiId.point(entry.key));
        if (entry.value > 0) {
          expect(observed.color, isNot(CheckerColor.black),
              reason: 'point ${entry.key + 1} must never change hands');
          (observed.color == CheckerColor.none ? lost : survived)
              .add(entry.key);
        } else {
          // Black is painted dark, nothing about it clips, and it survives.
          expect(observed.color, CheckerColor.black,
              reason: 'point ${entry.key + 1}');
        }
      }
      // The renderer paints odd-indexed points in its light colour and even
      // ones in its dark colour, and that is exactly the split.
      expect(lost, isNotEmpty);
      expect(lost.every((i) => i.isOdd), isTrue,
          reason: 'White was lost on $lost — expected only pale points');
      expect(survived.every((i) => i.isEven), isTrue,
          reason: 'White survived on $survived — expected only dark points');

      final fingerprint = CalibrationFingerprint.fromFrame(
        shot.frame,
        calibration.geometry,
      );
      expect(fingerprint.clippedFraction,
          greaterThan(Calibrator.maxClippedFraction),
          reason: 'the session has to be able to refuse this frame');
      // Pinned as the shortcoming it is, not as an approval: this frame is
      // 40% over and the drift check waves it through.
      expect(calibration.fingerprint.exposureMatches(fingerprint), isTrue,
          reason: 'if this ever starts failing, the luma ratio got better at '
              'its job and the comment above needs revisiting');
    });
  });

  group('the stack pitch calibration measures', () {
    test('is learned from the eight stacks the starting position labels', () {
      // The one number that turns a length into a count. It is measured, never
      // written down: the start position hands over stacks of two, three and
      // five on both halves, which is a regression with three distinct heights
      // and no assumption about how a board is proportioned.
      final calibration =
          _calibrate(renderShot(board: BoardState.initial()));
      final stacks = calibration.stacks;

      expect(stacks.wellConditioned, isTrue);
      // A point's region is half the board deep, and five checkers very nearly
      // fill it — so a pitch far from a tenth of the board would mean the fit
      // had latched onto something that is not a stack.
      expect(stacks.pitch, greaterThan(0.05));
      expect(stacks.pitch, lessThan(0.12));
    });

    // The pitch is how far one more checker reaches, and that cannot depend on
    // where a person happened to set the stack down. It used to: the reach
    // walk started at the board's edge and stopped at the first wide gap, so a
    // stack sitting a hand's width inside its edge had a gap before it, the
    // walk stopped before it started, and every stack on the board measured
    // zero. Calibration still learned the colours and said yes — and then
    // occupancy counted one checker on all eight stacks, which is the worst
    // kind of failure this pipeline can have.
    //
    // Run over the whole matrix, at each palette's own measured ceiling: this
    // used to be one classic render in one light, which is the easiest cell of
    // the bed, and the ceiling turns out to differ by a factor of three
    // between palettes. See [insetCeilingOf].
    for (final palette in BoardPalette.all) {
      for (final gain in <double>[0.6, 1.0, 1.4]) {
        if (palette == BoardPalette.blueRed && gain == 1.4) continue;

        test('is the same on a ${palette.name} board at gain $gain whose '
            'stacks are not flush', () {
          final insets = handPlacedStacks(palette, gain);
          final flush = _calibrate(renderShot(
            board: BoardState.initial(),
            palette: palette,
            lightingGain: gain,
          ));
          final shot = renderShot(
            board: BoardState.initial(),
            palette: palette,
            lightingGain: gain,
            pointPlacements: insets,
          );
          final calibration = _calibrate(shot);

          expect(calibration.stacks.wellConditioned, isTrue);
          expect(
            calibration.stacks.pitch,
            closeTo(flush.stacks.pitch, 0.01),
            reason: 'the same board, the same checkers, stacks left where a '
                'hand left them: ${calibration.stacks} against ${flush.stacks}',
          );

          final reader = BoardVision(calibration).occupancyIn(shot.frame);
          final start = BoardState.initial();
          // Every point, not only the eight with stacks: a triangle whose base
          // an inset stack has uncovered is exactly where a phantom checker
          // would turn up, and the sixteen empty ones are where nothing is
          // watching otherwise.
          for (var index = 0; index < 24; index++) {
            final reading = reader.read(RoiId.point(index));
            expect(reading.count, start.points[index].abs(),
                reason: 'point ${index + 1} holds ${start.points[index]}, '
                    'sitting ${insets[index]?.edgeInset ?? 0} in from its '
                    'edge, read $reading');
          }
        });
      }
    }

    test('holds across palettes and seatings', () {
      final pitches = <double>[];
      for (final palette in BoardPalette.all) {
        for (final orientation in BoardOrientation.values) {
          final calibration = _calibrate(
            renderShot(
              board: BoardState.initial(),
              palette: palette,
              orientation: orientation,
            ),
            orientation: orientation,
          );
          pitches.add(calibration.stacks.pitch);
        }
      }
      // The same physical board every time, so the same pitch every time —
      // within the quantisation of the profile the reach is measured on.
      final lo = pitches.reduce((a, b) => a < b ? a : b);
      final hi = pitches.reduce((a, b) => a > b ? a : b);
      expect(hi - lo, lessThan(0.01), reason: 'pitches: $pitches');
    });

    // The eight stacks the starting position labels, as the first real folding
    // frame measured them. Every number here came off that photograph and is
    // written down for the same reason every other measurement in this package
    // is: it is the case that broke, and arithmetic cannot be argued with.
    //
    // Two of the eight failed to measure. The 13-point's five-stack came back
    // 0.0667 where its three twins reach 0.33 to 0.37, and the 20-point's came
    // back 0.1458 — a run that stopped at a gap partway up the stack rather
    // than a stack that is short. Least squares cannot know that, so it
    // regressed through them anyway and returned a pitch of 0.0429 against a
    // true 0.087. Nothing refused: separation was 7.1, `confirm` agreed, and
    // then every count on the board was divided by half the truth — the tall
    // stacks over-counting (5 read as 8), the collapsed ones under-counting
    // (5 read as 1), ten of twenty-four points wrong on the frame the whole
    // session is calibrated from.
    const realFrameStacks = <(int, double)>[
      (2, 0.0917), // the 1-point
      (5, 0.3333), // the 6-point
      (3, 0.2000), // the 8-point
      (5, 0.0667), // the 13-point — collapsed
      (5, 0.3667), // the 14-point
      (3, 0.1208), // the 18-point
      (5, 0.1458), // the 20-point — collapsed
      (2, 0.0917), // the 24-point
    ];

    group('a stack that failed to measure is not data', () {
      test('the pitch survives two of eight collapsing', () {
        // The whole fix in one assertion. Stacks of the same labelled height
        // stand on the same board, so they reach the same distance; one that
        // measures a fraction of what its twins measure did not get measured,
        // and a regression that treats it as evidence is fitting a line
        // through a failure.
        final fitted = StackMetrics.fit(realFrameStacks);
        expect(fitted.pitch, closeTo(0.087, 0.005),
            reason: 'the two collapsed stacks dragged the pitch to '
                '${fitted.pitch} — every count on the board divides by this');
        expect(fitted.wellConditioned, isTrue,
            reason: 'six of the eight survived, at three distinct heights, '
                'which is a better regression than most boards will offer');
      });

      test('and the stacks that measured cleanly count back', () {
        // What the pitch is FOR, so the number above is not an abstraction.
        // Under the old fit, only the two 2-stacks counted back; the 6- and
        // 14-points read 7 and 8, the 8-point read 4, and the two collapsed
        // ones read 1 and 3.
        final fitted = StackMetrics.fit(realFrameStacks);
        const cleanlyMeasured = <(int, double)>[
          (2, 0.0917), // the 1-point
          (5, 0.3333), // the 6-point
          (3, 0.2000), // the 8-point
          (5, 0.3667), // the 14-point
          (2, 0.0917), // the 24-point
        ];
        for (final (height, reach) in cleanlyMeasured) {
          expect(fitted.heightOf(reach).round(), height,
              reason: 'a stack of $height reaching $reach came back as '
                  '${fitted.heightOf(reach)}');
        }

        // And the honest edge of the rule. This frame has a THIRD stack that
        // measured badly without measuring absurdly: the 18-point's three men
        // reach 0.1208 where their twin on the 8-point reach 0.2000. Sixty
        // percent is not the factor of two that says "this did not happen",
        // so [StackMetrics.minStackAgreement] keeps it and it counts back as
        // two rather than three. Tightening the rule until it caught this
        // would start throwing away honest measurements off noisy boards,
        // which trades a wrong count for a refused calibration. Pinned as the
        // edge it is: the fix takes this frame from two of eight counting
        // back to five, not to eight.
        expect(fitted.heightOf(0.1208).round(), 2,
            reason: 'if this becomes 3, the fit got better and the comment '
                'above wants revisiting');
      });

      test('a run of almost nothing is not a checker, whatever the line says',
          () {
        // The second half of what that frame got wrong, and it survives a
        // healthy pitch. Six honest stacks of two, three and five fit a pitch
        // of 0.0874 with an origin of -0.0905 — a fine line through the data
        // it was given, and one that says a run of NOTHING is 1.04 checkers.
        // Every empty region whose mass cleared the presence threshold then
        // came back holding a man: four of them on that frame, at runs of
        // 0.008 to 0.037 against a checker 0.0874 deep.
        //
        // Rounding cannot catch it, because rounding asks the same poisoned
        // line. The measured run is what has to be asked.
        final fitted = StackMetrics.fit(realFrameStacks);
        expect(fitted.origin, lessThan(0),
            reason: 'the origin this test is about is the negative one');
        expect(fitted.heightOf(0).round(), 1,
            reason: 'the line really does say a run of nothing is a checker — '
                'that is the trap, and holdsAnything is what avoids it');

        // The four phantoms on that frame.
        for (final reach in <double>[0.0, 0.008, 0.025, 0.037]) {
          expect(fitted.holdsAnything(reach), isFalse,
              reason: 'a run of $reach is a fraction of a checker '
                  '(${fitted.pitch}) and cannot be one');
        }
        // And the shortest real stack on it — two men — is never in doubt.
        expect(fitted.holdsAnything(0.0917), isTrue);

        // Where this is and is not covered, stated so nobody trusts it
        // further than it goes. The RULE is pinned here. Its wiring into
        // `OccupancyReader._resolve` is exercised end to end only by the die
        // in a point's headroom, whose run is exactly zero — because the bed
        // fits a positive origin on every frame it can draw, so a run of a
        // few hundredths already rounds to nothing there and the extra guard
        // never has to fire. It takes a real photograph's negative origin to
        // tell the two apart, and there is no real photograph in this repo.
      });

      test('a board where too many failed is not conditioned, and says so', () {
        // The other side. Exclusion is only honest while enough survives to
        // regress through; past that the answer is that this frame cannot say
        // how the checkers stack, which calibration turns into a sentence.
        final fitted = StackMetrics.fit(const <(int, double)>[
          (2, 0.0917),
          (5, 0.0667),
          (3, 0.0300),
          (5, 0.0700),
        ]);
        expect(fitted.wellConditioned, isFalse);
      });

      test('a board whose stacks all agree loses nothing', () {
        // The rule must be inert on a board that measured cleanly, or it is
        // trading real boards for broken ones.
        final clean = <(int, double)>[
          for (final (h, _) in realFrameStacks) (h, 0.02 + h * 0.087),
        ];
        final fitted = StackMetrics.fit(clean);
        expect(fitted.pitch, closeTo(0.087, 1e-9));
        expect(fitted.origin, closeTo(0.02, 1e-9));
        expect(fitted.wellConditioned, isTrue);
      });
    });
  });

  group('what the corpus found', () {
    test('a die lying in a point\'s headroom is no longer a phantom checker',
        () {
      // Found by the corpus harness, which reads occupancy on shots that have
      // dice on the board and so asks a question no test here had asked. It
      // was the largest single source of miscounts in the synthetic corpus.
      //
      // The mechanism, and why the two halves of the reading disagreed: the
      // dice band overlaps every point's headroom (see [RoiAtlas]), so a die
      // sitting there is inside the point's region. Its pale body is not the
      // board's own surface, so it classifies as a checker and lifts the
      // region's MASS over the presence threshold. But the reach walk starts
      // at the board's edge and stops at the first wide gap, so it found
      // nothing and returned zero — and `_resolve` floored the count at one.
      // The reading that came back was "one checker, reach zero", which is a
      // combination a real stack cannot produce.
      //
      // This was left as a finding for Task 7's diff-matching to dismiss with
      // context. It did not need context. The floor was overriding a
      // measurement with a guess: the region was measured, the measurement
      // said less than half a checker, and the floor said one anyway. Now the
      // measurement is what comes back, and a region that measures under half
      // a checker reads bare — which is what the frame shows.
      //
      // On the first real folding frame this floor alone invented checkers on
      // three empty points, at measured heights of -0.18, 0.21 and 0.21.
      final calibration = _calibrate(
        renderShot(board: BoardState.initial()),
      );
      final withDice = renderShot(
        board: BoardState.initial(),
        // Point 3 (index 2) is empty at the start; the band crosses its
        // headroom, so this die lies inside that point's region.
        dicePlacements: <DicePlacement>[
          const DicePlacement(face: 4, center: Pt(0.76, 0.5)),
          const DicePlacement(face: 2, center: Pt(0.30, 0.5)),
        ],
      );
      final reading = BoardVision(calibration)
          .occupancyIn(withDice.frame)
          .read(RoiId.point(2));

      expect(reading.mass, greaterThan(OccupancyReader.minPresenceMass),
          reason: 'the die still reads as something the board does not '
              'account for — that half was never the bug');
      expect(reading.reach, 0.0,
          reason: 'nothing was found at the foot of the point, which is the '
              'signature that separates this from a real checker');
      expect(reading.count, 0);
      expect(reading.color, CheckerColor.none,
          reason: 'count is zero exactly when the colour is none, and a '
              'region that measured nothing standing in it holds nothing');
    });

    test('a lone checker is still a lone checker', () {
      // The other side of dropping the floor, and the reason it was there. A
      // single checker measures barely over half a pitch on some boards, so
      // this is the reading that must NOT round away — the count where the
      // design promises exactness.
      final calibration = _calibrate(renderShot(board: BoardState.initial()));
      final lone = List<int>.filled(24, 0);
      lone[2] = 1;
      lone[9] = -1;
      // Thirty men on the board, so the exposure reference does not move.
      lone[7] = 14;
      lone[16] = -14;
      final shot = renderShot(
        board: BoardState(
          points: lone,
          whiteBar: 0,
          blackBar: 0,
          whiteOff: 0,
          blackOff: 0,
        ),
      );
      final reader = BoardVision(calibration).occupancyIn(shot.frame);
      expect(reader.read(RoiId.point(2)).count, 1);
      expect(reader.read(RoiId.point(2)).color, CheckerColor.white);
      expect(reader.read(RoiId.point(9)).count, 1);
      expect(reader.read(RoiId.point(9)).color, CheckerColor.black);
    });
  });
}

// --- the boards this file counts --------------------------------------------

/// Stacks by point index, positive for White. Both boards hold all thirty
/// checkers: `exposureIn` measures the board's own brightness, so a test board
/// with half its men missing would read as a room that had dimmed and every
/// classification would be judged against a reference that had moved.
///
/// Board A puts White's ladder of 1, 2, 3 and 5 on the near half and Black's
/// on the far one; board B swaps the colours over. Between them every count
/// the plan names is read on both halves in both colours, and the points left
/// out — including four the starting position had stacks on — are the empty
/// cases.
const Map<int, int> _boardA = <int, int>{
  1: 1, 3: 2, 5: 3, 8: 5, // White, near half
  20: 4, //                  White, parked far
  13: -1, 15: -2, 18: -3, 21: -5, // Black, far half
  9: -4, //                  Black, parked near
};

const Map<int, int> _boardB = <int, int>{
  2: -1, 4: -2, 7: -3, 10: -5, // Black, near half
  22: -4, //                     Black, parked far
  14: 1, 17: 2, 19: 3, 12: 5, // White, far half
  6: 4, //                       White, parked near
};

BoardState _boardOf(
  Map<int, int> stacks, {
  int whiteBar = 0,
  int blackBar = 0,
  int whiteOff = 0,
  int blackOff = 0,
}) {
  final points = List<int>.filled(24, 0);
  stacks.forEach((index, signed) => points[index] = signed);
  return BoardState(
    points: points,
    whiteBar: whiteBar,
    blackBar: blackBar,
    whiteOff: whiteOff,
    blackOff: blackOff,
  );
}

CheckerColor _colorOf(int signed) => signed == 0
    ? CheckerColor.none
    : signed > 0
        ? CheckerColor.white
        : CheckerColor.black;

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

// --- the scoreboard ---------------------------------------------------------

/// Accuracy accumulated across the whole matrix, split the way the plan says
/// to track it: by board half, because perspective makes the far one smaller
/// and noisier, and by palette, because a board whose colours barely differ is
/// a different problem from one whose colours shout.
class _Scoreboard {
  int readings = 0;
  final List<String> colorWrong = <String>[];
  final List<String> smallCountWrong = <String>[];
  final List<String> tallCountWrong = <String>[];
  final Map<String, _Tally> byHalf = <String, _Tally>{};
  final Map<String, _Tally> byPalette = <String, _Tally>{};
  final Map<String, _Tally> byGain = <String, _Tally>{};
  final Map<int, _Tally> byCount = <int, _Tally>{};

  void record({
    required String palette,
    required double gain,
    required bool near,
    required int expectedCount,
    required CheckerColor expectedColor,
    required RegionOccupancy observed,
    required String where,
  }) {
    readings++;
    final colourRight = observed.color == expectedColor;
    final exact = observed.count == expectedCount;
    final within1 = (observed.count - expectedCount).abs() <= 1;

    for (final tally in <_Tally>[
      byHalf.putIfAbsent(near ? 'near' : 'far', _Tally.new),
      byPalette.putIfAbsent(palette, _Tally.new),
      byGain.putIfAbsent('gain $gain', _Tally.new),
      byCount.putIfAbsent(expectedCount, _Tally.new),
    ]) {
      tally.add(colourRight: colourRight, exact: exact, within1: within1);
    }

    final saw = '${observed.color.name} x${observed.count}';
    if (!colourRight) {
      colorWrong.add('$where: expected ${expectedColor.name}, saw $saw');
    }
    if (expectedCount <= 2 && !exact) {
      smallCountWrong.add('$where: expected $expectedCount, saw $saw');
    }
    if (expectedCount > 2 && !within1) {
      tallCountWrong.add('$where: expected $expectedCount, saw $saw');
    }
  }

  void report() {
    final lines = <String>['', 'occupancy, as measured on the synthetic bed:'];
    void section(String title, Iterable<MapEntry<Object, _Tally>> rows) {
      lines.add('  $title');
      for (final row in rows) {
        lines.add('    ${row.key.toString().padRight(18)} ${row.value}');
      }
    }

    section('by half', byHalf.entries);
    section('by palette', byPalette.entries);
    section('by light', (byGain.keys.toList()..sort()).map(
          (k) => MapEntry(k, byGain[k]!),
        ));
    section(
      'by true count',
      (byCount.keys.toList()..sort()).map((k) => MapEntry(k, byCount[k]!)),
    );
    // ignore: avoid_print
    print(lines.join('\n'));
  }
}

class _Tally {
  int n = 0, colour = 0, exact = 0, within1 = 0;

  void add({
    required bool colourRight,
    required bool exact,
    required bool within1,
  }) {
    n++;
    if (colourRight) colour++;
    if (exact) this.exact++;
    if (within1) this.within1++;
  }

  String _pc(int hit) => n == 0 ? '   -  ' : '${(100 * hit / n).toStringAsFixed(1)}%';

  @override
  String toString() =>
      'n=${n.toString().padLeft(4)}  colour ${_pc(colour)}  '
      'exact ${_pc(exact)}  within 1 ${_pc(within1)}';
}
