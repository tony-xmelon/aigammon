import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// Build a guest wired to [f] and collecting everything it receives.
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

void main() {
  group('handshake', () {
    test('connect, welcome, and a live event stream', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);

      final welcome = await g.client.welcome;
      expect(welcome.side, Player.black);
      expect(welcome.config, const MatchConfig(length: 3, cubeless: false));
      expect(welcome.log, isEmpty);
      expect(g.client.side, Player.black);
      expect(g.client.isConnected, isTrue);
      expect(g.states.map((s) => s.status),
          contains(GuestConnectionStatus.connected));

      // The opening roll arrives on the inbound stream, welcome included.
      await waitFor(() => g.inbound.whereType<EventMessage>().isNotEmpty,
          what: 'the opening roll');
      expect(g.inbound.first, isA<WelcomeMessage>());
      expect(g.inbound.whereType<EventMessage>().first.entry.event,
          const OpeningRollEvent(whiteDie: 6, blackDie: 1));
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
      expect(f.authority.started, isFalse);
    });

    test('a busy host is waited out, not failed', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
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
      final f = ServerFixture.serve(stalled, dice: [Dice(6, 1)]);
      addTearDown(f.dispose);

      final welcome = await client.welcome.timeout(const Duration(seconds: 5));
      expect(welcome.side, Player.black);
      expect(f.server.hasGuest, isTrue);
      expect(states.map((s) => s.status), isNot(contains(GuestConnectionStatus.busy)),
          reason: 'the orphan must never have held the slot');
      expect(states.map((s) => s.status),
          isNot(contains(GuestConnectionStatus.failed)));
      await waitFor(() => f.server.pendingConnections == 0,
          what: 'the orphan to be closed');
    });
  });

  group('reconnection', () {
    test('a dropped guest reconnects, resyncs, and plays on', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      // A couple of turns before the drop.
      await advance(f, guest: g.client); // white moves
      await advance(f, guest: g.client); // black rolls
      final seqBeforeDrop = f.authority.lastSeq;
      expect(seqBeforeDrop, greaterThanOrEqualTo(3));

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
      expect(f.authority.lastSeq, seqBeforeDrop,
          reason: 'a resync appends nothing');
      expect(f.server.hasGuest, isTrue);

      // And the match continues over the NEW socket.
      final eventsBefore = g.inbound.whereType<EventMessage>().length;
      await advance(f, guest: g.client);
      await advance(f, guest: g.client);
      expect(f.authority.lastSeq, greaterThan(seqBeforeDrop));
      await waitFor(
          () => g.inbound.whereType<EventMessage>().length > eventsBefore,
          what: 'events over the new socket');
      // The status story IN ORDER, but not necessarily contiguous: reconnecting
      // is a backoff retry loop, so a run that needs two attempts legitimately
      // emits an extra reconnecting/connecting pair in the middle. Asserting the
      // exact list pins the test to "the first retry always succeeds", which is
      // a property of the host machine's timing rather than of the client.
      // containsAllInOrder keeps the part that is the contract: it connected,
      // noticed the drop, and came back.
      expect(g.states.map((s) => s.status).toList(), containsAllInOrder([
        GuestConnectionStatus.connecting,
        GuestConnectionStatus.connected,
        GuestConnectionStatus.reconnecting,
        GuestConnectionStatus.connected,
      ]));
    });

    test('a host that stops is retried until it comes back', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
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
      f.authority.close();
    });

    test('snapshot stays current while lastWelcome goes stale', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);

      // The welcome is answered BEFORE the host opens game 1, so the frame
      // itself carries an empty log — the stale-by-one-tick case a late folder
      // would otherwise adopt.
      final welcome = await g.client.welcome;
      expect(welcome.log, isEmpty);
      await waitFor(() => (g.client.snapshot?.log.length ?? 0) == 1,
          what: 'the opening roll to reach the snapshot');
      expect(g.client.lastWelcome!.log, isEmpty, reason: 'the FRAME is stale');
      expect(g.client.snapshot!.side, welcome.side);
      expect(g.client.snapshot!.config, welcome.config);
      expect(g.client.snapshot!.resume, welcome.resume);

      await advance(f, guest: g.client);
      await advance(f, guest: g.client);
      await waitFor(
          () => g.client.snapshot!.log.length == f.authority.lastSeq,
          what: 'the snapshot to track the log');
      expect(g.client.snapshot!.log.map((e) => e.seq),
          [for (var i = 1; i <= f.authority.lastSeq; i++) i]);

      // A resync welcome REPLACES it rather than appending to it.
      await settle(250);
      g.client.resync();
      await waitFor(() => g.inbound.whereType<WelcomeMessage>().length == 2,
          what: 'the resync welcome');
      expect(g.client.snapshot!.log.length, f.authority.lastSeq);
    });

    test('resync asks for the whole log again without touching the match',
        () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      await advance(f, guest: g.client); // white moves
      await advance(f, guest: g.client); // black rolls
      final seqBefore = f.authority.lastSeq;

      // The controller-facing recovery lever: one hello, one full log back.
      // Spaced past the host's helloMinInterval — inside it, the hello is
      // DROPPED (the amplification limit), which is why a folding controller
      // must re-request on the next gap rather than assume one resync lands.
      await settle(250);
      expect(g.client.resync(), isTrue);
      await waitFor(() => g.inbound.whereType<WelcomeMessage>().length == 2,
          what: 'the resync welcome');

      final resync = g.inbound.whereType<WelcomeMessage>().last;
      expect(resync.log.map((e) => e.seq), [
        for (var i = 1; i <= seqBefore; i++) i,
      ]);
      expect(f.authority.lastSeq, seqBefore, reason: 'a resync appends nothing');
      expect(g.client.isConnected, isTrue, reason: 'the link is untouched');

      // A resync on a DOWN link is refused rather than queued — the reconnect
      // resyncs anyway, so there is nothing to hold on to.
      await g.client.dispose();
      expect(g.client.resync(), isFalse);
    });

    test('dispose stops the retry loop', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      await g.client.welcome;

      await g.client.dispose();
      await waitFor(() => !f.server.hasGuest, what: 'the slot to free');
      await settle(200);
      expect(f.server.hasGuest, isFalse, reason: 'no reconnect after dispose');
      expect(g.client.send(const RollRequestMessage()), isFalse);
      await g.client.dispose(); // idempotent
    });
  });

  group('gameplay over real sockets', () {
    test('host and guest play a dozen turns; the guest sees every event',
        () async {
      final f = await ServerFixture.start(length: 5, dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      for (var i = 0; i < 12; i++) {
        await advance(f, guest: g.client);
      }

      final seq = f.authority.lastSeq;
      expect(seq, 13, reason: 'the opening roll plus twelve actions');
      await waitFor(
          () => g.inbound.whereType<EventMessage>().length == seq,
          what: 'every event to reach the guest');
      expect(
        g.inbound.whereType<EventMessage>().map((e) => e.entry.seq),
        [for (var i = 1; i <= seq; i++) i],
        reason: 'contiguous and in order',
      );
      expect(g.inbound.whereType<RejectMessage>(), isEmpty);
    });

    test('an illegal guest submission is rejected without moving the match',
        () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;
      await waitFor(() => f.authority.lastSeq == 1, what: 'the opening roll');

      // Black submits while White is on turn.
      g.client.submit(MoveEvent(Player.black, Move([const CheckerMove(0, 5)])));
      await waitFor(() => g.inbound.whereType<RejectMessage>().isNotEmpty,
          what: 'a reject');
      final reject = g.inbound.whereType<RejectMessage>().single;
      expect(reject.reason, contains('not your turn'));
      expect(reject.lastSeq, 1);
      expect(f.authority.lastSeq, 1);
      expect(g.client.isConnected, isTrue,
          reason: 'a refusal is not a disconnection');
    });

    test('back-to-back submissions are paced past the host rate limit',
        () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1), Dice(3, 1)]);
      addTearDown(f.dispose);
      final g = connectGuest(f);
      addTearDown(g.client.dispose);
      await g.client.welcome;

      // White plays; then black fires roll_request twice in the same instant.
      await advance(f); // white's opening move
      await waitFor(() => f.authority.state!.turn == Player.black,
          what: "black's turn");
      g.client.requestRoll();
      g.client.requestRoll(); // will be rejected (already rolled), not dropped

      await waitFor(() => f.authority.lastSeq == 3, what: "black's roll");
      await waitFor(() => g.inbound.whereType<RejectMessage>().isNotEmpty,
          what: 'the second request to be ANSWERED, not silently dropped');
      expect(g.inbound.whereType<RejectMessage>().single.reason,
          contains('not awaiting a roll'));
    });
  });
}
