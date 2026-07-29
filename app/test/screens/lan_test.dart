import 'dart:async';
import 'dart:io' show SocketException;

import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/lan/lan_transport.dart';
import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:aigammon_app/screens/lan_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';

import '../data/test_database.dart';

/// A no-native [EngineFacade] with instant, flat answers — enough for the
/// [TutorService] the game screen builds, without spawning the engine isolate.
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

/// The screen's whole view of the network, scripted.
///
/// Nothing here binds a socket: hosting hands back a REAL [InMemoryBackend] (so
/// the host's [NetMatchController] folds a real log and the game screen gets a
/// real match) with the presence signal under the test's thumb, and joining hands
/// back a session whose states and welcome the test drives by hand.
class FakeTransport implements NearbyTransport {
  @override
  String deviceName = 'TestPhone';

  /// What the next sweep reports.
  List<DiscoveredHost> hosts = [];

  /// What [localAddress] answers; null exercises the "no address" copy.
  String? address = '192.168.1.5';

  /// Set to make [startHosting] fail.
  Object? hostError;

  FakeHostSession? hostSession;
  FakeGuestSession? guestSession;

  int discoverCalls = 0;
  final List<({String address, int port, String code, String name})> joins = [];

  @override
  Future<HostSession> startHosting({
    required MatchConfig config,
    required String name,
  }) async {
    final error = hostError;
    if (error != null) throw error;
    return hostSession = FakeHostSession(config);
  }

  @override
  Future<List<DiscoveredHost>> discover({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    discoverCalls++;
    return hosts;
  }

  @override
  GuestSession join({
    required String address,
    required int port,
    required String code,
    required String name,
  }) {
    joins.add((address: address, port: port, code: code, name: name));
    return guestSession = FakeGuestSession();
  }

  @override
  Future<String?> localAddress() async => address;
}

/// A hosting session over an in-memory backend, with the guest arriving on cue.
class FakeHostSession implements HostSession {
  FakeHostSession(this.config)
      : backend = InMemoryBackend(
          config: config,
          matchCode: '4271',
          resumeToken: 'TESTTOKEN',
          capabilities: const Capabilities(durable: false, rejoinable: false),
        );

  @override
  final MatchConfig config;

  final InMemoryBackend backend;

  @override
  String roomCode = '4271';

  @override
  int port = 47780;

  @override
  Player get localSide => TransportSession.hostSide;

  @override
  final ValueNotifier<bool> guestConnected = ValueNotifier<bool>(false);

  @override
  String? guestName;

  bool stopped = false;

  InMemoryTransport? _peer;

  @override
  NetMatchController controller({
    MatchPersistence persistence = const NoopPersistence(),
  }) =>
      NetMatchController(
        transport: InMemoryTransport.host(backend),
        persistence: persistence,
      );

  @override
  Future<void> stop() async {
    stopped = true;
    await _peer?.dispose();
    _peer = null;
  }

  /// A guest presents the code: its endpoint attaches (which is what makes the
  /// host's `opponentPresent` true), game 1 opens with a SOUND commit-reveal
  /// roll, then presence flips — the same order the real relay uses.
  void guestArrives({String name = 'Bo'}) {
    guestName = name;
    _peer ??= InMemoryTransport.guest(backend);
    backend.seedOpening(whiteDie: 6, blackDie: 1);
    guestConnected.value = true;
  }
}

/// A guest session the test drives: it never connects to anything.
class FakeGuestSession implements GuestSession {
  FakeGuestSession() {
    // Keeps a scripted failure from surfacing as an unhandled async error.
    _welcome.future.then<void>((_) {}, onError: (Object _) {});
  }

  final _states = StreamController<GuestConnectionState>.broadcast();
  final _welcome = Completer<WelcomeMessage>();

  @override
  GuestConnectionState state = const GuestConnectionState.connecting();

  bool disposed = false;

  @override
  Stream<GuestConnectionState> get states => _states.stream;

  @override
  Future<WelcomeMessage> get welcome => _welcome.future;

  @override
  Player get localSide => Player.black;

  @override
  MatchConfig get config => const MatchConfig(length: 5);

