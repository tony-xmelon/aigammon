import 'dart:async';
import 'dart:io' show SocketException;

import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/lan/join_qr_code.dart';
import 'package:aigammon_app/lan/lan_transport.dart';
import 'package:aigammon_app/lan/qr_payload.dart';
import 'package:aigammon_app/lan/qr_scanner.dart';
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
import 'package:match_transport/testing.dart';

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

  /// What the NEXT session hosts as — so a test can restart hosting on a
  /// different port or code and check the screen followed it.
  String nextRoomCode = '4271';
  int nextPort = 47780;

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
    return hostSession = FakeHostSession(
      config,
      roomCode: nextRoomCode,
      port: nextPort,
    );
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
  FakeHostSession(this.config, {this.roomCode = '4271', this.port = 47780})
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
  String roomCode;

  @override
  int port;

  @override
  Player get localSide => TransportSession.hostSide;

  @override
  final ValueNotifier<bool> guestConnected = ValueNotifier<bool>(false);

  @override
  String? guestName;

  bool stopped = false;

  /// A failure the next controller's `connect()` throws — the link dying inside
  /// the handshake, which leaves [NetMatchController.isReady] false with
  /// [NetMatchController.error] set. The screen's bail path.
  Object? connectError;

  InMemoryTransport? _peer;

  @override
  NetMatchController controller({
    MatchPersistence persistence = const NoopPersistence(),
  }) =>
      NetMatchController(
        transport: _RefusingConnect(
            InMemoryTransport.host(backend), () => connectError),
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

/// An [InMemoryTransport] whose `connect()` throws whatever [failure] answers
/// at the moment it is called. Everything else is the real thing, so a
/// controller built on it behaves normally once the fault is cleared.
class _RefusingConnect implements MatchTransport {
  _RefusingConnect(this.inner, this.failure);

  final InMemoryTransport inner;
  final Object? Function() failure;

  @override
  Future<TransportSession> connect() async {
    final f = failure();
    if (f != null) throw f;
    return inner.connect();
  }

  @override
  Stream<InboundFrame> get inbound => inner.inbound;

  @override
  Future<void> sendEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) =>
      inner.sendEvent(seq: seq, gameNo: gameNo, event: event);

  @override
  Future<void> createRoll(int n, String commit) => inner.createRoll(n, commit);

  @override
  Future<void> sendEntropy(int n, String entropy) =>
      inner.sendEntropy(n, entropy);

  @override
  Future<void> sendReveal(int n, String reveal) => inner.sendReveal(n, reveal);

  @override
  Future<List<EventFrame>> eventsSince(int afterSeq) =>
      inner.eventsSince(afterSeq);

  @override
  Future<RollFrame?> fetchRoll(int n) => inner.fetchRoll(n);

  @override
  Future<List<RollFrame>> rollsSince(int from) => inner.rollsSince(from);

  @override
  Future<void> complete() => inner.complete();

  @override
  Stream<TransportStatusEvent> get statusStream => inner.statusStream;

  @override
  TransportStatus get status => inner.status;

  @override
  String? get statusReason => inner.statusReason;

  @override
  bool get opponentPresent => inner.opponentPresent;

  @override
  Stream<bool> get opponentPresence => inner.opponentPresence;

  @override
  Capabilities get capabilities => inner.capabilities;

  @override
  Duration get inboundCadence => inner.inboundCadence;

  @override
  void setPaceHint({required bool fast}) => inner.setPaceHint(fast: fast);

  @override
  Future<void> dispose() => inner.dispose();
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

/// The camera, scripted.
///
/// There is no camera on a test machine and no way to point one at anything, so
/// [QrScanner] is the seam the whole scan-to-join path is driven through: the
/// test says what the scanner "saw" and the screen does the rest.
class FakeScanner implements QrScanner {
  /// What the next scan comes back with.
  QrScanOutcome outcome = const QrScanCancelled();

  /// How many times a scanner was opened — the debounce assertion.
  int calls = 0;

  /// Held to keep a scan "open", so a second tap lands while the first route
  /// is still up.
  Completer<void>? gate;

  @override
  Future<QrScanOutcome> scan(BuildContext context) async {
    calls++;
    final open = gate;
    if (open != null) await open.future;
    return outcome;
  }
}

void main() {
  const surface = Size(900, 1400);

  late AppDatabase db;
  late FakeTransport transport;
  late FakeScanner scanner;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = newTestDatabase();
    transport = FakeTransport();
    scanner = FakeScanner();
  });
  tearDown(() => db.close());

  Widget app() => ProviderScope(
        overrides: [
          nearbyTransportProvider.overrideWithValue(transport),
          qrScannerProvider.overrideWithValue(scanner),
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

    testWidgets(
        'a launch that never connects says so, and does not jam the launcher',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.text('4271'));

      final session = transport.hostSession!;
      session.connectError =
          const TransportUnavailable('link-lost', 'the guest went away');
      session.guestArrives();
      await pumpUntil(t, find.textContaining('could not be started'));

      // (1) The failure reaches the user. Before, the spinner simply stopped
      //     and the host was left looking at a room code that would never open
      //     a board, with nothing said about why.
      expect(find.textContaining('the guest went away'), findsOneWidget);
      expect(find.byType(GameScreen), findsNothing);

      // (2) …and the launch guard is CLEAR, so the next presence flap launches.
      //     It used to be left latched on this exact path, which made the
      //     failure permanent for as long as the screen stayed open.
      session.connectError = null;
      session.guestConnected.value = false;
      await t.pump();
      session.guestConnected.value = true;
      await pumpUntil(t, find.byType(GameScreen));
      expect(find.byType(GameScreen), findsOneWidget);
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

  group('qr join', () {
    /// The one QR symbol on screen, and what it encodes.
    String shownQr(WidgetTester t) =>
        encodeQrJoin(t.widget<JoinQrCode>(find.byType(JoinQrCode)).payload);

    testWidgets('the host shows a QR code carrying its address, port and code',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.byType(JoinQrCode));

      expect(
        shownQr(t),
        encodeQrJoin(const QrJoinPayload(
            address: '192.168.1.5', port: 47780, code: '4271')),
      );
      // An addition, not a replacement: the spoken code is still there.
      expect(find.text('4271'), findsOneWidget);
      expect(find.text('192.168.1.5:47780'), findsOneWidget);
    });

    testWidgets('the QR follows the CURRENT session, not the first one',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.byType(JoinQrCode));
      final first = shownQr(t);

      await t.tap(find.widgetWithText(TextButton, 'Stop hosting'));
      await pumpUntil(t, find.widgetWithText(FilledButton, 'Start hosting'));

      // A second session on a different port, with a different code, on a
      // device that moved to another subnet.
      transport
        ..address = '10.0.0.9'
        ..nextPort = 47790
        ..nextRoomCode = '1357';
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.byType(JoinQrCode));

      expect(shownQr(t), isNot(first));
      expect(
        shownQr(t),
        encodeQrJoin(const QrJoinPayload(
            address: '10.0.0.9', port: 47790, code: '1357')),
      );
      // And it round-trips: what the guest's camera reads is what it dials.
      final decoded = tryDecodeQrJoin(shownQr(t))!;
      expect(decoded.address, '10.0.0.9');
      expect(decoded.port, 47790);
      expect(decoded.code, '1357');
    });

    testWidgets('with no local address there is no QR, but the code remains',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      transport.address = null;

      await t.pumpWidget(app());
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Start hosting'));
      await pumpUntil(t, find.text('4271'));

      // Nothing to encode — a QR pointing at no address would be worse than
      // none — but the join is still reachable by discovery and by typing.
      expect(find.byType(JoinQrCode), findsNothing);
      expect(find.text('4271'), findsOneWidget);
    });

    testWidgets('the join tab offers a scan entry point', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);

      expect(find.widgetWithText(FilledButton, 'Scan QR code'), findsOneWidget);
    });

    testWidgets('a scanned code fills the form and joins', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      scanner.outcome = QrScanCode(encodeQrJoin(const QrJoinPayload(
          address: '10.0.0.4', port: 47790, code: '1234')));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await pumpUntil(t, find.text('Joining 10.0.0.4'));

      expect(transport.joins, hasLength(1));
      expect(transport.joins.single.address, '10.0.0.4');
      expect(transport.joins.single.port, 47790);
      expect(transport.joins.single.code, '1234');
      expect(transport.joins.single.name, 'TestPhone');
      expect(find.text('Joining 10.0.0.4'), findsOneWidget);
    });

    testWidgets('the scanned target is left in the manual fields to correct',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      scanner.outcome = QrScanCode(encodeQrJoin(const QrJoinPayload(
          address: '10.0.0.4', port: 47790, code: '1234')));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await pumpUntil(t, find.text('Joining 10.0.0.4'));

      // Cancel back to the form: the scan is still visible, and editable.
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await pumpUntil(t, find.text('Enter address'));

      final fields = find.byType(TextField);
      expect(t.widget<TextField>(fields.at(0)).controller!.text, '10.0.0.4');
      expect(t.widget<TextField>(fields.at(1)).controller!.text, '47790');
      expect(t.widget<TextField>(fields.at(2)).controller!.text, '1234');
    });

    testWidgets('a foreign QR code is refused and nothing is dialled',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      scanner.outcome = const QrScanCode('WIFI:S:CafeWifi;T:WPA;P:hunter2;;');

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await pumpUntil(t, find.textContaining('not an AIGammon game'));

      expect(transport.joins, isEmpty);
      expect(find.textContaining('not an AIGammon game'), findsOneWidget);
      // Still on the browsing form, with every other way in intact.
      expect(find.text('Enter address'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Scan QR code'), findsOneWidget);
    });

    testWidgets('a refused camera explains itself and leaves manual entry '
        'working', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      scanner.outcome = const QrScanUnavailable(
          'AIGammon does not have permission to use the camera. Enter the '
          'address by hand.');

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await pumpUntil(t, find.textContaining('permission to use the camera'));

      expect(find.textContaining('permission to use the camera'),
          findsOneWidget);
      expect(transport.joins, isEmpty);

      // Not a dead end: the typed path still gets this device into a game.
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10.0.0.4');
      await t.enterText(fields.at(2), '1234');
      await t.tap(find.widgetWithText(FilledButton, 'Connect'));
      await t.pump();
      expect(transport.joins, hasLength(1));
      expect(transport.joins.single.address, '10.0.0.4');
    });

    testWidgets('cancelling the scanner changes nothing', (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      scanner.outcome = const QrScanCancelled();

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await t.pump();
      await t.pump();

      expect(transport.joins, isEmpty);
      expect(find.byIcon(Icons.error_outline), findsNothing,
          reason: 'backing out of a scan is not a failure');
      expect(find.text('Enter address'), findsOneWidget);
    });

    testWidgets('cancelling a later scan clears the earlier scan\'s error',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      scanner.outcome = const QrScanCode('WIFI:S:CafeWifi;T:WPA;P:hunter2;;');

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await pumpUntil(t, find.textContaining('not an AIGammon game'));
      expect(find.textContaining('not an AIGammon game'), findsOneWidget);

      // Second attempt, backed out of. The complaint about the FIRST scan is
      // about a scan that is over, and must not sit under the button.
      scanner.outcome = const QrScanCancelled();
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await t.pump();
      await t.pump();

      expect(find.textContaining('not an AIGammon game'), findsNothing);
      expect(transport.joins, isEmpty);
    });

    testWidgets('a second tap while the scanner is open opens nothing new',
        (t) async {
      await t.binding.setSurfaceSize(surface);
      addTearDown(() => t.binding.setSurfaceSize(null));
      scanner
        ..gate = Completer<void>()
        ..outcome = QrScanCode(encodeQrJoin(const QrJoinPayload(
            address: '10.0.0.4', port: 47790, code: '1234')));

      await t.pumpWidget(app());
      await t.pump();
      await openJoinTab(t);

      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Scan QR code'));
      await t.pump();
      expect(scanner.calls, 1, reason: 'one camera at a time');

      // One scan comes back; one join goes out.
      scanner.gate!.complete();
      await pumpUntil(t, find.text('Joining 10.0.0.4'));
      expect(transport.joins, hasLength(1));
    });
  });
}
