import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/match_transport.dart';

import 'firestore_listen.dart';
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
/// ## Two delivery paths, one set of watermarks
///
/// Inbound frames arrive by whichever of two mechanisms is healthy:
///
///   * a **real-time Listen stream** ([FirestoreListenChannel], gRPC) — the
///     normal path. Firestore pushes each changed document as it commits, and
///     bills per DELIVERED DOCUMENT, so a turn nobody takes costs nothing;
///   * the **poll loop** — two collection queries per cycle, the Task-4
///     mechanism, kept as the fallback that runs whenever the listener is not
///     live (including before it has caught up, and forever if no
///     [listenChannel] was supplied).
///
/// They share the watermarks below, so which one delivered a document is
/// invisible to the controller: every event is published exactly once, in
/// ascending seq order, and every roll phase exactly once.
///
/// A transport with NO [listenChannel] behaves exactly as Task 4's did. That is
/// deliberate — the lobby's widget tests drive a real transport over a `MatchApi`
/// FAKE, which has no gRPC endpoint behind it, and they neither need real-time
/// delivery nor should pay for a seam to opt out of it. (As a second belt, a
/// factory that THROWS when invoked disables the listener silently and
/// permanently rather than entering the retry loop: an un-constructible channel
/// is a configuration fact, not a network blip.)
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
///     Both paths only ever ask for `seq > _eventCursor` (the poll query and the
///     listen target's filter alike), so an event is read once and never again.
///     Crucially it is ALSO advanced by [eventsSince]: the controller primes with
///     `eventsSince(0)` immediately after [connect], and that answer seeds both
///     paths instead of being re-fetched a cycle later. It is safe because a
///     pull's events are retained by the controller (its inbox holds them until
///     they fold, and a failed replace re-pulls the whole log anyway), so handing
///     the cursor forward cannot lose one — and the listener cannot skip an event
///     the controller failed to fold, because the controller's recovery is a
///     fresh `eventsSince`, never a replay of the stream.
///   * `_rollFloor` — rolls MUTATE (commit → entropy → reveal), so they cannot
///     be retired by index alone; but once roll `k` is complete and every roll
///     below it is too, it can never change again. The floor is the first index
///     that still might, and neither path reads below it. This is what keeps a
///     long match's per-cycle cost flat instead of growing with its length.
///   * `_seenPhase` — the phase each live roll was last published at, so a roll
///     that has not moved is not re-emitted. On the poll path it is still read;
///     on the listen path it is not even delivered, because Firestore only pushes
///     a document that changed.
///
/// Two more savings are structural: the match document is read only until the
/// guest seat fills (see [opponentPresent]), and the resync pulls are DIRECT
/// gets rather than a stream restart.
///
/// [documentsRead] counts what this transport has actually been handed, for the
/// budget claims in `firebase/DEPLOY.md`.
///
/// ## Ordering: Listen delivers a SET, not a sequence
///
/// Firestore promises that the documents between two snapshot boundaries form one
/// consistent view; it promises nothing about the order they arrive in. So
/// deltas are buffered and flushed at each boundary ([ListenSnapshot]), sorted by
/// `seq`/`n` — which is what makes the listen path indistinguishable from the
/// poll path to the controller's contiguity check. [listenBatchWindow] is a
/// safety net that flushes a batch whose boundary never came.
///
/// ## RESET is NOT a match-identity change
///
/// Two different things are called "reset" here, and conflating them would be a
/// data-loss bug:
///
///   * a Listen `targetChange: RESET` means "discard what you hold for this
///     TARGET, I am about to resend it" — a transport-internal re-sync. It is
///     handled internally: the target's resume token is dropped, its buffered
///     deltas are discarded, and a catch-up read is issued at the current
///     watermarks. Firestore's re-delivery is then deduplicated by those same
///     watermarks;
///   * the contract's [ResetFrame] means "the MATCH IDENTITY changed — throw your
///     fold away and every per-match watermark with it" (see
///     `NetMatchController._onReset`, which re-adopts the identity and replaces
///     the log).
///
/// A [ResetFrame] is therefore NEVER emitted by this transport: a transport is
/// bound to one invite code, one code can only ever name one match (the id is
/// claimed write-once by the create), and a rejoin builds a NEW transport which
/// re-primes on connect. Emitting one for a Listen RESET would blow away the
/// controller's watermarks for what is, from the match's point of view, nothing
/// at all.
///
/// ## Fallback: never leave a match dead
///
/// [connect] starts the poll loop AND the listener. The loop is stopped the
/// moment the listener reports `CURRENT` on both targets, and restarted
/// immediately (with no initial sleep) if the stream ever errors, closes, or has
/// a target removed under it. Re-listen attempts back off from
/// [listenRetryFloor] to [listenRetryCeiling], each step jittered so a
/// server-side outage does not have every client re-attempt in lockstep (see
/// [_scheduleRelisten]); a recovery stops polling again.
/// A drop of a LIVE listener also surfaces a transient error on [inbound]
/// (without closing it — the contract forbids ending the stream to signal
/// trouble). [status] is deliberately NOT moved to `reconnecting` for a listener
/// drop: the match really is still connected, just slower, and a "reconnecting"
/// chip over a working match would be a lie.
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
/// [dispose] stops the poll loop, closes the Listen channel it built, and closes
/// this transport's streams — and NOTHING else. [api] holds the app's anonymous
/// session and its HTTP clients; it is built once per app run (a Riverpod provider
/// owns it) and outlives every match. The controller owns the transport; the app
/// owns the API. Mirrors `SocketTransport`, which likewise leaves its link
/// running.
class FirestoreTransport implements MatchTransport {
  FirestoreTransport({
    required this.api,
    required this.code,
    MatchDoc? match,
    this.pollInterval = const Duration(seconds: 2),
    Duration fastPollInterval = const Duration(milliseconds: 500),
    this.listenChannel,
    this.listenStartDelay = const Duration(milliseconds: 200),
    this.listenRetryFloor = const Duration(seconds: 1),
    this.listenRetryCeiling = const Duration(seconds: 30),
    this.listenBatchWindow = const Duration(milliseconds: 25),
  })  : fastPollInterval =
            fastPollInterval < pollInterval ? fastPollInterval : pollInterval,
        _match = match;

