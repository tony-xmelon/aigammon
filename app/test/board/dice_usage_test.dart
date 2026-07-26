import 'package:aigammon_app/board/dice_usage.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pipDistance', () {
    test('a plain point hop is the index difference, per direction', () {
      // White runs toward index 0; Black toward index 23.
      expect(pipDistance(const CheckerMove(7, 4), Player.white), 3);
      expect(pipDistance(const CheckerMove(4, 7), Player.black), 3);
    });

    test('bar entry is measured from 25 pips out, for both sides', () {
      // White enters on Black's home board (high indices): bar/24 is a 1.
      expect(pipDistance(const CheckerMove(CheckerMove.bar, 23), Player.white), 1);
      expect(pipDistance(const CheckerMove(CheckerMove.bar, 18), Player.white), 6);
      // Black enters on White's home board (low indices): bar/24 is a 1.
      expect(pipDistance(const CheckerMove(CheckerMove.bar, 0), Player.black), 1);
      expect(pipDistance(const CheckerMove(CheckerMove.bar, 5), Player.black), 6);
    });

    test('bear-off is the distance past the mover\'s own edge', () {
      expect(pipDistance(const CheckerMove(2, CheckerMove.off), Player.white), 3);
      expect(pipDistance(const CheckerMove(0, CheckerMove.off), Player.white), 1);
      expect(pipDistance(const CheckerMove(21, CheckerMove.off), Player.black), 3);
      expect(pipDistance(const CheckerMove(23, CheckerMove.off), Player.black), 1);
    });
  });

  group('usedDiceSlots (non-doubles)', () {
    test('nothing staged spends nothing', () {
      expect(usedDiceSlots(const [], Dice(3, 1), Player.white), isEmpty);
    });

    test('each die is spent independently, by pip distance', () {
      final dice = Dice(3, 1);
      // 8/5 is the 3 — slot 0 only.
      expect(usedDiceSlots(const [CheckerMove(7, 4)], dice, Player.white), {0});
      // 6/5 is the 1 — slot 1 only.
      expect(usedDiceSlots(const [CheckerMove(5, 4)], dice, Player.white), {1});
      // Both hops: both dice spent.
      expect(
        usedDiceSlots(
            const [CheckerMove(7, 4), CheckerMove(5, 4)], dice, Player.white),
        {0, 1},
      );
    });

    test('slots follow the ROLL order, not the die magnitude', () {
      // The same 3-pip hop lands on slot 1 when the 3 was rolled second.
      expect(usedDiceSlots(const [CheckerMove(7, 4)], Dice(1, 3), Player.white),
          {1});
    });

    test('Black hops resolve against the same pair', () {
      final dice = Dice(5, 2);
      expect(usedDiceSlots(const [CheckerMove(4, 9)], dice, Player.black), {0});
      expect(usedDiceSlots(const [CheckerMove(4, 6)], dice, Player.black), {1});
    });

    test('a bear-off OVERSHOOT spends the smallest die that covers it', () {
      // Bearing off the 2-point with 5-4 in hand: the exact 2 is not there, so
      // the 4 (the smaller of the two that reach) is the die that was spent.
      expect(
        usedDiceSlots(
            const [CheckerMove(1, CheckerMove.off)], Dice(5, 4), Player.white),
        {1},
      );
      // With 4-5 the same overshoot lands on the other slot.
      expect(
        usedDiceSlots(
            const [CheckerMove(1, CheckerMove.off)], Dice(4, 5), Player.white),
        {0},
      );
    });
  });

  group('usedDiceSlots (doubles)', () {
    final dice = Dice(2, 2);
    List<CheckerMove> hops(int n) =>
        [for (var i = 0; i < n; i++) const CheckerMove(12, 10)];

    test('four hops share two painted dice, so dimming is progressive', () {
      expect(usedDiceSlots(hops(1), dice, Player.white), isEmpty,
          reason: 'half a die is not a played die');
      expect(usedDiceSlots(hops(2), dice, Player.white), {0});
      expect(usedDiceSlots(hops(3), dice, Player.white), {0},
          reason: 'the second die only goes out with the fourth hop');
      expect(usedDiceSlots(hops(4), dice, Player.white), {0, 1});
    });
  });

  group('highestDieDestination', () {
    test('prefers the bigger die when both are legal from the checker', () {
      final state =
          GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));
      final builder = MoveBuilder(state.legalMoves);
      // The 8-point can play either die: 8/5 (the 3) or 8/7 (the 1).
      expect(builder.destinationsFor(7), containsAll(<int>{4, 6}));
      expect(highestDieDestination(builder, 7, Player.white), 4,
          reason: 'the 3 (8/5) beats the 1 (8/7)');
    });

    test('falls back to the only legal die when the higher one is blocked', () {
      // White on the bar with 6-1: Black owns the 19-point (index 18), so the
      // 6 cannot enter and only the 1 (bar/24) is available.
      final pts = List<int>.filled(24, 0);
      pts[0] = 14;
      pts[18] = -2;
      pts[22] = -13;
      final state = GameState.testState(
        board: BoardState(points: pts, whiteBar: 1),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(6, 1),
      );
      final builder = MoveBuilder(state.legalMoves);
      expect(builder.destinationsFor(CheckerMove.bar), {23});
      expect(highestDieDestination(builder, CheckerMove.bar, Player.white), 23);
    });

    test('returns null for a location that offers no hop', () {
      final state =
          GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));
      final builder = MoveBuilder(state.legalMoves);
      expect(highestDieDestination(builder, 0, Player.white), isNull);
    });
  });
}
