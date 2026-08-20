import 'dart:math' as math;

import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

/// The dice reader used to read a face by COUNTING dark dots, and the first
/// real footage showed what counting is worth at twenty-two pixels: a six
/// whose pip columns blur together counts three, a tilted die showing two
/// faces counts the union of both, a split dot counts twice. Every one of
/// those wrong counts sailed on toward the game state.
///
/// So a face is now READ AS A SHAPE: [PipPattern.faceOf] accepts one to six
/// pip positions only if they stand where that face's pips stand on a real
/// die — any rotation, any reflection, but the right shape at the right
/// size. These tests pin the shape test in both directions on constructed
/// geometry, where every position is exact and every tolerance deliberate.
void main() {
  /// A face's canonical pip positions, in a unit die frame.
  List<Pt> canonical(int face) {
    const c = Pt(0.5, 0.5);
    const corners = <Pt>[
      Pt(0.25, 0.25),
      Pt(0.75, 0.75),
      Pt(0.75, 0.25),
      Pt(0.25, 0.75),
    ];
    const middles = <Pt>[Pt(0.25, 0.5), Pt(0.75, 0.5)];
    switch (face) {
      case 1:
        return const <Pt>[c];
      case 2:
        return corners.sublist(0, 2);
      case 3:
        return <Pt>[...corners.sublist(0, 2), c];
      case 4:
        return corners;
      case 5:
        return <Pt>[...corners, c];
      case 6:
        return <Pt>[...corners, ...middles];
      default:
        throw ArgumentError('no face $face');
    }
  }

  List<Pt> rotated(List<Pt> pips, double angle) {
    final s = math.sin(angle), co = math.cos(angle);
    return <Pt>[
      for (final p in pips)
        Pt(
          0.5 + (p.x - 0.5) * co - (p.y - 0.5) * s,
          0.5 + (p.x - 0.5) * s + (p.y - 0.5) * co,
        ),
    ];
  }

  List<Pt> jittered(List<Pt> pips, int seed) {
    final random = math.Random(seed);
    return <Pt>[
      for (final p in pips)
        Pt(
          p.x + (random.nextDouble() - 0.5) * 0.08,
          p.y + (random.nextDouble() - 0.5) * 0.08,
        ),
    ];
  }

  test('every canonical face reads as itself, at any rotation, jittered', () {
    for (var face = 1; face <= 6; face++) {
      for (final angle in <double>[0, 0.4, math.pi / 4, 1.2, math.pi / 2]) {
        for (var seed = 1; seed <= 5; seed++) {
          final pips = jittered(rotated(canonical(face), angle), seed);
          expect(PipPattern.faceOf(pips), face,
              reason: 'face $face at $angle rad, jitter seed $seed');
        }
      }
    }
  });

  test('a six whose pip columns merged into a line of three is no face', () {
    // The first real footage's signature misread: at twenty-two pixels a
    // six's two tight columns blur pairwise into three dots one row pitch
    // apart — a LINE spaced 0.25 of the die, where a true three runs corner
    // to corner. Counting reads it as a three; the shape refuses it.
    final line = <Pt>[
      const Pt(0.5, 0.25),
      const Pt(0.5, 0.5),
      const Pt(0.5, 0.75),
    ];
    expect(PipPattern.faceOf(line), isNull);
  });

  test('two dots side by side are not a two', () {
    // A two runs corner to corner. Adjacent dots are a fragment of some
    // larger face, whatever they count as.
    expect(
      PipPattern.faceOf(const <Pt>[Pt(0.35, 0.5), Pt(0.65, 0.5)]),
      isNull,
    );
  });

  test('an ace off its die\'s middle is no ace', () {
    // A tilted die showing two faces reads as one blob with the top face's
    // single pip well off the union's middle — the real footage paired two
    // of those into a 1-1. A true ace sits in the middle of its die.
    expect(PipPattern.faceOf(const <Pt>[Pt(0.5, 0.22)]), isNull);
    expect(PipPattern.faceOf(const <Pt>[Pt(0.75, 0.75)]), isNull);
  });

  test('a quad with split extras is not a six', () {
    // Noise splits a dot in two and a four counts six. The six dots of a
    // real six stand in two even columns; a quad plus two splinters does
    // not.
    final quadPlus = <Pt>[
      ...canonical(4),
      const Pt(0.28, 0.31),
      const Pt(0.72, 0.69),
    ];
    expect(PipPattern.faceOf(quadPlus), isNull);
  });

  test('the union of two faces\' pips is no face at all', () {
    // The two-face blob of a tilted die carries the top face's pips AND a
    // strip of the neighbouring face's. Even when the count lands on a
    // legal number, the shape is the giveaway.
    final union = <Pt>[
      // A three, squeezed into the upper half of a tall union blob...
      const Pt(0.3, 0.15),
      const Pt(0.5, 0.25),
      const Pt(0.7, 0.35),
      // ...with one stray pip of the neighbouring face below.
      const Pt(0.45, 0.8),
    ];
    expect(PipPattern.faceOf(union), isNull);
  });

  test('nothing, or too much, is no face', () {
    expect(PipPattern.faceOf(const <Pt>[]), isNull);
    expect(
      PipPattern.faceOf(<Pt>[
        ...canonical(6),
        const Pt(0.5, 0.9),
      ]),
      isNull,
    );
  });
}
