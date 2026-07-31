/// The bear-off legality rule, in one place.
///
/// It used to live twice: once in the generator's search position (`_Pos`,
/// which is normalized — the mover is positive and travels toward index 0) and
/// once in [MoveBuilder]'s playability filter (which reasons about a live
/// [BoardState] for either colour). Two copies of a rule drift, and this is
/// the rule users already find hardest to trust, so both now call [canBearOff].
///
/// Everything is expressed in the generator's NORMALIZED frame; the builder
/// converts before asking (a Black point `i` is normalized index `23 - i`).
library;

/// Whether a checker standing on the normalized point [from] (0-23, where 0 is
/// the mover's ace point) may be borne off with [die].
///
/// * [allHome] — nothing of the mover's on the bar and no checker outside the
///   home board (normalized indices 0-5). Bearing off needs the whole army in.
/// * [highestPoint] — the normalized index of the mover's FURTHEST-BACK
///   checker, or -1 when none is on the board.
///
/// A die that matches the distance exactly lifts a checker from any point; a
/// die LARGER than the distance (an overshoot) may only lift the furthest-back
/// checker, which is why [highestPoint] has to be recomputed mid-turn rather
/// than once per position.
bool canBearOff({
  required bool allHome,
  required int from,
  required int die,
  required int highestPoint,
}) {
  if (!allHome) return false;
  final distance = from + 1;
  if (die == distance) return true;
  return die > distance && from == highestPoint;
}
