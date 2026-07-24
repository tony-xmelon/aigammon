import 'package:collection/collection.dart' show ListEquality;

import 'move.dart';
import 'player.dart';

/// Immutable board from White's perspective. `points[i]` is the point
/// numbered `i+1` for White; positive counts are White checkers, negative
/// are Black. White moves toward index 0, Black toward index 23.
class BoardState {
  final List<int> points;
  final int whiteBar;
  final int blackBar;
  final int whiteOff;
  final int blackOff;

  static const _eq = ListEquality<int>();

  BoardState({
    required List<int> points,
    this.whiteBar = 0,
    this.blackBar = 0,
    this.whiteOff = 0,
    this.blackOff = 0,
  }) : points = List.unmodifiable(points) {
    if (points.length != 24) {
      throw ArgumentError('points must have 24 entries');
    }
  }

  factory BoardState.initial() => BoardState(points: const [
        -2, 0, 0, 0, 0, 5, //  1-6  (White's home board)
        0, 3, 0, 0, 0, -5, //  7-12
        5, 0, 0, 0, -3, 0, // 13-18
        -5, 0, 0, 0, 0, 2, // 19-24
      ]);

  int barFor(Player p) => p == Player.white ? whiteBar : blackBar;
  int offFor(Player p) => p == Player.white ? whiteOff : blackOff;

  int checkerCount(Player p) {
    var n = barFor(p) + offFor(p);
    for (final c in points) {
      if (p == Player.white && c > 0) n += c;
      if (p == Player.black && c < 0) n += -c;
    }
    return n;
  }

  int pipCount(Player p) {
    var pips = barFor(p) * 25;
    for (var i = 0; i < 24; i++) {
      final c = points[i];
      if (p == Player.white && c > 0) pips += c * (i + 1);
      if (p == Player.black && c < 0) pips += -c * (24 - i);
    }
    return pips;
  }

  /// The board with colors and direction swapped, so perspective-free code
  /// can always treat the moving player as White.
  BoardState mirrored() => BoardState(
        points: [for (var i = 23; i >= 0; i--) -points[i]],
        whiteBar: blackBar,
        blackBar: whiteBar,
        whiteOff: blackOff,
        blackOff: whiteOff,
      );

  /// Applies an assumed-legal [move] for [player]. Hits are recomputed from
  /// the board so application is safe regardless of the isHit flags.
  /// Legality checking lives in MoveGenerator/GameState, not here.
  /// Violating the assumed-legal precondition produces a silently corrupt
  /// board, not an error.
  BoardState applyMove(Player player, Move move) {
    final pts = List.of(points);
    var wBar = whiteBar, bBar = blackBar, wOff = whiteOff, bOff = blackOff;
    final sign = player == Player.white ? 1 : -1;
    for (final cm in move.checkerMoves) {
      if (cm.from == CheckerMove.bar) {
        if (player == Player.white) {
          wBar--;
        } else {
          bBar--;
        }
      } else {
        pts[cm.from] -= sign;
      }
      if (cm.to == CheckerMove.off) {
        if (player == Player.white) {
          wOff++;
        } else {
          bOff++;
        }
      } else {
        if (pts[cm.to] == -sign) {
          pts[cm.to] = 0;
          if (player == Player.white) {
            bBar++;
          } else {
            wBar++;
          }
        }
        pts[cm.to] += sign;
      }
    }
    return BoardState(
      points: pts,
      whiteBar: wBar,
      blackBar: bBar,
      whiteOff: wOff,
      blackOff: bOff,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BoardState &&
      _eq.equals(other.points, points) &&
      other.whiteBar == whiteBar &&
      other.blackBar == blackBar &&
      other.whiteOff == whiteOff &&
      other.blackOff == blackOff;

  @override
  int get hashCode =>
      Object.hash(_eq.hash(points), whiteBar, blackBar, whiteOff, blackOff);

  @override
  String toString() =>
      'BoardState(${points.join(",")} wBar:$whiteBar bBar:$blackBar '
      'wOff:$whiteOff bOff:$blackOff)';
}
