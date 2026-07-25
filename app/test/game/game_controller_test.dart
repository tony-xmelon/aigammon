import 'dart:async';
import 'dart:math';

import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/game/dice_roller.dart';
import 'package:aigammon_app/game/game_controller.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// One captured [MatchPersistence.onGameFinished] call.
class RecordedGame {
  RecordedGame(this.gameNumber, this.isCrawford, this.events, this.result,
      this.matchAfter);
  final int gameNumber;
  final bool isCrawford;
  final List<GameEvent> events;
  final GameResult result;
  final MatchState matchAfter;
}

/// A [MatchPersistence] that records every hook call. When [throwOnGame] is set
/// it throws from [onGameFinished] to exercise the non-fatal error path.
class RecordingPersistence implements MatchPersistence {
  RecordingPersistence({this.throwOnGame = false});

  final bool throwOnGame;
  final List<RecordedGame> games = [];
  final List<MatchState> finishedMatches = [];

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {
    games.add(
        RecordedGame(gameNumber, isCrawford, events, result, matchAfter));
    if (throwOnGame) throw StateError('persistence boom');
  }

  @override
  Future<void> onMatchFinished(MatchState finalState) async {
    finishedMatches.add(finalState);
  }
}

/// Deterministic dice: a fixed opening and an infinitely-cycling roll list.
class ScriptedDiceRoller implements DiceRoller {
  ScriptedDiceRoller(this._opening, this._rolls);
  final Dice _opening;
  final List<Dice> _rolls;
  int _i = 0;

  @override
  Dice roll() => _rolls[_i++ % _rolls.length];

  @override
  Dice rollOpening() => _opening;
}

/// A scriptable [PlayerAgent]. Moves default to the first legal play (fakes
/// cannot evaluate positions); cube/resign/double answers are configurable.
class FakeAgent implements PlayerAgent {
  FakeAgent({
    this.wantsDoublePrompts = true,
    this.doubles = false,
    this.cubeResponse = CubeAction.take,
    this.acceptsResign = true,
  });

  @override
  final bool wantsDoublePrompts;
  bool doubles;
  CubeAction cubeResponse;
  bool acceptsResign;

  int disposeCount = 0;
  int chooseMoveCalls = 0;

  @override
  Future<Move> chooseMove(GameState state) async {
    chooseMoveCalls++;
    final legal = state.legalMoves;
    return legal.isEmpty ? Move.none : legal.first;
  }

  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) async =>
      doubles;

  @override
  Future<CubeAction> chooseCubeResponse(
          GameState state, MatchContext ctx) async =>
      cubeResponse;

  @override
  Future<bool> chooseResignResponse(
          GameState state, ResignValue value, MatchContext ctx) async =>
      acceptsResign;

  @override
  void dispose() => disposeCount++;
}

/// An agent whose [chooseMove] never completes — for cancellation tests.
class HangingAgent implements PlayerAgent {
  final Completer<Move> _never = Completer<Move>();
  int disposeCount = 0;

  @override
  bool get wantsDoublePrompts => true;

  @override
  Future<Move> chooseMove(GameState state) => _never.future;

  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) =>
      _never.future.then((_) => false);

  @override
  Future<CubeAction> chooseCubeResponse(GameState state, MatchContext ctx) =>
      _never.future.then((_) => CubeAction.take);

  @override
  Future<bool> chooseResignResponse(
          GameState state, ResignValue value, MatchContext ctx) =>
      _never.future.then((_) => true);

  @override
  void dispose() => disposeCount++;
}

/// An agent whose [chooseMove] throws — for error-path tests.
class ThrowingAgent implements PlayerAgent {
  int disposeCount = 0;

  @override
  bool get wantsDoublePrompts => true;

  @override
  Future<Move> chooseMove(GameState state) async =>
      throw StateError('boom from agent');

  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) async => false;

  @override
  Future<CubeAction> chooseCubeResponse(
          GameState state, MatchContext ctx) async =>
      CubeAction.take;

  @override
  Future<bool> chooseResignResponse(
          GameState state, ResignValue value, MatchContext ctx) async =>
      true;

  @override
  void dispose() => disposeCount++;
}

/// An agent that records the [MatchContext] handed to each [considerDouble],
/// and always offers a double (so a game ends immediately when the opponent
/// drops — letting a test advance the match score deterministically).
class RecordingAgent implements PlayerAgent {
  final List<MatchContext> doubleContexts = [];

  @override
  bool get wantsDoublePrompts => true;

  @override
  Future<Move> chooseMove(GameState state) async {
    final legal = state.legalMoves;
    return legal.isEmpty ? Move.none : legal.first;
  }

  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) async {
    doubleContexts.add(ctx);
    return true;
  }

  @override
  Future<CubeAction> chooseCubeResponse(
          GameState state, MatchContext ctx) async =>
      CubeAction.take;

  @override
  Future<bool> chooseResignResponse(
          GameState state, ResignValue value, MatchContext ctx) async =>
      true;

  @override
  void dispose() {}
}

