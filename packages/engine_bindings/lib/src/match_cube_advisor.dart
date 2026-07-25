import 'met.dart';
import 'scored_move.dart';

/// Mover's probability of eventually winning the MATCH from the start of a game
/// in which the mover is [aRemaining] points from victory and the opponent
/// [bRemaining]. This is the model's value function over match scores, shared by
/// [MatchCubeAdvisor] and the match-aware AI resign policy.
///
///  * `aRemaining <= 0` -> the mover has reached 0 away, i.e. won the match -> 1.0.
///  * `bRemaining <= 0` -> the opponent has won the match -> 0.0.
///  * otherwise both are >= 1 and we read the [MatchEquityTable].
///
/// See [MatchCubeAdvisor] for the pre-/post-Crawford reasoning ([crawfordPlayed]
/// selects the post-Crawford column when the leader sits permanently 1-away).
double matchEquityAfter(int aRemaining, int bRemaining,
    {required bool crawfordPlayed}) {
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

/// Mover's match-winning probability of playing a game on to completion at the
/// given per-game [stake] (in cube points), folding [probs] over the six
/// exclusive outcome buckets with [matchEquityAfter] as the value function.
///
/// [probs] are CUMULATIVE (win includes gammons+backgammons; winGammon includes
/// backgammons); this converts them to the exclusive single / gammon /
/// backgammon buckets and computes, from the mover's perspective at score
/// (mover [moverAway] away, opponent [opponentAway] away):
///
/// ```
/// E(stake) = P(win single)  * eqAfter(a - 1*stake, b)
///          + P(win gammon)  * eqAfter(a - 2*stake, b)
///          + P(win bg)      * eqAfter(a - 3*stake, b)
///          + P(lose single) * eqAfter(a, b - 1*stake)
///          + P(lose gammon) * eqAfter(a, b - 2*stake)
///          + P(lose bg)     * eqAfter(a, b - 3*stake)
/// ```
///
/// Shared by [MatchCubeAdvisor.advise] (its `E(s)` over the cube stakes) and the
/// AI resign policy (which compares E(cube) against the equity of accepting).
double matchEquityOfDistribution(
  Probabilities probs, {
  required int moverAway,
  required int opponentAway,
  required int stake,
  required bool crawfordPlayed,
}) {
  // Cumulative -> exclusive outcome buckets, mover's perspective.
  final win = probs.win;
  final lose = 1.0 - win;
  final singleWin = win - probs.winGammon;
  final gammonWin = probs.winGammon - probs.winBackgammon;
  final bgWin = probs.winBackgammon;
  final singleLose = lose - probs.loseGammon;
  final gammonLose = probs.loseGammon - probs.loseBackgammon;
  final bgLose = probs.loseBackgammon;

  double eqAfter(int a, int b) =>
      matchEquityAfter(a, b, crawfordPlayed: crawfordPlayed);

  return singleWin * eqAfter(moverAway - stake, opponentAway) +
      gammonWin * eqAfter(moverAway - 2 * stake, opponentAway) +
      bgWin * eqAfter(moverAway - 3 * stake, opponentAway) +
      singleLose * eqAfter(moverAway, opponentAway - stake) +
      gammonLose * eqAfter(moverAway, opponentAway - 2 * stake) +
      bgLose * eqAfter(moverAway, opponentAway - 3 * stake);
}

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

  /// Mover's match-winning probability after a double that is TAKEN.
  ///
  /// This is a cube-life interpolation (see [MatchCubeAdvisor], `cubeLife`):
  /// at `cubeLife == 0` it is the dead-cube value (the game played on at twice
  /// the stake with no recube value, i.e. the old v1 number); as `cubeLife`
  /// rises it is lowered toward the live-cube value that credits the TAKER with
  /// their recube (redouble-to-4s) potential. Lower = better for the taker.
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
/// ## The model (Janowski cube-life v1.5)
///
/// wildbg's own `cube_info` is money-only (it takes no away scores), so the
/// tutor and the match-playing AI need this adapter to reason at a match
/// score. This advisor generalises the earlier dead-cube v1 model with a
/// Janowski **cube-life** parameter `x = cubeLife` in `[0, 1]`, following the
/// same cube-efficiency idea as wildbg's money `CubeInfo`
/// (`native/wildbg/crates/logic/src/cube.rs`) and Janowski's cube formulae
/// (<https://bkgm.com/articles/Janowski/cubeformulae.pdf>):
///
///  * `x = 0` — a DEAD cube: the cube is worthless after it is turned and
///    taken. This reproduces the old v1 arithmetic BYTE-FOR-BYTE (it is the
///    regression anchor; every `x = 0` test below keeps its hand-computed
///    numbers). It is exact for last-roll / no-recube situations.
///  * `x = 1` — a fully LIVE cube: the taker gets full credit for owning a
///    recube after the take. In the money / long-match limit this shifts the
///    gammonless take point from 25% (dead) to 20% (live), exactly as in
///    Janowski's continuous model.
///  * `0 < x < 1` — a linear blend of the two, `x = 0.7` by default (near
///    Janowski's recommended 2/3 for money; a settings hook can override it).
///
/// ### What cube life changes, and what it does NOT (documented scope)
///
/// We model cube life on ONE branch only: the **doubled-and-taken** equity,
/// where the taker owns a live recube. This is the dominant, well-understood
/// cube-life effect (the 25% -> 20% take-point shift) and the one the AI/tutor
/// take/pass decision hinges on. We deliberately do NOT add cube life to:
///
///  * `equityNoDouble` — Janowski's centered-cube formula also inflates the
///    holder's no-double equity by `4 / (4 - x)` (the value of owning the
///    doubling rights). We omit that second-order term in v1.5; it would raise
///    the doubling bar further, and folding it in symmetrically is future work.
///    Consequence: as `x` rises we are slightly biased toward "double later"
///    (the live take is more generous, so a double gains the mover less), which
///    is the correct DIRECTION even without the no-double term.
///  * `equityDoubleDrop` — a terminal bank (mover cashes `cubeValue` points);
///    no cube exists after a drop, so it is genuinely `x`-independent.
///
/// This is an honest pragmatic approximation (v1.5): faithful to Janowski at
/// the endpoints and in the money limit, monotone in `x` for the take decision
/// (proved below), and cheap. A fully-live match model (recursive recube
/// valuation on both sides) can replace it later without changing this API.
///
/// ### The taker's recube credit (the live correction)
///
/// After the mover doubles to `2s` (s = `cubeValue`) and the taker takes, the
/// taker OWNS a cube worth `2s` and may redouble to `4s`. Porting wildbg's
/// money identity
///
/// ```
/// equity_double_take(x) = 2 * E_cubeless - x * q          // cube.rs, gammonless-general
///                       = E(2s)_dead   - x * q            // 2*E_cubeless == our dead E(2s)
/// ```
///
/// (where `q = P(mover loses)`; derived from `equity_opponent_owns =
/// E_cubeless - 0.5 * x * q`, doubled) into MATCH-equity space, we keep the
/// dead value `E(2s)` and subtract a live correction sized by the recube's
/// leverage measured through the MET:
///
/// ```
/// recubeSwing = eqAfter(a, b - 2s) - eqAfter(a, b - 4s)   // >= 0 always
/// E_live_take = E(2s) - 0.5 * q * recubeSwing
/// equityDoubleTake(x) = (1 - x) * E(2s) + x * E_live_take
///                     = E(2s) - x * 0.5 * q * recubeSwing
/// ```
///
///  * `eqAfter(a, b - 2s)` is the mover's match equity when the TAKER wins the
///    doubled game (banks `2s`); `eqAfter(a, b - 4s)` when the taker instead
///    redoubles to `4s` and wins (banks `4s`). Their difference is the extra
///    the mover loses if the cube turns again on the taker's win — i.e. the
///    per-game value of the taker's recube leverage, measured in MET points.
///  * The `0.5` is Janowski's efficient-cube coefficient (half a cube-jump of
///    realized leverage). Multiplying by `q` (the taker's cubeless win
///    probability) matches the money identity `- x * q` term exactly: with a
///    flat (long-match, locally linear) MET, `recubeSwing` -> two stake points
///    of slope and `0.5 * 2 = 1`, so `E_live_take -> 2*E_cubeless - q`,
///    reproducing cube.rs. This is why `x = 0` is the dead model and the money
///    limit is Janowski's.
///  * `recubeSwing >= 0` because `eqAfter` is non-decreasing in the opponent's
///    away score (opponent further away is better for the mover) and
///    `b - 4s <= b - 2s`. Hence `E_live_take <= E(2s)`: cube ownership never
///    HURTS the taker. This gives the monotonicity we need (see Decision).
///  * When the taker already wins the MATCH by banking `2s` (`b - 2s <= 0`,
///    e.g. 2-away/2-away with s = 1), both `eqAfter` terms are 0, so
///    `recubeSwing == 0` and the live and dead values COINCIDE: the recube is
///    worthless because the `2s` game already decides the match. The advisor is
///    then fully `x`-independent there (asserted by a test).
///
/// ### Value function over scores: [matchEquityAfter]
///
/// `matchEquityAfter(aRem, bRem)` is the mover's probability of eventually
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
///  * `equityNoDouble = E(cubeValue)` — play on at the current stake
///    (`x`-independent; see scope note above).
///  * `equityDoubleTake = E(2*cubeValue) - x*0.5*q*recubeSwing` — cube turned
///    and taken, with the taker's cube-life recube credit (see above). At
///    `x = 0` this is the dead `E(2*cubeValue)`.
///  * `equityDoubleDrop = eqAfter(a - cubeValue, b)` — opponent drops, mover
///    banks `cubeValue` points (`x`-independent).
///  * After a double the OPPONENT picks the option worse for the mover, so the
///    mover's post-double equity is `min(equityDoubleTake, equityDoubleDrop)`.
///  * `shouldDouble` iff that minimum STRICTLY exceeds `equityNoDouble`. Strict
///    `>` means a double that cannot gain (ties, e.g. an already-certain win)
///    is not recommended; no epsilon is used.
///  * `shouldTake` (opponent's view) iff `equityDoubleTake <= equityDoubleDrop`
///    — taking yields the mover no more than dropping does, i.e. taking is at
///    least as good for the opponent. Equality is the take point; we take
///    there by convention.
///
/// **Monotonicity of the take point in `x` (why cube life only widens takes).**
/// `equityDoubleTake` is non-increasing in `x` (the correction `x*0.5*q*
/// recubeSwing` is `>= 0` and grows with `x`), while `equityDoubleDrop` is
/// `x`-independent. So raising `x` can only turn a drop into a take, never the
/// reverse: the take threshold — the highest mover win probability at which the
/// taker still takes — is NON-DECREASING in `x`, moving from the dead take
/// point toward the (more generous) live one. A grid test pins this.
///
/// We deliberately do NOT expose scalar take-point / double-point WIN
/// probabilities: with gammons on the table those thresholds are not
/// well-defined without a gammonless assumption. The three exact equities
/// above are exposed instead and the tests verify them directly.
class MatchCubeAdvisor {
  const MatchCubeAdvisor();

  /// Match-aware cube advice for a mover [moverAway] points from victory
  /// against an opponent [opponentAway] away, with the cube currently at
  /// [cubeValue] (a doubles it to `2 * cubeValue`).
  ///
  /// [crawfordPlayed] must be `true` exactly when the Crawford game has
  /// already been played (i.e. the current game is post-Crawford, cube live).
  /// Doubling is illegal in the Crawford game itself; the advisor does not
  /// enforce that — callers must not ask for advice during the Crawford game.
  ///
  /// [cubeLife] is Janowski's cube-efficiency `x` in `[0, 1]`: `0` is a dead
  /// cube (the regression-anchor v1 arithmetic), `1` a fully live cube, `0.7`
  /// the default. See the class doc for the model.
  ///
  /// Throws [ArgumentError] if [moverAway], [opponentAway] or [cubeValue] is
  /// below 1, or if [cubeLife] is outside `[0, 1]`. [cubeValue] is not required
  /// to be a power of two; the caller is responsible for passing the real cube
  /// value.
  MatchCubeAdvice advise({
    required Probabilities probs,
    required int moverAway,
    required int opponentAway,
    required int cubeValue,
    bool crawfordPlayed = false,
    double cubeLife = 0.7,
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
    if (cubeLife < 0 || cubeLife > 1 || cubeLife.isNaN) {
      throw ArgumentError.value(cubeLife, 'cubeLife', 'must be in [0, 1]');
    }

    final win = probs.win;

    double equityAtStake(int stake) => matchEquityOfDistribution(
          probs,
          moverAway: moverAway,
          opponentAway: opponentAway,
          stake: stake,
          crawfordPlayed: crawfordPlayed,
        );

    final equityNoDouble = equityAtStake(cubeValue);

    // Dead doubled-take equity: play on at twice the stake, cube dead. This is
    // the regression-anchor value (v1), and Janowski's `2 * E_cubeless`.
    final deadDoubleTake = equityAtStake(2 * cubeValue);

    // Cube-life recube credit for the TAKER (see the class doc). The taker owns
    // a cube worth 2*cubeValue and may redouble to 4*cubeValue. The leverage is
    // the MET swing between the taker winning at 2s (banks 2s) and at 4s (banks
    // 4s); `q` is the taker's cubeless win probability. Both terms use the
    // loss-side score transition, so `recubeSwing >= 0` and the correction only
    // lowers the mover's equity (never below the dead value).
    final q = 1.0 - win; // P(mover loses) == taker's cubeless win probability
    final recubeWinAt2 = matchEquityAfter(
        moverAway, opponentAway - 2 * cubeValue,
        crawfordPlayed: crawfordPlayed);
    final recubeWinAt4 = matchEquityAfter(
        moverAway, opponentAway - 4 * cubeValue,
        crawfordPlayed: crawfordPlayed);
    final recubeSwing = recubeWinAt2 - recubeWinAt4; // >= 0
    // liveDoubleTake = deadDoubleTake - 0.5 * q * recubeSwing; blended by x:
    //   equityDoubleTake = (1 - x)*dead + x*live = dead - x*0.5*q*recubeSwing.
    final equityDoubleTake =
        deadDoubleTake - cubeLife * 0.5 * q * recubeSwing;

    final equityDoubleDrop = matchEquityAfter(moverAway - cubeValue, opponentAway,
        crawfordPlayed: crawfordPlayed);

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