  /// The auth + Firestore stack. NOT owned: see the class doc.
  final MatchApi api;

  /// The invite code — the `matches/{code}` document id, the human-facing handle
  /// and the resume token all at once.
  final String code;

  /// Builds the real-time channel. Null → poll only (see the class doc).
  final FirestoreListenChannelFactory? listenChannel;

  /// How long after [connect] the listener is opened.
  ///
  /// A pure read-budget optimisation, not a correctness requirement. The
  /// controller primes with `eventsSince(0)` the instant [connect] returns, and
  /// the listen target's filter is built from the cursor AT OPEN TIME — so
  /// opening a moment later means a rejoin into a long match watches
  /// `seq > tail` instead of `seq > -1`, and Firestore delivers (and bills) the
  /// tail instead of the whole log. Getting the race wrong costs one re-delivery
  /// of documents the controller already holds, and loses nothing.
  final Duration listenStartDelay;

  /// First re-listen delay after a drop; doubles up to [listenRetryCeiling].
  final Duration listenRetryFloor;

  /// Cap on the re-listen backoff.
  final Duration listenRetryCeiling;

  /// How long a buffered listen batch may wait for a snapshot boundary that
  /// never comes before it is flushed anyway.
  final Duration listenBatchWindow;

  /// The RESTING cadence, used whenever no dice handshake is in flight.
  final Duration pollInterval;

