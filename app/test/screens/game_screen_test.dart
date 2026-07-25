import 'dart:math';

import 'package:aigammon_app/game/dice_roller.dart';
import 'package:aigammon_app/game/game_controller.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:aigammon_app/tutor/tutor_service.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/board_driving.dart';

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
  void dispose() {}
}

/// A canned [EngineFacade] for the tutor: it ranks a synthetic BEST play above
/// every real legal move (all at a fixed lower equity), so whatever the human
/// commits resolves to a second-best entry — a known `error`-band loss of
/// `0.10 - 0.04 = 0.06`. [evalProbs] drives the cube advice (default gammonful:
/// 5a/5a doubles & takes).
class TutorEngine implements EngineFacade {
  TutorEngine({this.evalProbs = _gammonful});

  final Probabilities evalProbs;

  static const _gammonful = Probabilities(
    win: 0.6,
    winGammon: 0.3,
    winBackgammon: 0.05,
    loseGammon: 0.1,
    loseBackgammon: 0.0,
  );

  static const _flat = Probabilities(
    win: 0.5,
    winGammon: 0,
    winBackgammon: 0,
    loseGammon: 0,
    loseBackgammon: 0,
  );

  // Equity e <-> gammonless win via win = (e + 1) / 2.
  static Probabilities _probsForEquity(double e) => Probabilities(
        win: (e + 1) / 2,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      );

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async =>
      evalProbs;

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    final legal = MoveGenerator.legalMoves(board, mover, dice);
    return [
      // A synthetic best (single arbitrary hop; never sameAs a full 2-hop play)
      // ranked above every real move at 0.04.
      ScoredMove(
        move: Move(const [CheckerMove(23, 20)]),
        probabilities: _probsForEquity(0.10),
      ),
      for (final move in legal)
        ScoredMove(move: move, probabilities: _probsForEquity(0.04)),
    ];
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      throw UnimplementedError();

  static Probabilities get flat => _flat;
}

/// Like [TutorEngine] for cube advice, but ranks the REAL legal moves (top =
/// `MoveGenerator.legalMoves(...).first`) so a hint row stages a genuine play.
class RealRankEngine implements EngineFacade {
  static const _flat = Probabilities(
    win: 0.5,
    winGammon: 0,
    winBackgammon: 0,
    loseGammon: 0,
    loseBackgammon: 0,
  );

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async => _flat;

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    final legal = MoveGenerator.legalMoves(board, mover, dice);
    return [
      for (final move in legal)
        ScoredMove(move: move, probabilities: _flat),
    ];
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      throw UnimplementedError();
}

// --- Widget-test helpers -----------------------------------------------------

const _surface = Size(900, 1300);

Widget _tutorHarness(GameController c, TutorService tutor) => MaterialApp(
      home: GameScreen(key: ValueKey(c), controller: c, tutor: tutor),
    );

// Keyed by the controller so pumping a different controller into the same test
// remounts a fresh GameScreen State (re-running initState / playMatch).
Widget _harness(GameController c) => MaterialApp(
      home: GameScreen(key: ValueKey(c), controller: c),
    );

Widget _harnessOriented(GameController c, BoardOrientationMode mode) =>
    MaterialApp(
      home: GameScreen(key: ValueKey(c), controller: c, orientation: mode),
    );

