import 'dart:async';
import 'dart:io';

import 'host_server.dart' show matchPath;
import 'lan_timings.dart';
import 'protocol.dart';

/// Where a [GuestClient] is in its connection lifecycle.
enum GuestConnectionStatus {
  /// The first connection attempt is in flight.
  connecting,

  /// Connected AND welcomed — the match stream is live.
  connected,

  /// The link dropped; a retry is scheduled (see [LanTimings.reconnectMinDelay]).
  reconnecting,

  /// The host is playing someone else. Distinct from [reconnecting] because the
  /// link is FINE — the room is occupied — and distinct from [failed] because
  /// it very often clears on its own: a host whose previous guest dropped
  /// without a FIN answers busy until it reaps the half-open socket. Retried on
  /// [LanTimings.busyRetryDelay].
  busy,

  /// Terminally failed. Retrying cannot help (wrong room code, protocol
  /// mismatch), so the client has stopped.
  failed,
}

/// A connection lifecycle transition, with the reason when there is one.
class GuestConnectionState {
  const GuestConnectionState(this.status, [this.reason]);

  const GuestConnectionState.connecting()
      : status = GuestConnectionStatus.connecting,
        reason = null;
  const GuestConnectionState.connected()
      : status = GuestConnectionStatus.connected,
        reason = null;
  const GuestConnectionState.reconnecting(String this.reason)
      : status = GuestConnectionStatus.reconnecting;
  const GuestConnectionState.busy(String this.reason)
      : status = GuestConnectionStatus.busy;
  const GuestConnectionState.failed(String this.reason)
      : status = GuestConnectionStatus.failed;

  final GuestConnectionStatus status;

  /// Why the link dropped or failed; null for the happy transitions.
  final String? reason;

  bool get isConnected => status == GuestConnectionStatus.connected;
  bool get isFailed => status == GuestConnectionStatus.failed;
  bool get isBusy => status == GuestConnectionStatus.busy;

  @override
  bool operator ==(Object other) =>
      other is GuestConnectionState &&
      other.status == status &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(status, reason);

  @override
  String toString() =>
      'GuestConnectionState(${status.name}${reason == null ? '' : ', $reason'})';
}

/// Thrown into [GuestClient.welcome] when the handshake cannot succeed.
class GuestHandshakeException implements Exception {
  const GuestHandshakeException(this.reason);

  final String reason;

  @override
  String toString() => 'GuestHandshakeException: $reason';
}

/// The guest device's end of the LAN link: one WebSocket to the relay's
/// `/match`, a `hello`/`welcome` handshake carrying the room code, and a raw
/// [Envelope] stream.
///
/// Deliberately game-blind, exactly like [HostServer] on the other end: it
/// carries frames, reconnects, paces and heartbeats. Turning frames into
/// transport semantics (a mirrored log, write acknowledgements, resync) is
/// `SocketTransport.guest`'s job.
///
/// ## Lifecycle
///
/// Construction starts connecting immediately and returns synchronously, so a
/// caller can subscribe to [inbound] and [states] before the first frame can
/// possibly arrive:
///
/// ```dart
/// final guest = GuestClient.connect('192.168.1.20', 47780,
///     roomCode: '0421', name: 'Bo');
/// guest.inbound.listen(transport.onFrame);
/// final welcome = await guest.welcome;   // side + config + log + rolls
/// ```
///
/// ## Reconnection
///
/// A dropped link (host restart, Wi-Fi blip, the host's own
/// `disconnectGuest`) is retried with exponential backoff from
/// [LanTimings.reconnectMinDelay] to [LanTimings.reconnectMaxDelay], forever,
/// until [dispose]. Each attempt re-sends `hello` (with the resume token from
/// the last welcome), and the host answers with a FRESH welcome carrying the
/// whole log — which is exactly the resync path. That second and later welcome
/// is delivered on [inbound] (the [welcome] future only ever reports the first
/// one), so the controller re-folds the authoritative log and any submission
/// lost in the drop is simply gone rather than half-applied.
///
/// Each attempt carries a GENERATION number, checked after every await. A
/// connect cannot be cancelled — `Future.timeout` abandons the wait but the
/// socket underneath still completes — so an attempt that has been superseded
/// discards and CLOSES whatever it eventually produces. An orphan left open
/// would connect to the host, and (before the host gated its slot on
/// authentication) squat it until the handshake timeout, so the retry that
/// replaced it would be answered with `busy`.
///
/// The HANDSHAKE has its own deadline on top of the connect's, because the two
/// fail differently: a connect that never lands raises, while a `hello` that is
/// never answered is perfectly quiet — and a host that has accepted the socket is
/// already sending heartbeats, so the liveness rule below never fires. Without
/// that deadline an unanswered handshake pinned this client in
/// [GuestConnectionStatus.connecting] for good. See [LanTimings.handshakeTimeout].
///
/// `busy` is NOT terminal: it is retried on [LanTimings.busyRetryDelay] and
/// surfaced as [GuestConnectionStatus.busy], because the commonest cause is a
/// host still holding a half-open socket from this very guest. Only a `reject`
/// before the handshake completes — wrong code, protocol mismatch — is
/// terminal, since retrying that just burns the host's brute-force quota.
///
/// ## Sending
///
/// Frames are PACED to just outside the host's [LanTimings.frameMinInterval],
/// because the host DROPS frames that arrive too fast. Two decisions taken in
/// the same instant (drop the cube, then roll) therefore both land instead of
/// the second vanishing silently.
class GuestClient {
  GuestClient._(this.host, this.port, this.roomCode, this.name, this.timings) {
    _backoff = timings.reconnectMinDelay;
    _state = const GuestConnectionState.connecting();
    // Keeps a completeError from ever surfacing as an unhandled async error
    // when the caller only watches [states]; other listeners still see it.
    _welcome.future.then<void>((_) {}, onError: (Object _) {});
    // The first attempt runs in a microtask so a caller can subscribe to
    // [inbound] and [states] before anything at all is emitted.
    scheduleMicrotask(_attempt);
  }

