import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// Reading the dice is the one query with no expected answer to lean on. Every
/// other question perception is asked comes primed by the game state — which
/// of these seven plays, does this point still hold four — but a roll is new
/// information, and thirty-six answers are equally likely before it is read.
/// The spec's target is accordingly the highest of any query, and this is the
/// sub-problem it names as most likely to need the ML escape hatch.
///
/// So the tests below are unforgiving in one direction and generous in the
/// other: **all twenty-one unordered pairs must read exactly**, at three
/// placements and rotations across three palettes, and **anything that is not
/// exactly two dice must read as nothing at all**. A guess is worse than a
/// shrug here, because a wrong roll is folded into the authoritative game
/// state and every position after it is wrong, while a shrug costs one tap on
/// the manual dice pad.
///
/// The zone the reader looks in deliberately overlaps every point's headroom
/// and the bar (see [RoiAtlas]'s class doc), so it is full of round things
/// that are not dice. Rejecting them is not an edge case, it is the job.
void main() {
  final calibrations = <String, BoardCalibration>{};
  BoardCalibration calibrationFor(BoardPalette palette) =>
      calibrations.putIfAbsent(
        palette.name,
        () => _calibrate(
          renderShot(board: BoardState.initial(), palette: palette),
        ),
      );

  test('the placements this file rolls at are inside the band the atlas '
      'reserves', () {
    // Otherwise these tests would be measuring the renderer rather than the
    // reader: a die thrown half outside the zone is a different question, and
    // one the session answers by asking for another roll.
    for (final placement in _placements) {
      for (final spot in placement.spots) {
        // The die is square in physical units, so its half-span along the
        // board's short axis picks up the board's aspect on the way through
        // board space.
        final halfSpan = BoardLayout.dieSide /
            2 *
            (math.cos(spot.angle).abs() + math.sin(spot.angle).abs()) *
            kTopDownWidth /
            kTopDownHeight;
        expect(spot.y - halfSpan, greaterThanOrEqualTo(RoiAtlas.pointLength),
            reason: placement.name);
        expect(spot.y + halfSpan, lessThanOrEqualTo(1 - RoiAtlas.pointLength),
            reason: placement.name);
      }
    }
  });

  group('every roll a pair of dice can show', () {
    var pair = 0;
    for (var a = 1; a <= 6; a++) {
      for (var b = a; b <= 6; b++) {
        // Each pair is read at all three placements; the palette rotates over
        // the pairs, so all twenty-one are read on all three boards between
        // them without rendering sixty-three shots three times over.
        final palette = BoardPalette.all[(pair ~/ 3) % BoardPalette.all.length];
        pair++;

        test('$a-$b on ${palette.name}', () {
          final vision = BoardVision(calibrationFor(palette));
          for (final placement in _placements) {
            final shot = renderShot(
              board: BoardState.initial(),
              palette: palette,
              dicePlacements: placement.forFaces(a, b),
            );
            final reading = vision.readDice(shot.frame);
            expect(reading, isNotNull,
                reason: '${placement.name}: found no pair of dice');
            expect(_facesOf(reading!), <int>[a, b],
                reason: '${placement.name}: ${reading.confidence}');
            expect(reading.confidence, greaterThan(0),
                reason: placement.name);
          }
        });
      }
    }
  });

  group('dice the size real ones turned out to be', () {
    // **The bed drew dice at 0.075 of the board across and the first real
    // footage's are 0.021.** Three and a half times smaller, a fiftieth of the
    // area — and every size-derived number in the reader had been written for
    // the bed's. The smallest-blob gate was a share of the BAND, so it threw
    // the real dice away before anything looked at them: `readDice` returned
    // null on all seventy real windows.
    //
    // Nothing here is a new algorithm. The gates are the same three; they are
    // asked about a share of a DIE now instead of a share of the band, and
    // `BoardCalibration.dieSide` is where the session says how big that is.

    /// Comfortably inside the floor, and about what a phone at a sensible
    /// height over a real board gives.
    const workable = 0.030;

    /// What the first real footage actually measured, near the bottom of what
    /// the instrument can do.
    const asShot = 0.021;

    // One calibration per board per die size, not one per roll: a small die
    // means a fine lattice, and calibrating twenty-one times over would pay
    // for it twenty-one times for nothing.
    final small = <String, BoardCalibration>{};
    BoardCalibration bareBoard(
      BoardPalette palette,
      double dieSide, {
      ShotDegradation degradation = ShotDegradation.none,
    }) =>
        small.putIfAbsent(
          '${palette.name}/$dieSide/${degradation.blurSigma}',
          () => _calibrate(
            renderShot(
              board: BoardState.initial(),
              palette: palette,
              dieSide: dieSide,
              degradation: degradation,
            ),
            dieSide: dieSide,
          ),
        );

    for (final dieSide in <double>[workable, asShot]) {
      test('all 21 pairs at a die of $dieSide, on a sharp frame', () {
        // The load-bearing one. A sharp frame at either size must read every
        // roll exactly — the reader is not allowed to be worse at small dice,
        // only at soft ones.
        for (var a = 1; a <= 6; a++) {
          for (var b = a; b <= 6; b++) {
            final palette = BoardPalette.all[(a + b) % BoardPalette.all.length];
            // Calibrated on a BARE board, as a session is — a board
            // calibrated with dice on it learns them as part of itself and
            // can never see dice again (see the group below).
            final calibration = bareBoard(palette, dieSide);
            final shot = renderShot(
              board: BoardState.initial(),
              palette: palette,
              dice: Dice(a, b),
              dieSide: dieSide,
            );
            final reading = BoardVision(calibration).readDice(shot.frame);
            expect(reading, isNotNull,
                reason: '$a-$b on ${palette.name} at a die of $dieSide');
            expect(_facesOf(reading!), <int>[a, b],
                reason: '$a-$b on ${palette.name} at a die of $dieSide');
          }
        }
      });
    }

    test('a die the size the bed draws still reads exactly as it did', () {
      // The default is the bed's own number precisely so that nothing which
      // worked moves. This is the assertion that says so.
      expect(BoardCalibration.defaultDieSide, BoardLayout.dieSide);
      final shot = renderShot(board: BoardState.initial(), dice: Dice(3, 6));
      final reading = BoardVision(calibrationFor(BoardPalette.classic))
          .readDice(shot.frame);
      expect(_facesOf(reading!), <int>[3, 6]);
    });

    test('what small dice cost once the frame is soft', () {
      // Measured rather than asserted, because the honest answer is not "it
      // works". At the corpus's own blur and grain the reader loses readings
      // as the dice shrink, and it loses them as NULLS: over all 21 pairs,
      // 21 found and 21 right at a 31px die, 14 and 14 at 25px, 7 and 7 at
      // 21px. Never a wrong roll — which is the promise this file opens with.
      //
      // Pinned at the two ends rather than across the curve: the point is that
      // small-and-soft costs readings and not correctness.
      var found = 0, right = 0;
      for (var a = 1; a <= 6; a++) {
        for (var b = a; b <= 6; b++) {
          final palette = BoardPalette.all[(a + b) % BoardPalette.all.length];
          final shot = renderShot(
            board: BoardState.initial(),
            palette: palette,
            dice: Dice(a, b),
            dieSide: asShot,
            degradation: kCorpusDegradation,
          );
          final reading = BoardVision(
            bareBoard(palette, asShot, degradation: kCorpusDegradation),
          ).readDice(shot.frame);
          if (reading == null) continue;
          found++;
          if (_facesOf(reading).join() == '$a$b') right++;
        }
      }
      expect(found, greaterThan(0),
          reason: 'a die of $asShot at corpus blur reads nothing at all now');
      expect(right, found,
          reason: 'every reading that comes back has to be the right roll — '
              '$right of $found were');
    });

    test('a die too small to read is refused rather than guessed at', () {
      // Below about twenty pixels the reader stops failing closed: pips merge
      // and split, and the face count comes back confidently wrong. Measured
      // at an 18px die, 3 of 5 readings were the wrong roll on a sharp frame.
      // So there is a floor, and it is a refusal.
      //
      // The floor is in PIXELS, not board-space, because that is what the
      // limit is about — the sensor either resolved the pips or it did not.
      const tiny = 0.012;
      var found = 0;
      for (var a = 1; a <= 6; a++) {
        for (var b = a; b <= 6; b++) {
          final calibration = bareBoard(BoardPalette.classic, tiny);
          final shot = renderShot(
            board: BoardState.initial(),
            dice: Dice(a, b),
            dieSide: tiny,
          );
          expect(
            DiceReader(calibration, shot.frame).diePixels,
            lessThan(DiceReader.minDiePixels),
            reason: 'this test is about dice under the floor',
          );
          if (BoardVision(calibration).readDice(shot.frame) != null) found++;
        }
      }
      expect(found, 0,
          reason: '$found rolls came back from dice too small to resolve, and '
              'measured without the floor most of them are wrong');
    });
  });

  group('anything that is not two dice is nothing', () {
    test('a bare board has no dice on it', () {
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(board: BoardState.initial());
      expect(vision.readDice(shot.frame), isNull);
    });

    test('one die is not a roll', () {
      // A die that bounced off the table, or one hidden under a hand. There is
      // no honest way to report half a roll, and inventing the other half is
      // the one failure the game state cannot survive.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: <DicePlacement>[
          const DicePlacement(face: 5, center: Pt(0.30, 0.50)),
        ],
      );
      expect(vision.readDice(shot.frame), isNull);
    });

    test('a die-perfect thing against the board\'s wall is not a settled die',
        () {
      // A settled die LIES on the surface, so its middle cannot be nearer
      // than half a die to the surface's edge — anything there is standing
      // against the board's wall, however die-like it looks. The bed will
      // happily paint a die in that impossible place, which is exactly what
      // makes it a test: the first real footage grew a phantom "4" centred
      // 0.02 of the board from the far rim, where blur had fused the rim's
      // shadow into pip-sized marks.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: <DicePlacement>[
          const DicePlacement(face: 4, center: Pt(0.30, 0.035)),
          const DicePlacement(face: 3, center: Pt(0.60, 0.30)),
        ],
      );
      expect(vision.readDice(shot.frame), isNull,
          reason: 'the thing at the rim was read as half a pair');
    });

    test('a steep, softened board does not roll its own checkers', () {
      // MEASURED, and the same shape the real footage produces at its far
      // rim: at [kCorpusSteepQuad] the far edge measures half the near one,
      // and at 1.1 sigma of blur the outermost checker of each far stack
      // smears into a die-sized fragment whose bright cores read as pips.
      // Two such fragments pair up: a bare classic board came back 2-4 at a
      // confidence of 0.24 the day the search widened. What no real die
      // shares with them is WHERE they stand — centred 0.039 and 0.047 of
      // the board from the far edge, nearer than half a die, where a settled
      // die cannot put its middle without standing up the board's wall.
      final degradation = ShotDegradation(
        noise: kCorpusDegradation.noise,
        blurSigma: 1.1,
        quadJitter: kCorpusDegradation.quadJitter,
        seed: kCorpusDegradation.seed,
      );
      for (final palette in BoardPalette.all) {
        final bare = renderShot(
          board: BoardState.initial(),
          palette: palette,
          quad: kCorpusSteepQuad,
          degradation: degradation,
        );
        final calibrated = BoardVision.calibrate(
          frame: bare.frame,
          corners: bare.groundTruthQuad,
          orientation: BoardOrientation.whiteHomeNear,
        );
        expect(calibrated.ok, isTrue, reason: palette.name);
        expect(
          BoardVision(calibrated.calibration!).readDice(bare.frame),
          isNull,
          reason: '${palette.name}: a bare board rolled its own checkers',
        );
      }
    });

    test('three dice are not a roll either', () {
      // Somebody's cube, a die from the next table, a die that never got
      // picked up. Two of these three ARE the roll and there is no way to say
      // which, so the answer is nothing.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: <DicePlacement>[
          const DicePlacement(face: 5, center: Pt(0.22, 0.50)),
          const DicePlacement(face: 2, center: Pt(0.38, 0.50)),
          const DicePlacement(face: 6, center: Pt(0.72, 0.50)),
        ],
      );
      expect(vision.readDice(shot.frame), isNull);
    });
  });

  group('the round things in the dice zone are not dice', () {
    // The atlas puts the dice band exactly where a tall stack's top checkers
    // and the innermost checker of each colour on the bar already are. That
    // overlap is by design — the band is the same felt as the points'
    // headroom — so the reader cannot assume the zone is empty of checkers and
    // has to tell a checker from a die by what it looks like.

    test('a five-stack reaching into the band does not become a die', () {
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      // The starting position already stands five checkers on four points, and
      // the fifth of each reaches past where the triangles stop.
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: _placements.first.forFaces(4, 3),
      );
      final reading = vision.readDice(shot.frame);
      expect(reading, isNotNull);
      expect(_facesOf(reading!), <int>[3, 4]);
    });

    test('a loaded bar does not become a die', () {
      // Checkers on the bar stack outward from the middle, so the innermost of
      // each colour sits squarely inside the band — the roundest, most
      // die-sized thing on the board that is not a die.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final board = BoardState(
        points: _lightenedStart,
        whiteBar: 3,
        blackBar: 3,
      );
      final shot = renderShot(
        board: board,
        dicePlacements: _placements.first.forFaces(6, 1),
      );
      final reading = vision.readDice(shot.frame);
      expect(reading, isNotNull, reason: 'the real dice went missing');
      expect(_facesOf(reading!), <int>[1, 6]);
    });

    test('a loaded bar with no dice reads as no dice', () {
      // The sharpest form of the same test: take the real dice away and the
      // only die-sized blobs left in the band are checkers. Every one of them
      // has to be refused, or Buddy invents a roll out of the bar.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState(
          points: _lightenedStart,
          whiteBar: 3,
          blackBar: 3,
        ),
      );
      expect(vision.readDice(shot.frame), isNull);
    });

    test('a die resting against a tall stack is not read', () {
      // MEASURED, and the other side of the same coin: a die that rolls to a
      // stop touching a point's top checker merges with it, and a die fused to
      // a checker is neither square nor pipped enough to survive. One
      // candidate is not a pair, so the answer is nothing.
      //
      // Which is the RIGHT answer, if a frustrating one — the session waits
      // for the next stable frame and then offers the dice pad, rather than
      // reading a face off a shape that is half checker. Whether real dice
      // come to rest against stacks often enough to be worth separating
      // touching blobs is a question for photographs, and a watershed on the
      // foreign mask is the obvious tool if they do.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final points = List<int>.filled(24, 0);
      points[8] = 5;
      points[20] = 10;
      points[15] = -15;
      final (left, right) = BoardLayout.standard.pointSpan(8);
      final shot = renderShot(
        board: BoardState(points: points),
        dicePlacements: <DicePlacement>[
          DicePlacement(face: 4, center: Pt((left + right) / 2, 0.50)),
          const DicePlacement(face: 3, center: Pt(0.70, 0.50)),
        ],
      );
      expect(vision.readDice(shot.frame), isNull);
    });

    test('the same, on all three boards', () {
      for (final palette in BoardPalette.all) {
        final vision = BoardVision(calibrationFor(palette));
        final shot = renderShot(
          board: BoardState(
            points: _lightenedStart,
            whiteBar: 3,
            blackBar: 3,
          ),
          palette: palette,
        );
        expect(vision.readDice(shot.frame), isNull, reason: palette.name);
      }
    });
  });

  group('dice land where dice land, not where the band is', () {
    // MEASURED on the first real footage, and it is why the reader searches
    // the whole playing surface: real players roll wherever the dice stop.
    // Of the four rolls the real corpus carries, one pair settled with a die
    // above the band's far edge, one pair landed entirely among the far-half
    // points, and one pair sat out of the band on both halves at once. A
    // reader that looks only at the band answers null to all of them —
    // honestly, but a session that can never read a roll is a session on the
    // manual dice pad.
    //
    // The placements below sit on DARK-triangle columns deliberately. A
    // region's surfaces cover its whole column, so on a board whose pale
    // triangles sit within [DiceReader.minForeignDistance] of its dice —
    // measured on the bed: the classic palette's die body is 2.3 spreads from
    // a cream triangle's mode, against 13.1 from a dark one's — a die in a
    // pale column never becomes a foreign BLOB at all. Its pips still betray
    // it — the pip-first test below reads exactly that die — but these
    // placements pin the body channel, so they stay where bodies show.

    test('a pair among the far points is read', () {
      for (final palette in BoardPalette.all) {
        final vision = BoardVision(calibrationFor(palette));
        final shot = renderShot(
          board: BoardState.initial(),
          palette: palette,
          dicePlacements: <DicePlacement>[
            const DicePlacement(face: 6, center: Pt(0.238, 0.28)),
            const DicePlacement(face: 3, center: Pt(0.698, 0.30)),
          ],
        );
        final reading = vision.readDice(shot.frame);
        expect(reading, isNotNull,
            reason: '${palette.name}: found no pair among the far points');
        expect(_facesOf(reading!), <int>[3, 6], reason: palette.name);
      }
    });

    test('a pair split across the band\'s edge is read', () {
      // The real corpus's turn-1 shape: one die settled in the band, the
      // other just above its far edge.
      for (final palette in BoardPalette.all) {
        final vision = BoardVision(calibrationFor(palette));
        final shot = renderShot(
          board: BoardState.initial(),
          palette: palette,
          dicePlacements: <DicePlacement>[
            const DicePlacement(face: 4, center: Pt(0.30, 0.50)),
            const DicePlacement(face: 2, center: Pt(0.698, 0.28)),
          ],
        );
        final reading = vision.readDice(shot.frame);
        expect(reading, isNotNull,
            reason: '${palette.name}: found no pair across the band edge');
        expect(_facesOf(reading!), <int>[2, 4], reason: palette.name);
      }
    });

    test('a pair in the near half is read', () {
      for (final palette in BoardPalette.all) {
        final vision = BoardVision(calibrationFor(palette));
        final shot = renderShot(
          board: BoardState.initial(),
          palette: palette,
          // Clear of the near stacks: at y 0.72 the left die's corner kisses
          // the 8-point stack's top checker and the two blobs fuse — which is
          // the pinned die-against-a-stack refusal, not this test's subject.
          dicePlacements: <DicePlacement>[
            const DicePlacement(face: 5, center: Pt(0.301, 0.66)),
            const DicePlacement(face: 1, center: Pt(0.762, 0.70)),
          ],
        );
        final reading = vision.readDice(shot.frame);
        expect(reading, isNotNull,
            reason: '${palette.name}: found no pair in the near half');
        expect(_facesOf(reading!), <int>[1, 5], reason: palette.name);
      }
    });

    test('a die the board\'s colours cannot see is read by its pips', () {
      // The camouflage limit, closed from the other side. The classic
      // palette's die body sits 2.3 spreads from a cream triangle's mode —
      // under the foreign threshold — so a die in a pale column never
      // becomes a foreign blob at all. Its PIPS are another matter: dark,
      // pip-sized and foreign on any surface, they arrive in the mask as
      // isolated dots and carry the face by themselves. This die sits
      // mid-pale-column where its body vanishes; only the pip channel can
      // read it, and the partner die checks that the two channels' finds
      // pair like anything else.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: <DicePlacement>[
          const DicePlacement(face: 4, center: Pt(0.301, 0.30)),
          const DicePlacement(face: 3, center: Pt(0.70, 0.50)),
        ],
      );
      final reading = vision.readDice(shot.frame);
      expect(reading, isNotNull,
          reason: 'the camouflaged die\'s pips went unread');
      expect(_facesOf(reading!), <int>[3, 4]);
    });

    test('a die halved by a camouflage column is refused, not misread', () {
      // The sharpest hazard the widened search opened, MEASURED before it was
      // gated: a die is wider than a column, so it always straddles a column
      // boundary — and where the neighbouring column's surfaces sit within
      // [DiceReader.minForeignDistance] of the die's body, the die's cells
      // over that column simply are not foreign and the blob is the die CUT
      // AT THE SEAM. A truncated 5 reads as a 3 or a 2, and when BOTH dice
      // land that way their fragments agree about their (wrong) size, the
      // pair passes every gate, and a true 5-6 came back 3-3 at a confidence
      // of 0.63 — above the lowest legitimate corpus reading. The one output
      // this reader exists to never produce.
      //
      // What closes it is that the session is TOLD how big its dice are:
      // [BoardCalibration.dieSide] is a calibration input, so a candidate
      // well short of one die across is a fragment, whatever it looks like.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      for (final (a, b) in <(Pt, Pt)>[
        (const Pt(0.27, 0.66), const Pt(0.793, 0.70)),
        (const Pt(0.28, 0.66), const Pt(0.783, 0.70)),
        (const Pt(0.26, 0.66), const Pt(0.803, 0.70)),
      ]) {
        final shot = renderShot(
          board: BoardState.initial(),
          dicePlacements: <DicePlacement>[
            DicePlacement(face: 5, center: a),
            DicePlacement(face: 6, center: b),
          ],
        );
        final reading = vision.readDice(shot.frame);
        expect(reading, isNull,
            reason: 'a pair of camouflage-truncated fragments read as '
                '${reading == null ? '' : _facesOf(reading).join('-')} — a '
                'wrong roll offered instead of a refusal');
      }

      // The same die one column-width further in loses only a sliver — its
      // pips are all a sixth of a die inside its edges — and must still read.
      final mild = vision.readDice(
        renderShot(
          board: BoardState.initial(),
          dicePlacements: <DicePlacement>[
            const DicePlacement(face: 5, center: Pt(0.29, 0.66)),
            const DicePlacement(face: 1, center: Pt(0.762, 0.70)),
          ],
        ).frame,
      );
      expect(mild, isNotNull,
          reason: 'a die merely clipped by a camouflage column went missing');
      expect(_facesOf(mild!), <int>[1, 5]);
    });

    test('a lone checker near the pair does not turn it into three dice', () {
      // The widened search walks territory full of checkers, and the reader
      // gives up the moment it holds three candidates. A checker must
      // therefore die at the shape gate, not linger to veto a real roll.
      // The checker stands on a dark column, where it is as foreign — and as
      // die-sized — as a checker anywhere can be.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final points = List<int>.of(BoardState.initial().points);
      // One Black checker moved off its starting stack to stand alone among
      // the far points, so the board still holds thirty men.
      points[18] += 1;
      points[20] = -1;
      final shot = renderShot(
        board: BoardState(points: points),
        dicePlacements: <DicePlacement>[
          const DicePlacement(face: 6, center: Pt(0.238, 0.28)),
          const DicePlacement(face: 5, center: Pt(0.30, 0.50)),
        ],
      );
      final reading = vision.readDice(shot.frame);
      expect(reading, isNotNull,
          reason: 'the lone checker became a third candidate');
      expect(_facesOf(reading!), <int>[5, 6]);
    });

    test('a busy midgame board with no dice on it reads as no dice', () {
      // The whole-surface form of "anything that is not two dice is
      // nothing": singles and short stacks scattered over both halves are
      // the most die-sized things checkers ever get, and every one of them
      // has to be refused everywhere, not merely inside the band.
      final points = List<int>.filled(24, 0);
      points[2] = 1;
      points[4] = 2;
      points[7] = 5;
      points[10] = -1;
      points[14] = -2;
      points[16] = -1;
      points[18] = -5;
      points[20] = 1;
      points[22] = -3;
      points[12] = 4;
      for (final palette in BoardPalette.all) {
        final vision = BoardVision(calibrationFor(palette));
        final shot = renderShot(
          board: BoardState(points: points, whiteBar: 2, blackBar: 3),
          palette: palette,
        );
        expect(vision.readDice(shot.frame), isNull, reason: palette.name);
      }
    });
  });

  group('a face is a shape, not a count', () {
    // What the first real footage taught at twenty-two pixels a die: a six
    // whose pip columns blur together COUNTS three, a die tilted into two
    // visible faces counts their union, a split dot counts twice — and every
    // one of those wrong counts is a legal number that pairs into a roll no
    // one threw. See [PipPattern] for the shape test that replaced counting;
    // these are the bed-level pins that the reader actually consults it.

    test('dots that stand where no face\'s pips stand are not a die', () {
      // The merged-six signature, painted exactly: three dots in a line at
      // row pitch, where a true three runs corner to corner. A counter calls
      // this a three and pairs it with the real die beside it.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: <DicePlacement>[
          const DicePlacement(
            face: 3,
            center: Pt(0.30, 0.50),
            pipOffsets: <(double, double)>[(0, -1), (0, 0), (0, 1)],
          ),
          const DicePlacement(face: 4, center: Pt(0.70, 0.50)),
        ],
      );
      expect(vision.readDice(shot.frame), isNull,
          reason: 'a line of three dots was read as a face');
    });

    test('dice that drill their pips tighter than the canon read through '
        'their session\'s measured span', () {
      // Real dice vary in where they put their pips: the first real
      // footage's hold their pip square at about 0.8 of the canonical span,
      // and with the centroid wobble of twenty-two-pixel dots on top their
      // true quad misses the canonical shape at its diagonal slots — the
      // measured pattern is pinned in `pip_pattern_test.dart`. The span is
      // a session fact exactly like the die's size: measured once, fixed
      // for the session, never fitted per blob. Here the bed paints such
      // dice and the session says so.
      const tightQuad = <(double, double)>[
        (-0.8, -0.8),
        (0.8, -0.8),
        (-0.8, 0.8),
        (0.8, 0.8),
      ];
      const tightPair = <(double, double)>[(-0.8, -0.8), (0.8, 0.8)];
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: const <DicePlacement>[
          DicePlacement(face: 4, center: Pt(0.30, 0.50), pipOffsets: tightQuad),
          DicePlacement(face: 2, center: Pt(0.70, 0.50), pipOffsets: tightPair),
        ],
      );
      final bare = renderShot(board: BoardState.initial());
      final told = BoardVision.calibrate(
        frame: bare.frame,
        corners: bare.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
        pipSpan: 0.8,
      );
      expect(told.ok, isTrue, reason: told.message);
      final reading = BoardVision(told.calibration!).readDice(shot.frame);
      expect(reading, isNotNull,
          reason: 'the measured span should read these dice');
      expect(_facesOf(reading!), <int>[2, 4]);
    });

    test('a face missing its faintest pips is not read as the smaller face '
        'it resembles', () {
      // The subset trap, measured on the real footage: window glare washes
      // an up-face's pips toward the body's colour, the pip cut misses the
      // faintest of them, and what remains of a five is a geometrically
      // perfect diagonal three — a quincunx CONTAINS the three, a six's
      // corners are a quad. Frame 046 of the stable set read a washed five
      // as a clean 3 that way, through every shape test, and paired it into
      // a roll nobody threw. The recount at a kinder cut is what refuses
      // it: the washed pips are invisible at the pip cut and perfectly
      // visible at half its depth, and a face with more marks than pips is
      // a guess.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: const <DicePlacement>[
          // A five whose two right-hand pips the light has washed: the cut
          // sees the diagonal three.
          DicePlacement(
            face: 5,
            center: Pt(0.30, 0.50),
            pipOffsets: <(double, double)>[(-1, -1), (0, 0), (1, 1)],
            faintPipOffsets: <(double, double)>[(1, -1), (-1, 1)],
          ),
          DicePlacement(face: 4, center: Pt(0.70, 0.50)),
        ],
      );
      expect(vision.readDice(shot.frame), isNull,
          reason: 'a washed five was read as the three inside it');
    });

    test('two die-perfect candidates half a die apart are one die, not a '
        'roll', () {
      // Two SETTLED dice cannot stand their middles much nearer than a die —
      // that close, their blobs merge and the size gate already refuses the
      // union. Separate candidates that close are one die seen twice:
      // measured on the real footage, a tilted die splits at the dark roll
      // of its edge into a top-face and a side-face candidate 0.8 to 1.1
      // dies apart, and three windows paired those halves into 2-3, 1-3 and
      // 1-2 — rolls no one threw. The bed CAN paint two whole dice this
      // close without merging them, which is exactly what makes it a test:
      // the reader must prefer refusing a rare legitimate near-pair to
      // reading a common split die as a roll.
      // On blue-red, whose die stands foreign to every column — a vertical
      // pair cannot fit inside the band, and on the classic palette
      // whichever half it pokes into holds a cream column that camouflages
      // the poking part.
      final vision = BoardVision(calibrationFor(BoardPalette.blueRed));
      final near = vision.readDice(
        renderShot(
          board: BoardState.initial(),
          palette: BoardPalette.blueRed,
          dicePlacements: <DicePlacement>[
            const DicePlacement(face: 2, center: Pt(0.30, 0.4425)),
            const DicePlacement(face: 4, center: Pt(0.30, 0.5575)),
          ],
        ).frame,
      );
      expect(near, isNull,
          reason: 'two candidates a die apart were paired into a roll');

      // A pair with clear felt between the two is a roll, and stays one.
      final apart = vision.readDice(
        renderShot(
          board: BoardState.initial(),
          palette: BoardPalette.blueRed,
          dicePlacements: <DicePlacement>[
            const DicePlacement(face: 2, center: Pt(0.30, 0.42)),
            const DicePlacement(face: 4, center: Pt(0.30, 0.58)),
          ],
        ).frame,
      );
      expect(apart, isNotNull,
          reason: 'a legitimate close pair went missing');
      expect(_facesOf(apart!), <int>[2, 4]);
    });
  });

  group('what the corpus found', () {
    test('a die overlapping the bar is refused, not read with a phantom pip',
        () {
      // The bar is wood where the rest of the band is felt, and a die lying
      // across that seam has a hard dark edge under one side of it. The blur
      // any real optics apply spreads that edge INTO the die, far enough to
      // survive the pip erosion — and when this was first measured, the edge
      // was then COUNTED as a pip: a three read as a four, nothing about the
      // reading looked doubtful, and the wrong roll was offered with full
      // confidence. A seam's blend stands where no face puts a pip, though,
      // and [PipPattern] — the shape test that retired counting when the
      // widened search met the same trick in checker-stack shadows — refuses
      // the blob that carries it. So the same shot is a null today: one
      // candidate short of a pair, one tap on the dice pad, nothing folded
      // into the game state.
      //
      // The corpus generator still keeps dice off the bar and the capture
      // checklist still says throw onto the felt: a refusal costs a tap, and
      // this pin is what says the cost stopped being a wrong roll.
      final calibration = calibrationFor(BoardPalette.blueRed);
      final vision = BoardVision(calibration);

      List<int>? facesAt(double x) {
        final shot = renderShot(
          board: BoardState.initial(),
          palette: BoardPalette.blueRed,
          dicePlacements: <DicePlacement>[
            DicePlacement(face: 3, center: Pt(x, 0.5)),
            const DicePlacement(face: 4, center: Pt(0.70, 0.5)),
          ],
          degradation: kCorpusDegradation,
        );
        final reading = vision.readDice(shot.frame);
        return reading == null ? null : _facesOf(reading);
      }

      // Clear of the bar: right.
      expect(facesAt(0.30), <int>[3, 4]);
      // Lying across the bar's right-hand edge: the seam reads as a line,
      // and a line is not a pip, so the blob is refused rather than read 4.
      expect(facesAt(0.54), isNull,
          reason: 'the seam under the die must refuse the blob, not become '
              'one of its pips');
    });
  });

  group('what calibration must not have been shown', () {
    test('a board calibrated with dice on it can never see dice again', () {
      // Found while building the corpus, and it decides the shape of the whole
      // capture plan, so it is pinned here rather than remembered.
      //
      // The reader finds dice by finding what the board does not account for,
      // and calibration is what teaches it what the board accounts for. Learn
      // the dice band from a frame with dice sitting in it and the dice ARE
      // one of the band's surfaces from then on — perfectly familiar, never
      // foreign, and therefore invisible. Calibration does not notice: it
      // succeeds, because every other thing it checks is still true.
      //
      // Two consequences. The corpus is organised into sessions whose first
      // shot is a bare starting position and whose later shots are read
      // through that calibration, exactly as a real session is. And the
      // calibration screen (the plan's Task 12) has to say so: clear the dice
      // off the board before calibrating.
      final bare = renderShot(board: BoardState.initial());
      final dicey = renderShot(board: BoardState.initial(), dice: Dice(5, 2));

      final fromBare = _calibrate(bare);
      final fromDicey = BoardVision.calibrate(
        frame: dicey.frame,
        corners: dicey.groundTruthQuad,
        orientation: BoardOrientation.whiteHomeNear,
      );
      expect(fromDicey.ok, isTrue,
          reason: 'nothing in calibration is untrue, which is the trap');

      expect(BoardVision(fromBare).readDice(dicey.frame), isNotNull);
      expect(BoardVision(fromDicey.calibration!).readDice(dicey.frame), isNull,
          reason: 'the dice were learned as part of the board');
    });
  });

  group('what a reading is worth', () {
    test('a dim room reads the same dice with less confidence', () {
      // Confidence here is not "how likely is this right" — it is how much
      // signal the frame carried. Halve the light and the pips sit half as far
      // from the die's body in the sensor's own levels, so the same answer is
      // worth less even when it is the same answer. The session uses that to
      // decide whether to speak the roll or ask for a tap.
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final placements = _placements.first.forFaces(6, 3);

      final bright = vision.readDice(
        renderShot(
          board: BoardState.initial(),
          dicePlacements: placements,
        ).frame,
      );
      final dim = vision.readDice(
        renderShot(
          board: BoardState.initial(),
          dicePlacements: placements,
          lightingGain: 0.5,
        ).frame,
      );

      expect(bright, isNotNull);
      expect(dim, isNotNull, reason: 'a dim board is still readable');
      expect(_facesOf(dim!), <int>[3, 6]);
      expect(dim.confidence, lessThan(bright!.confidence));
    });

    test('a reading says where it found each die', () {
      final vision = BoardVision(calibrationFor(BoardPalette.classic));
      final shot = renderShot(
        board: BoardState.initial(),
        dicePlacements: <DicePlacement>[
          const DicePlacement(face: 2, center: Pt(0.22, 0.50)),
          const DicePlacement(face: 5, center: Pt(0.38, 0.50)),
        ],
      );
      final reading = vision.readDice(shot.frame)!;

      // Reported left to right in board space, which is the order the frame
      // shows them in and the only order a reader can honestly claim.
      expect(reading.first.face, 2);
      expect(reading.second.face, 5);
      expect(reading.first.center.x, closeTo(0.22, 0.02));
      expect(reading.second.center.x, closeTo(0.38, 0.02));
      for (final die in <DieReading>[reading.first, reading.second]) {
        expect(die.center.y, closeTo(0.50, 0.02));
      }
    });
  });
}

