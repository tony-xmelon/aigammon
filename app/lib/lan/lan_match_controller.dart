import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_play/lan_play.dart';

import '../data/persistence_hooks.dart';
import '../game/applied_move.dart';
import '../game/match_controller.dart';
import '../game/player_agent.dart';

/// A non-fatal fault surfaced through [MatchController.error] while playing on
/// the LAN. Shaped like `OnlineException` (a machine [code] plus a
/// user-readable [message]) so the game screen's error banner treats both the
/// same way.
class LanMatchException implements Exception {
  const LanMatchException(this.code, this.message);

  /// A stable machine code: `offline`, `rejected`, `diverged`.
  final String code;

  /// The line the banner shows.
  final String message;

  @override
  String toString() => 'LanMatchException($code): $message';
}

/// The transport seam both LAN controllers fold: an inbound [Envelope] stream
/// (`welcome` / `event` / `reject`), the three intents a player can express,
/// and a `resync` that asks for the whole log back.
///
/// Two implementations ship, deliberately narrow so ONE fold serves both ends:
///
///  * the HOST link — in-process. Intents call [HostAuthority.localRoll] /
///    [HostAuthority.localSubmit] directly (no socket for the host's own
///    actions); inbound is the authority's own `outbound` stream filtered to
///    the messages destined for the local player.
///  * the GUEST link — over the wire. Intents become `roll_request` / `submit`
///    frames; inbound is [GuestClient.inbound].
///
/// Public so a test can drive the fold's recovery paths (a seq gap, a reject
/// from behind, a send that never leaves the device) deterministically, without
/// having to provoke them through a real socket — see
/// [LanMatchController.overLink].
abstract interface class LanLink {
  /// The frames the controller folds. A SINGLE-SUBSCRIPTION stream, so nothing
  /// emitted between construction and the controller's `listen` is lost.
  Stream<Envelope> get inbound;

  /// Ask the host to roll for the local side.
  bool requestRoll();

  /// Submit an event for the local side.
  bool submit(GameEvent event);

  /// Ask for the authoritative log to be replayed as a fresh `welcome`.
  bool resync();

  /// Stop listening. Does NOT own (or close) the authority / client — the
  /// screen that built them does.
  Future<void> dispose();
}

/// The host's in-process link to its own [HostAuthority].
class _HostLink implements LanLink {
  _HostLink(this.authority) {
    // SEEDED, not merely subscribed. `outbound` is a broadcast, non-buffering
    // stream, so everything the authority emitted before this constructor ran
    // is already gone — and the guest's `hello` (which starts game 1) routinely
    // lands first, because the screen builds the server before the controller.
    // Opening with the same synthetic welcome [resync] uses replays whatever
    // the log already holds, so there is no ordering contract to get wrong.
    if (authority.log.isNotEmpty) _out.add(_welcome());
    _sub = authority.outbound.listen((out) {
      if (!out.toLocal) return; // welcomes and guest-bound rejects are not ours
      if (!_out.isClosed) _out.add(out.message);
    });
  }

  final HostAuthority authority;
  final _out = StreamController<Envelope>();
  late final StreamSubscription<HostOutbound> _sub;

  @override
  Stream<Envelope> get inbound => _out.stream;

  @override
  bool requestRoll() {
    authority.localRoll();
    return true;
  }

  @override
  bool submit(GameEvent event) {
    authority.localSubmit(event);
    return true;
  }

  /// The host's resync needs no round trip: the authoritative log is right
  /// here, so synthesise the very `welcome` a guest would be sent and let the
  /// ordinary full-replace path rebuild from it.
  @override
  bool resync() {
    if (_out.isClosed) return false;
    _out.add(_welcome());
    return true;
  }

  /// The authority's current state as the guest would be told it.
  ///
  /// `side` names the GUEST's side by protocol convention; the fold ignores it
  /// (the local side is fixed at construction) and reads the log and the resume
  /// token, the latter being what identifies THIS match to the fold.
  WelcomeMessage _welcome() => WelcomeMessage(
        config: authority.config,
        side: authority.guestSide,
        resume: authority.resumeToken,
        log: authority.log,
      );

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _out.close();
  }
}