  /// Start connecting to `ws://host:port/match`. Returns immediately; await
  /// [welcome] for the handshake.
  factory GuestClient.connect(
    String host,
    int port, {
    required String roomCode,
    required String name,
    LanTimings timings = LanTimings.defaults,
  }) =>
      GuestClient._(host, port, roomCode, name, timings);

  final String host;
  final int port;

  /// The code the host is showing on its screen.
  final String roomCode;

  /// This guest's display name.
  final String name;

  final LanTimings timings;

  final _inbound = StreamController<Envelope>.broadcast();
  final _states = StreamController<GuestConnectionState>.broadcast();
  final _welcome = Completer<WelcomeMessage>();
  final List<String> _queue = [];

  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  Timer? _liveness;
  Timer? _handshake;
  Timer? _pacer;
  DateTime? _lastSendAt;
  DateTime _lastRx = DateTime.now();
  late Duration _backoff;
  late GuestConnectionState _state;
  WelcomeMessage? _lastWelcome;
  String? _resume;
  bool _welcomedThisConnection = false;
  bool _announced = false;
  bool _stopped = false;
  bool _disposed = false;

  /// Names the current connection attempt. Every callback and every resumption
  /// after an await checks it, so a superseded attempt can never install a
  /// socket, start a timer, or report a state.
  int _generation = 0;

  /// Every post-handshake frame from the relay: `event`s, `roll`s, `ack`s,
  /// `reject`s, and each `welcome` (including the first, and every resync welcome
  /// after a reconnect). `ping`/`pong` are handled internally and never surface.
  ///
  /// Broadcast and non-buffering: subscribe as soon as the client is built.
  Stream<Envelope> get inbound => _inbound.stream;

  /// Connection lifecycle transitions. Broadcast; [state] holds the current one.
  Stream<GuestConnectionState> get states => _states.stream;

  GuestConnectionState get state => _state;

  /// Completes with the FIRST welcome, or with a [GuestHandshakeException] on a
  /// terminal failure (wrong code, protocol mismatch). A busy room is NOT one
  /// of those: the future simply stays pending while the client waits it out.
  Future<WelcomeMessage> get welcome => _welcome.future;

  /// The most recent welcome, exactly as it ARRIVED.
  ///
  /// It goes stale the instant the next event lands: `SocketTransport.guest`
  /// keeps the live mirror (the log a late-attaching folder needs), because it is
  /// the layer that knows what a log entry means.
  WelcomeMessage? get lastWelcome => _lastWelcome;

  /// True while the link is up and welcomed.
  bool get isConnected => _state.isConnected;

  /// True once [dispose] has run: the link is gone for good and nothing on it
  /// will ever answer again. A view built over this client (see
  /// `SocketTransport.guest`) reads it to stop its own retry loops.
  bool get isDisposed => _disposed;

  /// Queue [message] for the relay. Returns false when there is no live socket
  /// (the frame is dropped — after a reconnect the fresh welcome resyncs, so a
  /// stale write must not be replayed).
  bool send(Envelope message) {
    if (_disposed || _socket == null) return false;
    _queue.add(message.encode());
    _flush();
    return true;
  }