  /// The cadence used while a handshake is outstanding ([setPaceHint]).
  ///
  /// A roll is three writes that alternate between the peers, and on the POLL
  /// path each peer only learns of the other's step by polling — so at 2s a
  /// single roll burns about three poll latencies, roughly six seconds of dead
  /// time per turn. Polling fast for exactly as long as a handshake is
  /// outstanding removes that, and costs almost nothing: the fast window is
  /// bounded by PROTOCOL STEPS, not by wall time, so the peers spend the same ~3
  /// cycles observing the same 3 phase changes whether each cycle is 500ms or 2s.
  /// (With the listener live there is no cycle at all and the hint is inert.)
  ///
  /// Capped at [pollInterval] so a caller asking for a slower-than-500ms resting
  /// cadence is not silently sped up — which is what lets the emulator E2E's
  /// `AIGAMMON_E2E_POLL_MS` override BOTH cadences with one number.
  final Duration fastPollInterval;

  /// A [gateTimeout] for the controller, sized against this cadence.
  ///
  /// Sized for the DEGRADED path on purpose. The controller's default assumes a
  /// pushed frame, and with the listener live that is exactly what this is — but
  /// the listener can drop mid-submission, and then the committed write has to
  /// come back through a poll cycle instead. A gate sized for the push path would
  /// declare a perfectly healthy submission lost at the worst possible moment, so
  /// four poll cycles it is, floored at the controller's own 5s default.
  ///
  /// Capped at [_maxGateTimeout] because the interval is a test knob as much as a
  /// production setting: a suite that parks the resting cadence at 30s (so that
  /// nothing is polled behind its back) must not thereby ask the controller to
  /// wait two minutes for a write.
  Duration get suggestedGateTimeout {
    final paced = pollInterval * 4;
    final floored = paced > _minGateTimeout ? paced : _minGateTimeout;
    return floored < _maxGateTimeout ? floored : _maxGateTimeout;
  }

  static const Duration _minGateTimeout = Duration(seconds: 5);
  static const Duration _maxGateTimeout = Duration(seconds: 20);

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

  /// Set when the next poll cycle must not sleep first (a fresh degradation
  /// wants an immediate read, since the listener may have missed something).
  bool _pollNow = false;

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

  /// Documents this transport has been handed by Firestore, by either path.
  int _documentsRead = 0;

  // --- listener state --------------------------------------------------------

  static const int _eventsTargetId = 1;
  static const int _rollsTargetId = 2;
  static const List<int> _allTargetIds = [_eventsTargetId, _rollsTargetId];

  FirestoreListenChannel? _channel;
  StreamSubscription<ListenDelta>? _listenSub;

  /// True from "both targets CURRENT" until the stream fails. While true the
  /// poll loop is stopped and [inboundCadence] reports zero.
  bool _listenerLive = false;

  /// Permanently off: no factory, or a factory that could not be invoked.
  bool _listenDisabled = false;

  Timer? _listenStartTimer;
  Timer? _relistenTimer;
  Duration? _listenBackoff;

  /// Spreads the re-listen ladder across clients — see [_scheduleRelisten].
  final _jitter = Random();

  /// Whether the attempt in flight replayed resume tokens, and whether it got as
  /// far as CURRENT — together they decide whether a failure invalidates the
  /// tokens (see [_onListenFailure]).
  bool _attemptUsedTokens = false;
  bool _attemptReachedCurrent = false;

  final Set<int> _currentTargets = {};
  _ResumePoint? _eventsResume;
  _ResumePoint? _rollsResume;