/// The guest's link over a live [GuestClient].
class _GuestLink implements LanLink {
  _GuestLink(this.client) {
    // SEEDED from the client's running snapshot, not from the welcome frame.
    // `inbound` is broadcast and non-buffering, and the host appends the joined
    // game's opening roll in the same tick it sends the welcome — so between
    // `await client.welcome` and this constructor, that first entry has usually
    // already been published to nobody. [GuestClient.snapshot] carries it; the
    // welcome frame alone would leave the fold one seq behind forever, because
    // nothing further arrives until someone plays.
    final now = client.snapshot;
    if (now != null) _out.add(now);
    _sub = client.inbound.listen((message) {
      if (!_out.isClosed) _out.add(message);
    });
  }

  final GuestClient client;
  final _out = StreamController<Envelope>();
  late final StreamSubscription<Envelope> _sub;

  @override
  Stream<Envelope> get inbound => _out.stream;

  @override
  bool requestRoll() => client.requestRoll();

  @override
  bool submit(GameEvent event) => client.submit(event);

  @override
  bool resync() => client.resync();

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _out.close();
  }
}

/// A [MatchController] driven by a LAN event log — the host's authoritative
/// stream folded into a [Game]/[MatchState], exactly as `OnlineMatchController`
/// folds the Firestore stream.
///
/// ## One fold, both ends
///
/// The host device could simply READ [HostAuthority.game] / [HostAuthority.match]
/// — it owns them. It deliberately does not. Instead it folds the same
/// seq-numbered log the guest folds, through the same code path, differing only
/// in the [LanLink] underneath. That keeps host and guest code identical (one
/// place for the pending-decision notifiers, the [AppliedMove] contract, the
/// game-end pause and the persistence hooks), and it proves the log is
/// sufficient: anything the host can show, a guest folding the same entries can
/// show too.
///
/// ## Folding
///
/// Identical in shape to the online controller:
///
///  * [_game] is `null` until an `openingRoll` folds; each one STARTS a fresh
///    [Game], everything else goes through [Game.append].
///  * [_match] advances locally via [MatchState.applyResult] on a terminal
///    event, and is rebuilt from scratch on a full replace.
///  * [_lastSeq] tracks the last folded seq. Host seqs are contiguous from 1,
///    so `seq <= _lastSeq` is a replay (ignored) and `seq > _lastSeq + 1` is a
///    GAP — events were missed, and the only cure is the whole log.
///
/// ## Resync — the one recovery path
///
/// There is no incremental refetch on the LAN: the protocol's `hello`/`welcome`
/// pair is the only thing that replays history, and EVERY [WelcomeMessage] on
/// the inbound stream means "replace your fold with this log" (a reconnect
/// emits one unprompted). So a gap, a fold that disagrees with the host, and a
/// `reject` whose `lastSeq` is ahead of ours all funnel into [_resync]:
///
///  * guest — re-send `hello`, and fold the welcome that comes back;
///  * host — synthesise the welcome from the authority's log in place.
///
/// A resync REQUEST can itself be lost: `hello` is the one frame that replays
/// the log, so the host spaces it by [LanTimings.helloMinInterval] and silently
/// drops the excess, and a link that is down cannot carry it at all. Waiting for
/// the next entry to ask again is not enough — a peer that is behind AND on turn
/// will never receive another entry — so [_resync] arms a bounded retry chain,
/// cancelled the moment a welcome lands.
///
/// A full replace re-derives EVERYTHING from the log, but must not re-fire
/// history the user has already lived through, so three watermarks survive it:
/// [_persistedThrough] (the last game written to storage), [_matchPersisted]
/// (whether the decided match was written) and [_acknowledgedThrough] (the last
/// game whose game-over dialog was dismissed). They survive a resync of the SAME
/// match only: a welcome bearing a different resume token is a different
/// authority (the host restarted, or a room-code collision put us on someone
/// else's match), and everything remembered about the old one is void — see
/// [_adoptIdentity].
///
/// ## Sending is not delivering
///
/// [GuestClient.send] returns `false` while the link is down, and frames queued
/// on a socket that then drops are DISCARDED rather than replayed — a stale
/// submission must never land after a resync. So an intent that could not be
/// sent leaves the gate OPEN and surfaces a transient [error]: the player
/// simply acts again once the banner clears. An intent that WAS sent latches
/// the gate ([submitting]) until the resulting event folds, a reject answers
/// it, a welcome replaces the fold, or the link drops.
///
/// None of those is guaranteed to happen, though — the host drops frames over
/// its rate limit SILENTLY and the protocol never replays a submission — so the
/// latch also carries a deadline ([_onGateTimeout]). A lost frame costs one
/// timeout and a banner, never the rest of the match.
///
/// ## Known caveat
///
/// The gate is unlatched by the NEXT answer of any kind, not by an answer
/// matched to the intent that latched it — the protocol carries no submission
/// id. So a `reject` still in flight for an earlier action can unlatch a gate
/// latched by a later one, briefly re-enabling controls the log is about to move
/// past. The window is one round trip and the fold stays correct (the authority
/// refuses anything stale), so this is cosmetic; closing it properly means
/// putting a client-side id on `submit`/`roll_request` and echoing it back.
class LanMatchController extends ChangeNotifier implements MatchController {
  /// The HOST's controller: plays through [authority] in-process.
  ///
  /// [guestConnected] is the socket-level presence signal, which the authority
  /// (transport-agnostic by design) cannot know; the screen feeds it from
  /// [HostServer.guestPresence]. Without it [linkStatus] can only report
  /// [GuestConnectionStatus.connecting] until something folds (which proves a
  /// guest is there) and never notices one leaving — so pass it.
  LanMatchController.host({
    required HostAuthority authority,
    this.persistence = const NoopPersistence(),
    ValueListenable<bool>? guestConnected,
  })  : _transport = _HostLink(authority),
        localSide = authority.hostSide,
        _config = authority.config,
        _clocks = LanTimings.defaults,
        _match = MatchState(matchLength: authority.config.length),
        _guestPresence = guestConnected,
        _linkStatusIsDriven = guestConnected != null {
    _listen();
    final presence = _guestPresence;
    if (presence != null) {
      presence.addListener(_onPresence);
      _onPresence();
    }
  }

