import 'dart:async';
import 'dart:math';

import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_view.dart';
import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/game/dice_roller.dart';
import 'package:aigammon_app/game/game_controller.dart';
import 'package:aigammon_app/game/match_controller.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/online/online_match_controller.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:aigammon_app/screens/history_screen.dart';
import 'package:aigammon_app/screens/metric_explainer.dart';
import 'package:aigammon_app/tutor/tutor_service.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_client/online_client.dart';

import '../data/test_database.dart';
import '../helpers/board_driving.dart';

/// A finished one-move game (White drops Black's double): a real [GameResult]
/// with a full event log, for seeding the post-match summary tests.
Game _finishedGame() {
  final g0 = Game.start(const OpeningRollEvent(whiteDie: 6, blackDie: 1));
  final g1 = g0.append(MoveEvent(Player.white, g0.state.legalMoves.first));
  final g2 = g1.append(const DoubleEvent(Player.black));
  return g2.append(const DropEvent(Player.white));
}

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

/// An AI whose [chooseMove] never completes (until teardown), FREEZING the game
/// in the mover's moving phase. Lets a test observe the board's dice right after
/// a non-local roll without the turn advancing past the beat window. Everything
/// else mirrors [FakeAgent] (it will roll pre-roll, never doubles).
class HangingMoveAgent implements PlayerAgent {
  final Completer<Move> _moveGate = Completer<Move>();

  @override
  bool get wantsDoublePrompts => true;

  @override
  Future<Move> chooseMove(GameState state) => _moveGate.future;

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

/// A minimal scriptable [MatchApi] for driving an [OnlineMatchController] in a
/// widget test. [initialLog] is served by [fetchEventsSince] (seed the opening
/// roll so the controller becomes ready); [pollEvents] returns a stream fed by
/// [push] (later remote events). [submitEvent] records the local side's event in
/// [lastSubmitted] and is otherwise a no-op (the server would echo it back as a
/// remote event, which the test injects via [push]).
class ScriptedMatchApi implements MatchApi {
  ScriptedMatchApi(this.initialLog);

  final List<RemoteEvent> initialLog;
  final StreamController<RemoteEvent> _poll = StreamController<RemoteEvent>();
  GameEvent? lastSubmitted;

  void push(RemoteEvent e) => _poll.add(e);
  Future<void> close() => _poll.close();

  @override
  Future<List<RemoteEvent>> fetchEventsSince(String matchId, int afterSeq) async =>
      [for (final e in initialLog) if (e.seq > afterSeq) e];

  @override
  Stream<RemoteEvent> pollEvents(String matchId,
          {Duration interval = const Duration(seconds: 2)}) =>
      _poll.stream;

  @override
  Future<int> submitEvent(String matchId, GameEvent event,
      {GameResultClaim? result}) async {
    lastSubmitted = event;
    return 1;
  }

  @override
  Future<Dice> rollDice(String matchId) async => Dice(1, 2);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A snapshot for a live 5-point online match (scores 0-0), enough to seed an
/// [OnlineMatchController]; the live game state is derived from the folded log.
MatchSnapshot _onlineSnap() => MatchSnapshot(
      status: 'active',
      code: 'ABC123',
      matchLength: 5,
      gameNo: 1,
      seq: 0,
      whiteUid: 'w',
      blackUid: 'b',
      whiteScore: 0,
      blackScore: 0,
      turn: Player.white,
      phase: GamePhase.moving,
      isCrawford: false,
      crawfordPlayed: false,
      winner: null,
    );

// --- Widget-test helpers -----------------------------------------------------

const _surface = Size(900, 1300);

/// A [GameScreen] over a generic [MatchController] with animation ENABLED, for
/// the online (non-[GameController]) cases.
Widget _controllerAnimHarness(MatchController c) => MaterialApp(
      home: GameScreen(
        key: ValueKey(c),
        controller: c,
        timings: AnimationTimings.normal,
      ),
    );

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

/// A [GameScreen] harness with animation ENABLED (a nonzero [AnimationTimings]
/// preset), so the opponent dice-roll beat runs. All other tests use the
/// [AnimationTimings.off] harnesses above (animation off), where the beat is
/// skipped entirely.
Widget _animHarness(
  GameController c, {
  AnimationTimings timings = AnimationTimings.normal,
}) =>
    MaterialApp(
      home: GameScreen(
        key: ValueKey(c),
        controller: c,
        timings: timings,
      ),
    );

/// Mounts a [GameScreen] whose interaction options + scoring are derived from
/// the (overridable) [settingsProvider] — exactly as the new-match / online
/// screens wire them in production. Lets a test override the provider and probe
/// that the settings reach the [BoardView] / HUD.
Widget _settingsHarness(GameController c, AppSettings settings) => ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
      ],
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          final s = ref.watch(settingsProvider).valueOrNull ?? settings;
          return GameScreen(
            key: ValueKey(c),
            controller: c,
            interactionOptions: BoardInteractionOptions(
              showHighlights: s.showHighlights,
              enableDrag: s.enableDrag,
              enableCombinedTaps: s.enableCombinedTaps,
            ),
            showScoring: s.showScoring,
          );
        }),
      ),
    );

