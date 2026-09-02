import 'dart:async';
import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';

import '../data/persistence_hooks.dart';
import '../net/net_match_controller.dart';

/// The screen's whole view of the network.
///
/// [LanScreen] talks to nearby devices ONLY through this seam, so its widget
/// tests can drive a host joining, a busy room and a wrong code without binding
/// a socket, opening a firewall hole, or waiting on a real two-second discovery
/// sweep. [LiveNearbyTransport] is the one production implementation.
///
/// ## Who stops what (read before changing any teardown)
///
/// Three things have three different owners, and the split is deliberate:
///
///  1. **The LINK** — the [HostServer] + [HostBeacon] on the hosting device, the
///     [GuestClient] on the joining one — belongs to the SESSION, and therefore
///     to this screen. It exists before any match does (the host is bound and
///     showing a room code while it waits; the guest is connecting while the
///     "joining…" spinner turns) and it is released by [HostSession.stop] /
///     [GuestSession.dispose].
///  2. **The TRANSPORT** ([SocketTransport], a view over the link) belongs to the
///     CONTROLLER: `NetMatchController.disposeController` disposes it. The screen
///     must never dispose a transport — that is the one ownership rule the
///     controller's doc calls out, and it is why [controller] builds the transport
///     itself rather than handing one out.
///  3. **The MATCH LOG** ([MatchRelay], on the hosting device only) belongs to the
///     session as well, because it outlives any one guest: a guest that drops and
///     reconnects is handed the same log back. [HostSession.stop] closes it.
///
/// So: pop the board -> dispose the controller (which disposes the transport) ->
/// stop the session (which stops the server, the beacon and the relay).
abstract interface class NearbyTransport {
  /// This device's advertised name — shown to the other player in the
  /// discovered-hosts list and in the game header.
  String get deviceName;

  /// Bind the match server, mint a room code, and start answering discovery
  /// probes. Throws if the port cannot be bound.
  Future<HostSession> startHosting({
    required MatchConfig config,
    required String name,
  });

  /// One discovery sweep. Never throws — a sweep that finds nothing and a
  /// sweep that could not be sent both come back empty.
  Future<List<DiscoveredHost>> discover({Duration timeout});

  /// Start connecting to a host. Returns immediately; the caller watches
  /// [GuestSession.states] and awaits [GuestSession.welcome].
  GuestSession join({
    required String address,
    required int port,
    required String code,
    required String name,
  });

  /// This device's address on the local network, for the "type this in"
  /// fallback. Null when it cannot be determined.
  Future<String?> localAddress();
}

/// A running host: the match log, the server that carries it, and the beacon
/// that advertises it.
///
/// The screen owns the lifecycle — [stop] releases ALL of it — and must dispose
/// any controller built from [controller] BEFORE calling [stop].
abstract interface class HostSession {
  /// The match this device fixed.
  MatchConfig get config;

  /// The four digits the other player has to type. Shown on screen; never
  /// broadcast (see [HostBeacon]).
  String get roomCode;

  /// The TCP port the match server is listening on.
  int get port;

  /// The side this device plays — [TransportSession.hostSide] (white) by the
  /// convention both LAN and online share.
  Player get localSide;

  /// True while an authenticated guest is attached. The screen watches this to
  /// know when to open the board; the controller gets the same signal from the
  /// transport (which is what gates the opening roll).
  ValueListenable<bool> get guestConnected;

  /// The connected guest's display name, if it gave one.
  String? get guestName;

  /// Build this device's controller, over a fresh transport it then OWNS.
  NetMatchController controller({MatchPersistence persistence});

  /// Stop the beacon, the server and the match log. Idempotent. Does NOT touch
  /// any controller or transport — see the [NearbyTransport] doc.
  Future<void> stop();
}

/// A guest's link to one host.
abstract interface class GuestSession {
  /// The lifecycle transitions the screen narrates.
  Stream<GuestConnectionState> get states;

  /// The current transition, for seeding before the first event arrives.
  GuestConnectionState get state;

  /// Completes on the first welcome, or with an error on a TERMINAL failure
  /// (wrong code, protocol mismatch). A busy room leaves it pending.
  Future<WelcomeMessage> get welcome;

  /// The side this device plays. Only valid once [welcome] has completed.
  Player get localSide;

  /// The match config the host fixed. Only valid once [welcome] has completed.
  MatchConfig get config;

  /// Build this device's controller, over a fresh transport it then OWNS.
  NetMatchController controller({MatchPersistence persistence});

  /// Stop reconnecting and release the socket. Idempotent. Does NOT touch any
  /// controller or transport — see the [NearbyTransport] doc.
  Future<void> dispose();
}

/// The production transport: real sockets, real UDP discovery.
class LiveNearbyTransport implements NearbyTransport {
  const LiveNearbyTransport({this.timings = LanTimings.defaults});

  final LanTimings timings;

  @override
  String get deviceName {
    try {
      final host = Platform.localHostname.trim();
      // Rune-safe (a hostname can carry non-ASCII): see [truncateForDisplay].
      if (host.isNotEmpty) return truncateForDisplay(host, 32);
    } catch (_) {
      // Some platforms refuse the hostname; a generic label still identifies
      // the device well enough for a room with two phones in it.
    }
    return 'AI Gammon device';
  }

