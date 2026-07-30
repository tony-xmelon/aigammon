import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// The standard 6-1 opening play for White: 13/7, 8/7.
final opening61 = Move([const CheckerMove(12, 6), const CheckerMove(7, 6)]);

/// Append one host-authored event straight into the relay — the in-process half
/// of the link, exactly what `SocketTransport.host` does for its own writes.
void hostAppends(ServerFixture f, GameEvent event, {int gameNo = 1}) =>
    f.relay.appendEvent(
      author: MatchRelay.hostAuthor,
      seq: f.relay.nextSeq,
      gameNo: gameNo,
      event: event,
    );

void main() {
  group('handshake', () {
    test('a hello with the room code is welcomed with the whole relay state',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.hello(name: 'Bo');
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      final welcome = guest.lastOf<WelcomeMessage>()!;
      expect(welcome.config, const MatchConfig(length: 3, cubeless: false));
      expect(welcome.side, Player.black, reason: 'the host keeps white');
      expect(welcome.resume, testToken);
      // Everything the relay holds, in one frame: the log AND the roll document
      // behind it, so the joiner can validate the dice it is being told about.
      expect(welcome.log.map((e) => e.seq), [1]);
      expect(welcome.log.single.author, MatchRelay.hostAuthor);
      expect(welcome.log.single.event,
          const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      expect(welcome.rolls.map((r) => r.n), [1]);
      expect(welcome.rolls.single.isComplete, isTrue);

      expect(f.server.hasGuest, isTrue);
      expect(f.server.guestName, 'Bo');
    });

    test('a later host event is relayed as an ordinary event frame', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      hostAppends(f, MoveEvent(Player.white, opening61));
      await waitFor(() => guest.of<EventMessage>().isNotEmpty,
          what: 'the relayed event');
      final entry = guest.of<EventMessage>().single.entry;
      expect(entry.seq, 2);
      expect(entry.author, MatchRelay.hostAuthor);
      expect(entry.event, MoveEvent(Player.white, opening61));
    });

    test('a wrong code is refused and closed, leaking nothing', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);

      // A real guest first, so there IS a log to leak.
      final first = await RawGuest.connect(f.server);
      first.hello();
      await waitFor(() => first.gotWelcome, what: 'the first welcome');
      hostAppends(f, MoveEvent(Player.white, opening61));
      await waitFor(() => f.relay.lastSeq == 2, what: 'the opening move');
      await first.close();
      await waitFor(() => !f.server.hasGuest, what: 'the slot to free');

      final intruder = await RawGuest.connect(f.server);
      addTearDown(intruder.close);
      intruder.hello(code: '9999');
      await waitFor(() => intruder.closed, what: 'the intruder to be closed');

      expect(intruder.gotWelcome, isFalse);
      expect(intruder.of<EventMessage>(), isEmpty);
      expect(intruder.of<RollMessage>(), isEmpty);
      final reject = intruder.lastOf<RejectMessage>()!;
      expect(reject.reason, 'bad code');
      expect(reject.lastSeq, 0,
          reason: 'an unauthenticated peer learns nothing about the match');
      expect(f.relay.lastSeq, 2, reason: 'the match is untouched');
    });

    test('a hello without a code is refused', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.hello(code: null);
      await waitFor(() => guest.closed, what: 'the connection to close');
      expect(guest.gotWelcome, isFalse);
      expect(guest.lastOf<RejectMessage>()!.reason, 'bad code');
    });

    test('a first frame that is not a hello is refused', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.send(const PingMessage());
      await waitFor(() => guest.closed, what: 'the connection to close');
      expect(guest.lastOf<RejectMessage>()!.reason, 'handshake required');
      expect(f.relay.lastSeq, 0);
    });

    test('a write before the handshake is refused and never reaches the relay',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.writeEvent(const TakeEvent(Player.black), seq: 1);
      await waitFor(() => guest.closed, what: 'the connection to close');
      expect(guest.of<AckMessage>(), isEmpty);
      expect(f.relay.lastSeq, 0, reason: 'nothing unauthenticated may write');
    });

    test('a garbage first frame is refused without reaching the relay',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.sendRaw('}{not json');
      await waitFor(() => guest.closed, what: 'the connection to close');
      expect(guest.gotWelcome, isFalse);
      expect(f.relay.lastSeq, 0);
    });

    test('a silent connection is dropped by the handshake timeout', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final idler = await RawGuest.connect(f.server);
      addTearDown(idler.close);

      await waitFor(() => idler.closed, what: 'the handshake timeout');
      await waitFor(() => f.server.pendingConnections == 0,
          what: 'the pending slot to be released');

      final real = await RawGuest.connect(f.server);
      addTearDown(real.close);
      real.hello();
      await waitFor(() => real.gotWelcome, what: 'a later guest to be welcomed');
    });

    test('an unauthenticated socket does NOT hold the playing slot', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);

      // Someone who does not know the code just holds a socket open.
      final squatter = await RawGuest.connect(f.server);
      addTearDown(squatter.close);
      await waitFor(() => f.server.pendingConnections == 1,
          what: 'the squatter to be pending');
      expect(f.server.hasGuest, isFalse);

      // The real guest walks straight in — no waiting for the squatter's
      // handshake timeout.
      final real = await RawGuest.connect(f.server);
      addTearDown(real.close);
      real.hello();
      await waitFor(() => real.gotWelcome, what: 'the real guest');
      expect(f.server.hasGuest, isTrue);
      expect(squatter.gotWelcome, isFalse);
      expect(squatter.of<EventMessage>(), isEmpty);
    });

    test('concurrent unauthenticated sockets are capped', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);

      final held = <RawGuest>[];
      for (var i = 0; i < LanTimings.test.maxPendingConnections; i++) {
        held.add(await RawGuest.connect(f.server));
      }
      addTearDown(() async {
        for (final g in held) {
          await g.close();
        }
      });
      expect(f.server.pendingConnections, LanTimings.test.maxPendingConnections);

      await expectLater(
          RawGuest.connect(f.server), throwsA(isA<WebSocketException>()));

      // Freeing one lets the next in.
      await held.first.close();
      await waitFor(
          () =>
              f.server.pendingConnections <
              LanTimings.test.maxPendingConnections,
          what: 'the freed pending slot');
      final admitted = await RawGuest.connect(f.server);
      addTearDown(admitted.close);
      admitted.hello();
      await waitFor(() => admitted.gotWelcome, what: 'the admitted guest');
    });
  });

  group('single-guest policy', () {
    test('a second guest is told busy and closed; the first plays on',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final first = await RawGuest.connect(f.server);
      addTearDown(first.close);
      first.hello(name: 'Bo');
      await waitFor(() => first.gotWelcome, what: 'the first welcome');

      final second = await RawGuest.connect(f.server);
      addTearDown(second.close);
      second.hello(name: 'Cy');
      await waitFor(() => second.closed, what: 'the second to be closed');
      expect(second.of<BusyMessage>(), hasLength(1));
      expect(second.gotWelcome, isFalse);

      // The incumbent is undisturbed.
      final before = first.of<EventMessage>().length;
      hostAppends(f, MoveEvent(Player.white, opening61));
      await waitFor(() => first.of<EventMessage>().length > before,
          what: 'the incumbent to keep receiving events');
      expect(f.server.guestName, 'Bo');
    });

    test('a reconnecting guest becomes the active guest and gets the full log',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final first = await RawGuest.connect(f.server);
      first.hello();
      await waitFor(() => first.gotWelcome, what: 'the first welcome');
      hostAppends(f, MoveEvent(Player.white, opening61));
      await waitFor(() => f.relay.lastSeq == 2, what: 'the opening move');

      await first.close();
      await waitFor(() => !f.server.hasGuest, what: 'the slot to free');

      final again = await RawGuest.connect(f.server);
      addTearDown(again.close);
      again.hello(resume: testToken);
      await waitFor(() => again.gotWelcome, what: 'the resync welcome');

      final welcome = again.lastOf<WelcomeMessage>()!;
      expect(welcome.log.map((e) => e.seq), [1, 2]);
      expect(welcome.log.last.event, MoveEvent(Player.white, opening61));
      expect(welcome.rolls, hasLength(1));
      expect(f.relay.lastSeq, 2, reason: 'a resync appends nothing');
      expect(f.server.hasGuest, isTrue);
    });

    test('two valid hellos racing: one wins the slot, the other is busy',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final a = await RawGuest.connect(f.server);
      final b = await RawGuest.connect(f.server);
      addTearDown(a.close);
      addTearDown(b.close);
      await waitFor(() => f.server.pendingConnections == 2,
          what: 'both to be pending');

      // Both claim in the same turn of the event loop.
      a.hello(name: 'Ana');
      b.hello(name: 'Bo');
      await waitFor(() => a.gotWelcome || b.gotWelcome, what: 'a winner');
      await waitFor(
          () =>
              a.of<BusyMessage>().isNotEmpty || b.of<BusyMessage>().isNotEmpty,
          what: 'a loser');

      final welcomes =
          a.of<WelcomeMessage>().length + b.of<WelcomeMessage>().length;
      final busies =
          a.of<BusyMessage>().length + b.of<BusyMessage>().length;
      expect(welcomes, 1, reason: 'exactly one guest is admitted');
      expect(busies, 1, reason: 'and the other is told so');
      expect(f.server.hasGuest, isTrue);
      expect(f.relay.lastSeq, 1, reason: 'a hello never appends');
    });

    test('the host can drop the guest without disturbing the match', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      await f.server.disconnectGuest();
      await waitFor(() => guest.closed, what: 'the guest to be dropped');
      expect(f.server.hasGuest, isFalse);
      expect(f.relay.lastSeq, 1, reason: 'the log survives');
      expect(f.relay.rollFrames, hasLength(1));
    });
  });

  group('liveness', () {
    test('the host pings, and drops a guest that goes silent', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      await waitFor(() => guest.of<PingMessage>().isNotEmpty,
          what: 'a heartbeat ping');
      await waitFor(() => guest.closed, what: 'the silent guest to be dropped');
      expect(f.server.hasGuest, isFalse);
      expect(f.relay.lastSeq, 1, reason: 'the match survives');
    });

    test('a guest that answers the pings is kept', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server, autoPong: true);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      // Three whole silence windows.
      await settle(LanTimings.test.silenceTimeout.inMilliseconds * 3);
      expect(guest.closed, isFalse);
      expect(f.server.hasGuest, isTrue);
      expect(guest.of<PingMessage>().length, greaterThan(2));
    });

    test('a guest ping is answered with a pong', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      await settle(20);
      guest.send(const PingMessage());
      await waitFor(() => guest.of<PongMessage>().isNotEmpty, what: 'a pong');
    });
  });

  group('rate limits', () {
    test('rapid hellos do not each replay the log', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server, autoPong: true);
      addTearDown(guest.close);

      for (var i = 0; i < 8; i++) {
        guest.hello();
      }
      await settle(LanTimings.test.helloMinInterval.inMilliseconds ~/ 2);
      expect(guest.of<WelcomeMessage>(), hasLength(1),
          reason: 'only the handshake hello is answered inside the window');
      expect(guest.closed, isFalse);

      // Past the window, a genuine resync is answered again.
      await settle(LanTimings.test.helloMinInterval.inMilliseconds + 40);
      guest.hello();
      await waitFor(() => guest.of<WelcomeMessage>().length == 2,
          what: 'the spaced resync welcome');
    });

    test('a long burst of ordinary frames is throttled, not answered',
        () async {
      // A coarse refill so the bucket's two halves are separable: capacity is
      // what a legitimate burst spends, the refill is what a spammer is held to.
      final f = await ServerFixture.start(
          timings: LanTimings.test
              .copyWith(frameMinInterval: const Duration(milliseconds: 200)));
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      // Seq 1 is taken, so every one of these earns a `contested` ack — unless
      // the limiter drops it first.
      for (var i = 0; i < 40; i++) {
        guest.writeEvent(const TakeEvent(Player.black), seq: 1);
      }
      await settle(80);
      expect(guest.of<AckMessage>().length,
          lessThanOrEqualTo(LanTimings.test.frameBurst),
          reason: 'the bucket answers its capacity and drops the rest — never '
              'one for one');
      expect(guest.closed, isFalse);
      expect(f.relay.lastSeq, 1, reason: 'nothing illegitimate applied');
    });

    test('the three frames of a guest-owned roll are never dropped', () async {
      // THE REGRESSION. A guest-owned roll is the one burst the protocol itself
      // produces: `createRoll`, then `reveal`, then the `RollEvent`. Under a hard
      // minimum-spacing limiter, two arriving inside the window — which ordinary
      // WiFi jitter causes, however carefully the client paced them — were
      // dropped silently, and the guest sat out a whole `writeTimeout` per drop.
      //
      // Policed here at 200ms while the frames arrive in the same instant: a
      // spacing rule could not pass this, and the protocol's own client cannot
      // guarantee spacing it does not control the arrival of.
      final f = await ServerFixture.start(
          timings: LanTimings.test
              .copyWith(frameMinInterval: const Duration(milliseconds: 200)));
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      final ids = [
        guest.nextId(),
        guest.nextId(),
        guest.nextId(),
      ];
      guest.send(WriteRollMessage(id: ids[0], n: 2, commit: 'a' * 64));
      guest.send(WriteEntropyMessage(id: ids[1], n: 2, entropy: 'b' * 64));
      guest.send(WriteRevealMessage(id: ids[2], n: 2, reveal: 'c' * 64));

      await waitFor(() => guest.of<AckMessage>().length == 3,
          what: 'all three frames of the burst to be answered');
      expect(guest.of<AckMessage>().map((a) => a.id), ids,
          reason: 'in order, none dropped');
    });
  });

  group('hostile input', () {
    test('a malformed frame is refused and the connection survives', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      guest.sendRaw('not json at all');
      await waitFor(() => guest.of<RejectMessage>().isNotEmpty,
          what: 'a bounded reject');
      // The refusal quotes OUR seq, so a guest that has drifted can tell the
      // difference between "you are behind" and "that frame was nonsense".
      expect(guest.lastOf<RejectMessage>()!.lastSeq, 1);
      expect(guest.closed, isFalse);

      // And the link still works.
      await settle(20);
      hostAppends(f, MoveEvent(Player.white, opening61));
      await waitFor(() => f.relay.lastSeq == 2, what: 'the next event');
      await waitFor(() => guest.of<EventMessage>().length == 1,
          what: 'the event to reach the guest');
    });

    test('an over-cap frame is dropped before the parser', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server, autoPong: true);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');
      final before = guest.answers;

      guest.sendRaw(jsonEncode({
        'v': protocolVersion,
        'type': 'w_event',
        'payload': {'pad': 'x' * (maxMessageLength + 1024)},
      }));
      await settle(80);
      expect(guest.answers, before,
          reason: 'dropped silently — not even a reject to amplify with');
      expect(guest.closed, isFalse);
      expect(f.relay.lastSeq, 1);

      hostAppends(f, MoveEvent(Player.white, opening61));
      await waitFor(() => guest.of<EventMessage>().length == 1,
          what: 'the link to still work');
    });

    test('a binary frame and an unknown type are ignored', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server, autoPong: true);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');
      final before = guest.answers;

      guest.socket.add([1, 2, 3, 4]);
      await settle(20);
      guest.sendRaw(jsonEncode(
          {'v': protocolVersion, 'type': 'from_the_future', 'payload': {}}));
      await settle(60);

      expect(guest.answers, before, reason: 'no answer to either');
      expect(guest.closed, isFalse);
      expect(f.relay.lastSeq, 1);
    });

    test('a relay-authored frame FROM a guest is refused, never applied',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      seedOpening(f.relay, whiteDie: 6, blackDie: 1);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      // A guest that tries to author a LOG ENTRY directly — the one shape that
      // would let it claim to be the host — is refused outright, so the relay's
      // authorship stamping cannot be bypassed.
      guest.send(EventMessage(const EventFrame(
        seq: 2,
        gameNo: 1,
        author: MatchRelay.hostAuthor,
        event: RollEvent(Player.white, 3, 1),
      )));
      await waitFor(() => guest.of<RejectMessage>().isNotEmpty,
          what: 'the refusal');
      expect(guest.lastOf<RejectMessage>()!.reason, contains('relay-only'));
      expect(f.relay.lastSeq, 1, reason: 'the log did not move');
      expect(guest.closed, isFalse);
    });

    test('a repeated wrong code locks the address out before the upgrade',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);

      for (var i = 0; i < LanTimings.test.maxAuthFailuresPerWindow; i++) {
        final probe = await RawGuest.connect(f.server);
        probe.hello(code: '0000');
        await waitFor(() => probe.closed, what: 'attempt $i to be refused');
      }

      // The quota is spent: the next attempt never reaches the WebSocket.
      await expectLater(
        RawGuest.connect(f.server),
        throwsA(isA<WebSocketException>()),
      );
      expect(f.relay.lastSeq, 0);
    });
  });

  group('http surface', () {
    test('only /match upgrades', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final client = HttpClient();
      addTearDown(client.close);
      final base = 'http://${InternetAddress.loopbackIPv4.address}:${f.port}';

      final wrongPath =
          await (await client.getUrl(Uri.parse('$base/'))).close();
      expect(wrongPath.statusCode, HttpStatus.notFound);
      await wrongPath.drain<void>();

      final plain =
          await (await client.getUrl(Uri.parse('$base$matchPath'))).close();
      expect(plain.statusCode, HttpStatus.badRequest);
      await plain.drain<void>();
    });

    test('stop closes the guest and the port', () async {
      final f = await ServerFixture.start();
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');
      final port = f.port;

      await f.server.stop();
      await f.server.stop(); // idempotent
      await waitFor(() => guest.closed, what: 'the guest to be closed');

      await expectLater(
        WebSocket.connect(
            'ws://${InternetAddress.loopbackIPv4.address}:$port$matchPath'),
        throwsA(isA<SocketException>()),
      );
      await f.dispose();
    });
  });

  group('room code', () {
    test('generateRoomCode makes four digits', () {
      for (var seed = 0; seed < 50; seed++) {
        final code = HostServer.generateRoomCode(Random(seed));
        expect(code, hasLength(4));
        expect(int.tryParse(code), isNotNull);
      }
    });

    test('an unusable room code is refused at start, not at the handshake',
        () async {
      await expectLater(
        HostServer.start(
            roomCode: '', bindAddress: InternetAddress.loopbackIPv4),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        HostServer.start(
            roomCode: 'x' * (maxCodeLength + 1),
            bindAddress: InternetAddress.loopbackIPv4),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('the throttle forgets addresses once their window passes', () async {
    final f = await ServerFixture.start(
      timings: LanTimings.test
          .copyWith(throttleWindow: const Duration(milliseconds: 50)),
    );
    addTearDown(f.dispose);

    final first = await RawGuest.connect(f.server);
    await first.close();
    expect(f.server.throttledAddresses, 1);

    await settle(80); // the window passes
    final second = await RawGuest.connect(f.server);
    addTearDown(second.close);
    expect(f.server.throttledAddresses, 1,
        reason: 'the expired entry was swept, not accumulated');
  });
}
