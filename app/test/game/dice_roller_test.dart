import 'dart:math';

import 'package:aigammon_app/game/dice_roller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiceRoller.roll', () {
    test('produces dice in 1..6', () {
      final roller = DiceRoller(Random(1));
      for (var i = 0; i < 200; i++) {
        final d = roller.roll();
        expect(d.die1, inInclusiveRange(1, 6));
        expect(d.die2, inInclusiveRange(1, 6));
      }
    });

    test('is deterministic for a given seed', () {
      final a = DiceRoller(Random(1));
      final b = DiceRoller(Random(1));
      final seqA = [for (var i = 0; i < 50; i++) a.roll()];
      final seqB = [for (var i = 0; i < 50; i++) b.roll()];
      expect(seqA, seqB);
    });

    test('defaults to a secure RNG when none supplied', () {
      final roller = DiceRoller();
      final d = roller.roll();
      expect(d.die1, inInclusiveRange(1, 6));
      expect(d.die2, inInclusiveRange(1, 6));
    });
  });

  group('DiceRoller.rollOpening', () {
    test('never returns a double across many seeds', () {
      for (var seed = 0; seed < 100; seed++) {
        final roller = DiceRoller(Random(seed));
        final d = roller.rollOpening();
        expect(d.isDouble, isFalse, reason: 'seed $seed produced a double');
        expect(d.die1, inInclusiveRange(1, 6));
        expect(d.die2, inInclusiveRange(1, 6));
      }
    });

    test('re-rolls past a seed whose first roll is a double', () {
      // Find a seed whose bare roll() is a double, then confirm rollOpening
      // skips past it rather than returning that double.
      int? doubleSeed;
      for (var seed = 0; seed < 500; seed++) {
        if (DiceRoller(Random(seed)).roll().isDouble) {
          doubleSeed = seed;
          break;
        }
      }
      expect(doubleSeed, isNotNull,
          reason: 'expected at least one seed with a leading double');
      final opening = DiceRoller(Random(doubleSeed!)).rollOpening();
      expect(opening.isDouble, isFalse);
    });
  });
}