  /// Deltas awaiting a snapshot boundary, keyed by index so a document that
  /// changes twice inside one batch collapses to its latest state.
  final Map<int, RemoteEvent> _pendingEvents = {};
  final Map<int, RollDoc> _pendingRolls = {};
  Timer? _flushTimer;

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
  ///
  /// Blocking until the guest seat fills is part of the contract, not an
  /// implementation detail: the seat identities travel on [TransportSession], and
  /// a controller handed a null `guestAuthor` freezes on the opponent's first
  /// event because author↔seat validation cannot map an identity it was never
  /// told about. The listener does not change that — it watches subcollections,
  /// and the match document's `guestUid` is not one of them.
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
    // Polling first, always: it is the path that is known to be working, and it
    // covers the window before the listener catches up (and forever if there is
    // no listener).
    _startPolling();
    _armListenStart();
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
  /// whole log. Advances the delivery cursor (class doc) — including while a
  /// Listen stream is up, where it means the stream will re-deliver those
  /// documents and the flush will drop them as already published. That is the
  /// right way round: the cursor can only ever suppress a DUPLICATE, never a
  /// first delivery, because the controller's own recovery from a failed fold is
  /// another call to this method rather than a replay of the stream.
  @override
  Future<List<EventFrame>> eventsSince(int afterSeq) async {
    _ensureConnected();
    final List<RemoteEvent> rows;
    try {
      rows = await api.fetchEventsSince(code, _docSeq(afterSeq));
    } on OnlineException catch (e) {
      throw _mapRead(e);
    }
    _documentsRead += rows.length;
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
    _documentsRead++;
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
    _documentsRead += rows.length;
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

  /// Whether the real-time Listen stream is currently delivering.
  bool get listenerLive => _listenerLive;

  /// Documents Firestore has handed this transport, by either path — pushed
  /// listen deltas, poll query rows and direct gets alike.
  ///
  /// A LOWER BOUND on what the match is billed: `firestore.rules` evaluates a
  /// `get()` on the match document for every read it authorises, and that get is
  /// itself a billed read which no client-side counter can see. Used by the
  /// emulator E2E to keep `firebase/DEPLOY.md`'s budget claims honest.
  int get documentsRead => _documentsRead;

  /// How long until a remote change is noticed: zero while the listener is live
  /// (Firestore pushes), the real poll interval while degraded.
  ///
  /// The number is the honest one either way, because the controller reuses it as
  /// the beat for its own self-healing retries (a roll whose document has not
  /// landed yet) — reporting zero while polling at 2s would make it retry twenty
  /// times per cycle for nothing, and reporting 2s while pushing would make a
  /// stuck roll wait 2s for no reason. The controller floors it, so zero is not a
  /// spin.
  @override
  Duration get inboundCadence => _listenerLive
      ? Duration.zero
      : (_fast ? fastPollInterval : pollInterval);

  /// Switch cadence. Takes effect on the NEXT cycle: the interval is read once
  /// per cycle, so a hint that arrives during a sleep does not cut it short
  /// (identical to the shipped poller, and the reason the fast window is
  /// measured in protocol steps rather than milliseconds). Inert while the
  /// listener is live — there is no cycle to pace.
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
    _listenStartTimer?.cancel();
    _relistenTimer?.cancel();
    _flushTimer?.cancel();
    await _teardownListener();
    await _inbound.close();
    await _status.close();
    await _presence.close();
  }

  // --- polling ---------------------------------------------------------------

  /// Start (or restart) the poll loop.
  ///
  /// It SLEEPS FIRST, deliberately: the controller primes its fold with
  /// `eventsSince(0)` + `rollsSince(1)` the moment [connect] returns, and those
  /// pulls advance the watermarks — so the first cycle asks only for what is
  /// genuinely new instead of re-reading the log the controller has just read.
  /// [immediate] overrides that for the one case where the wait is harmful: a
  /// listener that just died may have missed a document, and there is nothing to
  /// gain by learning that a cycle later.
  void _startPolling({bool immediate = false}) {
    if (_disposed) return;
    if (_polling) {
      // Already running: the most an immediate request can mean is "stop
      // sleeping", and cutting the pause short is exactly that.
      if (immediate) _wake();
      return;
    }
    _pollNow = immediate;
    _polling = true;
    unawaited(_pollLoop());
  }

