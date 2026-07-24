import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  BoardState barBoard({List<int>? blackHome}) {
    // White has 1 checker on the bar and 1 on the 13-point (index 12).
    // blackHome fills indices 18-23 (Black's blocking of White's entry).
    final pts = List<int>.filled(24, 0);
    pts[12] = 1;
    final home = blackHome ?? [0, 0, 0, 0, 0, 0];
    for (var i = 0; i < 6; i++) {
      pts[18 + i] = home[i];
    }
    return BoardState(points: pts, whiteBar: 1);
  }

  test('must enter from the bar before any other move', () {
    final moves =
        MoveGenerator.legalMoves(barBoard(), Player.white, Dice(6, 2));
    expect(moves, isNotEmpty);
    for (final m in moves) {
      expect(m.checkerMoves.first.from, CheckerMove.bar);
    }
  });

  test('entry point is 25 minus the die', () {
    final moves =
        MoveGenerator.legalMoves(barBoard(), Player.white, Dice(3, 3));
    // die 3 enters on White's 22-point (index 21)
    expect(moves.first.checkerMoves.first.to, 21);
  });

  test('fully blocked entry is a dance', () {
    final board = barBoard(blackHome: [-2, -2, -2, -2, -2, -2]);
    expect(MoveGenerator.legalMoves(board, Player.white, Dice(6, 2)), isEmpty);
  });

  test('entry can hit a blot', () {
    final board = barBoard(blackHome: [0, 0, 0, 0, 0, -1]);
    // die 1 enters on index 23 where a lone black checker sits
    final moves =
        MoveGenerator.legalMoves(board, Player.white, Dice(1, 5));
    final entries = [
      for (final m in moves) m.checkerMoves.first,
    ].where((c) => c.to == 23);
    expect(entries.every((c) => c.isHit), isTrue);
    expect(entries, isNotEmpty);
  });
}
