import 'met.dart';
import 'scored_move.dart';

/// A match-aware cube decision produced by [MatchCubeAdvisor].
///
/// All three equities are the MOVER's match-winning probability in `[0, 1]`
/// (NOT a money equity in `[-3, 3]`). They are directly comparable and the
/// tests pin them to the by-hand values, so they are the primary output; the
/// two booleans are derived from them.
class MatchCubeAdvice {
  /// The mover's best action is to double now (offer the cube).
  final bool shouldDouble;

  /// If the mover doubles, the opponent's best response is to take.
  final bool shouldTake;

  /// Mover's match-winning probability if the cube is NOT turned (the game is
  /// played on at the current [MatchCubeAdvisor.advise] `cubeValue`).
  final double equityNoDouble;

  /// Mover's match-winning probability after a double that is TAKEN. In this
  /// dead-cube v1 model the cube is treated as dead after the take: the game
  /// is simply played on at twice the stake with no recube value.
  final double equityDoubleTake;

  /// Mover's match-winning probability after a double that is DROPPED: the
  /// mover banks the current cube value and the score moves accordingly.
  final double equityDoubleDrop;

  const MatchCubeAdvice({
    required this.shouldDouble,
    required this.shouldTake,
    required this.equityNoDouble,
    required this.equityDoubleTake,
    required this.equityDoubleDrop,
  });

  @override
  String toString() => 'MatchCubeAdvice(double $shouldDouble, take $shouldTake, '
      'nd ${equityNoDouble.toStringAsFixed(5)}, '
      'dt ${equityDoubleTake.toStringAsFixed(5)}, '
      'dd ${equityDoubleDrop.toStringAsFixed(5)})';
}

/// Turns cubeless win/gammon/backgammon probabilities into a match-aware
/// double / take decision, using the Kazaross-XG2 match equity table
/// ([MatchEquityTable]) as the value function over match scores.
///
/// ## The model (dead-cube v1)
///
/// wildbg's own `cube_info` is money-only (it takes no away scores), so the
/// tutor and the match-playing AI need this adapter to reason at a match
/// score. This is the simplest defensible match model — a "dead cube" model,
/// closely related to the constant-value end of Janowski's cube formula:
///
///  * We assume the cube is DEAD after it is turned and taken (no recube
///    value). At a match score this understates the taker's equity somewhat
///    (they lose the option value of owning the cube), so it is slightly
///    double-happy and slightly take-shy versus a full live-cube model. It is
///    exact for last-roll / no-recube situations and is a documented v1
///    stepping stone; a live-cube refinement can replace it later without
///    changing this API.
///
/// ### Value function over scores: [_matchEquityAfter]
///
/// `_matchEquityAfter(aRem, bRem)` is the mover's probability of eventually
/// winning the MATCH from the start of a game in which the mover is `aRem`
/// points from victory and the opponent `bRem`:
///
///  * `aRem <= 0` -> the mover has reached 0 away, i.e. won the match -> 1.0.
///  * `bRem <= 0` -> the opponent has won the match -> 0.0.
///  * otherwise both are >= 1 and we read the MET.
///
/// **Why pre-Crawford values for all future states (Crawford is baked in).**
/// The advisor is only asked when doubling is legal, so the CURRENT game is
/// not the Crawford game. A future score with `aRem == 1` (or `bRem == 1`)
/// marks the point where the NEXT game becomes the Crawford game. The Kazaross
/// pre-Crawford table's 1-away row/column is, by construction, the equity at
/// the START of that Crawford game — the value of the upcoming
/// cube-disabled game is already embedded in those numbers. So for ordinary
/// (pre-Crawford) play we use `preCrawford(aRem, bRem)` for every continuing
/// state and never need `postCrawford`: the post-Crawford effect lives inside
/// the pre-Crawford table values.
///
/// **Post-Crawford (`crawfordPlayed == true`).** Once the Crawford game has
/// been played, the cube is live again and the match leader sits permanently
/// at 1-away. Here the pre-Crawford table is the WRONG value function (its
/// 1-away entries describe a game where the cube is still disabled). We
/// instead use the post-Crawford column: for a continuing state exactly one
/// side is 1-away (the leader; they only ever leave 1-away by winning the
/// whole match), so
///   * opponent 1-away  -> mover trails `aRem` -> `postCrawford(aRem)`;
///   * mover   1-away    -> mover leads, opponent trails `bRem`
///                          -> `1 - postCrawford(bRem)`.
/// `postCrawford(1) == 0.5`, so the double-match-point state (1-away/1-away)
/// correctly evaluates to 0.5. This makes the well-known result "the trailer
/// should double at once, post-Crawford" fall out of the model rather than
/// being hard-coded (see the trailer test).
///
/// ### Outcome distribution
///
/// [Probabilities] are CUMULATIVE (win includes gammons+backgammons;
/// winGammon includes backgammons). We convert to the EXCLUSIVE point buckets
/// (single / gammon / backgammon = x1 / x2 / x3 the stake) and, for a stake of
/// `s` cube points, compute
///
/// ```
/// E(s) = P(win single)  * eqAfter(a - 1s, b)
///      + P(win gammon)  * eqAfter(a - 2s, b)
///      + P(win bg)      * eqAfter(a - 3s, b)
///      + P(lose single) * eqAfter(a, b - 1s)
///      + P(lose gammon) * eqAfter(a, b - 2s)
///      + P(lose bg)     * eqAfter(a, b - 3s)
/// ```
///
/// ### Decision
///
///  * `equityNoDouble = E(cubeValue)` — play on at the current stake.
///  * `equityDoubleTake = E(2 * cubeValue)` — cube turned and taken (dead).
///  * `equityDoubleDrop = eqAfter(a - cubeValue, b)` — opponent drops, mover
///    banks `cubeValue` points.
///  * After a double the OPPONENT picks the option worse for the mover, so the
///    mover's post-double equity is `min(equityDoubleTake, equityDoubleDrop)`.
///  * `shouldDouble` iff that minimum STRICTLY exceeds `equityNoDouble`. Strict
///    `>` means a double that cannot gain (ties, e.g. an already-certain win)
///    is not recommended; no epsilon is used, since in a dead-cube model any
///    genuine positive gain is a correct double.
///  * `shouldTake` (opponent's view) iff `equityDoubleTake <= equityDoubleDrop`
///    — taking yields the mover no more than dropping does, i.e. taking is at
///    least as good for the opponent. Equality is the take point; we take
///    there by convention.
///
/// We deliberately do NOT expose scalar take-point / double-point WIN
/// probabilities: with gammons on the table those thresholds are not
/// well-defined without a gammonless assumption. The three exact equities
/// above are exposed instead and the tests verify them directly.
class MatchCubeAdvisor {
  const MatchCubeAdvisor();

