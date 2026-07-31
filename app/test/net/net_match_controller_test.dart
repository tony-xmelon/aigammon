/// The unified controller's HAPPY PATH, from both seats: two real
/// [NetMatchController]s over one [InMemoryBackend] playing whole matches through
/// the commit-reveal protocol, with the cube, resignations, a dance and the
/// persistence hooks — the merged superset of the shipped online and LAN
/// happy-path suites.
library;

import 'package:aigammon_app/game/player_agent.dart' show CubeAction;
import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:match_transport/match_transport.dart';
import 'package:match_transport/testing.dart';

import 'net_harness.dart';

void main() {
  test('two controllers play a whole match through the commit-reveal protocol',
      () async {
    final p = await NetPair.start(length: 3);

    expect(p.host.localSide, Player.white, reason: 'the host plays white');
    expect(p.guest.localSide, Player.black);
    expect(p.host.isHost, isTrue);
    expect(p.guest.isHost, isFalse);
    expect(p.host.matchCode, p.guest.matchCode);

    await p.playOut(onGameOver: (c) => expect(c.state.phase, GamePhase.gameOver));

    // Both peers agree on the outcome and neither ended in a fault.
    expect(p.host.error, isNull);
    expect(p.guest.error, isNull);
    expect(p.host.cheatError, isNull);
    expect(p.guest.cheatError, isNull);
    expect(p.host.match.winner, isNotNull);
    expect(p.host.match.winner, p.guest.match.winner);
    expect(p.host.match.whiteScore, p.guest.match.whiteScore);
    expect(p.host.match.blackScore, p.guest.match.blackScore);
    expect(p.pauses, greaterThan(0), reason: 'a 3-point match takes >1 game');

    // Seqs are contiguous FROM 1 — the contract this controller implements.
    final seqs = [for (final e in p.backend.events) e.seq];
    expect(seqs, [for (var i = 1; i <= seqs.length; i++) i]);
    expect(p.host.lastSeq, seqs.length);
    expect(p.guest.lastSeq, seqs.length);

    // Every roll ran the full protocol, exactly once per roll-bearing event, at
    // contiguous indices from 1 — the counter both peers derive from the log.
    final rolls = await p.host.transport.rollsSince(1);
    expect([for (final r in rolls) r.n],
        [for (var i = 1; i <= p.backend.rollCount; i++) i]);
    for (final r in rolls) {
      expect(r.isComplete, isTrue, reason: 'roll ${r.n} never finished');
      expect(commitMatches(r.commit, r.reveal!), isTrue);
    }

    // Openings are ALWAYS the host's; ordinary rolls are the mover's, and every
    // one carries exactly the dice its roll frame derives.
    final byIndex = {for (final r in rolls) r.n: r};
    var n = 0;
    for (final ef in p.backend.events) {
      final event = ef.event;
      if (event is! OpeningRollEvent && event is! RollEvent) continue;
      final roll = byIndex[++n]!.completed!;
      if (event is OpeningRollEvent) {
        expect(ef.author, p.backend.hostAuthor,
            reason: "openings are the host's to roll");
        expect(openingDiceMatchRoll(roll, event), isTrue);
      } else {
        expect(
            ef.author,
            (event as RollEvent).player == Player.white
                ? p.backend.hostAuthor
                : p.backend.guestAuthor);
        expect(diceMatchRoll(roll, event), isTrue);
      }
    }
  });

  test('the cube is offered, TAKEN, and the stake doubles on both peers',
      () async {
    final p = await NetPair.start(length: 5);
    // Doubling is only legal at a pre-roll gate, which is the second turn on.
    await p.advanceUntil(
        () => p.host.awaitingHumanTurn || p.guest.awaitingHumanTurn,
        what: 'a pre-roll gate');

    final mover = p.host.awaitingHumanTurn ? p.host : p.guest;
    final taker = identical(mover, p.host) ? p.guest : p.host;
    expect(mover.cubeless, isFalse);
    p.cubeResponses = [CubeAction.take];
    mover.offerDouble();

    await pumpUntil(
        () => taker.isReady && taker.state.phase == GamePhase.cubeOffered,
        reason: 'the double never reached the other peer');
    await p.advanceUntil(() => p.host.state.cube.value == 2,
        what: 'the cube to be taken');
    await pumpUntil(() => p.guest.state.cube.value == 2);

    expect(p.host.state.cube.owner, taker.localSide);
    expect(p.guest.state.cube.owner, taker.localSide);
    expect(positionSignature(p.host), positionSignature(p.guest));
    expect(p.host.error, isNull);
    expect(p.guest.error, isNull);
  });

  test('the cube is offered and DROPPED: the offerer takes the pre-double stake',
      () async {
    final p = await NetPair.start(length: 5);
    await p.advanceUntil(
        () => p.host.awaitingHumanTurn || p.guest.awaitingHumanTurn,
        what: 'a pre-roll gate');

    final mover = p.host.awaitingHumanTurn ? p.host : p.guest;
    final dropper = identical(mover, p.host) ? p.guest : p.host;
    p.cubeResponses = [CubeAction.drop];
    mover.offerDouble();

    await pumpUntil(
        () => dropper.isReady && dropper.state.phase == GamePhase.cubeOffered);
    await p.advanceUntil(() => p.host.awaitingNextGame && p.guest.awaitingNextGame,
        what: 'the dropped game to end on both peers');

    // A drop concedes the stake BEFORE the double: one point.
    int scoreOf(NetMatchController c) => c.localSide == Player.white
        ? c.match.whiteScore
        : c.match.blackScore;
    expect(scoreOf(mover), 1, reason: 'the offerer wins the pre-double stake');
    expect(scoreOf(dropper), 0);
    expect(p.host.match.whiteScore, p.guest.match.whiteScore);
    expect(p.host.match.blackScore, p.guest.match.blackScore);
    expect(p.host.state.phase, GamePhase.gameOver);
    expect(p.guest.state.phase, GamePhase.gameOver);
  });

  test('a resignation is offered and accepted on the other peer', () async {
    final p = await NetPair.start(length: 5);
    await p.advanceUntil(
        () => p.host.awaitingHumanTurn || p.guest.awaitingHumanTurn,
        what: 'a pre-roll gate');

    final loser = p.host.awaitingHumanTurn ? p.host : p.guest;
    final winner = identical(loser, p.host) ? p.guest : p.host;
    p.acceptResign = true;
    loser.offerResign(ResignValue.single);

    await pumpUntil(
        () => winner.isReady && winner.state.phase == GamePhase.resignOffered,
        reason: 'the resignation never reached the other peer');
    expect(winner.pendingResignOf(winner.localSide).value, isNotNull);

    await p.advanceUntil(() => p.host.awaitingNextGame && p.guest.awaitingNextGame,
        what: 'the resigned game to end on both peers');
    expect(p.host.state.result!.winner, winner.localSide);
    expect(p.guest.state.result!.winner, winner.localSide);
  });

  test('a dance folds on both peers and passes the turn', () async {
    // The priming driver actually shuts a board, which is the only way a
    // scripted playout reaches a dance without hand-building a position.
    final p = await NetPair.start(length: 5, pickMove: primingMove);
    bool danced() => p.backend.events.any((e) {
          final ev = e.event;
          return ev is MoveEvent && ev.move.checkerMoves.isEmpty;
        });
    await p.advanceUntil(danced, what: 'a dance', maxIters: 200000);

    expect(danced(), isTrue);
    // The dance is a real log entry, so both folds carry it and stay level.
    await pumpUntil(() => p.host.lastSeq == p.guest.lastSeq);
    expect(p.host.frozen, isFalse);
    expect(p.guest.frozen, isFalse);
    expect(p.host.error, isNull);
    expect(p.guest.error, isNull);
  });

  test('cubeless travels in the session config and is honoured by both peers',
      () async {
    final p = await NetPair.start(cubeless: true);
    expect(p.host.cubeless, isTrue);
    expect(p.guest.cubeless, isTrue);
    await p.advanceUntil(
        () => p.host.awaitingHumanTurn || p.guest.awaitingHumanTurn,
        what: 'a pre-roll gate');
    final mover = p.host.awaitingHumanTurn ? p.host : p.guest;
    expect(mover.offerDouble, throwsStateError);
  });

  group('canonicalisation', () {
    test('a peer\'s move is FOLDED AND RECORDED in the engine\'s own form',
        () async {
      // [Game.append] computes the next state from the canonical play but stores
      // what it was handed, so the peer's rendering used to reach the animation
      // ([lastMove]) and the persisted event log — and from there the analysis
      // replay. `HostAuthority` closed this by rewriting the entry before it
      // entered the authoritative log; with the referee gone, the folding peer
      // rewrites it on the way in.
      //
      // White (the scripted host) plays first.
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 6, openingBlackDie: 3);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);

      final canonical = rig.mirrorGame().state.legalMoves.first;
      expect(canonical.checkerMoves.length, greaterThan(1),
          reason: 'a 6-3 opening plays two hops, so hop ORDER is observable');
      // The same play as the peer chooses to render it: hops in the reverse order
      // and every hit flag lied about. Still LEGAL — [GameState.canonicalPlay]
      // matches by hop multiset and ignores hit flags — so nothing freezes.
      final lying = Move([
        for (final h in canonical.checkerMoves.reversed)
          CheckerMove(h.from, h.to, isHit: !h.isHit),
      ]);
      expect(lying.checkerMoves, isNot(canonical.checkerMoves));

      rig.forge(MoveEvent(Player.white, lying));
      await pumpUntil(() => c.lastSeq == 2);
      expect(c.frozen, isFalse, reason: 'the play itself is legal');

      final recorded = c.game.events.last as MoveEvent;
      expect(recorded.move.checkerMoves, canonical.checkerMoves,
          reason: 'the log must hold the generator\'s representative');
      expect(c.lastMove.value!.event.move.checkerMoves, canonical.checkerMoves,
          reason: 'and so must the move the animation replays');
      // The property that makes it matter: replaying the RECORDED log reproduces
      // the board the fold reached. A non-canonical decomposition need not —
      // [BoardState.applyMove] is order-dependent for a transited point.
      expect(Game.replay(c.game.events).state.board, c.state.board);
    });
  });

  group('persistence', () {
    test('fires once per finished game and once per match on BOTH ends',
        () async {
      final p = await NetPair.start(length: 1);
      await p.playOut();
      await settle();

      expect(p.host.matchOver, isTrue);
      expect(p.guest.matchOver, isTrue);
      for (final rec in [p.hostPersistence, p.guestPersistence]) {
        expect(rec.games.length, 1, reason: 'a 1-point match is one game');
        final g = rec.games.single;
        expect(g.gameNumber, 1);
        expect(g.isCrawford, isTrue, reason: 'the first game of a 1-pointer');
        expect(g.events.first, isA<OpeningRollEvent>());
        expect(g.result.winner, p.host.match.winner);
        expect(g.matchAfter.isMatchOver, isTrue);
        expect(rec.matchFinishedCalls, 1);
        expect(rec.finalState!.winner, p.host.match.winner);
      }
      expect(p.host.persistenceError, isNull);
      expect(p.guest.persistenceError, isNull);
    });

    test('a persistence failure is non-fatal: sets persistenceError, folds on',
        () async {
      final p = await NetPair.start(length: 1);
      p.guestPersistence.throwOnGame = 1;
      await p.playOut();
      await settle();

      expect(p.guest.matchOver, isTrue);
      expect(p.guest.persistenceError, isNotNull);
      expect(p.guest.error, isNull, reason: 'storage never touches the loop');
      expect(p.guestPersistence.games, isEmpty);
      expect(p.guestPersistence.matchFinishedCalls, 1,
          reason: 'chained after the failed hook');
    });
  });

  group('pacing', () {
    test('a dice handshake asks the transport to go fast, and relaxes after',
        () async {
      final backend = InMemoryBackend();
      final host = InMemoryTransport.host(backend);
      final guest = InMemoryTransport.guest(backend);
      final c = NetMatchController(transport: host);
      addTearDown(c.disposeController);
      addTearDown(guest.dispose);

      // Nothing in flight before the match starts: the resting cadence.
      await c.playMatch();
      // The host commits the opening roll immediately, so a handshake is
      // outstanding and the transport has been asked to hurry.
      await settle();
      expect(host.inboundCadence, const Duration(milliseconds: 50),
          reason: 'setPaceHint(fast: true) while the commit is unanswered');

      // Drive the guest side of the handshake by hand and let the roll fold.
      final g = NetMatchController(transport: guest);
      addTearDown(g.disposeController);
      await g.playMatch();
      await pumpUntil(() => c.isReady && g.isReady,
          reason: 'the opening handshake never completed');
      expect(host.inboundCadence, const Duration(seconds: 2),
          reason: 'setPaceHint(fast: false) once the roll folded');
    });
  });

  group('lifecycle', () {
    test('disposeController disposes the transport and is idempotent', () async {
      final rig = await ScriptedRig.guest(openingWhiteDie: 6, openingBlackDie: 3);
      await pumpUntil(() => rig.controller.isReady);

      rig.controller.disposeController();
      await settle();
      rig.controller.disposeController(); // idempotent

      // The transport is gone: it refuses further work.
      await expectLater(rig.transport.eventsSince(0),
          throwsA(isA<TransportUnavailable>()));

      // And nothing folds after disposal.
      final seq = rig.backend.events.last.seq;
      rig.forge(MoveEvent(Player.white, Move.none));
      await settle();
      expect(rig.backend.events.last.seq, seq + 1);
    });

    test('a non-participant cannot connect', () async {
      final backend = InMemoryBackend();
      final stranger = InMemoryTransport(backend, 'nobody');
      final c = NetMatchController(transport: stranger);
      addTearDown(c.disposeController);
      await c.playMatch();
      expect(c.isReady, isFalse);
      expect(c.error, isA<TransportRejected>());
      // [ready] still completes, so a screen awaiting it can bail out.
      await c.ready;
    });

    test('the opening roll waits for the opponent to be present', () async {
      final backend = InMemoryBackend();
      final hostOnly = InMemoryTransport.host(backend);
      final c = NetMatchController(transport: hostOnly, rng: null);
      addTearDown(c.disposeController);
      await c.playMatch();
      await settle();

      expect(c.opponentPresent.value, isFalse);
      expect(await hostOnly.rollsSince(1), isEmpty,
          reason: 'no witness exists, so committing would only stall');

      // The joiner arrives; the host opens the match.
      final guest = InMemoryTransport.guest(backend);
      addTearDown(guest.dispose);
      await pumpUntil(() => c.opponentPresent.value);
      await pumpUntil(() => backend.rollFrames.isNotEmpty,
          reason: 'the opening roll never started once a witness existed');
    });
  });
}