  Future<void> _pollLoop() async {
    while (_polling && !_disposed) {
      if (_pollNow) {
        _pollNow = false;
      } else {
        await _sleep(inboundCadence);
      }
      if (!_polling || _disposed) return;
      try {
        await _pollOnce();
        if (_statusValue != TransportStatus.connected) {
          _setStatus(TransportStatus.connected);
        }
      } on OnlineException catch (e) {
        final fault = _mapRead(e);
        if (fault is TransportRejected) {
          _onTerminalRead(fault);
          return;
        }
        _onPollFailure(fault);
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
    if (_disposed) return;
    _documentsRead += events.length;
    for (final row in events) {
      if (row.seq <= _eventCursor) continue;
      _eventCursor = row.seq;
      _publish(_frameOf(row));
    }
    final rolls = await api.fetchRollsFrom(code, _rollFloor);
    if (_disposed) return;
    _documentsRead += rolls.length;
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
    _publishError(error);
  }

  /// A read that CANNOT succeed on a retry: the rules refuse us, or a document
  /// in the log does not decode.
  ///
  /// Both paths stop. Polling a document that will never parse is the worst
  /// possible use of a 50,000-read daily quota — at the 2s cadence it is ~43,000
  /// reads for no information — and the listener would only re-deliver the same
  /// bytes. So this is a TERMINAL state: `failed` on [statusStream] (which the
  /// controller surfaces as a hard error rather than a reconnect banner) and the
  /// fault itself on [inbound], then silence.
  ///
  /// [inbound] is NOT closed: the contract forbids ending the stream to signal
  /// trouble, and `failed` is the agreed way to say "retrying cannot help".
  void _onTerminalRead(TransportRejected error) {
    if (_disposed) return;
    _polling = false;
    _wake();
    _listenDisabled = true;
    _listenStartTimer?.cancel();
    _listenStartTimer = null;
    _relistenTimer?.cancel();
    _relistenTimer = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _listenerLive = false;
    _pendingEvents.clear();
    _pendingRolls.clear();
    unawaited(_teardownListener());
    _setStatus(TransportStatus.failed, error.message);
    _publishError(error);
  }

  /// Advance [_rollFloor] over the leading run of finished rolls in [byIndex].
  ///
  /// Index-keyed rather than sequential so it works for a single [fetchRoll], a
  /// bulk [rollsSince] from any starting index, a poll page and a listen batch
  /// alike.
  void _retireCompletedRolls(Map<int, RollDoc> byIndex) {
    while (byIndex[_rollFloor]?.isComplete ?? false) {
      _seenPhase.remove(_rollFloor);
      _rollFloor++;
    }
  }

  // --- listening -------------------------------------------------------------

  /// Schedule the first listen attempt. See [listenStartDelay] for the delay.
  void _armListenStart() {
    if (_disposed || _listenDisabled || listenChannel == null) {
      _listenDisabled = true;
      return;
    }
    _listenStartTimer?.cancel();
    if (listenStartDelay == Duration.zero) {
      _startListening();
      return;
    }
    _listenStartTimer = Timer(listenStartDelay, () {
      _listenStartTimer = null;
      _startListening();
    });
  }

  void _startListening() {
    if (_disposed || _listenDisabled || _channel != null) return;
    final factory = listenChannel;
    if (factory == null) return;

    final FirestoreListenChannel channel;
    try {
      channel = factory();
    } catch (e) {
      // An un-constructible channel is a configuration fact, not a blip: retrying
      // it forever would only burn timers (and, in a widget test over a fake
      // MatchApi, hang the tester on a pending one).
      _listenDisabled = true;
      return;
    }
    _channel = channel;
    _attemptReachedCurrent = false;
    _currentTargets.clear();

    final targets = _listenTargets();
    _attemptUsedTokens = targets.any((t) => t.resumeToken != null);
    // Remember the bounds this attempt actually opened with: a resume token is
    // only replayable against the query that produced it.
    for (final target in targets) {
      if (target.targetId == _eventsTargetId) _openedEventsFrom = target.from;
      if (target.targetId == _rollsTargetId) _openedRollsFrom = target.from;
    }

    try {
      _listenSub = channel.listen(targets).listen(
            _onDelta,
            onError: (Object e) => _onListenFailure(_mapListen(e)),
            onDone: () => _onListenFailure(const TransportUnavailable(
                'listen-closed', 'the Firestore listen stream closed')),
            cancelOnError: true,
          );
    } catch (e) {
      _onListenFailure(_mapListen(e));
    }
  }

  /// The two query targets, resumed where that is legal and cheap.
  ///
  /// A resume token belongs to the exact query that produced it, so it may only
  /// be replayed with the SAME filter bound — which means it is usable only while
  /// the corresponding watermark has not moved since the snapshot it came from.
  /// That is the common case for a drop during a long think, and it is where the
  /// token earns its keep (an in-flight roll document is not re-delivered). When
  /// the watermark HAS moved, a fresh target at the new bound is strictly
  /// cheaper than a replay anyway, so the token is simply dropped.
  List<ListenTarget> _listenTargets() {
    final events = _eventsResume;
    final rolls = _rollsResume;
    return [
      ListenTarget(
        targetId: _eventsTargetId,
        parentPath: 'matches/$code',
        collectionId: 'events',
        field: 'seq',
        inclusive: false,
        from: events != null && events.watermark == _eventCursor
            ? events.queryFrom
            : _eventCursor,
        resumeToken:
            events != null && events.watermark == _eventCursor ? events.token : null,
      ),
      ListenTarget(
        targetId: _rollsTargetId,
        parentPath: 'matches/$code',
        collectionId: 'rolls',
        field: 'n',
        inclusive: true,
        from: rolls != null && rolls.watermark == _rollFloor
            ? rolls.queryFrom
            : _rollFloor,
        resumeToken:
            rolls != null && rolls.watermark == _rollFloor ? rolls.token : null,
      ),
    ];
  }

  void _onDelta(ListenDelta delta) {
    if (_disposed) return;
    switch (delta) {
      case ListenDocument(:final name, :final fields):
        _documentsRead++;
        _buffer(name, fields);
        _armFlush();
      case ListenSnapshot(:final targetIds, :final current, :final resumeToken):
        _flush();
        _rememberResumeToken(targetIds, resumeToken);
        if (current) {
          _currentTargets
              .addAll(targetIds.isEmpty ? _allTargetIds : targetIds);
          if (_allTargetIds.every(_currentTargets.contains)) _onListenerLive();
        }
      case ListenTargetReset(:final targetIds):
        _onTargetReset(targetIds.isEmpty ? _allTargetIds : targetIds);
      case ListenTargetRemoved(:final cause):
        // The server dropped the target — an expired token, or a rules refusal.
        // Either way this stream is over; the poll path will produce the
        // authoritative refusal if there really is one, so it is NOT mapped to a
        // TransportRejected here (a token that went stale must not freeze a
        // match).
        _onListenFailure(TransportUnavailable(
            'listen-target-removed', cause ?? 'the listen target was removed'));
      case ListenTargetAdded():
        break;
      case ListenDocumentGone():
        // Nothing in this model is ever deleted, and a query-target removal can
        // only mean the document left the filtered range — impossible, since
        // `seq`/`n` never change. Ignored rather than trusted.
        break;
    }
  }

  void _buffer(String name, Map<String, Object?> fields) {
    try {
      if (name.contains('/events/')) {
        final row = RemoteEvent.fromFields(fields);
        _pendingEvents[row.seq] = row;
      } else if (name.contains('/rolls/')) {
        final roll = RollDoc.fromFields(fields);
        _pendingRolls[roll.n] = roll;
      }
    } on OnlineException catch (e) {
      final fault = _mapRead(e);
      if (fault is TransportRejected) {
        // Undecodable bytes, delivered. Re-listening would only re-deliver the
        // same document and the poll fallback would re-read it every cycle, so
        // this is terminal on both paths — see [_onTerminalRead].
        _onTerminalRead(fault);
        return;
      }
      // A transient decode failure is the peer's problem, not a stream fault:
      // surface it and keep listening.
      _publishError(fault);
    }
  }

  void _armFlush() {
    if (_flushTimer != null || _disposed) return;
    _flushTimer = Timer(listenBatchWindow, () {
      _flushTimer = null;
      _flush();
    });
  }

  /// Publish one consistent batch, in order.
  ///
  /// The watermark guards are what make double delivery impossible when the poll
  /// loop and the listener overlap (they always do, briefly, at startup and at
  /// every recovery), and what make Firestore's re-delivery after a RESET free.
  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed) return;
    if (_pendingEvents.isEmpty && _pendingRolls.isEmpty) return;

    final events = _pendingEvents.values.toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    _pendingEvents.clear();
    for (final row in events) {
      if (row.seq <= _eventCursor) continue;
      _eventCursor = row.seq;
      _publish(_frameOf(row));
    }

    final rolls = _pendingRolls.values.toList()..sort((a, b) => a.n.compareTo(b.n));
    _pendingRolls.clear();
    for (final roll in rolls) {
      if (roll.n < _rollFloor) continue;
      if (_seenPhase[roll.n] == roll.phase) continue;
      _seenPhase[roll.n] = roll.phase;
      _publish(_rollFrameOf(roll));
    }
    _retireCompletedRolls({for (final r in rolls) r.n: r});
  }

