import 'package:backgammon_core/backgammon_core.dart';

/// Maps entered hops back onto the dice they consumed, so the board can DIM the
/// dice that have already been played out during move entry (the "when I play a
/// die, make it look dimmer/disabled" feedback).
///
/// The core's [MoveBuilder] tracks hops, not dice — it is constructed from the
/// legal-move list and never sees the roll. The mapping is therefore rebuilt
/// here from the hop geometry, which is unambiguous: a hop's pip distance IS the
/// die it consumed, except for a bear-off OVERSHOOT (a checker borne off with a
/// die larger than its exact distance, legal only when no checker sits further
/// back), which consumes the smallest remaining die that covers the distance.

/// The pip distance of [hop] for [player] — the die value it consumed, except
/// for a bear-off overshoot where the die may be larger (see [usedDiceSlots]).
///
/// White moves toward index 0 and bears off past it; Black moves toward index 23
/// and bears off past it. [CheckerMove.bar] enters 25 pips from the mover's own
/// bear-off edge, so a White bar entry to index 23 is a 1 and a Black bar entry
/// to index 0 is a 1.
int pipDistance(CheckerMove hop, Player player) {
  final white = player == Player.white;
  // Normalise the bar to the virtual point one step beyond the far edge.
  final from = hop.from == CheckerMove.bar ? (white ? 24 : -1) : hop.from;
  if (hop.to == CheckerMove.off) return white ? from + 1 : 24 - from;
  return white ? from - hop.to : hop.to - from;
}

/// Which SLOTS of the mover's painted dice pair the [hops] have consumed, where
/// slot 0 is `dice.die1` and slot 1 is `dice.die2`.
///
/// Non-doubles: each hop consumes one slot, matched by exact pip distance first
/// and, failing that (a bear-off overshoot), by the smallest remaining die that
/// covers the distance. The two dice therefore dim INDEPENDENTLY — play the 5 of
/// a 5-2 and only the 5 goes dim.
///
/// Doubles: four hops are available but only two dice are painted, so the pair
/// dims PROGRESSIVELY — the first die after two hops, the second after all four.
/// A single hop leaves both bright (half a die is not a played die).
Set<int> usedDiceSlots(List<CheckerMove> hops, Dice dice, Player player) {
  if (hops.isEmpty) return const {};
  if (dice.isDouble) {
    return {
      if (hops.length >= 2) 0,
      if (hops.length >= 4) 1,
    };
  }
  final values = [dice.die1, dice.die2];
  final used = <int>{};
  for (final hop in hops) {
    final distance = pipDistance(hop, player);
    var pick = -1;
    // Exact match wins.
    for (var i = 0; i < values.length; i++) {
      if (!used.contains(i) && values[i] == distance) {
        pick = i;
        break;
      }
    }
    // Bear-off overshoot: the smallest remaining die that covers the distance.
    if (pick < 0) {
      for (var i = 0; i < values.length; i++) {
        if (used.contains(i)) continue;
        if (values[i] < distance) continue;
        if (pick < 0 || values[i] < values[pick]) pick = i;
      }
    }
    // Defensive: an unrecognisable hop still burns a die rather than none.
    if (pick < 0) {
      for (var i = 0; i < values.length; i++) {
        if (!used.contains(i)) {
          pick = i;
          break;
        }
      }
    }
    if (pick < 0) break; // more hops than dice: nothing left to mark
    used.add(pick);
  }
  return used;
}

/// The destination for [source] that consumes the HIGHEST die among the hops the
/// builder currently offers, or `null` when [source] offers none.
///
/// This is what a DOUBLE-TAP plays: the bigger die first is the conventional
/// default (it keeps the smaller, more flexible die in hand), and it matches
/// what a player reaching for "just move this checker" expects.
int? highestDieDestination(MoveBuilder builder, int source, Player player) {
  int? best;
  var bestDistance = -1;
  for (final destination in builder.destinationsFor(source)) {
    final distance = pipDistance(CheckerMove(source, destination), player);
    if (distance > bestDistance) {
      bestDistance = distance;
      best = destination;
    }
  }
  return best;
}
