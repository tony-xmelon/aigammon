import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/match_transport.dart';

import 'match_api.dart';
import 'online_exception.dart';

/// The online [MatchTransport]: two devices anywhere, one Firestore match
/// document, no server code at all.
///
/// A thin view over [MatchApi] (anonymous auth + direct document operations),
/// mapping the shipped document model onto the transport contract WITHOUT
/// changing a single field or rule. Everything the serverless design proved —
/// commit-reveal `rolls/{n}` documents, the append-only `events/{seq}` log,
/// `firebase/firestore.rules` as the only server-side logic, a durable anonymous
/// uid — is untouched; only the surface the controller sees is new.
///
/// ## Seq: a 0-based log behind a 1-based contract
///
/// The contract's event seq is "contiguous from 1", and the shipped log is
/// `events/{seq}` numbered FROM 0 (the document id IS the seq — that is what
/// makes an append land at most once without a server, and
/// `firestore.rules` enforces `int(id) == data.seq`). Renumbering the model was
/// never an option: matches in flight would break and every rules test would
/// have to be re-reasoned. So this transport does the arithmetic, in exactly two
/// places:
///
///   * OUT: `docSeq = frameSeq - 1` ([sendEvent], [eventsSince]);
///   * IN:  `frameSeq = docSeq + 1` (every [EventFrame] it publishes).
///
/// Hence `eventsSince(0)` — the contract's "the whole log" — becomes
/// `fetchEventsSince(code, -1)`, and the first event ever written lands in
/// `events/00000000` and arrives as `EventFrame(seq: 1)`.
///
/// Roll indices need NO mapping: `rolls/{n}` was already 1-based
/// (`n == 1 + roll-bearing events folded`), the same convention the contract
/// states.
///
/// ## Read budget: the watermarks live HERE
///
/// The Spark free tier bills per document read, so nothing may be read twice
/// without cause. Three watermarks, all private to this class:
///
///   * `_eventCursor` — the highest doc seq we have handed to the controller.
///     The poll loop only ever asks for `seq > _eventCursor`, so an event is
///     read once and never again. Crucially it is ALSO advanced by
///     [eventsSince]: the controller primes with `eventsSince(0)` immediately
///     after [connect], and that answer seeds the poll instead of being
///     re-fetched a cycle later. It is safe because a pull's events are retained
///     by the controller (its inbox holds them until they fold, and a failed
///     replace re-pulls the whole log anyway), so handing the cursor forward
///     cannot lose one.
///   * `_rollFloor` — rolls MUTATE (commit → entropy → reveal), so they cannot
///     be retired by index alone; but once roll `k` is complete and every roll
///     below it is too, it can never change again. The floor is the first index
///     that still might, and the poll never reads below it. This is what keeps a
///     long match's per-cycle cost flat instead of growing with its length.
///   * `_seenPhase` — the phase each live roll was last published at, so a roll
///     that has not moved is not re-emitted (it is still read; only the frame is
///     suppressed).
///
/// Two more savings are structural: the match document is read only until the
/// guest seat fills (see [opponentPresent]), and the resync pulls are DIRECT
/// gets rather than a stream restart.
///
/// ## Presence: the guest seat, read once
///
/// [connect] does not resolve until the match has both seats, because the seat
/// identities travel on [TransportSession] and a controller handed a null
/// `guestAuthor` would freeze on the opponent's first event (author↔seat
/// validation cannot map an identity it was never told about). So the host's
/// connect polls `matches/{code}` until `guestUid` appears, and from then on
/// [opponentPresent] is true forever: a claimed seat is permanent in this model
/// — there is no leave, no heartbeat and nothing to watch, so not one further
/// match-document read is spent. (The lobby's "waiting for opponent" card is the
/// SCREEN's own poll: it needs the invite code on screen and a Cancel button, and
/// no controller exists yet.)
///
/// ## Capabilities: durable AND rejoinable
///
/// `durable: true, rejoinable: true` — the log is in Firestore, so a match
/// survives the process, and either peer can re-open it later with the same
/// anonymous identity (see `token_store.dart`). [TransportSession.resumeToken]
/// is the invite [code]: it is the match document's id, claimed write-once by a
/// create, so one code can never name two matches — exactly the stable
/// match-identity the controller compares its watermarks against.
///
/// ## Ownership: the transport does NOT own the API stack
///
/// [dispose] stops the poll loop and closes this transport's streams, and
/// NOTHING else. [api] holds the app's anonymous session and its HTTP clients; it
/// is built once per app run (a Riverpod provider owns it) and outlives every
/// match. The controller owns the transport; the app owns the API. Mirrors
/// `SocketTransport`, which likewise leaves its link running.
class FirestoreTransport implements MatchTransport {
  FirestoreTransport({
    required this.api,
    required this.code,
    MatchDoc? match,
    this.pollInterval = const Duration(seconds: 2),
    Duration fastPollInterval = const Duration(milliseconds: 500),
  })  : fastPollInterval =
            fastPollInterval < pollInterval ? fastPollInterval : pollInterval,
        _match = match;

