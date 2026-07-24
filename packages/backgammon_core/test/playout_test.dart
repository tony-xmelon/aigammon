import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('300 random games terminate with invariants intact', () {
    final rng = Random(20260724);
    Dice rollDice() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);

    for (var g = 0; g < 300; g++) {
      var opening = rollDice();
      while (opening.isDouble) {
        opening = rollDice();
      }
      var state = GameState.opening(
        firstPlayer:
            opening.die1 > opening.die2 ? Player.white : Player.black,
        openingDice: opening,
      );
      var turns = 0;
      while (state.phase != GamePhase.gameOver) {
        turns++;
        expect(turns, lessThan(2000),
            reason: 'game $g did not terminate');
        expect(state.board.checkerCount(Player.white), 15);
        expect(state.board.checkerCount(Player.black), 15);
        switch (state.phase) {
          case GamePhase.awaitingRoll:
            // Occasionally double when allowed.
            final canDouble = !state.isCrawfordGame &&
                (state.cube.owner == null || state.cube.owner == state.turn);
            if (canDouble && state.cube.value < 8 && rng.nextInt(20) == 0) {
              state = state.offerDouble();
            } else {
              state = state.roll(rollDice());
            }
          case GamePhase.moving:
            final legal = state.legalMoves;
            state = state.play(
                legal.isEmpty ? Move.none : legal[rng.nextInt(legal.length)]);
          case GamePhase.cubeOffered:
            state = rng.nextInt(4) == 0 ? state.drop() : state.take();
          case GamePhase.resignOffered:
          case GamePhase.gameOver:
            fail('unexpected phase ${state.phase}');
        }
      }
      final r = state.result!;
      expect(r.points, greaterThan(0));
      if (r.outcome != GameOutcome.drop) {
        expect(state.board.offFor(r.winner), 15);
      }
    }
  });
}
