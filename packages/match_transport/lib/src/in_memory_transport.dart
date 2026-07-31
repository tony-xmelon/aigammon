/// An in-process [MatchTransport] pair for driving two controllers against each
/// other with scripted dice — the merged best of the shipped
/// `fake_online_backend` (a modelled store two API views share) and `lan_harness`
/// (a real two-endpoint rig with scripted-secret helpers).
///
/// A single [InMemoryBackend] holds the canonical log and roll documents; two
/// [InMemoryTransport] endpoints (host + guest) attach to it and carry frames
/// BOTH ways, so a test can run the unified controller from either seat exactly
/// as two devices would. Delivery is configurable — immediate (a microtask, for
/// plain `test()` cases) or manual-pump (for fake-clock widget tests and for
/// asserting ordering precisely). [Capabilities.durable]/`rejoinable` default to
/// true so the durable-rejoin path can be exercised.
library;

import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';

import 'fair_dice.dart';
import 'match_transport.dart';
import 'scripted_dice.dart';
import 'transport_channels.dart';

/// A mutable roll document inside the [InMemoryBackend].
class _Roll {
  _Roll({required this.n, required this.roller, required this.commit});

  final int n;
  final String roller;
  final String commit;
  String? entropy;
  String? reveal;

  FairDicePhase get phase {
    if (reveal != null) return FairDicePhase.revealed;
    if (entropy != null) return FairDicePhase.entropy;
    return FairDicePhase.committed;
  }

  RollFrame toFrame() => RollFrame(
      n: n, roller: roller, commit: commit, entropy: entropy, reveal: reveal);
}

/// The shared store both [InMemoryTransport] endpoints read and write.
///
/// Enforces exactly what the real backends enforce and no more: write-once
/// document ids (the [TransportContested] a create loses) and the write-once
/// roll phases (the [TransportRejected] a bad phase write earns). Everything
/// else — turn legality, dice fairness — is the controller's job, which is the
/// point of testing against it.
class InMemoryBackend {
  InMemoryBackend({
    this.config = const MatchConfig(length: 1),
    this.hostAuthor = 'host',
    this.guestAuthor = 'guest',
    this.matchCode = 'INMEM',
    this.resumeToken = 'INMEM-TOKEN',
    this.capabilities = const Capabilities(durable: true, rejoinable: true),
    this.deliverImmediately = true,
  });

  /// The match parameters. MUTABLE for the same reason [resumeToken] is: the
  /// room-code-collision / host-restart scenario replaces the whole match
  /// identity, and a new identity brings its OWN length and cubeless flag. A
  /// `final` config here would make that case untestable and would quietly
  /// assert that a reset can only ever mean "same match, replay it".
  MatchConfig config;
  final String hostAuthor;
  final String guestAuthor;
  final String matchCode;

  /// The current match identity. Mutable so a test can change it under a folding
  /// controller (a host restart) and then [InMemoryTransport.simulateReset].
  String resumeToken;
  final Capabilities capabilities;

  /// When true (the default) a write schedules a microtask flush to both
  /// endpoints; when false, frames buffer in the store until [pump].
  bool deliverImmediately;

  final List<EventFrame> _events = [];
  final Map<int, _Roll> _rolls = {};
  final List<InMemoryTransport> _endpoints = [];

  bool _flushScheduled = false;

  /// The next free sequence number (seqs are contiguous from 1).
  int get nextSeq => _events.length + 1;

  /// Roll-bearing events so far — so the next roll's index is `rollCount + 1`.
  int get rollCount => _events
      .where((e) => e.event is OpeningRollEvent || e.event is RollEvent)
      .length;

  /// A read-only snapshot of the log, for assertions.
  List<EventFrame> get events => List.unmodifiable(_events);

  // --- endpoint plumbing -----------------------------------------------------

  void _register(InMemoryTransport t) {
    _endpoints.add(t);
    _announcePresence();
  }

  void _unregister(InMemoryTransport t) {
    _endpoints.remove(t);
    _announcePresence();
  }

  /// True once BOTH seats have an attached endpoint — the in-memory stand-in for
  /// online's `guestUid != null` and LAN's `HostServer.guestPresence`.
  bool _seatFilled(String author) =>
      _endpoints.any((e) => e.author == author && !e._disposed);

  void _announcePresence() {
    for (final t in List<InMemoryTransport>.from(_endpoints)) {
      t.setOpponentPresent(_seatFilled(
          t.author == hostAuthor ? guestAuthor : hostAuthor));
    }
  }