  @override
  Future<HostSession> startHosting({
    required MatchConfig config,
    required String name,
  }) async {
    final relay = MatchRelay(config: config);
    final roomCode = HostServer.generateRoomCode();
    HostServer server;
    try {
      server = await HostServer.start(
        port: defaultMatchPort,
        roomCode: roomCode,
        timings: timings,
        lastSeq: () => relay.lastSeq,
      );
    } catch (_) {
      // The preferred port is taken. An OS-chosen one works just as well —
      // discovery carries it, and the screen shows it for manual entry.
      server = await HostServer.start(
        roomCode: roomCode,
        timings: timings,
        lastSeq: () => relay.lastSeq,
      );
    }
    HostBeacon? beacon;
    try {
      beacon = await HostBeacon.start(name: name, matchPort: server.port);
    } catch (_) {
      // The discovery port is already taken (another AI Gammon on this device,
      // or something else on 47777). Hosting still works — the guest types the
      // address in — so this is a degraded mode, not a failure.
      beacon = null;
    }
    return _LiveHostSession(relay, server, beacon, timings);
  }

  @override
  Future<List<DiscoveredHost>> discover({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      return await discoverHosts(timeout: timeout);
    } catch (_) {
      // A sweep that could not go out is indistinguishable, to the user, from
      // one that found nobody. Both are an empty list and a retry in 3 seconds.
      return const [];
    }
  }

  @override
  GuestSession join({
    required String address,
    required int port,
    required String code,
    required String name,
  }) =>
      _LiveGuestSession(
        GuestClient.connect(
          address,
          port,
          roomCode: code,
          name: name,
          timings: timings,
        ),
        timings,
      );

  /// The address to SHOW the host so they can read it out to their guest.
  ///
  /// Enumerating the interfaces is the whole implementation. This used to try
  /// `network_info_plus`'s `getWifiIP()` first and fall back to here, but the
  /// fallback answered every case the plugin did: `NetworkInterface.list` needs
  /// no permission, works on every platform the app targets (including the
  /// desktops and simulators where the plugin returned nothing), and returns the
  /// same Wi-Fi address because that is the non-loopback IPv4 interface a phone
  /// on a LAN has. The plugin was five transitive dependencies and a location
  /// permission on some Android versions, bought nothing the fallback did not
  /// already provide, and is gone.
  ///
  /// Null when enumeration is refused outright; the caller then shows its "ask
  /// them to search for you" copy instead of an address.
  @override
  Future<String?> localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.isLinkLocal) continue;
          return address.address;
        }
      }
    } catch (_) {
      // Enumeration refused; the caller shows its "ask them to search" copy.
    }
    return null;
  }
}

class _LiveHostSession implements HostSession {
  _LiveHostSession(this._relay, this._server, this._beacon, this._timings) {
    _presence = _server.guestPresence.listen((connected) {
      guestConnected.value = connected;
    });
  }

  final MatchRelay _relay;
  final HostServer _server;
  final HostBeacon? _beacon;

  /// The clocks this transport was built with, handed to the controller as its
  /// gate deadline so both ends of the link run on the same beats.
  final LanTimings _timings;
  late final StreamSubscription<bool> _presence;
  bool _stopped = false;

  /// Deliberately NOT disposed by [stop]: a controller built from this session
  /// holds a listener on it, and the screen disposes the controller as part of
  /// tearing down — after which an undisposed notifier with no listeners is
  /// simply garbage. Disposing it here would make that ordering load-bearing.
  @override
  final ValueNotifier<bool> guestConnected = ValueNotifier<bool>(false);

  @override
  MatchConfig get config => _relay.config;

  @override
  String get roomCode => _server.roomCode;

  @override
  int get port => _server.port;

  @override
  Player get localSide => TransportSession.hostSide;

  @override
  String? get guestName => _server.guestName;

  @override
  NetMatchController controller({
    MatchPersistence persistence = const NoopPersistence(),
  }) =>
      NetMatchController(
        transport: SocketTransport.host(server: _server, relay: _relay),
        persistence: persistence,
        // The one clock the controller needs: how long a latched "sending…" gate
        // may wait for the log to answer. A LAN round trip is orders of magnitude
        // shorter, so reaching it really does mean the frame is gone.
        gateTimeout: _timings.connectTimeout,
      );

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _beacon?.stop();
    await _presence.cancel();
    await _server.stop();
    await _relay.close();
  }
}

class _LiveGuestSession implements GuestSession {
  _LiveGuestSession(this._client, this._timings);

  final GuestClient _client;
  final LanTimings _timings;

  @override
  Stream<GuestConnectionState> get states => _client.states;

  @override
  GuestConnectionState get state => _client.state;

  @override
  Future<WelcomeMessage> get welcome => _client.welcome;

  @override
  Player get localSide => _welcome.side;

  @override
  MatchConfig get config => _welcome.config;

  WelcomeMessage get _welcome {
    final w = _client.lastWelcome;
    if (w == null) {
      throw StateError('not welcomed yet — await welcome before reading this');
    }
    return w;
  }

  @override
  NetMatchController controller({
    MatchPersistence persistence = const NoopPersistence(),
  }) =>
      NetMatchController(
        transport: SocketTransport.guest(client: _client),
        persistence: persistence,
        gateTimeout: _timings.connectTimeout,
      );

  @override
  Future<void> dispose() => _client.dispose();
}

/// The transport [LanScreen] uses. Overridden in widget tests with a fake.
final nearbyTransportProvider = Provider<NearbyTransport>(
  (ref) => const LiveNearbyTransport(),
);
