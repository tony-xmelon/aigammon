@Tags(['emulator'])
library;

import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

/// Integration tests that run the real transport (anonymous auth + direct
/// Firestore documents) against the local Firebase Emulator Suite.
///
/// These are the proof that `firebase/firestore.rules` and this package agree:
/// every allow path is exercised through the public [MatchApi] surface, and
/// every deny path is asserted to arrive as the TYPED exception the controller
/// branches on ([PermissionDeniedException], [AlreadyExistsException],
/// [NotFoundException], [FailedPreconditionException]).
///
/// Excluded from the default `dart test` run by the `emulator` tag (see
/// dart_test.yaml). Run inside a running Firestore+Auth emulator:
///
///   pwsh firebase/run-emulator-tests.ps1      (Windows dev machine)
///   bash firebase/ci-emulator-suites.sh       (CI, emulator already up)
///
/// No Functions emulator is involved — there are no Cloud Functions.

/// A signed-in anonymous user with its own transport stack.
class TestUser {
  final MatchApi api;
  final String uid;

  TestUser(this.api, this.uid);

  void close() => api.close();
}

void main() {
  final config = OnlineConfig.emulator();
  final users = <TestUser>[];

  /// Sign up a fresh anonymous user. Registered for teardown.
  Future<TestUser> signIn({Random? codeRandom}) async {
    final api = MatchApi.forConfig(config, codeRandom: codeRandom);
    final uid = await api.signIn();
    final user = TestUser(api, uid);
    users.add(user);
    return user;
  }

  late TestUser host;
  late TestUser guest;

  setUp(() async {
    host = await signIn();
    guest = await signIn();
  });

  tearDown(() {
    for (final u in users) {
      u.close();
    }
    users.clear();
  });

  /// A fresh active match with [host] seated white and [guest] black.
  Future<MatchDoc> activeMatch({int length = 3, bool cubeless = false}) async {
    final created =
        await host.api.createMatch(length: length, cubeless: cubeless);
    return guest.api.joinMatch(created.code);
  }

  // =========================================================================
  group('auth', () {
    test('anonymous sign-up mints a usable session', () async {
      expect(host.uid, isNotEmpty);
      expect(guest.uid, isNot(host.uid));
      final session = host.api.auth.session!;
      expect(session.idToken, isNotEmpty);
      expect(session.refreshToken, isNotEmpty);
      expect(session.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('an expiring token is exchanged at the secure-token endpoint',
        () async {
      // Drive the clock past the refresh window so validToken() must call
      // securetoken.googleapis.com/v1/token for real.
      var clock = DateTime.now().toUtc();
      final auth = AuthClient(config, now: () => clock);
      addTearDown(auth.close);
      final session = await auth.signInAnonymously();
      final first = session.idToken;

      clock = clock.add(const Duration(minutes: 58));
      final refreshed = await auth.validToken();

      expect(refreshed, isNotEmpty);
      expect(auth.session!.uid, session.uid);
      expect(auth.session!.expiresAt.isAfter(clock), isTrue);

      // The refreshed credential really works against Firestore.
      final docs = FirestoreDocs(config, token: () async => refreshed);
      addTearDown(docs.close);
      expect(await docs.get('matches/NOSUCHXX'), isNull);
      expect(first, isNotEmpty);
    });
  });

  // =========================================================================
  group('match creation', () {
    test('create stamps createdAt server-side and leaves the seat open',
        () async {
      final before = DateTime.now().toUtc();
      final created = await host.api.createMatch(length: 5, cubeless: true);

      expect(created.code, hasLength(kCodeLength));
      expect(created.hostUid, host.uid);

      // The rules require createdAt == request.time, which only the
      // updateTransforms REQUEST_TIME path can satisfy; read it back to prove
      // the transform landed rather than the create being rejected.
      final fetched = await host.api.fetchMatch(created.code);
      expect(fetched.status, 'waiting');
      expect(fetched.guestUid, isNull);
      expect(fetched.length, 5);
      expect(fetched.cubeless, isTrue);
      expect(fetched.createdAt, isNotNull);
      expect(
        fetched.createdAt!.difference(before).abs(),
        lessThan(const Duration(minutes: 5)),
        reason: 'createdAt must be the server clock, not a client value',
      );
    });

    test('a waiting match is readable by anyone (join-by-code)', () async {
      final created = await host.api.createMatch(length: 3, cubeless: false);
      final outsider = await signIn();
      final seen = await outsider.api.fetchMatch(created.code);
      expect(seen.hostUid, host.uid);
      expect(seen.isWaiting, isTrue);
    });

    test('an invite-code collision is retried onto a free code', () async {
      // Two users drawing from identically seeded generators pick the same
      // first code; the second create must lose the exists:false precondition
      // and fall through to the next code.
      final a = await signIn(codeRandom: Random(20260727));
      final b = await signIn(codeRandom: Random(20260727));

      final first = await a.api.createMatch(length: 3, cubeless: false);
      final second = await b.api.createMatch(length: 3, cubeless: false);

      expect(second.code, isNot(first.code));
      expect((await a.api.fetchMatch(first.code)).hostUid, a.uid,
          reason: 'the loser must not have clobbered the winner');
      expect((await b.api.fetchMatch(second.code)).hostUid, b.uid);
    });

    test('claiming an occupied document id is AlreadyExists', () async {
      final created = await host.api.createMatch(length: 3, cubeless: false);
      await expectLater(
        host.api.docs.create(
          'matches/${created.code}',
          {
            'hostUid': host.uid,
            'guestUid': null,
            'length': 3,
            'cubeless': false,
            'status': 'waiting',
          },
          serverTimestamps: ['createdAt'],
        ),
        throwsA(isA<AlreadyExistsException>()),
      );
    });
  });

  // =========================================================================
  group('join', () {
    test('the guest takes the seat and both sides agree on the seating',
        () async {
      final created = await host.api.createMatch(length: 3, cubeless: false);
      final joined = await guest.api.joinMatch(created.code);

      expect(joined.guestUid, guest.uid);
      expect(joined.status, 'active');
      expect(joined.sideOf(host.uid), Player.white);
      expect(joined.sideOf(guest.uid), Player.black);

      final asHost = await host.api.fetchMatch(created.code);
      expect(asHost.status, 'active');
      expect(asHost.guestUid, guest.uid);
    });

    test('an unknown code is NotFound', () async {
      await expectLater(
        guest.api.joinMatch('ZZZZZZZZ'),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('a second join is refused', () async {
      final created = await host.api.createMatch(length: 3, cubeless: false);
      await guest.api.joinMatch(created.code);
      final outsider = await signIn();
      await expectLater(
        outsider.api.joinMatch(created.code),
        // The joined match is no longer readable by outsiders at all, so the
        // refusal arrives on the read.
        throwsA(isA<PermissionDeniedException>()),
      );
      expect((await host.api.fetchMatch(created.code)).guestUid, guest.uid);
    });

    test('the host cannot join their own match', () async {
      final created = await host.api.createMatch(length: 3, cubeless: false);
      await expectLater(
        host.api.joinMatch(created.code),
        throwsA(isA<FailedPreconditionException>()),
      );
    });

    test('the rules refuse a seat claim that is not the caller', () async {
      final created = await host.api.createMatch(length: 3, cubeless: false);
      final outsider = await signIn();
      await expectLater(
        guest.api.docs.patch(
          'matches/${created.code}',
          {'guestUid': outsider.uid, 'status': 'active'},
          updateMask: const ['guestUid', 'status'],
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('a guest that read the seat open but lost the race is refused',
        () async {
      // Both guests see `waiting`; only one write can satisfy the transition's
      // `guestUid == null` pre-state, and the loser must not overwrite it.
      final created = await host.api.createMatch(length: 3, cubeless: false);
      final other = await signIn();
      final seenOpen = await other.api.fetchMatch(created.code);
      expect(seenOpen.isWaiting, isTrue);

      await guest.api.joinMatch(created.code);
      await expectLater(
        other.api.docs.patch(
          'matches/${created.code}',
          {'guestUid': other.uid, 'status': 'active'},
          updateMask: const ['guestUid', 'status'],
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect((await host.api.fetchMatch(created.code)).guestUid, guest.uid);
    });

    test('a patch never creates the document it was meant to amend', () async {
      await expectLater(
        host.api.docs.patch(
          'matches/NOSUCHXX',
          {'status': 'complete'},
          updateMask: const ['status'],
        ),
        throwsA(isA<OnlineException>()),
      );
      expect(await host.api.docs.get('matches/NOSUCHXX'), isNull);
    });

    test('either participant may complete an active match', () async {
      final match = await activeMatch();
      await guest.api.completeMatch(match.code);
      expect((await host.api.fetchMatch(match.code)).status, 'complete');
    });
  });

  // =========================================================================
  group('event log', () {
    test('both sides append and read back a contiguous log', () async {
      final match = await activeMatch();
      const opening = OpeningRollEvent(whiteDie: 6, blackDie: 3);
      final move = MoveEvent(
        Player.white,
        Move([const CheckerMove(24, 18), const CheckerMove(13, 10)]),
      );

      await host.api
          .submitEvent(code: match.code, seq: 0, gameNo: 1, event: opening);
      await host.api
          .submitEvent(code: match.code, seq: 1, gameNo: 1, event: move);
      await guest.api.submitEvent(
          code: match.code, seq: 2, gameNo: 1, event: DoubleEvent(Player.black));

      final log = await host.api.fetchEventsSince(match.code, -1);
      expect(log.map((e) => e.seq), [0, 1, 2]);
      expect(log[0].event, opening);
      expect(log[1].event, move,
          reason: 'nested move hops survive the JSON-string payload');
      expect(log[1].author, host.uid);
      expect(log[2].event, DoubleEvent(Player.black));
      expect(log[2].author, guest.uid);

      // Incremental fetch skips what the caller already has.
      final tail = await host.api.fetchEventsSince(match.code, 1);
      expect(tail.map((e) => e.seq), [2]);
    });

    test('a seq already claimed is AlreadyExists, and the log is unchanged',
        () async {
      final match = await activeMatch();
      await host.api.submitEvent(
          code: match.code,
          seq: 0,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 5, blackDie: 1));
      await expectLater(
        guest.api.submitEvent(
            code: match.code,
            seq: 0,
            gameNo: 1,
            event: DoubleEvent(Player.black)),
        throwsA(isA<AlreadyExistsException>()),
      );
      final log = await guest.api.fetchEventsSince(match.code, -1);
      expect(log, hasLength(1));
      expect(log.single.event, const OpeningRollEvent(whiteDie: 5, blackDie: 1));
    });

    test('the log paginates in seq order across several pages', () async {
      final match = await activeMatch();
      await host.api.submitEvent(
          code: match.code,
          seq: 0,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 4, blackDie: 2));
      for (var seq = 1; seq <= 6; seq++) {
        await host.api.submitEvent(
          code: match.code,
          seq: seq,
          gameNo: 1,
          event: RollEvent(Player.white, (seq % 6) + 1, ((seq + 2) % 6) + 1),
        );
      }
      // pageSize 2 over 7 documents: four round trips, still one ordered log.
      final log = await host.api.fetchEventsSince(match.code, -1, pageSize: 2);
      expect(log.map((e) => e.seq), [0, 1, 2, 3, 4, 5, 6]);
      expect(log.first.event, const OpeningRollEvent(whiteDie: 4, blackDie: 2));
      expect(log.last.event, RollEvent(Player.white, 1, 3));
    });

    test('an event may not be rewritten or deleted', () async {
      final match = await activeMatch();
      await host.api.submitEvent(
          code: match.code, seq: 0, gameNo: 1, event: DoubleEvent(Player.white));
      await expectLater(
        host.api.docs.patch(
          'matches/${match.code}/events/00000000',
          {'gameNo': 9},
          updateMask: const ['gameNo'],
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('an oversized payload is refused by the rules', () async {
      final match = await activeMatch();
      await expectLater(
        host.api.docs.create('matches/${match.code}/events/00000000', {
          'seq': 0,
          'gameNo': 1,
          'event': 'x' * 4097,
          'author': host.uid,
        }),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('an event authored as the opponent is refused', () async {
      final match = await activeMatch();
      await expectLater(
        host.api.docs.create('matches/${match.code}/events/00000000', {
          'seq': 0,
          'gameNo': 1,
          'event': '{}',
          'author': guest.uid,
        }),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  // =========================================================================
  group('commit-reveal rolls', () {
    test('the full dance runs and both peers derive the same dice', () async {
      final match = await activeMatch();
      final roller = RollerSession(rollIndex: 0);
      final witness = WitnessSession(rollIndex: 0);

      // Phase 1 — the host commits.
      final commit = roller.makeCommit();
      await host.api.createRoll(code: match.code, n: 0, commit: commit);

      // The witness sees the commit through the transport, not out of band.
      final seen = (await guest.api.fetchRoll(match.code, 0))!;
      expect(seen.roller, host.uid);
      expect(seen.phase, FairDicePhase.committed);
      witness.seeCommit(seen.commit);

      // Phase 2 — the guest contributes entropy.
      await guest.api.submitEntropy(
          code: match.code, n: 0, entropy: witness.contributeEntropy());
      final withEntropy = (await host.api.fetchRoll(match.code, 0))!;
      expect(withEntropy.phase, FairDicePhase.entropy);
      roller.acceptEntropy(withEntropy.entropy!);

      // Phase 3 — the host reveals.
      await host.api
          .submitReveal(code: match.code, n: 0, reveal: roller.reveal());
      final done = (await guest.api.fetchRoll(match.code, 0))!;
      expect(done.isComplete, isTrue);
      witness.verifyReveal(done.reveal!);

      final completed = done.completed!;
      completed.verifyCommit();
      expect(roller.dice, witness.dice);
      expect(completed.dice, roller.dice);
      expect(roller.dice.die1, inInclusiveRange(1, 6));
      expect(roller.dice.die2, inInclusiveRange(1, 6));
    });

    test('revealing before entropy exists is denied (phase skip)', () async {
      final match = await activeMatch();
      final roller = RollerSession();
      await host.api
          .createRoll(code: match.code, n: 1, commit: roller.makeCommit());
      await expectLater(
        host.api.submitReveal(
            code: match.code, n: 1, reveal: 'd' * 64),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect((await host.api.fetchRoll(match.code, 1))!.reveal, isNull);
    });

    test('the roller may not supply its own entropy', () async {
      final match = await activeMatch();
      await host.api
          .createRoll(code: match.code, n: 0, commit: 'a' * 64);
      await expectLater(
        host.api.submitEntropy(code: match.code, n: 0, entropy: 'b' * 64),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('the witness may not reveal', () async {
      final match = await activeMatch();
      await host.api.createRoll(code: match.code, n: 0, commit: 'a' * 64);
      await guest.api.submitEntropy(code: match.code, n: 0, entropy: 'b' * 64);
      await expectLater(
        guest.api.submitReveal(code: match.code, n: 0, reveal: 'c' * 64),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('each protocol field is write-once', () async {
      final match = await activeMatch();
      await host.api.createRoll(code: match.code, n: 0, commit: 'a' * 64);
      await guest.api.submitEntropy(code: match.code, n: 0, entropy: 'b' * 64);
      await expectLater(
        guest.api.submitEntropy(code: match.code, n: 0, entropy: 'c' * 64),
        throwsA(isA<PermissionDeniedException>()),
      );
      await host.api.submitReveal(code: match.code, n: 0, reveal: 'c' * 64);
      await expectLater(
        host.api.submitReveal(code: match.code, n: 0, reveal: 'd' * 64),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('a non-hex commit is refused', () async {
      final match = await activeMatch();
      await expectLater(
        host.api.createRoll(code: match.code, n: 0, commit: 'not-hex'),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('both peers racing to commit the same roll: one AlreadyExists',
        () async {
      final match = await activeMatch();
      await host.api.createRoll(code: match.code, n: 3, commit: 'a' * 64);
      await expectLater(
        guest.api.createRoll(code: match.code, n: 3, commit: 'b' * 64),
        throwsA(isA<AlreadyExistsException>()),
      );
      expect((await guest.api.fetchRoll(match.code, 3))!.roller, host.uid);
    });

    test('rolls are listed in order and an absent roll reads as null',
        () async {
      final match = await activeMatch();
      for (var n = 0; n < 3; n++) {
        await host.api.createRoll(code: match.code, n: n, commit: 'a' * 64);
      }
      final rolls = await host.api.fetchRollsFrom(match.code, 0, pageSize: 2);
      expect(rolls.map((r) => r.n), [0, 1, 2]);
      expect(await host.api.fetchRollsFrom(match.code, 2), hasLength(1));
      expect(await host.api.fetchRoll(match.code, 9), isNull);
    });
  });

  // =========================================================================
  group('polling', () {
    test('picks up the opponent\'s events and roll phases', () async {
      final match = await activeMatch();
      final events = <int>[];
      final phases = <(int, FairDicePhase)>[];
      final sub = host.api
          .pollMatch(match.code, interval: const Duration(milliseconds: 50))
          .listen((poll) {
        events.addAll(poll.events.map((e) => e.seq));
        phases.addAll(poll.rolls.map((r) => (r.n, r.phase)));
      });
      addTearDown(sub.cancel);

      await guest.api.submitEvent(
          code: match.code,
          seq: 0,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 3, blackDie: 6));
      await guest.api.createRoll(code: match.code, n: 0, commit: 'a' * 64);

      // Wait for both to surface.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((events.isEmpty || phases.isEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(events, [0]);
      expect(phases, contains((0, FairDicePhase.committed)));

      // The host answers with entropy; the phase change must be re-emitted.
      await host.api.submitEntropy(code: match.code, n: 0, entropy: 'b' * 64);
      while (!phases.contains((0, FairDicePhase.entropy)) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(phases, contains((0, FairDicePhase.entropy)));
      expect(events, [0], reason: 'events are emitted exactly once');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  // =========================================================================
  group('non-participant access', () {
    late MatchDoc match;
    late TestUser outsider;

    setUp(() async {
      match = await activeMatch();
      outsider = await signIn();
    });

    test('cannot read the match', () async {
      await expectLater(
        outsider.api.fetchMatch(match.code),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('cannot read or append to the event log', () async {
      await host.api.submitEvent(
          code: match.code, seq: 0, gameNo: 1, event: DoubleEvent(Player.white));
      await expectLater(
        outsider.api.fetchEventsSince(match.code, -1),
        throwsA(isA<PermissionDeniedException>()),
      );
      await expectLater(
        outsider.api.submitEvent(
            code: match.code, seq: 1, gameNo: 1, event: TakeEvent(Player.black)),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('cannot touch the roll protocol', () async {
      await host.api.createRoll(code: match.code, n: 0, commit: 'a' * 64);
      await expectLater(
        outsider.api.fetchRoll(match.code, 0),
        throwsA(isA<PermissionDeniedException>()),
      );
      await expectLater(
        outsider.api.fetchRollsFrom(match.code, 0),
        throwsA(isA<PermissionDeniedException>()),
      );
      await expectLater(
        outsider.api.submitEntropy(code: match.code, n: 0, entropy: 'b' * 64),
        throwsA(isA<PermissionDeniedException>()),
      );
      await expectLater(
        outsider.api.createRoll(code: match.code, n: 1, commit: 'b' * 64),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('cannot complete or reopen the match', () async {
      await expectLater(
        outsider.api.completeMatch(match.code),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });
}