  // --- writes ----------------------------------------------------------------

  void appendEvent({
    required String author,
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) {
    if (_events.any((e) => e.seq == seq)) {
      throw TransportContested('seq-taken', 'events/$seq already exists');
    }
    _events.add(
        EventFrame(seq: seq, gameNo: gameNo, event: event, author: author));
    _schedule();
  }

  void createRoll({
    required String author,
    required int n,
    required String commit,
  }) {
    if (_rolls.containsKey(n)) {
      throw TransportContested('roll-taken', 'rolls/$n already exists');
    }
    _rolls[n] = _Roll(n: n, roller: author, commit: commit);
    _schedule();
  }

  void addEntropy({
    required String author,
    required int n,
    required String entropy,
  }) {
    final roll = _rolls[n];
    if (roll == null) {
      throw TransportRejected('no-roll', 'rolls/$n does not exist');
    }
    if (roll.roller == author) {
      throw const TransportRejected(
          'entropy-by-roller', 'the roller cannot add entropy');
    }
    if (roll.entropy != null || roll.reveal != null) {
      throw const TransportRejected('entropy-write-once', 'entropy is write-once');
    }
    roll.entropy = entropy;
    _schedule();
  }

  void addReveal({
    required String author,
    required int n,
    required String reveal,
  }) {
    final roll = _rolls[n];
    if (roll == null) {
      throw TransportRejected('no-roll', 'rolls/$n does not exist');
    }
    if (roll.roller != author) {
      throw const TransportRejected(
          'reveal-not-roller', 'only the roller may reveal');
    }
    if (roll.entropy == null) {
      throw const TransportRejected('reveal-before-entropy', 'reveal before entropy');
    }
    if (roll.reveal != null) {
      throw const TransportRejected('reveal-write-once', 'reveal is write-once');
    }
    roll.reveal = reveal;
    _schedule();
  }

  // --- reads (resync pulls) --------------------------------------------------

  List<EventFrame> eventsSince(int afterSeq) =>
      [for (final e in _events) if (e.seq > afterSeq) e]
        ..sort((a, b) => a.seq.compareTo(b.seq));

  RollFrame? fetchRoll(int n) => _rolls[n]?.toFrame();

  /// Every roll document, ascending by index — the delivery order an endpoint
  /// walks. (A read-only snapshot, so a listener may write during a flush.)
  List<RollFrame> get rollFrames {
    final ns = _rolls.keys.toList()..sort();
    return [for (final n in ns) _rolls[n]!.toFrame()];
  }

  // --- scripted seeding ------------------------------------------------------

  /// Seed a SOUND opening roll: a complete `rolls/{n}` plus the
  /// [OpeningRollEvent] it derives, authored by the host. Everything a
  /// controller validates holds — this is how a test starts from a live game
  /// without running the handshake, and how it AIMS a known opening.
  void seedOpening({
    required int whiteDie,
    required int blackDie,
    int gameNo = 1,
  }) {
    final n = rollCount + 1;
    final s = openingSecretsFor(whiteDie, blackDie);
    _rolls[n] = _Roll(n: n, roller: hostAuthor, commit: s.commit)
      ..entropy = s.entropy
      ..reveal = s.secret;
    _events.add(EventFrame(
      seq: nextSeq,
      gameNo: gameNo,
      event: OpeningRollEvent(whiteDie: whiteDie, blackDie: blackDie),
      author: hostAuthor,
    ));
    _schedule();
  }

  /// Seed a SOUND ordinary roll for [author] (playing [player]) plus its
  /// [RollEvent], aiming exactly [die1]/[die2].
  void seedRoll({
    required String author,
    required Player player,
    required int die1,
    required int die2,
    int gameNo = 1,
  }) {
    final n = rollCount + 1;
    final s = turnSecretsFor(die1, die2);
    _rolls[n] = _Roll(n: n, roller: author, commit: s.commit)
      ..entropy = s.entropy
      ..reveal = s.secret;
    _events.add(EventFrame(
      seq: nextSeq,
      gameNo: gameNo,
      event: RollEvent(player, die1, die2),
      author: author,
    ));
    _schedule();
  }

  /// Seed a SOUND, AIMED roll DOCUMENT at the next free index — no event, and
  /// optionally stopping short of the entropy/reveal phase. Returns the index and
  /// the secrets, so a test can advance the phases itself later.
  ///
  /// Why a test would want this rather than [seedRoll]: aiming an opponent's dice
  /// means choosing the roller's secret and the WITNESS'S ENTROPY together, which
  /// is exactly the substitution a live witness refuses (`NetMatchController`
  /// freezes on entropy it did not contribute to a roll it is witnessing). Seeded
  /// BEFORE a controller connects, the roll falls below that controller's roll
  /// floor and is legitimately taken as found — which is what makes an aimed
  /// opponent roll scriptable at all.
  ({int n, ScriptedSecrets secrets}) seedRollDoc({
    required String author,
    required int die1,
    required int die2,
    bool withEntropy = true,
    bool withReveal = true,
  }) {
    final n = _rolls.isEmpty ? 1 : (_rolls.keys.reduce((a, b) => a > b ? a : b) + 1);
    final s = turnSecretsFor(die1, die2);
    final roll = _Roll(n: n, roller: author, commit: s.commit);
    if (withEntropy) roll.entropy = s.entropy;
    if (withEntropy && withReveal) roll.reveal = s.secret;
    _rolls[n] = roll;
    _schedule();
    return (n: n, secrets: s);
  }

  // --- delivery --------------------------------------------------------------

  void _schedule() {
    if (!deliverImmediately) return;
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      _flush();
    });
  }

  /// Push every not-yet-delivered frame to each endpoint. In manual-pump mode
  /// (`deliverImmediately == false`) this is the ONLY way frames reach the
  /// endpoints; a test calls it to advance delivery a beat at a time. Returns
  /// the number of frames delivered across all endpoints.
  int pump() => _flush();

  int _flush() {
    var delivered = 0;
    // Snapshot: an endpoint may be disposed by a listener mid-flush.
    for (final t in List<InMemoryTransport>.from(_endpoints)) {
      delivered += t._deliverFrom(this);
    }
    return delivered;
  }
}

