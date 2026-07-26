import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/lan/lan_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';

import 'lan_harness.dart';

/// The end-to-end proof for LAN play: ONE three-point match, played to its last
/// point by two [LanMatchController]s over REAL loopback sockets, with every
/// interesting thing that can happen to a match happening in it.
///
/// This is not another unit test of the fold — `lan_link_recovery_test.dart`
/// owns that, with a hand-driven link. Here nothing is faked below the
/// controllers: the host's authority, an [HttpServer] upgrading a WebSocket, a
/// [GuestClient] reconnecting on its own timers. What it proves is the property
/// the whole design rests on — *the log is sufficient*: two devices folding one
/// seq-numbered stream through the same code reach the same game, the same
/// score and the same history, whatever happens to the wire in between.
///
/// ## The script
///
/// Both sides are driven by [primingMove] (deterministic, and unlike the
/// first-legal-play driver it actually shuts a board, which is the only way a
/// scripted playout reaches a DANCE without hand-building a position):
///
///  * **game 1** — played until a dance lands in the log, then the guest
///    doubles and the host DROPS: a game ended by the cube. 0-1.
///  * **game 2** — the host doubles and the guest TAKES (cube 2, owned by the
///    guest). Mid-game the guest's socket is cut from under it; it reconnects
///    on its own and the reconnect's welcome resyncs the fold. Play continues,
///    then the guest resigns and the host accepts: 2 points at cube 2. 2-1.
///  * **game 3** — Crawford (the cube is refused, and that is asserted). The
///    guest resigns again; the host takes the last point. 3-1, match over.
///
/// ## What is checked, and when
///
/// After EVERY exchange, not merely at the end: both folds hold the same seq,
/// and the same [positionSignature] — board, bars, borne-off, turn, phase,
/// dice, cube, Crawford, pending resignation, score, game number. Every move
/// entry must publish an [AppliedMove] on BOTH devices, once, carrying the
/// board the move was applied to. Seqs must be contiguous from 1 in the
/// authority's log and in what the guest took off the wire. Each finished game
/// must be persisted exactly once on each device, the match exactly once, and
/// the teardown must leave nothing running.
void main() {
  test('a whole 3-point match: cube, drop, resign, dance, disconnect', () async {
    final pair = await LanPair.start(length: 3, pickMove: primingMove);
    addTearDown(pair.dispose);

    final host = pair.host;
    final guest = pair.guest;
    final hostSide = host.localSide;
    final guestSide = guest.localSide;

    // --- observers -----------------------------------------------------------

    // Every AppliedMove publication, on each device, so a move can be asserted
    // to fire exactly once per logged MoveEvent — on the RECEIVING side too.
    var hostMoveFires = 0;
    var guestMoveFires = 0;
    host.lastMove.addListener(() => hostMoveFires++);
    guest.lastMove.addListener(() => guestMoveFires++);

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

    // --- assertions both devices must satisfy after every exchange ------------

    Future<void> converged(String where) async {
      await pair.settleFold();
      expect(host.lastSeq, pair.authority.lastSeq, reason: 'host seq: $where');
      expect(guest.lastSeq, pair.authority.lastSeq, reason: 'guest seq: $where');
      expect(guest.awaitingNextGame, host.awaitingNextGame,
          reason: 'game-over pause: $where');
      expect(positionSignature(guest), positionSignature(host),
          reason: 'position/score/game: $where');
      expect(host.error, isNull, reason: 'host banner: $where');
      expect(guest.error, isNull, reason: 'guest banner: $where');
      expect(host.persistenceError, isNull, reason: 'host storage: $where');
      expect(guest.persistenceError, isNull, reason: 'guest storage: $where');
    }

    /// Express one intent and wait for the AUTHORITY to answer it before
    /// checking convergence.
    ///
    /// Waiting on [LanPair.settleFold] alone would be a race that always
    /// passes: until the submission reaches the host, both folds are already
    /// level with an authority that has not moved yet.
    Future<void> act(void Function() intent, String where) async {
      final before = pair.authority.lastSeq;
      intent();
      await waitFor(() => pair.authority.lastSeq > before,
          what: 'the log to answer: $where');
      await converged(where);
    }

    /// One driven exchange, with the whole contract checked around it.
    Future<void> playStep(String where) async {
      await pair.sync();
      final mover = host.state.turn;
      final preBoard = host.state.board;
      final hostFiresBefore = hostMoveFires;
      final guestFiresBefore = guestMoveFires;
      final seqBefore = pair.authority.lastSeq;

      await pair.step();
      await converged(where);

      final landed = pair.authority.log[seqBefore]; // the entry seq+1
      expect(landed.seq, seqBefore + 1);
      final event = landed.event;
      if (event is! MoveEvent) return;

      // A move — including a DANCE, which is a move with no hops — must reach
      // the animation layer on both devices, exactly once, carrying the board
      // it was applied to.
      expect(hostMoveFires, hostFiresBefore + 1,
          reason: 'the host published one AppliedMove: $where');
      expect(guestMoveFires, guestFiresBefore + 1,
          reason: 'the guest published one AppliedMove: $where');
      for (final c in [host, guest]) {
        final applied = c.lastMove.value!;
        expect(applied.player, mover, reason: 'mover: $where');
        expect(applied.move.sameAs(event.move), isTrue,
            reason: 'move: $where');
        expect(applied.preBoard, preBoard,
            reason: 'the board the move was applied to: $where');
      }
    }

    /// Advance (driving both sides) until [done], checking the contract at each
    /// exchange rather than only at the end.
    Future<void> advance(bool Function() done, String what,
        {int maxSteps = 200}) async {
      var steps = 0;
      await pair.sync();
      while (!done()) {
        if (steps++ > maxSteps) fail('never reached $what');
        expect(pair.authority.matchOver, isFalse,
            reason: 'the match ended before $what');
        await playStep('$what (step $steps)');
        await pair.sync();
      }
    }

    /// [doubler] offers the cube; its peer answers. Both halves are separate
    /// authoritative entries, so the contract is checked twice.
    Future<void> cube(LanMatchController doubler, CubeAction answer) async {
      final peer = identical(doubler, host) ? guest : host;
      await advance(() => doubler.awaitingHumanTurn,
          '${doubler.localSide.name}\'s pre-roll gate to double');
      await act(doubler.offerDouble, 'the cube offer');
      await waitFor(() => peer.pendingCubeOf(peer.localSide).value != null,
          what: 'the cube offer to reach ${peer.localSide.name}');
      expect(doubler.state.phase, GamePhase.cubeOffered);

      await act(() => peer.submitCubeResponse(peer.localSide, answer),
          'the cube ${answer.name}');
    }

    /// [resigner] offers a resignation; its peer accepts.
    Future<void> resign(LanMatchController resigner, ResignValue value) async {
      final peer = identical(resigner, host) ? guest : host;
      await advance(() => resigner.awaitingHumanTurn,
          '${resigner.localSide.name}\'s pre-roll gate to resign');
      await act(() => resigner.offerResign(value), 'the resignation offer');
      await waitFor(() => peer.pendingResignOf(peer.localSide).value != null,
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
    expect(guest.localSide, hostSide.opponent);
    await converged('the opening roll');

    bool danced() => pair.authority.log.any((e) =>
        e.event is MoveEvent && (e.event as MoveEvent).move.checkerMoves.isEmpty);

    await advance(danced, 'a dance (no legal play)');
    expect(guest.gameNumber, 1);
    final firstDance = pair.authority.log
        .firstWhere((e) => e.event is MoveEvent && (e.event as MoveEvent).move.checkerMoves.isEmpty);
    expect((firstDance.event as MoveEvent).move.checkerMoves, isEmpty);

    await cube(guest, CubeAction.drop);

    // A drop pays the cube value BEFORE the double: one point to the doubler.
    for (final c in [host, guest]) {
      expect(c.state.phase, GamePhase.gameOver);
      expect(c.state.result!.outcome, GameOutcome.drop);
      expect(c.state.result!.winner, guestSide);
      expect(c.state.result!.points, 1);
      expect(c.awaitingNextGame, isTrue, reason: 'the game-over pause is owed');
    }
    expect(pair.authority.match.whiteScore, hostSide == Player.white ? 0 : 1);
    await waitFor(
        () =>
            pair.hostPersistence.games.length == 1 &&
            pair.guestPersistence.games.length == 1,
        what: 'both devices to record game 1');

    await pair.sync(); // both players dismiss the dialog; game 2 is under way
    await converged('the start of game 2');
    expect(host.gameNumber, 2);

    // =========================================================================
    // Game 2 — a TAKE, an abrupt disconnect mid-game, then a resignation.
    // =========================================================================

    await cube(host, CubeAction.take);
    for (final c in [host, guest]) {
      expect(c.state.cube.value, 2);
      expect(c.state.cube.owner, guestSide, reason: 'the taker owns the cube');
    }

    await playStep('after the take');
    await playStep('after the take');

    // THE DROP-OUT. The host cuts the guest's socket from under it mid-game;
    // nothing warns the guest's controller, and the authority keeps the match.
    final seqAtDrop = pair.authority.lastSeq;
    final signatureAtDrop = positionSignature(host);
    final welcomesBefore = pair.welcomes;
    await pair.server.disconnectGuest('abrupt drop');
    await waitFor(
        () => guest.linkStatus.value != GuestConnectionStatus.connected,
        what: 'the guest to notice the drop');
    expect(pair.server.hasGuest, isFalse);
    expect(host.linkStatus.value, isNot(GuestConnectionStatus.connected),
        reason: 'the host is told its guest left');

    // It reconnects on its own; the reconnect's welcome IS the resync.
    await waitFor(
        () => guest.linkStatus.value == GuestConnectionStatus.connected,
        what: 'the guest to reconnect');
    await waitFor(() => pair.welcomes > welcomesBefore,
        what: 'the resync welcome');
    await waitFor(() => host.linkStatus.value == GuestConnectionStatus.connected,
        what: 'the host to see its guest return');
    await converged('the resync after the drop');

    expect(guest.lastSeq, seqAtDrop, reason: 'nothing was lost in the drop');
    expect(positionSignature(guest), signatureAtDrop,
        reason: 'the resync rebuilt exactly the position we left');
    expect(guest.state.cube.value, 2, reason: 'the cube survived the drop');
    expect(pair.server.hasGuest, isTrue);

    // ...and the match carries on over the NEW socket.
    await playStep('after the reconnect');
    await playStep('after the reconnect');

    await resign(guest, ResignValue.single);
    for (final c in [host, guest]) {
      expect(c.state.result!.outcome, GameOutcome.resignation);
      expect(c.state.result!.winner, hostSide, reason: 'the resigner loses');
      expect(c.state.result!.points, 2, reason: 'a single at cube 2');
      expect(c.awaitingNextGame, isTrue);
    }
    await waitFor(
        () =>
            pair.hostPersistence.games.length == 2 &&
            pair.guestPersistence.games.length == 2,
        what: 'both devices to record game 2');

    await pair.sync();
    await converged('the start of game 3');
    expect(host.gameNumber, 3);

    // =========================================================================
    // Game 3 — Crawford, and the last point.
    // =========================================================================

    for (final c in [host, guest]) {
      expect(c.state.isCrawfordGame, isTrue,
          reason: 'one side is one point from the match');
    }
    await advance(() => host.awaitingHumanTurn, 'the host\'s pre-roll gate');
    expect(() => host.offerDouble(), throwsStateError,
        reason: 'no doubling in the Crawford game');
    await converged('the refused Crawford double');

    await playStep('the Crawford game');
    await resign(guest, ResignValue.single);

    // =========================================================================
    // The match is decided — and decided identically on both devices.
    // =========================================================================

    expect(pair.authority.matchOver, isTrue);
    final winner = pair.authority.match.winner;
    expect(winner, hostSide);
    for (final c in [host, guest]) {
      expect(c.matchOver, isTrue);
      expect(c.match.winner, winner);
      expect(c.match.whiteScore, pair.authority.match.whiteScore);
      expect(c.match.blackScore, pair.authority.match.blackScore);
      expect(c.gameNumber, 3);
      expect(c.state.phase, GamePhase.gameOver);
      expect(c.error, isNull);
      expect(c.persistenceError, isNull);
    }
    expect(positionSignature(guest), positionSignature(host));
    expect(guest.game.events.length, host.game.events.length);

    // Seq contiguity: the authority assigned 1..N with no holes, and every one
    // of them reached the guest exactly once, in order.
    final log = pair.authority.log;
    expect([for (final e in log) e.seq], [for (var i = 1; i <= log.length; i++) i]);
    expect(pair.guestEventSeqs, [for (var i = 1; i <= log.length; i++) i],
        reason: 'the wire delivered every entry once, in order');
    expect(host.lastSeq, log.length);
    expect(guest.lastSeq, log.length);

    // Exactly one resync welcome beyond the handshake: the reconnect's.
    expect(pair.welcomes, 2);

    // Both devices recorded every finished game ONCE, and the match ONCE.
    await waitFor(
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
      expect(
          [for (final e in pair.guestPersistence.games[i].events) e.toJson().toString()],
          [for (final e in pair.hostPersistence.games[i].events) e.toJson().toString()]);
    }

    // =========================================================================
    // Teardown — everything stops, and stays stopped.
    // =========================================================================

    await pair.dispose();
    final seqAtTeardown = pair.authority.lastSeq;
    final welcomesAtTeardown = pair.welcomes;
    final deliveredAtTeardown = pair.guestEventSeqs.length;
    final firesAtTeardown = hostMoveFires + guestMoveFires;
    // Comfortably past every clock the rig runs on (silence 200ms, reconnect
    // backoff 80ms, heartbeat 40ms): if anything were still armed, it would
    // fire in here — as a reconnect attempt, an unhandled socket error, or a
    // notifier used after dispose.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(pair.authority.lastSeq, seqAtTeardown);
    expect(pair.welcomes, welcomesAtTeardown);
    expect(pair.guestEventSeqs.length, deliveredAtTeardown);
    expect(hostMoveFires + guestMoveFires, firesAtTeardown);
    expect(pair.server.hasGuest, isFalse);
    // Idempotent: the safety-net teardown that follows must be a no-op.
    await pair.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
