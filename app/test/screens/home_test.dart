import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:aigammon_app/screens/home_screen.dart';
import 'package:aigammon_app/screens/new_match_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/test_database.dart';

/// A no-native [EngineFacade] with instant, always-legal responses: it ranks
/// the real legal moves (so the AI plays something valid) with flat equities,
/// and advises never-double / always-accept. Enough to drive a match to the
/// human's turn gate in a widget test without spawning the engine isolate.
class FakeFacade implements EngineFacade {
  const FakeFacade();

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async =>
      const Probabilities(
        win: 0.5,
        winGammon: 0,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      );

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    const flat = Probabilities(
      win: 0.5,
      winGammon: 0,
      winBackgammon: 0,
      loseGammon: 0,
      loseBackgammon: 0,
    );
    final legal = MoveGenerator.legalMoves(board, mover, dice);
    return [
      for (final move in legal) ScoredMove(move: move, probabilities: flat),
    ];
  }

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      const CubeAdvice(
        shouldDouble: false,
        shouldAccept: true,
        equityCubeless: 0,
        equityNoDouble: 0,
        equityDoubleTake: 0,
      );
}

const _surface = Size(900, 1300);

/// The in-memory database for the current test, overriding the real
/// file-backed [databaseProvider] so match setup persists without touching the
/// disk. Set in [main]'s `setUp`, closed in `tearDown`.
late AppDatabase _db;

Widget _app() => ProviderScope(
      overrides: [
        engineFacadeProvider.overrideWithValue(const FakeFacade()),
        databaseProvider.overrideWithValue(_db),
      ],
      child: const MaterialApp(home: HomeScreen()),
    );

// --- Board-driving helpers (mirror game_screen_test) -------------------------

BoardPainter _painterOf(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .firstWhere((c) => c.painter is BoardPainter)
    .painter as BoardPainter;

Rect _boardRect(WidgetTester t) => t.getRect(
    find.byWidgetPredicate((w) => w is CustomPaint && w.painter is BoardPainter));

Future<void> _tapPoint(WidgetTester t, int index) async {
  final r = _boardRect(t);
  // Read the painter's real orientation so taps land correctly even when the
  // board is flipped for Black in a hot-seat (rotate-for-Black) match.
  final g = _painterOf(t).geometry;
  await t.tapAt(r.topLeft + g.pointRect(index).center);
  await t.pump();
}

bool _enabled(WidgetTester t, Finder f) {
  final w = t.widget(f);
  return w is ButtonStyleButton && w.onPressed != null;
}

/// Drives the interactive board greedily (first highlighted source → first
/// destination) until Confirm is enabled, then commits (or passes a dance).
Future<void> _commitOneMove(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    final confirm = find.widgetWithText(FilledButton, 'Confirm');
    if (confirm.evaluate().isNotEmpty && _enabled(t, confirm)) break;
    final pass = find.text('No moves — pass');
    if (pass.evaluate().isNotEmpty) {
      await t.tap(pass);
      await t.pump();
      return;
    }
    await _tapPoint(t, _painterOf(t).highlightedSources.first);
    await _tapPoint(t, _painterOf(t).highlightedDestinations.first);
  }
  await t.tap(find.widgetWithText(FilledButton, 'Confirm'));
  await t.pump();
}

