/// The rig the unified-controller suite runs on: two [NetMatchController]s over
/// one [InMemoryBackend], a fault-injecting transport proxy, and the assertion
/// helpers ported from BOTH shipped suites (`fake_online_backend`'s recording
/// persistence + play-out driver, `lan_harness`'s [positionSignature] convergence
/// idea and priming driver).
library;

import 'dart:async';
import 'dart:math';

import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/game/player_agent.dart' show CubeAction;
import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:match_transport/match_transport.dart';
import 'package:match_transport/testing.dart';

// ---------------------------------------------------------------------------
// Persistence recorder
// ---------------------------------------------------------------------------

/// A [MatchPersistence] that records every hook call, so a test can assert
/// onGameFinished fired ONCE per finished game (with the full event log and the
/// folded result) and onMatchFinished once at match end. [throwOnGame] scripts a
/// single non-fatal onGameFinished failure for that game number.
class RecordingPersistence implements MatchPersistence {
  final List<
      ({
        int gameNumber,
        bool isCrawford,
        List<GameEvent> events,
        GameResult result,
        MatchState matchAfter,
      })> games = [];
  int matchFinishedCalls = 0;
  MatchState? finalState;
  int throwOnGame = -1;

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {
    if (gameNumber == throwOnGame) {
      throw StateError('scripted persistence failure');
    }
    games.add((
      gameNumber: gameNumber,
      isCrawford: isCrawford,
      events: events,
      result: result,
      matchAfter: matchAfter,
    ));
  }

  @override
  Future<void> onMatchFinished(MatchState finalState) async {
    matchFinishedCalls++;
    this.finalState = finalState;
  }
}

// ---------------------------------------------------------------------------
// Convergence
// ---------------------------------------------------------------------------

/// Everything two folds of one log must agree on, as one comparable string: the
/// position (points, bars, borne-off), whose turn it is, the phase, the dice on
/// the table, the cube, Crawford, any pending resignation — plus the match score
/// and game number the fold derived.
///
/// Comparing this on both devices after every exchange is what "converged" means
/// here: not merely the same seq, but the same GAME. (Ported verbatim in spirit
/// from `lan_harness.positionSignature`.)
String positionSignature(NetMatchController c) {
  final s = c.state;
  final b = s.board;
  final m = c.match;
  final resign = s.resignOffer;
  return [
    b.points.join(','),
    'bar:${b.whiteBar}/${b.blackBar}',
    'off:${b.whiteOff}/${b.blackOff}',
    'turn:${s.turn.name}',
    'phase:${s.phase.name}',
    'dice:${s.dice?.die1}-${s.dice?.die2}',
    'cube:${s.cube.value}@${s.cube.owner?.name}',
    'crawford:${s.isCrawfordGame}',
    'resign:${resign?.by.name}/${resign?.value.name}',
    'score:${m.whiteScore}-${m.blackScore}/${m.matchLength}',
    'over:${m.isMatchOver}',
    'game:${c.gameNumber}',
  ].join('|');
}

// ---------------------------------------------------------------------------
// Async helpers
// ---------------------------------------------------------------------------

