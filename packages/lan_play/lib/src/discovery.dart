import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'display_name.dart' show truncateForDisplay;
import 'protocol.dart' show maxNameLength;

/// The UDP port the host's beacon listens on.
///
/// Fixed (not OS-chosen) because a prober has to know where to knock; the
/// injectable `port` parameter exists for tests, which must never touch a real
/// well-known port.
const int discoveryPort = 47777;

/// The one datagram a prober sends. Compared BYTE FOR BYTE — a near miss is not
/// a probe, so nothing but this exact string is ever answered.
///
/// The `v1` is the discovery handshake's own version, independent of the match
/// protocol's: a future prober that wants a richer answer asks with `v2` and old
/// beacons stay silent rather than answering something it cannot read.
const String discoveryProbe = 'AIGAMMON?v1';

/// Hard cap on a datagram either end will look at. Both the probe and the
/// answer are tens of bytes; anything approaching a kilobyte is a peer trying
/// something, and is dropped before the JSON parser.
const int maxDatagramLength = 1024;

/// Minimum spacing between two answers to the SAME source address.
///
/// The answer is a few times the size of the probe, so an unthrottled beacon is
/// a (small) reflection amplifier. One answer every fifth of a second is far
/// more than a real prober needs — it probes every few seconds — and turns the
/// amplifier off.
const Duration beaconMinAnswerInterval = Duration(milliseconds: 200);

/// How many source addresses the beacon's spacing table will track. Past this
/// the table is dropped wholesale rather than grown without bound; on a home
/// LAN it is unreachable.
const int maxBeaconSources = 256;

/// A host that answered a probe: enough to reach it, and nothing else.
///
/// There is deliberately NO room code here — see [HostBeacon].
class DiscoveredHost {
  const DiscoveredHost({
    required this.name,
    required this.address,
    required this.port,
  });

  /// The host device's display name, as it chose to advertise itself.
  final String name;

  /// The IP the answer came FROM — observed, never self-reported, so a host
  /// cannot point a guest at a third party.
  final String address;

  /// The TCP port its match server is listening on.
  final int port;

  /// Identity is where to knock: two answers from the same endpoint are one
  /// host, however many times it repeats itself.
  @override
  bool operator ==(Object other) =>
      other is DiscoveredHost && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);

  @override
  String toString() => 'DiscoveredHost($name at $address:$port)';
}

/// The host device's presence beacon: a UDP socket that answers [discoveryProbe]
/// with a tiny JSON object saying WHO is here and WHERE to knock.
///
/// ## What it does not say
///
/// The answer carries `{name, port, code: false}` and nothing more. The room
/// code is the ONLY thing standing between a stranger on the Wi-Fi and the
/// match, so it is never broadcast — `code` is the literal `false`, a permanent
/// marker that this beacon does not and will not carry the secret. A guest
/// still has to be told the four digits by the person holding the other phone,
/// which is exactly the intended ceremony.
///
/// ## Hostile input
///
/// Nothing a peer sends can throw out of this class: oversized datagrams are
/// dropped before decoding, undecodable bytes are dropped before comparison,
/// and anything that is not EXACTLY the probe is ignored in silence. Answers
/// are spaced per source address (see [beaconMinAnswerInterval]).
class HostBeacon {
  HostBeacon._(this._socket, this.name, this.matchPort);

  /// Bind and start answering.
  ///
  /// [matchPort] is the port [HostServer] is listening on — read it back from
  /// the server rather than assuming, since the server may have been given 0.
  /// [port] 0 asks the OS for a free port (tests only; a real beacon must sit on
  /// [discoveryPort] or nobody can find it). [bindAddress] defaults to all
  /// IPv4 interfaces.
  static Future<HostBeacon> start({
    required String name,
    required int matchPort,
    int port = discoveryPort,
    InternetAddress? bindAddress,
  }) async {
    final socket = await RawDatagramSocket.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    // Not needed to ANSWER (answers are unicast), but a beacon bound to the
    // wildcard address on some platforms must have this set to receive
    // broadcasts addressed to the subnet rather than to it specifically.
    socket.broadcastEnabled = true;
    final beacon = HostBeacon._(socket, _trimName(name), matchPort);
    beacon._listen();
    return beacon;
  }

