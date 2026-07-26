import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lan_play/lan_play.dart';
import 'package:test/test.dart';

/// Discovery over LOOPBACK, deliberately: a test run must never send a real
/// broadcast (that raises a firewall prompt on Windows and leaks probes onto
/// whatever network the machine happens to be on). The broadcast path itself is
/// exercised through [broadcastTargets], which is pure address arithmetic.
void main() {
  /// A datagram socket that answers nothing — a stand-in for a hostile or
  /// broken peer that a test can make say whatever it likes.
  Future<RawDatagramSocket> rogue() =>
      RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

  group('HostBeacon + discoverHosts', () {
    test('a probe reaches the beacon and its answer becomes a host', () async {
      final beacon = await HostBeacon.start(
        name: 'Ada',
        matchPort: 47780,
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(beacon.stop);

      final found = await discoverHosts(
        port: beacon.port,
        targets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(seconds: 2),
      );

      expect(found, hasLength(1));
      expect(found.single.name, 'Ada');
      expect(found.single.port, 47780);
      expect(found.single.address, InternetAddress.loopbackIPv4.address);
    });

    test('the beacon never advertises the room code', () async {
      final beacon = await HostBeacon.start(
        name: 'Ada',
        matchPort: 47780,
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(beacon.stop);

      final probe = await rogue();
      addTearDown(probe.close);
      final answer = Completer<String>();
      probe.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = probe.receive();
        if (dg != null && !answer.isCompleted) {
          answer.complete(utf8.decode(dg.data));
        }
      });
      probe.send(utf8.encode(discoveryProbe), InternetAddress.loopbackIPv4,
          beacon.port);

      final text = await answer.future.timeout(const Duration(seconds: 2));
      final json = jsonDecode(text) as Map<String, dynamic>;
      // Presence only: a name and where to knock. `code` is the literal false —
      // the room code is the auth secret and never leaves the host's screen.
      expect(json['name'], 'Ada');
      expect(json['port'], 47780);
      expect(json['code'], isFalse);
      expect(text, isNot(contains('4271')));
    });

    test('two beacons are both discovered', () async {
      // One shared discovery port is impossible on loopback without SO_REUSEPORT
      // semantics, so the second beacon stands in as a rogue answering by hand —
      // what matters is that the prober collects MORE THAN ONE reply.
      final beacon = await HostBeacon.start(
        name: 'Ada',
        matchPort: 47780,
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(beacon.stop);
      final other = await HostBeacon.start(
        name: 'Bo',
        matchPort: 47781,
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(other.stop);

      final found = await Future.wait([
        discoverHosts(
          port: beacon.port,
          targets: [InternetAddress.loopbackIPv4],
          timeout: const Duration(seconds: 2),
        ),
        discoverHosts(
          port: other.port,
          targets: [InternetAddress.loopbackIPv4],
          timeout: const Duration(seconds: 2),
        ),
      ]);

      expect(found[0].single.name, 'Ada');
      expect(found[1].single.name, 'Bo');
    });

    test('no beacon → an empty result after the timeout', () async {
      // Nothing is listening on this port; the probe simply goes unanswered.
      final idle = await rogue();
      final port = idle.port;
      idle.close();

      final started = DateTime.now();
      final found = await discoverHosts(
        port: port,
        targets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 300),
      );

      expect(found, isEmpty);
      // It really waited rather than returning instantly.
      expect(DateTime.now().difference(started).inMilliseconds,
          greaterThanOrEqualTo(250));
    });
  });

  group('hostile input', () {
    test('the beacon ignores garbage and keeps answering probes', () async {
      final beacon = await HostBeacon.start(
        name: 'Ada',
        matchPort: 47780,
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(beacon.stop);

      final noise = await rogue();
      addTearDown(noise.close);
      // Empty, wrong-version, near-miss, oversized, and non-UTF8 datagrams.
      final junk = <List<int>>[
        <int>[],
        utf8.encode('AIGAMMON?v2'),
        utf8.encode('aigammon?v1'),
        utf8.encode('AIGAMMON?v1 '),
        utf8.encode('X' * (maxDatagramLength + 500)),
        <int>[0xC3, 0x28, 0xA0, 0xA1],
      ];
      for (final bytes in junk) {
        noise.send(bytes, InternetAddress.loopbackIPv4, beacon.port);
      }
      // Anything the beacon wrongly answered would land here.
      var replies = 0;
      noise.listen((event) {
        if (event == RawSocketEvent.read && noise.receive() != null) replies++;
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(replies, 0, reason: 'garbage must not be answered');

      // Still alive and still correct.
      final found = await discoverHosts(
        port: beacon.port,
        targets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(seconds: 2),
      );
      expect(found.single.name, 'Ada');
    });

    test('the prober ignores malformed answers', () async {
      final liar = await rogue();
      addTearDown(liar.close);
      liar.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = liar.receive();
        if (dg == null) return;
        for (final bad in <List<int>>[
          utf8.encode('not json at all'),
          utf8.encode('[1,2,3]'), // JSON, but not an object
          utf8.encode('{"name":"A"}'), // no port
          utf8.encode('{"name":"A","port":"47780"}'), // port not an int
          utf8.encode('{"name":"A","port":0}'), // out of range
          utf8.encode('{"name":"A","port":70000}'), // out of range
          utf8.encode('{"name":42,"port":47780}'), // name not a string
          utf8.encode(jsonEncode({'name': 'X' * 5000, 'port': 47780})),
        ]) {
          liar.send(bad, dg.address, dg.port);
        }
      });

      final found = await discoverHosts(
        port: liar.port,
        targets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 400),
      );
      expect(found, isEmpty);
    });

    test('a repeated answer yields one host, and a blank name gets a fallback',
        () async {
      final liar = await rogue();
      addTearDown(liar.close);
      liar.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = liar.receive();
        if (dg == null) return;
        final answer = utf8.encode(jsonEncode({'name': '  ', 'port': 47780}));
        liar.send(answer, dg.address, dg.port);
        liar.send(answer, dg.address, dg.port);
        liar.send(answer, dg.address, dg.port);
      });

      final found = await discoverHosts(
        port: liar.port,
        targets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 400),
      );
      expect(found, hasLength(1));
      expect(found.single.name, isNotEmpty);
    });
  });

  group('broadcastTargets', () {
    test('always includes the all-networks broadcast address', () async {
      final targets = await broadcastTargets();
      expect(
        targets.map((a) => a.address),
        contains('255.255.255.255'),
      );
    });

    test('derives a per-interface broadcast address for an IPv4 address', () {
      final targets = broadcastTargetsFor([
        InternetAddress('192.168.1.42'),
        InternetAddress('10.0.0.7'),
        InternetAddress.loopbackIPv4,
        InternetAddress('::1'),
      ]);
      final addresses = targets.map((a) => a.address).toList();
      expect(addresses, contains('255.255.255.255'));
      expect(addresses, contains('192.168.1.255'));
      expect(addresses, contains('10.0.0.255'));
      // Loopback and IPv6 contribute nothing — there is no LAN behind them.
      expect(addresses, isNot(contains('127.0.0.255')));
      expect(addresses.toSet(), hasLength(addresses.length));
    });
  });
}