// --- the placements this file rolls at --------------------------------------

/// Where a pair of dice is thrown, and at what angle.
///
/// Three of them, chosen to move every part of the problem: flat and together
/// in one half; tilted and straddling the bar, which is the one place the
/// band's background is wood rather than felt; and steeply tilted out at the
/// far right, where the band nearly runs out of room for a rotated die and the
/// two lie close enough together to be mistaken for one blob.
class _Placement {
  final String name;
  final List<({double x, double y, double angle})> spots;

  const _Placement(this.name, this.spots);

  List<DicePlacement> forFaces(int a, int b) => <DicePlacement>[
        for (final (i, spot) in spots.indexed)
          DicePlacement(
            face: i == 0 ? a : b,
            center: Pt(spot.x, spot.y),
            angle: spot.angle,
          ),
      ];
}

const List<_Placement> _placements = <_Placement>[
  _Placement('flat, left half', <({double x, double y, double angle})>[
    (x: 0.22, y: 0.50, angle: 0.0),
    (x: 0.38, y: 0.50, angle: 0.0),
  ]),
  _Placement('tilted, across the bar', <({double x, double y, double angle})>[
    (x: 0.30, y: 0.505, angle: 0.35),
    (x: 0.68, y: 0.495, angle: -0.25),
  ]),
  _Placement('steep, far right', <({double x, double y, double angle})>[
    (x: 0.71, y: 0.50, angle: 0.5),
    (x: 0.86, y: 0.50, angle: -0.5),
  ]),
];

/// The starting position with three checkers of each colour lifted onto the
/// bar rather than conjured, so the board still holds thirty men.
List<int> get _lightenedStart {
  final points = List<int>.of(BoardState.initial().points);
  points[5] -= 3; // three White off the 6-point
  points[11] += 3; // three Black off the 12-point
  return points;
}

List<int> _facesOf(DiceReading reading) =>
    <int>[reading.first.face, reading.second.face]..sort();

BoardCalibration _calibrate(
  SyntheticShot shot, {
  double dieSide = BoardCalibration.defaultDieSide,
}) {
  final result = BoardVision.calibrate(
    frame: shot.frame,
    corners: shot.groundTruthQuad,
    orientation: BoardOrientation.whiteHomeNear,
    dieSide: dieSide,
  );
  expect(result.ok, isTrue, reason: result.message);
  return result.calibration!;
}