  /// The GUEST's controller: plays through [client] over the wire.
  ///
  /// The client must already be welcomed (`await client.welcome`) — the
  /// welcome carries the match config and this device's side, and the
  /// controller adopts both. The link then seeds itself from
  /// [GuestClient.snapshot], so however long the caller took to get here, the
  /// log it starts from is the current one.
  LanMatchController.guest({
    required GuestClient client,
    this.persistence = const NoopPersistence(),
  })  : _transport = _GuestLink(client),
        localSide = _welcomeOf(client).side,
        _config = _welcomeOf(client).config,
        _clocks = client.timings,
        _match = MatchState(matchLength: _welcomeOf(client).config.length),
        _guestPresence = null,
        _linkStatusIsDriven = true {
    _listen();
    _linkStatus.value = client.state.status;
    _statusSub = client.states.listen((s) {
      if (_disposed) return;
      _linkStatus.value = s.status;
      if (s.status != GuestConnectionStatus.connected) {
        // A dropped link cannot deliver the answer we were waiting for; open
        // the gate so the player can act again after the resync.
        _submitting = false;
      }
      _notify();
    });
  }

  /// Fold an arbitrary [LanLink]. The two named constructors above are thin
  /// wrappers over this one; a test uses it to drive the recovery paths (seq
  /// gaps, rejects, undeliverable sends) that a healthy socket never produces.
  @visibleForTesting
  LanMatchController.overLink({
    required LanLink link,
    required MatchConfig config,
    required this.localSide,
    this.persistence = const NoopPersistence(),
    LanTimings timings = LanTimings.defaults,
  })  : _transport = link,
        _config = config,
        _clocks = timings,
        _match = MatchState(matchLength: config.length),
        _guestPresence = null,
        _linkStatusIsDriven = false {
    _listen();
  }

  static WelcomeMessage _welcomeOf(GuestClient client) {
    final w = client.lastWelcome;
    if (w == null) {
      throw ArgumentError.value(client, 'client',
          'not welcomed yet — await client.welcome before building the '
              'controller');
    }
    return w;
  }

  final LanLink _transport;

  /// The seat whose decisions are sent; the other side is the peer's.
  final Player localSide;

  final MatchConfig _config;

  /// The transport's clocks — read only for [_resyncRetryDelay], which has to
  /// clear the host's `hello` limiter.
  final LanTimings _clocks;

  /// Persistence seam invoked as the match progresses. Defaults to a no-op; a
  /// failing hook is non-fatal (see [_persist]).
  final MatchPersistence persistence;

  final ValueListenable<bool>? _guestPresence;

  /// True when something else owns [_linkStatus] (the guest client's own state
  /// stream). False means the fold may nudge it — see [_afterFold].
  final bool _linkStatusIsDriven;

  StreamSubscription<GuestConnectionState>? _statusSub;
  StreamSubscription<Envelope>? _sub;

  Game? _game;
  MatchState _match;

  /// The 1-based number of the current game (from the authoritative `gameNo`).
  int _gameNumber = 0;

