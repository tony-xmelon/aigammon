import 'dart:io';

import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/lan/lan_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';

import 'lan_harness.dart';

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
    client.inbound.listen((m) {
      if (m is WelcomeMessage) welcomes.add(m);
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
      .._welcomes = welcomes;
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

  /// How many `welcome` frames the guest has seen. The first is the handshake;
  /// every later one is a full resync.
  int get welcomes => _welcomes.length;

  Future<void> dispose() async {
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

  Future<void> settleFold() =>
      waitFor(() => converged, what: 'both folds to reach seq ${authority.lastSeq}');

  /// Bring both folds level with the authority and dismiss any game-over pause
  /// on either device — the caller's precondition for reading either state.
  Future<void> sync() async {
    await settleFold();
    if (host.awaitingNextGame) host.continueToNextGame();
    if (guest.awaitingNextGame) guest.continueToNextGame();
  }

  /// Play one authoritative event, acting through whichever CONTROLLER owns the
  /// side on turn — the host in process, the guest over the socket.
  Future<void> step() async {
    await sync();
    final actor = host.state.turn == host.localSide ? host : guest;
    final before = authority.lastSeq;
    actInController(actor);
    await waitFor(() => authority.lastSeq > before,
        what: 'seq to pass $before (${actor.localSide.name})');
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

void main() {
  test('both controllers fold one log to the same finished match', () async {
    final pair = await LanPair.start(length: 1);
    addTearDown(pair.dispose);

    // The guest adopted the host's config and the side the welcome assigned.
    expect(pair.guest.localSide, pair.authority.guestSide);
    expect(pair.guest.match.matchLength, 1);
    expect(pair.guest.cubeless, isFalse);
    expect(pair.guest.isLocalHuman(pair.guest.localSide), isTrue);
    expect(pair.guest.isLocalHuman(pair.host.localSide), isFalse);
    expect(pair.guest.linkStatus.value, GuestConnectionStatus.connected);

    await pair.playOut();

    expect(pair.authority.matchOver, isTrue);
    for (final c in [pair.host, pair.guest]) {
      expect(c.matchOver, isTrue);
      expect(c.state.phase, GamePhase.gameOver);
      expect(c.match.whiteScore, pair.authority.match.whiteScore);
      expect(c.match.blackScore, pair.authority.match.blackScore);
      expect(c.match.winner, pair.authority.match.winner);
      expect(c.gameNumber, pair.authority.gameNumber);
      expect(c.error, isNull);
      expect(c.persistenceError, isNull);
    }
    // The two folds are identical event for event.
    expect(pair.guest.game.events.length, pair.host.game.events.length);

    // Both ends persisted the same finished game and match.
    await waitFor(() =>
        pair.hostPersistence.matchFinishedCalls == 1 &&
        pair.guestPersistence.matchFinishedCalls == 1);
    for (final rec in [pair.hostPersistence, pair.guestPersistence]) {
      expect(rec.games.length, 1);
      expect(rec.games.single.gameNumber, 1);
      expect(rec.games.single.result.winner, pair.authority.match.winner);
      expect(rec.finalState!.isMatchOver, isTrue);
    }
    expect(pair.welcomes, 1, reason: 'no resync was needed on a healthy link');
  });

  test('the cube travels: the guest doubles, the host takes', () async {
    final pair = await LanPair.start(length: 5);
    addTearDown(pair.dispose);

    await pair.advanceUntil(() => pair.guest.awaitingHumanTurn,
        what: 'the guest pre-roll gate');

    pair.guest.offerDouble();
    await waitFor(() => pair.host.pendingCubeOf(pair.host.localSide).value != null,
        what: 'the host to be asked for a cube decision');
    expect(pair.host.state.phase, GamePhase.cubeOffered);

    pair.host.submitCubeResponse(pair.host.localSide, CubeAction.take);
    await pair.settleFold();

    for (final c in [pair.host, pair.guest]) {
      expect(c.state.cube.value, 2);
      expect(c.state.cube.owner, pair.host.localSide);
    }
    expect(pair.guest.awaitingHumanTurn, isTrue);
  });

  test('the guest resigns and the host accepts; both score it the same',
      () async {
    final pair = await LanPair.start(length: 5);
    addTearDown(pair.dispose);

    await pair.advanceUntil(() => pair.guest.awaitingHumanTurn,
        what: 'the guest pre-roll gate');

    pair.guest.offerResign(ResignValue.single);
    await waitFor(
        () => pair.host.pendingResignOf(pair.host.localSide).value != null,
        what: 'the host to be asked about the resignation');

    pair.host.submitResignResponse(pair.host.localSide, true);
    await pair.settleFold();

    for (final c in [pair.host, pair.guest]) {
      expect(c.state.phase, GamePhase.gameOver);
      expect(c.awaitingNextGame, isTrue);
      expect(c.match.whiteScore, pair.authority.match.whiteScore);
      expect(c.match.blackScore, pair.authority.match.blackScore);
    }
    // The RESIGNER loses the point.
    await waitFor(() => pair.guestPersistence.games.length == 1);
    expect(pair.guestPersistence.games.single.result.winner, pair.host.localSide);
  });

  test('a mid-game disconnect resyncs the guest and play continues', () async {
    final pair = await LanPair.start(length: 5);
    addTearDown(pair.dispose);

    // Get a few events in, then cut the socket from the host's side.
    for (var i = 0; i < 4; i++) {
      await pair.step();
    }
    await pair.settleFold();
    final seqAtDrop = pair.authority.lastSeq;

    await pair.server.disconnectGuest('test drop');
    await waitFor(() => pair.guest.linkStatus.value != GuestConnectionStatus.connected,
        what: 'the guest to notice the drop');

    // It reconnects on its own, and the reconnect's welcome IS the resync.
    await waitFor(() => pair.guest.linkStatus.value == GuestConnectionStatus.connected,
        what: 'the guest to reconnect');
    await waitFor(() => pair.welcomes >= 2, what: 'a resync welcome');
    await pair.settleFold();

    expect(pair.guest.lastSeq, greaterThanOrEqualTo(seqAtDrop));
    expect(pair.guest.state.turn, pair.host.state.turn);
    expect(pair.guest.state.phase, pair.host.state.phase);
    expect(pair.guest.error, isNull, reason: 'the resync healed the banner');
    expect(pair.server.hasGuest, isTrue);

    // And the match plays through to the end over the new socket.
    await pair.playOut();
    expect(pair.guest.matchOver, isTrue);
    expect(pair.guest.match.winner, pair.authority.match.winner);
  });

  test('an out-of-turn guest submission is refused without moving the log',
      () async {
    final pair = await LanPair.start(length: 5);
    addTearDown(pair.dispose);

    // Make sure it is the HOST's turn, so a guest submission is out of turn.
    await pair.advanceUntil(() => pair.host.state.turn == pair.host.localSide,
        what: 'a host turn');
    final seqBefore = pair.authority.lastSeq;

    // Straight down the wire, bypassing the controller's own gating.
    pair.client.submit(MoveEvent(pair.guest.localSide, Move.none));
    await waitFor(() => pair.guest.error != null,
        what: 'the rejection to reach the guest');

    expect(pair.authority.lastSeq, seqBefore, reason: 'the log did not move');
    expect((pair.guest.error! as LanMatchException).code, 'rejected',
        reason: 'level lastSeq means the refusal was about the submission');
    expect(pair.welcomes, 1, reason: 'a level rejection must not pull the log');

    // The guest is otherwise unharmed and the match plays on.
    await pair.playOut();
    expect(pair.guest.matchOver, isTrue);
  });
}