/// The [BoardView] in the tree.
BoardView _boardViewOf(WidgetTester t) =>
    t.widget<BoardView>(find.byType(BoardView));

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

  group('pre-roll: tapping the dice rolls', () {
    /// A match parked at White's (the human's) pre-roll gate.
    GameController atGate() => GameController(
          white: LocalHumanAgent(),
          black: FakeAgent(),
          matchLength: 5,
          // Black wins the opening (6 > 1) and moves; White then reaches its
          // pre-roll gate as its first action.
          diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
        );

    /// Taps the centre of [player]'s dice pair on the board.
    Future<void> tapDice(WidgetTester t, Player player, Player mover) async {
      final painter = boardPainterOf(t);
      final target = painter.geometry.diceRect(player, mover: mover).center;
      await t.tapAt(boardRect(t).topLeft + target);
      await t.pump();
    }

    testWidgets("tapping the mover's dice rolls, like the Roll button",
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = atGate();
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      // The Roll button STAYS: the dice tap is a second route, not a swap.
      expect(find.widgetWithText(FilledButton, 'Roll'), findsOneWidget);
      expect(boardPainterOf(t).diceTapHint, isTrue,
          reason: 'the tappable pair is ringed while the gate is open');

      await tapDice(t, c.state.turn, c.state.turn);
      await pumpUntil(t, () => !c.awaitingHumanTurn);
      expect(c.awaitingHumanTurn, isFalse, reason: 'the tap rolled the dice');
      c.disposeController();
    });

    testWidgets("tapping the WAITING player's pair rolls too", (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = atGate();
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      final mover = c.state.turn;
      await tapDice(t, mover.opponent, mover);
      await pumpUntil(t, () => !c.awaitingHumanTurn);
      expect(c.awaitingHumanTurn, isFalse);
      c.disposeController();
    });

    testWidgets('the hint clears once the gate closes (a move is being entered)',
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
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      expect(boardPainterOf(t).diceTapHint, isFalse,
          reason: 'no dice affordance while a move is being entered');
      // And the board is interactive again: the dice area must not swallow taps.
      expect(boardPainterOf(t).highlightedSources, isNotEmpty);
      c.disposeController();
    });
  });

  testWidgets('the board spans the FULL width of its slot (no side padding)',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final c = GameController(
      white: LocalHumanAgent(),
      black: FakeAgent(),
      matchLength: 5,
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );
    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.awaitingHumanTurn);

    // On a phone-shaped surface the slot is taller than the board's aspect
    // clamp allows, so the WIDTH binds: the board must start at x=0 and end at
    // the screen's right edge — every pixel, no inset.
    final board = boardRect(t);
    final screen = t.getRect(find.byType(GameScreen));
    expect(board.left, closeTo(screen.left, 0.5));
    expect(board.right, closeTo(screen.right, 0.5));
    c.disposeController();
  });

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

  testWidgets('the header fits its widest load on a phone (Crawford badge)',
      (t) async {
    // The fullest the left group ever gets: a 1-point match is Crawford from
    // the first roll, so score + Crawford badge + cube chip all share the row
    // with Double and the overflow menu. On a 390pt phone that group outgrew
    // the row — flutter_test turns the resulting RenderFlex overflow into a
    // failure, so simply pumping the screen is the assertion.
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final human = LocalHumanAgent();
    final c = GameController(
      white: human,
      black: FakeAgent(),
      matchLength: 1,
      diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
    );
    await t.pumpWidget(_harness(c));
    await pumpUntil(t, () => c.awaitingHumanTurn);

    // Guard the guard: the badge really is in the row being measured.
    expect(c.state.isCrawfordGame, isTrue);
    expect(find.text('Crawford'), findsOneWidget);
    expect(find.textContaining('to 1'), findsOneWidget);
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
    // The dialog message is present. (The always-on history strip also shows the
    // matching record line "… offers to resign a gammon", so match both.)
    expect(find.textContaining('Accept or decline'), findsOneWidget);
    expect(find.textContaining('resign a gammon'), findsWidgets);

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
    // Seed 7's first game is a White gammon: the dialog says so in plain words
    // (points as a signed gain, the outcome named), plus the match score line.
    expect(result.outcome, GameOutcome.gammon);
    expect(
        find.textContaining('White wins this game (+${result.points}, gammon).'),
        findsOneWidget);
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

  group('post-match "Match summary" link', () {
    // A vs-AI controller decided by a single game (match over immediately). The
    // engine is never actually queried in these dialog-only tests.
    GameController matchOver() => GameController(
          white: FakeAgent(),
          black: FakeAgent(),
          matchLength: 1,
          diceRoller: DiceRoller(Random(7)),
        );

    // A 7-point vs-AI controller: the first game ends but the match does not, so
    // the game-end ("Game over") dialog shows.
    GameController gameOver() => GameController(
          white: FakeAgent(),
          black: FakeAgent(),
          matchLength: 7,
          diceRoller: DiceRoller(Random(7)),
        );

    // Wraps a GameScreen over the in-memory db so a tapped "Match summary" can
    // resolve its games from the real repository. The persisted match + one
    // game are seeded first; [matchId] resolves immediately.
    Widget harness(GameController c, {
      required int? matchId,
      required TutorService? tutor,
      required AppDatabase db,
    }) =>
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: GameScreen(
              key: ValueKey(c),
              controller: c,
              tutor: tutor,
              persistedMatchId: matchId == null ? null : Future.value(matchId),
            ),
          ),
        );

    testWidgets('match-end: shows the button when tutor+id present; pushes '
        'MatchDetailScreen', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final db = newTestDatabase();
      addTearDown(db.close);
      final repo = MatchRepository(db);
      late int matchId;
      final game = _finishedGame();
      await t.runAsync(() async {
        matchId = await repo.startMatch(
            matchLength: 1, mode: 'online', whiteType: 'human', blackType: 'remote');
        await repo.recordGame(
          matchId: matchId,
          gameNumber: 1,
          isCrawford: game.state.isCrawfordGame,
          events: game.events,
          result: game.state.result!,
        );
      });

      final c = matchOver();
      await t.pumpWidget(harness(c,
          matchId: matchId, tutor: TutorService(RealRankEngine()), db: db));
      await t.pumpAndSettle();
      expect(find.text('Match over'), findsOneWidget);

      // The link is offered.
      final summary = find.widgetWithText(TextButton, 'Match summary');
      expect(summary, findsOneWidget);

      await t.runAsync(() async {
        await t.tap(summary);
      });
      // Resolve the id future + gamesFor, then settle the pushed route.
      for (var i = 0; i < 20; i++) {
        await t.runAsync(() async =>
            Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      await t.pumpAndSettle();

      expect(find.byType(MatchDetailScreen), findsOneWidget);
      expect(find.text('Game 1'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('game-end: shows the "Analyze game" button (tutor+id present)',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final db = newTestDatabase();
      addTearDown(db.close);
      final c = gameOver();
      await t.pumpWidget(harness(c,
          matchId: 42, tutor: TutorService(RealRankEngine()), db: db));
      await t.pumpAndSettle();

      expect(find.text('Game over'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Analyze game'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Next game'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('game-end: "Analyze game" shows with tutor OFF (id present)',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final db = newTestDatabase();
      addTearDown(db.close);
      final c = gameOver();
      // Tutor OFF: post-game analysis needs only the engine, so the entry point
      // must still appear when the match is persisted.
      await t.pumpWidget(harness(c, matchId: 42, tutor: null, db: db));
      await t.pumpAndSettle();

      expect(find.text('Game over'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Analyze game'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('match-end: "Match summary" + "Saved to History" show with '
        'tutor OFF (id present)', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final db = newTestDatabase();
      addTearDown(db.close);
      final c = matchOver();
      await t.pumpWidget(harness(c, matchId: 7, tutor: null, db: db));
      await t.pumpAndSettle();

      expect(find.text('Match over'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Match summary'), findsOneWidget);
      expect(find.text('Saved to History'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('tutor OFF: tapping "Match summary" pushes MatchDetailScreen',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final db = newTestDatabase();
      addTearDown(db.close);
      final repo = MatchRepository(db);
      late int matchId;
      final game = _finishedGame();
      await t.runAsync(() async {
        matchId = await repo.startMatch(
            matchLength: 1,
            mode: 'vsComputer',
            whiteType: 'human',
            blackType: 'ai:expert');
        await repo.recordGame(
          matchId: matchId,
          gameNumber: 1,
          isCrawford: game.state.isCrawfordGame,
          events: game.events,
          result: game.state.result!,
        );
      });

      final c = matchOver();
      // No live tutor — the analysis route must still be reachable and build its
      // own analyzer from the engine provider.
      await t.pumpWidget(harness(c, matchId: matchId, tutor: null, db: db));
      await t.pumpAndSettle();
      expect(find.text('Match over'), findsOneWidget);

      final summary = find.widgetWithText(TextButton, 'Match summary');
      expect(summary, findsOneWidget);
      await t.runAsync(() async {
        await t.tap(summary);
      });
      for (var i = 0; i < 20; i++) {
        await t.runAsync(() async =>
            Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      await t.pumpAndSettle();

      expect(find.byType(MatchDetailScreen), findsOneWidget);
      expect(find.text('Game 1'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('absent when there is no persisted id (even with a tutor)',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final db = newTestDatabase();
      addTearDown(db.close);
      final c = matchOver();
      await t.pumpWidget(harness(c,
          matchId: null, tutor: TutorService(RealRankEngine()), db: db));
      await t.pumpAndSettle();

      expect(find.text('Match over'), findsOneWidget);
      // No persisted record → no analysis entry point and no History hint.
      expect(find.widgetWithText(TextButton, 'Match summary'), findsNothing);
      expect(find.text('Saved to History'), findsNothing);

      c.disposeController();
    });

    testWidgets('game-end "Analyze game" absent when there is no persisted id',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final db = newTestDatabase();
      addTearDown(db.close);
      final c = gameOver();
      await t.pumpWidget(harness(c,
          matchId: null, tutor: TutorService(RealRankEngine()), db: db));
      await t.pumpAndSettle();

      expect(find.text('Game over'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Analyze game'), findsNothing);

      c.disposeController();
    });
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

  // The board FILLS the slot between the fixed HUD and the fixed bottom region,
  // so on a phone (where the slot is HEIGHT-bound) anything that changes a
  // sibling's height would resize the board mid-turn — the F6 no-jump rule.
  // Both intermittent siblings are checked on a real phone surface.
  group('F6: no board reflow on a phone', () {
    const phone = Size(390, 844);

    testWidgets('the tutor advice line appearing and going leaves the board put',
        (t) async {
      await t.binding.setSurfaceSize(phone);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        // Black wins the opening (6 > 1) and moves; White then reaches its
        // pre-roll gate, where the cube advice line resolves.
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      final tutor = TutorService(TutorEngine());
      await t.pumpWidget(_tutorHarness(c, tutor));

      // At the gate, with the advice line showing.
      await pumpUntil(t, () => c.awaitingHumanTurn);
      await pumpUntil(
          t, () => find.textContaining('Tutor:').evaluate().isNotEmpty);
      final withAdvice = boardRect(t);

      // Rolling closes the gate and the advice goes: the slot stays reserved,
      // so the board must not grow into it (and must not shrink back when the
      // next gate's advice lands).
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => !c.awaitingHumanTurn);
      expect(find.textContaining('Tutor:'), findsNothing);
      expect(boardRect(t), withAdvice,
          reason: 'the advice line has a reserved slot — the board holds still');

      c.disposeController();
    });

    testWidgets('the error banner appearing leaves the board put', (t) async {
      await t.binding.setSurfaceSize(phone);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: ThrowingAgent(),
        // 3, not 1: an ordinary non-Crawford match, so the header carries its
        // usual load. The widest header is covered by its own test.
        matchLength: 3,
        // White (human) wins the opening and moves; Black's agent then throws.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.pendingMoveOf(Player.white).value != null);
      final clean = boardRect(t);
      expect(find.byIcon(Icons.error_outline), findsNothing);

      await commitFirstMove(t);
      await pumpUntil(t, () => c.error != null);
      await t.pump();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(boardRect(t), clean,
          reason: 'the banner floats over the board — no reflow');

      c.disposeController();
    });
  });

  group('opponent dice-roll beat', () {
    // Reaches a NON-local (AI Black) roll: White (human) wins the opening
    // (6 > 1) and plays, then Black auto-rolls its first turn. [HangingMoveAgent]
    // then freezes Black in its moving phase so the dice stay put — Black's roll
    // is the roller's first `roll()` (index 0), i.e. Dice(6, 5).
    (GameController, LocalHumanAgent, HangingMoveAgent) freezeOnAiRoll() {
      final human = LocalHumanAgent();
      final ai = HangingMoveAgent();
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      return (c, human, ai);
    }

    Future<void> driveToAiRoll(WidgetTester t, GameController c,
        LocalHumanAgent human) async {
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      human.submitMove(c.state.legalMoves.first);
      await pumpUntil(
          t,
          () => c.game.events
              .whereType<RollEvent>()
              .any((e) => e.player == Player.black));
    }

    testWidgets('AI roll shows a cycling override, then settles to the real roll',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final (c, human, _) = freezeOnAiRoll();
      await t.pumpWidget(_animHarness(c));
      await driveToAiRoll(t, c, human);

      const realRoll = (6, 5);
      expect(c.state.dice, Dice(realRoll.$1, realRoll.$2),
          reason: 'Black settled on its real roll internally');

      // The beat is live: Black (the roller) paints override faces on ITS pair,
      // NOT the real roll.
      expect(boardPainterOf(t).blackDice, isNot(Dice(realRoll.$1, realRoll.$2)),
          reason: 'the roll beat overrides the roller pair');

      // After the tumble frames (6 × 140ms) the override clears and the real
      // roll shows. Pump comfortably past the cycling window.
      await t.pump(const Duration(milliseconds: 1000));
      expect(boardPainterOf(t).blackDice, Dice(realRoll.$1, realRoll.$2),
          reason: 'the beat settled to the real roll');

      // Let the settle-pause timer fire before teardown so no timer outlives it.
      await t.pumpAndSettle();
      c.disposeController();
    });

    testWidgets('animation off (Duration.zero): AI roll has no beat', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final (c, human, _) = freezeOnAiRoll();
      await t.pumpWidget(_harness(c)); // Duration.zero: animation off
      await driveToAiRoll(t, c, human);

      // No override ever: Black's pair shows its real roll immediately.
      expect(boardPainterOf(t).blackDice, Dice(6, 5));
      expect(boardPainterOf(t).blackDice, c.state.dice);

      c.disposeController();
    });

    testWidgets('AI move is HELD through the dice presentation, then plays',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      // White (human) wins the opening (6 > 1) and plays; Black (AI, instant)
      // then rolls AND moves. Black's move event fires WHILE the dice beat is
      // still presenting, so its travel must be queued (held) until the tumble
      // frames + settle pause finish (~6×140 + 500ms).
      final human = LocalHumanAgent();
      final ai = FakeAgent();
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_animHarness(c, timings: AnimationTimings.normal));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      human.submitMove(c.state.legalMoves.first);

      // Wait until Black has both rolled AND moved (its MoveEvent → lastMove
      // fired, so the board queued the held travel).
      await pumpUntil(
          t,
          () => c.game.events
              .whereType<MoveEvent>()
              .any((e) => e.player == Player.black));

      // White's own (immediate) opening-move animation may still be finishing
      // (up to ~820ms for a 2-hop play at the normal preset); once it clears,
      // Black's queued move must NOT show any travelling overlay — it is held
      // for the whole dice presentation (~6×140 + 500ms ≈ 1340ms).
      await pumpUntil(t, () => boardPainterOf(t).overlayChecker == null,
          maxFrames: 1000);
      await t.pump(const Duration(milliseconds: 150));
      expect(boardPainterOf(t).overlayChecker, isNull,
          reason: 'the opponent move stays held while the dice are presented');

      // After the tumble frames + settle pause the hold releases and the queued
      // move finally travels — the overlay appears.
      await pumpUntil(t, () => boardPainterOf(t).overlayChecker != null,
          maxFrames: 2000);
      expect(boardPainterOf(t).overlayChecker, isNotNull,
          reason: 'the held move plays once the dice presentation completes');

      await t.pumpAndSettle();
      c.disposeController();
    });

    testWidgets('local human roll is instant (no beat override)', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        // Black (AI) wins the opening and moves; White (human) then rolls at its
        // gate — its own roll must never trigger a beat.
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );

      await t.pumpWidget(_animHarness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      final realRoll = c.state.dice;
      expect(realRoll, isNotNull);
      // The human's own roll shows immediately: White's (the mover's) pair
      // equals the real state dice with no override in between.
      expect(boardPainterOf(t).whiteDice, realRoll,
          reason: 'a local roll is instant — no beat override');

      // Let any move animation from the AI opening finish before teardown.
      await t.pumpAndSettle();
      c.disposeController();
    });
  });

  group('no self-replay of hand-entered moves', () {
    testWidgets('vs-AI: the human hand-entered move does NOT replay; the AI '
        'reply DOES animate', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final ai = FakeAgent();
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        // White (human) wins the opening (6 > 1) and plays; Black (AI) then rolls
        // (6,5) and replies.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_animHarness(c, timings: AnimationTimings.normal));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      // Enter White's opening move BY HAND (taps → Confirm) on the board.
      await commitFirstMove(t);

      // The human's own move is not replayed: no travelling overlay appears in
      // the window right after the commit (the AI's reply is still held behind
      // its dice presentation, so any overlay here could only be the replay).
      await t.pump(const Duration(milliseconds: 200));
      expect(boardPainterOf(t).overlayChecker, isNull,
          reason: "the human's hand-entered move must not replay");

      // The AI's reply, by contrast, DOES animate once its dice presentation
      // finishes and the held travel releases.
      await pumpUntil(t, () => boardPainterOf(t).overlayChecker != null,
          maxFrames: 2000);
      expect(boardPainterOf(t).overlayChecker, isNotNull,
          reason: 'the AI reply still animates');

      await t.pumpAndSettle();
      c.disposeController();
    });

    testWidgets(
        'vs-AI: the confirmed move STAYS applied through the opponent roll '
        'and reply (it never reverts and is never re-played)', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        // White (human) wins the opening (6 > 1) and plays; Black (AI) then rolls
        // (6,5) and replies instantly — inside the SAME frame gap as the commit,
        // exactly as the real engine does on device.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_animHarness(c, timings: AnimationTimings.normal));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      final preMove = c.state.board;
      await commitFirstMove(t);

      // Both moves have already landed on the controller (the AI answers within
      // the commit's microtask chain — no frame in between), so the whole
      // legitimate board sequence is known: White's committed move applied, then
      // Black's reply hop by hop as its animation plays it out.
      final moves = c.game.events.whereType<MoveEvent>().toList();
      expect(moves.length, greaterThanOrEqualTo(2),
          reason: 'White committed and the AI replied');
      expect(moves.first.player, Player.white);
      final afterWhite = preMove.applyMove(Player.white, moves.first.move);
      expect(afterWhite, isNot(preMove), reason: 'the commit changed the board');
      final allowed = <BoardState>[afterWhite];
      for (final hop in moves[1].move.checkerMoves) {
        allowed.add(allowed.last.applyMove(Player.black, Move([hop])));
      }

      // (a) The very first frame after Confirm already shows the move applied —
      // no revert to the pre-move position.
      expect(boardPainterOf(t).board, afterWhite,
          reason: 'the confirmed move is painted immediately');

      // (b) EVERY frame from here until the AI's reply animation settles paints
      // one of the legitimate boards: the confirmed position, or that position
      // with a prefix of Black's hops. The pre-move board is never among them.
      var sawOverlay = false;
      var settled = false;
      for (var i = 0; i < 2000 && !settled; i++) {
        final painter = boardPainterOf(t);
        expect(allowed, contains(painter.board),
            reason: 'frame $i paints neither the confirmed position nor a '
                "prefix of Black's reply — the committed move reverted");
        if (painter.overlayChecker != null) sawOverlay = true;
        settled = sawOverlay && painter.overlayChecker == null;
        if (!settled) await t.pump(const Duration(milliseconds: 8));
      }
      expect(sawOverlay, isTrue, reason: "Black's reply animates");
      expect(settled, isTrue, reason: "Black's reply settles");
      expect(boardPainterOf(t).board, allowed.last,
          reason: 'both moves are applied once the reply settles');

      await t.pumpAndSettle();
      c.disposeController();
    });

    testWidgets('tap-to-apply hint: the applied move DOES animate', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        // Black (AI) wins the opening and plays; White (human) then rolls (3,1)
        // at its gate and applies a hint.
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      final tutor = TutorService(RealRankEngine());

      await t.pumpWidget(MaterialApp(
        home: GameScreen(
          key: ValueKey(c),
          controller: c,
          tutor: tutor,
          timings: AnimationTimings.normal,
        ),
      ));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      // Let the AI's opening-move animation settle before the human acts.
      await pumpUntil(t, () => boardPainterOf(t).overlayChecker == null,
          maxFrames: 2000);

      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      final s = c.state;
      final expected = MoveGenerator.legalMoves(s.board, s.turn, s.dice!).first;
      await t.tap(find.widgetWithText(OutlinedButton, 'Hint'));
      await pumpUntil(t, () => find.text('Top plays').evaluate().isNotEmpty);
      await t.tap(find.text('$expected').first);
      await t.pump(); // panel closes; the play is STAGED programmatically

      // Confirm the staged hint → it animates (the user did not drag it).
      await t.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await pumpUntil(t, () => boardPainterOf(t).overlayChecker != null,
          maxFrames: 800);
      expect(boardPainterOf(t).overlayChecker, isNotNull,
          reason: 'a tap-to-apply hint move still animates');

      await t.pumpAndSettle();
      c.disposeController();
    });

    testWidgets('hot-seat: a hand-entered move does NOT replay for either side',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final white = LocalHumanAgent();
      final black = LocalHumanAgent();
      final c = GameController(
        white: white,
        black: black,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_animHarness(c, timings: AnimationTimings.normal));
      await pumpUntil(t, () => white.pendingMoveRequest.value != null);
      await commitFirstMove(t);

      // The mover just performed the move live on the shared board — no replay.
      // (The other side is human too and will not move on its own.)
      await t.pump(const Duration(milliseconds: 300));
      expect(boardPainterOf(t).overlayChecker, isNull,
          reason: 'hot-seat: a hand-entered move is not replayed');

      c.disposeController();
    });

    testWidgets('online: a REMOTE move animates', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      // Opening: Black (the REMOTE side) wins (6 > 3) and is on move first.
      final log = [
        const RemoteEvent(
          seq: 0,
          gameNo: 1,
          event: OpeningRollEvent(whiteDie: 3, blackDie: 6),
        ),
      ];
      final api = ScriptedMatchApi(log);
      addTearDown(api.close);
      final c = OnlineMatchController(
        api: api,
        matchId: 'm',
        localSide: Player.white, // the remote mover is Black
        initialSnapshot: _onlineSnap(),
      );

      // Bring the controller to readiness (folds the opening, subscribes the
      // poll) BEFORE mounting the screen (whose initState reads `state`). Pumping
      // flushes the catch-up microtasks; the placeholder keeps the tester alive.
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      unawaited(c.playMatch());
      await pumpUntil(t, () => c.isReady);
      await t.pumpWidget(_controllerAnimHarness(c));
      await t.pump();

      // Inject Black's (remote) move — a legal play for the folded state.
      final remoteMove = c.state.legalMoves.first;
      api.push(RemoteEvent(
          seq: 1, gameNo: 1, event: MoveEvent(Player.black, remoteMove)));

      await pumpUntil(t, () => boardPainterOf(t).overlayChecker != null,
          maxFrames: 800);
      expect(boardPainterOf(t).overlayChecker, isNotNull,
          reason: 'a remote opponent move animates');

      // Let the travel finish (bounded), then tear down. Avoids pumpAndSettle,
      // which never settles against the controller's live poll subscription.
      await pumpUntil(t, () => boardPainterOf(t).overlayChecker == null,
          maxFrames: 2000);
      c.disposeController();
    });

    testWidgets('online: the LOCAL hand-entered move does NOT animate',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      // Opening: White (the LOCAL side) wins (6 > 3) and is on move first.
      final log = [
        const RemoteEvent(
          seq: 0,
          gameNo: 1,
          event: OpeningRollEvent(whiteDie: 6, blackDie: 3),
        ),
      ];
      final api = ScriptedMatchApi(log);
      addTearDown(api.close);
      final c = OnlineMatchController(
        api: api,
        matchId: 'm',
        localSide: Player.white,
        initialSnapshot: _onlineSnap(),
      );

      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      unawaited(c.playMatch());
      await pumpUntil(t, () => c.isReady);
      await t.pumpWidget(_controllerAnimHarness(c));
      await t.pump();

      // Enter White's move BY HAND and confirm; the controller submits it to the
      // server (recorded in the fake), which then echoes it back as a remote
      // event — the injection below mirrors that echo.
      await commitFirstMove(t);
      final submitted = api.lastSubmitted;
      expect(submitted, isA<MoveEvent>(),
          reason: 'the confirmed local move was submitted');
      api.push(RemoteEvent(seq: 1, gameNo: 1, event: submitted!));

      // The echoed local move folds but must NOT replay (the user just entered
      // it on the board). No overlay ever appears.
      await pumpUntil(t, () => c.state.turn == Player.black, maxFrames: 800);
      await t.pump(const Duration(milliseconds: 300));
      expect(boardPainterOf(t).overlayChecker, isNull,
          reason: 'a local online move is not replayed');

      c.disposeController();
    });
  });

  group('persistent dice pairs', () {
    // The fold the screen applies: each player's most recent roll of the CURRENT
    // game (opening seeds the first mover), so a test can compute the expected
    // pairs directly from the live event log.
    (Dice?, Dice?) expectedDice(GameController c) {
      Dice? w;
      Dice? b;
      for (final e in c.game.events) {
        if (e is OpeningRollEvent) {
          final d = Dice(e.whiteDie, e.blackDie);
          if (e.firstPlayer == Player.white) {
            w = d;
          } else {
            b = d;
          }
        } else if (e is RollEvent) {
          final d = Dice(e.die1, e.die2);
          if (e.player == Player.white) {
            w = d;
          } else {
            b = d;
          }
        }
      }
      return (w, b);
    }

    testWidgets("opponent's roll stays visible on its pair while the human "
        'moves', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final ai = FakeAgent();
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        // White wins the opening (6 > 1) and plays; Black (AI) then rolls
        // Dice(6, 5) and moves; play returns to White's gate.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      // White's opening roll shows on White's pair; Black has no roll yet.
      expect(boardPainterOf(t).whiteDice, Dice(6, 1));
      expect(boardPainterOf(t).blackDice, isNull,
          reason: 'Black has not rolled yet: blank pair');

      // White plays; the AI rolls + moves; White returns to its pre-roll gate.
      await commitFirstMove(t);
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.white);

      final (ew, eb) = expectedDice(c);
      expect(eb, isNotNull, reason: 'the AI rolled on its turn');
      // The opponent's roll persists on the black pair even though it is now
      // White's turn (the mover is White).
      expect(boardPainterOf(t).blackDice, eb);
      expect(boardPainterOf(t).whiteDice, ew);
      expect(boardPainterOf(t).diceMover, Player.white);

      // White rolls and enters its move: its own pair updates to the new roll,
      // while the AI's roll REMAINS on the black pair (the core fix).
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      final (ew2, eb2) = expectedDice(c);
      expect(boardPainterOf(t).whiteDice, ew2);
      expect(boardPainterOf(t).blackDice, eb2,
          reason: "the opponent's roll is still visible while the human moves");
      expect(eb2, eb, reason: 'the AI has not rolled again');

      c.disposeController();
    });

    testWidgets('a new game clears both pairs (scoped to the current game)',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final c = GameController(
        white: FakeAgent(),
        black: FakeAgent(),
        matchLength: 7, // long enough that one game never ends the match
        diceRoller: DiceRoller(Random(7)),
      );

      await t.pumpWidget(_harness(c));
      await t.pumpAndSettle();
      expect(c.awaitingNextGame, isTrue);

      // Game 1 is over: both players have rolled, so both pairs are populated.
      final (w1, b1) = expectedDice(c);
      expect(w1, isNotNull);
      expect(b1, isNotNull);
      expect(boardPainterOf(t).whiteDice, w1);
      expect(boardPainterOf(t).blackDice, b1);

      final g1 = c.game;
      await t.tap(find.widgetWithText(FilledButton, 'Next game'));
      await pumpUntil(t, () => !identical(c.game, g1));
      await t.pumpAndSettle();

      // Game 2's log is fresh: the painted pairs are folded ONLY from the new
      // game's events (game 1's rolls are gone), proving the reset.
      expect(c.game.events.contains(g1.events.first), isFalse,
          reason: 'a new game has its own opening roll');
      final (w2, b2) = expectedDice(c);
      expect(boardPainterOf(t).whiteDice, w2);
      expect(boardPainterOf(t).blackDice, b2);

      c.disposeController();
    });
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

    testWidgets('history strip shows the score for the latest (human) line, '
        'not an AI move', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      // White (human) wins the opening (6 > 1) and moves first; Black is a
      // hanging AI, so after Black auto-rolls (a scoreless roll line) it freezes
      // — White's assessed move stays the LATEST record line for the strip.
      final human = LocalHumanAgent();
      final ai = HangingMoveAgent();
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      // Before any move is assessed, the strip carries no mark (coloured dot).
      expect(find.byIcon(Icons.circle), findsNothing,
          reason: 'nothing assessed yet — no mark on the strip');

      await commitFirstMove(t);
      await pumpUntil(t, () => find.textContaining('−0.060').evaluate().isNotEmpty);
      // 0.10 - 0.04 = 0.06 give-up, shown as "−0.060" with the mark dot on the
      // collapsed strip (the latest line is White's assessed move).
      final strip = find.byKey(const ValueKey('historyStrip'));
      expect(find.descendant(of: strip, matching: find.textContaining('−0.060')),
          findsOneWidget);
      expect(find.descendant(of: strip, matching: find.byIcon(Icons.circle)),
          findsOneWidget,
          reason: 'the assessed latest line carries a mark dot on the strip');

      c.disposeController();
    });

    testWidgets('strip shows the latest record line; expanding reveals the '
        'full scrollable record with scores and best', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      // White (human) starts and moves; Black (hanging AI) freezes after its
      // roll, so White's move remains the latest record line.
      final human = LocalHumanAgent();
      final ai = HangingMoveAgent();
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      final strip = find.byKey(const ValueKey('historyStrip'));
      expect(strip, findsOneWidget, reason: 'the strip is always present');
      // Before any move, the strip shows the only line so far — the opening.
      expect(
          find.descendant(
              of: strip, matching: find.textContaining('Opening:')),
          findsOneWidget);
      // The sheet is closed: only the strip's single latest line is shown.
      expect(find.text('Game record'), findsNothing);

      // Commit White's move so there is an assessed row to reveal a best for.
      await commitFirstMove(t);
      await pumpUntil(t, () => find.textContaining('−0.060').evaluate().isNotEmpty);

      // Tapping the strip expands the full sheet: header, score context, and the
      // opening line (which is no longer the strip's latest line).
      await t.tap(strip);
      await t.pumpAndSettle();
      expect(find.text('Game record'), findsOneWidget);
      expect(find.textContaining('to 5'), findsWidgets,
          reason: 'the sheet header carries the match score context');
      expect(find.text('Opening: W 6 — B 1 (W starts)'), findsOneWidget);

      // The assessed White row's best line is hidden until the row is tapped.
      expect(find.textContaining('Best:'), findsNothing);
      // Tap the White move row (inside the sheet) to reveal its best play.
      await t.tap(find.textContaining('1. W').last);
      await t.pumpAndSettle();
      expect(find.textContaining('Best:'), findsOneWidget,
          reason: 'tap-to-reveal shows the best move under the assessed row');

      c.disposeController();
    });

    testWidgets('tutor off: record rows are plain (no assessment marks)',
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

      // No tutor: commit a human move, then open the record.
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await commitFirstMove(t);
      // Wait on the controller (not the strip text, which the AI's reply quickly
      // supersedes) until White's move has landed in the log.
      await pumpUntil(
          t,
          () => c.game.events
              .whereType<MoveEvent>()
              .any((e) => e.player == Player.white));

      await t.tap(find.byKey(const ValueKey('historyStrip')));
      await t.pumpAndSettle();
      // The sheet lists White's move, but with no assessment marks/losses.
      expect(find.textContaining('2. W'), findsWidgets);
      expect(find.byIcon(Icons.circle), findsNothing);
      expect(find.textContaining('−0.'), findsNothing);

      c.disposeController();
    });

    testWidgets('board does not reflow when the strip expands', (t) async {
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

      final before = t.getRect(find.byType(BoardView));
      await t.tap(find.byKey(const ValueKey('historyStrip')));
      await t.pumpAndSettle();
      final after = t.getRect(find.byType(BoardView));
      expect(after, before,
          reason: 'the sheet floats over the board — no reflow on expand');

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

  group('game record panel', () {
    // Black (AI) wins the opening (6 > 1) and moves first; White (human) then
    // reaches its pre-roll gate. The log holds the opening plus Black's move.
    GameController preRoll(LocalHumanAgent human) => GameController(
          white: human,
          black: FakeAgent(),
          matchLength: 5,
          diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
        );

    testWidgets('menu entry opens the panel listing the game so far',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = preRoll(human);
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      // Hidden until the overflow menu's "Game record" entry is chosen.
      expect(find.textContaining('Opening:'), findsNothing);
      await t.tap(find.byIcon(Icons.more_vert));
      await t.pumpAndSettle();
      await t.tap(find.text('Game record'));
      await t.pumpAndSettle();

      // The panel (its "Game record" title, the menu now closed) lists the
      // opening header and Black's first move (6-1 from the opening dice). The
      // move line also appears on the always-present collapsed strip, so it is
      // matched by findsWidgets (strip + sheet), while the opening header lives
      // only in the sheet.
      expect(find.text('Game record'), findsOneWidget);
      expect(find.text('Opening: W 1 — B 6 (B starts)'), findsOneWidget);
      expect(find.textContaining('1. B 6-1:'), findsWidgets);

      c.disposeController();
    });

    testWidgets('live: a fresh move appends to the open panel', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = preRoll(human);
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      await t.tap(find.byIcon(Icons.more_vert));
      await t.pumpAndSettle();
      await t.tap(find.text('Game record'));
      await t.pumpAndSettle();
      // Only Black's move so far; White has not played.
      expect(find.textContaining('2. W'), findsNothing);

      // Drive White's turn programmatically (the scrim covers the Roll button,
      // but the controller drives the same events the UI would): the panel is
      // rebuilt from the live event log and gains White's move line.
      c.rollDice();
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      human.submitMove(c.state.legalMoves.first);
      await pumpUntil(
          t, () => find.textContaining('2. W 3-1:').evaluate().isNotEmpty);
      // The new line appears in the open sheet AND on the collapsed strip.
      expect(find.textContaining('2. W 3-1:'), findsWidgets,
          reason: 'the new move appended live while the panel was open');

      c.disposeController();
    });

    testWidgets('close affordance dismisses the panel', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = preRoll(human);
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      await t.tap(find.byIcon(Icons.more_vert));
      await t.pumpAndSettle();
      await t.tap(find.text('Game record'));
      await t.pumpAndSettle();
      expect(find.text('Opening: W 1 — B 6 (B starts)'), findsOneWidget);

      await t.tap(find.byIcon(Icons.close));
      await t.pumpAndSettle();
      expect(find.text('Opening: W 1 — B 6 (B starts)'), findsNothing,
          reason: 'closing removes the record panel');

      c.disposeController();
    });
  });

  group('gameplay options', () {
    GameController preRoll() => GameController(
          white: LocalHumanAgent(),
          black: FakeAgent(),
          matchLength: 5,
          diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
        );

    testWidgets('drag/combined wired from settings reach the BoardView',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = preRoll();

      // Non-default gameplay options: highlights off, drag on, combined off.
      const settings = AppSettings(
        themeMode: ThemeMode.system,
        animationSpeed: AnimationSpeed.normal,
        defaultMatchLength: 5,
        defaultDifficulty: Difficulty.medium,
        tutorOverride: null,
        showHighlights: false,
        enableDrag: true,
        enableCombinedTaps: false,
      );
      await t.pumpWidget(_settingsHarness(c, settings));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      final opts = _boardViewOf(t).interactionOptions;
      expect(opts.showHighlights, isFalse);
      expect(opts.enableDrag, isTrue);
      expect(opts.enableCombinedTaps, isFalse,
          reason: 'settings toggles reach the board verbatim');

      c.disposeController();
    });

    testWidgets('showScoring false hides the HUD score segment', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = preRoll();

      await t.pumpWidget(MaterialApp(
        home: GameScreen(key: ValueKey(c), controller: c, showScoring: false),
      ));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      // The compact score line ("… to 5") is gone; the rest of the header stays.
      expect(find.textContaining('to 5'), findsNothing,
          reason: 'the score segment is hidden');
      expect(find.widgetWithText(OutlinedButton, 'Double'), findsOneWidget,
          reason: 'the rest of the header is unaffected');

      c.disposeController();
    });

    testWidgets('showScoring true (default) shows the HUD score', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = preRoll();
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      expect(find.textContaining('to 5'), findsOneWidget);
      c.disposeController();
    });

    testWidgets('cubeless match: cube chip and Double button are hidden',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = GameController(
        white: LocalHumanAgent(),
        black: FakeAgent(),
        matchLength: 5,
        cubeless: true,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      expect(find.widgetWithText(OutlinedButton, 'Double'), findsNothing,
          reason: 'no Double button in a cubeless match');
      expect(find.textContaining('×'), findsNothing,
          reason: 'the cube chip is hidden in a cubeless match');

      c.disposeController();
    });

    testWidgets('non-cubeless match (default): cube chip and Double present',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = preRoll();
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);
      expect(find.widgetWithText(OutlinedButton, 'Double'), findsOneWidget);
      expect(find.textContaining('×'), findsOneWidget,
          reason: 'the cube chip shows ×1');
      c.disposeController();
    });

    testWidgets('cubeless match: a doubling AI never gets to offer a double',
        (t) async {
      // Black (AI) wants to double every chance it gets, but the cube is off.
      final human = LocalHumanAgent();
      final ai = FakeAgent(doubles: true);
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        cubeless: true,
        // White moves first; Black then reaches its pre-roll (would double).
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));

      // Drive White's opening move so Black reaches its pre-roll gate.
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      human.submitMove(c.state.legalMoves.first);

      // Let the loop run through Black's whole turn (its pre-roll — where a
      // doubling AI would double — then its move) until play returns to White's
      // pre-roll gate. No cube offer is ever raised along the way.
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.white,
          maxFrames: 1200);
      expect(c.game.events.whereType<DoubleEvent>(), isEmpty,
          reason: 'a cubeless match never produces a DoubleEvent');
      expect(c.state.cube.value, 1, reason: 'the cube never moved off 1');

      c.disposeController();
    });
  });

  group('one-time drag hint', () {
    const hintText = 'Tip: drag checkers or tap them — change in Settings';

    // White (human) wins the opening (6 > 1) and its move request fires straight
    // away — the first human move-entry of the match, where the hint may surface.
    GameController firstMove(LocalHumanAgent human) => GameController(
          white: human,
          black: FakeAgent(),
          matchLength: 5,
          diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
        );

    Widget hintHarness(
      GameController c, {
      required bool enableDrag,
      required bool dragHintShown,
      VoidCallback? onDragHintShown,
    }) =>
        MaterialApp(
          home: GameScreen(
            key: ValueKey(c),
            controller: c,
            interactionOptions: BoardInteractionOptions(enableDrag: enableDrag),
            dragHintShown: dragHintShown,
            onDragHintShown: onDragHintShown,
          ),
        );

    testWidgets('shows once on the first human move (drag on, not yet shown) '
        'and persists via the callback', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = firstMove(human);
      var persisted = false;
      await t.pumpWidget(hintHarness(c,
          enableDrag: true,
          dragHintShown: false,
          onDragHintShown: () => persisted = true));

      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await t.pump(); // run the post-frame callback that schedules the SnackBar
      await t.pump(const Duration(milliseconds: 300)); // animate it in

      expect(find.text(hintText), findsOneWidget,
          reason: 'the hint surfaces on the first human move-entry');
      expect(persisted, isTrue,
          reason: 'showing the hint fires the persistence callback');

      // It is dismissible (non-blocking): tapping the action hides it. (This
      // also cancels the SnackBar duration timer before teardown.)
      await t.tap(find.text('Got it'));
      await t.pumpAndSettle();
      expect(find.text(hintText), findsNothing);

      c.disposeController();
    });

    testWidgets('latches: does not re-fire on a later move-entry of the same '
        'game screen', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = firstMove(human);
      var shownCount = 0;
      await t.pumpWidget(hintHarness(c,
          enableDrag: true,
          dragHintShown: false,
          onDragHintShown: () => shownCount++));

      // First move-entry: the hint shows exactly once.
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text(hintText), findsOneWidget);
      expect(shownCount, 1);

      // Dismiss it, then commit White's move; the AI replies and play returns to
      // White for a SECOND human move-entry on the very same GameScreen State.
      await t.tap(find.text('Got it'));
      await t.pumpAndSettle();
      expect(find.text(hintText), findsNothing);

      await commitFirstMove(t);
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.white,
          maxFrames: 1200);
      await t.tap(find.widgetWithText(FilledButton, 'Roll'));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      // The latch held across the intervening _onChange notifications: no second
      // SnackBar, and the persistence callback fired only once.
      expect(find.text(hintText), findsNothing,
          reason: 'the one-time hint never re-fires within a session');
      expect(shownCount, 1);

      c.disposeController();
    });

    testWidgets('does not reappear once dragHintShown is persisted (true)',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = firstMove(human);
      // Simulates a later game/screen: the flag was persisted true previously.
      await t.pumpWidget(
          hintHarness(c, enableDrag: true, dragHintShown: true));

      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      expect(find.text(hintText), findsNothing,
          reason: 'a persisted dragHintShown suppresses the hint forever');

      c.disposeController();
    });

    testWidgets('never shows when drag is disabled in settings', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = firstMove(human);
      await t.pumpWidget(
          hintHarness(c, enableDrag: false, dragHintShown: false));

      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      expect(find.text(hintText), findsNothing,
          reason: 'no point advertising a disabled gesture');

      c.disposeController();
    });

    testWidgets('leaving the game screen takes the hint with it', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = firstMove(human);

      // A home route that pushes the game screen, so popping it disposes the
      // GameScreen while the (floating, route-outliving) hint is still up.
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => GameScreen(
                      key: ValueKey(c),
                      controller: c,
                      interactionOptions:
                          const BoardInteractionOptions(enableDrag: true),
                      dragHintShown: false,
                    ),
                  ),
                ),
                child: const Text('play'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('play'));
      await t.pumpAndSettle();

      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text(hintText), findsOneWidget, reason: 'the hint is up');

      // Leave mid-hint: the SnackBar must not follow the user to the next route.
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      nav.pop();
      await t.pumpAndSettle();

      expect(find.byType(GameScreen), findsNothing);
      expect(find.text(hintText), findsNothing,
          reason: 'the game screen clears its own hint on dispose');
      expect(find.byType(SnackBar), findsNothing);

      c.disposeController();
    });
  });

  group('history strip score chip', () {
    // White (human) wins the opening (6 > 1) and moves first; Black is a normal
    // AI, so it REPLIES — the strip's latest line becomes Black's move while
    // White's assessment is still the newest verdict on the local player.
    GameController vsAi(LocalHumanAgent human) => GameController(
          white: human,
          black: FakeAgent(),
          matchLength: 5,
          diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
        );

    testWidgets('persists after the AI replies: the strip shows the AI move '
        'AND the human score', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = vsAi(human);
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await commitFirstMove(t);

      // Wait for BOTH: Black's reply in the log (so the latest line is the AI's)
      // and White's assessment resolving (0.10 - 0.04 = 0.06).
      await pumpUntil(
          t,
          () => c.game.events
              .whereType<MoveEvent>()
              .any((e) => e.player == Player.black),
          maxFrames: 1200);
      await pumpUntil(
          t, () => find.textContaining('−0.060').evaluate().isNotEmpty);

      final strip = find.byKey(const ValueKey('historyStrip'));
      expect(find.descendant(of: strip, matching: find.textContaining('. B ')),
          findsOneWidget,
          reason: "the strip's line text is the AI's move, unchanged");
      expect(find.descendant(of: strip, matching: find.textContaining('−0.060')),
          findsOneWidget,
          reason: "the human's own score persists beside it");
      expect(find.descendant(of: strip, matching: find.byIcon(Icons.circle)),
          findsOneWidget,
          reason: 'with its mark dot');

      c.disposeController();
    });

    testWidgets('the strip stays 32px tall with the chip up', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = vsAi(human);
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await commitFirstMove(t);
      await pumpUntil(
          t, () => find.textContaining('−0.060').evaluate().isNotEmpty);

      expect(t.getSize(find.byKey(const ValueKey('historyStrip'))).height, 32);

      c.disposeController();
    });

    testWidgets('a new game clears the chip', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = vsAi(human);
      final tutor = TutorService(TutorEngine());

      await t.pumpWidget(_tutorHarness(c, tutor));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await commitFirstMove(t);
      await pumpUntil(
          t, () => find.textContaining('−0.060').evaluate().isNotEmpty);

      // End the game the deterministic way: at White's next pre-roll gate,
      // resign a single; the AI accepts.
      await pumpUntil(
          t, () => c.awaitingHumanTurn && c.state.turn == Player.white,
          maxFrames: 1200);
      await t.tap(find.byIcon(Icons.more_vert));
      await t.pumpAndSettle();
      await t.tap(find.text('Resign — single'));
      await pumpUntil(t, () => c.awaitingNextGame, maxFrames: 1200);

      final g1 = c.game;
      await t.tap(find.widgetWithText(FilledButton, 'Next game'));
      await pumpUntil(t, () => !identical(c.game, g1));
      await t.pump();

      final strip = find.byKey(const ValueKey('historyStrip'));
      expect(find.descendant(of: strip, matching: find.byIcon(Icons.circle)),
          findsNothing,
          reason: 'the new game starts with no verdict to show');
      expect(find.descendant(of: strip, matching: find.textContaining('−0.')),
          findsNothing);

      c.disposeController();
    });
  });

  group('hint sheet column headers', () {
    // White (human) moves first against a hanging AI, so the hint sheet can be
    // opened on a live human move-entry and stays open.
    GameController humanMoving(LocalHumanAgent human) => GameController(
          white: human,
          black: HangingMoveAgent(),
          matchLength: 5,
          diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
        );

    Future<void> openHint(WidgetTester t, LocalHumanAgent human) async {
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      await t.tap(find.widgetWithText(OutlinedButton, 'Hint'));
      await pumpUntil(t, () => find.text('Top plays').evaluate().isNotEmpty);
      await pumpUntil(
          t, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    }

    testWidgets('the two number columns are labelled Equity / Loss', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = humanMoving(human);
      await t.pumpWidget(_tutorHarness(c, TutorService(RealRankEngine())));
      await openHint(t, human);

      expect(find.text('Equity'), findsOneWidget);
      expect(find.text('Loss'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('the sheet ⓘ opens the shared metric explainer', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = humanMoving(human);
      await t.pumpWidget(_tutorHarness(c, TutorService(RealRankEngine())));
      await openHint(t, human);

      expect(find.byType(MetricExplainerDialog), findsNothing);
      await t.tap(find.byIcon(Icons.info_outline));
      await t.pumpAndSettle();

      expect(find.byType(MetricExplainerDialog), findsOneWidget);
      expect(find.text('Understanding the metrics'), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Got it'));
      await t.pumpAndSettle();
      expect(find.byType(MetricExplainerDialog), findsNothing);

      c.disposeController();
    });
  });

  group('score + outcome copy', () {
    testWidgets('vs the computer the header names the sides You / AI', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final c = GameController(
        white: LocalHumanAgent(),
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      expect(find.textContaining('You 0–0 AI · to 5'), findsOneWidget);
      expect(find.textContaining('W 0–0 B'), findsNothing,
          reason: 'the cryptic W/B form is gone in a vs-computer match');

      c.disposeController();
    });

    testWidgets('the header score is not truncated on a phone', (t) async {
      // The real capture surface: a 390x844 phone in portrait, where the header
      // has the least room (score + cube chip + Double + overflow on one row).
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));

      final c = GameController(
        white: LocalHumanAgent(),
        black: FakeAgent(),
        matchLength: 3,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      const score = 'You 0–0 AI · to 3';
      expect(find.text(score), findsOneWidget);
      final paragraph = t.renderObject<RenderParagraph>(find.text(score));
      expect(paragraph.didExceedMaxLines, isFalse,
          reason: 'the whole score must fit — no "You 0–0 AI · t…"');
      // Still a single line (the header is one row by design).
      expect(paragraph.size.height, lessThan(30));

      c.disposeController();
    });

    testWidgets('the local side is named first when the human plays Black',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: FakeAgent(),
        black: human,
        matchLength: 5,
        // White (AI) wins the opening and moves; Black (human) then gates.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn, maxFrames: 1200);

      expect(find.textContaining('You 0–0 AI · to 5'), findsOneWidget,
          reason: "the local (Black) score leads, whichever side that is");

      c.disposeController();
    });

    testWidgets('hot-seat keeps the neutral W / B header', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final c = GameController(
        white: LocalHumanAgent(),
        black: LocalHumanAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn || c.isThinking);
      await t.pump();

      expect(find.textContaining('W 0–0 B · to 5'), findsOneWidget,
          reason: 'neither of two local players is "you"');
      expect(find.textContaining('You'), findsNothing);

      c.disposeController();
    });

    testWidgets('opponentLabel renames the non-local side (online: Opp)',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final c = GameController(
        white: LocalHumanAgent(),
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      await t.pumpWidget(MaterialApp(
        home: GameScreen(key: ValueKey(c), controller: c, opponentLabel: 'Opp'),
      ));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      expect(find.textContaining('You 0–0 Opp · to 5'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('game-end copy for a drop names the declined double', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final ai = FakeAgent(doubles: true);
      final c = GameController(
        white: human,
        black: ai,
        matchLength: 5,
        // White moves first; Black then doubles at its pre-roll gate.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );

      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);
      human.submitMove(c.state.legalMoves.first);
      await pumpUntil(t, () => human.pendingCubeRequest.value != null,
          maxFrames: 1200);

      // Decline: Black wins the game's single point by the drop.
      await t.tap(find.widgetWithText(TextButton, 'Pass'));
      await pumpUntil(t, () => c.awaitingNextGame, maxFrames: 1200);

      expect(c.state.result!.outcome, GameOutcome.drop);
      expect(
          find.textContaining(
              'Black wins this game (+1) — White declined the double.'),
          findsOneWidget);

      c.disposeController();
    });
  });

  group('banners never intercept board taps', () {
    /// The board's own paint surface render object — what a board tap must reach.
    RenderObject boardSurface(WidgetTester t) => t.renderObject(find
        .byWidgetPredicate((w) => w is CustomPaint && w.painter is BoardPainter));

    /// Whether a tap at [global] reaches the board rather than being swallowed
    /// by whatever floats over it.
    void expectBoardReachableAt(WidgetTester t, Offset global) {
      final targets =
          t.hitTestOnBinding(global).path.map((e) => e.target).toList();
      expect(targets, contains(boardSurface(t)),
          reason: 'a tap at $global must reach the board surface');
    }

    testWidgets('the no-legal-move hint does not block the bear-off tray under '
        'it', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(5, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn, maxFrames: 1200);
      c.rollDice();
      await pumpUntil(t, () => human.pendingMoveRequest.value != null,
          maxFrames: 1200);

      // Raise the hint (the 24-point is stranded on 5-5).
      await tapBoardPoint(t, 23);
      final hint = find.byType(Material).evaluate();
      expect(hint, isNotEmpty);
      expect(
          find.text('No legal move for that checker with the remaining dice'),
          findsOneWidget);

      // The banner sits over the bottom bear-off tray. A tap in the middle of it
      // must still land on the board — otherwise bear-off taps go dead for the
      // 1.2s the hint is up.
      final banner = t.getRect(
          find.text('No legal move for that checker with the remaining dice'));
      expectBoardReachableAt(t, banner.center);

      c.disposeController();
    });

    testWidgets('the error banner does not block the tray under it', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: ThrowingAgent(),
        matchLength: 3,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.pendingMoveOf(Player.white).value != null);
      await commitFirstMove(t);
      await pumpUntil(t, () => c.error != null);
      await t.pump();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      expectBoardReachableAt(
          t, t.getRect(find.byIcon(Icons.error_outline)).center);

      c.disposeController();
    });
  });

  group('rolling twice in one frame', () {
    /// A match parked at White's (the human's) pre-roll gate.
    GameController atGate() => GameController(
          white: LocalHumanAgent(),
          black: FakeAgent(),
          matchLength: 5,
          diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
        );

    int whiteRolls(GameController c) => c.game.events
        .whereType<RollEvent>()
        .where((e) => e.player == Player.white)
        .length;

    testWidgets('two dice taps in the same frame roll exactly once', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = atGate();
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      final painter = boardPainterOf(t);
      final target = boardRect(t).topLeft +
          painter.geometry.diceRect(c.state.turn, mover: c.state.turn).center;
      // No pump between the taps: BOTH hit the callback captured by the frame
      // that is already on screen, exactly as a real double-tap on the dice
      // does. The second must be swallowed, not throw out of the gesture
      // handler (GameController's gate is already completed by then).
      await t.tapAt(target);
      await t.tapAt(target);
      await t.pump();

      expect(c.error, isNull);
      expect(whiteRolls(c), 1, reason: 'the second tap rolled nothing');
    });

    testWidgets('two Roll presses in the same frame roll exactly once',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final c = atGate();
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      final roll = find.widgetWithText(FilledButton, 'Roll');
      await t.tap(roll);
      await t.tap(roll, warnIfMissed: false);
      await t.pump();

      expect(c.error, isNull);
      expect(whiteRolls(c), 1);
    });
  });

  group('pip counts', () {
    testWidgets('the line is always present and names the local side', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final c = GameController(
        white: LocalHumanAgent(),
        black: FakeAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(3, 1), Dice(6, 5)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => c.awaitingHumanTurn);

      expect(find.byKey(const ValueKey('pipLine')), findsOneWidget);
      // The local (White) side is "You" and the computer takes the opponent
      // label; Black has already played its opening 6-1 by this gate.
      final white = c.state.board.pipCount(Player.white);
      final black = c.state.board.pipCount(Player.black);
      expect(white, 167, reason: 'White has not moved yet');
      expect(black, lessThan(167), reason: 'Black opened');
      expect(find.text('Pips: You $white · AI $black'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('the counts follow the position and match BoardState.pipCount',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final human = LocalHumanAgent();
      final c = GameController(
        white: human,
        black: FakeAgent(),
        matchLength: 5,
        // White wins the opening 6-1 and moves first.
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => human.pendingMoveRequest.value != null);

      expect(find.text('Pips: You 167 · AI 167'), findsOneWidget);
      human.submitMove(c.state.legalMoves.first);
      await pumpUntil(t, () => c.awaitingHumanTurn, maxFrames: 1200);

      final white = c.state.board.pipCount(Player.white);
      final black = c.state.board.pipCount(Player.black);
      expect(white, lessThan(167), reason: 'White has played a move');
      expect(find.text('Pips: You $white · AI $black'), findsOneWidget);

      c.disposeController();
    });

    testWidgets('hot-seat keeps the neutral W / B naming', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final c = GameController(
        white: LocalHumanAgent(),
        black: LocalHumanAgent(),
        matchLength: 5,
        diceRoller: ScriptedDiceRoller(Dice(6, 1), [Dice(6, 5), Dice(4, 3)]),
      );
      await t.pumpWidget(_harness(c));
      await pumpUntil(t, () => find.byKey(const ValueKey('pipLine')).evaluate().isNotEmpty);
      await _dismissPassDevice(t);

      expect(find.text('Pips: W 167 · B 167'), findsOneWidget);

      c.disposeController();
    });
  });

  group('no-legal-move hint', () {
    /// A match parked at White's move with 5-5 from the opening position.
    ///
    /// Black opens 6-1 and replies; White then rolls 5-5, and the two checkers
    /// on the 24-point (index 23) are STRANDED — their only hop, 24/19, lands on
    /// Black's five-strong 19-point (index 18). That is the reported "why am I
    /// not able to move this checker?" shape, reachable from a real game.
    (GameController, LocalHumanAgent) strandedFives() {
      final human = LocalHumanAgent();
      return (
        GameController(
          white: human,
          black: FakeAgent(),
          matchLength: 5,
          // Black wins the opening roll (6 > 1) and moves; White then rolls 5-5.
          diceRoller: ScriptedDiceRoller(Dice(1, 6), [Dice(5, 5), Dice(4, 3)]),
        ),
        human,
      );
    }

    /// Rolls White in and waits for its move request.
    Future<void> reachWhitesMove(
        WidgetTester t, GameController c, LocalHumanAgent human) async {
      await pumpUntil(t, () => c.awaitingHumanTurn, maxFrames: 1200);
      c.rollDice();
      await pumpUntil(t, () => human.pendingMoveRequest.value != null,
          maxFrames: 1200);
      expect(c.state.dice, Dice(5, 5), reason: 'precondition: White rolled 5-5');
      expect(c.state.board.points[18], lessThanOrEqualTo(-2),
          reason: 'precondition: Black still owns the 19-point');
    }

    testWidgets('a dead checker tap surfaces a hint that auto-clears, and the '
        'board never reflows', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final (c, human) = strandedFives();
      await t.pumpWidget(_harness(c));
      await reachWhitesMove(t, c, human);

      final before = t.getRect(find.byType(BoardView));
      expect(find.textContaining('No legal move for that checker'), findsNothing);

      await tapBoardPoint(t, 23);
      expect(
          find.text('No legal move for that checker with the remaining dice'),
          findsOneWidget);
      expect(t.getRect(find.byType(BoardView)), before,
          reason: 'the hint floats over the board — no reflow (F6)');

      // Rate-limited: a second tap replaces the hint rather than stacking one.
      await tapBoardPoint(t, 23);
      expect(find.textContaining('No legal move for that checker'),
          findsOneWidget);

      // It clears itself.
      await t.pump(const Duration(milliseconds: 1300));
      expect(find.textContaining('No legal move for that checker'), findsNothing);
      expect(t.getRect(find.byType(BoardView)), before);

      c.disposeController();
    });

    testWidgets('a staged partial move adds the Undo nudge', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final (c, human) = strandedFives();
      await t.pumpWidget(_harness(c));
      await reachWhitesMove(t, c, human);

      await tapBoardPoint(t, 12); // 13/8 — one of four hops
      await tapBoardPoint(t, 7);
      expect(isButtonEnabled(t, find.widgetWithText(TextButton, 'Undo')), isTrue,
          reason: 'precondition: a partial move is staged');

      await tapBoardPoint(t, 23);
      expect(
          find.text('No legal move for that checker with the remaining dice '
              '— try Undo'),
          findsOneWidget);

      c.disposeController();
    });

    testWidgets('tapping a checker that CAN move stays silent', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final (c, human) = strandedFives();
      await t.pumpWidget(_harness(c));
      await reachWhitesMove(t, c, human);

      await tapBoardPoint(t, 12);
      expect(boardPainterOf(t).selectedCheckerLocation, 12);
      expect(find.textContaining('No legal move for that checker'), findsNothing);

      c.disposeController();
    });
  });
}
