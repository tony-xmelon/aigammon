import 'bear_off.dart';
import 'board_state.dart';
import 'dice.dart';
import 'move.dart';
import 'player.dart';

/// A search position packed into five small ints — the key the search dedupes
/// resulting positions by, and the one it memoizes expanded doubles nodes by.
///
/// A record, so structural `==` and `hashCode` come for free and hashing costs
/// five int mixes. It replaced a `'${points.join(",")}|…'` string, which
/// allocated 24 substrings plus a join buffer EVERY time a node was keyed —
/// once per leaf and once per memo probe.
///
/// The encoding is a bijection over the reachable range, so distinct positions
/// cannot collide: a point holds -15..15 checkers (15 per side is the whole
/// army), which fits the 5 bits of `value + 15` (0..30), and six points fit one
/// 30-bit int — under the 2^31 that stays exact on every Dart backend,
/// including the web's doubles. The four point words carry indices 0-5, 6-11,
/// 12-17 and 18-23; the fifth carries bar, opponent bar and off (0..15 each).
typedef _Sig = (int, int, int, int, int);

/// One leaf of the search: the hop sequence reaching it (relative to the node
/// it was expanded from) and the packed position it lands on.
typedef _Leaf = ({List<CheckerMove> hops, _Sig sig});

/// Mutable position used only inside the search. Always normalized: the
/// moving player is positive and moves toward index 0.
class _Pos {
  final List<int> points;
  int bar; // moving player's checkers on the bar
  int oppBar;
  int off;

  _Pos(this.points, this.bar, this.oppBar, this.off);

  factory _Pos.of(BoardState b) =>
      _Pos(List.of(b.points), b.whiteBar, b.blackBar, b.whiteOff);

  _Pos clone() => _Pos(List.of(points), bar, oppBar, off);

  /// This position's packed key — see [_Sig].
  _Sig signature() => (
        _word(0),
        _word(6),
        _word(12),
        _word(18),
        bar | (oppBar << 5) | (off << 10),
      );

  /// Six points from [start], five bits each (`checkers + 15`, so an empty
  /// point is 15 and the sign survives).
  int _word(int start) {
    var word = 0;
    for (var i = start + 5; i >= start; i--) {
      word = (word << 5) | (points[i] + 15);
    }
    return word;
  }

  bool get allHome {
    if (bar > 0) return false;
    for (var i = 6; i < 24; i++) {
      if (points[i] > 0) return false;
    }
    return true;
  }

  int get highestPoint {
    for (var i = 23; i >= 0; i--) {
      if (points[i] > 0) return i;
    }
    return -1;
  }

  /// Attempts to move one checker with [die] from [from] (0-23 or
  /// [CheckerMove.bar]), mutating this position. Returns null if illegal.
  CheckerMove? tryMove(int from, int die) {
    if (bar > 0 && from != CheckerMove.bar) return null;
    if (from == CheckerMove.bar) {
      if (bar == 0) return null;
      final to = 24 - die;
      if (points[to] < -1) return null;
      final hit = points[to] == -1;
      if (hit) {
        points[to] = 0;
        oppBar++;
      }
      points[to]++;
      bar--;
      return CheckerMove(CheckerMove.bar, to, isHit: hit);
    }
    if (points[from] <= 0) return null;
    final to = from - die;
    if (to < 0) {
      // The rule itself lives in bear_off.dart — MoveBuilder asks the same
      // question of a live board and must get the same answer.
      if (!canBearOff(
        allHome: allHome,
        from: from,
        die: die,
        highestPoint: highestPoint,
      )) {
        return null;
      }
      points[from]--;
      off++;
      return CheckerMove(from, CheckerMove.off);
    }
    if (points[to] < -1) return null;
    final hit = points[to] == -1;
    if (hit) {
      points[to] = 0;
      oppBar++;
    }
    points[to]++;
    points[from]--;
    return CheckerMove(from, to, isHit: hit);
  }
}

