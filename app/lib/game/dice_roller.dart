import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';

/// Cryptographically-secure dice for local play (design spec §4).
class DiceRoller {
  DiceRoller([Random? rng]) : _rng = rng ?? Random.secure();
  final Random _rng;

  Dice roll() => Dice(_rng.nextInt(6) + 1, _rng.nextInt(6) + 1);

  /// Opening roll: one die per player, ties re-rolled — never a double.
  Dice rollOpening() {
    var d = roll();
    while (d.isDouble) {
      d = roll();
    }
    return d;
  }
}
