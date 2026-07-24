import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('opponent flips', () {
    expect(Player.white.opponent, Player.black);
    expect(Player.black.opponent, Player.white);
  });

  test('dice validate range and detect doubles', () {
    expect(Dice(3, 3).isDouble, isTrue);
    expect(Dice(3, 1).isDouble, isFalse);
    expect(Dice(6, 5).high, 6);
    expect(Dice(5, 6).high, 6);
    expect(() => Dice(0, 3), throwsArgumentError);
    expect(() => Dice(3, 7), throwsArgumentError);
  });

  test('dice equality', () {
    expect(Dice(3, 1), Dice(3, 1));
    expect(Dice(3, 1), isNot(Dice(1, 3)));
  });
}