  /// The auth + Firestore stack. NOT owned: see the class doc.
  final MatchApi api;

  /// The invite code — the `matches/{code}` document id, the human-facing handle
  /// and the resume token all at once.
  final String code;

  /// The RESTING cadence, used whenever no dice handshake is in flight.
  final Duration pollInterval;

  /// The cadence used while a handshake is outstanding ([setPaceHint]).
  ///
  /// A roll is three writes that alternate between the peers, and each peer only
  /// learns of the other's step by polling — so at 2s a single roll burns about
  /// three poll latencies, roughly six seconds of dead time per turn. Polling
  /// fast for exactly as long as a handshake is outstanding removes that, and
  /// costs almost nothing: the fast window is bounded by PROTOCOL STEPS, not by
  /// wall time, so the peers spend the same ~3 cycles observing the same 3 phase
  /// changes whether each cycle is 500ms or 2s.
  ///
  /// Capped at [pollInterval] so a caller asking for a slower-than-500ms resting
  /// cadence is not silently sped up — which is what lets the emulator E2E's
  /// `AIGAMMON_E2E_POLL_MS` override BOTH cadences with one number.
  final Duration fastPollInterval;

  /// A [gateTimeout] for the controller, sized against this cadence.
  ///
  /// The controller's default assumes a pushed frame; here a committed write has
  /// to come back through a poll cycle, so the deadline must clear several
  /// cycles or a healthy submission would look lost. Four cycles, floored at the
  /// controller's own 5s default.
  Duration get suggestedGateTimeout {
    final paced = pollInterval * 4;
    return paced > _minGateTimeout ? paced : _minGateTimeout;
  }

  static const Duration _minGateTimeout = Duration(seconds: 5);

  final _inbound = StreamController<InboundFrame>.broadcast();
  final _status = StreamController<TransportStatusEvent>.broadcast();
  final _presence = StreamController<bool>.broadcast();

  /// The match document, once read (or handed in by the screen that created or
  /// joined it, saving a read).
  MatchDoc? _match;
  TransportSession? _session;

  TransportStatus _statusValue = TransportStatus.connecting;
  String? _statusReason;
  bool _opponentPresent = false;
  bool _fast = false;
  bool _disposed = false;
  bool _polling = false;

  /// The poll loop's single pending pause — see [_sleep].
  Timer? _sleepTimer;
  Completer<void>? _sleeper;

  /// The highest `events/{seq}` doc id handed to the controller; `-1` = nothing.
  /// See the class doc's read-budget note.
  int _eventCursor = -1;

  /// The lowest roll index that might still change. Rolls are 1-based.
  int _rollFloor = 1;

  /// The phase each live roll was last published at.
  final Map<int, FairDicePhase> _seenPhase = {};

  // --- MatchTransport --------------------------------------------------------