/// Runs the match — committing any human opening move and dismissing hot-seat
/// pass-device gates — until a human pre-roll gate opens (Roll enabled). The
/// engine (fake) moves instantly, so the only points that stall are human ones.
Future<void> _driveToRollGate(WidgetTester t, {int maxSteps = 60}) async {
  for (var i = 0; i < maxSteps; i++) {
    final roll = find.widgetWithText(FilledButton, 'Roll');
    if (roll.evaluate().isNotEmpty && _enabled(t, roll)) return;
    final pass = find.text('Tap to continue');
    if (pass.evaluate().isNotEmpty) {
      await t.tap(pass);
      await t.pump();
      continue;
    }
    if (_painterOf(t).highlightedSources.isNotEmpty ||
        find.text('No moves — pass').evaluate().isNotEmpty) {
      await _commitOneMove(t);
      continue;
    }
    await t.pump(const Duration(milliseconds: 1));
  }
  fail('never reached the human roll gate');
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    _db = newTestDatabase();
  });
  tearDown(() => _db.close());

  testWidgets('home shows both mode buttons; vs-computer reveals AI selectors, '
      'two-players hides them', (t) async {
    await t.pumpWidget(_app());

    expect(find.text('AIGammon'), findsOneWidget);
    expect(find.text('Play vs Computer'), findsOneWidget);
    expect(find.text('Two Players'), findsOneWidget);

    // Play vs Computer → difficulty + side selectors appear.
    await t.tap(find.text('Play vs Computer'));
    await t.pumpAndSettle();
    expect(find.byType(NewMatchScreen), findsOneWidget);
    expect(find.text('Difficulty'), findsOneWidget);
    expect(find.text('Your side'), findsOneWidget);
    // vs-computer has no hot-seat rotate toggle.
    expect(find.text('Rotate board for Black'), findsNothing);

    // Back to home, then Two Players → those selectors are gone.
    await t.pageBack();
    await t.pumpAndSettle();
    await t.tap(find.text('Two Players'));
    await t.pumpAndSettle();
    expect(find.byType(NewMatchScreen), findsOneWidget);
    expect(find.text('Match length'), findsOneWidget);
    expect(find.text('Difficulty'), findsNothing);
    expect(find.text('Your side'), findsNothing);
    // Hot-seat exposes the rotate-for-Black toggle.
    expect(find.text('Rotate board for Black'), findsOneWidget);
  });

  testWidgets('vs computer: Start builds a controller and the match runs to a '
      'human roll gate', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(_app());
    await t.tap(find.text('Play vs Computer'));
    await t.pumpAndSettle();

    // A 1-point match keeps the run short (single, Crawford game).
    await t.tap(find.text('1'));
    await t.pump();

    await t.tap(find.text('Start match'));
    await t.pumpAndSettle();
    expect(find.byType(GameScreen), findsOneWidget);

    // The match actually plays (AI moves via the fake facade) through to the
    // human's pre-roll gate — proving controller + agent wiring end to end.
    await _driveToRollGate(t);
    expect(find.widgetWithText(FilledButton, 'Roll'), findsOneWidget);
  });

  testWidgets('vs computer: starting a match persists a match row', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(_app());
    await t.tap(find.text('Play vs Computer'));
    await t.pumpAndSettle();

    await t.tap(find.text('1'));
    await t.pump();
    await t.tap(find.text('Start match'));
    await t.pumpAndSettle();
    expect(find.byType(GameScreen), findsOneWidget);

    // The setup screen created the match row in the (overridden) in-memory db.
    // Drift I/O needs the real event loop (runAsync); the row insert is
    // fire-and-forget from the controller, so poll briefly until it lands.
    final rows = await t.runAsync(() async {
      final repo = MatchRepository(_db);
      for (var i = 0; i < 100; i++) {
        final r = await repo.watchMatches().first;
        if (r.isNotEmpty) return r;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return const <MatchRow>[];
    });
    expect(rows, isNotNull);
    expect(rows!, hasLength(1));
    expect(rows.single.mode, 'vsComputer');
    expect(rows.single.matchLength, 1);
    // Human plays White by default; AI is Black at the chosen difficulty.
    expect(rows.single.whiteType, 'human');
    expect(rows.single.blackType, startsWith('ai:'));
  });

  testWidgets('hot-seat: Start pushes the game and a human roll gate opens',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(_app());
    await t.tap(find.text('Two Players'));
    await t.pumpAndSettle();

    await t.tap(find.text('Start match'));
    await t.pumpAndSettle();
    expect(find.byType(GameScreen), findsOneWidget);

    await _driveToRollGate(t);
    expect(find.widgetWithText(FilledButton, 'Roll'), findsOneWidget);
  });

  bool tutorSwitchValue(WidgetTester t) => t
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Tutor mode'))
      .value;

  group('tutor toggle', () {
    testWidgets('vs-computer easy defaults ON, expert defaults OFF', (t) async {
      await t.pumpWidget(_app());
      await t.tap(find.text('Play vs Computer'));
      await t.pumpAndSettle();

      // Default difficulty is medium -> ON.
      expect(tutorSwitchValue(t), isTrue);

      await t.tap(find.text('Easy'));
      await t.pumpAndSettle();
      expect(tutorSwitchValue(t), isTrue, reason: 'easy -> ON');

      await t.tap(find.text('Expert'));
      await t.pumpAndSettle();
      expect(tutorSwitchValue(t), isFalse, reason: 'expert -> OFF');

      await t.tap(find.text('Hard'));
      await t.pumpAndSettle();
      expect(tutorSwitchValue(t), isFalse, reason: 'hard -> OFF');
    });

    testWidgets('hot-seat defaults OFF', (t) async {
      await t.pumpWidget(_app());
      await t.tap(find.text('Two Players'));
      await t.pumpAndSettle();
      expect(tutorSwitchValue(t), isFalse);
    });

    testWidgets('user override is sticky across difficulty changes', (t) async {
      await t.pumpWidget(_app());
      await t.tap(find.text('Play vs Computer'));
      await t.pumpAndSettle();

      // At expert the default is OFF; the user turns it ON.
      await t.tap(find.text('Expert'));
      await t.pumpAndSettle();
      expect(tutorSwitchValue(t), isFalse);
      await t.tap(find.widgetWithText(SwitchListTile, 'Tutor mode'));
      await t.pumpAndSettle();
      expect(tutorSwitchValue(t), isTrue);

      // Switching to another OFF-default difficulty must NOT reset it.
      await t.tap(find.text('Hard'));
      await t.pumpAndSettle();
      expect(tutorSwitchValue(t), isTrue,
          reason: 'a touched toggle stays authoritative');
    });
  });

  testWidgets('back from setup returns to home', (t) async {
    await t.pumpWidget(_app());
    await t.tap(find.text('Play vs Computer'));
    await t.pumpAndSettle();
    expect(find.byType(NewMatchScreen), findsOneWidget);

    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Play vs Computer'), findsOneWidget);
    expect(find.text('Two Players'), findsOneWidget);
  });
}