  @override
  NetMatchController controller({
    MatchPersistence persistence = const NoopPersistence(),
  }) =>
      throw UnimplementedError('the join tests stop before the board');

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_states.isClosed) await _states.close();
  }

  void emit(GuestConnectionState next) {
    state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// A terminal handshake failure — what a wrong code looks like.
  void fail(String reason) {
    emit(GuestConnectionState.failed(reason));
    if (!_welcome.isCompleted) {
      _welcome.completeError(GuestHandshakeException(reason));
    }
  }
}

void main() {
  const surface = Size(900, 1400);

  late AppDatabase db;
  late FakeTransport transport;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = newTestDatabase();
    transport = FakeTransport();
  });
  tearDown(() => db.close());

  Widget app() => ProviderScope(
        overrides: [
          nearbyTransportProvider.overrideWithValue(transport),
          engineFacadeProvider.overrideWithValue(const FakeFacade()),
          databaseProvider.overrideWithValue(db),
          // A plain stream keeps the test off drift's watch-timer.
          settingsProvider
              .overrideWith((ref) => Stream.value(AppSettings.defaults)),
        ],
        child: const MaterialApp(home: LanScreen()),
      );

  /// Pump until [finder] matches. Never `pumpAndSettle`: the waiting and
  /// probing states carry a [CircularProgressIndicator], which never settles.
  Future<void> pumpUntil(WidgetTester t, Finder finder, {int tries = 60}) async {
    for (var i = 0; i < tries; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> openJoinTab(WidgetTester t) async {
    await t.tap(find.text('Join'));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  group('host tab', () {
    testWidgets('start hosting shows the room code, the address and a wait',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();

      expect(find.text('Host a game'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.text('4271'));

      // The code is the secret, shown large; the address is the manual-entry
      // fallback for a network where discovery does not get through.
      expect(find.text('4271'), findsOneWidget);
      expect(find.text('192.168.1.5:47780'), findsOneWidget);
      expect(find.text('Waiting for a player…'), findsOneWidget);
      expect(find.byType(GameScreen), findsNothing);
    });

    testWidgets('without a local address the copy still tells the user what '
        'to do', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.address = null;

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.text('4271'));

      expect(find.textContaining('Listening on port 47780'), findsOneWidget);
    });

    testWidgets('a guest joining opens the game screen', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.text('4271'));

      transport.hostSession!.guestArrives();
      await pumpUntil(t, find.byType(GameScreen));

      expect(find.byType(GameScreen), findsOneWidget);
      // A real match, folded from the relay's own log.
      expect(find.textContaining('Game 1'), findsWidgets);
    });

    testWidgets('the launched match is persisted as a lan match', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.text('4271'));
      transport.hostSession!.guestArrives();
      await pumpUntil(t, find.byType(GameScreen));

      final rows = await t.runAsync(() async {
        final repo = MatchRepository(db);
        for (var i = 0; i < 100; i++) {
          final r = await repo.watchMatches().first;
          if (r.isNotEmpty) return r;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return const <MatchRow>[];
      });
      expect(rows, isNotNull);
      expect(rows!, hasLength(1));
      expect(rows.single.mode, 'lan');
      expect(rows.single.matchLength, 5);
      // The host plays White; the peer is remote, not an AI.
      expect(rows.single.whiteType, 'human');
      expect(rows.single.blackType, 'remote');
    });

    testWidgets('stop hosting tears the session down and returns to the form',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.text('4271'));

      final session = transport.hostSession!;
      await t.tap(find.widgetWithText(TextButton, 'Stop hosting'));
      await pumpUntil(t, find.widgetWithText(FilledButton, 'Start hosting'));

      expect(session.stopped, isTrue);
      expect(find.text('4271'), findsNothing);
      expect(find.text('Match length'), findsOneWidget);
    });

    testWidgets('a bind failure is reported in words, not in an exception',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.hostError = const SocketException('address in use');

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.textContaining('port is already in use'));

      expect(find.textContaining('port is already in use'), findsOneWidget);
      // Still on the form, so the user can try again.
      expect(find.widgetWithText(FilledButton, 'Start hosting'), findsOneWidget);
    });
  });

  group('join tab', () {
    testWidgets('a discovered host is listed and leads to the code field',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.hosts = const [
        DiscoveredHost(name: 'Ada', address: '192.168.1.9', port: 47780),
      ];

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);

      expect(transport.discoverCalls, greaterThan(0));
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('192.168.1.9:47780'), findsOneWidget);

      await t.tap(find.text('Ada'));
      await t.pump();
      expect(find.text('Join Ada'), findsOneWidget);
      expect(find.textContaining('4-digit code'), findsWidgets);
    });

    testWidgets('an empty sweep says so and keeps the manual form available',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);

      expect(find.textContaining('No games found yet'), findsOneWidget);
      expect(find.text('Enter address'), findsOneWidget);
    });

    testWidgets('the sweep repeats while the tab is open', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      final first = transport.discoverCalls;

      await t.pump(const Duration(seconds: 3));
      await t.pump();
      expect(transport.discoverCalls, greaterThan(first));
    });

    testWidgets('a code shorter than four digits is refused before connecting',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.hosts = const [
        DiscoveredHost(name: 'Ada', address: '192.168.1.9', port: 47780),
      ];

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.text('Ada'));
      await t.pump();

      await t.enterText(find.byType(TextField), '12');
      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();

      expect(transport.joins, isEmpty);
      // The card's own copy says "shown on the other device"; the error says
      // "from the other device" — match the error specifically.
      expect(find.textContaining('code from the other device'), findsOneWidget);
    });

    testWidgets('a busy room reads as waiting, not as an error', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.hosts = const [
        DiscoveredHost(name: 'Ada', address: '192.168.1.9', port: 47780),
      ];

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.text('Ada'));
      await t.pump();
      await t.enterText(find.byType(TextField), '4271');
      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();

      expect(transport.joins.single.address, '192.168.1.9');
      expect(transport.joins.single.code, '4271');
      expect(find.text('Connecting…'), findsOneWidget);

      transport.guestSession!
          .emit(const GuestConnectionState.busy('the host is already playing'));
      await t.pump();

      expect(find.text('Room in use — waiting…'), findsOneWidget);
      // Not an error: no retry offered, the client is still trying.
      expect(find.widgetWithText(FilledButton, 'Try again'), findsNothing);
    });

    testWidgets('a wrong code is terminal: a readable reason and a retry',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.hosts = const [
        DiscoveredHost(name: 'Ada', address: '192.168.1.9', port: 47780),
      ];

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.text('Ada'));
      await t.pump();
      await t.enterText(find.byType(TextField), '0000');
      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();

      final session = transport.guestSession!;
      session.fail('bad code');
      await pumpUntil(t, find.textContaining('Wrong room code'));

      expect(find.textContaining('Wrong room code'), findsOneWidget);
      expect(session.disposed, isTrue, reason: 'a dead session is released');

      // Retry puts the code field back, ready for another attempt.
      await t.tap(find.widgetWithText(FilledButton, 'Try again'));
      await t.pump();
      expect(find.text('Join Ada'), findsOneWidget);
    });

    testWidgets('a version mismatch is explained rather than quoted', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.hosts = const [
        DiscoveredHost(name: 'Ada', address: '192.168.1.9', port: 47780),
      ];

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.text('Ada'));
      await t.pump();
      await t.enterText(find.byType(TextField), '4271');
      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();

      transport.guestSession!.fail('unsupported version 2');
      await pumpUntil(t, find.textContaining('different version'));
      expect(find.textContaining('different version'), findsOneWidget);
    });

    testWidgets('manual entry submits the typed address, port and code',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);

      // The manual form's three fields, in order: address, port, code.
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10.0.0.4');
      await t.enterText(fields.at(1), '47790');
      await t.enterText(fields.at(2), '1234');
      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();

      expect(transport.joins, hasLength(1));
      expect(transport.joins.single.address, '10.0.0.4');
      expect(transport.joins.single.port, 47790);
      expect(transport.joins.single.code, '1234');
      expect(transport.joins.single.name, 'TestPhone');
      expect(find.text('Joining 10.0.0.4'), findsOneWidget);
    });

    testWidgets('manual entry refuses an empty address', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);

      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();

      expect(transport.joins, isEmpty);
      expect(find.textContaining('Enter the address'), findsOneWidget);
    });

    testWidgets('cancelling a connection releases the session', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);

      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10.0.0.4');
      await t.enterText(fields.at(2), '1234');
      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();

      final session = transport.guestSession!;
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await pumpUntil(t, find.text('Enter address'));

      expect(find.text('Enter address'), findsOneWidget);
      expect(session.disposed, isTrue);
    });
  });
}
