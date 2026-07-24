import 'dart:convert';

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

  test('fromJson throws FormatException on malformed input', () {
    expect(
        () => GameEvent.fromJson({'type': 'teleport'}), throwsFormatException);
    expect(() => GameEvent.fromJson({'type': 'roll', 'die1': 3, 'die2': 1}),
        throwsFormatException); // missing player
    expect(
        () => GameEvent.fromJson({
              'type': 'move',
              'player': 'white',
              'move': [
                [7]
              ]
            }),
        throwsFormatException); // malformed hop triple
    expect(() => GameEvent.fromJson({}), throwsFormatException);
  });

  test('events survive a real jsonEncode/jsonDecode round-trip', () {
    final original = MoveEvent(Player.white,
        Move(const [CheckerMove(7, 4, isHit: true), CheckerMove(5, 4)]));
    final wire = jsonDecode(jsonEncode(original.toJson()));
    final back = GameEvent.fromJson((wire as Map).cast<String, dynamic>());
    expect(back, original);
    // isHit must survive the wire even though == ignores it:
    expect((back as MoveEvent).move.checkerMoves.first.isHit, isTrue);
  });

  test('events by the wrong player are rejected at replay', () {
    expect(
      () => Game.replay([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.black, // white is on turn
            Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
      ]),
      throwsStateError,
    );
  });

  test('append does not expose a mutable event log', () {
    final game = Game.replay([const OpeningRollEvent(whiteDie: 3, blackDie: 1)])
        .append(MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])));
    expect(() => game.events.add(const DoubleEvent(Player.black)),
        throwsUnsupportedError);
  });
}
