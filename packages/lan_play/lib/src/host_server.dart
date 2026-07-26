import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'host_authority.dart';
import 'lan_timings.dart';
import 'protocol.dart';

/// The path the match WebSocket lives at.
const String matchPath = '/match';

/// The TCP port a host asks for first.
///
/// [HostServer.start] will happily take an OS-chosen port, and discovery
/// carries whichever one it got — but a guest typing an address BY HAND (the
/// always-available fallback when UDP discovery is blocked) has to be told the
/// port too, and a stable default means that field is usually already right.
/// A host that finds it taken falls back to 0 and shows what it actually got.
const int defaultMatchPort = 47780;

/// How many remote addresses the brute-force/amplification throttle will track
/// at once. A flood of DISTINCT source addresses degrades the throttle to
/// nothing rather than growing its bookkeeping without bound — the
/// per-connection limits still hold, and on a home LAN this is unreachable.
const int maxThrottledAddresses = 256;

/// The host device's socket transport: an [HttpServer] on the local network
/// that upgrades `GET /match` to a WebSocket and wires exactly ONE guest to a
/// [HostAuthority].
///
/// ## Policy (all of it deliberate, none of it in the authority)
///
///  * **One guest, claimed by AUTHENTICATION.** The playing slot is taken by a
///    valid `hello`, never by a mere connection — otherwise anyone able to open
///    a socket could lock the room out for a whole handshake window without
///    knowing the code. The claim itself is synchronous (inside the frame
///    handler, no await), so two valid hellos racing cannot both win: the loser
///    is told [BusyMessage] and closed. Sockets still mid-handshake are capped
///    at [LanTimings.maxPendingConnections] and each carries its own
///    [LanTimings.handshakeTimeout].
///  * **Room code.** The first frame must be a valid `hello` carrying the room
///    code. Anything else — a wrong code, a missing code, a `submit`, a garbage
///    frame — gets a constant-size `reject` (with `lastSeq: 0`, so nothing about
///    the match escapes) and the connection is closed. The authority never sees
///    the frame, so an unauthenticated peer can never pull the log.
///  * **Brute force.** Wrong codes are counted per remote address; past
///    [LanTimings.maxAuthFailuresPerWindow] that address is refused before the
///    upgrade. That, not the four digits, is what makes a four-digit code
///    adequate on a home network.
///  * **Amplification.** `hello` is the ONLY frame that replays the whole log,
///    so it is rate-limited twice: [LanTimings.helloMinInterval] within a
///    connection, and [LanTimings.maxConnectionsPerWindow] across reconnects
///    from one address. Every other frame is limited by
///    [LanTimings.frameMinInterval]. Excess is DROPPED silently — never
///    answered, never queued.
///  * **Hostile input.** Frames over [maxMessageLength] are dropped before the
///    parser; binary frames are ignored; decode failures are handed to
///    [HostAuthority.onGuestRaw], which answers with a bounded reject. Nothing a
///    peer sends can throw out of this class.
///  * **Liveness.** A `ping` goes out every [LanTimings.heartbeatInterval]; a
///    connection silent for [LanTimings.silenceTimeout] is dropped.
///
/// A dropped guest does NOT disturb the authority: the match state, the log and
/// the score all survive. The next connection presenting the right code becomes
/// the active guest and resyncs through the ordinary `hello`/`welcome` path.
class HostServer {
  /// Serve on an already-bound [server] that has NOT been listened to yet,
  /// taking ownership of it ([stop] closes it).
  ///
  /// [HostServer.start] is the usual entry point; this one exists for a caller
  /// that must hold the port before the match machinery exists.
  HostServer.attach(
    this._server, {
    required HostAuthority authority,
    required this.roomCode,
    this.timings = LanTimings.defaults,
  }) : _authority = authority {
    validateRoomCode(roomCode);
    // Subscribed BEFORE any request can arrive: `outbound` is a non-buffering
    // broadcast stream, so a late subscription would silently swallow the first
    // welcome.
    _outSub = _authority.outbound.listen(_onOutbound);
    _server.listen(_onRequest, onError: (Object _) {});
  }

