import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('white plays 24/23 13/11 from the start', () {
    final b = BoardState.initial().applyMove(
        Player.white, Move(const [CheckerMove(23, 22), CheckerMove(12, 10)]));
    expect(b.points[23], 1);
    expect(b.points[22], 1);
    expect(b.points[12], 4);
    expect(b.points[10], 1);
    expect(b.checkerCount(Player.white), 15);
  });

  test('landing on a lone opponent checker hits it to the bar', () {
    final b = BoardState(points: [
      0, 0, 0, -1, 0, 2, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]).applyMove(Player.white, Move(const [CheckerMove(5, 3, isHit: true)]));
    expect(b.points[3], 1);
    expect(b.blackBar, 1);
  });

  test('hit is applied even when the flag is stale', () {
    // applyMove computes hits from the board, not from isHit.
    final b = BoardState(points: [
      0, 0, 0, -1, 0, 2, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]).applyMove(Player.white, Move(const [CheckerMove(5, 3)]));
    expect(b.points[3], 1);
    expect(b.blackBar, 1);
  });

  test('entering from the bar and bearing off', () {
    var b = BoardState(
      points: [
        1, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ],
      whiteBar: 1,
    );
    b = b.applyMove(Player.white, Move(const [CheckerMove(CheckerMove.bar, 21)]));
    expect(b.whiteBar, 0);
    expect(b.points[21], 1);
    b = b.applyMove(Player.white, Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(b.whiteOff, 1);
    expect(b.points[0], 0);
  });

  test('black moves increase indices and hit white blots', () {
    final b = BoardState(points: [
      -2, 0, 0, 1, 0, 0, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]).applyMove(Player.black, Move(const [CheckerMove(0, 3)]));
    expect(b.points[0], -1);
    expect(b.points[3], -1);
    expect(b.whiteBar, 1);
  });

  test('sequential same-checker hop within one Move', () {
    final b = BoardState.initial().applyMove(
        Player.white, Move(const [CheckerMove(23, 22), CheckerMove(22, 20)]));
    expect(b.points[23], 1);
    expect(b.points[22], 0);
    expect(b.points[20], 1);
    expect(b.checkerCount(Player.white), 15);
  });

  test('hit then land a second checker on the same point in one Move', () {
    final b = BoardState(points: [
      0, 0, 0, -1, 1, 1, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]).applyMove(Player.white,
        Move(const [CheckerMove(5, 3, isHit: true), CheckerMove(4, 3)]));
    expect(b.points[3], 2);
    expect(b.blackBar, 1);
  });

  test('applyMove does not mutate the source board', () {
    final original = BoardState.initial();
    original.applyMove(
        Player.white, Move(const [CheckerMove(23, 22), CheckerMove(12, 10)]));
    expect(original, BoardState.initial());
  });
}
