/// The rig the LAN integration suite runs on: two [NetMatchController]s over a
/// REAL loopback WebSocket pair.
///
/// Nothing is faked below the controllers — an [HttpServer] upgrading a socket, a
/// [MatchRelay] holding the log, a [GuestClient] reconnecting on its own timers,
/// and the commit-reveal dice handshake travelling over the wire in both
/// directions. The fold-level unit work lives in `app/test/net/` against the
/// in-memory transport; what this rig is for is the property the whole design
/// rests on — *the log is sufficient*.
///
/// The assertion helpers ([positionSignature], [RecordingPersistence]) and the
/// move drivers are shared with the in-memory suite rather than duplicated, so
/// both rigs check convergence by the same definition.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:aigammon_app/game/player_agent.dart' show CubeAction;
import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';

import '../net/net_harness.dart';

export '../net/net_harness.dart'
    show
        MovePicker,
        RecordingPersistence,
        greedyFirstMove,
        positionSignature,
        primingMove,
        waitFor;

/// The room code the socket tests use.
const String testRoomCode = '4271';

/// The resume token the rig's relay mints, so a test can assert on it.
const String testResumeToken = 'TESTTOKEN';

/// The clocks the rig runs on: [LanTimings.test] with ONE value relaxed.
///
/// `connectTimeout` doubles as the controller's gate deadline (that is how the
/// screen wires it), and a whole three-message dice handshake — each frame paced
/// past the relay's rate limit, each with a socket round trip — can legitimately
/// outlast 250ms on a loaded CI machine. Two seconds is still hundreds of times a
/// healthy LAN exchange, so a gate that reaches it is still a genuinely lost
/// frame.
final LanTimings lanTestTimings =
    LanTimings.test.copyWith(connectTimeout: const Duration(seconds: 2));