  /// Sign in, seat this device, and wait for the other seat.
  ///
  /// Creating and joining are deliberately NOT done here: those are lobby
  /// decisions with their own user-facing copy (a mistyped code, a seat someone
  /// else took), and the screen has to own them anyway to show the invite code
  /// before any opponent exists. A transport is a view over a seat this device
  /// already holds, so a caller that is not a participant is a programming error
  /// dressed as a [TransportRejected].
  ///
  /// Returns the SAME session on a second call (the controller only connects
  /// once, but the contract asks for it).
  @override
  Future<TransportSession> connect() async {
    _ensureLive();
    final existing = _session;
    if (existing != null) return existing;
    try {
      await api.signIn();
    } on OnlineException catch (e) {
      throw TransportUnavailable(e.code, e.message);
    }
    _ensureLive();
    var doc = _match ?? await _readMatch();
    final side = doc.sideOf(api.uid);
    if (side == null) {
      throw TransportRejected('not-a-participant',
          'this device (${api.uid}) holds no seat in match $code');
    }
    // Wait for the guest seat. Only ever true for the host, and only until
    // somebody joins; a guest reads a match that already has both seats.
    while (doc.guestUid == null) {
      await _sleep(pollInterval);
      _ensureLive();
      doc = await _readMatch();
    }
    _match = doc;
    _session = TransportSession(
      assignedSide: side,
      config: MatchConfig(length: doc.length, cubeless: doc.cubeless),
      localAuthor: api.uid,
      hostAuthor: doc.hostUid,
      guestAuthor: doc.guestUid,
      matchCode: code,
      resumeToken: code,
    );
    _setStatus(TransportStatus.connected);
    _setOpponentPresent(true);
    _startPolling();
    return _session!;
  }

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Future<void> sendEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) async {
    _ensureConnected();
    try {
      await api.submitEvent(
        code: code,
        seq: _docSeq(seq),
        gameNo: gameNo,
        event: event,
      );
    } on OnlineException catch (e) {
      // A taken seq is the one refusal that carries information: the index we
      // asked for is committed, so the authority's log is at least that long.
      throw _mapWrite(e, peerLastSeq: e is AlreadyExistsException ? seq : null);
    }
  }

  @override
  Future<void> createRoll(int n, String commit) async {
    _ensureConnected();
    try {
      await api.createRoll(code: code, n: n, commit: commit);
    } on OnlineException catch (e) {
      throw _mapWrite(e);
    }
  }

  @override
  Future<void> sendEntropy(int n, String entropy) async {
    _ensureConnected();
    try {
      await api.submitEntropy(code: code, n: n, entropy: entropy);
    } on OnlineException catch (e) {
      throw _mapWrite(e);
    }
  }

  @override
  Future<void> sendReveal(int n, String reveal) async {
    _ensureConnected();
    try {
      await api.submitReveal(code: code, n: n, reveal: reveal);
    } on OnlineException catch (e) {
      throw _mapWrite(e);
    }
  }

  /// EXACTLY the events with `seq > afterSeq`, ascending and contiguous — a
  /// paginated query straight at Firestore, never a mirror, so it is
  /// authoritative by construction.
  ///
  /// `afterSeq` is in the contract's 1-based space; `afterSeq == 0` reads the
  /// whole log. Advances the poll cursor (class doc).
  @override
  Future<List<EventFrame>> eventsSince(int afterSeq) async {
    _ensureConnected();
    final List<RemoteEvent> rows;
    try {
      rows = await api.fetchEventsSince(code, _docSeq(afterSeq));
    } on OnlineException catch (e) {
      throw _mapRead(e);
    }
    if (rows.isNotEmpty) {
      _eventCursor = _max(_eventCursor, rows.last.seq);
    }
    return [for (final row in rows) _frameOf(row)];
  }

  @override
  Future<RollFrame?> fetchRoll(int n) async {
    _ensureConnected();
    final RollDoc? doc;
    try {
      doc = await api.fetchRoll(code, n);
    } on OnlineException catch (e) {
      throw _mapRead(e);
    }
    if (doc == null) return null;
    _retireCompletedRolls({n: doc});
    return _rollFrameOf(doc);
  }

  @override
  Future<List<RollFrame>> rollsSince(int from) async {
    _ensureConnected();
    final List<RollDoc> rows;
    try {
      rows = await api.fetchRollsFrom(code, from);
    } on OnlineException catch (e) {
      throw _mapRead(e);
    }
    _retireCompletedRolls({for (final r in rows) r.n: r});
    return [for (final r in rows) _rollFrameOf(r)];
  }

  /// Flip the match document to `complete`. Bookkeeping only — the event log is
  /// the authority — so the caller swallows a failure.
  @override
  Future<void> complete() async {
    _ensureConnected();
    try {
      await api.completeMatch(code);
    } on OnlineException catch (e) {
      throw _mapWrite(e);
    }
  }

  @override
  Stream<TransportStatusEvent> get statusStream => _status.stream;

  @override
  TransportStatus get status => _statusValue;

  @override
  String? get statusReason => _statusReason;

  /// True from [connect] onwards, and never false again — see the class doc.
  @override
  bool get opponentPresent => _opponentPresent;

  @override
  Stream<bool> get opponentPresence => _presence.stream;

  /// Both true: the log lives in Firestore, and a durable anonymous uid can
  /// re-open a match after a restart. This is what enables the controller's
  /// rejoin path and the lobby's "Match in progress" card.
  @override
  Capabilities get capabilities =>
      const Capabilities(durable: true, rejoinable: true);

  /// The interval the poll loop is using RIGHT NOW — the real number, because
  /// the controller reuses it as the beat for its own self-healing retries (a
  /// roll whose document has not landed yet). Reporting zero here would make a
  /// 2s-polling transport retry twenty times per cycle for nothing.
  @override
  Duration get inboundCadence => _fast ? fastPollInterval : pollInterval;

  /// Switch cadence. Takes effect on the NEXT cycle: the interval is read once
  /// per cycle, so a hint that arrives during a sleep does not cut it short
  /// (identical to the shipped poller, and the reason the fast window is
  /// measured in protocol steps rather than milliseconds).
  @override
  void setPaceHint({required bool fast}) {
    _fast = fast;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _polling = false;
    _wake();
    await _inbound.close();
    await _status.close();
    await _presence.close();
  }

  // --- polling ---------------------------------------------------------------

  /// The one poll loop, started by [connect].
  ///
  /// It SLEEPS FIRST, deliberately: the controller primes its fold with
  /// `eventsSince(0)` + `rollsSince(1)` the moment [connect] returns, and those
  /// pulls advance the watermarks — so the first cycle asks only for what is
  /// genuinely new instead of re-reading the log the controller has just read.
  void _startPolling() {
    if (_polling) return;
    _polling = true;
    unawaited(_pollLoop());
  }

  Future<void> _pollLoop() async {
    while (_polling && !_disposed) {
      await _sleep(inboundCadence);
      if (!_polling || _disposed) return;
      try {
        await _pollOnce();
        if (_statusValue != TransportStatus.connected) {
          _setStatus(TransportStatus.connected);
        }
      } on OnlineException catch (e) {
        _onPollFailure(_mapRead(e));
      } catch (e) {
        _onPollFailure(TransportUnavailable('io', '$e'));
      }
    }
  }

  /// One cycle: the new events, then every roll that might still move.
  ///
  /// Events first so a roll event and its roll document are as close together as
  /// two queries allow; the controller tolerates either order anyway (it fetches
  /// a roll it has not seen).
  Future<void> _pollOnce() async {
    final events = await api.fetchEventsSince(code, _eventCursor);
    if (!_polling || _disposed) return;
    for (final row in events) {
      _eventCursor = _max(_eventCursor, row.seq);
      _publish(_frameOf(row));
    }
    final rolls = await api.fetchRollsFrom(code, _rollFloor);
    if (!_polling || _disposed) return;
    for (final roll in rolls) {
      if (_seenPhase[roll.n] == roll.phase) continue;
      _seenPhase[roll.n] = roll.phase;
      _publish(_rollFrameOf(roll));
    }
    _retireCompletedRolls({for (final r in rolls) r.n: r});
  }

  /// A poll blip: a transient fault on [inbound] WITHOUT closing it (the
  /// contract forbids ending the stream to signal trouble), plus a
  /// [TransportStatus.reconnecting] chip. The next successful cycle clears both.
  void _onPollFailure(TransportException error) {
    if (_disposed) return;
    _setStatus(TransportStatus.reconnecting, error.message);
    if (!_inbound.isClosed) _inbound.addError(error);
  }

  /// Advance [_rollFloor] over the leading run of finished rolls in [byIndex].
  ///
  /// Index-keyed rather than sequential so it works for a single [fetchRoll], a
  /// bulk [rollsSince] from any starting index, and a poll page alike.
  void _retireCompletedRolls(Map<int, RollDoc> byIndex) {
    while (byIndex[_rollFloor]?.isComplete ?? false) {
      _seenPhase.remove(_rollFloor);
      _rollFloor++;
    }
  }

  // --- mapping ---------------------------------------------------------------

  /// The document seq for a contract seq: the whole 0-based↔1-based bridge.
  int _docSeq(int frameSeq) => frameSeq - 1;

  EventFrame _frameOf(RemoteEvent row) => EventFrame(
        seq: row.seq + 1,
        gameNo: row.gameNo,
        event: row.event,
        author: row.author,
      );

  RollFrame _rollFrameOf(RollDoc doc) => RollFrame(
        n: doc.n,
        roller: doc.roller,
        commit: doc.commit,
        entropy: doc.entropy,
        reveal: doc.reveal,
      );

  /// A WRITE failure, mapped onto the contract's three meanings.
  ///
  ///   * [AlreadyExistsException] — the write-once index was claimed first, so
  ///     our view of the log is behind: [TransportContested], resync and retry.
  ///   * [PermissionDeniedException] — `firestore.rules` refused (phase skip,
  ///     wrong author, non-participant). An identical retry fails identically:
  ///     [TransportRejected], never retried.
  ///   * [FailedPreconditionException] — the document moved under us; the same
  ///     cure as a collision, so [TransportContested].
  ///   * everything else (auth blip, 5xx, socket) — [TransportUnavailable]: it
  ///     may or may not have landed, which is precisely what that class means.
  TransportException _mapWrite(OnlineException e, {int? peerLastSeq}) {
    if (e is AlreadyExistsException) {
      return TransportContested(e.code, e.message, peerLastSeq: peerLastSeq);
    }
    if (e is PermissionDeniedException) {
      return TransportRejected(e.code, e.message);
    }
    if (e is FailedPreconditionException) {
      return TransportContested(e.code, e.message, peerLastSeq: peerLastSeq);
    }
    return TransportUnavailable(e.code, e.message);
  }

  /// A READ failure. A refusal here is not a protocol violation to freeze on —
  /// a token that expired mid-flight reads as `PERMISSION_DENIED` too — so only
  /// a rules refusal on a read stays terminal, and everything else is transient.
  TransportException _mapRead(OnlineException e) {
    if (e is PermissionDeniedException) {
      return TransportRejected(e.code, e.message);
    }
    return TransportUnavailable(e.code, e.message);
  }

  // --- internals -------------------------------------------------------------

  Future<MatchDoc> _readMatch() async {
    try {
      return await api.fetchMatch(code);
    } on OnlineException catch (e) {
      if (e is NotFoundException || e is PermissionDeniedException) {
        throw TransportRejected(e.code, e.message);
      }
      throw TransportUnavailable(e.code, e.message);
    }
  }

  /// A CANCELLABLE pause — the loop's only timer.
  ///
  /// A plain `Future.delayed` would outlive [dispose] (nothing can cancel one),
  /// which leaks a poll cycle past the end of a match and trips the "a Timer is
  /// still pending" invariant in widget tests. There is never more than one in
  /// flight: [connect]'s wait for the guest seat finishes before the poll loop
  /// starts, and the loop sleeps once per cycle.
  Future<void> _sleep(Duration d) {
    _wake();
    final waiter = Completer<void>();
    _sleeper = waiter;
    _sleepTimer = Timer(d, () {
      _sleepTimer = null;
      _sleeper = null;
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future;
  }

  /// Cancel any pending pause and release whoever is waiting on it (so a loop
  /// woken by [dispose] runs its exit check immediately).
  void _wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final waiting = _sleeper;
    _sleeper = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  void _publish(InboundFrame frame) {
    if (_disposed || _inbound.isClosed) return;
    _inbound.add(frame);
  }

  void _setStatus(TransportStatus status, [String? reason]) {
    if (_disposed) return;
    if (_statusValue == status && _statusReason == reason) return;
    _statusValue = status;
    _statusReason = reason;
    if (!_status.isClosed) _status.add(TransportStatusEvent(status, reason));
  }

  void _setOpponentPresent(bool present) {
    if (_disposed || _opponentPresent == present) return;
    _opponentPresent = present;
    if (!_presence.isClosed) _presence.add(present);
  }

  void _ensureLive() {
    if (_disposed) {
      throw const TransportUnavailable('disposed', 'transport disposed');
    }
  }

  void _ensureConnected() {
    _ensureLive();
    if (_session == null) {
      throw const TransportUnavailable('not-connected', 'connect() first');
    }
  }

  static int _max(int a, int b) => a > b ? a : b;
}
