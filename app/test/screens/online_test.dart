import 'dart:async';

import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/online/online_providers.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:aigammon_app/screens/online_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_client/online_client.dart';

import 'package:aigammon_app/online/online_session_store.dart';

import '../data/test_database.dart';
import '../online/fake_match_api.dart';

/// A no-native [EngineFacade] with instant, flat responses — enough for the
/// online [TutorService] the game screen constructs (it never blocks a test).
class FakeFacade implements EngineFacade {
  const FakeFacade();

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
    return [for (final m in legal) ScoredMove(move: m, probabilities: _flat)];
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

/// A [FakeMatchApi] wired for the create/join screen: `createMatch` hands out
/// `ABC123`, an invisible opponent takes the guest seat after [activeAfter]
/// `fetchMatch` calls, and the match goes live with a sound opening roll already
/// in its log (there is no second client here to make one, and the
/// [NetMatchController] the screen launches cannot become ready without it).
FakeMatchApi screenApi(FakeBackend backend, {int activeAfter = 1}) =>
    FakeMatchApi(backend, 'me')
      ..nextCode = 'ABC123'
      ..autoJoinAfterFetches = activeAfter
      ..autoSeedOpening = true;

/// A match sitting open under [code], for the join flow to claim.
FakeMatch _waitingMatch(FakeBackend backend, String code) {
  final m = FakeMatch(
    code: code,
    hostUid: 'their-host',
    length: 5,
    cubeless: false,
    status: 'waiting',
  );
  backend.matches[code] = m;
  return m;
}

/// The online screen under test. [configured] false overrides the config to
/// `null` (the not-configured case); otherwise the emulator config is used.
///
/// [db] backs the (now history-persisted) online launch: `_launch` inserts a
/// match row through the repository over [databaseProvider], so the tests pass
/// an in-memory db to keep off the real drift store.
Widget _app(FakeMatchApi api, {bool configured = true, required AppDatabase db}) {
  return ProviderScope(
    overrides: [
      onlineConfigProvider
          .overrideWithValue(configured ? OnlineConfig.emulator() : null),
      matchApiProvider.overrideWith((ref) async => api),
      // The lobby's api is a FAKE with no Firestore behind it, so there is
      // nothing to open a real-time gRPC stream to: every match here runs on the
      // transport's poll loop. (The transport would degrade to exactly that by
      // itself, but saying so keeps the test free of a retry timer.)
      listenChannelBuilderProvider.overrideWithValue((_) => null),
      engineFacadeProvider.overrideWithValue(const FakeFacade()),
      databaseProvider.overrideWithValue(db),
      // Launching a game reads settingsProvider (for animation speed); serve a
      // static value so the test avoids the real drift store and its watch-timer.
      settingsProvider.overrideWith((ref) => Stream.value(AppSettings.defaults)),
    ],
    child: const MaterialApp(home: OnlineScreen()),
  );
}

/// Pumps (firing the 2s poll timers) until [finder] matches or [tries] elapse.
Future<void> _pumpUntil(WidgetTester t, Finder finder, {int tries = 40}) async {
  for (var i = 0; i < tries; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await t.pump(const Duration(seconds: 2));
  }
}

void main() {
  const surface = Size(900, 1400);

  late AppDatabase db;
  late FakeBackend backend;
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = newTestDatabase();
    backend = FakeBackend();
  });
  tearDown(() async {
    await db.close();
  });

  testWidgets('config null shows the not-configured card, no crash', (t) async {
    await t.pumpWidget(
        _app(screenApi(backend), configured: false, db: db));
    await t.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('configured'), findsWidgets);
    // No create/join controls when unconfigured.
    expect(find.text('Create match'), findsNothing);
    expect(find.text('Join match'), findsNothing);
  });

  testWidgets('create flow: code shown, then active → GameScreen pushed',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    // waiting on the first fetch, active on the second.
    final api = screenApi(backend, activeAfter: 2);
    await t.pumpWidget(_app(api, db: db));
    await t.pumpAndSettle();

    expect(find.text('Create match'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Create'));
    // Let createMatch resolve and the code render.
    await t.pump();
    await t.pump();
    expect(find.text('ABC123'), findsOneWidget);
    expect(find.text('Waiting for opponent…'), findsOneWidget);

    // Poll to active, then the controller reaches readiness and the game opens.
    await _pumpUntil(t, find.byType(GameScreen));
    expect(find.byType(GameScreen), findsOneWidget);
    expect(api.calls['createMatch'], 1);
  });

  testWidgets('join flow: enter code → GameScreen pushed with the uppercased code',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final api = screenApi(backend);
    _waitingMatch(backend, 'ABC123');
    await t.pumpWidget(_app(api, db: db));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), 'abc123');
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Join'));

    await _pumpUntil(t, find.byType(GameScreen));
    expect(find.byType(GameScreen), findsOneWidget);
    expect(api.joinCodes, ['ABC123']); // trimmed + uppercased
  });

  testWidgets('join flow persists an online match row (joiner is Black)',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final api = screenApi(backend);
    _waitingMatch(backend, 'ABC123');
    await t.pumpWidget(_app(api, db: db));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), 'abc123');
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Join'));
    await _pumpUntil(t, find.byType(GameScreen));
    expect(find.byType(GameScreen), findsOneWidget);

    // The launch inserted an online match row over the in-memory db. The joiner
    // plays Black, so blackType is 'human' and whiteType (the opponent) 'remote'.
    final rows =
        await t.runAsync(() => MatchRepository(db).watchMatches().first);
    expect(rows, isNotNull);
    expect(rows!.length, 1);
    final row = rows.first;
    expect(row.mode, 'online');
    expect(row.matchLength, 5);
    expect(row.whiteType, 'remote');
    expect(row.blackType, 'human');
    expect(row.completed, isFalse);
  });

  testWidgets('join error: inline error shown, field editable, retry works',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    // Nothing seeded under ZZZZZZ, so the first join is a genuine NOT_FOUND.
    final api = screenApi(backend);

    await t.pumpWidget(_app(api, db: db));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), 'ZZZZZZ');
    await t.tap(find.widgetWithText(FilledButton, 'Join'));
    await t.pump();
    await t.pump();

    expect(find.text('No match with that code. Check it and try again.'),
        findsOneWidget);
    expect(find.byType(GameScreen), findsNothing);
    // The field is still editable (not disabled).
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isTrue);

    // The match appears (the host created it a moment later) and the retry — the
    // same field, the same code — goes through.
    _waitingMatch(backend, 'ZZZZZZ');
    await t.tap(find.widgetWithText(FilledButton, 'Join'));
    await _pumpUntil(t, find.byType(GameScreen));
    expect(find.byType(GameScreen), findsOneWidget);
    expect(api.joinCodes, ['ZZZZZZ', 'ZZZZZZ']);
  });

  testWidgets('cancel-while-waiting stops polling without errors', (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    // Never becomes active, so the flow parks in the waiting state.
    final api = screenApi(backend, activeAfter: 1000);
    await t.pumpWidget(_app(api, db: db));
    await t.pumpAndSettle();

    await t.tap(find.widgetWithText(FilledButton, 'Create'));
    await t.pump();
    await t.pump();
    await t.pump();
    expect(find.text('Waiting for opponent…'), findsOneWidget);

    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await t.pump();

    // Back to the create/join view; no game was pushed.
    expect(find.text('Match length'), findsOneWidget);
    expect(find.byType(GameScreen), findsNothing);

    // No poll timer outlives the cancel (advancing time triggers nothing).
    await t.pump(const Duration(seconds: 6));
    expect(find.byType(GameScreen), findsNothing);
  });

  group('rejoin after a restart', () {
    /// A live match this device is ALREADY a participant of, plus the resume
    /// pointer a previous launch would have left behind.
    Future<FakeMatch> seedResumable(String code) async {
      final m = FakeMatch(
        code: code,
        hostUid: 'me', // the local uid — we are the host of this one
        guestUid: 'them',
        length: 5,
        cubeless: false,
        status: 'active',
      );
      backend.matches[code] = m;
      seedOpening(m, whiteDie: 6, blackDie: 3);
      await OnlineSessionStore(db).rememberMatch(code);
      return m;
    }

    testWidgets('the card offers the stored match and Rejoin re-enters it',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await seedResumable('RESUME12');
      await t.pumpWidget(_app(screenApi(backend), db: db));
      await t.pumpAndSettle();

      expect(find.text('Match in progress'), findsOneWidget);
      expect(find.textContaining('RESUME12'), findsOneWidget);

      await t.tap(find.widgetWithText(FilledButton, 'Rejoin'));
      await _pumpUntil(t, find.byType(GameScreen));
      expect(find.byType(GameScreen), findsOneWidget);
    });

    testWidgets('no stored match means no card', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(_app(screenApi(backend), db: db));
      await t.pumpAndSettle();
      expect(find.text('Match in progress'), findsNothing);
    });

    testWidgets('a finished match is dropped rather than offered as a dead door',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final m = await seedResumable('DONE1234');
      m.status = 'complete';

      await t.pumpWidget(_app(screenApi(backend), db: db));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Rejoin'));
      await t.pump();
      await t.pump();

      expect(find.byType(GameScreen), findsNothing);
      // The card is gone (there is nothing to rejoin) and a snackbar says why.
      expect(find.text('Match in progress'), findsNothing);
      expect(find.widgetWithText(SnackBar, 'That match has finished — nothing '
          'left to rejoin.'), findsOneWidget);
      // The pointer is gone, so the card does not come back next launch.
      expect(await OnlineSessionStore(db).lastMatchCode(), isNull);
    });

    testWidgets('Forget this match clears the card', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await seedResumable('RESUME12');
      await t.pumpWidget(_app(screenApi(backend), db: db));
      await t.pumpAndSettle();
      expect(find.text('Match in progress'), findsOneWidget);

      await t.tap(find.widgetWithText(TextButton, 'Forget this match'));
      await t.pumpAndSettle();

      expect(find.text('Match in progress'), findsNothing);
      expect(await OnlineSessionStore(db).lastMatchCode(), isNull);
    });

    testWidgets('typing your OWN code into Join resumes instead of failing',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      // Both seats are taken and one of them is ours: joinMatch refuses by
      // design (it only ever claims an EMPTY seat), so the screen has to fall
      // back to a read-and-resume rather than showing "the seat has been taken".
      final api = screenApi(backend);
      await seedResumable('RESUME12');
      await OnlineSessionStore(db).forgetMatch(); // no card; use the field
      await t.pumpWidget(_app(api, db: db));
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextField), 'resume12');
      await t.tap(find.widgetWithText(FilledButton, 'Join'));
      await _pumpUntil(t, find.byType(GameScreen));

      expect(find.byType(GameScreen), findsOneWidget);
      expect(find.textContaining('seat has been taken'), findsNothing);
    });
  });
}