  /// The last folded seq. Host seqs start at 1, so 0 means "nothing yet".
  int _lastSeq = 0;

  /// The last game whose end was written through [persistence] — so a full
  /// replace does not record a game twice.
  int _persistedThrough = 0;

  /// The last game whose game-over pause the user dismissed — so a full
  /// replace does not re-open a dialog they already closed.
  int _acknowledgedThrough = 0;

  /// Whether the decided match has already been written through
  /// [MatchPersistence.onMatchFinished] — the third watermark a full replace
  /// must carry across (a resync after the last point must not record the
  /// match twice).
  bool _matchPersisted = false;

  /// Which match the watermarks above are ABOUT: the resume token of the
  /// welcome that last replaced the fold. See [_adoptIdentity].
  String? _matchIdentity;

  /// The pending retry of a resync request that may have been dropped, and how
  /// many have been sent for the current divergence. See [_requestResync].
  Timer? _resyncRetry;
  int _resyncAttempts = 0;
  String _resyncReason = '';

  /// How many times one divergence will ask for the log before giving up and
  /// leaving the banner for the user. Five covers a burst of same-second
  /// requests against the host's one-per-second limiter with room to spare.
  static const int _maxResyncAttempts = 5;

  bool _awaitingNextGame = false;
  bool _replacing = false;

  /// Set when a full replace could not fold the host's own log — the one
  /// failure resyncing cannot fix (see [_applyEntry]).
  Object? _replaceFailed;
  bool _disposed = false;
  Object? _error;
  Object? _persistenceError;

  /// Serialises persistence hooks so one game's [MatchPersistence.onGameFinished]
  /// completes before the next (and before [MatchPersistence.onMatchFinished]).
  Future<void> _persistChain = Future<void>.value();

  /// Completes the first time a game folds (so [state]/[game] become safe to
  /// read), or when the controller is disposed before that happens.
  final Completer<void> _ready = Completer<void>();

  /// Events received while paused between games, applied on [continueToNextGame].
  List<LogEntry> _buffer = [];

  // Pending-decision notifiers for the LOCAL side.
  final ValueNotifier<GameState?> _pendingMove = ValueNotifier(null);
  final ValueNotifier<GameState?> _pendingCube = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> _pendingResign =
      ValueNotifier(null);

  // Constant null-valued notifiers returned for the peer's side.
  final ValueNotifier<GameState?> _nullState = ValueNotifier(null);
  final ValueNotifier<(GameState, ResignValue)?> _nullResign =
      ValueNotifier(null);

  /// The last folded move, carrying the board it was applied TO (captured
  /// before the fold) — see [AppliedMove].
  final ValueNotifier<AppliedMove?> _lastMove =
      ValueNotifier<AppliedMove?>(null);

  final ValueNotifier<GuestConnectionStatus> _linkStatus =
      ValueNotifier<GuestConnectionStatus>(GuestConnectionStatus.connecting);

  /// The gate latch, as a notifier so the UI can watch it directly. Backed by
  /// [_submitting], which is what the rest of this class reads and writes.
  final ValueNotifier<bool> _submittingGate = ValueNotifier<bool>(false);

  /// Bounds how long the latch below may last. See [_onGateTimeout].
  Timer? _gateTimer;

  bool get _submitting => _submittingGate.value;

  /// Latching ALWAYS arms the deadline; unlatching always disarms it, however
  /// the answer arrived.
  set _submitting(bool latched) {
    _gateTimer?.cancel();
    _gateTimer = null;
    _submittingGate.value = latched;
    if (latched) _gateTimer = Timer(_clocks.connectTimeout, _onGateTimeout);
  }

  /// Nothing answered an intent that DID leave the device.
  ///
  /// The host drops frames it will not process — over its rate limit, or
  /// arriving on a socket it is about to reap — SILENTLY, by design, and the
  /// protocol never replays a submission. So "wait for the log to answer" is
  /// not on its own a terminating condition, and without this the player's
  /// controls would stay dead for the rest of the match. One connect timeout is
  /// hundreds of times a LAN round trip, so reaching this really does mean the
  /// intent is gone: re-open the gate and say so.
  void _onGateTimeout() {
    if (_disposed || !_submitting) return;
    _submitting = false;
    _error = const LanMatchException(
        'offline', 'the other device did not answer — try again');
    _refreshPending();
    _notify();
  }

  /// How long to wait before asking for the log again. Comfortably past the
  /// host's [LanTimings.helloMinInterval], which is what drops the excess.
  Duration get _resyncRetryDelay => _clocks.helloMinInterval * 1.5;

