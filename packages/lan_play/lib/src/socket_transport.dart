import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/match_transport.dart';

import 'guest_client.dart';
import 'host_server.dart';
import 'lan_timings.dart';
import 'match_relay.dart';
import 'protocol.dart';

/// The LAN [MatchTransport]: two devices on one Wi-Fi, one WebSocket, no server
/// and no referee.
///
/// ## The two ends
///
/// [SocketTransport.host] is the peer that BOUND the socket. Its writes go
/// straight into the in-process [MatchRelay] — there is no loop back through a
/// socket to itself — and the relay's committed frames are published on
/// [inbound] and forwarded to the guest in one step. It answers the guest's
/// `hello` with the whole log, which is why it must keep that log: it is the only
/// resync source either peer has.
///
/// [SocketTransport.guest] is the peer that CONNECTED. It mirrors the log and the
/// roll documents locally as frames arrive (replacing the mirror wholesale on
/// every `welcome`), so [eventsSince]/[fetchRoll]/[rollsSince] are answered
/// without a round trip and are exact by construction. Its writes are optimistic
/// and correlated: each carries an id and resolves only when the relay's `ack`
/// quotes it back — which is what makes `await sendEvent(...)` mean COMMITTED,
/// per the transport contract.
///
/// ## Seats
///
/// The host plays [TransportSession.hostSide] (white) and the joiner plays black,
/// fixed for the match's life and identical to the online convention. Author
/// identity is not negotiated either: [MatchRelay.hostAuthor] /
/// [MatchRelay.guestAuthor] are constants the relay stamps from the connection a
/// write arrived on, so neither peer can author an event as the other and the
/// controllers' author↔seat validation is trustworthy.
///
/// ## Capabilities: nothing survives the socket
///
/// `durable: false, rejoinable: false`. A LAN match lives in the host's process,
/// so it cannot be re-opened after a restart, and a peer that drops does not
/// "rejoin the same live match" the way a Firestore peer does — it reconnects and
/// is handed the whole log, which the transport surfaces as a [ResetFrame]
/// (replay from scratch) rather than as the controller's durable-rejoin path.
///
/// ## Ownership: the transport does NOT own the link
///
/// [dispose] releases this transport's own streams and subscriptions and NOTHING
/// else. The [HostServer]/[MatchRelay] on one side and the [GuestClient] on the
/// other outlive it by design — the host's server is bound (and showing a room
/// code) before any match exists, and the guest's client is connecting before the
/// board opens. Their owner is whoever built them (the "Play Nearby" screen, or a
/// test fixture), and the controller owns only the transport. See
/// `app/lib/lan/lan_transport.dart`, which documents the whole chain.
abstract class SocketTransport implements MatchTransport {
  /// The bound peer's end: writes land in [relay], and every committed frame is
  /// relayed to whichever guest is attached to [server].
  ///
  /// Neither [server] nor [relay] is closed by [dispose].
  factory SocketTransport.host({
    required HostServer server,
    required MatchRelay relay,
  }) = _HostSocketTransport;

  /// The joining peer's end, over an already-connecting [client]. [connect]
  /// awaits the handshake.
  ///
  /// [client] is not disposed by [dispose].
  factory SocketTransport.guest({required GuestClient client}) =
      _GuestSocketTransport;
}

// ---------------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------------

class _HostSocketTransport implements SocketTransport {
  _HostSocketTransport({required this.server, required this.relay}) {
    // Subscribed in the CONSTRUCTOR, not in [connect]: both streams are
    // broadcast and non-buffering, and a guest can present its code (and start
    // writing) the instant the server is bound.
    _committed = relay.committed.listen(_onCommitted);
    _frames = server.guestFrames.listen(_onGuestFrame);
    _presenceSub = server.guestPresence.listen(_onPresence);
    _opponentPresent = server.hasGuest;
  }

  /// The bound socket. NOT owned: [dispose] leaves it serving.
  final HostServer server;

