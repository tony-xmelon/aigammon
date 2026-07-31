import 'dart:async';
import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:match_transport/testing.dart';

/// The room code every socket test uses unless it is testing the code itself.
const String testCode = '4271';

/// The resume token the fixtures mint, so a test can assert on it.
const String testToken = 'TESTTOKEN';

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

/// A [MatchRelay] + [HostServer] + host-side [SocketTransport], bound to loopback
/// on an OS-chosen port.
///
/// Loopback deliberately, not `anyIPv4`: a test run must never raise a firewall
/// prompt.
class ServerFixture {
  ServerFixture(this.relay, this.server, this.transport);

  static Future<ServerFixture> start({
    int port = 0,
    int length = 3,
    bool cubeless = false,
    String roomCode = testCode,
    LanTimings timings = LanTimings.test,
  }) async {
    final relay = MatchRelay(
      config: MatchConfig(length: length, cubeless: cubeless),
      resumeToken: testToken,
    );
    final server = await HostServer.start(
      port: port,
      roomCode: roomCode,
      timings: timings,
      bindAddress: InternetAddress.loopbackIPv4,
      lastSeq: () => relay.lastSeq,
    );
    return ServerFixture(
        relay, server, SocketTransport.host(server: server, relay: relay));
  }

  /// Serve on an already-bound [http] server — the deterministic way to make a
  /// port go from "connects but never answers" to "hosting a match" without a
  /// close/rebind race.
  static ServerFixture serve(
    HttpServer http, {
    int length = 3,
    bool cubeless = false,
    String roomCode = testCode,
    LanTimings timings = LanTimings.test,
  }) {
    final relay = MatchRelay(
      config: MatchConfig(length: length, cubeless: cubeless),
      resumeToken: testToken,
    );
    final server = HostServer.attach(http,
        roomCode: roomCode, timings: timings, lastSeq: () => relay.lastSeq);
    return ServerFixture(
        relay, server, SocketTransport.host(server: server, relay: relay));
  }

  final MatchRelay relay;
  final HostServer server;

  /// The bound peer's transport. Already wired to [relay] and [server]; call
  /// [connect] to open it.
  final SocketTransport transport;

  int get port => server.port;

  Future<TransportSession> connect() => transport.connect();

  /// Innermost first: the transport owns nothing, so it goes first, then the
  /// socket, then the log.
  Future<void> dispose() async {
    await transport.dispose();
    await server.stop();
    await relay.close();
  }
}

/// Seed a SOUND opening roll straight into [relay]: a complete `rolls/{n}` plus
/// the [OpeningRollEvent] it derives, authored by the host. Everything a
/// controller would validate holds.
void seedOpening(MatchRelay relay,
    {required int whiteDie, required int blackDie, int gameNo = 1}) {
  final n = _rollCount(relay) + 1;
  final s = openingSecretsFor(whiteDie, blackDie);
  relay.createRoll(author: MatchRelay.hostAuthor, n: n, commit: s.commit);
  relay.addEntropy(
      author: MatchRelay.guestAuthor, n: n, entropy: s.entropy);
  relay.addReveal(author: MatchRelay.hostAuthor, n: n, reveal: s.secret);
  relay.appendEvent(
    author: MatchRelay.hostAuthor,
    seq: relay.nextSeq,
    gameNo: gameNo,
    event: OpeningRollEvent(whiteDie: whiteDie, blackDie: blackDie),
  );
}

/// Seed a SOUND ordinary roll for [author] (playing [player]) plus its
/// [RollEvent], aiming exactly [die1]/[die2].
void seedRoll(
  MatchRelay relay, {
  required String author,
  required Player player,
  required int die1,
  required int die2,
  int gameNo = 1,
}) {
  final n = _rollCount(relay) + 1;
  final witness = author == MatchRelay.hostAuthor
      ? MatchRelay.guestAuthor
      : MatchRelay.hostAuthor;
  final s = turnSecretsFor(die1, die2);
  relay.createRoll(author: author, n: n, commit: s.commit);
  relay.addEntropy(author: witness, n: n, entropy: s.entropy);
  relay.addReveal(author: author, n: n, reveal: s.secret);
  relay.appendEvent(
    author: author,
    seq: relay.nextSeq,
    gameNo: gameNo,
    event: RollEvent(player, die1, die2),
  );
}

int _rollCount(MatchRelay relay) => relay.events
    .where((e) => e.event is OpeningRollEvent || e.event is RollEvent)
    .length;

/// A hand-driven guest: a bare WebSocket that records what the relay sends and
/// sends exactly what a test tells it to — including frames no real client would
/// ever produce.
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

  /// Every decodable frame the relay sent, oldest first.
  final List<Envelope> received = [];

  /// Every text frame verbatim.
  final List<String> raw = [];

  /// Anything non-text the relay sent (nothing, in a correct implementation).
  final List<Object?> binary = [];

  bool closed = false;
  int _writeId = 0;

  void send(Envelope message) => sendRaw(message.encode());

  void sendRaw(String frame) {
    try {
      socket.add(frame);
    } catch (_) {
      // The relay may have closed already; tests assert on `closed`.
    }
  }

  void hello({String name = 'Bo', String? code = testCode, String? resume}) =>
      send(HelloMessage(name: name, code: code, resume: resume));

  /// The next write id, so a test can correlate its own acks.
  int nextId() => ++_writeId;

  int writeEvent(GameEvent event, {required int seq, int gameNo = 1}) {
    final id = nextId();
    send(WriteEventMessage(id: id, seq: seq, gameNo: gameNo, event: event));
    return id;
  }

  List<T> of<T extends Envelope>() => received.whereType<T>().toList();

  T? lastOf<T extends Envelope>() {
    final all = of<T>();
    return all.isEmpty ? null : all.last;
  }

  AckMessage? ack(int id) =>
      of<AckMessage>().where((a) => a.id == id).firstOrNull;

  bool get gotWelcome => of<WelcomeMessage>().isNotEmpty;

  /// Everything the relay sent that is not a heartbeat — i.e. everything it said
  /// IN ANSWER to something.
  int get answers => received.where((m) => m is! PingMessage).length;

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {
      // already gone
    }
  }
}
