import 'dart:async';
import 'dart:io';
import 'dart:math';

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

/// The bound peer's socket transport: an [HttpServer] on the local network that
/// upgrades `GET /match` to a WebSocket and carries frames to and from exactly
/// ONE guest.
///
/// ## A pipe, not a player
///
/// This class knows nothing about backgammon. It authenticates a guest, polices
/// the connection, and exposes two things: [guestFrames] (every authenticated,
/// rate-limited frame the guest sent) and [send] (one frame to the guest). What
/// those frames MEAN is `SocketTransport`'s business, and the game logic above it
/// is the controller's. Before Plan 17 this class held a `HostAuthority`
/// reference and fed a referee; the referee is gone and the socket policy below
/// is unchanged — that separation is exactly why the deletion was safe.
///
/// ## Policy (all of it deliberate)
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
///    code. Anything else — a wrong code, a missing code, a write frame, a
///    garbage frame — gets a constant-size `reject` (with `lastSeq: 0`, so
///    nothing about the match escapes) and the connection is closed. No frame
///    from an unauthenticated peer ever reaches [guestFrames], so it can never
///    pull the log.
///  * **Brute force.** Wrong codes are counted per remote address; past
///    [LanTimings.maxAuthFailuresPerWindow] that address is refused before the
///    upgrade. That, not the four digits, is what makes a four-digit code
///    adequate on a home network.
///  * **Amplification.** `hello` is the ONLY frame that replays the whole log,
///    so it is rate-limited twice: [LanTimings.helloMinInterval] within a
///    connection, and [LanTimings.maxConnectionsPerWindow] across reconnects
///    from one address. Every other frame is limited by a per-connection TOKEN
///    BUCKET — [LanTimings.frameBurst] frames of capacity, refilled one per
///    [LanTimings.frameMinInterval] — so the sustained rate is bounded while the
///    protocol's own three-frame roll burst always gets through (see
///    `_GuestConnection.allowFrame` for why a hard minimum spacing could not).
///    Excess is DROPPED silently — never answered, never queued.
///  * **Hostile input.** Frames over [maxMessageLength] are dropped before the
///    parser; binary frames are ignored; a decode failure earns a bounded
///    `reject` (an unknown TYPE is ignored instead — a newer peer may send
///    frames we predate). Nothing a peer sends can throw out of this class.
///  * **Liveness.** A `ping` goes out every [LanTimings.heartbeatInterval]; a
///    connection silent for [LanTimings.silenceTimeout] is dropped.
///
/// A dropped guest does NOT disturb the match: the relay's log and roll
/// documents survive. The next connection presenting the right code becomes the
/// active guest and resyncs through the ordinary `hello`/`welcome` path.
class HostServer {
  /// Serve on an already-bound [server] that has NOT been listened to yet,
  /// taking ownership of it ([stop] closes it).
  ///
  /// [HostServer.start] is the usual entry point; this one exists for a caller
  /// that must hold the port before the match machinery exists.
  ///
  /// [lastSeq] is read when refusing a malformed frame, so the guest learns
  /// whether it is behind. It defaults to "nothing committed"; the socket
  /// transport wires it to the relay.
  HostServer.attach(
    this._server, {
    required this.roomCode,
    this.timings = LanTimings.defaults,
    int Function()? lastSeq,
  }) : _lastSeq = lastSeq ?? _noSeq {
    validateRoomCode(roomCode);
    _server.listen(_onRequest, onError: (Object _) {});
  }

  /// Bind and start serving. [port] 0 asks the OS for a free port — read the
  /// chosen one back from [port].
  static Future<HostServer> start({
    int port = 0,
    required String roomCode,
    LanTimings timings = LanTimings.defaults,
    InternetAddress? bindAddress,
    int Function()? lastSeq,
  }) async {
    // Validated BEFORE binding: a bad code must not leave a socket behind.
    validateRoomCode(roomCode);
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
    );
    return HostServer.attach(server,
        roomCode: roomCode, timings: timings, lastSeq: lastSeq);
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

  static int _noSeq() => 0;

  final HttpServer _server;
  final int Function() _lastSeq;

  /// The code a guest must present in its `hello`.
  final String roomCode;

  final LanTimings timings;

  final _presence = StreamController<bool>.broadcast();
  final _frames = StreamController<Envelope>.broadcast();
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

  /// The `hello` the CURRENTLY authenticated guest presented, or null when nobody
  /// holds the playing slot.
  ///
  /// Retained because [guestFrames] is broadcast and NON-BUFFERING while the slot
  /// is claimed the instant the socket is bound: the "Play Nearby" screen shows a
  /// room code long before it builds a transport, so the join `hello` is routinely
  /// published with no subscriber attached and is then gone for good. A transport
  /// built late reads it here and answers it (see `SocketTransport.host`), instead
  /// of leaving the guest waiting for a welcome that can never arrive.
  ///
  /// Lives on the connection, so it disappears with the guest.
  HelloMessage? get guestHello => _guest?.hello;

  /// How many sockets are mid-handshake. Diagnostics (and a test hook).
  int get pendingConnections => _pendingCount;

  /// How many remote addresses the throttle is currently tracking.
  /// Diagnostics — see [maxThrottledAddresses].
  int get throttledAddresses => _throttle.trackedAddresses;

  /// `true` when a guest completes the handshake, `false` when it goes away.
  /// Broadcast and non-buffering — subscribe before starting to wait.
  Stream<bool> get guestPresence => _presence.stream;