  /// Mover's match-winning probability from the start of a game at score
  /// (mover `aRemaining` away, opponent `bRemaining` away). See the class doc
  /// for the pre-/post-Crawford reasoning.
  double _matchEquityAfter(int aRemaining, int bRemaining, bool crawfordPlayed) {
    if (aRemaining <= 0) return 1.0; // mover reached the match
    if (bRemaining <= 0) return 0.0; // opponent reached the match
    if (crawfordPlayed) {
      // Post-Crawford: the leader is permanently 1-away, so a continuing state
      // has exactly one side at 1-away. Use the post-Crawford column.
      if (bRemaining == 1) {
        // Opponent is the 1-away leader; mover trails aRemaining away.
        return MatchEquityTable.postCrawford(aRemaining);
      }
      if (aRemaining == 1) {
        // Mover is the 1-away leader; opponent trails bRemaining away.
        return 1.0 - MatchEquityTable.postCrawford(bRemaining);
      }
      // Neither side 1-away: not a genuine post-Crawford state. Fall through
      // to the pre-Crawford table (defensive; should not occur for valid
      // input, where crawfordPlayed implies one current away == 1).
    }
    return MatchEquityTable.preCrawford(aRemaining, bRemaining);
  }

  /// Match-aware cube advice for a mover [moverAway] points from victory
  /// against an opponent [opponentAway] away, with the cube currently at
  /// [cubeValue] (a doubles it to `2 * cubeValue`).
  ///
  /// [crawfordPlayed] must be `true` exactly when the Crawford game has
  /// already been played (i.e. the current game is post-Crawford, cube live).
  /// Doubling is illegal in the Crawford game itself; the advisor does not
  /// enforce that — callers must not ask for advice during the Crawford game.
  ///
  /// Throws [ArgumentError] if [moverAway], [opponentAway] or [cubeValue] is
  /// below 1. [cubeValue] is not required to be a power of two; the caller is
  /// responsible for passing the real cube value.
  MatchCubeAdvice advise({
    required Probabilities probs,
    required int moverAway,
    required int opponentAway,
    required int cubeValue,
    bool crawfordPlayed = false,
  }) {
    if (moverAway < 1) {
      throw ArgumentError.value(moverAway, 'moverAway', 'must be >= 1');
    }
    if (opponentAway < 1) {
      throw ArgumentError.value(opponentAway, 'opponentAway', 'must be >= 1');
    }
    if (cubeValue < 1) {
      throw ArgumentError.value(cubeValue, 'cubeValue', 'must be >= 1');
    }

    // Cumulative -> exclusive outcome buckets, mover's perspective.
    final win = probs.win;
    final lose = 1.0 - win;
    final singleWin = win - probs.winGammon;
    final gammonWin = probs.winGammon - probs.winBackgammon;
    final bgWin = probs.winBackgammon;
    final singleLose = lose - probs.loseGammon;
    final gammonLose = probs.loseGammon - probs.loseBackgammon;
    final bgLose = probs.loseBackgammon;

    double equityAtStake(int stake) =>
        singleWin *
                _matchEquityAfter(
                    moverAway - stake, opponentAway, crawfordPlayed) +
            gammonWin *
                _matchEquityAfter(
                    moverAway - 2 * stake, opponentAway, crawfordPlayed) +
            bgWin *
                _matchEquityAfter(
                    moverAway - 3 * stake, opponentAway, crawfordPlayed) +
            singleLose *
                _matchEquityAfter(
                    moverAway, opponentAway - stake, crawfordPlayed) +
            gammonLose *
                _matchEquityAfter(
                    moverAway, opponentAway - 2 * stake, crawfordPlayed) +
            bgLose *
                _matchEquityAfter(
                    moverAway, opponentAway - 3 * stake, crawfordPlayed);

    final equityNoDouble = equityAtStake(cubeValue);
    final equityDoubleTake = equityAtStake(2 * cubeValue);
    final equityDoubleDrop =
        _matchEquityAfter(moverAway - cubeValue, opponentAway, crawfordPlayed);

    // After a double the opponent chooses the branch worse for the mover.
    final doubledEquity = equityDoubleTake < equityDoubleDrop
        ? equityDoubleTake
        : equityDoubleDrop;

    return MatchCubeAdvice(
      shouldDouble: doubledEquity > equityNoDouble,
      shouldTake: equityDoubleTake <= equityDoubleDrop,
      equityNoDouble: equityNoDouble,
      equityDoubleTake: equityDoubleTake,
      equityDoubleDrop: equityDoubleDrop,
    );
  }
}