/// Yields to the event loop [times] times, letting the transport's microtask
/// flushes and the controller's async chains run to completion.
Future<void> settle([int times = 24]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pumps the event loop until [done], failing with [reason] if it never becomes
/// true. Everything here is real-async but zero-delay, so this converges fast.
Future<void> pumpUntil(bool Function() done,
    {int rounds = 6000, String reason = 'condition never became true'}) async {
  for (var i = 0; i < rounds; i++) {
    if (done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(reason);
}

/// Like [pumpUntil] but lets REAL time pass, for the timer-backed behaviours
/// (the gate deadline, the paced backoff).
Future<void> waitFor(bool Function() done,
    {Duration timeout = const Duration(seconds: 10),
    String what = 'condition'}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

// ---------------------------------------------------------------------------
// Drivers
// ---------------------------------------------------------------------------

/// How a driver chooses the play for the side on turn. Returns [Move.none] when
/// there is nothing to play (a dance).
typedef MovePicker = Move Function(GameState state);

/// The default driver: the first legal play the generator offers.
Move greedyFirstMove(GameState state) {
  final legal = state.legalMoves;
  return legal.isEmpty ? Move.none : legal.first;
}

/// A driver that PRIMES: of the legal plays it takes the one that makes the most
/// home-board points and keeps the most opposing checkers on the bar.
///
/// Deterministic like [greedyFirstMove], but unlike it this one actually shuts a
/// board — which is the only way a scripted playout reaches a DANCE without
/// hand-building a position.
Move primingMove(GameState state) {
  final legal = state.legalMoves;
  if (legal.isEmpty) return Move.none;
  final side = state.turn;
  var best = legal.first;
  var bestScore = _primeScore(state, best, side);
  for (final move in legal.skip(1)) {
    final score = _primeScore(state, move, side);
    if (score > bestScore) {
      best = move;
      bestScore = score;
    }
  }
  return best;
}

int _primeScore(GameState state, Move move, Player side) {
  final board = state.board.applyMove(side, move);
  var made = 0;
  if (side == Player.white) {
    for (var i = 0; i < 6; i++) {
      if (board.points[i] >= 2) made++;
    }
  } else {
    for (var i = 18; i < 24; i++) {
      if (board.points[i] <= -2) made++;
    }
  }
  return made * 4 + board.barFor(side.opponent) * 3;
}

// ---------------------------------------------------------------------------
// Fault-injecting transport proxy
// ---------------------------------------------------------------------------

/// A [MatchTransport] that forwards everything to an [InMemoryTransport] while
/// letting a test break it in the ways only a real network can.
///
/// The fold's recovery paths — a frame the relay drops, a write that lost the
/// seq race, a read blip, a committed submission whose echo never arrives — are
/// exactly the ones a healthy pipe never produces, so provoking them through the
/// backend would be a race. Here they are one field each.
class ProxyTransport implements MatchTransport {
  ProxyTransport(this.inner);

  final InMemoryTransport inner;

  /// Event seqs whose inbound frame is SWALLOWED (once each) — the relay losing
  /// a frame, which the fold must notice as a gap.
  final Set<int> dropEventSeqs = {};

  /// When true, [sendEvent] resolves normally WITHOUT writing: the caller's await
  /// says "committed", nothing ever echoes back. The silently-dropped
  /// submission the gate deadline exists for.
  bool swallowSends = false;

  /// Called before every forwarded operation; a non-null return is thrown
  /// instead. Operation names are the method names.
  Object? Function(String op)? intercept;

  /// Per-operation call counts, for assertions.
  final Map<String, int> calls = {};

  void _tick(String op) {
    calls[op] = (calls[op] ?? 0) + 1;
    final failure = intercept?.call(op);
    if (failure != null) throw failure;
  }

  @override
  Stream<InboundFrame> get inbound => inner.inbound.where((f) {
        if (f is EventFrame && dropEventSeqs.remove(f.seq)) return false;
        return true;
      });

  @override
  Future<TransportSession> connect() async {
    _tick('connect');
    return inner.connect();
  }

  @override
  Future<void> sendEvent({
    required int seq,
    required int gameNo,
    required GameEvent event,
  }) async {
    _tick('sendEvent');
    if (swallowSends) return;
    return inner.sendEvent(seq: seq, gameNo: gameNo, event: event);
  }

  @override
  Future<void> createRoll(int n, String commit) async {
    _tick('createRoll');
    return inner.createRoll(n, commit);
  }

  @override
  Future<void> sendEntropy(int n, String entropy) async {
    _tick('sendEntropy');
    return inner.sendEntropy(n, entropy);
  }

  @override
  Future<void> sendReveal(int n, String reveal) async {
    _tick('sendReveal');
    return inner.sendReveal(n, reveal);
  }

  @override
  Future<List<EventFrame>> eventsSince(int afterSeq) async {
    _tick('eventsSince');
    return inner.eventsSince(afterSeq);
  }

  @override
  Future<RollFrame?> fetchRoll(int n) async {
    _tick('fetchRoll');
    return inner.fetchRoll(n);
  }

  @override
  Future<List<RollFrame>> rollsSince(int from) async {
    _tick('rollsSince');
    return inner.rollsSince(from);
  }

  @override
  Future<void> complete() async {
    _tick('complete');
    return inner.complete();
  }

  @override
  Stream<TransportStatusEvent> get statusStream => inner.statusStream;

  @override
  TransportStatus get status => inner.status;

  @override
  String? get statusReason => inner.statusReason;

  @override
  bool get opponentPresent => inner.opponentPresent;

  @override
  Stream<bool> get opponentPresence => inner.opponentPresence;

  @override
  Capabilities get capabilities => inner.capabilities;

  @override
  Duration get inboundCadence => inner.inboundCadence;

  /// The last pace hint the controller sent, or null if it never sent one. The
  /// controller only sends on a CHANGE, so this is the current hint.
  bool? paceFast;

  @override
  void setPaceHint({required bool fast}) {
    paceFast = fast;
    inner.setPaceHint(fast: fast);
  }

  @override
  Future<void> dispose() => inner.dispose();

  // --- passthrough test controls --------------------------------------------

  void simulateDrop([String reason = 'link dropped']) =>
      inner.simulateDrop(reason);
  void simulateReconnect() => inner.simulateReconnect();
  void simulateReset({String reason = 'reconnected'}) =>
      inner.simulateReset(reason: reason);
  void injectFrame(InboundFrame frame) => inner.injectFrame(frame);
  void simulateInboundError([
    TransportException error =
        const TransportUnavailable('read-failed', 'transient read failure'),
  ]) =>
      inner.simulateInboundError(error);
}

// ---------------------------------------------------------------------------
// One live controller against a scripted opponent
// ---------------------------------------------------------------------------

/// A single live controller (the GUEST seat by default) whose opponent is
/// scripted straight into the backend — the shape every adversarial case wants,
/// because a forged event has no honest peer to write it.
class ScriptedRig {
  ScriptedRig._(this.backend, this.transport, this.controller, this.persistence);

  static Future<ScriptedRig> guest({
    int length = 3,
    bool cubeless = false,
    int? openingWhiteDie,
    int? openingBlackDie,
    Duration gateTimeout = const Duration(seconds: 30),
    bool registerOpponentEndpoint = true,
    void Function(InMemoryBackend backend)? seed,
  }) =>
      _start(
        host: false,
        length: length,
        cubeless: cubeless,
        openingWhiteDie: openingWhiteDie,
        openingBlackDie: openingBlackDie,
        gateTimeout: gateTimeout,
        registerOpponentEndpoint: registerOpponentEndpoint,
        seed: seed,
      );

  static Future<ScriptedRig> host({
    int length = 3,
    bool cubeless = false,
    int? openingWhiteDie,
    int? openingBlackDie,
    Duration gateTimeout = const Duration(seconds: 30),
    bool registerOpponentEndpoint = true,
    void Function(InMemoryBackend backend)? seed,
  }) =>
      _start(
        host: true,
        length: length,
        cubeless: cubeless,
        openingWhiteDie: openingWhiteDie,
        openingBlackDie: openingBlackDie,
        gateTimeout: gateTimeout,
        registerOpponentEndpoint: registerOpponentEndpoint,
        seed: seed,
      );

  static Future<ScriptedRig> _start({
    required bool host,
    required int length,
    required bool cubeless,
    required int? openingWhiteDie,
    required int? openingBlackDie,
    required Duration gateTimeout,
    required bool registerOpponentEndpoint,
    void Function(InMemoryBackend backend)? seed,
  }) async {
    final backend =
        InMemoryBackend(config: MatchConfig(length: length, cubeless: cubeless));
    if (openingWhiteDie != null && openingBlackDie != null) {
      backend.seedOpening(whiteDie: openingWhiteDie, blackDie: openingBlackDie);
    }
    // Anything the test needs to PRE-EXIST — i.e. to be there before the
    // controller ever primes, and so to fall at or below its roll floor. That is
    // the only way to script an AIMED opponent roll (which needs both secrets
    // chosen together, the witness's included): a roll created mid-match would be
    // one the controller is the live witness of, and entropy it did not itself
    // contribute is a proven forgery there. See `_witnessEntropyFailure`.
    seed?.call(backend);
    // The opponent's endpoint exists but is never folded — it is what makes
    // `opponentPresent` true, exactly as the absent peer's socket/uid would.
    if (registerOpponentEndpoint) {
      final peer = host
          ? InMemoryTransport.guest(backend)
          : InMemoryTransport.host(backend);
      addTearDown(peer.dispose);
    }
    final transport = ProxyTransport(
        host ? InMemoryTransport.host(backend) : InMemoryTransport.guest(backend));
    final rec = RecordingPersistence();
    final c = NetMatchController(
      transport: transport,
      persistence: rec,
      gateTimeout: gateTimeout,
      rng: Random(host ? 101 : 202),
    );
    addTearDown(c.disposeController);
    await c.playMatch();
    return ScriptedRig._(backend, transport, c, rec);
  }

  final InMemoryBackend backend;
  final ProxyTransport transport;
  final NetMatchController controller;
  final RecordingPersistence persistence;

  String get localAuthor => controller.session.localAuthor;
  String get peerAuthor =>
      controller.isHost ? backend.guestAuthor : backend.hostAuthor;

  /// The seq the next forged event must claim.
  int get nextSeq => backend.nextSeq;

  /// A mirror of the log's game, for choosing a legal play for the scripted
  /// opponent.
  Game mirrorGame() {
    final events = backend.events.map((e) => e.event).toList();
    final start = events.lastIndexWhere((e) => e is OpeningRollEvent);
    return Game.replay(events.sublist(start));
  }

  /// Forge one event for the scripted opponent, with NO validation — what a
  /// hacked client would write.
  void forge(GameEvent event, {String? author, int? gameNo, int? seq}) =>
      backend.appendEvent(
        author: author ?? peerAuthor,
        seq: seq ?? backend.nextSeq,
        gameNo: gameNo ?? (controller.gameNumber == 0 ? 1 : controller.gameNumber),
        event: event,
      );

  /// Play the opponent's whole turn from a roll document that was PRE-SEEDED (see
  /// the `seed` hook and [InMemoryBackend.seedRollDoc]): append the [RollEvent]
  /// the document derives, then the opponent's first legal move.
  ///
  /// The two-step shape exists because an aimed opponent roll cannot be created
  /// mid-match any more: choosing the roller's secret together with the witness's
  /// entropy IS the dice-substitution attack, and a live witness now freezes on
  /// it. Seeded before the controller connects, the document is below its roll
  /// floor and legitimately taken as found.
  void scriptSeededTurn() {
    final n = controller.rollCount + 1;
    final doc = backend.fetchRoll(n);
    if (doc == null || !doc.isComplete) {
      throw StateError('no complete pre-seeded roll document at index $n');
    }
    final dice = doc.completed!.dice;
    final side = controller.localSide.opponent;
    forge(RollEvent(side, dice.die1, dice.die2));
    final legal = mirrorGame().state.legalMoves;
    forge(MoveEvent(side, legal.isEmpty ? Move.none : legal.first));
  }

  /// Play the scripted opponent's whole turn: a sound roll plus its first legal
  /// move.
  void scriptTurn({required int die1, required int die2}) {
    final side = controller.localSide.opponent;
    backend.seedRoll(
      author: peerAuthor,
      player: side,
      die1: die1,
      die2: die2,
      gameNo: controller.gameNumber == 0 ? 1 : controller.gameNumber,
    );
    // [seedRoll] already appended the RollEvent, so the mirror carries it.
    final legal = mirrorGame().state.legalMoves;
    forge(MoveEvent(side, legal.isEmpty ? Move.none : legal.first));
  }
}

// ---------------------------------------------------------------------------
// Two live controllers, one backend
// ---------------------------------------------------------------------------

/// Both peers of a match, each a real [NetMatchController], over one
/// [InMemoryBackend] — the merged replacement for `lan_harness.LanPair` and the
/// online suite's `pair()`.
class NetPair {
  NetPair._(this.backend, this.host, this.guest, this.hostPersistence,
      this.guestPersistence, this.hostTransport, this.guestTransport);

  static Future<NetPair> start({
    int length = 3,
    bool cubeless = false,
    MovePicker pickMove = greedyFirstMove,
    Duration gateTimeout = const Duration(seconds: 60),
  }) async {
    final backend =
        InMemoryBackend(config: MatchConfig(length: length, cubeless: cubeless));
    final hostRec = RecordingPersistence();
    final guestRec = RecordingPersistence();
    // Both seats go through a [ProxyTransport] — a faithful passthrough unless a
    // test arms one of its knobs — so a two-controller test can break ONE side's
    // pipe (a refused write, a dropped frame) or read back the pace hint,
    // exactly as the single-controller rig can.
    final hostTransport = ProxyTransport(InMemoryTransport.host(backend));
    final guestTransport = ProxyTransport(InMemoryTransport.guest(backend));
    final host = NetMatchController(
      transport: hostTransport,
      persistence: hostRec,
      gateTimeout: gateTimeout,
      rng: Random(101),
    );
    final guest = NetMatchController(
      transport: guestTransport,
      persistence: guestRec,
      gateTimeout: gateTimeout,
      rng: Random(202),
    );
    addTearDown(host.disposeController);
    addTearDown(guest.disposeController);
    final pair = NetPair._(backend, host, guest, hostRec, guestRec,
        hostTransport, guestTransport)
      ..pickMove = pickMove;
    await host.playMatch();
    await guest.playMatch();
    await pumpUntil(() => host.isReady && guest.isReady,
        reason: 'the host never made an opening roll both sides could fold');
    return pair;
  }

  final InMemoryBackend backend;
  final NetMatchController host;
  final NetMatchController guest;
  final RecordingPersistence hostPersistence;
  final RecordingPersistence guestPersistence;

  /// Each seat's pipe, for the tests that need to break one.
  final ProxyTransport hostTransport;
  final ProxyTransport guestTransport;

  MovePicker pickMove = greedyFirstMove;

  /// Cube responses the driver gives, in order; the last one repeats.
  List<CubeAction> cubeResponses = [CubeAction.take];

  /// Whether the driver accepts a resignation offer.
  bool acceptResign = true;

  /// Game-over pauses seen, per controller.
  int pauses = 0;

  final Map<NetMatchController, GameState?> _lastActed = {};

  /// One decision for [c], deduplicated by [GameState] identity so a submission
  /// that has not been echoed back yet is never re-issued.
  void act(NetMatchController c, {void Function(NetMatchController)? onGameOver}) {
    if (c.matchOver || c.frozen) return;
    if (c.awaitingNextGame) {
      onGameOver?.call(c);
      pauses++;
      c.continueToNextGame();
      _lastActed[c] = null;
      return;
    }
    if (!c.isReady) return;
    final GameState s;
    try {
      s = c.state;
    } on StateError {
      return;
    }
    if (identical(s, _lastActed[c])) return;
    final side = c.localSide;
    if (c.pendingCubeOf(side).value != null) {
      final response =
          cubeResponses.isEmpty ? CubeAction.take : cubeResponses.first;
      if (cubeResponses.length > 1) cubeResponses.removeAt(0);
      c.submitCubeResponse(side, response);
    } else if (c.pendingResignOf(side).value != null) {
      c.submitResignResponse(side, acceptResign);
    } else if (c.pendingMoveOf(side).value != null) {
      c.submitMove(side, pickMove(s));
    } else if (c.awaitingHumanTurn) {
      c.rollDice();
    }
    _lastActed[c] = s;
  }

  /// True when both folds are level with the log and neither is paused — the only
  /// moment their signatures are comparable.
  bool get _comparable =>
      host.isReady &&
      guest.isReady &&
      !host.awaitingNextGame &&
      !guest.awaitingNextGame &&
      host.lastSeq == backend.events.length &&
      guest.lastSeq == backend.events.length;

  /// CONVERGENCE: after every exchange, if both folds are level they must agree
  /// on the whole game, not merely on the seq.
  void checkConverged() {
    if (!_comparable) return;
    expect(positionSignature(host), positionSignature(guest),
        reason: 'the two folds of one log diverged at seq ${host.lastSeq}');
  }

  /// Drives both controllers until the match is decided, asserting convergence
  /// after every exchange.
  Future<void> playOut({
    void Function(NetMatchController)? onGameOver,
    int maxIters = 60000,
  }) async {
    var iters = 0;
    while (!(host.matchOver && guest.matchOver)) {
      if (host.frozen || guest.frozen) {
        fail('a controller froze mid-match: '
            '${host.cheatError ?? guest.cheatError}');
      }
      if (++iters > maxIters) {
        fail('the match did not finish in $maxIters iterations '
            '(host: over=${host.matchOver} ready=${host.isReady} '
            'err=${host.error}; guest: over=${guest.matchOver} '
            'ready=${guest.isReady} err=${guest.error})');
      }
      act(host, onGameOver: onGameOver);
      act(guest, onGameOver: onGameOver);
      await Future<void>.delayed(Duration.zero);
      checkConverged();
    }
    await settle();
  }

  /// Step both controllers until [done] holds, asserting convergence throughout.
  Future<void> advanceUntil(bool Function() done,
      {int maxIters = 60000, String what = 'the condition'}) async {
    var iters = 0;
    while (!done()) {
      if (host.frozen || guest.frozen) {
        fail('a controller froze before $what: '
            '${host.cheatError ?? guest.cheatError}');
      }
      if (host.matchOver && guest.matchOver) fail('the match ended before $what');
      if (++iters > maxIters) fail('never reached $what');
      act(host);
      act(guest);
      await Future<void>.delayed(Duration.zero);
      checkConverged();
    }
  }

  /// The controller whose side is on turn, and its peer.
  NetMatchController get onTurn =>
      host.state.turn == host.localSide ? host : guest;
  NetMatchController get offTurn => identical(onTurn, host) ? guest : host;
}
