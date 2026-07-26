import 'dart:io';

import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/lan/lan_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';

/// The room code the socket tests use.
const String testRoomCode = '4271';

/// How a driver chooses the play for the side on turn. Returns [Move.none] when
/// there is nothing to play (a dance).
typedef MovePicker = Move Function(GameState state);

/// The default driver: the first legal play the generator offers.
Move greedyFirstMove(GameState state) {
  final legal = state.legalMoves;
  return legal.isEmpty ? Move.none : legal.first;
}

/// A driver that PRIMES: of the legal plays it takes the one that makes the
/// most home-board points and keeps the most opposing checkers on the bar.
///
/// Deterministic like [greedyFirstMove], but unlike it this one actually shuts
/// a board — which is the only way a scripted playout reaches a DANCE without
/// hand-building a position. See `lan_full_match_test.dart`.
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

/// Everything two folds of one log must agree on, as one comparable string:
/// the position (points, bars, borne-off), whose turn it is, the phase, the
/// dice on the table, the cube, Crawford, any pending resignation — plus the
/// match score and game number the fold derived.
///
/// Comparing this on both devices after every exchange is what "converged"
/// means in the integration test: not merely the same seq, but the same GAME.
String positionSignature(LanMatchController c) {
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

/// A [MatchPersistence] that records every hook call, so a test can assert
/// onGameFinished fired ONCE per finished game (with the full event log and the
/// folded result) and onMatchFinished at match end.
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

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {
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

/// Poll until [condition] holds, or fail loudly. Sockets and timers make the
/// exact instant unpredictable, so every asynchronous assertion goes through
/// here rather than through a fixed sleep.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A fresh authority with deterministic dice and a token a test can predict.
HostAuthority newAuthority({
  int length = 1,
  bool cubeless = false,
  Player hostSide = Player.white,
  List<Dice> dice = const [],
}) =>
    HostAuthority(
      config: MatchConfig(length: length, cubeless: cubeless),
      hostSide: hostSide,
      dice: ScriptedDiceRoller(dice),
      resumeToken: 'TESTTOKEN',
    );

/// Start the match the way a joining guest does.
void guestHello(HostAuthority authority, {String name = 'Bo'}) =>
    authority.onGuestMessage(HelloMessage(name: name));

/// Act for whichever side is on turn STRAIGHT INTO [authority] — the headless
/// opponent the host-side tests play against, and the engine behind
/// [authorityLog].
///
/// [side] names the seat to act for; the caller is responsible for it being that
/// seat's turn. Guest actions travel the guest inbox (so they take the real
/// validation path), host actions the local verbs.
void actInAuthority(
  HostAuthority authority,
  Player side, {
  CubeAction cubeResponse = CubeAction.take,
  bool acceptResign = true,
}) {
  final state = authority.state!;
  final isHost = side == authority.hostSide;
  void deliver(GameEvent event) {
    if (isHost) {
      authority.localSubmit(event);
    } else {
      authority.onGuestMessage(SubmitMessage(event));
    }
  }

  switch (state.phase) {
    case GamePhase.awaitingRoll:
      if (isHost) {
        authority.localRoll();
      } else {
        authority.onGuestMessage(const RollRequestMessage());
      }
    case GamePhase.moving:
      final legal = state.legalMoves;
      deliver(MoveEvent(side, legal.isEmpty ? Move.none : legal.first));
    case GamePhase.cubeOffered:
      deliver(cubeResponse == CubeAction.take ? TakeEvent(side) : DropEvent(side));
    case GamePhase.resignOffered:
      deliver(acceptResign ? ResignAcceptEvent(side) : ResignDeclineEvent(side));
    case GamePhase.gameOver:
      throw StateError('nothing to do in the gameOver phase');
  }
}

/// Play a whole match head-on inside one [HostAuthority] (no controller, no
/// transport) and return its authoritative log — the fixture the fold tests
/// replay. Stops early once the log reaches [maxEntries] entries.
List<LogEntry> authorityLog({
  int length = 1,
  Player hostSide = Player.white,
  int maxEntries = 1 << 30,
}) {
  final authority = newAuthority(length: length, hostSide: hostSide);
  guestHello(authority);
  var guard = 0;
  while (!authority.matchOver && authority.log.length < maxEntries) {
    if (guard++ > 20000) {
      throw StateError('authority playout did not terminate');
    }
    actInAuthority(authority, authority.state!.turn);
  }
  final log = authority.log;
  authority.close();
  return log.length <= maxEntries ? log : log.sublist(0, maxEntries);
}

/// Act for [controller]'s own side, whatever the phase asks for. Mirrors what
/// the game screen's controls would do.
void actInController(
  LanMatchController controller, {
  CubeAction cubeResponse = CubeAction.take,
  bool acceptResign = true,
  MovePicker pickMove = greedyFirstMove,
}) {
  final side = controller.localSide;
  final state = controller.state;
  switch (state.phase) {
    case GamePhase.awaitingRoll:
      controller.rollDice();
    case GamePhase.moving:
      controller.submitMove(side, pickMove(state));
    case GamePhase.cubeOffered:
      controller.submitCubeResponse(side, cubeResponse);
    case GamePhase.resignOffered:
      controller.submitResignResponse(side, acceptResign);
    case GamePhase.gameOver:
      throw StateError('nothing to do in the gameOver phase');
  }
}

/// Both controllers over REAL loopback sockets: a [HostServer] wired to a
/// [HostAuthority] the host's controller folds in process, and a [GuestClient]
/// whose controller folds the same log off the wire.
///
/// Loopback deliberately (never `anyIPv4`): a test run must not raise a
/// firewall prompt. [LanTimings.test] compresses every clock so a whole
/// drop-and-reconnect cycle fits inside a test.
class LanPair {
  LanPair._(this.authority, this.server, this.client, this.host, this.guest,
      this.hostPersistence, this.guestPersistence, this._presence);

  static Future<LanPair> start({
    int length = 1,
    bool cubeless = false,
    Player hostSide = Player.white,
    MovePicker pickMove = greedyFirstMove,
  }) async {
    final authority =
        newAuthority(length: length, cubeless: cubeless, hostSide: hostSide);
    final server = await HostServer.start(
      port: 0,
      authority: authority,
      roomCode: testRoomCode,
      timings: LanTimings.test,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    final presence = ValueNotifier<bool>(false);
    server.guestPresence.listen((present) => presence.value = present);

    final hostPersistence = RecordingPersistence();
    final host = LanMatchController.host(
      authority: authority,
      persistence: hostPersistence,
      guestConnected: presence,
    );
    await host.playMatch();

    final client = GuestClient.connect(
      InternetAddress.loopbackIPv4.address,
      server.port,
      roomCode: testRoomCode,
      name: 'Bo',
      timings: LanTimings.test,
    );
    final welcomes = <WelcomeMessage>[];
    final seqs = <int>[];
    client.inbound.listen((m) {
      if (m is WelcomeMessage) welcomes.add(m);
      if (m is EventMessage) seqs.add(m.entry.seq);
    });
    await client.welcome;

    final guestPersistence = RecordingPersistence();
    final guest = LanMatchController.guest(
      client: client,
      persistence: guestPersistence,
    );
    await guest.playMatch();

    final pair = LanPair._(authority, server, client, host, guest,
        hostPersistence, guestPersistence, presence)
      .._welcomes = welcomes
      .._guestSeqs = seqs
      ..pickMove = pickMove;
    await waitFor(() => host.isReady && guest.isReady,
        what: 'both controllers to fold game 1');
    return pair;
  }

  final HostAuthority authority;
  final HostServer server;
  final GuestClient client;
  final LanMatchController host;
  final LanMatchController guest;
  final RecordingPersistence hostPersistence;
  final RecordingPersistence guestPersistence;
  final ValueNotifier<bool> _presence;
  late final List<WelcomeMessage> _welcomes;
  late final List<int> _guestSeqs;

  /// How the driver plays a turn. Swap it for [primingMove] when the test needs
  /// a game that actually develops — and therefore dances.
  MovePicker pickMove = greedyFirstMove;

  /// How many `welcome` frames the guest has seen. The first is the handshake;
  /// every later one is a full resync.
  int get welcomes => _welcomes.length;

  /// Every `event` seq the GUEST took off the wire, in arrival order — the raw
  /// material for a contiguity assertion.
  List<int> get guestEventSeqs => List.unmodifiable(_guestSeqs);

  bool _disposed = false;

  /// Tear the whole rig down, innermost first. Idempotent, so a test may
  /// dispose explicitly (to assert the teardown itself is clean) and still
  /// register this as a safety net.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    host.disposeController();
    guest.disposeController();
    await client.dispose();
    await server.stop();
    authority.close();
    _presence.dispose();
  }

  /// Both controllers have taken in everything the authority has assigned.
  bool get converged =>
      host.lastSeq == authority.lastSeq && guest.lastSeq == authority.lastSeq;

  Future<void> settleFold() => waitFor(() => converged,
      what: 'both folds to reach seq ${authority.lastSeq}');

  /// Bring both folds level with the authority and dismiss any game-over pause
  /// on either device — the caller's precondition for reading either state.
  Future<void> sync() async {
    await settleFold();
    if (host.awaitingNextGame) host.continueToNextGame();
    if (guest.awaitingNextGame) guest.continueToNextGame();
  }

  /// True when [c] may act right now — its turn, and no intent in flight.
  static bool canAct(LanMatchController c) {
    if (!c.isReady || c.matchOver || c.awaitingNextGame) return false;
    if (c.state.turn != c.localSide) return false;
    return c.state.phase == GamePhase.awaitingRoll
        ? c.awaitingHumanTurn
        : !c.submitting.value;
  }

  /// The controller whose side is on turn, and its peer.
  LanMatchController get onTurn =>
      host.state.turn == host.localSide ? host : guest;
  LanMatchController get offTurn => identical(onTurn, host) ? guest : host;

  /// Play one authoritative event, acting through whichever CONTROLLER owns the
  /// side on turn — the host in process, the guest over the socket.
  ///
  /// RE-ACTS if the log does not move. A frame really can vanish (the host
  /// silently drops anything over its rate limit, and a blip discards whatever
  /// was queued), the protocol never replays a submission, and the controller's
  /// answer to that is to re-open the gate — so a player, and therefore this
  /// driver, simply acts again. Without the retry a lost frame would show up as
  /// a mystery timeout rather than the recoverable event it is.
  Future<void> step() async {
    await sync();
    final actor = onTurn;
    final before = authority.lastSeq;
    for (var attempt = 1; attempt <= 5; attempt++) {
      actInController(actor, pickMove: pickMove);
      try {
        await waitFor(() => authority.lastSeq > before,
            timeout: const Duration(seconds: 1),
            what: 'seq to pass $before (${actor.localSide.name})');
        return;
      } on StateError {
        // The gate re-opens on its own deadline; wait for it, then act again.
        await waitFor(() => canAct(actor),
            what: 'the gate to re-open for a retry '
                '(attempt $attempt, seq $before)');
      }
    }
    fail('five attempts did not move the log past $before');
  }

  /// Step until [done] holds with both folds settled. Deliberately re-syncs
  /// BEFORE testing [done], so a gate the test is waiting for is never consumed
  /// by one step too many.
  Future<void> advanceUntil(
    bool Function() done, {
    int maxSteps = 400,
    String what = 'the condition',
  }) async {
    var guard = 0;
    while (true) {
      await sync();
      if (done()) return;
      if (guard++ > maxSteps) fail('never reached $what');
      if (authority.matchOver) fail('the match ended before $what');
      await step();
    }
  }

  /// Drive the whole match out through both controllers.
  Future<void> playOut({int maxSteps = 3000}) async {
    var guard = 0;
    while (!authority.matchOver) {
      if (guard++ > maxSteps) fail('the match did not terminate');
      await step();
    }
    await sync();
  }
}
