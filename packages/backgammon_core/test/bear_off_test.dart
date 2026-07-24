import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  BoardState home(List<int> whiteHome, {int whiteOff = 0, int outside = 0}) {
    // whiteHome fills indices 0-5; outside optionally puts a checker on 12.
    final pts = List<int>.filled(24, 0);
    for (var i = 0; i < 6; i++) {
      pts[i] = whiteHome[i];
    }
    if (outside > 0) pts[12] = outside;
    return BoardState(points: pts, whiteOff: whiteOff);
  }

  test('exact die bears off', () {
    final board = home([0, 0, 0, 0, 0, 2], whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 6));
    // Both checkers on the 6-point bear off with sixes.
    expect(
        moves.any((m) =>
            m.checkerMoves.where((c) => c.to == CheckerMove.off).length == 2),
        isTrue);
  });

  test('cannot bear off while a checker is outside the home board', () {
    final board = home([0, 0, 0, 0, 0, 2], whiteOff: 12, outside: 1);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
    for (final m in moves) {
      // The outside checker travels (13/7 with the 6, 13/8 with the 5,
      // etc.); no hop may bear off while index 12 is occupied.
      for (final cm in m.checkerMoves) {
        expect(cm.to, isNot(CheckerMove.off));
      }
    }
  });

  test('overshoot only from the highest occupied point', () {
    final board = home([0, 1, 0, 1, 0, 0], whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 6));
    // Die 6 > both points; only the highest (index 3, the 4-point) may
    // bear off first, then index 1.
    final first = moves.first.checkerMoves.first;
    expect(first.from, 3);
    expect(first.to, CheckerMove.off);
    expect(moves.first.checkerMoves[1].from, 1);
  });

  test('opponent checkers in the home board do not block bear-off', () {
    final pts = List<int>.filled(24, 0);
    pts[5] = 2; // White on the 6-point
    pts[0] = -2; // Black anchor on White's 1-point
    pts[10] = -1; // Black blot outside
    final board = BoardState(points: pts, whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 6));
    expect(
        moves.any((m) =>
            m.checkerMoves.where((c) => c.to == CheckerMove.off).length == 2),
        isTrue);
  });

  test('a checker can come home and bear off in the same turn', () {
    final pts = List<int>.filled(24, 0);
    pts[7] = 1; // White's 8-point, outside home
    final board = BoardState(points: pts, whiteOff: 14);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(4, 4));
    // 8/4 with the first 4, then 4/off exactly, twice unused? Only one
    // checker: 8/4 then 4/off — a length-2 sequence bearing off the last
    // checker mid-doubles.
    expect(
        moves.any((m) => m.checkerMoves.any((c) => c.to == CheckerMove.off)),
        isTrue);
  });

  test('smaller die may still move inside the home board', () {
    final board = home([0, 0, 0, 0, 0, 2], whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(2, 1));
    // Checkers sit on the 6-point; dice 2,1 move within the board only —
    // no bear-off is possible (die < point number, no overshoot rights).
    expect(
        moves.every(
            (m) => m.checkerMoves.every((c) => c.to != CheckerMove.off)),
        isTrue);
  });
}
