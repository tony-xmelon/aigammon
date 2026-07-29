/// The trust model: a PROVEN protocol violation freezes the match for good, a
/// transient fault never does, and the dice-lookahead squat gets nothing.
///
/// Ported from the shipped online suite's adversarial legs (the LAN controller had
/// none — it trusted its host; adopting commit-reveal + mutual validation is what
/// makes these cases apply on BOTH transports now).
library;

import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:match_transport/match_transport.dart';

import 'net_harness.dart';

void main() {
  group('cheat freeze', () {
    test('a transient inbound fault self-heals; an illegal opponent event freezes',
        () async {
      // White (the scripted host) moves first.
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 6, openingBlackDie: 3);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);

      // 1. TRANSIENT: a read blip is a banner, not a freeze, and the next
      //    successful fold clears it.
      rig.transport.simulateInboundError();
      await settle();
      expect(c.error, isNotNull);
      expect(c.frozen, isFalse);
      expect(c.isThinking, isTrue, reason: 'a blip must not change whose turn');

      final mirror = rig.mirrorGame();
      rig.forge(MoveEvent(Player.white, mirror.state.legalMoves.first));
      await pumpUntil(() => c.state.turn == Player.black);
      expect(c.error, isNull, reason: 'a good fold heals a transient fault');

      // 2. FREEZE: the host takes a cube nobody offered — the rules engine
      //    refuses it, so the match stops for good.
      rig.forge(TakeEvent(Player.white));
      await pumpUntil(() => c.frozen);

      final cheat = c.cheatError!;
      expect(cheat.code, 'illegal-event');
      expect(cheat.message, contains('frozen'));
      expect(c.error, same(cheat));
      expect(c.awaitingHumanTurn, isFalse);
      expect(c.isThinking, isFalse);
      expect(c.pendingMoveOf(Player.black).value, isNull);

      // Not self-healing: further (even perfectly good) traffic changes nothing.
      rig.transport.simulateInboundError();
      await settle();
      expect(c.error, same(cheat));
      expect(c.cheatError, same(cheat));
    });

    test('an event claiming the other seat freezes', () async {
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 6, openingBlackDie: 3);
      await pumpUntil(() => rig.controller.isReady);
      // The host writes an event for BLACK — our seat.
      rig.forge(DoubleEvent(Player.black));
      await pumpUntil(() => rig.controller.frozen);
      expect(rig.controller.cheatError!.code, 'wrong-author');
      expect(rig.controller.cheatError!.message, contains('frozen'));
    });

    test('a double in a CUBELESS match freezes, however legal it looks',
        () async {
      // The one rule the rules engine cannot see: [Game] knows nothing about the
      // cubeless flag, which is a MatchConfig fact. `HostAuthority` refused this
      // submission before it entered the log; the honest peer now refuses it on
      // the fold, which is what keeps the check from being lost with the referee.
      //
      // Deliberately staged at a moment where the cube WOULD otherwise be legal:
      // we are the host (White), we play the opening move, and the joiner is then
      // on turn awaiting its roll — the exact spot a double belongs.
      final rig = await ScriptedRig.host(
          cubeless: true, openingWhiteDie: 6, openingBlackDie: 3);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      expect(c.cubeless, isTrue);
      expect(c.state.turn, Player.white);

      c.submitMove(Player.white, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.black);
      expect(c.state.phase, GamePhase.awaitingRoll,
          reason: 'the joiner is on turn, so a double would be legal here');

      rig.forge(const DoubleEvent(Player.black));
      await pumpUntil(() => c.frozen);
      expect(c.cheatError!.code, 'cube-in-cubeless');
      expect(c.cheatError!.message, contains('without it'));
      // And the fold did NOT take it: the cube stays where it was.
      expect(c.state.cube.value, 1);
    });

    test('an event from a stranger freezes', () async {
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 6, openingBlackDie: 3);
      await pumpUntil(() => rig.controller.isReady);
      rig.forge(MoveEvent(Player.white, Move.none), author: 'someone-else');
      await pumpUntil(() => rig.controller.frozen);
      expect(rig.controller.cheatError!.code, 'not-a-participant');
    });

    test('an opening roll from the joiner freezes (openings are the host seat\'s)',
        () async {
      // A HOST controller whose joiner forges the opening, roll frame and all.
      // No joiner endpoint, so our host never starts its own opening drive and
      // the forgery is the only thing to fold.
      final rig = await ScriptedRig.host(registerOpponentEndpoint: false);
      final backend = rig.backend;
      final s = openingSecretsFor(6, 3);
      backend.createRoll(author: backend.guestAuthor, n: 1, commit: s.commit);
      backend.addEntropy(
          author: backend.hostAuthor, n: 1, entropy: s.entropy);
      backend.addReveal(author: backend.guestAuthor, n: 1, reveal: s.secret);
      backend.appendEvent(
        author: backend.guestAuthor,
        seq: 1,
        gameNo: 1,
        event: const OpeningRollEvent(whiteDie: 6, blackDie: 3),
      );

      await pumpUntil(() => rig.controller.frozen);
      expect(rig.controller.cheatError!.code, 'opening-not-host');
    });

    test('a tampered reveal freezes before any event folds', () async {
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 6, openingBlackDie: 3);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      final backend = rig.backend;

      // A roll whose revealed secret is NOT the pre-image of the commitment —
      // the only way a roller could steer the dice after seeing our entropy.
      final honest = turnSecretsFor(3, 4);
      // A DIFFERENT seed, so the swapped secret really is a different pre-image.
      final swapped = turnSecretsFor(6, 6, rng: _seeded(4242));
      backend.createRoll(
          author: backend.hostAuthor, n: 2, commit: honest.commit);
      backend.addEntropy(
          author: backend.guestAuthor, n: 2, entropy: honest.entropy);
      backend.addReveal(
          author: backend.hostAuthor, n: 2, reveal: swapped.secret);

      await pumpUntil(() => c.frozen);
      expect(c.cheatError!.code, 'fair-dice');
      expect(c.cheatError!.message, contains('tampered dice'));
      expect(c.cheatError!.message, contains('frozen'));
    });

    test('a roll event whose dice differ from the roll frame freezes', () async {
      // Black (us) opens and moves, so the NEXT roll is the host's.
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 3, openingBlackDie: 6);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      expect(c.state.turn, Player.black);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);

      // A perfectly sound roll frame deriving 3-4 …
      final backend = rig.backend;
      final s = turnSecretsFor(3, 4);
      backend.createRoll(author: backend.hostAuthor, n: 2, commit: s.commit);
      backend.addEntropy(
          author: backend.guestAuthor, n: 2, entropy: s.entropy);
      backend.addReveal(author: backend.hostAuthor, n: 2, reveal: s.secret);
      // … under an event claiming 6-6.
      rig.forge(RollEvent(Player.white, 6, 6));

      await pumpUntil(() => c.frozen);
      expect(c.cheatError!.code, 'dice-mismatch');
      expect(c.cheatError!.message, contains('frozen'));
    });

    test('a roll event authored by someone other than the roller freezes',
        () async {
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 3, openingBlackDie: 6);
      final c = rig.controller;
      await pumpUntil(() => c.isReady);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);

      // The roll is OURS (the guest committed it), but the host writes the event.
      final backend = rig.backend;
      final s = turnSecretsFor(3, 4);
      backend.createRoll(author: backend.guestAuthor, n: 2, commit: s.commit);
      backend.addEntropy(author: backend.hostAuthor, n: 2, entropy: s.entropy);
      backend.addReveal(author: backend.guestAuthor, n: 2, reveal: s.secret);
      rig.forge(RollEvent(Player.white, 3, 4));

      await pumpUntil(() => c.frozen);
      expect(c.cheatError!.code, 'roll-author');
    });
  });

  group('roll-frame abuse', () {
    test('entropy goes ONLY to the due roll — no dice lookahead', () async {
      // Black (us) opens and moves, so rolls 2, 4, 6 … are the HOST's turns: a
      // predictable parity, which is what makes the attack possible. A hostile
      // host pre-creates them and, if we answer, learns several of its coming
      // rolls before it has to choose a move or a double. The dice stay unbiased
      // and nothing ever folds illegally, so no other check sees it.
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 3, openingBlackDie: 6);
      final c = rig.controller;
      final backend = rig.backend;
      await pumpUntil(() => c.isReady);

      // The squat: its next roll (2) plus two it has no business preparing.
      for (final n in [2, 4, 6]) {
        final s = turnSecretsFor(3, 4, rng: _seeded(900 + n));
        backend.createRoll(author: backend.hostAuthor, n: n, commit: s.commit);
      }
      await settle();

      // Roll 2 is the due INDEX, but it is still black's move — white is not on
      // turn, so nothing is owed to any of them yet.
      for (final n in [2, 4, 6]) {
        expect(backend.fetchRoll(n)!.entropy, isNull);
      }

      // Our move hands white the turn. NOW roll 2 is genuinely due — and it is
      // the only one that may be answered.
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => backend.fetchRoll(2)!.entropy != null,
          reason: 'the DUE roll must still be witnessed — no deadlock');

      expect(backend.fetchRoll(4)!.entropy, isNull,
          reason: 'a roll two turns ahead must never be answered');
      expect(backend.fetchRoll(6)!.entropy, isNull);
      expect(c.frozen, isFalse, reason: 'squatting is refused, not fatal');
    });

    test('an incomplete roll backs off instead of spinning the fetcher',
        () async {
      // A peer appends its RollEvent but never reveals. The event cannot be
      // validated without a COMPLETE roll frame, so the drain blocks — and must
      // not re-fetch in a tight loop while it waits (every attempt is a billed
      // read, and the loop pins the isolate).
      final rig =
          await ScriptedRig.guest(openingWhiteDie: 3, openingBlackDie: 6);
      final c = rig.controller;
      final backend = rig.backend;
      await pumpUntil(() => c.isReady);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);

      final before = rig.transport.calls['fetchRoll'] ?? 0;
      // Committed and witnessed, but never revealed — then the event anyway.
      final s = turnSecretsFor(5, 2, rng: _seeded(31));
      backend.createRoll(author: backend.hostAuthor, n: 2, commit: s.commit);
      backend.addEntropy(
          author: backend.guestAuthor, n: 2, entropy: s.entropy);
      rig.forge(RollEvent(Player.white, 5, 2));
      await settle(400);

      final fetches = (rig.transport.calls['fetchRoll'] ?? 0) - before;
      expect(fetches, lessThanOrEqualTo(4),
          reason: 'the blocked drain must back off, not spin (saw $fetches)');
      // Still blocked, still healthy: the event has NOT been folded on trust.
      expect(c.state.turn, Player.white);
      expect(c.state.phase, GamePhase.awaitingRoll);
      expect(c.frozen, isFalse);

      // The moment the peer reveals, the frame arrives and the event folds.
      backend.addReveal(author: backend.hostAuthor, n: 2, reveal: s.secret);
      await pumpUntil(() => c.state.phase == GamePhase.moving,
          reason: 'a completed roll unblocks the drain');
      expect(c.state.dice, Dice(5, 2));
    });
  });
}

/// A distinct search seed, so two scripted secret pairs really differ.
Random _seeded(int seed) => Random(seed);
