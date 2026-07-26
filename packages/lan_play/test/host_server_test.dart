import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// The standard 6-1 opening play for White: 13/7, 8/7.
final opening61 = Move([const CheckerMove(12, 6), const CheckerMove(7, 6)]);

void main() {
  group('handshake', () {
    test('a hello with the room code is welcomed with the match', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.hello(name: 'Bo');
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      final welcome = guest.lastOf<WelcomeMessage>()!;
      expect(welcome.config, const MatchConfig(length: 3, cubeless: false));
      expect(welcome.side, Player.black, reason: 'the host keeps white');
      expect(welcome.resume, 'TESTTOKEN');
      expect(welcome.log, isEmpty);

      // The opening roll follows as an ordinary event.
      await waitFor(() => guest.of<EventMessage>().isNotEmpty, what: 'events');
      final entry = guest.of<EventMessage>().first.entry;
      expect(entry.seq, 1);
      expect(entry.event, const OpeningRollEvent(whiteDie: 6, blackDie: 1));

      expect(f.authority.started, isTrue);
      expect(f.server.hasGuest, isTrue);
      expect(f.server.guestName, 'Bo');
    });

    test('a wrong code is refused and closed, leaking nothing', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);

      // A real guest first, so there IS a log to leak.
      final first = await RawGuest.connect(f.server);
      first.hello();
      await waitFor(() => first.gotWelcome, what: 'the first welcome');
      f.authority.localSubmit(MoveEvent(Player.white, opening61));
      await waitFor(() => f.authority.lastSeq == 2, what: 'the opening move');
      await first.close();
      await waitFor(() => !f.server.hasGuest, what: 'the slot to free');

      final intruder = await RawGuest.connect(f.server);
      addTearDown(intruder.close);
      intruder.hello(code: '9999');
      await waitFor(() => intruder.closed, what: 'the intruder to be closed');

      expect(intruder.gotWelcome, isFalse);
      expect(intruder.of<EventMessage>(), isEmpty);
      final reject = intruder.lastOf<RejectMessage>()!;
      expect(reject.reason, 'bad code');
      expect(reject.lastSeq, 0,
          reason: 'an unauthenticated peer learns nothing about the match');
      expect(f.authority.lastSeq, 2, reason: 'the match is untouched');
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
      expect(f.authority.started, isFalse);
    });

    test('a first frame that is not a hello is refused', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.send(const RollRequestMessage());
      await waitFor(() => guest.closed, what: 'the connection to close');
      expect(guest.lastOf<RejectMessage>()!.reason, 'handshake required');
      expect(f.authority.started, isFalse);
    });

    test('a garbage first frame is refused without reaching the authority',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);

      guest.sendRaw('}{not json');
      await waitFor(() => guest.closed, what: 'the connection to close');
      expect(guest.gotWelcome, isFalse);
      expect(f.authority.started, isFalse);
    });

    test('a silent connection is dropped and frees the slot', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final idler = await RawGuest.connect(f.server);
      addTearDown(idler.close);

      await waitFor(() => idler.closed, what: 'the handshake timeout');
      expect(f.authority.started, isFalse);

      final real = await RawGuest.connect(f.server);
      addTearDown(real.close);
      real.hello();
      await waitFor(() => real.gotWelcome, what: 'the slot to be reusable');
    });
  });

  group('single-guest policy', () {
    test('a second guest is told busy and closed; the first plays on',
        () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
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
      f.authority.localSubmit(MoveEvent(Player.white, opening61));
      await waitFor(() => first.of<EventMessage>().length > before,
          what: 'the incumbent to keep receiving events');
      expect(f.server.guestName, 'Bo');
    });

    test('a reconnecting guest becomes the active guest and gets the full log',
        () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final first = await RawGuest.connect(f.server);
      first.hello();
      await waitFor(() => first.gotWelcome, what: 'the first welcome');
      f.authority.localSubmit(MoveEvent(Player.white, opening61));
      await waitFor(() => f.authority.lastSeq == 2, what: 'the opening move');

      await first.close();
      await waitFor(() => !f.server.hasGuest, what: 'the slot to free');

      final again = await RawGuest.connect(f.server);
      addTearDown(again.close);
      again.hello(resume: 'TESTTOKEN');
      await waitFor(() => again.gotWelcome, what: 'the resync welcome');

      final welcome = again.lastOf<WelcomeMessage>()!;
      expect(welcome.log.map((e) => e.seq), [1, 2]);
      expect(welcome.log.last.event, MoveEvent(Player.white, opening61));
      expect(f.authority.lastSeq, 2, reason: 'a resync appends nothing');
      expect(f.server.hasGuest, isTrue);
    });

    test('the host can drop the guest without disturbing the match', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      await f.server.disconnectGuest();
      await waitFor(() => guest.closed, what: 'the guest to be dropped');
      expect(f.server.hasGuest, isFalse);
      expect(f.authority.started, isTrue);
      expect(f.authority.lastSeq, 1);
    });
  });

  group('liveness', () {
    test('the host pings, and drops a guest that goes silent', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      await waitFor(() => guest.of<PingMessage>().isNotEmpty,
          what: 'a heartbeat ping');
      await waitFor(() => guest.closed, what: 'the silent guest to be dropped');
      expect(f.server.hasGuest, isFalse);
      expect(f.authority.started, isTrue, reason: 'the match survives');
    });

    test('a guest that answers the pings is kept', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
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
  });

  group('rate limits', () {
    test('rapid hellos do not each replay the log', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
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

    test('a burst of ordinary frames is throttled, not answered', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      // White (the host) is on turn, so every one of these earns a reject —
      // unless the limiter drops it first.
      for (var i = 0; i < 12; i++) {
        guest.send(const RollRequestMessage());
      }
      await settle(80);
      expect(guest.of<RejectMessage>().length, lessThan(4),
          reason: 'the burst is dropped, not answered one for one');
      expect(guest.closed, isFalse);
      expect(f.authority.lastSeq, 1, reason: 'nothing illegitimate applied');
    });
  });

  group('hostile input', () {
    test('a malformed frame is refused and the connection survives', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');

      guest.sendRaw('not json at all');
      await waitFor(() => guest.of<RejectMessage>().isNotEmpty,
          what: 'a bounded reject');
      expect(guest.closed, isFalse);

      // And the link still works.
      await settle(20);
      f.authority.localSubmit(MoveEvent(Player.white, opening61));
      await waitFor(() => f.authority.lastSeq == 2, what: 'the next event');
      await waitFor(() => guest.of<EventMessage>().length == 2,
          what: 'the event to reach the guest');
    });

    test('an over-cap frame is dropped before the parser', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
      final guest = await RawGuest.connect(f.server, autoPong: true);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'a welcome');
      final before = guest.answers;

      guest.sendRaw(jsonEncode({
        'v': protocolVersion,
        'type': 'submit',
        'payload': {'pad': 'x' * (maxMessageLength + 1024)},
      }));
      await settle(80);
      expect(guest.answers, before,
          reason: 'dropped silently — not even a reject to amplify with');
      expect(guest.closed, isFalse);
      expect(f.authority.lastSeq, 1);

      f.authority.localSubmit(MoveEvent(Player.white, opening61));
      await waitFor(() => guest.of<EventMessage>().length == 2,
          what: 'the link to still work');
    });

    test('a binary frame and an unknown type are ignored', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
      addTearDown(f.dispose);
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
      expect(f.authority.lastSeq, 1);
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
      expect(f.authority.started, isFalse);
    });
  });

  group('http surface', () {
    test('only /match upgrades', () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final client = HttpClient();
      addTearDown(client.close);
      final base = 'http://${InternetAddress.loopbackIPv4.address}:${f.port}';

      final wrongPath = await (await client.getUrl(Uri.parse('$base/'))).close();
      expect(wrongPath.statusCode, HttpStatus.notFound);
      await wrongPath.drain<void>();

      final plain =
          await (await client.getUrl(Uri.parse('$base$matchPath'))).close();
      expect(plain.statusCode, HttpStatus.badRequest);
      await plain.drain<void>();
    });

    test('stop closes the guest and the port', () async {
      final f = await ServerFixture.start(dice: [Dice(6, 1)]);
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
      f.authority.close();
    });
  });

  test('generateRoomCode makes four digits', () {
    for (var seed = 0; seed < 50; seed++) {
      final code = HostServer.generateRoomCode(Random(seed));
      expect(code, hasLength(4));
      expect(int.tryParse(code), isNotNull);
    }
  });
}
