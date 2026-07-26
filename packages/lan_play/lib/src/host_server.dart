import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'host_authority.dart';
import 'lan_timings.dart';
import 'protocol.dart';

/// The path the match WebSocket lives at.
const String matchPath = '/match';

/// The host device's socket transport: an [HttpServer] on the local network
/// that upgrades `GET /match` to a WebSocket and wires exactly ONE guest to a
/// [HostAuthority].
///
/// ## Policy (all of it deliberate, none of it in the authority)
///
///  * **One guest.** The connection slot is reserved SYNCHRONOUSLY, before the
///    WebSocket upgrade is awaited, so two simultaneous joiners cannot both win
///    it. The loser is told [BusyMessage] and closed. A pending (not yet
///    authenticated) connection holds the slot too — bounded by
///    [LanTimings.handshakeTimeout], so an idle socket cannot lock the room out.
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
  HostServer._(this._server, this._authority, this.roomCode, this.timings) {
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
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
      shared: false,
    );
    return HostServer._(server, authority, roomCode, timings);
  }

  /// Mint a room code: four digits, drawn from [Random.secure] unless a
  /// deterministic [rng] is supplied.
  static String generateRoomCode([Random? rng]) {
    final r = rng ?? Random.secure();
    return r.nextInt(10000).toString().padLeft(4, '0');
  }

  final HttpServer _server;
  final HostAuthority _authority;

  /// The code a guest must present in its `hello`.
  final String roomCode;

  final LanTimings timings;

  late final StreamSubscription<HostOutbound> _outSub;
  final _presence = StreamController<bool>.broadcast();
  final _Throttle _throttle = _Throttle();

  _GuestConnection? _conn;
  bool _slotTaken = false;
  bool _stopped = false;

  /// The bound port.
  int get port => _server.port;

  /// The bound address (`0.0.0.0` for the default any-IPv4 bind).
  InternetAddress get address => _server.address;

  /// True while an authenticated guest is connected.
  bool get hasGuest => _conn?.authenticated ?? false;

  /// The connected guest's display name, if any.
  String? get guestName => hasGuest ? _conn?.name : null;

  /// `true` when a guest completes the handshake, `false` when it goes away.
  /// Broadcast and non-buffering — subscribe before starting to wait.
  Stream<bool> get guestPresence => _presence.stream;

  /// Close the current guest's connection, keeping the server (and the match)
  /// running. The guest's client will reconnect and resync.
  Future<void> disconnectGuest([String reason = 'disconnected']) async {
    final c = _conn;
    if (c == null) return;
    await _close(c, WebSocketStatus.normalClosure, reason);
  }

  /// Stop serving and close the guest connection. Does NOT close the
  /// [HostAuthority] — its owner does that. Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _outSub.cancel();
    final c = _conn;
    if (c != null) await _close(c, WebSocketStatus.goingAway, 'host stopped');
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

    // Reserve the single guest slot BEFORE the upgrade's async gap.
    final busy = _slotTaken;
    if (!busy) _slotTaken = true;

    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      if (!busy) _slotTaken = false;
      return;
    }
    if (busy || _stopped) {
      await _sendAndClose(socket, const BusyMessage(),
          WebSocketStatus.policyViolation, 'busy');
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
    _conn = conn;
    conn.handshakeTimer = Timer(timings.handshakeTimeout, () {
      unawaited(_close(
          conn, WebSocketStatus.policyViolation, 'handshake timeout'));
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
    if (!identical(_conn, c) || _stopped) return;
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
    if (!identical(_conn, c)) return;
    if (DateTime.now().difference(c.lastActivity) > timings.silenceTimeout) {
      unawaited(_close(c, WebSocketStatus.goingAway, 'silent peer'));
      return;
    }
    _send(c, const PingMessage());
  }

  // --- outbound --------------------------------------------------------------

  void _onOutbound(HostOutbound out) {
    if (!out.toGuest) return; // host-local messages ride the authority stream
    final c = _conn;
    if (c == null || !c.authenticated) return;
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

  Future<void> _sendAndClose(
      WebSocket socket, Envelope message, int status, String reason) async {
    try {
      socket.add(message.encode());
    } catch (_) {
      // fall through to the close
    }
    try {
      await socket.close(status, reason);
    } catch (_) {
      // already gone
    }
  }

  Future<void> _close(_GuestConnection c, int status, String reason) async {
    c.closing = true;
    final socket = c.socket;
    _detach(c);
    try {
      await socket.close(status, reason);
    } catch (_) {
      // already gone
    }
  }

  void _detach(_GuestConnection c) {
    if (!identical(_conn, c)) return;
    final wasAuthenticated = c.authenticated;
    c.handshakeTimer?.cancel();
    c.heartbeat?.cancel();
    _conn = null;
    _slotTaken = false;
    if (wasAuthenticated && !_presence.isClosed) _presence.add(false);
  }
}

/// One accepted socket and everything the policy needs to remember about it.
class _GuestConnection {
  _GuestConnection(this.socket, this.remote) : lastActivity = DateTime.now();

  final WebSocket socket;
  final String remote;

  bool authenticated = false;
  bool closing = false;
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
class _Throttle {
  final Map<String, List<DateTime>> _connections = {};
  final Map<String, List<DateTime>> _failures = {};

  bool allowConnection(String remote, LanTimings timings) {
    final now = DateTime.now();
    if (_count(_failures, remote, now, timings.throttleWindow) >=
        timings.maxAuthFailuresPerWindow) {
      return false;
    }
    final hits = _prune(_connections, remote, now, timings.throttleWindow);
    if (hits.length >= timings.maxConnectionsPerWindow) return false;
    hits.add(now);
    return true;
  }

  void recordFailure(String remote) =>
      _failures.putIfAbsent(remote, () => []).add(DateTime.now());

  int _count(Map<String, List<DateTime>> m, String key, DateTime now,
          Duration window) =>
      _prune(m, key, now, window).length;

  List<DateTime> _prune(Map<String, List<DateTime>> m, String key, DateTime now,
      Duration window) {
    final hits = m.putIfAbsent(key, () => []);
    hits.removeWhere((t) => now.difference(t) > window);
    return hits;
  }
}