  void _listen() {
    _sub = _transport.inbound.listen(_onMessage);
  }

  // --- observable state ------------------------------------------------------

  /// The current game's derived state.
  ///
  /// Throws [StateError] until the first opening roll has folded. On the HOST
  /// that is the moment a guest joins (the authority starts game 1 on `hello`),
  /// so the screen must gate on [isReady].
  @override
  GameState get state {
    final g = _game;
    if (g == null) throw StateError('no game has started yet');
    return g.state;
  }

  @override
  MatchState get match => _match;

  @override
  int get gameNumber => _gameNumber;

  @override
  Game get game {
    final g = _game;
    if (g == null) throw StateError('no game has started yet');
    return g;
  }

  /// True once the first opening roll has folded — i.e. [state] and [game] are
  /// safe to read. The UI must not push the game screen until this is true.
  bool get isReady => _game != null;

  /// The last authoritative seq this controller has taken in (folded, or
  /// buffered behind the game-over pause). `0` before the first event. Equal to
  /// [HostAuthority.lastSeq] means "fully caught up".
  int get lastSeq => _lastSeq;

  /// Completes once the controller [isReady], or when it is disposed
  /// beforehand. Callers should `await` this, then check [isReady].
  Future<void> get ready => _ready.future;

  /// The state of the link to the peer, for the UI's connection chip.
  ///
  /// On the guest this is [GuestClient.state] verbatim. On the host it is the
  /// same vocabulary applied to the guest's socket:
  /// [GuestConnectionStatus.connecting] while nobody has ever joined,
  /// [GuestConnectionStatus.connected] while a guest is attached, and
  /// [GuestConnectionStatus.reconnecting] after one has dropped (its client is,
  /// in fact, reconnecting).
  ValueListenable<GuestConnectionStatus> get linkStatus => _linkStatus;

  /// True while a local intent has left the device and the log has not answered
  /// it yet — the "sending…" window, which on a half-open socket can last until
  /// the transport's silence timeout. Exposed as a listenable so the UI can show
  /// progress without polling; [awaitingHumanTurn] and the pending notifiers
  /// already account for it.
  ValueListenable<bool> get submitting => _submittingGate;

  /// The most recently folded move (for the animation layer), or `null`.
  @override
  ValueListenable<AppliedMove?> get lastMove => _lastMove;

  /// True while waiting on the peer (the match is active but it is NOT the
  /// local side's moment to act).
  ///
  /// Deliberately does NOT gate on [error]: a dropped frame is a banner, not a
  /// change of turn.
  @override
  bool get isThinking {
    final g = _game;
    if (g == null || _match.isMatchOver || _awaitingNextGame) return false;
    return !_localActsNow(g.state);
  }

  @override
  Object? get error => _error;

  @override
  Object? get persistenceError => _persistenceError;

  /// Whether the host configured this match without the doubling cube. Unlike
  /// online play the LAN host owns the rules, so the option travels in the
  /// `welcome` and is honoured on both devices.
  @override
  bool get cubeless => _config.cubeless;

  @override
  bool get matchOver => _match.isMatchOver;

  @override
  bool get awaitingNextGame => _awaitingNextGame;

  /// True while the local side's pre-roll gate is open.
  ///
  /// Does NOT gate on [error]: a transient failure must never lock the pre-roll
  /// controls, or one blip would deadlock the loop.
  @override
  bool get awaitingHumanTurn {
    final g = _game;
    if (g == null || _match.isMatchOver || _awaitingNextGame || _submitting) {
      return false;
    }
    final s = g.state;
    return s.turn == localSide && s.phase == GamePhase.awaitingRoll;
  }

  // --- lifecycle -------------------------------------------------------------

  /// No-op beyond marking the loop live: the inbound subscription is attached
  /// in the CONSTRUCTOR, because on the host the guest's `hello` (which starts
  /// game 1) can land before the screen's `initState` runs.
  @override
  Future<void> playMatch() async {}