  /// Bind and start serving. [port] 0 asks the OS for a free port — read the
  /// chosen one back from [port].
  static Future<HostServer> start({
    int port = 0,
    required HostAuthority authority,
    required String roomCode,
    LanTimings timings = LanTimings.defaults,
    InternetAddress? bindAddress,
  }) async {
    // Validated BEFORE binding: a bad code must not leave a socket behind.
    validateRoomCode(roomCode);
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
    );
    return HostServer.attach(server,
        authority: authority, roomCode: roomCode, timings: timings);
  }

  /// Mint a room code: four digits, drawn from [Random.secure] unless a
  /// deterministic [rng] is supplied.
  static String generateRoomCode([Random? rng]) {
    final r = rng ?? Random.secure();
    return r.nextInt(10000).toString().padLeft(4, '0');
  }

  /// A code nobody could ever present is a silently unjoinable room, so refuse
  /// it at the source rather than at the handshake.
  static void validateRoomCode(String code) {
    if (code.isEmpty) {
      throw ArgumentError.value(code, 'roomCode', 'must not be empty');
    }
    if (code.length > maxCodeLength) {
      throw ArgumentError.value(
          code, 'roomCode', 'must be at most $maxCodeLength characters');
    }
  }

  final HttpServer _server;
  final HostAuthority _authority;

  /// The code a guest must present in its `hello`.
  final String roomCode;

  final LanTimings timings;

  late final StreamSubscription<HostOutbound> _outSub;
  final _presence = StreamController<bool>.broadcast();
  final _Throttle _throttle = _Throttle();

  /// Sockets that have connected but not yet authenticated.
  final Set<_GuestConnection> _pending = {};

  /// Pre-auth sockets INCLUDING those whose upgrade is still in flight, so the
  /// cap can be applied synchronously, before that await.
  int _pendingCount = 0;

  /// The authenticated guest: the playing slot.
  _GuestConnection? _guest;

  bool _stopped = false;

  /// The bound port.
  int get port => _server.port;

  /// The bound address (`0.0.0.0` for the default any-IPv4 bind).
  InternetAddress get address => _server.address;

  /// True while an authenticated guest is connected.
  bool get hasGuest => _guest != null;

  /// The connected guest's display name, if any.
  String? get guestName => _guest?.name;

  /// How many sockets are mid-handshake. Diagnostics (and a test hook).
  int get pendingConnections => _pendingCount;

  /// How many remote addresses the throttle is currently tracking.
  /// Diagnostics — see [maxThrottledAddresses].
  int get throttledAddresses => _throttle.trackedAddresses;

  /// `true` when a guest completes the handshake, `false` when it goes away.
  /// Broadcast and non-buffering — subscribe before starting to wait.
  Stream<bool> get guestPresence => _presence.stream;

  /// Close the current guest's connection, keeping the server (and the match)
  /// running. The guest's client will reconnect and resync.
  Future<void> disconnectGuest([String reason = 'disconnected']) async {
    final c = _guest;
    if (c == null) return;
    await _close(c, WebSocketStatus.normalClosure, reason);
  }

  /// Stop serving and close every connection. Does NOT close the
  /// [HostAuthority] — its owner does that. Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _outSub.cancel();
    final open = <_GuestConnection>[
      if (_guest != null) _guest!,
      ..._pending,
    ];
    for (final c in open) {
      await _close(c, WebSocketStatus.goingAway, 'host stopped');
    }
    await _server.close(force: true);
    await _presence.close();
  }

  // --- accepting -------------------------------------------------------------

  Future<void> _onRequest(HttpRequest request) async {
    if (_stopped) {
      await _refuse(request, HttpStatus.serviceUnavailable);
      return;
    }
    if (request.uri.path != matchPath) {
      await _refuse(request, HttpStatus.notFound);
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _refuse(request, HttpStatus.badRequest);
      return;
    }
    final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (!_throttle.allowConnection(remote, timings)) {
      await _refuse(request, HttpStatus.tooManyRequests);
      return;
    }
    if (_pendingCount >= timings.maxPendingConnections) {
      await _refuse(request, HttpStatus.serviceUnavailable);
      return;
    }
    // Reserved SYNCHRONOUSLY, before the upgrade's async gap, and released on
    // every path out of here that does not end in an attached connection.
    _pendingCount++;

    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      _pendingCount--;
      return;
    }
    if (_stopped) {
      _pendingCount--;
      await _closeSocket(socket, WebSocketStatus.goingAway, 'host stopped');
      return;
    }
    _attach(socket, remote);
  }

  Future<void> _refuse(HttpRequest request, int status) async {
    try {
      request.response.statusCode = status;
      await request.response.close();
    } catch (_) {
      // The peer may have vanished mid-refusal; nothing to do.
    }
  }

  void _attach(WebSocket socket, String remote) {
    final conn = _GuestConnection(socket, remote);
    _pending.add(conn);
    conn.handshakeTimer = Timer(timings.handshakeTimeout, () {
      unawaited(
          _close(conn, WebSocketStatus.policyViolation, 'handshake timeout'));
    });
    socket.listen(
      (Object? data) => _onData(conn, data),
      onDone: () => _detach(conn),
      onError: (Object _) => _detach(conn),
      cancelOnError: true,
    );
  }

  // --- inbound ---------------------------------------------------------------

  void _onData(_GuestConnection c, Object? data) {
    if (c.detached || _stopped) return;
    // Any traffic at all proves the peer is alive — even traffic we then drop.
    c.lastActivity = DateTime.now();
    if (data is! String) return; // binary is not part of the protocol
    if (data.length > maxMessageLength) return; // dropped before the parser

    final result = Envelope.decode(data);
    if (!c.authenticated) {
      _handshake(c, result);
      return;
    }
    final now = DateTime.now();
    switch (result) {
      case DecodeOk(:final envelope):
        if (envelope is HelloMessage) {
          // The full-log path: spaced, and still code-checked.
          if (!c.allowHello(now, timings.helloMinInterval)) return;
          if (!_codeMatches(envelope.code)) {
            _fail(c, 'bad code', countFailure: true);
            return;
          }
          _authority.onGuestMessage(envelope);
          return;
        }
        if (!c.allowFrame(now, timings.frameMinInterval)) return;
        _authority.onGuestMessage(envelope);
      case DecodeFailure():
        if (!c.allowFrame(now, timings.frameMinInterval)) return;
        // Hand the RAW frame over so the authority's refusal policy (unknown
        // types ignored, everything else a bounded reject) stays in one place.
        _authority.onGuestRaw(data);
    }
  }

  void _handshake(_GuestConnection c, DecodeResult result) {
    if (result is! DecodeOk || result.envelope is! HelloMessage) {
      _fail(c, 'handshake required', countFailure: false);
      return;
    }
    final hello = result.envelope as HelloMessage;
    if (!_codeMatches(hello.code)) {
      _fail(c, 'bad code', countFailure: true);
      return;
    }
    // THE CLAIM. Synchronous from this check to the assignment, so a second
    // valid hello arriving in the same tick loses rather than ties.
    if (_guest != null) {
      _send(c, const BusyMessage());
      unawaited(_close(c, WebSocketStatus.policyViolation, 'busy'));
      return;
    }
    if (_pending.remove(c)) _pendingCount--;
    _guest = c;
    c.authenticated = true;
    c.name = hello.name;
    c.handshakeTimer?.cancel();
    c.handshakeTimer = null;
    c.markHello(DateTime.now());
    c.heartbeat = Timer.periodic(timings.heartbeatInterval, (_) => _beat(c));
    if (!_presence.isClosed) _presence.add(true);
    _authority.onGuestMessage(hello);
  }

  /// Constant-time-ish comparison: no early exit on the first differing
  /// character, so a peer cannot time its way to the code.
  bool _codeMatches(String? offered) {
    if (offered == null) return false;
    if (offered.length != roomCode.length) return false;
    var diff = 0;
    for (var i = 0; i < roomCode.length; i++) {
      diff |= offered.codeUnitAt(i) ^ roomCode.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Refuse and close. The reject deliberately carries `lastSeq: 0`: a peer that
  /// never authenticated learns NOTHING about the match, not even its length.
  void _fail(_GuestConnection c, String reason, {required bool countFailure}) {
    if (countFailure) _throttle.recordFailure(c.remote);
    _send(c, RejectMessage(reason: reason, lastSeq: 0));
    unawaited(_close(c, WebSocketStatus.policyViolation, reason));
  }

  void _beat(_GuestConnection c) {
    if (!identical(_guest, c)) return;
    if (DateTime.now().difference(c.lastActivity) > timings.silenceTimeout) {
      unawaited(_close(c, WebSocketStatus.goingAway, 'silent peer'));
      return;
    }
    _send(c, const PingMessage());
  }

  // --- outbound --------------------------------------------------------------

  void _onOutbound(HostOutbound out) {
    if (!out.toGuest) return; // host-local messages ride the authority stream
    final c = _guest;
    if (c == null) return;
    _send(c, out.message);
  }

  void _send(_GuestConnection c, Envelope message) {
    if (c.closing) return;
    try {
      c.socket.add(message.encode());
    } catch (_) {
      // Racing a close; the socket's onDone will clean up.
    }
  }

  Future<void> _close(_GuestConnection c, int status, String reason) async {
    c.closing = true;
    final socket = c.socket;
    _detach(c);
    await _closeSocket(socket, status, reason);
  }

  Future<void> _closeSocket(WebSocket socket, int status, String reason) async {
    try {
      await socket.close(status, reason);
    } catch (_) {
      // already gone
    }
  }

  void _detach(_GuestConnection c) {
    if (c.detached) return;
    c.detached = true;
    c.handshakeTimer?.cancel();
    c.heartbeat?.cancel();
    if (_pending.remove(c)) _pendingCount--;
    if (identical(_guest, c)) {
      _guest = null;
      if (!_presence.isClosed) _presence.add(false);
    }
  }
}

/// One accepted socket and everything the policy needs to remember about it.
class _GuestConnection {
  _GuestConnection(this.socket, this.remote) : lastActivity = DateTime.now();

  final WebSocket socket;
  final String remote;

  bool authenticated = false;
  bool closing = false;
  bool detached = false;
  String? name;
  DateTime lastActivity;
  DateTime? _lastHello;
  DateTime? _lastFrame;
  Timer? handshakeTimer;
  Timer? heartbeat;

  void markHello(DateTime at) => _lastHello = at;

  bool allowHello(DateTime now, Duration min) {
    final last = _lastHello;
    if (last != null && now.difference(last) < min) return false;
    _lastHello = now;
    return true;
  }

  bool allowFrame(DateTime now, Duration min) {
    final last = _lastFrame;
    if (last != null && now.difference(last) < min) return false;
    _lastFrame = now;
    return true;
  }
}

/// Per-remote-address sliding-window quotas: connections (the reconnect-based
/// log-pull lever) and wrong codes (the brute-force lever).
///
/// Bookkeeping is bounded: expired hits are swept on every check, addresses
/// with nothing left are forgotten, and past [maxThrottledAddresses] the tables
/// are dropped wholesale (see that constant).
class _Throttle {
  final Map<String, List<DateTime>> _connections = {};
  final Map<String, List<DateTime>> _failures = {};

  int get trackedAddresses => {..._connections.keys, ..._failures.keys}.length;

  bool allowConnection(String remote, LanTimings timings) {
    final now = DateTime.now();
    _sweep(now, timings.throttleWindow);
    if ((_failures[remote]?.length ?? 0) >= timings.maxAuthFailuresPerWindow) {
      return false;
    }
    final hits = _connections[remote] ?? [];
    if (hits.length >= timings.maxConnectionsPerWindow) return false;
    hits.add(now);
    _connections[remote] = hits;
    return true;
  }

  void recordFailure(String remote) =>
      (_failures[remote] ??= []).add(DateTime.now());

  /// Drop expired hits, forget addresses that have none left, and refuse to
  /// grow without bound if a flood of distinct addresses ever arrives.
  void _sweep(DateTime now, Duration window) {
    for (final table in [_connections, _failures]) {
      table.removeWhere((_, hits) {
        hits.removeWhere((t) => now.difference(t) > window);
        return hits.isEmpty;
      });
    }
    if (trackedAddresses > maxThrottledAddresses) {
      _connections.clear();
      _failures.clear();
    }
  }
}