  void _rememberResumeToken(List<int> targetIds, Uint8List? token) {
    if (token == null || token.isEmpty) return;
    for (final id in targetIds.isEmpty ? _allTargetIds : targetIds) {
      if (id == _eventsTargetId) {
        _eventsResume = _ResumePoint(
          token: token,
          queryFrom: _openedEventsFrom,
          watermark: _eventCursor,
        );
      } else if (id == _rollsTargetId) {
        _rollsResume = _ResumePoint(
          token: token,
          queryFrom: _openedRollsFrom,
          watermark: _rollFloor,
        );
      }
    }
  }

  /// The filter bounds the live targets were opened with — see [_startListening].
  int _openedEventsFrom = -1;
  int _openedRollsFrom = 1;

  /// A Listen RESET: re-sync THIS target, which is not a match-identity change
  /// (see the class doc).
  ///
  /// The handling is almost nothing, and that is the point. RESET means "discard
  /// what you hold for this target; the complete new result set follows" — and
  /// this transport holds no document set to discard. It holds MONOTONE
  /// watermarks and forwards everything else, so the promised re-delivery is
  /// deduplicated for free and the only state that has to go is the resume token
  /// (void, because the snapshot it named is disowned) and the half-built batch
  /// (superseded by the resend).
  ///
  /// It must stay this cheap. The Firestore EMULATOR sends a RESET before every
  /// single change batch — it recomputes query results rather than diffing them —
  /// so anything expensive here (an off-cycle catch-up read was the first
  /// attempt) would fire on every opponent move and hand back the entire read
  /// budget the listener exists to save. Nothing is lost by trusting the resend:
  /// if the stream dies before it arrives, the drop restarts the poll loop with
  /// an immediate read.
  void _onTargetReset(List<int> targetIds) {
    for (final id in targetIds) {
      if (id == _eventsTargetId) {
        _eventsResume = null;
        _pendingEvents.clear();
      } else if (id == _rollsTargetId) {
        _rollsResume = null;
        _pendingRolls.clear();
      }
    }
  }