  /// The log and roll documents. NOT owned: [dispose] leaves it open.
  final MatchRelay relay;

  final _inbound = StreamController<InboundFrame>.broadcast();
  final _status = StreamController<TransportStatusEvent>.broadcast();
  final _presence = StreamController<bool>.broadcast();

  late final StreamSubscription<InboundFrame> _committed;
  late final StreamSubscription<Envelope> _frames;
  late final StreamSubscription<bool> _presenceSub;

  TransportStatus _statusValue = TransportStatus.connecting;
  bool _opponentPresent = false;
  bool _connected = false;
  bool _disposed = false;

  // --- MatchTransport --------------------------------------------------------

  @override
  Future<TransportSession> connect() async {
    if (_disposed) {
      throw const TransportUnavailable('disposed', 'transport disposed');
    }
    if (!_connected) {
      _connected = true;
      _setStatus(TransportStatus.connected);
    }
    return TransportSession(
      assignedSide: TransportSession.hostSide,
      config: relay.config,
      localAuthor: MatchRelay.hostAuthor,
      hostAuthor: MatchRelay.hostAuthor,
      // Known from the start even though nobody has joined yet: the seat ids are
      // constants, so the seat mapping is a fact about the protocol rather than
      // about who happens to be attached. [opponentPresent] is what says whether
      // anyone is there.
      guestAuthor: MatchRelay.guestAuthor,
      matchCode: server.roomCode,
      resumeToken: relay.resumeToken,
    );
  }

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Future<void> sendEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) async {
    _ensureLive();
    relay.appendEvent(
        author: MatchRelay.hostAuthor, seq: seq, gameNo: gameNo, event: event);
  }

  @override
  Future<void> createRoll(int n, String commit) async {
    _ensureLive();
    relay.createRoll(author: MatchRelay.hostAuthor, n: n, commit: commit);
  }

  @override
  Future<void> sendEntropy(int n, String entropy) async {
    _ensureLive();
    relay.addEntropy(author: MatchRelay.hostAuthor, n: n, entropy: entropy);
  }

  @override
  Future<void> sendReveal(int n, String reveal) async {
    _ensureLive();
    relay.addReveal(author: MatchRelay.hostAuthor, n: n, reveal: reveal);
  }

  @override
  Future<List<EventFrame>> eventsSince(int afterSeq) async {
    _ensureLive();
    return relay.eventsSince(afterSeq);
  }

  @override
  Future<RollFrame?> fetchRoll(int n) async {
    _ensureLive();
    return relay.roll(n);
  }

  @override
  Future<List<RollFrame>> rollsSince(int from) async {
    _ensureLive();
    return relay.rollsFrom(from);
  }

  @override
  Future<void> complete() async {
    // Bookkeeping only: the log is the authority, and it lives here.
  }

  @override
  Stream<TransportStatusEvent> get statusStream => _status.stream;

  @override
  TransportStatus get status => _statusValue;

  /// Always null: the bound peer's own link cannot be down — it IS the link. A
  /// guest that has left shows up in [opponentPresent], not here.
  @override
  String? get statusReason => null;

  @override
  bool get opponentPresent => _opponentPresent;

  @override
  Stream<bool> get opponentPresence => _presence.stream;

  @override
  Capabilities get capabilities =>
      const Capabilities(durable: false, rejoinable: false);

  /// Zero: frames are PUSHED the moment they are written. (The controller floors
  /// its own self-healing retries at 200ms, so a zero here means "as fast as the
  /// controller is willing to go", not a spin.)
  @override
  Duration get inboundCadence => Duration.zero;

  @override
  void setPaceHint({required bool fast}) {
    // A socket has one speed.
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _committed.cancel();
    await _frames.cancel();
    await _presenceSub.cancel();
    await _inbound.close();
    await _status.close();
    await _presence.close();
  }

  // --- internals -------------------------------------------------------------

  void _ensureLive() {
    if (_disposed) {
      throw const TransportUnavailable('disposed', 'transport disposed');
    }
    if (!_connected) {
      throw const TransportUnavailable('not-connected', 'connect() first');
    }
  }

  /// One committed frame: published to our own controller AND relayed to the
  /// guest. The two peers therefore see the same frame from the same act of
  /// committing, which is what keeps their folds in step.
  void _onCommitted(InboundFrame frame) {
    if (_disposed) return;
    if (!_inbound.isClosed) _inbound.add(frame);
    switch (frame) {
      case EventFrame():
        server.send(EventMessage(frame));
      case RollFrame():
        server.send(RollMessage(frame));
      case ResetFrame():
        break; // the relay never emits one
    }
  }

  void _onGuestFrame(Envelope message) {
    if (_disposed) return;
    switch (message) {
      case HelloMessage():
        // A join, a rejoin or a plain resync — all answered the same way, with
        // everything the relay holds.
        server.send(relay.welcome());
        // And OUR fold re-primes too: a guest that (re)connects may have written
        // while we were not looking at it, and a replay from our own log is free.
        _emitReset('the other player joined');
      case WriteEventMessage(:final id, :final seq, :final gameNo, :final event):
        _ack(id, () => relay.appendEvent(
              author: MatchRelay.guestAuthor,
              seq: seq,
              gameNo: gameNo,
              event: event,
            ));
      case WriteRollMessage(:final id, :final n, :final commit):
        _ack(id, () => relay.createRoll(
            author: MatchRelay.guestAuthor, n: n, commit: commit));
      case WriteEntropyMessage(:final id, :final n, :final entropy):
        _ack(id, () => relay.addEntropy(
            author: MatchRelay.guestAuthor, n: n, entropy: entropy));
      case WriteRevealMessage(:final id, :final n, :final reveal):
        _ack(id, () => relay.addReveal(
            author: MatchRelay.guestAuthor, n: n, reveal: reveal));
      // Relay-authored frames are never accepted FROM a guest: one that sends
      // them is buggy or probing, and must never move the log.
      case WelcomeMessage():
      case EventMessage():
      case RollMessage():
      case AckMessage():
      case RejectMessage():
      case BusyMessage():
      case PingMessage():
      case PongMessage():
        server.send(RejectMessage(
          reason: 'relay-only message type: ${message.type}',
          lastSeq: relay.lastSeq,
        ));
    }
  }

  /// Run one guest write and answer it. Every failure mode maps onto an
  /// [AckStatus] the guest turns back into the matching typed error.
  void _ack(int id, void Function() write) {
    AckStatus status;
    String? reason;
    try {
      write();
      status = AckStatus.ok;
    } on TransportContested catch (e) {
      status = AckStatus.contested;
      reason = e.message;
    } on TransportRejected catch (e) {
      status = AckStatus.rejected;
      reason = e.message;
    } catch (e) {
      status = AckStatus.unavailable;
      reason = '$e';
    }
    server.send(AckMessage(
      id: id,
      status: status,
      reason: reason,
      lastSeq: relay.lastSeq,
    ));
  }

  void _onPresence(bool present) {
    if (_disposed || _opponentPresent == present) return;
    _opponentPresent = present;
    if (!_presence.isClosed) _presence.add(present);
  }

  void _emitReset(String reason) {
    if (_disposed || _inbound.isClosed) return;
    _inbound.add(ResetFrame(resumeToken: relay.resumeToken, reason: reason));
  }

  void _setStatus(TransportStatus status) {
    if (_disposed) return;
    _statusValue = status;
    if (!_status.isClosed) _status.add(TransportStatusEvent(status));
  }
}