  @override
  void disposeController() {
    if (_disposed) return;
    _disposed = true;
    // Unblock anyone awaiting readiness; [isReady] stays false so they can bail.
    _completeReady();
    _cancelResyncRetry();
    _gateTimer?.cancel();
    _gateTimer = null;
    _guestPresence?.removeListener(_onPresence);
    unawaited(_statusSub?.cancel());
    _statusSub = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_transport.dispose());
    _pendingMove.dispose();
    _pendingCube.dispose();
    _pendingResign.dispose();
    _nullState.dispose();
    _nullResign.dispose();
    _lastMove.dispose();
    _linkStatus.dispose();
    _submittingGate.dispose();
    super.dispose();
  }

  @override
  void continueToNextGame() {
    if (!_awaitingNextGame) {
      throw StateError('not awaiting the next game');
    }
    _awaitingNextGame = false;
    _acknowledgedThrough = _gameNumber;
    final queued = _buffer;
    _buffer = [];
    for (var i = 0; i < queued.length; i++) {
      // A buffered entry may end another game and re-pause; hold the rest back.
      if (_awaitingNextGame) {
        _buffer.addAll(queued.sublist(i));
        break;
      }
      _applyEntry(queued[i]);
    }
    _afterFold();
  }

  // --- pre-roll verbs --------------------------------------------------------

  @override
  void rollDice() {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    _intend(_transport.requestRoll);
  }

  @override
  void offerDouble() {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    if (cubeless) throw StateError('this match is played without the cube');
    if (!_doublingLegal(state)) {
      throw StateError('doubling is not legal now');
    }
    _submitEvent(DoubleEvent(localSide));
  }

  @override
  void offerResign(ResignValue value) {
    if (!awaitingHumanTurn) throw StateError('not awaiting the human turn');
    _submitEvent(ResignOfferEvent(localSide, value));
  }

  // --- interaction surface ---------------------------------------------------

  @override
  bool isLocalHuman(Player side) => side == localSide;

  @override
  ValueListenable<GameState?> pendingMoveOf(Player side) =>
      side == localSide ? _pendingMove : _nullState;

  @override
  void submitMove(Player side, Move move) {
    _requireLocal(side);
    _submitEvent(MoveEvent(localSide, move));
  }

  @override
  ValueListenable<GameState?> pendingCubeOf(Player side) =>
      side == localSide ? _pendingCube : _nullState;

  @override
  void submitCubeResponse(Player side, CubeAction action) {
    _requireLocal(side);
    _submitEvent(
        action == CubeAction.take ? TakeEvent(localSide) : DropEvent(localSide));
  }

  @override
  ValueListenable<(GameState, ResignValue)?> pendingResignOf(Player side) =>
      side == localSide ? _pendingResign : _nullResign;

  @override
  void submitResignResponse(Player side, bool accept) {
    _requireLocal(side);
    _submitEvent(
        accept ? ResignAcceptEvent(localSide) : ResignDeclineEvent(localSide));
  }

  @override
  MatchContext contextFor(Player actor) {
    final actorScore =
        actor == Player.white ? _match.whiteScore : _match.blackScore;
    final opponentScore =
        actor == Player.white ? _match.blackScore : _match.whiteScore;
    return MatchContext(
      moverAway: _match.matchLength - actorScore,
      opponentAway: _match.matchLength - opponentScore,
      crawfordPlayed: _match.crawfordPlayed,
    );
  }

  // --- inbound ---------------------------------------------------------------

  void _onMessage(Envelope message) {
    if (_disposed) return;
    switch (message) {
      case WelcomeMessage():
        _replaceWith(message);
      case EventMessage(:final entry):
        _ingest(entry);
      case RejectMessage():
        _onReject(message);
      default:
        // ping/pong never reach here; anything else is not ours to fold.
        break;
    }
  }

  /// Fold one authoritative entry, or recognise that we have fallen behind.
  void _ingest(LogEntry entry) {
    if (entry.seq <= _lastSeq) return; // a replay of something already folded
    if (entry.seq > _lastSeq + 1) {
      // A GAP. Nothing incremental can close it — only the whole log can.
      _resync('missed events (seq ${entry.seq} after $_lastSeq)');
      return;
    }
    _lastSeq = entry.seq;
    _submitting = false; // the log moved: whatever we sent has been answered
    if (_awaitingNextGame) {
      _buffer.add(entry);
      return;
    }
    _applyEntry(entry);
  }

  void _applyEntry(LogEntry entry) {
    _gameNumber = entry.gameNo;
    try {
      _fold(entry);
    } on StateError catch (e) {
      if (_replacing) {
        // The AUTHORITATIVE log itself does not fold. Resyncing would fetch the
        // same log again, so stop and surface it rather than spin.
        _replaceFailed = LanMatchException(
            'diverged', 'the host log did not replay: ${e.message}');
        return;
      }
      // Our fold disagrees with the host's ordering — rebuild from the log.
      _resync('local state diverged');
      return;
    }
    if (!_replacing) _afterFold();
  }

  void _fold(LogEntry entry) {
    final event = entry.event;
    if (event is OpeningRollEvent) {
      _game = Game.start(event, isCrawfordGame: _match.isCrawfordNext);
      return;
    }
    // The board the event is about to fold onto — the animation's starting
    // position, knowable only here. See [AppliedMove].
    final preBoard = _game!.state.board;
    final next = _game!.append(event);
    _game = next;
    // NOT published during a full replace: [lastMove] drives a cosmetic
    // animation, and a resync replaying fifty historical moves must snap to the
    // rebuilt position, not re-play the game. (The online controller gets this
    // for free by rebuilding through Game.replay.)
    if (event is MoveEvent && !_replacing) {
      _lastMove.value = AppliedMove(event, preBoard);
    }
    if (next.state.phase != GamePhase.gameOver) return;

    final result = next.state.result!;
    _match = _match.applyResult(result);
    // Persist the JUST-finished game with its COMPLETE log. The watermark keeps
    // a full replace from recording a game a second time.
    if (entry.gameNo > _persistedThrough) {
      _persistedThrough = entry.gameNo;
      _persist(() => persistence.onGameFinished(
            gameNumber: entry.gameNo,
            isCrawford: next.state.isCrawfordGame,
            events: next.events,
            result: result,
            matchAfter: _match,
          ));
    }
    if (_match.isMatchOver) {
      if (!_matchPersisted) {
        _matchPersisted = true;
        _persist(() => persistence.onMatchFinished(_match));
      }
    } else if (entry.gameNo > _acknowledgedThrough) {
      // Pause for the game-over dialog — unless this is a replay of a game the
      // user already dismissed.
      _awaitingNextGame = true;
    }
  }

  /// Replace the whole fold with [welcome]'s log — the meaning of EVERY
  /// `welcome`.
  ///
  /// Replays through the ordinary [_ingest] path from a clean slate, so the
  /// game-end pause and the buffering behave exactly as they do live: a game
  /// that ended while we were away still gets its dialog, and one already
  /// dismissed does not get a second (see [_acknowledgedThrough]).
  void _replaceWith(WelcomeMessage welcome) {
    // The welcome ANSWERED whatever we asked for (or arrived unprompted from a
    // reconnect); either way the retry chain has done its job.
    _cancelResyncRetry();
    _adoptIdentity(welcome.resume);
    final log = welcome.log;
    _replacing = true;
    _replaceFailed = null;
    _match = MatchState(matchLength: _config.length);
    _game = null;
    _gameNumber = 0;
    _lastSeq = 0;
    _buffer = [];
    _awaitingNextGame = false;
    _submitting = false;
    for (final entry in log) {
      _ingest(entry);
    }
    _replacing = false;
    final failure = _replaceFailed;
    if (failure == null) {
      _afterFold();
      return;
    }
    _error = failure;
    if (_game != null) _completeReady();
    _refreshPending();
    _notify();
  }

  void _onReject(RejectMessage reject) {
    _submitting = false;
    if (reject.lastSeq > _lastSeq) {
      // The refusal is a symptom: we are behind, and acted on a stale view.
      _resync('rejected while behind: ${reject.reason}');
      return;
    }
    // Level with the host, so the refusal was about the submission itself. For
    // legal local play this should not happen; surface it and re-open the gate
    // so the player can decide again.
    _error = LanMatchException('rejected', reject.reason);
    _refreshPending();
    _notify();
  }

  /// The identity of the match the watermarks describe.
  ///
  /// A welcome's resume token names the authority that issued it. A DIFFERENT
  /// token on the same controller means we are looking at a different match —
  /// the host restarted and minted a fresh one, or a four-digit room code
  /// collided and we landed on someone else's. Its games have not been
  /// persisted, its dialogs have not been shown, and its game numbers restart at
  /// 1, so every watermark from the old match is void. Carrying them over is how
  /// a second match would silently never be recorded.
  void _adoptIdentity(String? identity) {
    if (identity == null || identity == _matchIdentity) return;
    final hadOne = _matchIdentity != null;
    _matchIdentity = identity;
    if (!hadOne) return; // the first welcome simply names the match
    _persistedThrough = 0;
    _acknowledgedThrough = 0;
    _matchPersisted = false;
  }

  /// Ask for the whole log back. On the host that is synchronous (the log is
  /// in-process); on the guest it is a `hello` whose `welcome` arrives later —
  /// and if the link is down, the reconnect's own welcome does the same job.
  void _resync(String why) {
    if (_disposed) return;
    _resyncReason = why;
    _resyncAttempts = 0;
    _submitting = false;
    _requestResync();
  }

  /// Send one resync request and arm the next.
  ///
  /// The request can be lost two ways, indistinguishable from here: the link is
  /// down (`resync` returns false), or the host's `hello` limiter silently drops
  /// it (`resync` returns true and nothing comes back). Waiting for the next
  /// entry to notice the gap again is NOT a sufficient fallback — a peer that is
  /// behind and on turn receives nothing further, ever — so the chain retries on
  /// its own, spaced past the limiter and bounded by [_maxResyncAttempts].
  /// [_replaceWith] cancels it the moment a welcome lands.
  void _requestResync() {
    _resyncRetry?.cancel();
    _resyncRetry = null;
    if (_disposed) return;
    final sent = _transport.resync();
    _resyncAttempts++;
    _error = sent
        ? LanMatchException('diverged', '$_resyncReason; resyncing')
        : const LanMatchException('offline',
            'not connected to the other device — resyncing when it returns');
    if (_resyncAttempts < _maxResyncAttempts) {
      _resyncRetry = Timer(_resyncRetryDelay, _requestResync);
    }
    _notify();
  }

  void _cancelResyncRetry() {
    _resyncRetry?.cancel();
    _resyncRetry = null;
    _resyncAttempts = 0;
  }

  void _afterFold() {
    // A successful fold proves the stream is healthy again.
    _error = null;
    if (_game != null) _completeReady();
    // Nothing else is reporting the link, and something just folded — which on
    // the host means a guest is there to have caused it. A coarse signal, and
    // the reason [LanMatchController.host] asks for `guestConnected`: without
    // it, nobody ever reports the guest LEAVING.
    if (!_linkStatusIsDriven && _game != null) {
      _linkStatus.value = GuestConnectionStatus.connected;
    }
    _refreshPending();
    _notify();
  }

  /// Recomputes the local-side pending notifiers from the current game state.
  void _refreshPending() {
    final g = _game;
    final active = g != null && !_match.isMatchOver && !_awaitingNextGame;
    final s = g?.state;
    _pendingMove.value =
        (active && s!.phase == GamePhase.moving && s.turn == localSide)
            ? s
            : null;
    _pendingCube.value =
        (active && s!.phase == GamePhase.cubeOffered && s.turn == localSide)
            ? s
            : null;
    _pendingResign.value =
        (active && s!.phase == GamePhase.resignOffered && s.turn == localSide)
            ? (s, s.resignOffer!.value)
            : null;
  }

  void _onPresence() {
    if (_disposed) return;
    final connected = _guestPresence?.value ?? false;
    _linkStatus.value = connected
        ? GuestConnectionStatus.connected
        : (_lastSeq == 0
            ? GuestConnectionStatus.connecting
            : GuestConnectionStatus.reconnecting);
    _notify();
  }

  // --- outbound --------------------------------------------------------------

  void _submitEvent(GameEvent event) => _intend(() => _transport.submit(event));

  /// Express one intent. A send that could not leave the device leaves the gate
  /// OPEN (the player retries); one that left latches it until the log answers.
  void _intend(bool Function() send) {
    if (_submitting || _disposed || _game == null) return;
    if (!send()) {
      _error = const LanMatchException(
          'offline', 'not connected to the other device — try again');
      _notify();
      return;
    }
    _submitting = true;
    _error = null;
    _notify();
  }

  // --- helpers ---------------------------------------------------------------

  void _completeReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  bool _localActsNow(GameState s) {
    switch (s.phase) {
      case GamePhase.awaitingRoll:
      case GamePhase.moving:
      case GamePhase.cubeOffered:
      case GamePhase.resignOffered:
        return s.turn == localSide;
      case GamePhase.gameOver:
        return false;
    }
  }

  bool _doublingLegal(GameState s) =>
      s.phase == GamePhase.awaitingRoll &&
      !s.isCrawfordGame &&
      (s.cube.owner == null || s.cube.owner == s.turn);

  void _requireLocal(Player side) {
    if (side != localSide) {
      throw StateError('$side is not the local side');
    }
  }

  /// Runs a persistence [hook], chained after any in-flight one, swallowing a
  /// failure into [persistenceError] so the fold is never interrupted by the
  /// storage layer.
  void _persist(Future<void> Function() hook) {
    _persistChain = _persistChain.then((_) async {
      if (_disposed) return;
      try {
        await hook();
      } catch (e) {
        _persistenceError = e;
        _notify();
      }
    });
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