  void _onListenerLive() {
    _attemptReachedCurrent = true;
    if (_listenerLive) return;
    _listenerLive = true;
    _listenBackoff = null;
    // Real-time delivery has caught up: stop paying for cycles.
    _polling = false;
    _wake();
    if (_statusValue != TransportStatus.connected) {
      _setStatus(TransportStatus.connected);
    }
  }

  void _onListenFailure(TransportException error) {
    if (_disposed) return;
    final wasLive = _listenerLive;
    _listenerLive = false;
    _currentTargets.clear();
    _pendingEvents.clear();
    _pendingRolls.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_attemptUsedTokens && !_attemptReachedCurrent) {
      // The tokens we replayed are the likeliest cause; a fresh query next time.
      _eventsResume = null;
      _rollsResume = null;
    }
    unawaited(_teardownListener());
    // Never leave the match dead — and do not wait a cycle to find out what the
    // dying stream missed.
    _startPolling(immediate: true);
    if (wasLive) {
      // Only a LIVE listener dropping is worth telling the controller about, and
      // only as a transient: the match is still connected (over polling), so the
      // status stays `connected` and no "reconnecting" chip appears.
      _publishError(error);
    }
    _scheduleRelisten();
  }

  /// Arm the next listen attempt at the current backoff, PLUS jitter.
  ///
  /// The jitter (up to +25%) is not cosmetic. The thing that most often kills a
  /// listener is not this client — it is the far end: an outage, a proxy, a rules
  /// deploy. Every client that was watching drops at the same instant, and a
  /// deterministic 1-2-4-8-16-30 ladder then has all of them re-attempt in the
  /// same instants forever, so each recovery attempt arrives as a synchronised
  /// spike against the endpoint that is already unhealthy. Spreading each step
  /// over a quarter of its own length breaks the lockstep after the first retry
  /// while leaving the ladder's shape (and its ceiling) intact.
  void _scheduleRelisten() {
    if (_disposed || _listenDisabled) return;
    _relistenTimer?.cancel();
    final previous = _listenBackoff;
    final next = previous == null
        ? listenRetryFloor
        : (previous * 2 > listenRetryCeiling ? listenRetryCeiling : previous * 2);
    // The BACKOFF is stored unjittered, so the ladder does not drift.
    _listenBackoff = next;
    final spread = next.inMicroseconds ~/ 4;
    final delay = spread <= 0
        ? next
        : next + Duration(microseconds: _jitter.nextInt(spread + 1));
    _relistenTimer = Timer(delay, () {
      _relistenTimer = null;
      _startListening();
    });
  }

  Future<void> _teardownListener() async {
    final sub = _listenSub;
    _listenSub = null;
    final channel = _channel;
    _channel = null;
    await sub?.cancel();
    await channel?.close();
  }

  /// Any failure out of the Listen stream is transient by construction: a gRPC
  /// status, a socket, a truncated protobuf. The poll loop is the arbiter of what
  /// is actually terminal, because it is the path whose refusals come from
  /// `firestore.rules` with a body attached.
  TransportException _mapListen(Object error) =>
      error is TransportException ? error : TransportUnavailable('listen', '$error');

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
  /// A read failure as a typed fault.
  ///
  /// [MalformedDocumentException] joins `PERMISSION_DENIED` on the TERMINAL side
  /// deliberately: a document that does not decode now will not decode on the
  /// next cycle either (`events/{seq}` is write-once), so retrying it forever at
  /// the poll cadence would burn the whole day's free-tier read budget on one
  /// bad document. See [_isTerminalRead].
  TransportException _mapRead(OnlineException e) {
    if (e is PermissionDeniedException || e is MalformedDocumentException) {
      return TransportRejected(e.code, e.message);
    }
    return TransportUnavailable(e.code, e.message);
  }

  // --- internals -------------------------------------------------------------

  Future<MatchDoc> _readMatch() async {
    try {
      final doc = await api.fetchMatch(code);
      _documentsRead++;
      return doc;
    } on OnlineException catch (e) {
      if (e is NotFoundException) throw TransportRejected(e.code, e.message);
      throw _mapRead(e);
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
  /// woken by [dispose], or by the listener going live, runs its exit check
  /// immediately).
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

  void _publishError(Object error) {
    if (_disposed || _inbound.isClosed) return;
    _inbound.addError(error);
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

/// A resume token plus the two numbers that decide whether it is still usable:
/// the filter bound of the query that produced it, and the delivery watermark at
/// the snapshot it marks. See `FirestoreTransport._listenTargets`.
class _ResumePoint {
  const _ResumePoint({
    required this.token,
    required this.queryFrom,
    required this.watermark,
  });

  final Uint8List token;
  final int queryFrom;
  final int watermark;
}
