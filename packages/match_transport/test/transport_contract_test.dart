/// The NORMATIVE contract every `MatchTransport` must satisfy, exercised against
/// the reference implementation ([InMemoryTransport]).
///
/// These cases are written from the prose contract in `src/match_transport.dart`
/// (one group per clause). The clauses that are true of EVERY backend have been
/// lifted into `lib/transport_contract.dart` and are run here against
/// [InMemoryTransport], in `packages/lan_play/test/socket_contract_test.dart`
/// against [SocketTransport] over a real loopback socket, and in
/// `packages/online_client/test/emulator_integration_test.dart` against
/// `FirestoreTransport` on the emulator — same assertions, three backends.
///
/// What stays HERE is what only the reference implementation can pin down: the
/// manual-pump delivery model, the reset/replay clause, scripted dice, presence,
/// pacing, and the fine-grained ordering cases that need a controllable clock.
library;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:match_transport/match_transport.dart';
import 'package:match_transport/testing.dart';
import 'package:match_transport/transport_contract.dart';
import 'package:test/test.dart';

/// A host+guest endpoint pair on one backend, plus a frame recorder per endpoint.
class _Rig {
  _Rig({
    MatchConfig config = const MatchConfig(length: 1),
    bool deliverImmediately = true,
  }) : backend = InMemoryBackend(
          config: config,
          deliverImmediately: deliverImmediately,
        ) {
    host = InMemoryTransport.host(backend);
    guest = InMemoryTransport.guest(backend);
    hostFrames = _record(host);
    guestFrames = _record(guest);
  }

  final InMemoryBackend backend;
  late final InMemoryTransport host;
  late final InMemoryTransport guest;
  late final List<InboundFrame> hostFrames;
  late final List<InboundFrame> guestFrames;

  /// Collected inbound errors, so the contract's "errors do not end the stream"
  /// clause can be asserted (and an unhandled error cannot fail an unrelated
  /// case).
  final List<Object> inboundErrors = [];

  List<InboundFrame> _record(MatchTransport t) {
    final out = <InboundFrame>[];
    t.inbound.listen(out.add, onError: inboundErrors.add);
    return out;
  }

  Future<void> connectBoth() async {
    await host.connect();
    await guest.connect();
  }

  /// Let every pending microtask (and therefore every scheduled flush) run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> dispose() async {
    await host.dispose();
    await guest.dispose();
  }
}

List<EventFrame> _events(List<InboundFrame> frames) =>
    frames.whereType<EventFrame>().toList();

List<RollFrame> _rolls(List<InboundFrame> frames) =>
    frames.whereType<RollFrame>().toList();

