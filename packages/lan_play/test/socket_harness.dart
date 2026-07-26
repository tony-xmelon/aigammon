import 'dart:async';
import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';

/// The room code every socket test uses unless it is testing the code itself.
const String testCode = '4271';

/// Poll until [condition] holds, or fail loudly. Sockets and timers make the
/// exact instant unpredictable, so every socket assertion goes through here
/// rather than through a fixed sleep.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
}

/// Let pending timers and socket events run for [ms] milliseconds.
Future<void> settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// A [HostAuthority] + [HostServer] pair bound to loopback on an OS-chosen
/// port. Loopback deliberately, not `anyIPv4`: a test run must never raise a
/// firewall prompt.
class ServerFixture {
  ServerFixture(this.authority, this.server);

  static Future<ServerFixture> start({
    int port = 0,
    int length = 3,
    bool cubeless = false,
    Player hostSide = Player.white,
    List<Dice> dice = const [],
    String roomCode = testCode,
    LanTimings timings = LanTimings.test,
  }) async {
    final authority = HostAuthority(
      config: MatchConfig(length: length, cubeless: cubeless),
      hostSide: hostSide,
      dice: ScriptedDiceRoller(dice),
      resumeToken: 'TESTTOKEN',
    );
    final server = await HostServer.start(
      port: port,
      authority: authority,
      roomCode: roomCode,
      timings: timings,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    return ServerFixture(authority, server);
  }

  final HostAuthority authority;
  final HostServer server;

  int get port => server.port;

  Future<void> dispose() async {
    await server.stop();
    authority.close();
  }
}

/// A hand-driven guest: a bare WebSocket that records what the host sends and
/// sends exactly what a test tells it to — including frames no real client
/// would ever produce.
class RawGuest {
  RawGuest._(this.socket, {required bool autoPong}) : _autoPong = autoPong {
    socket.listen(
      (Object? data) {
        if (data is String) {
          raw.add(data);
          final result = Envelope.decode(data);
          if (result is DecodeOk) {
            received.add(result.envelope);
            if (_autoPong && result.envelope is PingMessage) {
              send(const PongMessage());
            }
          }
        } else {
          binary.add(data);
        }
      },
      onDone: () => closed = true,
      onError: (Object _) => closed = true,
      cancelOnError: true,
    );
  }

  static Future<RawGuest> connect(HostServer server,
      {bool autoPong = false}) async {
    final socket = await WebSocket.connect(
        'ws://${InternetAddress.loopbackIPv4.address}:${server.port}$matchPath');
    return RawGuest._(socket, autoPong: autoPong);
  }

  final WebSocket socket;
  final bool _autoPong;

  /// Every decodable frame the host sent, oldest first.
  final List<Envelope> received = [];

  /// Every text frame verbatim.
  final List<String> raw = [];

  /// Anything non-text the host sent (nothing, in a correct implementation).
  final List<Object?> binary = [];

  bool closed = false;

  void send(Envelope message) => sendRaw(message.encode());

  void sendRaw(String frame) {
    try {
      socket.add(frame);
    } catch (_) {
      // The host may have closed already; tests assert on `closed`.
    }
  }

  void hello({String name = 'Bo', String? code = testCode, String? resume}) =>
      send(HelloMessage(name: name, code: code, resume: resume));

  List<T> of<T extends Envelope>() => received.whereType<T>().toList();

  T? lastOf<T extends Envelope>() {
    final all = of<T>();
    return all.isEmpty ? null : all.last;
  }

  bool get gotWelcome => of<WelcomeMessage>().isNotEmpty;

  /// Everything the host sent that is not a heartbeat — i.e. everything the
  /// host said IN ANSWER to something.
  int get answers => received.where((m) => m is! PingMessage).length;

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {
      // already gone
    }
  }
}

/// Drive whichever side is on turn through ONE authoritative event, waiting for
/// it to land in the log. [guest] is null when the host plays both roles.
///
/// Move choice reads the authority's own state (this is a transport test, not a
/// controller test — the guest-side fold arrives in Task 3), but every guest
/// action still travels over the real socket.
Future<void> advance(ServerFixture fixture, {GuestClient? guest}) async {
  final authority = fixture.authority;
  final state = authority.state!;
  final before = authority.lastSeq;
  final side = state.turn;
  final isHost = side == authority.hostSide;

  if (state.phase == GamePhase.awaitingRoll) {
    if (isHost) {
      authority.localRoll();
    } else {
      guest!.requestRoll();
    }
  } else {
    final legal = state.legalMoves;
    final move = legal.isEmpty ? Move.none : legal.first;
    final event = MoveEvent(side, move);
    if (isHost) {
      authority.localSubmit(event);
    } else {
      guest!.submit(event);
    }
  }
  await waitFor(() => authority.lastSeq > before,
      what: 'seq to advance past $before (${side.name}, ${state.phase.name})');
}