// ---------------------------------------------------------------------------
// Guest
// ---------------------------------------------------------------------------

class _GuestSocketTransport implements SocketTransport {
  _GuestSocketTransport({required this.client}) {
    // Subscribed in the CONSTRUCTOR: the welcome (and the frames the relay sends
    // in the same tick) arrive before anyone can await [connect].
    _frames = client.inbound.listen(_onFrame);
    _states = client.states.listen(_onState);
    _statusValue = _map(client.state.status);
    _statusReason = client.state.reason;
    // A client that was welcomed BEFORE this view existed (the "Play Nearby"
    // screen connects first and opens the board second) already holds the log it
    // was handed; adopt it rather than starting from an empty mirror.
    final welcomed = client.lastWelcome;
    if (welcomed != null) _adopt(welcomed);
  }

  /// The link. NOT owned: [dispose] leaves it connected (see the class doc).
  final GuestClient client;

  final _inbound = StreamController<InboundFrame>.broadcast();
  final _status = StreamController<TransportStatusEvent>.broadcast();
  final _presence = StreamController<bool>.broadcast();

  late final StreamSubscription<Envelope> _frames;
  late final StreamSubscription<GuestConnectionState> _states;

  /// The mirror: the relay's log as we have seen it, contiguous from 1 by
  /// construction (a welcome replaces it wholesale; a live event extends it only
  /// when it is the very next seq — anything else means we missed one and asks
  /// for the whole log again, see [_resyncSoon]).
  final List<EventFrame> _events = [];
  final Map<int, RollFrame> _rolls = {};

