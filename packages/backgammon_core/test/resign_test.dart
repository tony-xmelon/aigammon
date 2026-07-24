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

  test('backgammon resignation pays cube x3', () {
    final done = turnOf(Player.white)
        .offerResign(ResignValue.backgammon)
        .acceptResign();
    expect(done.result!.points, 6); // cube 2 × backgammon 3
  });

  test('resignation cannot be offered outside a normal turn', () {
    final pending = turnOf(Player.white)
        .offerResign(ResignValue.single); // now resignOffered
    expect(() => pending.offerResign(ResignValue.single), throwsStateError);
    final cubePending = GameState.testState(
      board: BoardState.initial(),
      turn: Player.white,
      phase: GamePhase.cubeOffered,
    );
    expect(() => cubePending.offerResign(ResignValue.single), throwsStateError);
  });

  test('accept and decline require a pending resignation', () {
    expect(() => turnOf(Player.white).acceptResign(), throwsStateError);
    expect(() => turnOf(Player.white).declineResign(), throwsStateError);
  });

  test('no other verbs while a resignation is pending', () {
    final pending = turnOf(Player.white).offerResign(ResignValue.single);
    expect(() => pending.roll(Dice(3, 1)), throwsStateError);
    expect(() => pending.play(Move.none), throwsStateError);
    expect(() => pending.offerDouble(), throwsStateError);
  });

  test('decline leaves cube and board untouched', () {
    final s = turnOf(Player.white)
        .offerResign(ResignValue.single)
        .declineResign();
    expect(s.cube, const CubeState(value: 2, owner: Player.black));
    expect(s.board, BoardState.initial());
  });
}
