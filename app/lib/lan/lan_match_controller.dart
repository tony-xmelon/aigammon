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
    // Subscribed in the CONSTRUCTOR: `outbound` is a broadcast, non-buffering
    // stream, and the guest's `hello` (which starts game 1) can arrive before
    // anyone calls playMatch. The controller-facing [_out] is
    // single-subscription and therefore buffers until the fold attaches.
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
  ///
  /// `side` names the GUEST's side by protocol convention; the fold ignores it
  /// (the local side is fixed at construction) and reads only the log.
  @override
  bool resync() {
    if (_out.isClosed) return false;
    _out.add(WelcomeMessage(
      config: authority.config,
      side: authority.guestSide,
      log: authority.log,
    ));
    return true;
  }

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _out.close();
  }
}

/// The guest's link over a live [GuestClient].
class _GuestLink implements LanLink {
  _GuestLink(this.client) {
    // The welcome that made this controller constructible was published on the
    // client's broadcast `inbound` before we could subscribe, so replay it —
    // a welcome is idempotent (it REPLACES the fold), and any newer one simply
    // supersedes it.
    final first = client.lastWelcome;
    if (first != null) _out.add(first);
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
/// A full replace re-derives EVERYTHING from the log, but must not re-fire
/// history the user has already lived through, so three watermarks survive it:
/// [_persistedThrough] (the last game written to storage), [_matchPersisted]
/// (whether the decided match was written) and [_acknowledgedThrough] (the last
/// game whose game-over dialog was dismissed).
///
/// ## Sending is not delivering
///
/// [GuestClient.send] returns `false` while the link is down, and frames queued
/// on a socket that then drops are DISCARDED rather than replayed — a stale
/// submission must never land after a resync. So an intent that could not be
/// sent leaves the gate OPEN and surfaces a transient [error]: the player
/// simply acts again once the banner clears. An intent that WAS sent latches
/// the gate ([_submitting]) until the resulting event folds, a reject answers
/// it, a welcome replaces the fold, or the link drops — never indefinitely.
class LanMatchController extends ChangeNotifier implements MatchController {
  /// The HOST's controller: plays through [authority] in-process.
  ///
  /// [guestConnected] is the socket-level presence signal, which the authority
  /// (transport-agnostic by design) cannot know; the screen feeds it from
  /// [HostServer.guestPresence]. Omitted, the link is reported as
  /// [GuestConnectionStatus.connecting] until the first event folds.
  LanMatchController.host({
    required HostAuthority authority,
    this.persistence = const NoopPersistence(),
    ValueListenable<bool>? guestConnected,
  })  : _transport = _HostLink(authority),
        localSide = authority.hostSide,
        _config = authority.config,
        _match = MatchState(matchLength: authority.config.length),
        _guestPresence = guestConnected {
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
  /// controller adopts both. Build the controller as soon as that future
  /// resolves: the link replays the welcome it already holds, so the initial
  /// log is never lost to the broadcast stream.
  LanMatchController.guest({
    required GuestClient client,
    this.persistence = const NoopPersistence(),
  })  : _transport = _GuestLink(client),
        localSide = _welcomeOf(client).side,
        _config = _welcomeOf(client).config,
        _match = MatchState(matchLength: _welcomeOf(client).config.length),
        _guestPresence = null {
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
  })  : _transport = link,
        _config = config,
        _match = MatchState(matchLength: config.length),
        _guestPresence = null {
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

  /// Persistence seam invoked as the match progresses. Defaults to a no-op; a
  /// failing hook is non-fatal (see [_persist]).
  final MatchPersistence persistence;

  final ValueListenable<bool>? _guestPresence;
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

  bool _awaitingNextGame = false;
  bool _submitting = false;
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
      case WelcomeMessage(:final log):
        _replaceWith(log);
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

  /// Replace the whole fold with [log] — the meaning of EVERY `welcome`.
  ///
  /// Replays through the ordinary [_ingest] path from a clean slate, so the
  /// game-end pause and the buffering behave exactly as they do live: a game
  /// that ended while we were away still gets its dialog, and one already
  /// dismissed does not get a second (see [_acknowledgedThrough]).
  void _replaceWith(List<LogEntry> log) {
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

  /// Ask for the whole log back. On the host that is synchronous (the log is
  /// in-process); on the guest it is a `hello` whose `welcome` arrives later —
  /// and if the link is down, the reconnect's own welcome does the same job.
  ///
  /// The request may simply be DROPPED: `hello` is the one frame that replays
  /// the log, so the host spaces it by [LanTimings.helloMinInterval] and
  /// silently discards the excess. That is fine and deliberately not retried on
  /// a timer here — while we are behind, `_lastSeq` never advances, so the very
  /// next entry is another gap and asks again. Turn-based traffic is seconds
  /// apart, so at most a burst is spent before one lands.
  void _resync(String why) {
    if (_disposed) return;
    _error = LanMatchException('diverged', '$why; resyncing');
    _submitting = false;
    _transport.resync();
    _notify();
  }

  void _afterFold() {
    // A successful fold proves the stream is healthy again.
    _error = null;
    if (_game != null) _completeReady();
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
