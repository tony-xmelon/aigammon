import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';

import 'lan_harness.dart';

/// The end-to-end proof for LAN play: ONE three-point match, played to its last
/// point by two [NetMatchController]s over REAL loopback sockets, with every
/// interesting thing that can happen to a match happening in it.
///
/// This is not another unit test of the fold — `app/test/net/` owns that against
/// the in-memory transport. Here nothing is faked below the controllers: a
/// [MatchRelay] holding the log, an `HttpServer` upgrading a WebSocket, a
/// `GuestClient` reconnecting on its own timers, and every roll going through the
/// three-message commit-reveal handshake ACROSS THE WIRE. What it proves is the
/// property the whole design rests on — *the log is sufficient*: two devices
/// folding one seq-numbered stream through the same code reach the same game, the
/// same score and the same history, whatever happens to the wire in between.
///
/// ## What replaced the referee
///
/// Before Plan 17 the host validated every submission and dealt every die. Here
/// the relay does neither, so this test is also the proof that the pair still
/// agrees without one: each peer derives the dice from the commit-reveal
/// documents, validates the other's events against the rules engine, and NEITHER
/// FREEZES (a freeze anywhere in this test fails it — see [SocketPair.step]).
///
/// ## The script
///
///  * **game 1** — played until a dance lands in the log, then the guest doubles
///    and the host DROPS: a game ended by the cube. 0-1.
///  * **game 2** — the host doubles and the guest TAKES (cube 2, owned by the
///    guest). Mid-game the guest's socket is cut from under it; it reconnects on
///    its own and the reconnect's welcome resyncs the fold. Play continues, then
///    the guest resigns and the host accepts: 2 points at cube 2. 2-1.
///  * **game 3** — Crawford (the cube is refused, and that is asserted). The
///    guest resigns again; the host takes the last point. 3-1, match over.
///
/// ## What is checked, and when
///
/// After EVERY exchange, not merely at the end: both folds hold the same seq and
/// the same [positionSignature] — board, bars, borne-off, turn, phase, dice, cube,
/// Crawford, pending resignation, score, game number. Seqs must be contiguous
/// from 1 in the relay's log. Each finished game must be persisted exactly once on
/// each device, the match exactly once, and the teardown must leave nothing
/// running.
void main() {
  test('a whole 3-point match: cube, drop, resign, dance, disconnect',
      () async {
    final pair = await SocketPair.start(length: 3, pickMove: primingMove);
    addTearDown(pair.dispose);

    final host = pair.host;
    final guest = pair.guest;
    final hostSide = host.localSide;
    final guestSide = guest.localSide;

    // --- observers -----------------------------------------------------------

    // Neither fold may ever go backwards, resync or no resync.
    var hostHighWater = 0;
    var guestHighWater = 0;
    host.addListener(() {
      expect(host.lastSeq, greaterThanOrEqualTo(hostHighWater),
          reason: 'the host fold went backwards');
      hostHighWater = host.lastSeq;
    });
    guest.addListener(() {
      expect(guest.lastSeq, greaterThanOrEqualTo(guestHighWater),
          reason: 'the guest fold went backwards');
      guestHighWater = guest.lastSeq;
    });

    // --- assertions both devices must satisfy after every exchange -----------

    Future<void> converged(String where) async {
      await pair.settleFold();
      expect(host.frozen, isFalse, reason: 'host freeze: ${host.cheatError}');
      expect(guest.frozen, isFalse, reason: 'guest freeze: ${guest.cheatError}');
      expect(host.lastSeq, pair.lastSeq, reason: 'host seq: $where');
      expect(guest.lastSeq, pair.lastSeq, reason: 'guest seq: $where');
      expect(guest.awaitingNextGame, host.awaitingNextGame,
          reason: 'game-over pause: $where');
      expect(positionSignature(guest), positionSignature(host),
          reason: 'position/score/game: $where');
      expect(host.persistenceError, isNull, reason: 'host storage: $where');
      expect(guest.persistenceError, isNull, reason: 'guest storage: $where');
    }

    /// Express one intent and wait for the RELAY to answer it before checking
    /// convergence. Waiting on the folds alone would be a race that always
    /// passes: until the write lands, both folds are already level with a log
    /// that has not moved yet.
    Future<void> act(void Function() intent, String where) async {
      final before = pair.lastSeq;
      intent();
      await pair.waitUntil(() => pair.lastSeq > before,
          what: 'the log to answer: $where');
      await converged(where);
    }

    /// [doubler] offers the cube; its peer answers. Both halves are separate log
    /// entries, so the contract is checked twice.
    Future<void> cube(NetMatchController doubler, CubeAction answer) async {
      final peer = identical(doubler, host) ? guest : host;
      await pair.advanceUntil(() => doubler.awaitingHumanTurn,
          what: '${doubler.localSide.name}\'s pre-roll gate to double');
      await act(doubler.offerDouble, 'the cube offer');
      await pair.waitUntil(
          () => peer.pendingCubeOf(peer.localSide).value != null,
          what: 'the cube offer to reach ${peer.localSide.name}');
      expect(doubler.state.phase, GamePhase.cubeOffered);

      await act(() => peer.submitCubeResponse(peer.localSide, answer),
          'the cube ${answer.name}');
    }

    /// [resigner] offers a resignation; its peer accepts.
    Future<void> resign(NetMatchController resigner, ResignValue value) async {
      final peer = identical(resigner, host) ? guest : host;
      await pair.advanceUntil(() => resigner.awaitingHumanTurn,
          what: '${resigner.localSide.name}\'s pre-roll gate to resign');
      await act(() => resigner.offerResign(value), 'the resignation offer');
      await pair.waitUntil(
          () => peer.pendingResignOf(peer.localSide).value != null,
          what: 'the resignation to reach ${peer.localSide.name}');
      expect(peer.pendingResignOf(peer.localSide).value!.$2, value);

      await act(() => peer.submitResignResponse(peer.localSide, true),
          'the resignation accepted');
    }

    // =========================================================================
    // Game 1 — a dance, then a game ended by a DROP.
    // =========================================================================

    expect(host.match.matchLength, 3);
    expect(guest.match.matchLength, 3);
    expect(hostSide, TransportSession.hostSide,
        reason: 'the bound peer plays white, by the shared convention');
    expect(guestSide, hostSide.opponent);
    expect(host.isHost, isTrue);
    expect(guest.isHost, isFalse);
    expect(host.matchCode, testRoomCode);
    await converged('the opening roll');

    // The opening roll came out of the commit-reveal handshake, not out of a
    // dealer: there is a complete roll document behind it, on both peers.
    expect(pair.relay.rollFrames, hasLength(1));
    expect(pair.relay.rollFrames.single.isComplete, isTrue);
    expect(pair.relay.rollFrames.single.roller, MatchRelay.hostAuthor,
        reason: 'the host seat is the opening roller by convention');
    expect(pair.relay.rollFrames.single.entropy, isNotNull,
        reason: 'the joiner witnessed it');
    expect(pair.relay.events.first.author, MatchRelay.hostAuthor);

    bool danced() => pair.relay.events.any((e) =>
        e.event is MoveEvent &&
        (e.event as MoveEvent).move.checkerMoves.isEmpty);

    await pair.advanceUntil(danced, what: 'a dance (no legal play)');
    expect(guest.gameNumber, 1);

    await cube(guest, CubeAction.drop);

    // A drop pays the cube value BEFORE the double: one point to the doubler.
    for (final c in [host, guest]) {
      expect(c.state.phase, GamePhase.gameOver);
      expect(c.state.result!.outcome, GameOutcome.drop);
      expect(c.state.result!.winner, guestSide);
      expect(c.state.result!.points, 1);
      expect(c.awaitingNextGame, isTrue, reason: 'the game-over pause is owed');
    }
    await pair.waitUntil(
        () =>
            pair.hostPersistence.games.length == 1 &&
            pair.guestPersistence.games.length == 1,
        what: 'both devices to record game 1');

    await pair.sync(); // both players dismiss the dialog; game 2 is under way
    await pair.waitUntil(() => host.gameNumber == 2 && guest.gameNumber == 2,
        what: 'game 2 to start');
    await converged('the start of game 2');

    // =========================================================================
    // Game 2 — a TAKE, an abrupt disconnect mid-game, then a resignation.
    // =========================================================================

    await cube(host, CubeAction.take);
    for (final c in [host, guest]) {
      expect(c.state.cube.value, 2);
      expect(c.state.cube.owner, guestSide, reason: 'the taker owns the cube');
    }

    await pair.step(where: 'after the take');
    await pair.step(where: 'after the take');

    // THE DROP-OUT. The relay cuts the guest's socket from under it mid-game;
    // nothing warns the guest's controller, and the log survives on the host.
    final seqAtDrop = pair.lastSeq;
    final signatureAtDrop = positionSignature(host);
    await pair.server.disconnectGuest('abrupt drop');
    await pair.waitUntil(
        () => guest.linkStatus.value != TransportStatus.connected,
        what: 'the guest to notice the drop');
    expect(pair.server.hasGuest, isFalse);
    await pair.waitUntil(() => !host.opponentPresent.value,
        what: 'the host to be told its guest left');

    // It reconnects on its own; the reconnect's welcome IS the resync.
    await pair.waitUntil(
        () => guest.linkStatus.value == TransportStatus.connected,
        what: 'the guest to reconnect');
    await pair.waitUntil(() => host.opponentPresent.value,
        what: 'the host to see its guest return');
    await converged('the resync after the drop');

    expect(guest.lastSeq, seqAtDrop, reason: 'nothing was lost in the drop');
    expect(positionSignature(guest), signatureAtDrop,
        reason: 'the resync rebuilt exactly the position we left');
    expect(guest.state.cube.value, 2, reason: 'the cube survived the drop');
    expect(pair.server.hasGuest, isTrue);

    // ...and the match carries on over the NEW socket.
    await pair.step(where: 'after the reconnect');
    await pair.step(where: 'after the reconnect');

    await resign(guest, ResignValue.single);
    for (final c in [host, guest]) {
      expect(c.state.result!.outcome, GameOutcome.resignation);
      expect(c.state.result!.winner, hostSide, reason: 'the resigner loses');
      expect(c.state.result!.points, 2, reason: 'a single at cube 2');
      expect(c.awaitingNextGame, isTrue);
    }
    await pair.waitUntil(
        () =>
            pair.hostPersistence.games.length == 2 &&
            pair.guestPersistence.games.length == 2,
        what: 'both devices to record game 2');

    await pair.sync();
    await pair.waitUntil(() => host.gameNumber == 3 && guest.gameNumber == 3,
        what: 'game 3 to start');
    await converged('the start of game 3');

    // =========================================================================
    // Game 3 — Crawford, and the last point.
    // =========================================================================

    for (final c in [host, guest]) {
      expect(c.state.isCrawfordGame, isTrue,
          reason: 'one side is one point from the match');
    }
    await pair.advanceUntil(() => host.awaitingHumanTurn,
        what: 'the host\'s pre-roll gate');
    expect(host.offerDouble, throwsStateError,
        reason: 'no doubling in the Crawford game');
    await converged('the refused Crawford double');

    await pair.step(where: 'the Crawford game');
    await resign(guest, ResignValue.single);

    // =========================================================================
    // The match is decided — and decided identically on both devices.
    // =========================================================================

    final winner = host.match.winner;
    expect(winner, hostSide);
    for (final c in [host, guest]) {
      expect(c.matchOver, isTrue);
      expect(c.match.winner, winner);
      expect(c.gameNumber, 3);
      expect(c.state.phase, GamePhase.gameOver);
      expect(c.frozen, isFalse);
      expect(c.persistenceError, isNull);
    }
    expect(guest.match.whiteScore, host.match.whiteScore);
    expect(guest.match.blackScore, host.match.blackScore);
    expect(positionSignature(guest), positionSignature(host));
    expect(guest.game.events.length, host.game.events.length);

    // Seq contiguity: the relay assigned 1..N with no holes, and both folds are
    // level with it. Every roll-bearing event has a COMPLETE roll document behind
    // it — the commit-reveal chain is unbroken across the whole match.
    final log = pair.relay.events;
    expect([for (final e in log) e.seq],
        [for (var i = 1; i <= log.length; i++) i]);
    expect(host.lastSeq, log.length);
    expect(guest.lastSeq, log.length);
    final rollBearing = log
        .where((e) => e.event is OpeningRollEvent || e.event is RollEvent)
        .length;
    expect(pair.relay.rollFrames, hasLength(rollBearing));
    expect(pair.relay.rollFrames.every((r) => r.isComplete), isTrue);
    expect(host.rollCount, rollBearing);
    expect(guest.rollCount, rollBearing);
    // Both seats rolled, so the handshake ran in both directions over the wire.
    final rollers = pair.relay.rollFrames.map((r) => r.roller).toSet();
    expect(rollers, containsAll([MatchRelay.hostAuthor, MatchRelay.guestAuthor]));

    // Both devices recorded every finished game ONCE, and the match ONCE.
    await pair.waitUntil(
        () =>
            pair.hostPersistence.matchFinishedCalls == 1 &&
            pair.guestPersistence.matchFinishedCalls == 1,
        what: 'both devices to record the finished match');
    for (final rec in [pair.hostPersistence, pair.guestPersistence]) {
      expect(rec.games.length, 3);
      expect([for (final g in rec.games) g.gameNumber], [1, 2, 3]);
      expect([for (final g in rec.games) g.isCrawford], [false, false, true]);
      expect(rec.games[0].result.winner, guestSide);
      expect(rec.games[1].result.winner, hostSide);
      expect(rec.games[2].result.winner, hostSide);
      expect(rec.finalState!.isMatchOver, isTrue);
      expect(rec.finalState!.winner, winner);
      expect(rec.matchFinishedCalls, 1);
      // The persisted log of each game is the game's OWN events, complete.
      for (final g in rec.games) {
        final fromLog = log.where((e) => e.gameNo == g.gameNumber).length;
        expect(g.events.length, fromLog,
            reason: 'game ${g.gameNumber} was persisted with its whole log');
      }
    }
    // The two devices persisted the SAME history, event for event.
    for (var i = 0; i < 3; i++) {
      expect([
        for (final e in pair.guestPersistence.games[i].events)
          e.toJson().toString()
      ], [
        for (final e in pair.hostPersistence.games[i].events)
          e.toJson().toString()
      ]);
    }

    // =========================================================================
    // Teardown — everything stops, and stays stopped.
    // =========================================================================

    await pair.dispose();
    final seqAtTeardown = pair.lastSeq;
    // Comfortably past every clock the rig runs on (silence 200ms, reconnect
    // backoff 80ms, heartbeat 40ms): if anything were still armed, it would fire
    // in here — as a reconnect attempt, an unhandled socket error, or a notifier
    // used after dispose.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(pair.lastSeq, seqAtTeardown);
    expect(pair.server.hasGuest, isFalse);
    // Idempotent: the safety-net teardown that follows must be a no-op.
    await pair.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
