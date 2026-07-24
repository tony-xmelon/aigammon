import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  GameState fresh() =>
      GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));

  test('opening state is ready to move with the opening dice', () {
    final s = fresh();
    expect(s.turn, Player.white);
    expect(s.phase, GamePhase.moving);
    expect(s.dice, Dice(3, 1));
    expect(s.cube.value, 1);
    expect(s.cube.owner, isNull);
  });

  test('playing a legal move passes the turn', () {
    final s = fresh()
        .play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]));
    expect(s.turn, Player.black);
    expect(s.phase, GamePhase.awaitingRoll);
    expect(s.dice, isNull);
    expect(s.board.points[4], 2);
  });

  test('illegal moves throw', () {
    expect(() => fresh().play(Move(const [CheckerMove(23, 20)])),
        throwsStateError); // one hop when two dice are playable
  });

  test('a transit-equivalent decomposition of a legal move is accepted', () {
    // 24/20 with 3-then-1 vs 1-then-3: the generator keeps one
    // representative; play() must accept the other decomposition too
    // because it reaches the same position.
    final viaA = Move(const [CheckerMove(23, 20), CheckerMove(20, 19)]);
    final viaB = Move(const [CheckerMove(23, 22), CheckerMove(22, 19)]);
    final a = fresh().play(viaA);
    final b = fresh().play(viaB);
    expect(a.board, b.board);
    expect(a.phase, GamePhase.awaitingRoll);
  });

  test('roll only when awaiting roll', () {
    expect(() => fresh().roll(Dice(2, 2)), throwsStateError);
    final s = fresh()
        .play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]))
        .roll(Dice(2, 2));
    expect(s.phase, GamePhase.moving);
    expect(s.turn, Player.black);
  });

  test('bearing off the 15th checker wins: single, gammon, backgammon', () {
    GameState endgame({required int blackOff, int blackInWhiteHome = 0}) {
      final pts = List<int>.filled(24, 0);
      pts[0] = 1; // White's last checker on his 1-point
      if (blackInWhiteHome > 0) pts[3] = -blackInWhiteHome;
      final blackRemaining = 15 - blackOff - blackInWhiteHome;
      if (blackRemaining > 0) pts[20] = -blackRemaining;
      return GameState.testState(
        board: BoardState(
            points: pts, whiteOff: 14, blackOff: blackOff),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(1, 2),
        cube: const CubeState(value: 2, owner: Player.white),
      );
    }

    final single = endgame(blackOff: 3)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(single.phase, GamePhase.gameOver);
    expect(single.result!.winner, Player.white);
    expect(single.result!.outcome, GameOutcome.single);
    expect(single.result!.points, 2); // cube 2 × 1

    final gammon = endgame(blackOff: 0)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(gammon.result!.outcome, GameOutcome.gammon);
    expect(gammon.result!.points, 4); // cube 2 × 2

    final bg = endgame(blackOff: 0, blackInWhiteHome: 2)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(bg.result!.outcome, GameOutcome.backgammon);
    expect(bg.result!.points, 6); // cube 2 × 3
  });

  test('a dance passes the turn with Move.none', () {
    // White on the bar, Black's home fully closed.
    final pts = List<int>.filled(24, 0);
    for (var i = 18; i < 24; i++) {
      pts[i] = -2;
    }
    pts[0] = -3; // remaining black checkers
    pts[12] = 14; // white checkers elsewhere
    final s = GameState.testState(
      board: BoardState(points: pts, whiteBar: 1),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(6, 2),
      cube: const CubeState(value: 1, owner: null),
    );
    expect(s.legalMoves, isEmpty);
    expect(() => s.play(Move(const [CheckerMove(12, 10)])), throwsStateError);
    final next = s.play(Move.none);
    expect(next.turn, Player.black);
    expect(next.phase, GamePhase.awaitingRoll);
  });
}
