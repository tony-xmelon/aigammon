import 'dart:math';

import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/game/dice_roller.dart';
import 'package:aigammon_app/game/game_controller.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic dice: a fixed opening and a cycling roll list.
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

/// A scriptable AI: plays the first legal move; cube/resign/double configurable.
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

  @override
  Future<Move> chooseMove(GameState state) async {
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
  void dispose() {}
}

/// An agent whose [chooseMove] throws — for the error-banner test.
class ThrowingAgent implements PlayerAgent {
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
  void dispose() {}
}

// --- Widget-test helpers -----------------------------------------------------

const _surface = Size(900, 1300);

// Keyed by the controller so pumping a different controller into the same test
// remounts a fresh GameScreen State (re-running initState / playMatch).
Widget _harness(GameController c) => MaterialApp(
      home: GameScreen(key: ValueKey(c), controller: c),
    );

/// Pumps frames until [cond] holds (the controller loop advances on the
/// microtasks each pump flushes), failing if it never does.
Future<void> pumpUntil(
  WidgetTester t,
  bool Function() cond, {
  int maxFrames = 800,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (cond()) {
      await t.pump(); // flush the pending setState rebuild before asserting
      return;
    }
    await t.pump(const Duration(milliseconds: 1));
  }
  fail('condition not met after $maxFrames frames');
}

/// The board's painter (the only [BoardPainter] in the tree).
BoardPainter _painterOf(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .firstWhere((c) => c.painter is BoardPainter)
    .painter as BoardPainter;

/// The global rect of the board's paint surface.
Rect _boardRect(WidgetTester t) => t.getRect(
    find.byWidgetPredicate((w) => w is CustomPaint && w.painter is BoardPainter));

Future<void> _tapPoint(WidgetTester t, int index) async {
  final r = _boardRect(t);
  final g = BoardGeometry(r.size, whiteAtBottom: true);
  await t.tapAt(r.topLeft + g.pointRect(index).center);
  await t.pump();
}

bool _enabled(WidgetTester t, Finder f) {
  final w = t.widget(f);
  return w is ButtonStyleButton && w.onPressed != null;
}

/// Drives the interactive board greedily (first highlighted source → first
/// destination) until Confirm is enabled, then commits.
Future<void> _commitFirstMove(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    final confirm = find.widgetWithText(FilledButton, 'Confirm');
    if (confirm.evaluate().isNotEmpty && _enabled(t, confirm)) break;
    final pass = find.text('No moves — pass');
    if (pass.evaluate().isNotEmpty) {
      await t.tap(pass);
      await t.pump();
      return;
    }
    final src = _painterOf(t).highlightedSources.first;
    await _tapPoint(t, src);
    final dst = _painterOf(t).highlightedDestinations.first;
    await _tapPoint(t, dst);
  }
  await t.tap(find.widgetWithText(FilledButton, 'Confirm'));
  await t.pump();
}

