import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';

/// The host's source of dice. Injectable so tests can script a whole match.
///
/// Mirrors the app's local `DiceRoller` surface (roll / rollOpening) so the two
/// can be swapped in the controllers.
abstract interface class DiceRoller {
  /// A turn roll; doubles allowed.
  Dice roll();

  /// An opening roll: never a double (ties are re-rolled, not recorded).
  Dice rollOpening();
}

/// The production roller: cryptographically-secure by default.
class RandomDiceRoller implements DiceRoller {
  RandomDiceRoller([Random? rng]) : _rng = rng ?? Random.secure();

  final Random _rng;

  @override
  Dice roll() => Dice(_rng.nextInt(6) + 1, _rng.nextInt(6) + 1);

  @override
  Dice rollOpening() {
    var d = roll();
    while (d.isDouble) {
      d = roll();
    }
    return d;
  }
}

/// A roller that replays a fixed script, then falls back to [fallback] (a
/// seeded [RandomDiceRoller] by default) once the script is exhausted — so a
/// test can pin the interesting rolls without scripting a whole match.
class ScriptedDiceRoller implements DiceRoller {
  ScriptedDiceRoller(List<Dice> script, {DiceRoller? fallback})
      : _script = List.of(script),
        _fallback = fallback ?? RandomDiceRoller(Random(20260726));

  final List<Dice> _script;
  final DiceRoller _fallback;

  /// How many scripted rolls are left.
  int get remaining => _script.length;

  @override
  Dice roll() => _script.isEmpty ? _fallback.roll() : _script.removeAt(0);

  @override
  Dice rollOpening() {
    while (_script.isNotEmpty) {
      final d = _script.removeAt(0);
      if (!d.isDouble) return d;
      // A scripted double cannot be an opening roll; skip it rather than
      // silently producing an illegal opening.
    }
    return _fallback.rollOpening();
  }
}