  final Map<int, Completer<AckMessage>> _pendingWrites = {};
  int _writeId = 0;

  TransportSession? _session;
  TransportStatus _statusValue = TransportStatus.connecting;
  String? _statusReason;
  bool _opponentPresent = false;
  bool _disposed = false;

  /// A gap (or a refusal quoting a seq ahead of ours) is outstanding and the
  /// `hello` that cures it has not been answered yet.
  bool _needResync = false;
  Timer? _resyncTimer;

  LanTimings get _timings => client.timings;

  // --- MatchTransport --------------------------------------------------------

  @override
  Future<TransportSession> connect() async {
    if (_disposed) {
      throw const TransportUnavailable('disposed', 'transport disposed');
    }
    final existing = _session;
    if (existing != null) return existing;
    final WelcomeMessage welcome;
    try {
      welcome = await client.welcome;
    } on GuestHandshakeException catch (e) {
      // Terminal by definition — the client has stopped retrying.
      throw TransportRejected('handshake', e.reason);
    }
    if (_disposed) {
      throw const TransportUnavailable('disposed', 'transport disposed');
    }
    return _session = TransportSession(
      assignedSide: welcome.side,
      config: welcome.config,
      localAuthor: MatchRelay.guestAuthor,
      hostAuthor: MatchRelay.hostAuthor,
      guestAuthor: MatchRelay.guestAuthor,
      matchCode: client.roomCode,
      // Carried even though the transport is not durable: it is the MATCH
      // IDENTITY, and a host that restarted mints a new one. The controller
      // compares it on every ResetFrame and voids its per-match watermarks when
      // it changes, so a second match is never written into the first one's row.
      resumeToken: welcome.resume,
    );
  }

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Future<void> sendEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) =>
      _write((id) => WriteEventMessage(
          id: id, seq: seq, gameNo: gameNo, event: event));

  @override
  Future<void> createRoll(int n, String commit) =>
      _write((id) => WriteRollMessage(id: id, n: n, commit: commit));

  @override
  Future<void> sendEntropy(int n, String entropy) =>
      _write((id) => WriteEntropyMessage(id: id, n: n, entropy: entropy));

  @override
  Future<void> sendReveal(int n, String reveal) =>
      _write((id) => WriteRevealMessage(id: id, n: n, reveal: reveal));

  @override
  Future<List<EventFrame>> eventsSince(int afterSeq) async {
    _ensureLive();
    return [for (final e in _events) if (e.seq > afterSeq) e];
  }

  @override
  Future<RollFrame?> fetchRoll(int n) async {
    _ensureLive();
    return _rolls[n];
  }

  @override
  Future<List<RollFrame>> rollsSince(int from) async {
    _ensureLive();
    final ns = _rolls.keys.where((n) => n >= from).toList()..sort();
    return [for (final n in ns) _rolls[n]!];
  }

  @override
  Future<void> complete() async {
    // The relay's log decides the match; a guest has no bookkeeping to do.
  }

  @override
  Stream<TransportStatusEvent> get statusStream => _status.stream;

  @override
  TransportStatus get status => _statusValue;

  @override
  String? get statusReason => _statusReason;

  /// True from the moment we are welcomed until the link goes away again: a
  /// welcome PROVES the host is there, and losing the link is the only way to
  /// stop knowing that.
  @override
  bool get opponentPresent => _opponentPresent;

  @override
  Stream<bool> get opponentPresence => _presence.stream;

  @override
  Capabilities get capabilities =>
      const Capabilities(durable: false, rejoinable: false);

  /// Zero: frames are pushed. See the host end's note.
  @override
  Duration get inboundCadence => Duration.zero;

  @override
  void setPaceHint({required bool fast}) {
    // A socket has one speed.
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _failPending('the transport was disposed');
    await _frames.cancel();
    await _states.cancel();
    await _inbound.close();
    await _status.close();
    await _presence.close();
  }

  // --- writes ----------------------------------------------------------------

  /// One optimistic write: queue it, wait for the relay's `ack`, and turn that
  /// into the contract's typed answer.
  ///
  /// The deadline is [LanTimings.writeTimeout], and it matters: the relay DROPS a
  /// frame that arrives inside its rate limit (silently, by design), so "no
  /// answer" is a real outcome and not merely a slow one. It surfaces as
  /// [TransportUnavailable] — may or may not have landed — which the controller
  /// cures with a resync and a retry.
  Future<void> _write(WriteMessage Function(int id) build) async {
    _ensureLive();
    final id = ++_writeId;
    final completer = Completer<AckMessage>();
    _pendingWrites[id] = completer;
    if (!client.send(build(id))) {
      _pendingWrites.remove(id);
      throw const TransportUnavailable(
          'offline', 'the link to the other player is down');
    }
    final AckMessage ack;
    try {
      ack = await completer.future.timeout(_timings.writeTimeout);
    } on TimeoutException {
      throw const TransportUnavailable(
          'no-ack', 'the other device did not acknowledge the write');
    } finally {
      _pendingWrites.remove(id);
    }
    switch (ack.status) {
      case AckStatus.ok:
        return;
      case AckStatus.contested:
        throw TransportContested('contested', ack.reason ?? 'index taken',
            peerLastSeq: ack.lastSeq);
      case AckStatus.rejected:
        throw TransportRejected('rejected', ack.reason ?? 'refused',
            peerLastSeq: ack.lastSeq);
      case AckStatus.unavailable:
        throw TransportUnavailable('unavailable', ack.reason ?? 'write failed');
    }
  }

  void _failPending(String why) {
    if (_pendingWrites.isEmpty) return;
    final waiting = List<Completer<AckMessage>>.from(_pendingWrites.values);
    _pendingWrites.clear();
    for (final c in waiting) {
      if (!c.isCompleted) {
        c.completeError(TransportUnavailable('link-lost', why));
      }
    }
  }

  // --- inbound ---------------------------------------------------------------

  void _onFrame(Envelope message) {
    if (_disposed) return;
    switch (message) {
      case WelcomeMessage():
        _onWelcome(message);
      case EventMessage(:final entry):
        _onEvent(entry);
      case RollMessage(:final roll):
        _rolls[roll.n] = roll;
        _publish(roll);
      case AckMessage():
        final waiting = _pendingWrites.remove(message.id);
        if (waiting != null && !waiting.isCompleted) waiting.complete(message);
      case RejectMessage(:final reason, :final lastSeq):
        // Post-welcome, a reject is about a frame we sent, not about the
        // handshake (the client fails terminally on those before we see them).
        _publishError(TransportUnavailable('rejected', reason));
        if (lastSeq > _lastSeq) _resyncSoon();
      case HelloMessage():
      case WriteEventMessage():
      case WriteRollMessage():
      case WriteEntropyMessage():
      case WriteRevealMessage():
      case BusyMessage():
      case PingMessage():
      case PongMessage():
        break; // not ours to act on (the client handles liveness and busy)
    }
  }

  /// A welcome is the WHOLE truth: adopt it and tell the controller to replay.
  void _onWelcome(WelcomeMessage welcome) {
    _adopt(welcome);
    _publish(ResetFrame(
      resumeToken: welcome.resume,
      reason: 'the match log was replayed',
    ));
  }

  /// Replace the mirror with what a welcome carries, and stand the resync loop
  /// down.
  void _adopt(WelcomeMessage welcome) {
    _needResync = false;
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _events
      ..clear()
      ..addAll(welcome.log);
    _rolls
      ..clear()
      ..addEntries(welcome.rolls.map((r) => MapEntry(r.n, r)));
    _setOpponentPresent(true);
  }

  void _onEvent(EventFrame entry) {
    if (entry.seq == _lastSeq + 1) {
      _events.add(entry);
      _publish(entry);
      return;
    }
    if (entry.seq <= _lastSeq) {
      // A duplicate (at-least-once delivery); harmless to republish.
      _publish(entry);
      return;
    }
    // A GAP: our mirror would stop being contiguous, and [eventsSince] would
    // then answer with a hole in it — which the contract forbids. Nothing
    // incremental can close it, so ask for the whole log instead and do NOT
    // publish the orphan.
    _resyncSoon();
  }

  /// Ask the relay to replay everything, and keep asking until it does.
  ///
  /// One `hello` is not guaranteed to be answered: the relay spaces them at
  /// [LanTimings.helloMinInterval] and DROPS the excess, so a resync that lands
  /// inside that window would otherwise leave the mirror short for good.
  void _resyncSoon() {
    if (_disposed) return;
    _needResync = true;
    client.resync();
    if (_resyncTimer != null) return;
    _resyncTimer = Timer.periodic(_timings.helloMinInterval, (t) {
      if (_disposed || !_needResync || client.isDisposed) {
        t.cancel();
        _resyncTimer = null;
        return;
      }
      client.resync();
    });
  }

  int get _lastSeq => _events.isEmpty ? 0 : _events.last.seq;

  void _onState(GuestConnectionState state) {
    if (_disposed) return;
    _statusValue = _map(state.status);
    _statusReason = state.reason;
    if (state.status != GuestConnectionStatus.connected) {
      // Nothing can answer a write over a link that is not there.
      _failPending(state.reason ?? 'the link went away');
      _setOpponentPresent(false);
    }
    if (!_status.isClosed) {
      _status.add(TransportStatusEvent(_statusValue, state.reason));
    }
  }

  static TransportStatus _map(GuestConnectionStatus status) => switch (status) {
        GuestConnectionStatus.connecting => TransportStatus.connecting,
        GuestConnectionStatus.connected => TransportStatus.connected,
        GuestConnectionStatus.reconnecting => TransportStatus.reconnecting,
        GuestConnectionStatus.busy => TransportStatus.busy,
        GuestConnectionStatus.failed => TransportStatus.failed,
      };

  void _setOpponentPresent(bool present) {
    if (_disposed || _opponentPresent == present) return;
    _opponentPresent = present;
    if (!_presence.isClosed) _presence.add(present);
  }

  void _publish(InboundFrame frame) {
    if (_disposed || _inbound.isClosed) return;
    _inbound.add(frame);
  }

  /// A transient fault on the stream, WITHOUT closing it — per the contract, a
  /// transport never ends `inbound` to signal trouble.
  void _publishError(TransportException error) {
    if (_disposed || _inbound.isClosed) return;
    _inbound.addError(error);
  }

  void _ensureLive() {
    if (_disposed) {
      throw const TransportUnavailable('disposed', 'transport disposed');
    }
  }
}
