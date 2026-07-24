import 'dart:async';
import 'dart:math';

import 'package:aigammon_app/game/dice_roller.dart';
import 'package:aigammon_app/game/game_controller.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<bool> considerDouble(GameState state) async => doubles;

  @override
  Future<CubeAction> chooseCubeResponse(GameState state) async => cubeResponse;

  @override
  Future<bool> chooseResignResponse(GameState state, ResignValue value) async =>
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
  Future<bool> considerDouble(GameState state) => _never.future.then((_) => false);

  @override
  Future<CubeAction> chooseCubeResponse(GameState state) =>
      _never.future.then((_) => CubeAction.take);

  @override
  Future<bool> chooseResignResponse(GameState state, ResignValue value) =>
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
  Future<bool> considerDouble(GameState state) async => false;

  @override
  Future<CubeAction> chooseCubeResponse(GameState state) async =>
      CubeAction.take;

  @override
  Future<bool> chooseResignResponse(GameState state, ResignValue value) async =>
      true;

  @override
  void dispose() => disposeCount++;
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
}
