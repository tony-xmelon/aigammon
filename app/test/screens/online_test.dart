import 'dart:async';

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

/// A scriptable [MatchApi] stand-in for the online screen.
///
/// `createMatch`/`joinMatch` return canned ids; `fetchMatch` reports `waiting`
/// until the [activeAfter]-th call, then `active`; `fetchEventsSince` serves
/// [log] (seed it with an opening roll so a launched controller reaches
/// readiness); `pollEvents` is an idle stream (no timers). `joinMatch` throws
/// [joinError] when set.
class FakeMatchApi implements MatchApi {
  FakeMatchApi({this.activeAfter = 1});

  final int activeAfter;
  String createdCode = 'ABC123';
  String createdMatchId = 'm-created';
  String joinedMatchId = 'm-joined';
  Object? joinError;

  List<RemoteEvent> log = [];

  int createMatchCalls = 0;
  int fetchMatchCalls = 0;
  final List<String> joinCodes = [];
  final _poll = StreamController<RemoteEvent>();

  @override
  Future<({String matchId, String code})> createMatch(int matchLength) async {
    createMatchCalls++;
    return (matchId: createdMatchId, code: createdCode);
  }

  @override
  Future<String> joinMatch(String code) async {
    joinCodes.add(code);
    final err = joinError;
    if (err != null) throw err;
    return joinedMatchId;
  }

  @override
  Future<MatchSnapshot> fetchMatch(String matchId) async {
    fetchMatchCalls++;
    final active = fetchMatchCalls >= activeAfter;
    return _snap(status: active ? 'active' : 'waiting');
  }

  @override
  Future<List<RemoteEvent>> fetchEventsSince(
          String matchId, int afterSeq) async =>
      [for (final e in log) if (e.seq > afterSeq) e];

  @override
  Stream<RemoteEvent> pollEvents(String matchId,
          {Duration interval = const Duration(seconds: 2)}) =>
      _poll.stream;

  @override
  Future<Dice> rollDice(String matchId) async => Dice(1, 2);

  @override
  Future<int> submitEvent(String matchId, GameEvent event,
          {GameResultClaim? result}) async =>
      1;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

MatchSnapshot _snap({required String status, int matchLength = 5}) =>
    MatchSnapshot(
      status: status,
      code: 'ABC123',
      matchLength: matchLength,
      gameNo: 1,
      seq: 0,
      whiteUid: 'w',
      blackUid: status == 'active' ? 'b' : null,
      whiteScore: 0,
      blackScore: 0,
      turn: Player.white,
      phase: GamePhase.moving,
      isCrawford: false,
      crawfordPlayed: false,
      winner: null,
    );

/// An opening-roll log (white first: 6 > 3) so a launched controller folds a
/// game and becomes ready.
List<RemoteEvent> _openingLog() => const [
      RemoteEvent(
        seq: 0,
        gameNo: 1,
        event: OpeningRollEvent(whiteDie: 6, blackDie: 3),
      ),
    ];

/// The online screen under test. [configured] false overrides the config to
/// `null` (the not-configured case); otherwise the emulator config is used.
Widget _app(FakeMatchApi api, {bool configured = true}) {
  return ProviderScope(
    overrides: [
      onlineConfigProvider
          .overrideWithValue(configured ? OnlineConfig.emulator() : null),
      matchApiProvider.overrideWith((ref) async => api),
      engineFacadeProvider.overrideWithValue(const FakeFacade()),
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

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('config null shows the not-configured card, no crash', (t) async {
    await t.pumpWidget(_app(FakeMatchApi(), configured: false));
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
    final api = FakeMatchApi(activeAfter: 2)..log = _openingLog();
    await t.pumpWidget(_app(api));
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
    expect(api.createMatchCalls, 1);
  });

  testWidgets('join flow: enter code → GameScreen pushed with the uppercased code',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final api = FakeMatchApi(activeAfter: 1)..log = _openingLog();
    await t.pumpWidget(_app(api));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), 'abc123');
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Join'));

    await _pumpUntil(t, find.byType(GameScreen));
    expect(find.byType(GameScreen), findsOneWidget);
    expect(api.joinCodes, ['ABC123']); // trimmed + uppercased
  });

  testWidgets('join error: inline error shown, field editable, retry works',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final api = FakeMatchApi(activeAfter: 1)..log = _openingLog();
    api.joinError = const OnlineException('not-found', 'No match with that code.');

    await t.pumpWidget(_app(api));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), 'ZZZZZZ');
    await t.tap(find.widgetWithText(FilledButton, 'Join'));
    await t.pump();
    await t.pump();

    expect(find.text('No match with that code.'), findsOneWidget);
    expect(find.byType(GameScreen), findsNothing);
    // The field is still editable (not disabled).
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isTrue);

    // Clear the fault and retry — the same field, a real join now succeeds.
    api.joinError = null;
    await t.tap(find.widgetWithText(FilledButton, 'Join'));
    await _pumpUntil(t, find.byType(GameScreen));
    expect(find.byType(GameScreen), findsOneWidget);
    expect(api.joinCodes, ['ZZZZZZ', 'ZZZZZZ']);
  });

  testWidgets('cancel-while-waiting stops polling without errors', (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    // Never becomes active, so the flow parks in the waiting state.
    final api = FakeMatchApi(activeAfter: 1000)..log = _openingLog();
    await t.pumpWidget(_app(api));
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
}
