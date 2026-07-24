import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('when only one die can be played, the higher must be chosen', () {
    // Setup: White has a checker on his 6-point (index 5) and one on
    // index 22 that is fully blocked for both dice (Black owns 17 and 19).
    // Dice 5-3. The 5 plays 6/1 (index 5 -> 0); the 3 plays 6/3
    // (index 5 -> 2). Neither play has a legal continuation: the follow-up
    // would have to bear off, which is illegal while the index-22 checker
    // is outside the home board. So both single-die plays exist, only one
    // die can ever be used, and the higher (the 5, 6/1) is mandatory.
    final pts = List<int>.filled(24, 0);
    pts[5] = 1; // White on his 6-point
    pts[22] = 1; // White checker outside home, blocked for both dice
    pts[17] = -2; // blocks 23/18 (the 5)
    pts[19] = -2; // blocks 23/20 (the 3)
    final board = BoardState(points: pts, whiteOff: 13);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(5, 3));
    expect(moves, hasLength(1));
    expect(moves.single.checkerMoves.single.from, 5);
    expect(moves.single.checkerMoves.single.to, 0); // 6/1 = the 5
  });

  test('rule does not apply when both dice are playable together', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(5, 3));
    expect(moves.every((m) => m.checkerMoves.length == 2), isTrue);
  });
}