/// Let real timers and socket events run for a beat.
Future<void> tick([int ms = 2]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Both peers of one match over a real socket pair: a [MatchRelay] + [HostServer]
/// on one side, a [GuestClient] on the other, and a [NetMatchController] on each.
///
/// Loopback deliberately (never `anyIPv4`): a test run must not raise a firewall
/// prompt.
class SocketPair {
  SocketPair._(
    this.relay,
    this.server,
    this.client,
    this.host,
    this.guest,
    this.hostPersistence,
    this.guestPersistence,
  );

  static Future<SocketPair> start({
    int length = 1,
    bool cubeless = false,
    MovePicker pickMove = greedyFirstMove,
  }) async {
    final relay = MatchRelay(
      config: MatchConfig(length: length, cubeless: cubeless),
      resumeToken: testResumeToken,
    );
    final server = await HostServer.start(
      port: 0,
      roomCode: testRoomCode,
      timings: lanTestTimings,
      bindAddress: InternetAddress.loopbackIPv4,
      lastSeq: () => relay.lastSeq,
    );
    final client = GuestClient.connect(
      InternetAddress.loopbackIPv4.address,
      server.port,
      roomCode: testRoomCode,
      name: 'Bo',
      timings: lanTestTimings,
    );

    final hostRec = RecordingPersistence();
    final guestRec = RecordingPersistence();
    final host = NetMatchController(
      transport: SocketTransport.host(server: server, relay: relay),
      persistence: hostRec,
      gateTimeout: lanTestTimings.connectTimeout,
      rng: Random(101),
    );
    final guest = NetMatchController(
      transport: SocketTransport.guest(client: client),
      persistence: guestRec,
      gateTimeout: lanTestTimings.connectTimeout,
      rng: Random(202),
    );

    final pair = SocketPair._(
        relay, server, client, host, guest, hostRec, guestRec)
      ..pickMove = pickMove;

    // The host must be running before the guest's handshake, exactly as the
    // screen does it: the board opens when a guest arrives.
    unawaited(host.playMatch());
    unawaited(guest.playMatch());
    await pair.waitUntil(() => host.isReady && guest.isReady,
        what: 'both controllers to fold game 1',
        timeout: const Duration(seconds: 20));
    return pair;
  }

  final MatchRelay relay;
  final HostServer server;
  final GuestClient client;
  final NetMatchController host;
  final NetMatchController guest;
  final RecordingPersistence hostPersistence;
  final RecordingPersistence guestPersistence;

  /// How the driver plays a turn. Swap it for [primingMove] when the test needs
  /// a game that actually develops — and therefore dances.
  MovePicker pickMove = greedyFirstMove;

  /// Cube responses the driver gives, in order; the last one repeats.
  List<CubeAction> cubeResponses = [CubeAction.take];

  /// Whether the driver accepts a resignation offer.
  bool acceptResign = true;

  bool _disposed = false;

  final Map<NetMatchController, GameState?> _lastActed = {};

  /// The last seq the relay has committed — the authority both folds chase.
  int get lastSeq => relay.lastSeq;

  /// Tear the whole rig down, innermost first: the controllers own their
  /// transports, this rig owns the link and the log. Idempotent, so a test may
  /// dispose explicitly (to assert the teardown itself is clean) and still
  /// register this as a safety net.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    host.disposeController();
    guest.disposeController();
    await client.dispose();
    await server.stop();
    await relay.close();
  }

  /// Poll until [done], letting real time pass.
  Future<void> waitUntil(
    bool Function() done, {
    String what = 'condition',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $what '
            '(relay seq $lastSeq, host ${host.lastSeq}/${host.error}, '
            'guest ${guest.lastSeq}/${guest.error})');
      }
      await tick();
    }
  }

  /// Both folds have taken in everything the relay has committed.
  bool get converged => host.lastSeq == lastSeq && guest.lastSeq == lastSeq;

  Future<void> settleFold() =>
      waitUntil(() => converged, what: 'both folds to reach seq $lastSeq');

  /// Bring both folds level and dismiss any game-over pause on either device —
  /// the caller's precondition for reading either state.
  Future<void> sync() async {
    await settleFold();
    if (host.awaitingNextGame) host.continueToNextGame();
    if (guest.awaitingNextGame) guest.continueToNextGame();
    await settleFold();
  }

  /// The controller whose side is on turn, and its peer.
  NetMatchController get onTurn =>
      host.state.turn == host.localSide ? host : guest;
  NetMatchController get offTurn => identical(onTurn, host) ? guest : host;

  /// One decision for [c], deduplicated by [GameState] identity so a submission
  /// that has not been echoed back yet is never re-issued.
  void act(NetMatchController c) {
    if (c.matchOver || c.frozen || !c.isReady || c.awaitingNextGame) return;
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
    } else {
      return;
    }
    _lastActed[c] = s;
  }

  /// Drive one authoritative event out of whichever controller owns the side on
  /// turn, and wait for the relay to answer.
  ///
  /// RE-ACTS if the log does not move: a frame really can vanish (the relay
  /// silently drops anything over its rate limit), the protocol never replays a
  /// write, and the controller's answer to that is to re-open the gate — so a
  /// player, and therefore this driver, simply acts again.
  Future<void> step({String where = 'a step'}) async {
    await sync();
    final before = lastSeq;
    for (var attempt = 1; attempt <= 6; attempt++) {
      _lastActed.clear();
      act(host);
      act(guest);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (lastSeq == before && DateTime.now().isBefore(deadline)) {
        if (host.frozen || guest.frozen) {
          fail('a controller froze during $where: '
              '${host.cheatError ?? guest.cheatError}');
        }
        await tick();
      }
      if (lastSeq > before) {
        await settleFold();
        return;
      }
    }
    fail('six attempts did not move the log past $before ($where; '
        'host ${host.error}, guest ${guest.error})');
  }

  /// Step until [done] holds with both folds settled. Deliberately re-syncs
  /// BEFORE testing [done], so a gate the test is waiting for is never consumed
  /// by one step too many.
  Future<void> advanceUntil(
    bool Function() done, {
    int maxSteps = 400,
    String what = 'the condition',
  }) async {
    var steps = 0;
    while (true) {
      await sync();
      if (done()) return;
      if (steps++ > maxSteps) fail('never reached $what');
      if (host.matchOver) fail('the match ended before $what');
      await step(where: '$what (step $steps)');
    }
  }

  /// Drive the whole match out through both controllers.
  Future<void> playOut({int maxSteps = 2000}) async {
    var steps = 0;
    while (!host.matchOver) {
      if (steps++ > maxSteps) fail('the match did not terminate');
      await step(where: 'the play-out (step $steps)');
    }
    await sync();
  }
}
