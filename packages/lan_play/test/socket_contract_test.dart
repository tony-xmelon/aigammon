import 'dart:io';

import 'package:lan_play/lan_play.dart';
import 'package:match_transport/transport_contract.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// The SHARED `MatchTransport` contract, run against [SocketTransport] over a
/// REAL loopback WebSocket.
///
/// `packages/match_transport/lib/transport_contract.dart` holds the assertions;
/// this file only builds the pair. That is the point: the socket implementation
/// is held to the same expectations as the in-memory reference and as Firestore,
/// from one source, so a clause that drifts on one backend fails visibly rather
/// than being quietly re-interpreted in a bespoke suite.
///
/// `socket_transport_test.dart` keeps everything this cannot cover — the wire
/// protocol, the reconnect/reset semantics that are specific to a relay, presence
/// and the ping/pong liveness machinery.
void main() {
  runTransportContract(
    name: 'SocketTransport (loopback)',
    // A bound host whose guest never arrives: connected as a transport, but the
    // relay has no session, which is exactly the pre-connect state the clause is
    // about.
    newUnconnected: () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      return f.transport;
    },
    newPair: (config) async {
      final f = await ServerFixture.start(
        length: config.length,
        cubeless: config.cubeless,
      );
      final host = f.transport;
      final hostSession = await host.connect();

      final client = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        f.port,
        roomCode: testCode,
        name: 'Contract',
        timings: LanTimings.test,
      );
      final guest = SocketTransport.guest(client: client);
      final guestSession = await guest.connect();

      return TransportPair(
        host: host,
        guest: guest,
        hostSession: hostSession,
        guestSession: guestSession,
        // Innermost first: the guest transport, then its socket, then the
        // server + relay the fixture owns.
        dispose: () async {
          await guest.dispose();
          await client.dispose();
          await f.dispose();
        },
      );
    },
    // Loopback: milliseconds, but a real event loop and a real handshake.
    timeout: const Duration(seconds: 10),
  );
}