  /// Every frame from the AUTHENTICATED guest, after the rate limits, including
  /// each `hello` (the first one and every later resync).
  ///
  /// Broadcast and non-buffering: subscribe before the server can accept, or the
  /// handshake that arrives first will be missed.
  Stream<Envelope> get guestFrames => _frames.stream;

  /// Send one frame to the active guest. Returns false when there is nobody to
  /// send to (the frame is dropped — the guest resyncs on its next `hello`).
  bool send(Envelope message) {
    final c = _guest;
    if (c == null || _stopped) return false;
    _send(c, message);
    return true;
  }

  /// Close the current guest's connection, keeping the server (and the match)
  /// running. The guest's client will reconnect and resync.
  Future<void> disconnectGuest([String reason = 'disconnected']) async {
    final c = _guest;
    if (c == null) return;
    await _close(c, WebSocketStatus.normalClosure, reason);
  }

  /// Stop serving and close every connection. Does NOT close the [MatchRelay] or
  /// the transport built over this server — their owner does that (see
  /// `SocketTransport.host`). Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final open = <_GuestConnection>[
      if (_guest != null) _guest!,
      ..._pending,
    ];
    for (final c in open) {
      await _close(c, WebSocketStatus.goingAway, 'host stopped');
    }
    await _server.close(force: true);
    await _presence.close();
    await _frames.close();
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
          _publish(envelope);
          return;
        }
        if (envelope is PingMessage) {
          if (!c.allowFrame(now, timings.frameMinInterval, timings.frameBurst)) return;
          _send(c, const PongMessage());
          return;
        }
        if (envelope is PongMessage) return; // liveness only, already recorded
        if (!c.allowFrame(now, timings.frameMinInterval, timings.frameBurst)) return;
        _publish(envelope);
      case DecodeFailure(:final error):
        if (error.kind == ProtocolErrorKind.unknownType) return;
        if (!c.allowFrame(now, timings.frameMinInterval, timings.frameBurst)) return;
        // A bounded refusal, carrying our seq so a guest that has drifted can
        // tell the difference between "you are behind" and "that frame was
        // nonsense".
        _send(c, RejectMessage(reason: error.message, lastSeq: _lastSeq()));
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
    // Kept for a transport that does not exist yet — see [guestHello].
    c.hello = hello;
    c.handshakeTimer?.cancel();
    c.handshakeTimer = null;
    c.markHello(DateTime.now());
    c.heartbeat = Timer.periodic(timings.heartbeatInterval, (_) => _beat(c));
    if (!_presence.isClosed) _presence.add(true);
    _publish(hello);
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

  void _publish(Envelope message) {
    if (!_frames.isClosed) _frames.add(message);
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

  /// The `hello` that claimed the playing slot — see [HostServer.guestHello].
  HelloMessage? hello;
  DateTime lastActivity;
  DateTime? _lastHello;

  /// When the frame bucket last paid out, less any unspent remainder — see
  /// [allowFrame].
  DateTime? _lastFrame;

  /// Frames the bucket can pay out right now.
  int _tokens = 0;
  Timer? handshakeTimer;
  Timer? heartbeat;

  void markHello(DateTime at) => _lastHello = at;

  bool allowHello(DateTime now, Duration min) {
    final last = _lastHello;
    if (last != null && now.difference(last) < min) return false;
    _lastHello = now;
    return true;
  }

  /// The frame limiter: a TOKEN BUCKET, not a minimum spacing.
  ///
  /// The average it enforces is the same one [LanTimings.frameMinInterval] always
  /// named — one frame per interval — but it lets a short burst through, and that
  /// difference is a correctness requirement rather than a kindness.
  ///
  /// A minimum spacing is unsatisfiable by an honest peer over a real link. The
  /// guest paces its sends to 1.25x this interval plus 2ms (see
  /// `GuestClient._sendSpacing`), which on the production 50ms is about 15ms of
  /// margin; a WiFi retransmit or a power-save wakeup delays one frame by more
  /// than that routinely, and the frame BEHIND it then arrives inside the window
  /// through no fault of the sender. Dropping it — silently, with nothing to
  /// replay it — cost the guest a whole [LanTimings.writeTimeout] before its
  /// controller could even retry.
  ///
  /// That landed on exactly one thing: a roll the GUEST owns is the only burst in
  /// the protocol (`createRoll`, then `reveal`, then the `RollEvent`), which is
  /// why the symptom was "each time the joiner rolls the dice" and never a move
  /// or a host roll, both of which are single frames.
  ///
  /// [burst] is the bucket's capacity, sized to cover that burst with room to
  /// spare. Sustained spam is still capped at one frame per [min] — a peer cannot
  /// buy more than [burst] frames of head start, ever — so the amplification
  /// bound the policy rests on is unchanged.
  bool allowFrame(DateTime now, Duration min, int burst) {
    final last = _lastFrame;
    if (last == null) {
      _tokens = burst - 1;
      _lastFrame = now;
      return true;
    }
    if (min > Duration.zero) {
      final earned = now.difference(last).inMicroseconds ~/ min.inMicroseconds;
      if (earned > 0) {
        _tokens = (_tokens + earned).clamp(0, burst);
        // Credit only the whole intervals actually spent, so the remainder is
        // carried rather than repeatedly rounded away (which would let a fast
        // enough caller earn a token per frame at any rate).
        _lastFrame = last.add(min * earned);
      }
    } else {
      _tokens = burst;
    }
    if (_tokens <= 0) return false;
    _tokens--;
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