/// Completes once [predicate] holds, polling on every notification from [c].
/// The caller owns the running `playMatch` future.
Future<void> waitFor(
  GameController c,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final done = Completer<void>();
  void check() {
    if (!done.isCompleted && predicate()) done.complete();
  }

  c.addListener(check);
  check();
  await done.future.timeout(timeout);
  c.removeListener(check);
}

void main() {
  group('full match to 1 point', () {
    test('single game decides the match; scores match the result', () async {
      final white = FakeAgent();
      final black = FakeAgent();
      final c = GameController(
        white: white,
        black: black,
        matchLength: 1,
        diceRoller: DiceRoller(Random(7)),
      );

      var everAwaitedNextGame = false;
      c.addListener(() {
        if (c.awaitingNextGame) everAwaitedNextGame = true;
      });

      await c.playMatch();

      expect(c.matchOver, isTrue);
      expect(c.match.isMatchOver, isTrue);
      expect(c.state.phase, GamePhase.gameOver);

      final result = c.state.result!;
      expect(c.match.winner, result.winner);
      final total = c.match.whiteScore + c.match.blackScore;
      expect(total, result.points);
      expect(total, greaterThanOrEqualTo(1));
      expect(everAwaitedNextGame, isFalse,
          reason: 'a 1-point match ends after its single game');
      expect(c.isThinking, isFalse);
      expect(c.error, isNull);

      c.disposeController();
      expect(white.disposeCount, 1);
      expect(black.disposeCount, 1);
    });
  });

  group('multi-game match', () {
    test('pauses between games and preserves the Crawford invariant',
        () async {
      final white = FakeAgent();
      final black = FakeAgent();
      final c = GameController(
        white: white,
        black: black,
        matchLength: 4,
        diceRoller: DiceRoller(Random(3)),
      );

      // Invariant: each freshly-started game's isCrawfordGame equals the
      // match's isCrawfordNext at the moment it began.
      final violations = <String>[];
      var sawSecondGame = false;
      var pauseCount = 0;
      Game? lastGame = c.game;
      bool? expectedCrawfordForNextGame;

      c.addListener(() {
        if (!identical(c.game, lastGame)) {
          lastGame = c.game;
          if (c.game.events.length == 1 && expectedCrawfordForNextGame != null) {
            sawSecondGame = true;
            if (c.game.state.isCrawfordGame != expectedCrawfordForNextGame) {
              violations.add(
                  'game crawford=${c.game.state.isCrawfordGame} '
                  'expected=$expectedCrawfordForNextGame');
            }
            expectedCrawfordForNextGame = null;
          }
        }
        if (c.awaitingNextGame && expectedCrawfordForNextGame == null) {
          pauseCount++;
          expectedCrawfordForNextGame = c.match.isCrawfordNext;
          c.continueToNextGame();
        }
      });

      await c.playMatch();

      expect(c.matchOver, isTrue);
      expect(sawSecondGame, isTrue, reason: 'match spanned multiple games');
      expect(pauseCount, greaterThanOrEqualTo(1));
      expect(violations, isEmpty);

      c.disposeController();
    });
  });

  group('doubling cube', () {
    test('double then take: cube becomes 2 owned by the taker', () async {
      final white = FakeAgent(wantsDoublePrompts: true, doubles: true);
      final black = FakeAgent(
        wantsDoublePrompts: true,
        doubles: false,
        cubeResponse: CubeAction.take,
      );
      final c = GameController(
        white: white,
        black: black,
        matchLength: 5,
        // White wins the opening (6 > 1) and later doubles pre-roll.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      final matchFuture = c.playMatch();
      await waitFor(
          c, () => c.state.cube.value == 2 && c.state.cube.owner == Player.black);

      expect(c.state.cube.value, 2);
      expect(c.state.cube.owner, Player.black);
      expect(c.state.phase, isNot(GamePhase.gameOver));

      c.disposeController();
      await matchFuture;
    });

    test('double then drop: game ends at the pre-double stake', () async {
      final white = FakeAgent(wantsDoublePrompts: true, doubles: true);
      final black = FakeAgent(
        wantsDoublePrompts: true,
        doubles: false,
        cubeResponse: CubeAction.drop,
      );
      final c = GameController(
        white: white,
        black: black,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      final matchFuture = c.playMatch();
      await waitFor(c, () => c.awaitingNextGame);

      final result = c.state.result!;
      expect(result.outcome, GameOutcome.drop);
      expect(result.winner, Player.white);
      expect(result.points, 1, reason: 'drop forfeits the pre-double stake');
      expect(c.match.whiteScore, 1);
      expect(c.match.blackScore, 0);
      expect(c.matchOver, isFalse);

      c.disposeController();
      await matchFuture;
    });
  });

  group('cubeless match', () {
    test('a doubling AI never offers a double; the cube stays at 1', () async {
      // Both AIs would double at every opportunity, but the cube is off.
      final white = FakeAgent(wantsDoublePrompts: true, doubles: true);
      final black = FakeAgent(wantsDoublePrompts: true, doubles: true);
      final c = GameController(
        white: white,
        black: black,
        matchLength: 1,
        cubeless: true,
        diceRoller: DiceRoller(Random(7)),
      );

      await c.playMatch();

      expect(c.matchOver, isTrue);
      // No DoubleEvent was ever produced across the whole match.
      expect(c.game.events.whereType<DoubleEvent>(), isEmpty);
      expect(c.state.cube.value, 1, reason: 'the cube never left 1');
      expect(c.error, isNull);

      c.disposeController();
    });

    test('reports cubeless; a human offerDouble throws at the gate', () async {
      final human = LocalHumanAgent();
      final black = FakeAgent();
      final c = GameController(
        white: human,
        black: black,
        matchLength: 5,
        cubeless: true,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(6, 5), Dice(4, 3)]),
      );
      expect(c.cubeless, isTrue);

      final matchFuture = c.playMatch();
      await waitFor(
          c, () => c.awaitingHumanTurn && c.state.turn == Player.white);

      // Doubling is never legal in a cubeless match, so the verb throws even
      // with the gate open.
      expect(() => c.offerDouble(), throwsStateError);
      expect(c.game.events.whereType<DoubleEvent>(), isEmpty);

      c.disposeController();
      await matchFuture;
    });

    test('default match is NOT cubeless', () {
      final c = GameController(
        white: FakeAgent(),
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(6, 5)]),
      );
      expect(c.cubeless, isFalse);
      c.disposeController();
    });
  });

  group('human pre-roll verbs', () {
    test('offerDouble appends a DoubleEvent the opponent takes', () async {
      final human = LocalHumanAgent();
      final black = FakeAgent(cubeResponse: CubeAction.take);
      final c = GameController(
        white: human,
        black: black,
        matchLength: 5,
        // Black wins the opening (6 > 1) and moves; white then reaches its
        // pre-roll gate as its first action.
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(6, 5), Dice(4, 3)]),
      );

      final matchFuture = c.playMatch();
      await waitFor(
          c, () => c.awaitingHumanTurn && c.state.turn == Player.white);
      expect(c.state.turn, Player.white);

      c.offerDouble();

      await waitFor(
          c, () => c.state.cube.value == 2 && c.state.cube.owner == Player.black);
      expect(c.state.cube.owner, Player.black);
      expect(c.game.events.whereType<DoubleEvent>().length, 1);

      c.disposeController();
      await matchFuture;
    });

    test('offerResign the opponent accepts ends the game', () async {
      final human = LocalHumanAgent();
      final black = FakeAgent(acceptsResign: true);
      final c = GameController(
        white: human,
        black: black,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(6, 5), Dice(4, 3)]),
      );

      final matchFuture = c.playMatch();
      await waitFor(
          c, () => c.awaitingHumanTurn && c.state.turn == Player.white);

      c.offerResign(ResignValue.single);

      await waitFor(c, () => c.awaitingNextGame);

      final result = c.state.result!;
      expect(result.outcome, GameOutcome.resignation);
      expect(result.winner, Player.black,
          reason: 'white resigned, so black wins');
      expect(result.points, 1);
      expect(c.match.blackScore, 1);

      c.disposeController();
      await matchFuture;
    });

    test('pre-roll verbs throw when no human turn is open', () {
      final human = LocalHumanAgent();
      final black = FakeAgent();
      final c = GameController(
        white: human,
        black: black,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(6, 5)]),
      );
      // playMatch not started: no gate is open yet.
      expect(() => c.rollDice(), throwsStateError);
      expect(() => c.offerDouble(), throwsStateError);
      expect(() => c.offerResign(ResignValue.single), throwsStateError);
      c.disposeController();
    });
  });

  group('cancellation', () {
    test('disposeController stops a stuck loop promptly, disposing agents once',
        () async {
      final white = HangingAgent();
      final black = FakeAgent();
      final c = GameController(
        white: white,
        black: black,
        matchLength: 1,
        // White opens (6 > 1) and hangs in chooseMove.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5)]),
      );

      final matchFuture = c.playMatch();
      await pumpEventQueue();
      expect(c.isThinking, isTrue, reason: 'parked awaiting the stuck agent');

      c.disposeController();
      await matchFuture.timeout(const Duration(milliseconds: 100));

      expect(white.disposeCount, 1);
      expect(black.disposeCount, 1);
    });
  });

  group('error path', () {
    test('an agent throwing stops the loop and records the error', () async {
      final white = ThrowingAgent();
      final black = FakeAgent();
      final c = GameController(
        white: white,
        black: black,
        matchLength: 1,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5)]),
      );

      await c.playMatch();

      expect(c.error, isNotNull);
      expect(c.isThinking, isFalse);
      expect(c.game.events.length, 1,
          reason: 'only the opening roll; no event after the throw');

      c.disposeController();
    });
  });

  group('isThinking', () {
    test('toggles true then false around agent decisions', () async {
      final white = FakeAgent();
      final black = FakeAgent();
      final c = GameController(
        white: white,
        black: black,
        matchLength: 1,
        diceRoller: DiceRoller(Random(5)),
      );

      final observed = <bool>{};
      c.addListener(() => observed.add(c.isThinking));

      await c.playMatch();

      expect(observed.contains(true), isTrue,
          reason: 'thinking flag was raised during agent awaits');
      expect(observed.contains(false), isTrue);
      expect(c.isThinking, isFalse, reason: 'settled after the match');

      c.disposeController();
    });
  });

  group('match context', () {
    test('contextFor anchors moverAway to the actor at the start of a match',
        () async {
      final c = GameController(
        white: FakeAgent(),
        black: FakeAgent(),
        matchLength: 5,
      );
      final white = c.contextFor(Player.white);
      expect(white.moverAway, 5, reason: 'white 0-0, 5-away');
      expect(white.opponentAway, 5);
      expect(white.crawfordPlayed, isFalse);

      final black = c.contextFor(Player.black);
      expect(black.moverAway, 5);
      expect(black.opponentAway, 5);

      c.disposeController();
    });

    test('passes each actor its own aways (white 2-away after leading 1-0)',
        () async {
      // 3-point match. White opens every game (6 > 1) and doubles at once;
      // black drops, so white banks 1 point per game. In game 2 white leads
      // 1-0, so white is 2-away and black 3-away — the ctx handed to white's
      // considerDouble must reflect that.
      final white = RecordingAgent();
      final black = FakeAgent(cubeResponse: CubeAction.drop);
      final c = GameController(
        white: white,
        black: black,
        matchLength: 3,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      // Auto-advance past the between-games pause so game 2 begins.
      c.addListener(() {
        if (c.awaitingNextGame) c.continueToNextGame();
      });

      final matchFuture = c.playMatch();
      // Wait until white has been asked to double in the SECOND game.
      await waitFor(c, () => white.doubleContexts.length >= 2);

      final game1 = white.doubleContexts[0];
      expect(game1.moverAway, 3, reason: 'game 1: white 0-0, 3-away');
      expect(game1.opponentAway, 3);
      expect(game1.crawfordPlayed, isFalse);

      final game2 = white.doubleContexts[1];
      expect(game2.moverAway, 2, reason: 'game 2: white leads 1-0, 2-away');
      expect(game2.opponentAway, 3, reason: 'black still 0, 3-away');
      expect(game2.crawfordPlayed, isFalse);

      c.disposeController();
      await matchFuture;
    });
  });

  group('persistence hooks', () {
    test('onGameFinished (once, game 1) and onMatchFinished fire in a 1-point '
        'match', () async {
      final persistence = RecordingPersistence();
      final c = GameController(
        white: FakeAgent(),
        black: FakeAgent(),
        matchLength: 1,
        diceRoller: DiceRoller(Random(7)),
        persistence: persistence,
      );

      await c.playMatch();

      expect(c.matchOver, isTrue);
      expect(persistence.games, hasLength(1),
          reason: 'a 1-point match records exactly one game');
      final recorded = persistence.games.single;
      expect(recorded.gameNumber, 1);
      expect(recorded.isCrawford, isTrue,
          reason: 'the only game of a 1-point match is the Crawford game');
      expect(recorded.result, c.state.result);
      expect(recorded.events, c.game.events);
      expect(recorded.matchAfter, c.match);

      expect(persistence.finishedMatches, hasLength(1));
      expect(persistence.finishedMatches.single, c.match);
      expect(c.persistenceError, isNull);
      expect(c.error, isNull);

      c.disposeController();
    });

    test('a throwing persistence hook does not stop the match', () async {
      final persistence = RecordingPersistence(throwOnGame: true);
      final c = GameController(
        white: FakeAgent(),
        black: FakeAgent(),
        matchLength: 1,
        diceRoller: DiceRoller(Random(7)),
        persistence: persistence,
      );

      await c.playMatch();

      // The match still completes despite the storage layer throwing.
      expect(c.matchOver, isTrue);
      expect(c.match.isMatchOver, isTrue);
      expect(c.error, isNull, reason: 'a persistence throw is not a loop error');
      expect(c.persistenceError, isNotNull);
      expect(c.persistenceError, isA<StateError>());

      c.disposeController();
    });
  });
}
