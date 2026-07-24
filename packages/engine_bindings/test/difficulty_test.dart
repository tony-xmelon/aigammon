import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

ScoredMove scored(int fromIdx, double equity) => ScoredMove(
      move: Move([CheckerMove(fromIdx, fromIdx - 1)]),
      probabilities: Probabilities(
        win: (equity + 1) / 2,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      ),
    );

void main() {
  final ranked = [
    scored(23, 0.20),
    scored(22, 0.15),
    scored(21, 0.00),
    scored(20, -0.40),
  ];

  test('expert always plays the best move', () {
    final rng = Random(1);
    for (var i = 0; i < 50; i++) {
      expect(pickMove(ranked, Difficulty.expert, rng), same(ranked.first));
    }
  });

  test('lower difficulties never pick outside their equity window', () {
    final rng = Random(2);
    for (var i = 0; i < 200; i++) {
      final hard = pickMove(ranked, Difficulty.hard, rng);
      expect(ranked.first.equity - hard.equity,
          lessThanOrEqualTo(Difficulty.hard.equityWindow));
      final easy = pickMove(ranked, Difficulty.easy, rng);
      expect(ranked.first.equity - easy.equity,
          lessThanOrEqualTo(Difficulty.easy.equityWindow));
    }
  });

  test('easy actually varies its play (samples more than one move)', () {
    final rng = Random(3);
    final picks = <int>{};
    for (var i = 0; i < 300; i++) {
      picks.add(ranked.indexOf(pickMove(ranked, Difficulty.easy, rng)));
    }
    expect(picks.length, greaterThan(1));
  });

  test('single candidate is always returned', () {
    final rng = Random(4);
    final only = [scored(5, -1.0)];
    expect(pickMove(only, Difficulty.easy, rng), same(only.first));
  });

  test('empty list throws', () {
    expect(() => pickMove(const [], Difficulty.expert, Random(5)),
        throwsArgumentError);
  });
}
