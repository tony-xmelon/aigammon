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

  test('higher die is forced for bar entry too', () {
    // White: one on the bar, one spare on index 5. Entry with the 6
    // (-> idx 18) and entry with the 2 (-> idx 22) are both legal, but
    // neither has a continuation: after either entry the other die is
    // blocked everywhere (Black owns 16 and 3; bear-off impossible with a
    // checker still outside home). Two distinct length-1 turns -> the
    // higher entry is mandatory.
    final pts = List<int>.filled(24, 0);
    pts[5] = 1;
    pts[16] = -2; // blocks 18->16 (the 2 after entering with the 6) and 22->16 (the 6)
    pts[3] = -2; // blocks 5->3 (the 2)
    final board = BoardState(points: pts, whiteBar: 1);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 2));
    expect(moves, hasLength(1));
    expect(moves.single.checkerMoves.single.from, CheckerMove.bar);
    expect(moves.single.checkerMoves.single.to, 18); // entry with the 6
  });

  test('a lone overshoot bear-off is still offered despite the rule', () {
    final pts = List<int>.filled(24, 0);
    pts[2] = 1; // last checker on the 3-point
    final board = BoardState(points: pts, whiteOff: 14);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
    expect(moves, hasLength(1));
    expect(moves.single.checkerMoves.single.to, CheckerMove.off);
    expect(moves.single.checkerMoves.single.from, 2);
  });
}
