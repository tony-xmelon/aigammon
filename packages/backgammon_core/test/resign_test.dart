import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  GameState turnOf(Player p, {Dice? dice}) => GameState.testState(
        board: BoardState.initial(),
        turn: p,
        phase: dice == null ? GamePhase.awaitingRoll : GamePhase.moving,
        dice: dice,
        cube: const CubeState(value: 2, owner: Player.black),
      );

  test('offer and accept a gammon resignation', () {
    final s = turnOf(Player.white).offerResign(ResignValue.gammon);
    expect(s.phase, GamePhase.resignOffered);
    expect(s.turn, Player.black); // decider
    final done = s.acceptResign();
    expect(done.phase, GamePhase.gameOver);
    expect(done.result!.winner, Player.black);
    expect(done.result!.points, 4); // cube 2 × gammon 2
    expect(done.result!.outcome, GameOutcome.resignation);
  });

  test('decline returns to the offering player mid-turn', () {
    final s = turnOf(Player.white, dice: Dice(3, 1))
        .offerResign(ResignValue.single)
        .declineResign();
    expect(s.turn, Player.white);
    expect(s.phase, GamePhase.moving); // dice were already rolled
    expect(s.dice, Dice(3, 1));
  });

  test('decline before rolling returns to awaitingRoll', () {
    final s = turnOf(Player.white)
        .offerResign(ResignValue.single)
        .declineResign();
    expect(s.phase, GamePhase.awaitingRoll);
  });
}
