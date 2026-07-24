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
      return null; // bear-off: Task 8
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

class MoveGenerator {
  /// All distinct legal full-turn moves for [player] with [dice], in real
  /// (White-perspective) coordinates. Implements: play the maximum number
  /// of dice possible; doubles allow four moves. Returns an empty list on a
  /// dance. The higher-die tiebreak is added in Task 9.
  static List<Move> legalMoves(BoardState board, Player player, Dice dice) {
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
    final byResult = <String, Move>{};

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
          byResult.putIfAbsent(pos.signature(), () => Move(List.of(seq)));
        }
      }
    }

    for (final order in orders) {
      search(_Pos.of(normalized), order, 0, const []);
    }

    return _denormalize(byResult.values.toList(), player);
  }

  static List<Move> _denormalize(List<Move> moves, Player player) {
    if (player == Player.white) return moves;
    Move flip(Move m) => Move([
          for (final cm in m.checkerMoves)
            CheckerMove(
              cm.from == CheckerMove.bar ? CheckerMove.bar : 23 - cm.from,
              cm.to == CheckerMove.off ? CheckerMove.off : 23 - cm.to,
              isHit: cm.isHit,
            ),
        ]);
    return [for (final m in moves) flip(m)];
  }
}
