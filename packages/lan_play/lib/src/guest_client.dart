import 'dart:async';
import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';

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

  /// Terminally failed. Retrying would be pointless (wrong room code, the room
  /// is busy, protocol mismatch), so the client has stopped.
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
  const GuestConnectionState.failed(String this.reason)
      : status = GuestConnectionStatus.failed;

  final GuestConnectionStatus status;

  /// Why the link dropped or failed; null for the happy transitions.
  final String? reason;

  bool get isConnected => status == GuestConnectionStatus.connected;
  bool get isFailed => status == GuestConnectionStatus.failed;

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

/// The guest device's end of the LAN link: one WebSocket to the host's
/// `/match`, a `hello`/`welcome` handshake carrying the room code, and an
/// [Envelope] stream a controller folds exactly like the Firestore stream.
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
/// guest.inbound.listen(controller.apply);
/// final welcome = await guest.welcome;   // side + config + log so far
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
/// Terminal failures — a `reject` before the handshake completes (wrong code,
/// version mismatch) or `busy` — stop the retry loop and land on
/// [GuestConnectionStatus.failed]: retrying a wrong code only burns the host's
/// brute-force quota.
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

  /// Every post-handshake frame from the host: `event`s, `reject`s, and each
  /// `welcome` (including the first, and every resync welcome after a
  /// reconnect). `ping`/`pong` are handled internally and never surface.
  ///
  /// Broadcast and non-buffering: subscribe as soon as the client is built.
  Stream<Envelope> get inbound => _inbound.stream;

  /// Connection lifecycle transitions. Broadcast; [state] holds the current one.
  Stream<GuestConnectionState> get states => _states.stream;

  GuestConnectionState get state => _state;

  /// Completes with the FIRST welcome, or with a [GuestHandshakeException] on a
  /// terminal failure (wrong code, busy room, version mismatch).
  Future<WelcomeMessage> get welcome => _welcome.future;

  /// The most recent welcome — the current authoritative log snapshot.
  WelcomeMessage? get lastWelcome => _lastWelcome;

  /// The side this guest plays, once welcomed.
  Player? get side => _lastWelcome?.side;

  /// True while the link is up and welcomed.
  bool get isConnected => _state.isConnected;

  /// Queue [message] for the host. Returns false when there is no live socket
  /// (the frame is dropped — after a reconnect the fresh welcome resyncs, so a
  /// stale submission must not be replayed).
  bool send(Envelope message) {
    if (_disposed || _socket == null) return false;
    _queue.add(message.encode());
    _flush();
    return true;
  }

  /// Submit an event for this guest's own side.
  bool submit(GameEvent event) => send(SubmitMessage(event));

  /// Ask the host (which owns the dice) to roll for this guest.
  bool requestRoll() => send(const RollRequestMessage());

  /// Stop reconnecting and release everything. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopped = true;
    _retry?.cancel();
    _pacer?.cancel();
    _liveness?.cancel();
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
    if (!_announced) {
      _announced = true;
      _emit(const GuestConnectionState.connecting());
    }
    final uri = 'ws://${_hostForUri()}:$port$matchPath';
    try {
      final socket =
          await WebSocket.connect(uri).timeout(timings.connectTimeout);
      if (_disposed || _stopped) {
        try {
          await socket.close(WebSocketStatus.normalClosure);
        } catch (_) {
          // already gone
        }
        return;
      }
      _socket = socket;
      _welcomedThisConnection = false;
      _lastRx = DateTime.now();
      _lastSendAt = null;
      _queue.clear();
      _sub = socket.listen(
        _onData,
        onDone: () => _onDropped('connection closed'),
        onError: (Object e) => _onDropped('socket error: $e'),
        cancelOnError: true,
      );
      // The handshake: the only frame that carries the room code.
      _sendNow(
        HelloMessage(name: name, code: roomCode, resume: _resume).encode(),
      );
      _liveness =
          Timer.periodic(timings.heartbeatInterval, (_) => _checkLiveness());
    } on Object catch (e) {
      _onDropped('connect failed: $e');
    }
  }

  /// Bracket a bare IPv6 literal so the URI parses.
  String _hostForUri() =>
      host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  void _checkLiveness() {
    if (_socket == null) return;
    if (DateTime.now().difference(_lastRx) > timings.silenceTimeout) {
      _onDropped('host silent');
    }
  }

  void _onDropped(String reason) {
    if (_disposed || _stopped) return;
    unawaited(_teardownSocket());
    _emit(GuestConnectionState.reconnecting(reason));
    _retry?.cancel();
    _retry = Timer(_backoff, () {
      _backoff = _backoff * 2 > timings.reconnectMaxDelay
          ? timings.reconnectMaxDelay
          : _backoff * 2;
      unawaited(_attempt());
    });
  }

  /// A failure retrying cannot fix.
  void _fail(String reason) {
    if (_disposed) return;
    _stopped = true;
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

  void _onData(Object? data) {
    if (_disposed) return;
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
        _fail('the host is already playing another guest');
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