  /// Ask the relay to replay the WHOLE log, by re-sending `hello` — the only
  /// frame that answers with a [WelcomeMessage]. That welcome arrives on
  /// [inbound] like any other, so a folding controller resyncs through exactly
  /// the path a reconnect uses.
  ///
  /// Returns false when there is no live socket; nothing is lost by that,
  /// because the reconnect's own `hello` will resync anyway. Spaced by the
  /// host's [LanTimings.helloMinInterval] — a caller that resyncs in a tight
  /// loop has its excess hellos dropped, not answered.
  bool resync() =>
      send(HelloMessage(name: name, code: roomCode, resume: _resume));

  /// Stop reconnecting and release everything. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopped = true;
    _generation++; // retires any connect still in flight
    _retry?.cancel();
    _pacer?.cancel();
    _liveness?.cancel();
    _handshake?.cancel();
    await _teardownSocket();
    if (!_welcome.isCompleted) {
      _welcome.completeError(const GuestHandshakeException('disposed'));
    }
    await _inbound.close();
    await _states.close();
  }

  // --- connecting ------------------------------------------------------------

  Future<void> _attempt() async {
    if (_disposed || _stopped) return;
    final gen = ++_generation;
    if (!_announced) {
      _announced = true;
      _emit(const GuestConnectionState.connecting());
    }
    // Never install a socket over a live one: the old one must be torn down
    // (timers cancelled, queue dropped) first, or its callbacks outlive it.
    await _teardownSocket();
    if (_stale(gen)) return;

    final uri = 'ws://${_hostForUri()}:$port$matchPath';
    final WebSocket socket;
    try {
      socket = await _openSocket(uri, gen);
    } on Object catch (e) {
      _onDropped('connect failed: $e', gen);
      return;
    }
    // The await above is an eternity in socket terms: dispose, a liveness drop
    // or a newer attempt may all have happened meanwhile.
    if (_stale(gen)) {
      _discard(socket);
      return;
    }
    _socket = socket;
    _welcomedThisConnection = false;
    _lastRx = DateTime.now();
    _lastSendAt = null;
    _queue.clear();
    _sub = socket.listen(
      (Object? data) => _onData(data, gen),
      onDone: () => _onDropped('connection closed', gen),
      onError: (Object e) => _onDropped('socket error: $e', gen),
      cancelOnError: true,
    );
    // The handshake: the only frame that carries the room code.
    _sendNow(HelloMessage(name: name, code: roomCode, resume: _resume).encode());
    // A DEADLINE ON THE HANDSHAKE ITSELF, not just on the connect.
    //
    // The liveness rule below cannot stand in for this one: it watches for
    // SILENCE, and an unanswered hello is not silent. A host that accepts the
    // socket and starts its heartbeat — but whose relay never answers, because the
    // transport that answers hellos did not exist when ours arrived — refreshes
    // [_lastRx] every [LanTimings.heartbeatInterval] forever. Without this timer
    // the client then stays in [GuestConnectionStatus.connecting] for good: no
    // welcome, no drop, no retry, and a joining device spinning on "Connecting…"
    // with nothing behind it. That was a real shipped hang, so the deadline is a
    // correctness requirement rather than a nicety. Dropping the link is the right
    // cure: the reconnect re-sends `hello`, which the host answers by then.
    _handshake = Timer(timings.handshakeTimeout, () {
      if (_stale(gen) || _welcomedThisConnection) return;
      _onDropped('the host did not answer the handshake', gen);
    });
    _liveness =
        Timer.periodic(timings.heartbeatInterval, (_) => _checkLiveness(gen));
  }

  /// Connect with a REAL deadline.
  ///
  /// `Future.timeout` only abandons the wait — the connect underneath keeps
  /// going and eventually hands over a live socket that nobody owns. On a
  /// stalled SYN (a host that is booting, or a manually typed IP that is only
  /// half-listening) that orphan reaches the host after the retry has already
  /// been scheduled, and the two race. So the late socket is caught here and
  /// closed.
  Future<WebSocket> _openSocket(String uri, int gen) {
    final result = Completer<WebSocket>();
    final deadline = Timer(timings.connectTimeout, () {
      if (!result.isCompleted) {
        result.completeError(
            TimeoutException('connect timed out', timings.connectTimeout));
      }
    });
    WebSocket.connect(uri).then((socket) {
      deadline.cancel();
      if (result.isCompleted || _stale(gen)) {
        _discard(socket); // too late to be useful, too dangerous to leave open
      } else {
        result.complete(socket);
      }
    }, onError: (Object e) {
      deadline.cancel();
      if (!result.isCompleted) result.completeError(e);
    });
    return result.future;
  }

  /// True once [gen] no longer names the attempt this client is pursuing.
  bool _stale(int gen) => _disposed || _stopped || gen != _generation;

  /// Close a socket we are not going to use, without waiting on it.
  void _discard(WebSocket socket) {
    unawaited(() async {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {
        // already gone
      }
    }());
  }

  /// Bracket a bare IPv6 literal so the URI parses.
  String _hostForUri() =>
      host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  void _checkLiveness(int gen) {
    if (_stale(gen) || _socket == null) return;
    if (DateTime.now().difference(_lastRx) > timings.silenceTimeout) {
      _onDropped('host silent', gen);
    }
  }

  void _onDropped(String reason, int gen) {
    if (_stale(gen)) return;
    // Bumping the generation here retires this attempt for good: a second
    // callback from the same dying socket, or a connect still in flight for it,
    // is now stale and cannot resurrect anything.
    _generation++;
    unawaited(_teardownSocket());
    _emit(GuestConnectionState.reconnecting(reason));
    _schedule(_backoff);
    _backoff = _backoff * 2 > timings.reconnectMaxDelay
        ? timings.reconnectMaxDelay
        : _backoff * 2;
  }

  /// The room is taken. Not a failure and not a broken link — wait longer, and
  /// say so distinctly, then try again.
  void _onBusy(int gen) {
    if (_stale(gen)) return;
    _generation++;
    unawaited(_teardownSocket());
    _emit(const GuestConnectionState.busy('the host is already playing'));
    _schedule(timings.busyRetryDelay);
  }

  void _schedule(Duration delay) {
    _retry?.cancel();
    _retry = Timer(delay, () => unawaited(_attempt()));
  }

  /// A failure retrying cannot fix.
  void _fail(String reason) {
    if (_disposed) return;
    _stopped = true;
    _generation++;
    _retry?.cancel();
    unawaited(_teardownSocket());
    _emit(GuestConnectionState.failed(reason));
    if (!_welcome.isCompleted) {
      _welcome.completeError(GuestHandshakeException(reason));
    }
  }

  Future<void> _teardownSocket() async {
    _liveness?.cancel();
    _liveness = null;
    _handshake?.cancel();
    _handshake = null;
    _pacer?.cancel();
    _pacer = null;
    _queue.clear();
    final sub = _sub;
    final socket = _socket;
    _sub = null;
    _socket = null;
    _welcomedThisConnection = false;
    if (sub != null) await sub.cancel();
    if (socket != null) {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {
        // already gone
      }
    }
  }

  // --- inbound ---------------------------------------------------------------

  void _onData(Object? data, int gen) {
    if (_stale(gen)) return;
    _lastRx = DateTime.now();
    if (data is! String || data.length > maxMessageLength) return;
    final result = Envelope.decode(data);
    if (result is! DecodeOk) return; // a frame we cannot read is not actionable
    final message = result.envelope;
    switch (message) {
      case PingMessage():
        send(const PongMessage());
      case PongMessage():
        break; // liveness only, already recorded
      case BusyMessage():
        _onBusy(gen);
      case WelcomeMessage():
        _onWelcome(message);
      case RejectMessage(:final reason):
        if (!_welcomedThisConnection) {
          // Before the welcome, a reject IS the handshake's answer.
          _fail(reason);
          return;
        }
        _publish(message);
      default:
        _publish(message);
    }
  }

  void _onWelcome(WelcomeMessage message) {
    _welcomedThisConnection = true;
    _handshake?.cancel();
    _handshake = null;
    _lastWelcome = message;
    _resume = message.resume;
    _backoff = timings.reconnectMinDelay;
    _emit(const GuestConnectionState.connected());
    if (!_welcome.isCompleted) _welcome.complete(message);
    _publish(message);
  }

  void _publish(Envelope message) {
    if (!_inbound.isClosed) _inbound.add(message);
  }

  void _emit(GuestConnectionState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  // --- paced sending ---------------------------------------------------------

  /// The spacing this client keeps: the host's minimum plus a margin, so
  /// clock skew and scheduling jitter cannot push a frame under the host's
  /// limiter (which drops, silently, by design).
  Duration get _sendSpacing => Duration(
      microseconds: (timings.frameMinInterval.inMicroseconds * 1.25).round() +
          2000);

  void _flush() {
    if (_disposed || _socket == null || _queue.isEmpty) return;
    final now = DateTime.now();
    final last = _lastSendAt;
    if (last != null) {
      final waited = now.difference(last);
      if (waited < _sendSpacing) {
        _pacer?.cancel();
        _pacer = Timer(_sendSpacing - waited, _flush);
        return;
      }
    }
    _sendNow(_queue.removeAt(0));
    if (_queue.isNotEmpty) {
      _pacer?.cancel();
      _pacer = Timer(_sendSpacing, _flush);
    }
  }

  void _sendNow(String frame) {
    final socket = _socket;
    if (socket == null) return;
    _lastSendAt = DateTime.now();
    try {
      socket.add(frame);
    } catch (_) {
      // Racing a close; onDone/onError will schedule the reconnect.
    }
  }
}