/// Every distinct way to ENTER one legal resulting position.
///
/// The generator dedupes by resulting position: two hop sequences that leave the
/// board identical are one legal move, and [MoveVariants.canonical] is the
/// representative `legalMoves` lists. But a human entering the move hop by hop
/// may well reach for one of the OTHER sequences — most commonly running a
/// single checker through a different transit point (13/12 12/8 vs. 13/9 9/8 on
/// a 4-1, or 6/5 5/off vs. 6/1 1/off bearing off). Discarding those made the
/// just-moved checker unplayable with the second die, so they are kept here and
/// fed to `MoveBuilder`, which accepts any of them and commits [canonical].
///
/// [decompositions] holds one entry per distinct hop MULTISET (order-insensitive)
/// and always contains [canonical]; the builder handles reordering itself.
class MoveVariants {
  MoveVariants(this.canonical, this.decompositions);

  /// The move `legalMoves` lists for this resulting position.
  final Move canonical;

  /// Distinct hop multisets that all reach [canonical]'s position, each playable
  /// in the order given. Includes [canonical].
  final List<Move> decompositions;

  @override
  String toString() => '$canonical (${decompositions.length} way(s))';
}

/// Accumulates the decompositions of one resulting position during the search.
///
/// Only [legalVariants] asks for the extra sequences; [legalMoves] leaves
/// [collect] false so its search costs exactly what it always did (it is on the
/// AI's path) and only the first-seen representative is kept.
class _Variants {
  _Variants(this.canonical, {required this.collect}) {
    if (collect) add(canonical);
  }

  final Move canonical;
  final bool collect;
  final Map<int, Move> _byHops = {};

  /// Records [m] unless a permutation of its hops is already known. Keyed by
  /// [Move.hopSetKey], which is order-insensitive by construction. The search
  /// only ever produces on-board hops, so the key is never null here.
  void add(Move m) {
    if (!collect) return;
    _byHops.putIfAbsent(m.hopSetKey!, () => m);
  }

  List<Move> get decompositions =>
      collect ? _byHops.values.toList() : [canonical];
}

class MoveGenerator {
  /// All distinct legal full-turn moves for [player] with [dice], in real
  /// (White-perspective) coordinates. Implements: play the maximum number
  /// of dice possible; doubles allow four moves. Returns an empty list on a
  /// dance. The higher-die rule is applied by the search below.
  ///
  /// One move per distinct RESULTING POSITION — see [legalVariants] when the
  /// several ways of entering the same position matter (hop-by-hop move entry).
  static List<Move> legalMoves(BoardState board, Player player, Dice dice) => [
        for (final v in _search(board, player, dice, collect: false))
          _flip(v.canonical, player),
      ];

  /// [legalMoves], but each entry carries EVERY distinct hop multiset that
  /// reaches its resulting position (see [MoveVariants]). The canonical moves and
  /// their order are exactly [legalMoves]'.
  static List<MoveVariants> legalVariants(
          BoardState board, Player player, Dice dice) =>
      [
        for (final v in _search(board, player, dice, collect: true))
          MoveVariants(
            _flip(v.canonical, player),
            [for (final d in v.decompositions) _flip(d, player)],
          ),
      ];

