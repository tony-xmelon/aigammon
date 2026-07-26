/// Every clock and every quota the LAN transport runs on, in one injectable
/// bag — so a test can compress a fifteen-second liveness rule into a fifth of
/// a second without any `fakeAsync` gymnastics around real sockets.
///
/// The defaults are the production values; [LanTimings.test] is the compressed
/// preset the socket tests use.
class LanTimings {
  const LanTimings({
    this.handshakeTimeout = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 5),
    this.silenceTimeout = const Duration(seconds: 15),
    this.helloMinInterval = const Duration(seconds: 1),
    this.frameMinInterval = const Duration(milliseconds: 50),
    this.connectTimeout = const Duration(seconds: 5),
    this.reconnectMinDelay = const Duration(milliseconds: 500),
    this.reconnectMaxDelay = const Duration(seconds: 8),
    this.throttleWindow = const Duration(seconds: 30),
    this.maxConnectionsPerWindow = 10,
    this.maxAuthFailuresPerWindow = 5,
  });

  /// Production values.
  static const LanTimings defaults = LanTimings();

  /// The compressed preset for tests: same shape, ~25x faster, so a whole
  /// heartbeat-drop or reconnect cycle fits comfortably inside a test.
  static const LanTimings test = LanTimings(
    handshakeTimeout: Duration(milliseconds: 300),
    heartbeatInterval: Duration(milliseconds: 40),
    silenceTimeout: Duration(milliseconds: 200),
    helloMinInterval: Duration(milliseconds: 200),
    frameMinInterval: Duration(milliseconds: 5),
    connectTimeout: Duration(seconds: 2),
    reconnectMinDelay: Duration(milliseconds: 20),
    reconnectMaxDelay: Duration(milliseconds: 80),
    throttleWindow: Duration(seconds: 5),
  );

  /// How long a fresh connection has to present a valid `hello` before the host
  /// closes it. Bounds how long an idle socket can hold the single guest slot.
  final Duration handshakeTimeout;

  /// How often the host pings an authenticated guest, and how often both ends
  /// re-check their peer's liveness.
  final Duration heartbeatInterval;

  /// How long a peer may say NOTHING (not even a pong) before the connection is
  /// considered dead and dropped. Detection granularity is
  /// [heartbeatInterval], so the effective drop lands in
  /// `[silenceTimeout, silenceTimeout + heartbeatInterval]`.
  final Duration silenceTimeout;

  /// Minimum spacing between two `hello`s on one connection. `hello` is the
  /// only frame that replays the WHOLE log, so it is the only amplification
  /// lever a peer has; excess hellos are dropped, not answered.
  final Duration helloMinInterval;

  /// Minimum spacing between two non-`hello` frames on one connection. Excess
  /// frames are dropped silently — a peer cannot make the host spend unbounded
  /// CPU by spinning submissions.
  final Duration frameMinInterval;

  /// Cap on how long a single WebSocket connect attempt may take.
  final Duration connectTimeout;

  /// First reconnect delay; doubles up to [reconnectMaxDelay].
  final Duration reconnectMinDelay;

  /// Ceiling on the reconnect backoff.
  final Duration reconnectMaxDelay;

  /// The sliding window the per-address quotas below are counted over.
  final Duration throttleWindow;

  /// How many connections one remote address may open per [throttleWindow].
  /// Because every `hello` replays the log, unlimited RECONNECTS would be an
  /// amplification lever that per-connection hello spacing cannot see.
  final int maxConnectionsPerWindow;

  /// How many wrong room codes one remote address may present per
  /// [throttleWindow] before it is refused before the WebSocket upgrade — the
  /// defence that makes a four-digit code adequate.
  final int maxAuthFailuresPerWindow;

  LanTimings copyWith({
    Duration? handshakeTimeout,
    Duration? heartbeatInterval,
    Duration? silenceTimeout,
    Duration? helloMinInterval,
    Duration? frameMinInterval,
    Duration? connectTimeout,
    Duration? reconnectMinDelay,
    Duration? reconnectMaxDelay,
    Duration? throttleWindow,
    int? maxConnectionsPerWindow,
    int? maxAuthFailuresPerWindow,
  }) =>
      LanTimings(
        handshakeTimeout: handshakeTimeout ?? this.handshakeTimeout,
        heartbeatInterval: heartbeatInterval ?? this.heartbeatInterval,
        silenceTimeout: silenceTimeout ?? this.silenceTimeout,
        helloMinInterval: helloMinInterval ?? this.helloMinInterval,
        frameMinInterval: frameMinInterval ?? this.frameMinInterval,
        connectTimeout: connectTimeout ?? this.connectTimeout,
        reconnectMinDelay: reconnectMinDelay ?? this.reconnectMinDelay,
        reconnectMaxDelay: reconnectMaxDelay ?? this.reconnectMaxDelay,
        throttleWindow: throttleWindow ?? this.throttleWindow,
        maxConnectionsPerWindow:
            maxConnectionsPerWindow ?? this.maxConnectionsPerWindow,
        maxAuthFailuresPerWindow:
            maxAuthFailuresPerWindow ?? this.maxAuthFailuresPerWindow,
      );
}