  final RawDatagramSocket _socket;

  /// The name advertised to probers — bounded, and never empty.
  final String name;

  /// The match server's TCP port, which is what a guest actually connects to.
  final int matchPort;

  final Map<String, DateTime> _lastAnswer = {};
  bool _stopped = false;

  /// The UDP port this beacon is bound to.
  int get port => _socket.port;

  /// Stop answering and release the socket. Idempotent.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _socket.close();
  }

  void _listen() {
    _socket.listen(
      _onEvent,
      // A UDP socket can report an error (Windows raises one when a previous
      // datagram drew an ICMP port-unreachable); it is never fatal here.
      onError: (Object _) {},
    );
  }

  void _onEvent(RawSocketEvent event) {
    if (_stopped || event != RawSocketEvent.read) return;
    final Datagram? datagram;
    try {
      datagram = _socket.receive();
    } catch (_) {
      return; // see the onError note above
    }
    if (datagram == null) return;
    if (datagram.data.length > maxDatagramLength) return;
    final String text;
    try {
      text = utf8.decode(datagram.data);
    } catch (_) {
      return; // not text, so not a probe
    }
    if (text != discoveryProbe) return;
    if (!_allow(datagram.address.address)) return;
    _answer(datagram.address, datagram.port);
  }

  /// One answer per source address per [beaconMinAnswerInterval].
  bool _allow(String source) {
    final now = DateTime.now();
    _lastAnswer.removeWhere(
        (_, at) => now.difference(at) > beaconMinAnswerInterval * 10);
    if (_lastAnswer.length > maxBeaconSources) _lastAnswer.clear();
    final last = _lastAnswer[source];
    if (last != null && now.difference(last) < beaconMinAnswerInterval) {
      return false;
    }
    _lastAnswer[source] = now;
    return true;
  }

  void _answer(InternetAddress to, int port) {
    // `code: false` is a CONSTANT, not a value: presence is public, the room
    // code is not. See the class doc.
    final payload = utf8.encode(jsonEncode({
      'name': name,
      'port': matchPort,
      'code': false,
    }));
    try {
      _socket.send(payload, to, port);
    } catch (_) {
      // The peer vanished, or the route went away mid-answer; a probe that goes
      // unanswered is simply retried.
    }
  }
}

/// Send one probe to every address in [targets] and collect the answers for
/// [timeout].
///
/// Returns the distinct hosts that answered, in the order they were first heard
/// from. The prober binds an EPHEMERAL port (never [discoveryPort] — a device
/// may be hosting and probing at the same time) and always waits the full
/// [timeout]: there is no way to know how many devices are out there, so the
/// deadline is the only terminating condition.
///
/// [targets] defaults to [broadcastTargets]. Passing an explicit list is how a
/// test probes over loopback, and how a future "probe this one address" feature
/// would work.
///
/// Nothing here throws for a network reason: an interface that refuses a
/// broadcast, an answer that is not JSON, an answer whose fields are the wrong
/// shape — all are dropped, and the result is simply the hosts that behaved.
Future<List<DiscoveredHost>> discoverHosts({
  int port = discoveryPort,
  List<InternetAddress>? targets,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final destinations = targets ?? await broadcastTargets();
  final RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  } catch (_) {
    return const []; // no usable socket: nothing to report, nothing to throw
  }
  socket.broadcastEnabled = true;

  final found = <DiscoveredHost>[];
  final seen = <DiscoveredHost>{};
  socket.listen(
    (event) {
      if (event != RawSocketEvent.read) return;
      final Datagram? datagram;
      try {
        datagram = socket.receive();
      } catch (_) {
        return;
      }
      if (datagram == null) return;
      final host = _readAnswer(datagram);
      if (host == null) return;
      if (seen.add(host)) found.add(host);
    },
    onError: (Object _) {},
  );

  final probe = utf8.encode(discoveryProbe);
  for (final target in destinations) {
    try {
      socket.send(probe, target, port);
    } catch (_) {
      // A broadcast an interface will not carry (a down adapter, a VPN tunnel)
      // must not take the whole sweep down with it.
    }
  }

  await Future<void>.delayed(timeout);
  socket.close();
  return found;
}

