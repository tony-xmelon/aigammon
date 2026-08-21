import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/branding/app_mark.dart';
import 'package:aigammon_app/branding/app_version.dart';
import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/screens/buddy/buddy_setup_screen.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:aigammon_app/screens/home_screen.dart';
import 'package:aigammon_app/screens/new_match_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/foundation.dart';
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
        // NewMatchScreen reads its defaults from settingsProvider; serve them
        // from a plain stream so the widget test stays off drift's watch-timer
        // (which otherwise lingers past tree disposal), mirroring history_test.
        // The real defaults (drag ON, hint not yet shown) are served verbatim:
        // the one-time hint SnackBar floats ABOVE the bottom action bar, so it
        // does not obscure the Roll/Confirm buttons these setup-flow tests tap.
        settingsProvider.overrideWith((ref) => Stream.value(AppSettings.defaults)),
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

/// The one LIVE button among [f]'s matches, or `null` when none of them is
/// enabled.
///
/// A given label can be on screen twice: the tabletop hot-seat layout (the
/// default for two players on one device) mounts an action bar at EACH player's
/// edge, so at any moment one copy carries the callback and the other is the
/// inert reservation belonging to the player whose turn it is not. Driving the
/// UI therefore means pressing the enabled one, whichever edge it is at.
Finder? _liveButton(WidgetTester t, Finder f) {
  for (final element in f.evaluate()) {
    final w = element.widget;
    if (w is ButtonStyleButton && w.onPressed != null) return find.byWidget(w);
  }
  return null;
}

bool _enabled(WidgetTester t, Finder f) => _liveButton(t, f) != null;

/// Drives the interactive board greedily (first highlighted source → first
/// destination) until Confirm is enabled, then commits (or passes a dance).
Future<void> _commitOneMove(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    final confirm = find.widgetWithText(FilledButton, 'Confirm');
    if (_enabled(t, confirm)) break;
    final pass =
        _liveButton(t, find.widgetWithText(FilledButton, 'No moves — pass'));
    if (pass != null) {
      await t.tap(pass);
      await t.pump();
      return;
    }
    await _tapPoint(t, _painterOf(t).highlightedSources.first);
    await _tapPoint(t, _painterOf(t).highlightedDestinations.first);
  }
  await t.tap(_liveButton(t, find.widgetWithText(FilledButton, 'Confirm'))!);
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
    // The two remote modes sit below the local ones, nearby before online.
    expect(find.text('Play Nearby'), findsOneWidget);
    expect(find.text('Play Online'), findsOneWidget);
    expect(t.getTopLeft(find.text('Play Nearby')).dy,
        lessThan(t.getTopLeft(find.text('Play Online')).dy));

    // Play vs Computer → difficulty + side selectors appear.
    await t.tap(find.text('Play vs Computer'));
    await t.pumpAndSettle();
    expect(find.byType(NewMatchScreen), findsOneWidget);
    expect(find.text('Difficulty'), findsOneWidget);
    expect(find.text('Your side'), findsOneWidget);
    // The board-rotation choice is no longer a per-match switch on either mode:
    // it moved to Settings ("Rotate board between turns", default off).
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
    // Hot-seat setup carries no rotation switch either — two players share a
    // FIXED board by default (the tabletop layout).
    expect(find.text('Rotate board for Black'), findsNothing);
    expect(find.text('Rotate board between turns'), findsNothing);
  });

  group('first impression (phone portrait)', () {
    const phone = Size(390, 844);

    Future<void> pumpPhone(WidgetTester t) async {
      await t.binding.setSurfaceSize(phone);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_app());
    }

    testWidgets('home leads with the brand mark and closes with the version',
        (t) async {
      await pumpPhone(t);

      // The hero: the same painted mark as the launcher icon, above the title.
      expect(find.byType(AppMark), findsOneWidget);
      expect(t.getBottomLeft(find.byType(AppMark)).dy,
          lessThan(t.getTopLeft(find.text('AIGammon')).dy));

      // The version sits in the bottom band, not in the content cluster.
      final footer = find.text('v$appVersion');
      expect(footer, findsOneWidget);
      expect(t.getBottomLeft(footer).dy, greaterThan(phone.height - 60));

      // The identity cluster reads in the upper half — the old layout left the
      // whole top of the screen empty.
      expect(t.getTopLeft(find.byType(AppMark)).dy,
          lessThan(phone.height * 0.35));
    });

    testWidgets('setup form starts under the app bar, not mid-screen',
        (t) async {
      await pumpPhone(t);
      await t.tap(find.text('Play vs Computer'));
      await t.pumpAndSettle();

      // App bar is 56 tall; with the form's 16pt top padding the first caption
      // lands around y=72. The old centred layout put it past y=400.
      expect(t.getTopLeft(find.text('Match length')).dy, lessThan(120));
    });
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
    // Production wires hot-seat as TABLETOP by default: a fixed board with an
    // action bar at each player's edge, the top one rotated a half turn.
    expect(t.widget<GameScreen>(find.byType(GameScreen)).tabletop, isTrue);
    expect(find.byKey(const ValueKey('topActionBar')), findsOneWidget);

    await _driveToRollGate(t);
    // Both bars carry a Roll; exactly one of them is live (the player on turn).
    final rolls = find.widgetWithText(FilledButton, 'Roll');
    expect(rolls, findsNWidgets(2));
    expect(_liveButton(t, rolls), isNotNull);
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

  group('the Buddy Mode entry', () {
    // A belt-and-braces reset for a test that fails part way through; the
    // desktop test below clears the override inside its own body, because
    // `testWidgets` checks the foundation debug variables before any teardown
    // registered against it has run.
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    testWidgets('sits with the local modes on a phone and opens its setup',
        (t) async {
      await t.pumpWidget(_app());

      final buddy = find.text('Play with Buddy');
      expect(buddy, findsOneWidget);
      // A local mode, listed with the other two and above the remote pair.
      expect(t.getTopLeft(find.text('Two Players')).dy,
          lessThan(t.getTopLeft(buddy).dy));
      expect(t.getTopLeft(buddy).dy,
          lessThan(t.getTopLeft(find.text('Play Nearby')).dy));

      await t.tap(buddy);
      await t.pumpAndSettle();
      expect(find.byType(BuddySetupScreen), findsOneWidget);
    });

    testWidgets('is not offered on a desktop, which has no board to watch',
        (t) async {
      // Buddy Mode is a camera propped over a real board and a voice reading
      // the play out loud, and this app also runs on Windows and Linux, where
      // it has neither. The entry is hidden rather than shown-and-refused.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await t.pumpWidget(_app());

      expect(find.text('Play with Buddy'), findsNothing);
      expect(find.text('Play Nearby'), findsOneWidget,
          reason: 'the rest of the home screen is unaffected — Play Nearby '
              'works perfectly well through a typed address');

      debugDefaultTargetPlatformOverride = null;
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
