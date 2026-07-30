/// The LAN join in the order the SCREEN really performs it.
///
/// [SocketPair] (see `lan_harness.dart`) builds the host controller in the same
/// synchronous stretch as the guest client, so the host's transport is always
/// subscribed before the guest's `hello` can cross a real socket. "Play Nearby"
/// cannot work that way, and the difference is not cosmetic:
///
///  1. the host binds the server and shows a room code — no transport yet;
///  2. the guest connects and its `hello` claims the playing slot;
///  3. only THEN does `guestConnected` fire and `HostSession.controller()` build
///     the transport that answers hellos.
///
/// Between 2 and 3 the join `hello` was published to a broadcast, non-buffering
/// stream with nobody listening, so it was dropped and never answered. The guest
/// hung in `connecting` — with the host's heartbeat refreshing its liveness clock
/// it never even dropped the link to retry — which is the "clicked join, stuck on
/// connecting" report. This test walks those three steps in order.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';

import 'lan_harness.dart';

void main() {
  test('a guest that joins before the host opens its board is welcomed',
      () async {
    // 1. "Start hosting": the port is bound and the room code is on screen. No
    //    transport and no controller exist yet.
    final relay = MatchRelay(
      config: const MatchConfig(length: 1, cubeless: false),
      resumeToken: testResumeToken,
    );
    final server = await HostServer.start(
      port: 0,
      roomCode: testRoomCode,
      timings: lanTestTimings,
      bindAddress: InternetAddress.loopbackIPv4,
      lastSeq: () => relay.lastSeq,
    );

    // 2. "Join": the guest connects and authenticates. Its hello arrives with
    //    nothing subscribed to `guestFrames`.
    final client = GuestClient.connect(
      InternetAddress.loopbackIPv4.address,
      server.port,
      roomCode: testRoomCode,
      name: 'Bo',
      timings: lanTestTimings,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!server.hasGuest) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the guest never authenticated');
      }
      await tick();
    }
    expect(client.lastWelcome, isNull,
        reason: 'nothing can have answered the hello yet');

    // 3. The presence notification opens the board, which is what builds the
    //    host's transport and controller.
    final host = NetMatchController(
      transport: SocketTransport.host(server: server, relay: relay),
      persistence: RecordingPersistence(),
      gateTimeout: lanTestTimings.connectTimeout,
      rng: Random(101),
    );
    unawaited(host.playMatch());

    // The guest's screen is awaiting exactly this future.
    final welcome = await client.welcome.timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          fail('the guest was never welcomed — the join hello was dropped'),
    );
    expect(welcome.side, Player.black);

    final guest = NetMatchController(
      transport: SocketTransport.guest(client: client),
      persistence: RecordingPersistence(),
      gateTimeout: lanTestTimings.connectTimeout,
      rng: Random(202),
    );
    unawaited(guest.playMatch());

    final ready = DateTime.now().add(const Duration(seconds: 20));
    while (!(host.isReady && guest.isReady)) {
      if (DateTime.now().isAfter(ready)) {
        fail('the controllers never folded game 1 '
            '(host ${host.isReady}/${host.error}, '
            'guest ${guest.isReady}/${guest.error})');
      }
      await tick();
    }
    expect(host.localSide, Player.white);
    expect(guest.localSide, Player.black);

    host.disposeController();
    guest.disposeController();
    await client.dispose();
    await server.stop();
    await relay.close();
  });
}
