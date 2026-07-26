import 'board_state.dart';
import 'dice.dart';
import 'move.dart';
import 'player.dart';

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

  String signature() => '${points.join(",")}|$bar|$oppBar|$off';

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
      if (!allHome) return null;
      final exact = die == from + 1;
      final overshoot = die > from + 1 && from == highestPoint;
      if (!exact && !overshoot) return null;
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

  /// Records [m] unless a permutation of its hops is already known.
  void add(Move m) {
    if (!collect) return;
    _byHops.putIfAbsent(_hopSetKey(m), () => m);
  }

  List<Move> get decompositions =>
      collect ? _byHops.values.toList() : [canonical];

  /// Order-insensitive key for a hop list. Each hop packs into
  /// `(from + 1) * 100 + (to + 1)` (0..2500, bar == 24 and off == -1 included),
  /// and up to four SORTED hop codes pack into one 64-bit int.
  static int _hopSetKey(Move m) {
    final codes = [
      for (final h in m.checkerMoves) (h.from + 1) * 100 + (h.to + 1),
    ]..sort();
    var key = 0;
    for (final code in codes) {
      key = key * 2600 + code;
    }
    return key;
  }
}

class MoveGenerator {
  /// All distinct legal full-turn moves for [player] with [dice], in real
  /// (White-perspective) coordinates. Implements: play the maximum number
  /// of dice possible; doubles allow four moves. Returns an empty list on a
  /// dance. The higher-die tiebreak is added in Task 9.
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
    // TODO(perf): for doubles, memoize expanded (dice-remaining, signature)
    // nodes — permutations of the same source multiset are currently
    // re-expanded and only collapse at the leaves. Revisit before heavy AI
    // playout use.
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
    final byResult = <String, _Variants>{};

    void search(_Pos pos, List<int> order, int i, List<CheckerMove> seq) {
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
            search(branch, order, i + 1, [...seq, cm]);
          }
        }
      }
      if (!moved) {
        // Dead end (die unplayable or dice exhausted): candidate turn.
        if (seq.length > maxLen) {
          maxLen = seq.length;
          byResult.clear();
        }
        if (seq.isNotEmpty && seq.length == maxLen) {
          final signature = pos.signature();
          final at = byResult[signature];
          if (at == null) {
            byResult[signature] =
                _Variants(Move(List.of(seq)), collect: collect);
          } else if (collect) {
            at.add(Move(List.of(seq))); // another way to enter the same position
          }
        }
      }
    }

    for (final order in orders) {
      search(_Pos.of(normalized), order, 0, const []);
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
