import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  final events = <GameEvent>[
    const OpeningRollEvent(whiteDie: 3, blackDie: 1),
    MoveEvent(Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
    const RollEvent(Player.black, 6, 5),
    MoveEvent(
        Player.black, Move(const [CheckerMove(0, 6), CheckerMove(6, 11)])),
  ];

  test('replay folds events into the expected state', () {
    final game = Game.replay(events);
    expect(game.state.turn, Player.white);
    expect(game.state.phase, GamePhase.awaitingRoll);
    expect(game.state.board.points[4], 2);
    // Black's leaping checker joins the 5 already on White's 12-point.
    expect(game.state.board.points[11], -6);
  });

  test('illegal events throw during replay', () {
    expect(
      () => Game.replay([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        const RollEvent(Player.white, 6, 5), // must move first, not roll
      ]),
      throwsStateError,
    );
  });

  test('opening tie is rejected', () {
    expect(() => const OpeningRollEvent(whiteDie: 2, blackDie: 2).validate(),
        throwsArgumentError);
  });

  test('every event survives a JSON round-trip', () {
    final all = <GameEvent>[
      ...events,
      const DoubleEvent(Player.white),
      const TakeEvent(Player.black),
      const DropEvent(Player.black),
      const ResignOfferEvent(Player.white, ResignValue.gammon),
      const ResignAcceptEvent(Player.black),
      const ResignDeclineEvent(Player.black),
    ];
    for (final e in all) {
      final back = GameEvent.fromJson(e.toJson());
      expect(back, e, reason: 'round-trip failed for ${e.runtimeType}');
    }
  });

  test('cube events replay', () {
    final game = Game.replay([
      const OpeningRollEvent(whiteDie: 3, blackDie: 1),
      MoveEvent(
          Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
      const DoubleEvent(Player.black),
      const TakeEvent(Player.white),
    ]);
    expect(game.state.cube, const CubeState(value: 2, owner: Player.white));
    expect(game.state.turn, Player.black);
  });
}
