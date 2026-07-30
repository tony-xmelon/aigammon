import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// The join order the APP actually uses, which no other socket test exercises.
///
/// Every fixture in `socket_harness.dart` builds the host-side transport BEFORE a
/// guest connects. The "Play Nearby" screen cannot: it binds the server and shows
/// a room code first, and only builds the transport (inside
/// `HostSession.controller()`) once a guest has authenticated — which is strictly
/// AFTER the guest's `hello` has already been published to
/// [HostServer.guestFrames].
///
/// That stream is broadcast and non-buffering, so with no subscriber yet the join
/// `hello` was dropped on the floor and nothing ever answered it. The guest then
/// waited for a welcome forever — kept alive, and so kept silent, by the host's
/// own heartbeat — which is the "stuck on connecting" report these tests pin down.
/// A well-formed commitment for roll [n] — the protocol requires exactly 64
/// lowercase hex characters, and a frame that carries anything else is refused at
/// the decoder rather than reaching the mirror.
String _commit(int n) => n.toRadixString(16).padLeft(64, '0');

void main() {
  group('a guest that authenticates before the host transport exists', () {
    late MatchRelay relay;
    late HostServer server;
    SocketTransport? transport;
    GuestClient? guest;

    setUp(() async {
      relay = MatchRelay(
        config: const MatchConfig(length: 3, cubeless: false),
        resumeToken: testToken,
      );
      server = await HostServer.start(
        roomCode: testCode,
        timings: LanTimings.test,
        bindAddress: InternetAddress.loopbackIPv4,
        lastSeq: () => relay.lastSeq,
      );
    });

    tearDown(() async {
      await guest?.dispose();
      await transport?.dispose();
      await server.stop();
      await relay.close();
    });

    test('is welcomed once the host builds its transport (the app join order)',
        () async {
      guest = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        server.port,
        roomCode: testCode,
        name: 'Bo',
        timings: LanTimings.test,
      );
      // The guest has claimed the playing slot: its hello reached the server and
      // was published to a stream with no subscriber.
      final seen = <GuestConnectionStatus>[];
      guest!.states.listen((s) => seen.add(s.status));
      await waitFor(() => server.hasGuest, what: 'the guest to authenticate');
      expect(guest!.state.status, GuestConnectionStatus.connecting);

      // NOW the screen opens the board and builds the transport, exactly as
      // `HostSession.controller()` does on a `guestConnected` notification.
      transport = SocketTransport.host(server: server, relay: relay);
      await transport!.connect();

      final welcome = await guest!.welcome.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
            'the guest was never welcomed: the join hello was dropped'),
      );
      expect(welcome.side, Player.black);
      expect(welcome.config.length, 3);
      expect(guest!.state.status, GuestConnectionStatus.connected);
      // On the FIRST connection, with no drop in between. The guest's handshake
      // deadline would eventually cure this too — the reconnect's `hello` finds a
      // subscriber — but only after a visible stall and a "lost the connection"
      // flash for something that never connected. The host answering the hello it
      // missed is what makes the join immediate.
      expect(seen, isNot(contains(GuestConnectionStatus.reconnecting)),
          reason: 'the guest should not have had to drop the link and retry');
    });

    test('does not lose the frames pushed before its own transport exists',
        () async {
      // THE SECOND HALF OF THE SAME BUG, on the other end of the link.
      //
      // Retaining the `hello` gets the guest welcomed. But the welcome is not the
      // last thing the host sends before the joining screen has built anything to
      // receive it: the host starts the OPENING ROLL the instant its transport
      // connects (it needs nothing from the guest to do that) and pushes the roll
      // frame straight after the welcome, routinely inside the same TCP segment.
      //
      // `GuestClient.inbound` is broadcast and non-buffering, so that frame was
      // dropped, and a dropped roll frame is gone for good — nothing replays it.
      // The guest then never contributes entropy for roll 1, and the host waits
      // for that entropy with no retry that could ever produce it. Neither peer
      // ever folds game 1, neither reports an error, and the board simply never
      // opens. Same symptom as the dropped `hello`, different cause.
      guest = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        server.port,
        roomCode: testCode,
        name: 'Bo',
        timings: LanTimings.test,
      );
      await waitFor(() => server.hasGuest, what: 'the guest to authenticate');

      transport = SocketTransport.host(server: server, relay: relay);
      await transport!.connect();
      await guest!.welcome.timeout(const Duration(seconds: 5));

      // The host's opening roll, pushed while the joining screen is still a
      // screen transition away from building its transport.
      await transport!.createRoll(1, _commit(1));
      // One beat, which is all it takes: the frame crosses the socket and is
      // published to a stream nobody is attached to yet.
      await settle(30);

      final view = SocketTransport.guest(client: guest!);
      addTearDown(view.dispose);
      await view.connect();

      final roll = await view.fetchRoll(1);
      expect(roll, isNotNull,
          reason: 'the roll frame pushed before this view existed was dropped, '
              'so this guest can never contribute entropy for it');
      expect(roll!.commit, _commit(1));
      expect(await view.rollsSince(1), hasLength(1));
    });

    test('resyncs when more was pushed than it could retain', () async {
      guest = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        server.port,
        roomCode: testCode,
        name: 'Bo',
        timings: LanTimings.test,
      );
      await waitFor(() => server.hasGuest, what: 'the guest to authenticate');
      transport = SocketTransport.host(server: server, relay: relay);
      await transport!.connect();
      await guest!.welcome.timeout(const Duration(seconds: 5));

      // Past the cap the retention holds only a PREFIX, so the mirror may have a
      // hole the retained frames themselves cannot reveal. The view must not
      // quietly trust it: it asks for the whole log instead.
      for (var n = 1; n <= maxRetainedFrames + 10; n++) {
        relay.createRoll(
            author: MatchRelay.hostAuthor, n: n, commit: _commit(n));
      }
      await waitFor(() => guest!.retainedFramesLost,
          timeout: const Duration(seconds: 10),
          what: 'the retention to overflow');

      final view = SocketTransport.guest(client: guest!);
      addTearDown(view.dispose);
      await view.connect();
      // The resync is a fresh `hello`, and the welcome answering it carries every
      // roll — so the hole heals rather than persisting.
      final want = maxRetainedFrames + 10;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var have = 0;
      while (have < want) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the overflowed mirror never healed: $have of $want rolls');
        }
        await settle(10);
        have = (await view.rollsSince(1)).length;
      }
    });

    test('never welcomed at all, it stops waiting instead of hanging forever',
        () async {
      // No host transport is EVER built, so nothing answers the hello. The guest
      // must not sit in `connecting` indefinitely: without a handshake deadline
      // the host's pings refresh its liveness clock forever and the UI spins with
      // nothing behind it.
      guest = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        server.port,
        roomCode: testCode,
        name: 'Bo',
        timings: LanTimings.test,
      );
      final seen = <GuestConnectionStatus>[];
      guest!.states.listen((s) => seen.add(s.status));

      await waitFor(
        () => seen.contains(GuestConnectionStatus.reconnecting),
        timeout: const Duration(seconds: 5),
        what: 'the guest to give up on an unanswered handshake',
      );
      expect(guest!.state.status, isNot(GuestConnectionStatus.connected));
    });
  });
}