  /// The maximal-play search, in NORMALIZED coordinates (mover positive, moving
  /// toward 0), after the higher-die tiebreak. One [_Variants] per resulting
  /// position, in first-seen order; [collect] keeps the alternative
  /// decompositions of each position as well.
  static List<_Variants> _search(BoardState board, Player player, Dice dice,
      {required bool collect}) {
    final normalized = player == Player.white ? board : board.mirrored();
    // Both dice orders are searched. When two orders reach the same
    // resulting position (e.g. 24/23 23/20 vs 24/21 21/20 with a 3-1), the
    // first-searched order supplies the deduped representative, so die2 is
    // placed first to make the second die the primary hop. This is purely a
    // representative choice; the set of resulting positions is unaffected.
    final orders = dice.isDouble
        ? [List<int>.filled(4, dice.die1)]
        : [
            [dice.die2, dice.die1],
            [dice.die1, dice.die2],
          ];

    var maxLen = 0;
    final byResult = <_Sig, _Variants>{};

    // DOUBLES MEMO, keyed by (dice remaining, position). All four dice are
    // equal, so what a node can still reach depends on nothing but how many
    // are left and where the checkers stand — and permutations of the same
    // source multiset reach the same node by many routes, each of which used
    // to re-expand the whole subtree below it. `i` counts dice SPENT, and the
    // order has fixed length, so it names the dice remaining exactly.
    //
    // Non-doubles are not memoized: two dice values in two orders make the
    // key's "dice remaining" a multiset rather than a count, and a search two
    // plies deep has nothing worth caching anyway.
    final memoize = dice.isDouble;
    final memo = <(int, _Sig), List<_Leaf>>{};

    /// Every leaf reachable from [pos] with the dice from [i] on, in DFS order
    /// — the same order the recording walk below consumes them in, so the
    /// first-seen representative of each resulting position is unchanged by
    /// the memo (a memo hit replays exactly the leaf sequence a fresh
    /// expansion would have produced).
    List<_Leaf> expand(_Pos pos, List<int> order, int i) {
      final key = memoize ? (i, pos.signature()) : null;
      if (key != null) {
        final hit = memo[key];
        if (hit != null) return hit;
      }
      final leaves = <_Leaf>[];
      var moved = false;
      if (i < order.length) {
        for (var from = CheckerMove.bar; from >= 0; from--) {
          // Cheap source precheck before the clone: most squares hold no
          // movable checker for this player.
          final hasSource = from == CheckerMove.bar
              ? pos.bar > 0
              : pos.bar == 0 && pos.points[from] > 0;
          if (!hasSource) continue;
          final branch = pos.clone();
          final cm = branch.tryMove(from, order[i]);
          if (cm != null) {
            moved = true;
            for (final leaf in expand(branch, order, i + 1)) {
              leaves.add((hops: [cm, ...leaf.hops], sig: leaf.sig));
            }
          }
        }
      }
      if (!moved) {
        // Dead end (die unplayable or dice exhausted): a candidate turn ends
        // here, with nothing more to play.
        leaves.add((hops: const <CheckerMove>[], sig: pos.signature()));
      }
      if (key != null) memo[key] = leaves;
      return leaves;
    }

    for (final order in orders) {
      for (final leaf in expand(_Pos.of(normalized), order, 0)) {
        final seq = leaf.hops;
        if (seq.length > maxLen) {
          maxLen = seq.length;
          byResult.clear();
        }
        if (seq.isNotEmpty && seq.length == maxLen) {
          final at = byResult[leaf.sig];
          if (at == null) {
            byResult[leaf.sig] = _Variants(Move(seq), collect: collect);
          } else if (collect) {
            at.add(Move(seq)); // another way to enter the same position
          }
        }
      }
    }

    // Higher-die rule: when only a single die can be played this turn (and
    // it is not a doubles turn), and the higher die alone is playable, the
    // player must play the higher die. For a single-move bear-off where
    // either die could be used (overshoot), both orders reach the same
    // position and dedupe to one Move; `_dieOf` reports the exact pip
    // distance, which may be lower than `dice.high`, so `usesHigh.isNotEmpty`
    // correctly falls back to offering that move.
    if (!dice.isDouble && maxLen == 1) {
      final usesHigh = [
        for (final v in byResult.values)
          if (_dieOf(v.canonical.checkerMoves.single) == dice.high) v,
      ];
      if (usesHigh.isNotEmpty) return usesHigh;
    }

    return byResult.values.toList();
  }

  /// The die a single normalized hop consumed. Bear-off overshoots consume
  /// a die larger than the exact distance; report the distance, and treat
  /// "at least" matches at the call site via dedup (overshoots reaching the
  /// same result collapse to one entry keyed by position).
  static int _dieOf(CheckerMove cm) {
    final from = cm.from == CheckerMove.bar ? 24 : cm.from;
    if (cm.to == CheckerMove.off) return from + 1;
    return from - cm.to;
  }

  /// Maps a normalized move back into real (White-perspective) coordinates.
  static Move _flip(Move m, Player player) {
    if (player == Player.white) return m;
    return Move([
      for (final cm in m.checkerMoves)
        CheckerMove(
          cm.from == CheckerMove.bar ? CheckerMove.bar : 23 - cm.from,
          cm.to == CheckerMove.off ? CheckerMove.off : 23 - cm.to,
          isHit: cm.isHit,
        ),
    ]);
  }
}
