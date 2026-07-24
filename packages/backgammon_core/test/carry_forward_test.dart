import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('GameResult value equality', () {
    const a = GameResult(
        winner: Player.white, points: 2, outcome: GameOutcome.gammon);
    const b = GameResult(
        winner: Player.white, points: 2, outcome: GameOutcome.gammon);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
        a,
        isNot(const GameResult(
            winner: Player.white, points: 2, outcome: GameOutcome.single)));
  });

  test('ResignOffer value equality', () {
    const a = ResignOffer(by: Player.white, value: ResignValue.gammon);
    expect(a, const ResignOffer(by: Player.white, value: ResignValue.gammon));
    expect(a,
        isNot(const ResignOffer(by: Player.black, value: ResignValue.gammon)));
  });

  test('GameState value equality', () {
    GameState fresh() =>
        GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));
    expect(fresh(), fresh());
    expect(fresh().hashCode, fresh().hashCode);
    final moved =
        fresh().play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]));
    expect(moved, isNot(fresh()));
    // Same events replayed produce equal states:
    expect(fresh().play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        moved);
  });

  test('GameState equality is sensitive to every field', () {
    GameState base({CubeState cube = const CubeState.initial(),
        bool crawford = false}) {
      return GameState.testState(
        board: BoardState.initial(),
        turn: Player.white,
        phase: GamePhase.awaitingRoll,
        cube: cube,
        isCrawfordGame: crawford,
      );
    }

    expect(base(),
        isNot(base(cube: const CubeState(value: 2, owner: Player.white))));
    expect(base(), isNot(base(crawford: true)));
    // resignOffer differs:
    expect(base().offerResign(ResignValue.single), isNot(base()));
    // result differs (drop ends the game):
    final dropped = base().offerDouble().drop();
    expect(dropped, isNot(base()));
    expect(dropped.result, isNotNull);
  });

  test('opening-roll ties are a FormatException at the JSON boundary', () {
    expect(
        () => GameEvent.fromJson(
            {'type': 'openingRoll', 'whiteDie': 2, 'blackDie': 2}),
        throwsFormatException);
  });
}
