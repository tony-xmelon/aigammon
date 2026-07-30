import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// The link itself: connect, welcome, reconnect, pace, give up only when giving
/// up is right. Deliberately game-blind — what the frames MEAN is
/// `socket_transport_test.dart`'s subject.
({GuestClient client, List<Envelope> inbound, List<GuestConnectionState> states})
    connectGuest(ServerFixture f, {String code = testCode, String name = 'Bo'}) {
  final client = GuestClient.connect(
    '127.0.0.1',
    f.port,
    roomCode: code,
    name: name,
    timings: LanTimings.test,
  );
  final inbound = <Envelope>[];
  final states = <GuestConnectionState>[];
  client.inbound.listen(inbound.add);
  client.states.listen(states.add);
  return (client: client, inbound: inbound, states: states);
}

/// Append one host-authored event straight into the relay.
void hostAppends(ServerFixture f, GameEvent event, {int gameNo = 1}) =>
    f.relay.appendEvent(
      author: MatchRelay.hostAuthor,
      seq: f.relay.nextSeq,
      gameNo: gameNo,
      event: event,
    );

void main() {
  group('handshake', () {
    test('connect, welcome, and a live frame stream', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);

      final welcome = await g.client.welcome;
      expect(welcome.side, Player.black);
      expect(welcome.config, const MatchConfig(length: 3, cubeless: false));
      expect(welcome.log.map((e) => e.seq), [1]);
      expect(welcome.rolls, hasLength(1));
      expect(g.client.isConnected, isTrue);
      expect(g.client.lastWelcome, same(welcome));
      expect(g.states.map((s) => s.status),
          contains(GuestConnectionStatus.connected));

      // A later event arrives on the inbound stream, welcome included.
      hostAppends(f, const RollEvent(Player.white, 3, 1));
      await waitFor(() => g.inbound.whereType<EventMessage>().isNotEmpty,
          what: 'the relayed event');
      expect(g.inbound.first, isA<WelcomeMessage>());
      expect(g.inbound.whereType<EventMessage>().single.entry.seq, 2);
      expect(f.server.guestName, 'Bo');
    });

    test('a wrong room code fails terminally and stops retrying', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final g = connectGuest(f, code: '0000');
      addTearDown(g.client.dispose);

      await expectLater(
          g.client.welcome, throwsA(isA<GuestHandshakeException>()));
      expect(g.client.state.status, GuestConnectionStatus.failed);
      expect(g.client.state.reason, 'bad code');

      // No retry storm: the room stays free and the state does not move on.
      await settle(200);
      expect(f.server.hasGuest, isFalse);
      expect(g.client.state.status, GuestConnectionStatus.failed);
      expect(f.relay.lastSeq, 0);
    });

    test('a busy host is waited out, not failed', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final first = connectGuest(f, name: 'Bo');
      await first.client.welcome;

      final second = connectGuest(f, name: 'Cy');
      addTearDown(second.client.dispose);
      await waitFor(() => second.client.state.isBusy, what: 'the busy state');
      expect(second.client.state.reason, contains('already playing'));
      expect(first.client.isConnected, isTrue);

      // The room frees up — and the waiting guest walks in without any help.
      await first.client.dispose();
      final welcome =
          await second.client.welcome.timeout(const Duration(seconds: 5));
      expect(welcome.side, Player.black);
      expect(f.server.guestName, 'Cy');
      expect(second.states.map((s) => s.status),
          isNot(contains(GuestConnectionStatus.failed)));
    });

    test('a host that is not there is retried indefinitely', () async {
      final dead = await ServerFixture.start();
      final port = dead.port;
      await dead.dispose();

      final client = GuestClient.connect('127.0.0.1', port,
          roomCode: testCode, name: 'Bo', timings: LanTimings.test);
      addTearDown(client.dispose);
      await waitFor(
          () => client.state.status == GuestConnectionStatus.reconnecting,
          what: 'the first failure');
      await settle(200);
      expect(client.state.status, GuestConnectionStatus.reconnecting,
          reason: 'a refused connection is never terminal');
    });

    test('a stalled connect is abandoned and cannot squat the host slot',
        () async {
      // Bound but never listened: the OS completes the TCP handshake into the
      // backlog and nothing answers the upgrade. That is the manual-IP /
      // host-still-booting case — and the one `Future.timeout` cannot cancel,
      // so the abandoned attempt is still on its way to the host when the
      // retry starts.
      final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = GuestClient.connect('127.0.0.1', stalled.port,
          roomCode: testCode, name: 'Bo', timings: LanTimings.test);
      final states = <GuestConnectionState>[];
      client.states.listen(states.add);
      addTearDown(client.dispose);

      await waitFor(
          () => client.state.status == GuestConnectionStatus.reconnecting,
          what: 'the connect deadline');

      // Start hosting on that very socket, with the orphan still queued on it.
      final f = ServerFixture.serve(stalled);
      addTearDown(f.dispose);

      final welcome = await client.welcome.timeout(const Duration(seconds: 5));
      expect(welcome.side, Player.black);
      expect(f.server.hasGuest, isTrue);
      expect(states.map((s) => s.status),
          isNot(contains(GuestConnectionStatus.busy)),
          reason: 'the orphan must never have held the slot');
      expect(states.map((s) => s.status),
          isNot(contains(GuestConnectionStatus.failed)));
      await waitFor(() => f.server.pendingConnections == 0,
          what: 'the orphan to be closed');
    });
  });

  group('reconnection', () {
    test('a dropped guest reconnects, resyncs, and plays on', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      hostAppends(f, const RollEvent(Player.white, 3, 1));
      hostAppends(f, const RollEvent(Player.black, 2, 1));
      final seqBeforeDrop = f.relay.lastSeq;
      expect(seqBeforeDrop, 3);

      await f.server.disconnectGuest();
      await waitFor(
          () => g.client.state.status == GuestConnectionStatus.reconnecting,
          what: 'the reconnecting state');

      await waitFor(() => g.client.isConnected, what: 'the reconnect');
      await waitFor(() => g.inbound.whereType<WelcomeMessage>().length == 2,
          what: 'the resync welcome');

      final resync = g.inbound.whereType<WelcomeMessage>().last;
      expect(resync.log.map((e) => e.seq), [
        for (var i = 1; i <= seqBeforeDrop; i++) i,
      ]);
      expect(f.relay.lastSeq, seqBeforeDrop,
          reason: 'a resync appends nothing');
      expect(f.server.hasGuest, isTrue);

      // And the match continues over the NEW socket.
      final eventsBefore = g.inbound.whereType<EventMessage>().length;
      hostAppends(f, const RollEvent(Player.white, 5, 4));
      await waitFor(
          () => g.inbound.whereType<EventMessage>().length > eventsBefore,
          what: 'events over the new socket');
      expect(f.relay.lastSeq, greaterThan(seqBeforeDrop));
      // The status story IN ORDER, but not necessarily contiguous: reconnecting
      // is a backoff retry loop, so a run that needs two attempts legitimately
      // emits an extra reconnecting/connecting pair in the middle. Asserting the
      // exact list pins the test to "the first retry always succeeds", which is
      // a property of the host machine's timing rather than of the client.
      expect(g.states.map((s) => s.status).toList(),
          containsAllInOrder([
            GuestConnectionStatus.connecting,
            GuestConnectionStatus.connected,
            GuestConnectionStatus.reconnecting,
            GuestConnectionStatus.connected,
          ]));
    });

    test('a host that stops is retried until it comes back', () async {
      final f = await ServerFixture.start();
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      await f.server.stop();
      await waitFor(
          () => g.client.state.status == GuestConnectionStatus.reconnecting,
          what: 'the reconnecting state');
      await settle(200);
      expect(g.client.state.status, GuestConnectionStatus.reconnecting,
          reason: 'it keeps trying rather than giving up');
      await f.dispose();
    });

    test('resync asks for the whole log again without touching the match',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      hostAppends(f, const RollEvent(Player.white, 3, 1));
      hostAppends(f, const RollEvent(Player.black, 2, 1));
      final seqBefore = f.relay.lastSeq;

      // The transport-facing recovery lever: one hello, one full log back.
      // Spaced past the relay's helloMinInterval — inside it, the hello is
      // DROPPED (the amplification limit), which is why the transport re-requests
      // on a timer rather than assuming one resync lands.
      await settle(250);
      expect(g.client.resync(), isTrue);
      await waitFor(() => g.inbound.whereType<WelcomeMessage>().length == 2,
          what: 'the resync welcome');

      final resync = g.inbound.whereType<WelcomeMessage>().last;
      expect(resync.log.map((e) => e.seq), [
        for (var i = 1; i <= seqBefore; i++) i,
      ]);
      expect(resync.rolls, hasLength(1));
      expect(f.relay.lastSeq, seqBefore, reason: 'a resync appends nothing');
      expect(g.client.isConnected, isTrue, reason: 'the link is untouched');

      // A resync on a DOWN link is refused rather than queued — the reconnect
      // resyncs anyway, so there is nothing to hold on to.
      await g.client.dispose();
      expect(g.client.resync(), isFalse);
    });

    test('dispose stops the retry loop', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final g = connectGuest(f);
      await g.client.welcome;

      await g.client.dispose();
      await waitFor(() => !f.server.hasGuest, what: 'the slot to free');
      await settle(200);
      expect(f.server.hasGuest, isFalse, reason: 'no reconnect after dispose');
      expect(g.client.send(const PingMessage()), isFalse);
      await g.client.dispose(); // idempotent
    });
  });

  group('sending over real sockets', () {
    test('every relayed event reaches the guest, contiguous and in order',
        () async {
      final f = await ServerFixture.start(length: 5);
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      for (var i = 0; i < 12; i++) {
        hostAppends(f, RollEvent(i.isEven ? Player.white : Player.black, 3, 1));
      }

      final seq = f.relay.lastSeq;
      expect(seq, 13, reason: 'the opening roll plus twelve events');
      await waitFor(
          () => g.inbound.whereType<EventMessage>().length == seq - 1,
          what: 'every later event to reach the guest');
      expect(
        g.inbound.whereType<EventMessage>().map((e) => e.entry.seq),
        [for (var i = 2; i <= seq; i++) i],
        reason: 'contiguous and in order',
      );
      expect(g.inbound.whereType<RejectMessage>(), isEmpty);
    });

    test('back-to-back writes are paced past the relay rate limit', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      // Two writes in the same instant. The relay DROPS anything inside its
      // frameMinInterval, so without the client's own pacing the second would
      // simply vanish; with it, both are answered.
      g.client.send(WriteEventMessage(
          id: 1, seq: 2, gameNo: 1, event: const DoubleEvent(Player.black)));
      g.client.send(WriteEventMessage(
          id: 2, seq: 3, gameNo: 1, event: const TakeEvent(Player.white)));

      await waitFor(() => g.inbound.whereType<AckMessage>().length == 2,
          what: 'both writes to be acknowledged');
      expect(
          g.inbound.whereType<AckMessage>().map((a) => (a.id, a.status)),
          [(1, AckStatus.ok), (2, AckStatus.ok)]);
      expect(f.relay.lastSeq, 3);
    });
  });
}
