import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('initial position is the standard backgammon setup', () {
    final b = BoardState.initial();
    expect(b.points[23], 2); // White's 24-point
    expect(b.points[12], 5); // White's 13-point
    expect(b.points[7], 3); //  White's 8-point
    expect(b.points[5], 5); //  White's 6-point
    expect(b.points[0], -2); // Black's 24-point
    expect(b.points[11], -5);
    expect(b.points[16], -3);
    expect(b.points[18], -5);
    expect(b.whiteBar, 0);
    expect(b.blackOff, 0);
    expect(b.checkerCount(Player.white), 15);
    expect(b.checkerCount(Player.black), 15);
  });

  test('initial pip count is 167 for both players', () {
    final b = BoardState.initial();
    expect(b.pipCount(Player.white), 167);
    expect(b.pipCount(Player.black), 167);
  });

  test('bar checkers count 25 pips', () {
    final b = BoardState(
      points: List.filled(24, 0),
      whiteBar: 2,
    );
    expect(b.pipCount(Player.white), 50);
  });

  test('mirrored swaps colors and direction, twice is identity', () {
    final b = BoardState.initial();
    final m = b.mirrored();
    expect(m.points[23], 2); // Black's back checkers become White's
    expect(m.points[0], -2);
    expect(m.mirrored(), b);
  });

  test('mirrored swaps bar and off counts', () {
    final b = BoardState(
      points: List.filled(24, 0),
      whiteBar: 1,
      blackOff: 3,
    );
    final m = b.mirrored();
    expect(m.blackBar, 1);
    expect(m.whiteBar, 0);
    expect(m.whiteOff, 3);
    expect(m.blackOff, 0);
    expect(m.mirrored(), b);
  });

  test('value equality', () {
    expect(BoardState.initial(), BoardState.initial());
    expect(BoardState.initial(),
        isNot(BoardState(points: List.filled(24, 0))));
  });
}
