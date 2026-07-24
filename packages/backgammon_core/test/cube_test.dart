import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  GameState awaiting({CubeState cube = const CubeState.initial(),
      bool crawford = false}) {
    return GameState.testState(
      board: BoardState.initial(),
      turn: Player.white,
      phase: GamePhase.awaitingRoll,
      cube: cube,
      isCrawfordGame: crawford,
    );
  }

  test('double before rolling; opponent decides', () {
    final s = awaiting().offerDouble();
    expect(s.phase, GamePhase.cubeOffered);
    expect(s.turn, Player.black); // the decider
  });

  test('take doubles the cube and gives ownership to the taker', () {
    final s = awaiting().offerDouble().take();
    expect(s.cube, const CubeState(value: 2, owner: Player.black));
    expect(s.turn, Player.white); // doubler now rolls
    expect(s.phase, GamePhase.awaitingRoll);
  });

  test('drop ends the game at the pre-double stake', () {
    final s = awaiting(cube: const CubeState(value: 2, owner: Player.white))
        .offerDouble()
        .drop();
    expect(s.phase, GamePhase.gameOver);
    expect(s.result!.winner, Player.white);
    expect(s.result!.points, 2);
    expect(s.result!.outcome, GameOutcome.drop);
  });

  test('only the cube owner may redouble', () {
    final owned = awaiting(cube: const CubeState(value: 2, owner: Player.black));
    expect(() => owned.offerDouble(), throwsStateError); // white, not owner
  });

  test('no doubling in the Crawford game', () {
    expect(() => awaiting(crawford: true).offerDouble(), throwsStateError);
  });

  test('cannot double after rolling', () {
    final rolled = awaiting().roll(Dice(3, 1));
    expect(() => rolled.offerDouble(), throwsStateError);
  });

  test('take and drop require a pending double', () {
    expect(() => awaiting().take(), throwsStateError);
    expect(() => awaiting().drop(), throwsStateError);
  });

  test('offering a double does not change the cube value', () {
    expect(awaiting().offerDouble().cube, const CubeState.initial());
  });
}
