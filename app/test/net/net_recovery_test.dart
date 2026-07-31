/// Recovery: the resync/replace paths, the [ResetFrame] contract, the match
/// identity reset, the contested-seq retry, the gate deadline and the durable
/// rejoin.
///
/// The merged superset of `lan_link_recovery_test` (gaps, gate deadline, identity
/// reset, no re-animation, no double persistence) and the online suite's resync
/// group (lost seq race, roll-counter recovery, resumed roll drive).
library;

import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:match_transport/match_transport.dart';

import 'net_harness.dart';

void main() {
  group('gap + replace', () {
    test('a dropped frame is a GAP that the whole log closes', () async {
      // Black (us) moves first, so the host's answering turn is scripted.
      // White's answering roll is AIMED at 5-2, so its document has to
      // PRE-EXIST: choosing a roller secret together with the witness entropy is
      // the substitution a live witness now freezes on. See
      // [ScriptedRig.scriptSeededTurn].
      final rig = await ScriptedRig.guest(
        openingWhiteDie: 3,
        openingBlackDie: 6,
        seed: (b) => b.seedRollDoc(author: b.hostAuthor, die1: 5, die2: 2),
      );
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      expect(c.lastSeq, 1, reason: 'seqs are contiguous FROM 1');

      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.lastSeq == 2);

      // The relay loses the host's roll event; only the move after it arrives.
      rig.transport.dropEventSeqs.add(3);
      rig.scriptSeededTurn();

      // The gap cannot be closed incrementally — the whole log is re-read, and
      // that heals it.
      await pumpUntil(() => c.lastSeq == 4,
          reason: 'the full replace never caught up');
      expect(c.error, isNull, reason: 'the rebuild healed the divergence');
      expect(c.frozen, isFalse);
      expect((rig.transport.calls['eventsSince'] ?? 0), greaterThan(1));
    });

    test('a full replace does not re-animate the moves it replays', () async {
      // White's answering roll is AIMED at 5-2, so its document has to
      // PRE-EXIST: choosing a roller secret together with the witness entropy is
      // the substitution a live witness now freezes on. See
      // [ScriptedRig.scriptSeededTurn].
      final rig = await ScriptedRig.guest(
        openingWhiteDie: 3,
        openingBlackDie: 6,
        seed: (b) => b.seedRollDoc(author: b.hostAuthor, die1: 5, die2: 2),
      );
      final c = rig.controller;
      await pumpUntil(() => c.isReady);

      var fires = 0;
      c.lastMove.addListener(() => fires++);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.lastSeq == 2);
      rig.scriptSeededTurn();
      await pumpUntil(() => c.lastSeq == 4);
      final liveFires = fires;
      expect(liveFires, greaterThan(0), reason: 'live moves DO animate');

      // A ResetFrame: "throw your fold away and replay from the log."
      rig.transport.simulateReset();
      await pumpUntil(() => c.error == null && c.lastSeq == 4,
          reason: 'the reset never replayed the log');
      expect(fires, liveFires,
          reason: 'a replace snaps to the position; it does not replay the game');
    });

    test('a ResetFrame replay does not persist a finished game twice', () async {
      final p = await NetPair.start(length: 1);
      await p.playOut();
      await settle();
      expect(p.guestPersistence.games.length, 1);
      expect(p.guestPersistence.matchFinishedCalls, 1);
      final seq = p.guest.lastSeq;

      // The same log again (a reconnect's reset). Everything re-derives; nothing
      // is recorded twice.
      (p.guest.transport as InMemoryTransport).simulateReset();
      await settle(200);
      expect(p.guest.matchOver, isTrue);
      expect(p.guest.lastSeq, seq);
      expect(p.guestPersistence.games.length, 1,
          reason: 'the game was already persisted');
      expect(p.guestPersistence.matchFinishedCalls, 1);
    });

    test('a game that ended while we were away pauses once, then not again',
        () async {
      final p = await NetPair.start(length: 5);
      // Play until game 2 has begun on the guest, so its log holds a finished
      // game 1 followed by game 2's opening roll.
      await p.advanceUntil(() => p.guest.gameNumber >= 2,
          what: 'game 2 to start');
      expect(p.pauses, greaterThan(0),
          reason: 'the game-over dialog is owed for a game that ended');
      final games = p.guestPersistence.games.length;

      // A SECOND replay must not re-open the dialog the user just dismissed.
      (p.guest.transport as InMemoryTransport).simulateReset();
      await settle(200);
      expect(p.guest.awaitingNextGame, isFalse);
      expect(p.guest.gameNumber, greaterThanOrEqualTo(2));
      expect(p.guestPersistence.games.length, games);
    });

    test('a ResetFrame with a DIFFERENT resume token voids the watermarks',
        () async {
      final p = await NetPair.start(length: 1);
      await p.playOut();
      await settle();
      expect(p.guestPersistence.games.length, 1);
      expect(p.guestPersistence.matchFinishedCalls, 1);

      // The host restarted (or a room code collided) and we are folding a
      // DIFFERENT authority's log: its game 1 has never been recorded here.
      p.backend.resumeToken = 'A-DIFFERENT-MATCH';
      (p.guest.transport as InMemoryTransport).simulateReset(reason: 'restart');
      await settle(200);

      expect(p.guest.matchOver, isTrue);
      expect(p.guestPersistence.games.length, 2,
          reason: 'the new identity records its own game 1');
      expect(p.guestPersistence.games.last.gameNumber, 1);
      expect(p.guestPersistence.matchFinishedCalls, 2);
    });

    test('a ResetFrame with a DIFFERENT identity adopts that match\'s CONFIG',
        () async {
      // The room-code collision the identity reset was written for, carried
      // through to its consequence. The controller writes its session ONCE (at
      // construction / connect), so adopting only the resume token left the
      // MatchConfig behind: the replayed log was folded with the previous match's
      // length, and — the part that matters — with its stale `cubeless` flag, so
      // the new opponent's perfectly legal double froze the match with
      // `cube-in-cubeless`. That was the only way this controller could freeze an
      // honest peer.
      // We are the host (white) and play the opening move, so the joiner is then
      // on turn awaiting its roll — the exact spot a double belongs.
      final rig = await ScriptedRig.host(
          length: 1, cubeless: true, openingWhiteDie: 6, openingBlackDie: 3);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      expect(c.cubeless, isTrue);
      expect(c.match.matchLength, 1);
      c.submitMove(Player.white, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.black);

      // A DIFFERENT authority's match, with its own parameters, on the same code.
      rig.backend
        ..config = const MatchConfig(length: 5)
        ..resumeToken = 'A-DIFFERENT-MATCH';
      rig.transport.simulateReset(reason: 'room code collision');

      await pumpUntil(() => c.match.matchLength == 5,
          reason: 'a new identity brings its own match length');
      expect(c.cubeless, isFalse, reason: 'and its own cube agreement');

      await pumpUntil(() => c.state.phase == GamePhase.awaitingRoll);
      expect(c.state.turn, Player.black);
      rig.forge(const DoubleEvent(Player.black));
      await pumpUntil(() => c.state.phase == GamePhase.cubeOffered,
          reason: 'an honest double in a cubeful match must simply fold');
      expect(c.frozen, isFalse);
    });

    test('a log that will NEVER replay is re-read a bounded number of times',
        () async {
      // The read-budget hole this closes. An event authored by US that the engine
      // refuses is not a cheat (we wrote it) and not retryable, so the fold stops
      // below the log's end permanently — and then EVERY later frame arrives as a
      // gap and asks for the whole log again. One `eventsSince(0)` +
      // `rollsSince(1)` per inbound frame, against a 50,000-read daily quota, for
      // the rest of the match.
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 3, openingBlackDie: 6);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      final primed = rig.transport.calls['eventsSince'] ?? 0;

      // A take with no double outstanding: our own author, and the engine will
      // refuse it on every replay for as long as the log exists.
      rig.forge(const TakeEvent(Player.black), author: rig.localAuthor);
      await pumpUntil(() => c.error != null,
          reason: 'the unfoldable own event never surfaced');
      expect(c.frozen, isFalse, reason: 'our own event is not a cheat');

      // Now keep the frames coming. Each is a fresh gap over a fold that cannot
      // advance, which is exactly the shape that used to re-read the log forever.
      for (var i = 0; i < 8; i++) {
        rig.forge(const TakeEvent(Player.black), author: rig.localAuthor);
        await settle();
      }
      await settle();

      final reads = (rig.transport.calls['eventsSince'] ?? 0) - primed;
      expect(reads, lessThanOrEqualTo(4),
          reason: 'the log was re-read $reads times for 9 unfoldable frames — '
              'the failed-replay bound is not holding');
      expect(reads, greaterThan(0), reason: 'it must try at least once');
      expect(c.error, isNotNull, reason: 'and the banner must stay up');
    });
  });

  group('contested writes', () {
    test('a submission that loses the seq race resyncs and keeps it pending',
        () async {
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 3, openingBlackDie: 6);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);

      final before = rig.transport.calls['eventsSince'] ?? 0;
      rig.transport.intercept = (op) => op == 'sendEvent'
          ? const TransportContested('seq-taken', 'events/2 already exists')
          : null;
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(
          () => (rig.transport.calls['eventsSince'] ?? 0) > before,
          reason: 'a lost race must trigger a full replace');
      await settle();

      // A lost race is NOT a cheat, and it is NOT retried at the same seq: the
      // log is re-read and the decision stays pending for the user.
      expect(c.frozen, isFalse);
      expect(rig.transport.calls['sendEvent'], 1,
          reason: 'no blind retry at that seq');
      expect(c.pendingMoveOf(Player.black).value, isNotNull);

      // With the fault cleared the same decision goes through.
      rig.transport.intercept = null;
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);
      expect(c.error, isNull);
    });

    test('the roll counter survives a resync', () async {
      // White's answering roll is AIMED at 5-2, so its document has to
      // PRE-EXIST: choosing a roller secret together with the witness entropy is
      // the substitution a live witness now freezes on. See
      // [ScriptedRig.scriptSeededTurn].
      final rig = await ScriptedRig.guest(
        openingWhiteDie: 3,
        openingBlackDie: 6,
        seed: (b) => b.seedRollDoc(author: b.hostAuthor, die1: 5, die2: 2),
      );
      final c = rig.controller;
      final backend = rig.backend;
      await pumpUntil(() => c.isReady);

      // Force a full rebuild by losing the sequence race once.
      rig.transport.intercept = (op) =>
          op == 'sendEvent' ? const TransportContested('taken', 'taken') : null;
      c.submitMove(Player.black, c.state.legalMoves.first);
      await settle(40);
      rig.transport.intercept = null;

      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);
      rig.scriptSeededTurn();
      await pumpUntil(() => c.awaitingHumanTurn,
          reason: 'the pre-roll gate never came back to us');

      // Two roll-bearing events are in the log (the opening and white's roll),
      // so OUR roll must claim index 3 — recounted from the log, not from a
      // counter the resync could have lost.
      expect(backend.rollCount, 2);
      expect(c.rollCount, 2);
      c.rollDice();
      await pumpUntil(() => backend.fetchRoll(3) != null);
      expect(backend.fetchRoll(3)!.roller, backend.guestAuthor);
      expect(backend.fetchRoll(4), isNull);
      expect(c.frozen, isFalse);
    });

    test('a failed roll re-opens the gate and the retry RESUMES the same roll',
        () async {
      // White's answering roll is AIMED at 5-2, so its document has to
      // PRE-EXIST: choosing a roller secret together with the witness entropy is
      // the substitution a live witness now freezes on. See
      // [ScriptedRig.scriptSeededTurn].
      final rig = await ScriptedRig.guest(
        openingWhiteDie: 3,
        openingBlackDie: 6,
        seed: (b) => b.seedRollDoc(author: b.hostAuthor, die1: 5, die2: 2),
      );
      final c = rig.controller;
      final backend = rig.backend;
      await pumpUntil(() => c.isReady);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);
      rig.scriptSeededTurn();
      await pumpUntil(() => c.awaitingHumanTurn);

      rig.transport.intercept = (op) => op == 'createRoll'
          ? const TransportUnavailable('unavailable', 'blip')
          : null;
      c.rollDice();
      await pumpUntil(() => c.error != null);
      expect(c.frozen, isFalse);
      expect(c.awaitingHumanTurn, isTrue,
          reason: 'one blip must not deadlock the pre-roll gate');
      expect(backend.fetchRoll(3), isNull);

      rig.transport.intercept = null;
      c.rollDice();
      await pumpUntil(() => backend.fetchRoll(3) != null);
      // Resumed, not restarted: exactly one roll frame, at the same index.
      expect(backend.fetchRoll(4), isNull);
      expect(backend.fetchRoll(3)!.roller, backend.guestAuthor);
    });

    test('a REJECTED createRoll stops instead of retrying forever', () async {
      // A rejection is deterministic — the backend refused the write on its
      // merits, so an identical retry earns an identical refusal. Retrying it on
      // the roll beat is an unbounded write loop against a METERED backend, not
      // a recovery. Compare the witness's entropy step, which has always marked
      // the step done and surfaced the error.
      final rig = await ScriptedRig.guest(
        openingWhiteDie: 3,
        openingBlackDie: 6,
        seed: (b) => b.seedRollDoc(author: b.hostAuthor, die1: 5, die2: 2),
      );
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);
      rig.scriptSeededTurn();
      await pumpUntil(() => c.awaitingHumanTurn);

      rig.transport.intercept = (op) => op == 'createRoll'
          ? const TransportRejected('refused', 'the match is not active')
          : null;
      c.rollDice();
      await pumpUntil(() => c.error != null);
      final attempts = rig.transport.calls['createRoll'];
      expect(attempts, isNotNull);
      // Real time, well past several beats of the 200ms roll-retry timer.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(rig.transport.calls['createRoll'], attempts,
          reason: 'a refused create must not be re-attempted on the beat');
      expect(c.error, isNotNull, reason: 'and the refusal must be surfaced');
      expect(c.frozen, isFalse);
      expect(rig.backend.fetchRoll(3), isNull);
    });

    test('a REJECTED sendReveal stops instead of retrying forever', () async {
      final rig = await ScriptedRig.guest(
        openingWhiteDie: 3,
        openingBlackDie: 6,
        seed: (b) => b.seedRollDoc(author: b.hostAuthor, die1: 5, die2: 2),
      );
      final c = rig.controller;
      final backend = rig.backend;
      await pumpUntil(() => c.isReady);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);
      rig.scriptSeededTurn();
      await pumpUntil(() => c.awaitingHumanTurn);

      // Commit lands; then the (scripted) opponent witnesses it, so the drive
      // moves on to the reveal — which is the step the backend refuses.
      c.rollDice();
      await pumpUntil(() => backend.fetchRoll(3) != null);
      rig.transport.intercept = (op) => op == 'sendReveal'
          ? const TransportRejected('refused', 'the match is not active')
          : null;
      backend.addEntropy(
        author: rig.peerAuthor,
        n: 3,
        entropy: 'b' * 64,
      );
      await pumpUntil(() => (rig.transport.calls['sendReveal'] ?? 0) > 0,
          reason: 'the drive never reached the reveal step');
      await pumpUntil(() => c.error != null);
      final attempts = rig.transport.calls['sendReveal'];
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(rig.transport.calls['sendReveal'], attempts,
          reason: 'a refused reveal must not be re-attempted on the beat');
      expect(c.error, isNotNull);
      expect(c.frozen, isFalse);
      expect(backend.fetchRoll(3)!.reveal, isNull);
    });
  });

  group('the gate', () {
    test('the submitting latch is published for the UI', () async {
      // A LIVE pair: the latch only clears when the log answers, which needs a
      // real witness on the other end of the handshake.
      final p = await NetPair.start(length: 5);
      await p.advanceUntil(
          () => p.host.awaitingHumanTurn || p.guest.awaitingHumanTurn,
          what: 'a pre-roll gate');
      final c = p.host.awaitingHumanTurn ? p.host : p.guest;

      final seen = <bool>[];
      c.submitting.addListener(() => seen.add(c.submitting.value));
      expect(c.submitting.value, isFalse);

      c.rollDice();
      expect(c.submitting.value, isTrue,
          reason: 'the intent is in flight and the log has not answered');
      expect(c.awaitingHumanTurn, isFalse);

      await pumpUntil(() => !c.submitting.value,
          reason: 'the latch never cleared when the roll folded');
      expect(seen.first, isTrue);
      expect(seen.last, isFalse);
    });

    test('an intent nothing ever answers re-opens the gate on its deadline',
        () async {
      final rig = await ScriptedRig.guest(
        openingWhiteDie: 3,
        openingBlackDie: 6,
        gateTimeout: const Duration(milliseconds: 150),
      );
      final c = rig.controller;
      await pumpUntil(() => c.isReady);

      // The send COMMITS (the await returns) and the echo is then silently
      // dropped — a relay over its rate limit. Nothing will ever answer.
      rig.transport.swallowSends = true;
      final move = c.state.legalMoves.first;
      c.submitMove(Player.black, move);
      await settle();
      expect(c.submitting.value, isTrue);
      expect(c.pendingMoveOf(Player.black).value, isNotNull);

      await waitFor(() => !c.submitting.value, what: 'the latch deadline');
      expect((c.error! as NetMatchException).code, 'offline');
      expect(c.frozen, isFalse);

      // Acting again works, and this time it is answered.
      rig.transport.swallowSends = false;
      c.submitMove(Player.black, move);
      await pumpUntil(() => c.state.turn == Player.white,
          reason: 'a dropped frame costs one timeout, not the match');
    });
  });

  group('link lifecycle', () {
    test('a drop re-opens the gate and the return rejoins the match', () async {
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 3, openingBlackDie: 6);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      expect(c.linkStatus.value, TransportStatus.connected);
      expect(rig.transport.capabilities.rejoinable, isTrue);

      rig.transport.swallowSends = true;
      c.submitMove(Player.black, c.state.legalMoves.first);
      await settle();
      expect(c.submitting.value, isTrue);

      rig.transport.simulateDrop();
      await settle();
      expect(c.linkStatus.value, TransportStatus.reconnecting);
      expect(c.submitting.value, isFalse,
          reason: 'a down link cannot deliver the answer we were waiting for');

      // Meanwhile the opponent played on. The rejoin re-reads the log.
      rig.transport.swallowSends = false;
      final before = rig.transport.calls['eventsSince'] ?? 0;
      rig.transport.simulateReconnect();
      await pumpUntil(
          () => (rig.transport.calls['eventsSince'] ?? 0) > before,
          reason: 'a rejoinable transport must re-read the log on return');
      expect(c.linkStatus.value, TransportStatus.connected);
      await pumpUntil(() => c.error == null);
      expect(c.frozen, isFalse);
    });

    test('a non-rejoinable transport does not re-read on return', () async {
      final backend = InMemoryBackend(
        capabilities: const Capabilities(durable: false, rejoinable: false),
      );
      backend.seedOpening(whiteDie: 3, blackDie: 6);
      final peer = InMemoryTransport.host(backend);
      addTearDown(peer.dispose);
      final transport = ProxyTransport(InMemoryTransport.guest(backend));
      final c = NetMatchController(transport: transport);
      addTearDown(c.disposeController);
      await c.playMatch();
      await pumpUntil(() => c.isReady);

      final before = transport.calls['eventsSince'] ?? 0;
      transport.simulateDrop();
      await settle();
      transport.simulateReconnect();
      await settle(40);
      expect(transport.calls['eventsSince'] ?? 0, before,
          reason: 'a socket session ends with the connection; the relay sends a '
              'ResetFrame instead');
    });
  });

  group('convergence', () {
    test('two controllers agree on the whole game after every exchange',
        () async {
      // [NetPair.playOut] asserts [positionSignature] equality after every
      // exchange; this case exists to state that as the contract it is.
      final p = await NetPair.start(length: 3);
      await p.playOut();
      expect(positionSignature(p.host), positionSignature(p.guest));
      expect(p.host.lastSeq, p.guest.lastSeq);
      expect(p.host.rollCount, p.guest.rollCount);
    });
  });
}
