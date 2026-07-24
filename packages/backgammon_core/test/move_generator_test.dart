import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

Matcher containsMove(Move expected) => predicate<List<Move>>(
    (moves) => moves.any((m) => m.sameAs(expected)),
    'contains ${expected.toString()}');

void main() {
  test('opening 3-1 includes the golden point play 8/5 6/5', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(3, 1));
    expect(moves, containsMove(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])));
    // 24/23 with the 1 then 23/20 with the 3 is also legal
    expect(moves, containsMove(Move(const [CheckerMove(23, 22), CheckerMove(22, 19)])));
  });

  test('blocked points are not landable', () {
    // Black owns index 18; White's checkers on index 23 want 23->18 with a
    // 5 but may not land there. White's checkers on index 9 can still play.
    final board = BoardState(points: [
      0, 0, 0, 0, 0, 0, //
      0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, -2, 0, 0, 0, 0, 2,
    ]);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(5, 5));
    expect(moves, isNotEmpty); // 10/5 plays are available
    for (final m in moves) {
      for (final cm in m.checkerMoves) {
        expect(cm.to, isNot(18));
      }
    }
  });

  test('landing on a blot is marked as a hit', () {
    final board = BoardState(points: [
      0, 0, -1, 0, 0, 1, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -2,
    ]);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(3, 2));
    final hit = moves.firstWhere(
        (m) => m.checkerMoves.any((c) => c.to == 2 && c.isHit));
    expect(hit, isNotNull);
  });

  test('must play both dice when possible: lone playable one-die move is excluded', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(6, 5));
    expect(moves.every((m) => m.checkerMoves.length == 2), isTrue);
  });

  test('a one-die line is excluded when another line plays both dice', () {
    // White can play 6-5 fully via 11/5 6/1 (10->4 then 5->0). But playing
    // the 5 as 11/6 (10->5) leaves the 6 unplayable everywhere — that
    // one-die line must be excluded. The checker on index 23 is outside
    // home and fully blocked by Black (so bear-off can never rescue the
    // stuck line, now or after Task 8).
    final pts = List<int>.filled(24, 0);
    pts[5] = 1;
    pts[10] = 1;
    pts[23] = 1;
    pts[17] = -2; // blocks 24/18 (the 6)
    pts[18] = -2; // blocks 24/19 (the 5)
    final board = BoardState(points: pts);
    final moves = MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
    expect(moves, hasLength(1));
    expect(
        moves.single
            .sameAs(Move(const [CheckerMove(10, 4), CheckerMove(5, 0)])),
        isTrue);
  });

  test('doubles play up to four checkers', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(1, 1));
    expect(moves.every((m) => m.checkerMoves.length == 4), isTrue);
  });

  test('black moves are returned in real board coordinates', () {
    final moves =
        MoveGenerator.legalMoves(BoardState.initial(), Player.black, Dice(3, 1));
    // Black's golden point: black 8/5 6/5 = indices 16->19, 18->19
    expect(moves, containsMove(Move(const [CheckerMove(16, 19), CheckerMove(18, 19)])));
  });
}