/// One endpoint on an [InMemoryBackend]: the host's or the guest's view.
class InMemoryTransport with TransportChannels implements MatchTransport {
  InMemoryTransport(this.backend, this.author) {
    backend._register(this);
  }

  /// The host endpoint (author == `backend.hostAuthor`).
  factory InMemoryTransport.host(InMemoryBackend backend) =>
      InMemoryTransport(backend, backend.hostAuthor);

  /// The guest endpoint (author == `backend.guestAuthor`).
  factory InMemoryTransport.guest(InMemoryBackend backend) =>
      InMemoryTransport(backend, backend.guestAuthor);

  final InMemoryBackend backend;

  /// This endpoint's identity in the author/roller space.
  final String author;

  bool _connected = false;
  bool _disposed = false;
  Duration _cadence = const Duration(milliseconds: 200);

  @override
  bool get isDisposed => _disposed;

  // Per-endpoint delivery cursors, so a flush emits only what is new to THIS
  // endpoint (at-least-once still holds; this only avoids re-emitting on every
  // beat). Its own writes are delivered back to it too.
  int _lastSeqDelivered = 0;
  final Map<int, FairDicePhase> _rollPhaseDelivered = {};

  // --- MatchTransport --------------------------------------------------------

  @override
  Future<TransportSession> connect() async {
    if (_disposed) {
      throw const TransportUnavailable('disposed', 'transport disposed');
    }
    final side = _sideOf(author);
    if (side == null) {
      throw TransportRejected(
          'not-a-participant', '$author is neither seat of this match');
    }
    _connected = true;
    setStatus(TransportStatus.connected);
    return _sessionNow();
  }

  /// The session as the backend stands RIGHT NOW. Rebuilt on every call rather
  /// than cached, so a test that changes the backend's identity/config is
  /// modelling a transport that re-reads it (which both shipped ones do).
  TransportSession _sessionNow() => TransportSession(
        assignedSide: _sideOf(author) ?? TransportSession.hostSide,
        config: backend.config,
        localAuthor: author,
        hostAuthor: backend.hostAuthor,
        guestAuthor: backend.guestAuthor,
        matchCode: backend.matchCode,
        resumeToken: backend.capabilities.durable ? backend.resumeToken : null,
      );

  Player? _sideOf(String a) {
    if (a == backend.hostAuthor) return TransportSession.hostSide;
    if (a == backend.guestAuthor) return TransportSession.hostSide.opponent;
    return null;
  }