/// Parse one answer, or null if it is not one. Every field is validated: this
/// is untrusted input from whoever felt like replying.
DiscoveredHost? _readAnswer(Datagram datagram) {
  if (datagram.data.length > maxDatagramLength) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(datagram.data));
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final port = decoded['port'];
  if (port is! int || port < 1 || port > 65535) return null;
  final rawName = decoded['name'];
  if (rawName != null && rawName is! String) return null;
  final name = _trimName(rawName as String? ?? '',
      fallback: datagram.address.address);
  return DiscoveredHost(
    name: name,
    // The OBSERVED source address, never a self-reported one: a peer must not
    // be able to point a guest at some third machine.
    address: datagram.address.address,
    port: port,
  );
}

/// Bound and clean a display name from either end of the wire, falling back to
/// [fallback] (or a generic label) when there is nothing usable left.
String _trimName(String name, {String fallback = ''}) {
  // Rune-safe: a name arriving from the wire is arbitrary user text, and a
  // substring cut at [maxNameLength] could land inside a surrogate pair — see
  // [truncateForDisplay]. The ellipsis is inside the budget, so the result still
  // satisfies the protocol's own maxNameLength check.
  final bounded = truncateForDisplay(name.trim(), maxNameLength);
  if (bounded.isNotEmpty) return bounded;
  return fallback.isNotEmpty ? fallback : 'Nearby device';
}

/// Every address worth sending a probe to on this device.
///
/// The all-networks broadcast `255.255.255.255` is always included, but on its
/// own it is not enough: it is not routed by every stack, and a device with
/// several interfaces (Wi-Fi plus a VPN or a hotspot) may put it on the wrong
/// one. So each interface's own subnet broadcast is added too — see
/// [broadcastTargetsFor] for the assumption that involves.
Future<List<InternetAddress>> broadcastTargets() async {
  List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
  } catch (_) {
    // Enumeration can be refused (a sandbox, a missing permission); the
    // all-networks address alone still finds a host on a simple network.
    return [InternetAddress('255.255.255.255')];
  }
  return broadcastTargetsFor(
      [for (final i in interfaces) ...i.addresses]);
}

/// The probe targets derived from a set of local [addresses]: the all-networks
/// broadcast plus one subnet broadcast per IPv4 address.
///
/// ## The /24 assumption
///
/// `dart:io` does not expose an interface's netmask, so the subnet broadcast
/// cannot be computed exactly. `a.b.c.d` therefore becomes `a.b.c.255`, which
/// is right for the /24 that essentially every home router hands out and
/// harmless when it is wrong: on a /16 the datagram reaches a smaller set of
/// machines than intended (a missed host, not a leak), and `255.255.255.255` is
/// always tried alongside it.
///
/// Loopback and IPv6 addresses contribute nothing — there is no LAN behind
/// them.
List<InternetAddress> broadcastTargetsFor(List<InternetAddress> addresses) {
  final targets = <String>{'255.255.255.255'};
  for (final address in addresses) {
    if (address.type != InternetAddressType.IPv4) continue;
    if (address.isLoopback) continue;
    final octets = address.address.split('.');
    if (octets.length != 4) continue;
    targets.add('${octets[0]}.${octets[1]}.${octets[2]}.255');
  }
  return [
    for (final t in targets)
      if (_parse(t) case final address?) address,
  ];
}

InternetAddress? _parse(String address) => InternetAddress.tryParse(address);
