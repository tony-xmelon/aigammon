@Tags(['engine'])
library;

import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('two engine players complete full games legally', () async {
    final service = await EngineService.spawn(
        netsPath: '../../native/wildbg-nets/neural-nets');
    addTearDown(service.dispose);
    final rng = Random(7);
    Dice roll() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);

    final sw = Stopwatch()..start();
    for (var g = 0; g < 3; g++) {
      var opening = roll();
      while (opening.isDouble) {
        opening = roll();
      }
      var state = GameState.opening(
        firstPlayer: opening.die1 > opening.die2 ? Player.white : Player.black,
        openingDice: opening,
      );
      var turns = 0;
      while (state.phase != GamePhase.gameOver) {
        expect(++turns, lessThan(600), reason: 'game $g stuck');
        switch (state.phase) {
          case GamePhase.awaitingRoll:
            state = state.roll(roll());
          case GamePhase.moving:
            final ranked =
                await service.rankMoves(state.board, state.turn, state.dice!);
            final pick = ranked.isEmpty
                ? Move.none
                : pickMove(
                        ranked,
                        state.turn == Player.white
                            ? Difficulty.expert
                            : Difficulty.easy,
                        rng)
                    .move;
            state = state.play(pick); // GameState enforces legality
          case GamePhase.cubeOffered:
          case GamePhase.resignOffered:
          case GamePhase.gameOver:
            fail('unexpected phase ${state.phase}');
        }
      }
      expect(state.result!.points, greaterThan(0));
    }
    sw.stop();
    // ignore: avoid_print
    print('3 AI-vs-AI games in ${sw.elapsedMilliseconds} ms');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