  @override
  Future<void> sendEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) async {
    _ensureLive();
    backend.appendEvent(
        author: author, seq: seq, gameNo: gameNo, event: event);
  }

  @override
  Future<void> createRoll(int n, String commit) async {
    _ensureLive();
    backend.createRoll(author: author, n: n, commit: commit);
  }

  @override
  Future<void> sendEntropy(int n, String entropy) async {
    _ensureLive();
    backend.addEntropy(author: author, n: n, entropy: entropy);
  }

  @override
  Future<void> sendReveal(int n, String reveal) async {
    _ensureLive();
    backend.addReveal(author: author, n: n, reveal: reveal);
  }

  @override
  Future<List<EventFrame>> eventsSince(int afterSeq) async {
    _ensureLive();
    return backend.eventsSince(afterSeq);
  }

  @override
  Future<RollFrame?> fetchRoll(int n) async {
    _ensureLive();
    return backend.fetchRoll(n);
  }

  @override
  Future<List<RollFrame>> rollsSince(int from) async {
    _ensureLive();
    return [for (final r in backend.rollFrames) if (r.n >= from) r];
  }

  @override
  Future<void> complete() async {
    // Bookkeeping only: the log is the authority. Nothing to persist in memory.
  }

  @override
  Capabilities get capabilities => backend.capabilities;

  @override
  Duration get inboundCadence => _cadence;

  @override
  void setPaceHint({required bool fast}) => _cadence =
      fast ? const Duration(milliseconds: 50) : const Duration(seconds: 2);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    backend._unregister(this);
    await closeChannels();
  }

  // --- test controls ---------------------------------------------------------

  /// Simulate the link dropping (retry under way).
  void simulateDrop([String reason = 'link dropped']) =>
      setStatus(TransportStatus.reconnecting, reason);

  /// Simulate the link coming back.
  void simulateReconnect() => setStatus(TransportStatus.connected);

  /// Simulate the relay's single guest slot being taken (self-clearing).
  void simulateBusy([String reason = 'room is busy']) =>
      setStatus(TransportStatus.busy, reason);

  /// Simulate a terminal failure (retrying cannot help).
  void simulateFailure([String reason = 'terminally failed']) =>
      setStatus(TransportStatus.failed, reason);

  /// Emit a [ResetFrame]: "discard your fold and replay from the log".
  ///
  /// Also rewinds this endpoint's delivery cursors, so the frames the controller
  /// is about to re-pull are the ones a real reconnect would re-deliver.
  void simulateReset({String reason = 'reconnected'}) {
    if (_disposed) return;
    _lastSeqDelivered = 0;
    _rollPhaseDelivered.clear();
    publish(ResetFrame(
      resumeToken: backend.capabilities.durable ? backend.resumeToken : null,
      reason: reason,
      // The CURRENT session, per the contract: a test that changed
      // [InMemoryBackend.config] alongside the token is modelling a different
      // match, and the frame has to say so.
      session: _sessionNow(),
    ));
  }

  /// Push an ARBITRARY frame onto [inbound], bypassing the store entirely.
  ///
  /// The store enforces what a well-behaved backend enforces (write-once phases,
  /// entropy from the non-roller), so it cannot express a peer that IS the wire —
  /// a LAN host, which publishes whatever it likes to the guest regardless of what
  /// its own relay would have allowed. This is how a test plays that peer.
  void injectFrame(InboundFrame frame) => publish(frame);

  /// Push a transient read failure onto [inbound] WITHOUT closing it.
  void simulateInboundError([
    TransportException error =
        const TransportUnavailable('read-failed', 'transient read failure'),
  ]) =>
      publishError(error);

  // --- internals -------------------------------------------------------------

  void _ensureLive() {
    if (_disposed) throw const TransportUnavailable('disposed', 'transport disposed');
    if (!_connected) {
      throw const TransportUnavailable('not-connected', 'connect() first');
    }
  }

  /// Emit every frame new to this endpoint: rolls (by advancing phase) first,
  /// then events (by ascending seq) — the friendly order a poll cycle uses,
  /// though the contract only promises ordering WITHIN a kind.
  int _deliverFrom(InMemoryBackend b) {
    if (_disposed) return 0;
    var delivered = 0;

    for (final roll in b.rollFrames) {
      if (_rollPhaseDelivered[roll.n] != roll.phase) {
        _rollPhaseDelivered[roll.n] = roll.phase;
        publish(roll);
        delivered++;
      }
    }

    for (final e in b.eventsSince(_lastSeqDelivered)) {
      _lastSeqDelivered = e.seq;
      publish(e);
      delivered++;
    }
    return delivered;
  }
}