void main() {
  // The SHARED suite, against the reference implementation. The identical call
  // appears in lan_play's and online_client's suites — that is what makes
  // "interchangeable with any other" a checked claim rather than a comment.
  runTransportContract(
    name: 'InMemoryTransport',
    newUnconnected: () async => InMemoryTransport.host(InMemoryBackend()),
    newPair: (config) async {
      final backend = InMemoryBackend(config: config);
      final host = InMemoryTransport.host(backend);
      final guest = InMemoryTransport.guest(backend);
      final hostSession = await host.connect();
      final guestSession = await guest.connect();
      return TransportPair(
        host: host,
        guest: guest,
        hostSession: hostSession,
        guestSession: guestSession,
        dispose: () async {
          await host.dispose();
          await guest.dispose();
        },
      );
    },
    // In-process: nothing here waits on a socket.
    timeout: const Duration(seconds: 5),
  );

  // -------------------------------------------------------------------------
  group('connect()', () {
    test('seats the host white and the joiner black, and reports connected',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);

      expect(rig.host.status, TransportStatus.connecting);

      final hostSession = await rig.host.connect();
      final guestSession = await rig.guest.connect();

      expect(hostSession.assignedSide, Player.white);
      expect(hostSession.assignedSide, TransportSession.hostSide);
      expect(guestSession.assignedSide, Player.black);
      expect(hostSession.isHost, isTrue);
      expect(guestSession.isHost, isFalse);

      expect(rig.host.status, TransportStatus.connected);
      expect(rig.host.statusReason, isNull);
    });

    test('carries the agreed config and the seat identities both ways',
        () async {
      final rig = _Rig(config: const MatchConfig(length: 5, cubeless: true));
      addTearDown(rig.dispose);

      final session = await rig.guest.connect();

      expect(session.config, const MatchConfig(length: 5, cubeless: true));
      expect(session.matchCode, 'INMEM',
          reason: 'the human-facing handle, distinct from the resume token');
      expect(session.localAuthor, 'guest');
      expect(session.hostAuthor, 'host');
      expect(session.guestAuthor, 'guest');
      // sideOf is what lets the controller check an inbound author against the
      // seat the event claims.
      expect(session.sideOf('host'), Player.white);
      expect(session.sideOf('guest'), Player.black);
      expect(session.sideOf('someone-else'), isNull);
    });

    test('a durable transport hands back a resume token; a volatile one does '
        'not', () async {
      final durable = InMemoryBackend(resumeToken: 'MATCH-ABC');
      final volatile = InMemoryBackend(
        capabilities: const Capabilities(durable: false, rejoinable: false),
      );
      final a = InMemoryTransport.host(durable);
      final b = InMemoryTransport.host(volatile);
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      expect((await a.connect()).resumeToken, 'MATCH-ABC');
      expect(a.capabilities.rejoinable, isTrue);
      expect((await b.connect()).resumeToken, isNull);
      expect(b.capabilities.rejoinable, isFalse);
    });

    test('I/O before connect() is TransportUnavailable, not a silent no-op',
        () async {
      final t = InMemoryTransport.host(InMemoryBackend());
      addTearDown(t.dispose);

      await expectLater(
        t.sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 3, 1)),
        throwsA(isA<TransportUnavailable>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('event ordering and at-least-once delivery', () {
    test('seq is contiguous from 1 and frames arrive in ascending seq order',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host.sendEvent(
          seq: 1, gameNo: 1, event: OpeningRollEvent(whiteDie: 6, blackDie: 3));
      await rig.host.sendEvent(
          seq: 2, gameNo: 1, event: MoveEvent(Player.white, Move.none));
      await rig.guest
          .sendEvent(seq: 3, gameNo: 1, event: RollEvent(Player.black, 2, 1));
      await rig.settle();

      expect(_events(rig.guestFrames).map((e) => e.seq), [1, 2, 3]);
      expect(_events(rig.hostFrames).map((e) => e.seq), [1, 2, 3]);
      expect(rig.backend.events.first.seq, 1, reason: 'contiguous from 1');
    });

    test("a device's OWN events are delivered back to it (the fold advances "
        'on them)', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host
          .sendEvent(seq: 1, gameNo: 1, event: DoubleEvent(Player.white));
      await rig.settle();

      final own = _events(rig.hostFrames);
      expect(own, hasLength(1));
      expect(own.single.author, 'host');
      expect(own.single.event, isA<DoubleEvent>());
    });

    test('every frame carries its author and gameNo, so the folder can check '
        'author against seat', () async {
      final rig = _Rig(config: const MatchConfig(length: 3));
      addTearDown(rig.dispose);
      final session = await rig.host.connect();
      await rig.guest.connect();

      await rig.guest
          .sendEvent(seq: 1, gameNo: 2, event: RollEvent(Player.black, 5, 5));
      await rig.settle();

      final frame = _events(rig.hostFrames).single;
      expect(frame.author, 'guest');
      expect(frame.gameNo, 2);
      expect(session.sideOf(frame.author), Player.black,
          reason: 'the author holds the seat its RollEvent claims');
    });

    test('a duplicate delivery is contract-legal: the folder ignores '
        'seq <= lastFolded', () async {
      // At-least-once is the promise, so the FOLDING RULE (not the transport)
      // is what makes a redelivery harmless. Assert the rule over a stream
      // that repeats every frame.
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host
          .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 3, 2));
      await rig.settle();

      final delivered = _events(rig.guestFrames);
      var lastFolded = 0;
      final folded = <int>[];
      for (final f in [...delivered, ...delivered, ...delivered]) {
        if (f.seq <= lastFolded) continue;
        lastFolded = f.seq;
        folded.add(f.seq);
      }
      expect(folded, [1], reason: 'three deliveries, one fold');
    });

    test('inbound is a broadcast stream: cancel and re-listen without tearing '
        'the transport down', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      final first = <InboundFrame>[];
      final sub = rig.guest.inbound.listen(first.add);
      await rig.host
          .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 1, 2));
      await rig.settle();
      await sub.cancel();

      final second = <InboundFrame>[];
      rig.guest.inbound.listen(second.add);
      await rig.host.sendEvent(
          seq: 2, gameNo: 1, event: MoveEvent(Player.white, Move.none));
      await rig.settle();

      expect(_events(first).map((e) => e.seq), [1]);
      expect(_events(second).map((e) => e.seq), [2]);
    });

    test('sendEvent at a taken seq throws TransportContested', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host
          .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 3, 2));
      await expectLater(
        rig.guest
            .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.black, 6, 6)),
        throwsA(isA<TransportContested>()),
      );

      // The loser resyncs and retries at the next free index.
      final missed = await rig.guest.eventsSince(0);
      await rig.guest.sendEvent(
          seq: missed.last.seq + 1,
          gameNo: 1,
          event: MoveEvent(Player.white, Move.none));
      expect(rig.backend.events.map((e) => e.seq), [1, 2]);
    });
  });

  // -------------------------------------------------------------------------
  group('a gap is closed by eventsSince, exactly', () {
    test('eventsSince(afterSeq) returns exactly seq > afterSeq, ascending and '
        'contiguous', () async {
      final rig = _Rig(deliverImmediately: false);
      addTearDown(rig.dispose);
      await rig.connectBoth();

      for (var seq = 1; seq <= 5; seq++) {
        await rig.host.sendEvent(
            seq: seq, gameNo: 1, event: RollEvent(Player.white, 3, 2));
      }

      expect(
          (await rig.guest.eventsSince(0)).map((e) => e.seq), [1, 2, 3, 4, 5]);
      expect((await rig.guest.eventsSince(2)).map((e) => e.seq), [3, 4, 5]);
      expect(await rig.guest.eventsSince(5), isEmpty);
      expect(await rig.guest.eventsSince(99), isEmpty);
    });

    test('a seq gap on inbound is filled exactly by eventsSince(lastFolded)',
        () async {
      // Manual-pump mode lets us MISS frames: the guest folds seq 1, then only
      // seq 5 of 2..5 reaches its folder, which must notice the hole.
      final rig = _Rig(deliverImmediately: false);
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host.sendEvent(
          seq: 1,
          gameNo: 1,
          event: OpeningRollEvent(whiteDie: 4, blackDie: 1));
      rig.backend.pump();
      await rig.settle();

      var lastFolded = 0;
      for (final f in _events(rig.guestFrames)) {
        expect(f.seq, lastFolded + 1);
        lastFolded = f.seq;
      }
      expect(lastFolded, 1);

      for (var seq = 2; seq <= 5; seq++) {
        await rig.host.sendEvent(
            seq: seq, gameNo: 1, event: MoveEvent(Player.white, Move.none));
      }
      final sawLate = <EventFrame>[];
      final sub = rig.guest.inbound.listen((f) {
        if (f is EventFrame && f.seq == 5) sawLate.add(f);
      });
      rig.backend.pump();
      await rig.settle();
      await sub.cancel();

      final late5 = sawLate.single;
      expect(late5.seq, greaterThan(lastFolded + 1), reason: 'a real gap');

      final fill = await rig.guest.eventsSince(lastFolded);
      expect(fill.map((e) => e.seq), [2, 3, 4, 5],
          reason: 'exactly the missing tail, ascending and contiguous, '
              'including the frame that revealed the gap');
      for (final f in fill) {
        expect(f.seq, lastFolded + 1);
        lastFolded = f.seq;
      }
      expect(lastFolded, 5);
    });
  });

  // -------------------------------------------------------------------------
  group('roll frames: commit then entropy then reveal', () {
    test('a roll is re-emitted at each phase, in phase order, to both peers',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      final roller = RollerSession(rollIndex: 1);
      final witness = WitnessSession(rollIndex: 1);

      await rig.host.createRoll(1, roller.makeCommit());
      await rig.settle();
      witness.seeCommit(_rolls(rig.guestFrames).last.commit);

      await rig.guest.sendEntropy(1, witness.contributeEntropy());
      await rig.settle();
      roller.acceptEntropy(_rolls(rig.hostFrames).last.entropy!);

      await rig.host.sendReveal(1, roller.reveal());
      await rig.settle();

      for (final frames in [rig.hostFrames, rig.guestFrames]) {
        expect(_rolls(frames).map((r) => r.phase), [
          FairDicePhase.committed,
          FairDicePhase.entropy,
          FairDicePhase.revealed,
        ]);
        expect(
            _rolls(frames).every((r) => r.n == 1 && r.roller == 'host'), isTrue);
      }

      final complete = _rolls(rig.guestFrames).last;
      expect(complete.isComplete, isTrue);
      final rolled = complete.completed!;
      rolled.verifyCommit();
      witness.verifyReveal(complete.reveal!);
      expect(rolled.dice, roller.dice);
      expect(rolled.dice, witness.dice);
    });

    test('an incomplete roll exposes no CompletedRoll', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host.createRoll(1, commitFor(generateSecretHex()));
      await rig.settle();

      final frame = _rolls(rig.guestFrames).single;
      expect(frame.isComplete, isFalse);
      expect(frame.completed, isNull);
      expect(frame.phase, FairDicePhase.committed);
    });

    test('fetchRoll returns the exact current document, or null when absent',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      expect(await rig.guest.fetchRoll(1), isNull);

      final roller = RollerSession(rollIndex: 1);
      final commit = roller.makeCommit();
      await rig.host.createRoll(1, commit);

      var pulled = (await rig.guest.fetchRoll(1))!;
      expect(pulled.commit, commit);
      expect(pulled.phase, FairDicePhase.committed);

      final witness = WitnessSession(rollIndex: 1)..seeCommit(commit);
      final entropy = witness.contributeEntropy();
      await rig.guest.sendEntropy(1, entropy);
      pulled = (await rig.guest.fetchRoll(1))!;
      expect(pulled.entropy, entropy);
      expect(pulled.phase, FairDicePhase.entropy);

      roller.acceptEntropy(entropy);
      final reveal = roller.reveal();
      await rig.host.sendReveal(1, reveal);
      pulled = (await rig.guest.fetchRoll(1))!;
      expect(pulled.reveal, reveal);
      expect(pulled.phase, FairDicePhase.revealed);
      expect(pulled.completed!.dice, roller.dice);

      expect(await rig.guest.fetchRoll(2), isNull);
    });

    test('a roll event can arrive before its roll document: fetchRoll closes '
        'the race', () async {
      // Ordering is promised WITHIN a kind only, so the folder must tolerate a
      // RollEvent whose roll frame has not been delivered yet.
      final rig = _Rig(deliverImmediately: false);
      addTearDown(rig.dispose);
      await rig.connectBoth();

      rig.backend
          .seedRoll(author: 'host', player: Player.white, die1: 5, die2: 3);
      final eventOnly = <InboundFrame>[];
      final sub = rig.guest.inbound.listen(eventOnly.add);
      rig.backend.pump();
      await rig.settle();
      await sub.cancel();

      final rollEvent = _events(eventOnly).single.event as RollEvent;
      final doc = await rig.guest.fetchRoll(1);
      expect(doc, isNotNull, reason: 'always pullable, whatever the ordering');
      expect(diceMatchRoll(doc!.completed!, rollEvent), isTrue);
      expect(rollEvent.die1, 5);
      expect(rollEvent.die2, 3);
    });

    test('createRoll at a taken n throws TransportContested', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host.createRoll(1, commitFor(generateSecretHex()));
      await expectLater(
        rig.guest.createRoll(1, commitFor(generateSecretHex())),
        throwsA(isA<TransportContested>()),
      );
    });

    test('roll index n is 1 + roll-bearing events folded so far', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      expect(rig.backend.rollCount + 1, 1);
      rig.backend.seedOpening(whiteDie: 6, blackDie: 2);
      expect(rig.backend.rollCount + 1, 2);

      // A non-roll event does NOT advance the roll index.
      await rig.host.sendEvent(
          seq: rig.backend.nextSeq,
          gameNo: 1,
          event: MoveEvent(Player.white, Move.none));
      expect(rig.backend.rollCount + 1, 2);

      rig.backend
          .seedRoll(author: 'guest', player: Player.black, die1: 4, die2: 4);
      expect(rig.backend.rollCount + 1, 3);
      expect((await rig.host.fetchRoll(2))!.roller, 'guest');
    });
  });

  // -------------------------------------------------------------------------
  group('a refused roll-phase write is TransportRejected (never retry)', () {
    late _Rig rig;
    setUp(() async {
      rig = _Rig();
      await rig.connectBoth();
    });
    tearDown(() => rig.dispose());

    test('entropy on a roll that does not exist', () async {
      await expectLater(rig.guest.sendEntropy(7, generateSecretHex()),
          throwsA(isA<TransportRejected>()));
    });

    test("entropy on one's OWN roll", () async {
      await rig.host.createRoll(1, commitFor(generateSecretHex()));
      await expectLater(rig.host.sendEntropy(1, generateSecretHex()),
          throwsA(isA<TransportRejected>()));
    });

    test('entropy twice', () async {
      await rig.host.createRoll(1, commitFor(generateSecretHex()));
      await rig.guest.sendEntropy(1, generateSecretHex());
      await expectLater(rig.guest.sendEntropy(1, generateSecretHex()),
          throwsA(isA<TransportRejected>()));
    });

    test('reveal by anyone but the roller', () async {
      await rig.host.createRoll(1, commitFor(generateSecretHex()));
      await rig.guest.sendEntropy(1, generateSecretHex());
      await expectLater(rig.guest.sendReveal(1, generateSecretHex()),
          throwsA(isA<TransportRejected>()));
    });

    test('reveal before entropy', () async {
      await rig.host.createRoll(1, commitFor(generateSecretHex()));
      await expectLater(rig.host.sendReveal(1, generateSecretHex()),
          throwsA(isA<TransportRejected>()));
    });

    test('reveal twice', () async {
      final roller = RollerSession();
      await rig.host.createRoll(1, roller.makeCommit());
      final entropy = generateSecretHex();
      await rig.guest.sendEntropy(1, entropy);
      roller.acceptEntropy(entropy);
      final reveal = roller.reveal();
      await rig.host.sendReveal(1, reveal);
      await expectLater(rig.host.sendReveal(1, reveal),
          throwsA(isA<TransportRejected>()));
    });
  });

  // -------------------------------------------------------------------------
  group('typed errors', () {
    test('all three are TransportExceptions carrying a code and a message', () {
      const rejected = TransportRejected('permission-denied', 'rules refused');
      const contested = TransportContested('already-exists', 'seq taken');
      const unavailable = TransportUnavailable('timeout', 'poll blip');

      for (final e in <TransportException>[rejected, contested, unavailable]) {
        expect(e, isA<Exception>());
        expect(e.code, isNotEmpty);
        expect(e.message, isNotEmpty);
        expect(e.toString(), contains(e.code));
        expect(e.toString(), contains(e.message));
      }
      // The three meanings are distinct TYPES, so a caller switches on the
      // meaning (never-retry / resync-and-retry / self-heals) rather than on a
      // string code.
      expect(rejected, isNot(isA<TransportContested>()));
      expect(contested, isNot(isA<TransportUnavailable>()));
      expect(unavailable, isNot(isA<TransportRejected>()));
    });

    test('a disposed transport reports TransportUnavailable, not a crash',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();
      await rig.guest.dispose();

      await expectLater(
          rig.guest.eventsSince(0), throwsA(isA<TransportUnavailable>()));
    });

    test('a refusal that knows the authority\'s seq carries peerLastSeq, so the '
        'caller can tell "behind" from "wrong"', () {
      const behind = TransportContested('seq-taken', 'events/4 exists',
          peerLastSeq: 9);
      const wrong = TransportRejected('bad-seat', 'not your seat');

      expect(behind.peerLastSeq, 9);
      expect(behind.toString(), contains('9'));
      expect(wrong.peerLastSeq, isNull,
          reason: 'unknown, not zero: the caller must not infer a rewind');
    });
  });

  // -------------------------------------------------------------------------
  group('status', () {
    test('connecting -> connected -> reconnecting -> busy -> connected -> '
        'failed, each event carrying its reason', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);

      final seen = <TransportStatusEvent>[];
      rig.host.statusStream.listen(seen.add);

      expect(rig.host.status, TransportStatus.connecting);
      await rig.host.connect();
      expect(rig.host.status, TransportStatus.connected);

      rig.host.simulateDrop('socket closed');
      expect(rig.host.status, TransportStatus.reconnecting);
      expect(rig.host.statusReason, 'socket closed');

      rig.host.simulateBusy('room is busy');
      expect(rig.host.status, TransportStatus.busy);
      expect(rig.host.status.isTransient, isTrue,
          reason: 'busy is a banner, not a gate: it self-clears');

      rig.host.simulateReconnect();
      expect(rig.host.status, TransportStatus.connected);
      expect(rig.host.statusReason, isNull,
          reason: 'reasons belong to the unhealthy states only');
      expect(rig.host.status.isTransient, isFalse);

      rig.host.simulateFailure('room code unknown');
      expect(rig.host.status, TransportStatus.failed);
      expect(rig.host.statusReason, 'room code unknown');
      expect(rig.host.status.isTransient, isFalse,
          reason: 'failed is terminal: retrying cannot help');

      await rig.settle();
      expect(seen, const [
        TransportStatusEvent(TransportStatus.connected),
        TransportStatusEvent(TransportStatus.reconnecting, 'socket closed'),
        TransportStatusEvent(TransportStatus.busy, 'room is busy'),
        TransportStatusEvent(TransportStatus.connected),
        TransportStatusEvent(TransportStatus.failed, 'room code unknown'),
      ]);
    });

    test('status/statusReason are updated BEFORE the event is emitted',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.host.connect();

      final observed = <(TransportStatusEvent, TransportStatus, String?)>[];
      rig.host.statusStream.listen(
          (s) => observed.add((s, rig.host.status, rig.host.statusReason)));

      rig.host.simulateDrop('link dropped');
      await rig.settle();

      expect(observed.single.$1,
          const TransportStatusEvent(TransportStatus.reconnecting, 'link dropped'));
      expect(observed.single.$2, TransportStatus.reconnecting,
          reason: 'the getter already agrees with the event');
      expect(observed.single.$3, 'link dropped');
    });

    test('the two endpoints have independent status', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      rig.guest.simulateDrop();
      expect(rig.guest.status, TransportStatus.reconnecting);
      expect(rig.host.status, TransportStatus.connected);
    });
  });

  // -------------------------------------------------------------------------
  group('two endpoints each see the other side of the match', () {
    test('a scripted opening plus two turns converges on both peers', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      rig.backend.seedOpening(whiteDie: 5, blackDie: 2);
      await rig.host.sendEvent(
          seq: rig.backend.nextSeq,
          gameNo: 1,
          event: MoveEvent(Player.white, Move.none));
      rig.backend
          .seedRoll(author: 'guest', player: Player.black, die1: 3, die2: 1);
      await rig.guest.sendEvent(
          seq: rig.backend.nextSeq,
          gameNo: 1,
          event: MoveEvent(Player.black, Move.none));
      await rig.settle();

      // Both sides folded the same log, in the same order.
      final hostSeqs = _events(rig.hostFrames).map((e) => e.seq).toList();
      final guestSeqs = _events(rig.guestFrames).map((e) => e.seq).toList();
      expect(hostSeqs, [1, 2, 3, 4]);
      expect(guestSeqs, hostSeqs);
      expect(
        _events(rig.guestFrames).map((e) => e.event.runtimeType).toList(),
        [OpeningRollEvent, MoveEvent, RollEvent, MoveEvent],
      );
      // ... and both saw both rolls, with the right roller on each.
      expect(_rolls(rig.hostFrames).map((r) => r.n).toSet(), {1, 2});
      expect(_rolls(rig.guestFrames).map((r) => r.n).toSet(), {1, 2});
      expect(_rolls(rig.guestFrames).last.roller, 'guest');
    });

    test('complete() is best-effort bookkeeping and never throws', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();
      await expectLater(rig.host.complete(), completes);
    });

    test('dispose() is idempotent and stops delivery', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.guest.dispose();
      await rig.guest.dispose(); // no throw

      final before = rig.guestFrames.length;
      await rig.host
          .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 2, 1));
      await rig.settle();
      expect(rig.guestFrames, hasLength(before));
      expect(_events(rig.hostFrames), hasLength(1),
          reason: 'the surviving endpoint is unaffected');
    });
  });

  // -------------------------------------------------------------------------
  group('scripted dice aim a KNOWN roll without forging anything', () {
    test('openingSecretsFor derives exactly the requested opening', () {
      final s = openingSecretsFor(6, 3);
      expect(commitFor(s.secret), s.commit);
      final derived = openingDiceFrom(s.secret, s.entropy);
      expect((derived.die1, derived.die2), (6, 3));
      CompletedRoll(commit: s.commit, entropy: s.entropy, reveal: s.secret)
          .verifyCommit();
    });

    test('turnSecretsFor derives exactly the requested dice', () {
      final s = turnSecretsFor(2, 5);
      final derived = diceFrom(s.secret, s.entropy);
      expect((derived.die1, derived.die2), (2, 5));
      expect(
        diceMatchRoll(
          CompletedRoll(commit: s.commit, entropy: s.entropy, reveal: s.secret),
          RollEvent(Player.white, 2, 5),
        ),
        isTrue,
      );
    });

    test('an opening tie is refused (the derivation never produces one)', () {
      expect(() => openingSecretsFor(4, 4), throwsArgumentError);
    });

    test('seedOpening/seedRoll produce documents that pass every check a '
        'folder makes', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      rig.backend.seedOpening(whiteDie: 1, blackDie: 6);
      rig.backend
          .seedRoll(author: 'guest', player: Player.black, die1: 6, die2: 6);
      await rig.settle();

      final opening = (await rig.host.fetchRoll(1))!;
      expect(opening.roller, 'host', reason: 'the host is the opening roller');
      final openingEvent =
          _events(rig.hostFrames).first.event as OpeningRollEvent;
      expect(openingDiceMatchRoll(opening.completed!, openingEvent), isTrue);
      expect((openingEvent.whiteDie, openingEvent.blackDie), (1, 6));

      final turn = (await rig.host.fetchRoll(2))!;
      final turnEvent = _events(rig.hostFrames).last.event as RollEvent;
      expect(diceMatchRoll(turn.completed!, turnEvent), isTrue);
      expect((turnEvent.die1, turnEvent.die2), (6, 6));
    });

    test('a TAMPERED reveal is caught by the folder, not by the transport', () {
      // The transport is a dumb pipe: it will happily carry a reveal that does
      // not open the commitment. Catching that is the controller's job.
      final s = turnSecretsFor(3, 3);
      final tampered = CompletedRoll(
          commit: s.commit, entropy: s.entropy, reveal: generateSecretHex());
      expect(tampered.verifyCommit, throwsA(isA<FairDiceCheatException>()));
    });
  });

  // -------------------------------------------------------------------------
  group('ResetFrame: discard the fold and replay', () {
    test('arrives unprompted and the re-prime returns the whole log', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      rig.backend.seedOpening(whiteDie: 3, blackDie: 1);
      await rig.host.sendEvent(
          seq: rig.backend.nextSeq,
          gameNo: 1,
          event: MoveEvent(Player.white, Move.none));
      await rig.settle();
      expect(_events(rig.guestFrames), hasLength(2));

      rig.guest.simulateReset();
      await rig.settle();

      final reset = rig.guestFrames.whereType<ResetFrame>().single;
      expect(reset.resumeToken, 'INMEM-TOKEN');
      expect(reset.reason, 'reconnected');

      // The controller re-primes from scratch: both pulls answer in full.
      expect((await rig.guest.eventsSince(0)).map((e) => e.seq), [1, 2]);
      expect((await rig.guest.rollsSince(1)).map((r) => r.n), [1]);
    });

    test('a CHANGED resume token is what flags a match-identity reset',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      final session = await rig.host.connect();
      await rig.guest.connect();

      rig.guest.simulateReset(reason: 'reconnected');
      await rig.settle();
      expect(rig.guestFrames.whereType<ResetFrame>().single.resumeToken,
          session.resumeToken,
          reason: 'same match: the watermarks survive');

      rig.backend.resumeToken = 'A-DIFFERENT-MATCH';
      rig.guest.simulateReset(reason: 'host restarted');
      await rig.settle();

      final latest = rig.guestFrames.whereType<ResetFrame>().last;
      expect(latest.resumeToken, isNot(session.resumeToken),
          reason: 'a foreign token means every per-match watermark is void');
      expect(latest.reason, 'host restarted');
    });

    test('a volatile transport resets with a null token', () async {
      final backend = InMemoryBackend(
        capabilities: const Capabilities(durable: false, rejoinable: false),
      );
      final t = InMemoryTransport.host(backend);
      addTearDown(t.dispose);
      final frames = <InboundFrame>[];
      t.inbound.listen(frames.add);

      await t.connect();
      t.simulateReset();
      await Future<void>.delayed(Duration.zero);

      expect(frames.whereType<ResetFrame>().single.resumeToken, isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('inbound errors do not end the stream', () {
    test('a transient read failure surfaces and folding continues', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      final errors = <Object>[];
      final frames = <InboundFrame>[];
      rig.guest.inbound.listen(frames.add, onError: errors.add);

      rig.guest.simulateInboundError();
      await rig.settle();
      await rig.host
          .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 6, 1));
      await rig.settle();

      expect(errors.single, isA<TransportUnavailable>());
      expect(rig.inboundErrors.single, same(errors.single),
          reason: 'broadcast: every listener sees the error');
      expect(_events(frames).map((e) => e.seq), [1],
          reason: 'the stream survived the error and kept delivering');
      expect(rig.guest.status, TransportStatus.connected,
          reason: 'a transient read failure is not a link state change');
    });
  });

  // -------------------------------------------------------------------------
  group('opponent presence is orthogonal to link status', () {
    test('false until the other seat attaches, true once it has', () async {
      final backend = InMemoryBackend();
      final host = InMemoryTransport.host(backend);
      addTearDown(host.dispose);

      final seen = <bool>[];
      host.opponentPresence.listen(seen.add);

      await host.connect();
      expect(host.status, TransportStatus.connected);
      expect(host.opponentPresent, isFalse,
          reason: 'bound and healthy, but nobody has joined: the host must '
              'not open with a roll yet');

      final guest = InMemoryTransport.guest(backend);
      addTearDown(guest.dispose);
      await guest.connect();
      await Future<void>.delayed(Duration.zero);

      expect(host.opponentPresent, isTrue);
      expect(guest.opponentPresent, isTrue);
      expect(seen, [true]);
    });

    test('goes false again when the opponent leaves, without touching status',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();
      expect(rig.host.opponentPresent, isTrue);

      final seen = <bool>[];
      rig.host.opponentPresence.listen(seen.add);
      await rig.guest.dispose();
      await rig.settle();

      expect(rig.host.opponentPresent, isFalse);
      expect(seen, [false]);
      expect(rig.host.status, TransportStatus.connected,
          reason: 'this device\'s own link is fine');
    });
  });

  // -------------------------------------------------------------------------
  group('rollsSince: the bulk pull a full replace needs', () {
    test('returns every roll with n >= from, ascending, in one call', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      rig.backend.seedOpening(whiteDie: 6, blackDie: 5);
      rig.backend
          .seedRoll(author: 'guest', player: Player.black, die1: 2, die2: 4);
      rig.backend
          .seedRoll(author: 'host', player: Player.white, die1: 1, die2: 1);

      expect((await rig.guest.rollsSince(1)).map((r) => r.n), [1, 2, 3]);
      expect((await rig.guest.rollsSince(3)).map((r) => r.n), [3]);
      expect(await rig.guest.rollsSince(4), isEmpty);
      expect((await rig.guest.rollsSince(1)).every((r) => r.isComplete), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('status events', () {
    test('a redundant set of the SAME status and reason emits nothing',
        () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      final statuses = <TransportStatusEvent>[];
      rig.host.statusStream.listen(statuses.add);

      await rig.host.connect();
      await rig.settle();
      expect(statuses, hasLength(1), reason: 'connecting -> connected');

      // connect() is documented idempotent, and a link that re-reports the
      // state it is already in must not bill the controller (or the connection
      // chip) an event for standing still.
      await rig.host.connect();
      rig.host.simulateReconnect();
      await rig.settle();
      expect(statuses, hasLength(1), reason: 'nothing changed');

      // A real transition still lands, and so does the way back.
      rig.host.simulateDrop('cable');
      rig.host.simulateDrop('cable');
      await rig.settle();
      expect(statuses, hasLength(2));
      expect(statuses.last.status, TransportStatus.reconnecting);
      expect(statuses.last.reason, 'cable');

      // The same status with a DIFFERENT reason is a change worth reporting.
      rig.host.simulateDrop('router');
      await rig.settle();
      expect(statuses, hasLength(3));
      expect(statuses.last.reason, 'router');
    });
  });

  // -------------------------------------------------------------------------
  group('pacing', () {
    test('setPaceHint moves inboundCadence, which the controller reuses as its '
        'own retry beat', () async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.connectBoth();

      final resting = rig.host.inboundCadence;
      rig.host.setPaceHint(fast: true);
      expect(rig.host.inboundCadence, lessThan(resting));
      rig.host.setPaceHint(fast: false);
      expect(rig.host.inboundCadence, greaterThan(resting));
    });
  });

  // -------------------------------------------------------------------------
  group('manual-pump delivery (fake-clock and ordering tests)', () {
    test('nothing is delivered until pump(), which reports what it delivered',
        () async {
      final rig = _Rig(deliverImmediately: false);
      addTearDown(rig.dispose);
      await rig.connectBoth();

      await rig.host
          .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 4, 2));
      await rig.settle();
      expect(rig.guestFrames, isEmpty);
      expect(rig.hostFrames, isEmpty);

      expect(rig.backend.pump(), 2, reason: 'one frame to each endpoint');
      await rig.settle();
      expect(_events(rig.guestFrames).single.seq, 1);
      expect(rig.backend.pump(), 0, reason: 'nothing new the second time');
    });
  });
}
