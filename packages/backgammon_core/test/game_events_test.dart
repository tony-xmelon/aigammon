import 'dart:convert';
import 'dart:math';

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

  test('walking a log with applyEvent equals replaying every prefix', () {
    // The equivalence the game screen's incremental assessment cache rests on:
    // carrying one running state forward must land, at EVERY prefix, on
    // exactly the state a from-scratch `Game.replay` of that prefix produces.
    // A random game supplies the log, so rolls, moves, doubles and takes all
    // pass through.
    final rng = Random(20260731);
    Dice roll() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);
    var opening = roll();
    while (opening.isDouble) {
      opening = roll();
    }
    final log = <GameEvent>[
      OpeningRollEvent(whiteDie: opening.die1, blackDie: opening.die2),
    ];
    var game = Game.replay(log);
    var turns = 0;
    while (game.state.phase != GamePhase.gameOver && turns < 300) {
      turns++;
      final s = game.state;
      switch (s.phase) {
        case GamePhase.awaitingRoll:
          final canDouble = s.cube.owner == null || s.cube.owner == s.turn;
          if (canDouble && s.cube.value < 8 && rng.nextInt(15) == 0) {
            log.add(DoubleEvent(s.turn));
          } else {
            final d = roll();
            log.add(RollEvent(s.turn, d.die1, d.die2));
          }
        case GamePhase.moving:
          final legal = s.legalMoves;
          log.add(MoveEvent(s.turn,
              legal.isEmpty ? Move.none : legal[rng.nextInt(legal.length)]));
        case GamePhase.cubeOffered:
          log.add(rng.nextInt(5) == 0
              ? DropEvent(s.turn)
              : TakeEvent(s.turn));
        case GamePhase.resignOffered:
        case GamePhase.gameOver:
          fail('unexpected phase ${s.phase}');
      }
      game = Game.replay(log);
    }
    expect(log.length, greaterThan(20), reason: 'the probe actually ran');

    // The incremental walk, checked against the replay oracle at every prefix.
    var running = Game.replay(log.sublist(0, 1)).state;
    for (var i = 1; i < log.length; i++) {
      expect(running, Game.replay(log.sublist(0, i)).state,
          reason: 'running state diverged before event $i');
      running = Game.applyEvent(running, log[i]);
    }
    expect(running, Game.replay(log).state);
  });

  test('applyEvent refuses what replay refuses', () {
    final start = Game.replay(events).state;
    // Out of turn.
    expect(
        () => Game.applyEvent(start, RollEvent(start.turn.opponent, 1, 2)),
        throwsStateError);
    // An opening roll can never be folded onto a running game.
    expect(
        () => Game.applyEvent(
            start, const OpeningRollEvent(whiteDie: 2, blackDie: 1)),
        throwsStateError);
  });

  test('append does not expose a mutable event log', () {
    final game = Game.replay([const OpeningRollEvent(whiteDie: 3, blackDie: 1)])
        .append(MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])));
    expect(() => game.events.add(const DoubleEvent(Player.black)),
        throwsUnsupportedError);
  });
}