// pumpUntil, boardPainterOf, tapBoardPoint, isButtonEnabled, and commitFirstMove
// come from the shared board-driving helpers (test/helpers/board_driving.dart),
// reused by the desktop end-to-end integration test.

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
    expect(boardPainterOf(t).highlightedSources, isNotEmpty);

    final before = c.state;
    await commitFirstMove(t);
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
    expect(isButtonEnabled(t, dbl), isTrue);
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
    expect(isButtonEnabled(t, dbl2), isFalse);
    c2.disposeController();
  });

  testWidgets('header is a single compact row (score and Double aligned)',
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
    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.awaitingHumanTurn);

    // The compact single-line score ("… to 5") is present.
    final score = find.textContaining('to 5');
    expect(score, findsOneWidget);
    // Score, cube chip and Double all sit on one horizontal line: their vertical
    // centres coincide (a single row, not stacked rows).
    final scoreY = t.getCenter(score).dy;
    final doubleY =
        t.getCenter(find.widgetWithText(OutlinedButton, 'Double')).dy;
    expect((scoreY - doubleY).abs(), lessThan(32),
        reason: 'header is a single row');
    c.disposeController();
  });

  testWidgets('Resign lives behind the header overflow (⋮) menu', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final human = LocalHumanAgent();
    final c = GameController(
      white: human,
      black: FakeAgent(),
      matchLength: 5,
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );
    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.awaitingHumanTurn);

    // Resign entries are hidden until the overflow menu is opened.
    expect(find.text('Resign — gammon'), findsNothing);
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    expect(find.text('Resign — single'), findsOneWidget);
    expect(find.text('Resign — gammon'), findsOneWidget);
    expect(find.text('Resign — backgammon'), findsOneWidget);
    c.disposeController();
  });

  testWidgets('bottom action bar keeps a fixed 64px height across phases',
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
    await t.pumpWidget(_harness(c));
    final bar = find.byKey(const ValueKey('actionBar'));

    await pumpUntil(t, () => c.awaitingHumanTurn);
    expect(t.getSize(bar).height, 64, reason: 'pre-roll (Roll) phase');

    await t.tap(find.widgetWithText(FilledButton, 'Roll'));
    await pumpUntil(t, () => human.pendingMoveRequest.value != null);
    expect(t.getSize(bar).height, 64, reason: 'moving (Undo/Confirm) phase');

    c.disposeController();
  });

  testWidgets('Undo/Confirm in the bottom bar drive move entry', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final human = LocalHumanAgent();
    final c = GameController(
      white: human,
      black: FakeAgent(),
      matchLength: 5,
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );
    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.awaitingHumanTurn);
    await t.tap(find.widgetWithText(FilledButton, 'Roll'));
    await pumpUntil(t, () => human.pendingMoveRequest.value != null);

    // Before any hop: both entry controls are present but disabled.
    final undo = find.widgetWithText(TextButton, 'Undo');
    final confirm = find.widgetWithText(FilledButton, 'Confirm');
    expect(undo, findsOneWidget);
    expect(confirm, findsOneWidget);
    expect(isButtonEnabled(t, undo), isFalse);
    expect(isButtonEnabled(t, confirm), isFalse);

    // Enter one hop from the board: the preview diverges and Undo turns on.
    final src = boardPainterOf(t).highlightedSources.first;
    await tapBoardPoint(t, src);
    final dst = boardPainterOf(t).highlightedDestinations.first;
    await tapBoardPoint(t, dst);
    expect(boardPainterOf(t).board, isNot(c.state.board));
    expect(isButtonEnabled(t, undo), isTrue);

    // Undo from the bar reverts the preview to the base board.
    await t.tap(undo);
    await t.pump();
    expect(boardPainterOf(t).board, c.state.board);

    c.disposeController();
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

  group('board orientation', () {
    // A hot-seat controller: White wins the opening (6 > 1) and plays, after
    // which Black's turn opens behind the pass-device overlay.
    GameController hotSeat(LocalHumanAgent white, LocalHumanAgent black) =>
        GameController(
          white: white,
          black: black,
          matchLength: 5,
          diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
        );

    bool whiteAtBottom(WidgetTester t) =>
        boardPainterOf(t).geometry.whiteAtBottom;

    testWidgets('hot-seat followActive: flips to the active player, '
        'revealed after the overlay', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final white = LocalHumanAgent();
      final black = LocalHumanAgent();
      final c = hotSeat(white, black);

      await t.pumpWidget(
          _harnessOriented(c, BoardOrientationMode.followActive));
      await pumpUntil(t, () => white.pendingMoveRequest.value != null);
      // White is the active player: White at the bottom.
      expect(whiteAtBottom(t), isTrue);

      // White commits; Black's turn opens behind the pass-device overlay.
      await commitFirstMove(t);
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.black);
      expect(find.text('Pass the device'), findsOneWidget);

      // Tapping through the overlay reveals a board flipped to Black-at-bottom.
      await t.tap(find.text('Tap to continue'));
      await t.pump();
      expect(whiteAtBottom(t), isFalse);

      c.disposeController();
    });

    testWidgets('hot-seat fixedWhite (toggle off): White stays at the bottom',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final white = LocalHumanAgent();
      final black = LocalHumanAgent();
      final c = hotSeat(white, black);

      await t.pumpWidget(
          _harnessOriented(c, BoardOrientationMode.fixedWhite));
      await pumpUntil(t, () => white.pendingMoveRequest.value != null);
      expect(whiteAtBottom(t), isTrue);

      await commitFirstMove(t);
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.black);
      await t.tap(find.text('Tap to continue'));
      await t.pump();
      // Actor changed to Black, but the fixed mode never flips.
      expect(whiteAtBottom(t), isTrue);

      c.disposeController();
    });

    testWidgets('vs-AI fixedBlack (human plays Black): Black at bottom, '
        'never flips', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: FakeAgent(),
        black: human,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(
          _harnessOriented(c, BoardOrientationMode.fixedBlack));
      // Black at the bottom from the very first frame.
      expect(whiteAtBottom(t), isFalse);

      // White (AI) plays the opening; the human's pre-roll gate opens — still
      // Black-at-bottom, and no pass-device overlay in a vs-AI match.
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.black);
      expect(whiteAtBottom(t), isFalse);
      expect(find.text('Pass the device'), findsNothing);

      c.disposeController();
    });

    testWidgets('followActive: orientation is constant within a turn '
        '(no flip mid-turn)', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final white = LocalHumanAgent();
      final black = LocalHumanAgent();
      final c = hotSeat(white, black);

      await t.pumpWidget(
          _harnessOriented(c, BoardOrientationMode.followActive));
      await pumpUntil(t, () => white.pendingMoveRequest.value != null);

      // Advance to Black's turn and dismiss the overlay: Black now at bottom.
      await commitFirstMove(t);
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.black);
      await t.tap(find.text('Tap to continue'));
      await t.pump();
      expect(whiteAtBottom(t), isFalse, reason: 'Black is the active player');

      // Black rolls: the phase advances pre-roll → moving within the same turn.
      // No overlay is up, so the orientation must not change.
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => black.pendingMoveRequest.value != null);
      expect(find.text('Pass the device'), findsNothing);
      expect(whiteAtBottom(t), isFalse,
          reason: 'orientation is stable across intra-turn state changes');

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

  group('tutor UI', () {
    testWidgets('hint panel opens with the ranked top plays', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      // The Hint button is available during the human's move.
      final hint = find.widgetWithText(OutlinedButton, 'Hint');
      expect(hint, findsOneWidget);
      await t.tap(hint);
      await pumpUntil(t, () => find.text('Top plays').evaluate().isNotEmpty);

      // The panel lists the synthetic best (0.100) above the real plays (0.040).
      expect(find.text('Top plays'), findsOneWidget);
      expect(find.textContaining('0.100'), findsWidgets);
      expect(find.textContaining('0.040'), findsWidgets);

      c.disposeController();
    });

    testWidgets('tapping a hint row stages the play; Confirm commits it',
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
      final tutor = TutorService(RealRankEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      // The top hint is the first legal move (the engine ranks them in order).
      final s = c.state;
      final expected =
          MoveGenerator.legalMoves(s.board, s.turn, s.dice!).first;
      final baseBoard = boardPainterOf(t).board;

      await t.tap(find.widgetWithText(OutlinedButton, 'Hint'));
      await pumpUntil(t, () => find.text('Top plays').evaluate().isNotEmpty);

      // Tap the top row (the move text of the first-ranked play).
      await t.tap(find.text('$expected').first);
      await t.pump();

      // Panel closed and the play is STAGED: the preview diverges from the base
      // board, but nothing is committed yet (state is unchanged).
      expect(find.text('Top plays'), findsNothing);
      expect(boardPainterOf(t).board, isNot(baseBoard),
          reason: 'the hinted play should be staged on the board');
      expect(c.state, s, reason: 'staging must not commit');

      // Confirm commits the hinted move. (The loop then advances — the AI moves
      // next — so assert against White's own move event, not the latest event.)
      final confirm = find.widgetWithText(FilledButton, 'Confirm');
      expect(isButtonEnabled(t, confirm), isTrue);
      await t.tap(confirm);
      await pumpUntil(
          t,
          () => c.game.events
              .whereType<MoveEvent>()
              .any((e) => e.player == Player.white));
      final played = c.game.events
          .whereType<MoveEvent>()
          .firstWhere((e) => e.player == Player.white)
          .move;
      expect(played.sameAs(expected), isTrue,
          reason: 'committed $played should equal hinted $expected');

      c.disposeController();
    });

    testWidgets('assessment chip appears after a human move, not an AI move',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        // Black (AI) wins the opening (6 > 1) and moves first; White then plays.
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      // After the AI's opening move, the human reaches its gate — no chip for
      // the AI move.
      await pumpUntil(t, () => c.awaitingHumanTurn);
      expect(find.textContaining('Error'), findsNothing,
          reason: 'AI moves are not assessed');

      // White rolls and commits a (second-best) move: the chip lands.
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await commitFirstMove(t);
      await pumpUntil(t, () => find.textContaining('Error').evaluate().isNotEmpty);
      expect(find.textContaining('Error'), findsOneWidget);
      // 0.10 - 0.04 = 0.06 give-up.
      expect(find.textContaining('0.060'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('cube advice line shows at the gate when tutor on, absent off',
        (t) async {
      // Tutor ON: the "Tutor: Double" line appears at the human pre-roll gate.
      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      final tutor = TutorService(TutorEngine());
      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      await pumpUntil(
          t, () => find.textContaining('Tutor:').evaluate().isNotEmpty);
      expect(find.textContaining('Tutor: Double'), findsOneWidget);
      c.disposeController();

      // Tutor OFF: no advice line at the same gate.
      final human2 = LocalHumanAgent();
      final c2 = GameController(
        white: human2,
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      await t.pumpWidget(_harness(c2));
      await pumpUntil(t, () => c2.awaitingHumanTurn);
      expect(find.textContaining('Tutor:'), findsNothing);
      c2.disposeController();
    });

    testWidgets('cube-offer dialog shows the tutor take/pass line', (t) async {
      final human = LocalHumanAgent();
      final ai = FakeAgent(doubles: true);
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        // White wins the opening (6 > 1) and moves; Black then doubles pre-roll.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      human.submitMove(c.state.legalMoves.first);

      await pumpUntil(t, () => human.pendingCubeRequest.value != null);
      expect(find.textContaining('offers a double'), findsOneWidget);
      await pumpUntil(
          t, () => find.textContaining('Tutor:').evaluate().isNotEmpty);
      // The advice is either Take or Pass; assert the line is present.
      expect(find.textContaining('Tutor:'), findsOneWidget);

      c.disposeController();
    });
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
    final src = boardPainterOf(t).highlightedSources.first;
    await tapBoardPoint(t, src);
    final dst = boardPainterOf(t).highlightedDestinations.first;
    await tapBoardPoint(t, dst);
    expect(boardPainterOf(t).board, isNot(c.state.board));

    // Force a same-state rebuild of GameScreen; the in-progress entry survives.
    rebuild.value++;
    await t.pump();
    expect(boardPainterOf(t).board, isNot(c.state.board),
        reason: 'identical-state rebuild kept the entered hop');

    c.disposeController();
  });
}
