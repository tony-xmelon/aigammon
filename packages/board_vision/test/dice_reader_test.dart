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

  group('what the corpus found', () {
    test('a die overlapping the bar can pick up a pip that is not there', () {
      // The bar is wood where the rest of the band is felt, and a die lying
      // across that seam has a hard dark edge under one side of it. The blur
      // any real optics apply spreads that edge INTO the die, far enough to
      // survive [DiceReader.pipErosion], and it is then counted as a pip: a
      // three reads as a four. Nothing about the reading looks doubtful — the
      // blob is square, its contrast is good, its size agrees with its
      // partner's — so the wrong roll is offered with full confidence.
      //
      // On the synthetic bed it costs one of the three palettes a reading at
      // the corpus's own sharpness and more of them as blur rises. Two things
      // follow, and both are done: the corpus generator keeps dice off the
      // bar, and the capture checklist tells a person to throw onto the felt.
      // A real player does that anyway, which is why this is a note for Task 9
      // rather than a hole in the MVP — but it is the kind of failure the
      // readability light cannot see, so it is written down.
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
      // Lying across the bar's right-hand edge: a phantom pip.
      expect(facesAt(0.54), <int>[4, 4],
          reason: 'the seam under the die is being read as one of its pips');
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

BoardCalibration _calibrate(SyntheticShot shot) {
  final result = BoardVision.calibrate(
    frame: shot.frame,
    corners: shot.groundTruthQuad,
    orientation: BoardOrientation.whiteHomeNear,
  );
  expect(result.ok, isTrue, reason: result.message);
  return result.calibration!;
}
