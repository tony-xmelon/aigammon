import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

/// The relay's whole job, in one suite: hold a contiguous log, hold the
/// commit-reveal documents, police write-once ordering — and NOTHING else.
///
/// The "nothing else" half is as load-bearing as the rest. `HostAuthority`, which
/// this class replaces, refused an out-of-turn submission, an illegal move and a
/// guest-authored roll; the relay accepts all three, because the honest PEER is
/// now the referee (`app/test/net/net_cheat_freeze_test.dart` is where those same
/// writes are proven to freeze the opponent's controller). The tests below pin
/// that boundary deliberately, so nobody "fixes" the relay back into a referee
/// and quietly makes LAN and online disagree about where trust lives.
void main() {
  MatchRelay newRelay({int length = 3, bool cubeless = false}) => MatchRelay(
        config: MatchConfig(length: length, cubeless: cubeless),
        resumeToken: 'TESTTOKEN',
      );

  String hex(int fill) => fill.toRadixString(16).padLeft(kHexLength, '0');
  final commit = hex(1);
  final entropy = hex(2);
  final reveal = hex(3);

  group('the log', () {
    test('starts empty and contiguous from 1', () {
      final relay = newRelay();
      expect(relay.lastSeq, 0);
      expect(relay.nextSeq, 1);
      expect(relay.events, isEmpty);
      expect(relay.eventsSince(0), isEmpty);

      relay.appendEvent(
          author: MatchRelay.hostAuthor,
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      relay.appendEvent(
          author: MatchRelay.guestAuthor,
          seq: 2,
          gameNo: 1,
          event: const TakeEvent(Player.black));
      expect(relay.lastSeq, 2);
      expect(relay.eventsSince(0).map((e) => e.seq), [1, 2]);
      expect(relay.eventsSince(1).map((e) => e.seq), [2]);
      expect(relay.eventsSince(2), isEmpty);
    });

    test('the AUTHOR is whatever the caller says it is, and that is the point',
        () {
      // The relay is the only thing that ever sets an author, and it sets it from
      // the connection a write arrived on (see SocketTransport). Nothing on the
      // wire carries an author, so a guest cannot claim to be the host.
      final relay = newRelay();
      final host = relay.appendEvent(
          author: MatchRelay.hostAuthor,
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 3, blackDie: 1));
      final guest = relay.appendEvent(
          author: MatchRelay.guestAuthor,
          seq: 2,
          gameNo: 1,
          event: const TakeEvent(Player.black));
      expect(host.author, 'host');
      expect(guest.author, 'guest');
      expect(MatchRelay.sideOf(host.author), Player.white);
      expect(MatchRelay.sideOf(guest.author), Player.black);
      expect(MatchRelay.sideOf('someone else'), isNull);
    });

    test('a taken seq is CONTESTED and quotes the relay lastSeq', () {
      final relay = newRelay();
      relay.appendEvent(
          author: MatchRelay.hostAuthor,
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      expect(
        () => relay.appendEvent(
            author: MatchRelay.guestAuthor,
            seq: 1,
            gameNo: 1,
            event: const TakeEvent(Player.black)),
        throwsA(isA<TransportContested>()
            .having((e) => e.peerLastSeq, 'peerLastSeq', 1)),
      );
      expect(relay.lastSeq, 1, reason: 'the loser changed nothing');
    });

    test('a seq beyond the next one is REJECTED, never left as a hole', () {
      final relay = newRelay();
      expect(
        () => relay.appendEvent(
            author: MatchRelay.guestAuthor,
            seq: 4,
            gameNo: 1,
            event: const TakeEvent(Player.black)),
        throwsA(isA<TransportRejected>()
            .having((e) => e.code, 'code', 'seq-gap')),
      );
      expect(relay.events, isEmpty);
    });
  });

  group('roll documents', () {
    test('the three phases, in order', () {
      final relay = newRelay();
      final created = relay.createRoll(
          author: MatchRelay.hostAuthor, n: 1, commit: commit);
      expect(created.phase, FairDicePhase.committed);
      expect(relay.roll(1)!.commit, commit);

      final withEntropy = relay.addEntropy(
          author: MatchRelay.guestAuthor, n: 1, entropy: entropy);
      expect(withEntropy.phase, FairDicePhase.entropy);

      final done = relay.addReveal(
          author: MatchRelay.hostAuthor, n: 1, reveal: reveal);
      expect(done.phase, FairDicePhase.revealed);
      expect(done.isComplete, isTrue);
      expect(relay.roll(1)!.reveal, reveal);
    });

    test('the roll index is BOUNDED, so the store cannot grow without limit',
        () {
      // `n` arrives from the guest socket and used to be accepted as-is. A peer
      // walking it upward filled this map without limit AND grew every
      // subsequent welcome() without limit — a frame the peer then silently
      // drops, so the match dies with no diagnostic anywhere. `n` is the roll's
      // position in the match, so it is bounded by the match itself.
      final relay = newRelay();
      expect(
        () => relay.createRoll(
            author: MatchRelay.guestAuthor,
            n: MatchRelay.maxRollIndex + 1,
            commit: commit),
        throwsA(isA<TransportRejected>()),
      );
      expect(
        () => relay.createRoll(
            author: MatchRelay.guestAuthor, n: 0, commit: commit),
        throwsA(isA<TransportRejected>()),
        reason: 'roll indices are 1-based (the controller creates count + 1)',
      );
      expect(
        () => relay.createRoll(
            author: MatchRelay.guestAuthor, n: -1, commit: commit),
        throwsA(isA<TransportRejected>()),
      );
      expect(relay.rollFrames, isEmpty,
          reason: 'a refused index leaves nothing behind');
      // The last index in range still works, so the bound is a ceiling and not
      // an off-by-one.
      relay.createRoll(
          author: MatchRelay.guestAuthor,
          n: MatchRelay.maxRollIndex,
          commit: commit);
      expect(relay.rollFrames, hasLength(1));
    });

    test('a taken roll index is CONTESTED', () {
      final relay = newRelay();
      relay.createRoll(author: MatchRelay.hostAuthor, n: 1, commit: commit);
      expect(
        () => relay.createRoll(
            author: MatchRelay.guestAuthor, n: 1, commit: entropy),
        throwsA(isA<TransportContested>()),
      );
      expect(relay.roll(1)!.roller, MatchRelay.hostAuthor);
    });

    test('the roller cannot supply its own entropy', () {
      final relay = newRelay();
      relay.createRoll(author: MatchRelay.hostAuthor, n: 1, commit: commit);
      expect(
        () => relay.addEntropy(
            author: MatchRelay.hostAuthor, n: 1, entropy: entropy),
        throwsA(isA<TransportRejected>()
            .having((e) => e.code, 'code', 'entropy-by-roller')),
      );
      expect(relay.roll(1)!.entropy, isNull);
    });

    test('entropy is write-once, and cannot follow a reveal', () {
      final relay = newRelay();
      relay.createRoll(author: MatchRelay.hostAuthor, n: 1, commit: commit);
      relay.addEntropy(
          author: MatchRelay.guestAuthor, n: 1, entropy: entropy);
      expect(
        () => relay.addEntropy(
            author: MatchRelay.guestAuthor, n: 1, entropy: reveal),
        throwsA(isA<TransportRejected>()
            .having((e) => e.code, 'code', 'entropy-write-once')),
      );
      expect(relay.roll(1)!.entropy, entropy);
    });

    test('only the roller may reveal, and only AFTER the entropy', () {
      final relay = newRelay();
      relay.createRoll(author: MatchRelay.hostAuthor, n: 1, commit: commit);
      // THE fairness ordering: revealing before the witness has committed its
      // entropy would let the roller pick the entropy that suits it.
      expect(
        () => relay.addReveal(
            author: MatchRelay.hostAuthor, n: 1, reveal: reveal),
        throwsA(isA<TransportRejected>()
            .having((e) => e.code, 'code', 'reveal-before-entropy')),
      );
      relay.addEntropy(
          author: MatchRelay.guestAuthor, n: 1, entropy: entropy);
      expect(
        () => relay.addReveal(
            author: MatchRelay.guestAuthor, n: 1, reveal: reveal),
        throwsA(isA<TransportRejected>()
            .having((e) => e.code, 'code', 'reveal-not-roller')),
      );
      relay.addReveal(author: MatchRelay.hostAuthor, n: 1, reveal: reveal);
      expect(
        () => relay.addReveal(
            author: MatchRelay.hostAuthor, n: 1, reveal: entropy),
        throwsA(isA<TransportRejected>()
            .having((e) => e.code, 'code', 'reveal-write-once')),
      );
      expect(relay.roll(1)!.reveal, reveal);
    });

    test('a phase write to a roll that does not exist is refused', () {
      final relay = newRelay();
      expect(
        () => relay.addEntropy(
            author: MatchRelay.guestAuthor, n: 7, entropy: entropy),
        throwsA(isA<TransportRejected>().having((e) => e.code, 'code', 'no-roll')),
      );
    });

    test('rollsFrom is ascending and index-bounded', () {
      final relay = newRelay();
      for (final n in [3, 1, 2]) {
        relay.createRoll(author: MatchRelay.hostAuthor, n: n, commit: commit);
      }
      expect(relay.rollFrames.map((r) => r.n), [1, 2, 3]);
      expect(relay.rollsFrom(2).map((r) => r.n), [2, 3]);
      expect(relay.rollsFrom(9), isEmpty);
      expect(relay.roll(9), isNull);
    });
  });

  group('what the relay deliberately does NOT police', () {
    test('an out-of-turn, illegal, result-claiming write is accepted', () {
      // Every one of these was refused by HostAuthority. The relay takes them —
      // and the opponent CONTROLLER freezes on them (see the app-level suite).
      final relay = newRelay();
      relay.appendEvent(
          author: MatchRelay.hostAuthor,
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      // White is on turn after a 6-1 opening; Black moves anyway, from a point it
      // does not occupy, with a hit it invented.
      relay.appendEvent(
        author: MatchRelay.guestAuthor,
        seq: 2,
        gameNo: 1,
        event: MoveEvent(
            Player.black, Move([const CheckerMove(3, 1, isHit: true)])),
      );
      // ...and a roll event with no roll document behind it at all.
      relay.appendEvent(
          author: MatchRelay.guestAuthor,
          seq: 3,
          gameNo: 1,
          event: const RollEvent(Player.black, 6, 6));
      expect(relay.lastSeq, 3, reason: 'the relay is not a referee');
      expect(relay.rollFrames, isEmpty, reason: 'and it never deals a die');
    });

    test('a guest may create a roll for any index — the lookahead defence is '
        'the controller\'s', () {
      final relay = newRelay();
      for (final n in [1, 2, 3, 4]) {
        relay.createRoll(author: MatchRelay.guestAuthor, n: n, commit: commit);
      }
      expect(relay.rollFrames, hasLength(4));
      // The squat is harmless because a witness only ever answers the DUE index
      // (NetMatchController._isDueRoll), so none of these ever gets entropy.
    });

    test('a cubeless match still carries a DoubleEvent if a peer writes one',
        () {
      final relay = newRelay(cubeless: true);
      relay.appendEvent(
          author: MatchRelay.guestAuthor,
          seq: 1,
          gameNo: 1,
          event: const DoubleEvent(Player.black));
      expect(relay.lastSeq, 1);
      // The rules engine refuses it on the fold, on BOTH peers.
    });
  });

  group('committed stream and welcome', () {
    test('every commit is published once, in order', () async {
      final relay = newRelay();
      final seen = <InboundFrame>[];
      relay.committed.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      relay.createRoll(author: MatchRelay.hostAuthor, n: 1, commit: commit);
      relay.addEntropy(
          author: MatchRelay.guestAuthor, n: 1, entropy: entropy);
      relay.addReveal(author: MatchRelay.hostAuthor, n: 1, reveal: reveal);
      relay.appendEvent(
          author: MatchRelay.hostAuthor,
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(4));
      expect(seen.whereType<RollFrame>().map((r) => r.phase), [
        FairDicePhase.committed,
        FairDicePhase.entropy,
        FairDicePhase.revealed,
      ]);
      expect(seen.last, isA<EventFrame>());
      // A refused write publishes nothing.
      expect(
          () => relay.appendEvent(
              author: MatchRelay.guestAuthor,
              seq: 1,
              gameNo: 1,
              event: const TakeEvent(Player.black)),
          throwsA(isA<TransportContested>()));
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(4));
    });

    test('welcome carries the config, the guest seat, the token, log and rolls',
        () {
      final relay = newRelay(length: 5, cubeless: true);
      relay.createRoll(author: MatchRelay.hostAuthor, n: 1, commit: commit);
      relay.appendEvent(
          author: MatchRelay.hostAuthor,
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      final welcome = relay.welcome();
      expect(welcome.config, const MatchConfig(length: 5, cubeless: true));
      expect(welcome.side, Player.black);
      expect(welcome.resume, 'TESTTOKEN');
      expect(welcome.log.map((e) => e.seq), [1]);
      expect(welcome.rolls.map((r) => r.n), [1]);
    });

    test('a fresh relay mints its own distinct token', () {
      final a = MatchRelay(config: const MatchConfig(length: 1));
      final b = MatchRelay(config: const MatchConfig(length: 1));
      expect(a.resumeToken, hasLength(12));
      expect(a.resumeToken, isNot(b.resumeToken),
          reason: 'a restarted host must be recognisable as a NEW match');
    });

    test('close is idempotent and refuses later writes', () async {
      final relay = newRelay();
      await relay.close();
      await relay.close();
      expect(
          () => relay.appendEvent(
              author: MatchRelay.hostAuthor,
              seq: 1,
              gameNo: 1,
              event: const TakeEvent(Player.white)),
          throwsA(isA<TransportUnavailable>()));
    });
  });
}
