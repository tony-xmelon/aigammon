import 'package:backgammon_core/backgammon_core.dart';

/// Encodes a board as wildbg's 26-int pip array from [mover]'s perspective:
/// index 0 = opponent's bar (negative), 1-24 = pips (mover positive, moving
/// 24 -> 1), index 25 = mover's bar.
List<int> encodePips(BoardState board, Player mover) {
  final n = mover == Player.white ? board : board.mirrored();
  return [
    -n.blackBar,
    ...n.points,
    n.whiteBar,
  ];
}

/// Maps one wildbg move detail (from: 1-25 where 25 = bar; to: 0-24 where
/// 0 = off) back to a [CheckerMove] in real White-perspective coordinates.
/// Hit flags are not reconstructed — BoardState.applyMove recomputes hits.
CheckerMove decodeDetail(int from, int to, Player mover) {
  if (mover == Player.white) {
    return CheckerMove(
      from == 25 ? CheckerMove.bar : from - 1,
      to == 0 ? CheckerMove.off : to - 1,
    );
  }
  return CheckerMove(
    from == 25 ? CheckerMove.bar : 24 - from,
    to == 0 ? CheckerMove.off : 24 - to,
  );
}
