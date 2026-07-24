import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  // Golden from wildbg's own C API docs (starting position, mover's view).
  const wildbgStart = [
    0, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, //
    -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2, 0,
  ];

  test('white mover: starting position matches wildbg golden array', () {
    expect(encodePips(BoardState.initial(), Player.white), wildbgStart);
  });

  test('black mover: symmetric start encodes identically', () {
    expect(encodePips(BoardState.initial(), Player.black), wildbgStart);
  });

  test('bars are encoded at indices 25 (mover) and 0 (opponent, negative)',
      () {
    final b = BoardState(
        points: List.filled(24, 0), whiteBar: 2, blackBar: 1);
    final whiteView = encodePips(b, Player.white);
    expect(whiteView[25], 2);
    expect(whiteView[0], -1);
    final blackView = encodePips(b, Player.black);
    expect(blackView[25], 1);
    expect(blackView[0], -2);
  });

  test('asymmetric position mirrors correctly for the black mover', () {
    // Lone white checker on White's 24-point (index 23).
    final pts = List<int>.filled(24, 0);
    pts[23] = 1;
    final b = BoardState(points: pts);
    // White mover: that checker is on wildbg pip 24.
    expect(encodePips(b, Player.white)[24], 1);
    // Black mover: mirrored — the white checker is the OPPONENT on pip 1.
    expect(encodePips(b, Player.black)[1], -1);
  });

  test('decodeDetail maps pips back to CheckerMove for both movers', () {
    // White mover: pip 8 -> 5 is index 7 -> 4.
    expect(decodeDetail(8, 5, Player.white), const CheckerMove(7, 4));
    // Bar entry: from 25; die 3 lands on pip 22 = index 21.
    expect(decodeDetail(25, 22, Player.white),
        const CheckerMove(CheckerMove.bar, 21));
    // Bear-off: to 0.
    expect(decodeDetail(3, 0, Player.white),
        const CheckerMove(2, CheckerMove.off));
    // Black mover: pip p = real index 24 - p.
    expect(decodeDetail(8, 5, Player.black), const CheckerMove(16, 19));
    expect(decodeDetail(25, 22, Player.black),
        const CheckerMove(CheckerMove.bar, 2));
    expect(decodeDetail(3, 0, Player.black),
        const CheckerMove(21, CheckerMove.off));
  });
}