Future<void> _dismissPassDevice(WidgetTester t) async {
  final overlay = find.text('Pass the device');
  if (overlay.evaluate().isNotEmpty) {
    await t.tap(find.text('Tap to continue'));
    await t.pump();
  }
}

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('human vs AI: Roll → interactive board → commit advances',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final human = LocalHumanAgent();
    final ai = FakeAgent();
    final c = GameController(
      white: human,
      black: ai,
      matchLength: 5,
      // Black wins the opening (6 > 1) and moves; White then reaches its
      // pre-roll gate as its first action.
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );

    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.awaitingHumanTurn);

    // The pre-roll action bar offers Roll.
    final roll = find.widgetWithText(FilledButton, 'Roll');
    expect(roll, findsOneWidget);
    await t.tap(roll);
    await t.pump();

    // Once White rolls, its move request fires and the board becomes interactive.
    await pumpUntil(t, () => human.pendingMoveRequest.value != null);
    expect(_painterOf(t).highlightedSources, isNotEmpty);

    final before = c.state;
    await _commitFirstMove(t);
    await pumpUntil(t, () => c.state != before);
    expect(c.state, isNot(before), reason: 'committing the move advanced state');

    c.disposeController();
  });

  testWidgets('Double button: enabled when legal, disabled in Crawford',
      (t) async {
    // Non-Crawford (matchLength 5): Double is enabled at the human pre-roll.
    final human = LocalHumanAgent();
    final c = GameController(
      white: human,
      black: FakeAgent(),
      matchLength: 5,
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );
    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.awaitingHumanTurn);
    expect(c.state.isCrawfordGame, isFalse);
    final dbl = find.widgetWithText(OutlinedButton, 'Double');
    expect(_enabled(t, dbl), isTrue);
    c.disposeController();

    // A 1-point match's only game is the Crawford game: Double is disabled.
    final human2 = LocalHumanAgent();
    final c2 = GameController(
      white: human2,
      black: FakeAgent(),
      matchLength: 1,
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );
    await t.pumpWidget(_harness(c2));
    await pumpUntil(t, () => c2.awaitingHumanTurn);
    expect(c2.state.isCrawfordGame, isTrue);
    final dbl2 = find.widgetWithText(OutlinedButton, 'Double');
    expect(_enabled(t, dbl2), isFalse);
    c2.disposeController();
  });

  testWidgets('cube-offer dialog: Take submits and the cube proceeds',
      (t) async {
    final human = LocalHumanAgent();
    final ai = FakeAgent(doubles: true);
    final c = GameController(
      white: human,
      black: ai,
      matchLength: 5,
      // White wins the opening (6 > 1) and moves; Black then doubles pre-roll.
      diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
    );

    await t.pumpWidget(_harness(c));
    // Drive White's opening move programmatically (not under test here).
    await pumpUntil(t, () => human.pendingMoveRequest.value != null);
    human.submitMove(c.state.legalMoves.first);

    // Black doubles → White is asked to respond.
    await pumpUntil(t, () => human.pendingCubeRequest.value != null);
    expect(find.textContaining('offers a double'), findsOneWidget);

    await t.tap(find.widgetWithText(FilledButton, 'Take'));
    await pumpUntil(t, () => c.state.cube.value == 2);
    expect(c.state.cube.value, 2);
    expect(c.state.cube.owner, Player.white);

    c.disposeController();
  });

  testWidgets('resign-offer dialog: Accept ends the game (hot-seat)', (t) async {
    final white = LocalHumanAgent();
    final black = LocalHumanAgent();
    final c = GameController(
      white: white,
      black: black,
      matchLength: 5,
      // White wins the opening (6 > 1) and moves; Black then reaches its gate.
      diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
    );

    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => white.pendingMoveRequest.value != null);
    white.submitMove(c.state.legalMoves.first);

    // Black's turn opens behind a pass-device overlay; dismiss then offer resign.
    await pumpUntil(
        t, () => c.awaitingHumanTurn && c.state.turn == Player.black);
    await _dismissPassDevice(t);
    c.offerResign(ResignValue.gammon);

    // White is asked to respond (behind its own pass-device overlay).
    await pumpUntil(t, () => white.pendingResignRequest.value != null);
    await _dismissPassDevice(t);
    expect(find.textContaining('resign a gammon'), findsOneWidget);

    await t.tap(find.widgetWithText(FilledButton, 'Accept'));
    await pumpUntil(t, () => c.awaitingNextGame);
    final result = c.state.result!;
    expect(result.outcome, GameOutcome.resignation);
    expect(result.winner, Player.white, reason: 'Black resigned, White wins');
    expect(result.points, 2, reason: 'cube 1 × gammon 2');

    c.disposeController();
  });

  testWidgets('game-end dialog shows the score; Next game continues', (t) async {
    final c = GameController(
      white: FakeAgent(),
      black: FakeAgent(),
      matchLength: 7, // long enough that one game never ends the match
      diceRoller: DiceRoller(Random(7)),
    );

    await t.pumpWidget(_harness(c));
    await t.pumpAndSettle();
    expect(c.awaitingNextGame, isTrue);

    expect(find.text('Game over'), findsOneWidget);
    final result = c.state.result!;
    // The dialog reports the winner's points and the updated match score line.
    expect(find.textContaining('wins ${result.points}'), findsOneWidget);
    expect(find.textContaining('White ${c.match.whiteScore} —'), findsWidgets);

    final g1 = c.game;
    await t.tap(find.widgetWithText(FilledButton, 'Next game'));
    await pumpUntil(t, () => !identical(c.game, g1));
    expect(identical(c.game, g1), isFalse, reason: 'a new game began');

    c.disposeController();
  });

  testWidgets('match-end dialog; Done pops the screen', (t) async {
    final c = GameController(
      white: FakeAgent(),
      black: FakeAgent(),
      matchLength: 1, // decided by a single game
      diceRoller: DiceRoller(Random(7)),
    );

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(builder: (_) => GameScreen(controller: c)),
              ),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('start'));
    await t.pumpAndSettle();

    expect(c.matchOver, isTrue);
    expect(find.text('Match over'), findsOneWidget);

    await t.tap(find.widgetWithText(FilledButton, 'Done'));
    await t.pumpAndSettle();
    expect(find.byType(GameScreen), findsNothing);
  });

  group('pass-device overlay', () {
    testWidgets('hot-seat: absent on the first turn, present on actor change',
        (t) async {
      final white = LocalHumanAgent();
      final black = LocalHumanAgent();
      final c = GameController(
        white: white,
        black: black,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => white.pendingMoveRequest.value != null);
      // First turn of the match: no overlay.
      expect(find.text('Pass the device'), findsNothing);

      white.submitMove(c.state.legalMoves.first);
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.black);
      // Actor changed White → Black: overlay gates the reveal.
      expect(find.text('Pass the device'), findsOneWidget);
      expect(find.textContaining("Black's turn"), findsOneWidget);

      c.disposeController();
    });

    testWidgets('vs AI: never appears', (t) async {
      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      human.submitMove(c.state.legalMoves.first);
      // Play returns to the human's pre-roll gate after the AI's turn; no
      // overlay ever shows in a vs-AI game.
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.white,
          maxFrames: 1200);
      expect(find.text('Pass the device'), findsNothing);

      c.disposeController();
    });
  });

  testWidgets('error banner surfaces controller.error', (t) async {
    final c = GameController(
      white: ThrowingAgent(),
      black: FakeAgent(),
      matchLength: 1,
      diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5)]),
    );

    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.error != null);
    await t.pump();
    expect(find.textContaining('boom from agent'), findsOneWidget);

    c.disposeController();
  });

  testWidgets('identical-state rebuild preserves in-progress move entry',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final human = LocalHumanAgent();
    final c = GameController(
      white: human,
      black: FakeAgent(),
      matchLength: 5,
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );

    // A ValueNotifier-driven wrapper lets us force a GameScreen rebuild with the
    // controller's state unchanged — the same rebuild a no-op controller
    // notification (e.g. an isThinking flicker) would trigger in production.
    final rebuild = ValueNotifier(0);
    await t.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: rebuild,
        builder: (_, _, _) => GameScreen(controller: c),
      ),
    ));

    await pumpUntil(t, () => c.awaitingHumanTurn);
    await t.tap(find.widgetWithText(FilledButton, 'Roll'));
    await pumpUntil(t, () => human.pendingMoveRequest.value != null);

    // Enter a single hop: the preview board now diverges from the game board.
    final src = _painterOf(t).highlightedSources.first;
    await _tapPoint(t, src);
    final dst = _painterOf(t).highlightedDestinations.first;
    await _tapPoint(t, dst);
    expect(_painterOf(t).board, isNot(c.state.board));

    // Force a same-state rebuild of GameScreen; the in-progress entry survives.
    rebuild.value++;
    await t.pump();
    expect(_painterOf(t).board, isNot(c.state.board),
        reason: 'identical-state rebuild kept the entered hop');

    c.disposeController();
  });
}
