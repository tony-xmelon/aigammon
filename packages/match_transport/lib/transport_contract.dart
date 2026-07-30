/// The NORMATIVE `MatchTransport` contract as a REUSABLE test suite.
///
/// `src/match_transport.dart`'s library doc states the fold/resync contract in
/// prose and says a transport that honours it "is interchangeable with any
/// other". This file is what makes that claim checkable: [runTransportContract]
/// is a group of expectations written against nothing but the public interface,
/// so the SAME assertions run against every implementation.
///
/// It is pointed at, today:
///
///   * `InMemoryTransport` — `test/transport_contract_test.dart` in this package;
///   * `SocketTransport` over a real loopback WebSocket —
///     `packages/lan_play/test/socket_contract_test.dart`;
///   * `FirestoreTransport` against the Firebase emulator —
///     `packages/online_client/test/emulator_integration_test.dart` (tagged
///     `emulator`, so it runs in `firebase/run-emulator-tests.ps1` and CI's
///     `online` job rather than in a bare `dart test`).
///
/// ## Why it lives in `lib/` and not `test/`
///
/// A file under `test/` cannot be imported by another package. The suite is a
/// deliverable of this package — the executable half of the contract — so it is
/// a library, which is also why `test` is a real dependency here rather than a
/// dev one.
///
/// ## What it does and does not cover
///
/// It covers the clauses that are TRUE OF EVERY TRANSPORT: seating, the seq
/// space, at-least-once delivery to both peers, `eventsSince` exactness, the
/// three-phase roll handshake and its re-emission, the typed write errors, and
/// the "errors never end `inbound`" rule.
///
/// It deliberately does NOT cover behaviour a transport is allowed to differ on:
/// reset/replay semantics (a socket relay resets on reconnect, Firestore
/// rejoins), presence (a pure relay may have no signal), pacing
/// ([MatchTransport.inboundCadence] is zero for a push transport), or the
/// listener/poll duality that only exists online. Those stay in each
/// implementation's own suite, which is where the mechanism lives.
///
/// Every wait is a poll-until-or-fail against a real clock, because two of the
/// three backends involve real sockets.
library;

import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

import 'match_transport.dart';

/// A connected host+guest pair on one backend, as the contract suite needs it.
///
/// The factory ([TransportPairFactory]) is responsible for whatever the backend
/// requires to reach this state — binding a socket, seating two anonymous users
/// in a Firestore match — and for tearing it down in [dispose].
class TransportPair {
  TransportPair({
    required this.host,
    required this.guest,
    required this.hostSession,
    required this.guestSession,
    required this.dispose,
  });

  final MatchTransport host;
  final MatchTransport guest;

  /// The sessions [MatchTransport.connect] returned, so the suite does not have
  /// to guess author identities (they are backend-specific: `host`/`guest`
  /// strings on a relay, anonymous uids online).
  final TransportSession hostSession;
  final TransportSession guestSession;

  /// Releases everything the factory created, innermost first.
  final Future<void> Function() dispose;
}

/// Builds a fresh, CONNECTED pair for one case. Called once per test.
typedef TransportPairFactory = Future<TransportPair> Function(MatchConfig config);

/// Builds an UNCONNECTED transport, for the "I/O before connect" clause.
///
/// Optional: a backend where an unconnected instance cannot be constructed in
/// isolation passes null and that one case is skipped.
typedef UnconnectedTransportFactory = Future<MatchTransport> Function();

/// Run the shared contract against one implementation.
///
/// [name] appears in every test description, so a failure says which backend
/// broke the contract. [timeout] bounds each wait; loopback and the emulator
/// both need more than a microtask.
void runTransportContract({
  required String name,
  required TransportPairFactory newPair,
  UnconnectedTransportFactory? newUnconnected,
  Duration timeout = const Duration(seconds: 20),
  Object? skip,
}) {
  /// Poll until [done], or fail with [reason].
  Future<void> waitFor(
    bool Function() done, {
    String reason = 'the contract condition never became true',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('$name: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A pair plus a frame/error recorder per endpoint, disposed automatically.
  Future<_Rec> record(MatchConfig config) async {
    final pair = await newPair(config);
    addTearDown(pair.dispose);
    return _Rec(pair);
  }

  const config = MatchConfig(length: 3);

  group('$name: the MatchTransport contract', () {
    // -----------------------------------------------------------------------
    test('connect seats the host white and the joiner black, and both peers '
        'agree on the config and the seats', () async {
      final r = await record(const MatchConfig(length: 5, cubeless: true));

      expect(r.pair.hostSession.assignedSide, Player.white);
      expect(r.pair.hostSession.assignedSide, TransportSession.hostSide);
      expect(r.pair.guestSession.assignedSide, Player.black);
      expect(r.pair.hostSession.isHost, isTrue);
      expect(r.pair.guestSession.isHost, isFalse);

      for (final s in [r.pair.hostSession, r.pair.guestSession]) {
        expect(s.config, const MatchConfig(length: 5, cubeless: true));
        // Author → seat is what lets the controller check that an event's author
        // holds the seat the event claims.
        expect(s.sideOf(s.hostAuthor), Player.white);
        expect(s.sideOf(s.guestAuthor!), Player.black);
        expect(s.sideOf('nobody-by-that-name'), isNull);
      }
      expect(r.pair.hostSession.localAuthor, r.pair.hostSession.hostAuthor);
      expect(r.pair.guestSession.localAuthor, r.pair.guestSession.guestAuthor);

      expect(r.pair.host.status, TransportStatus.connected);
      expect(r.pair.host.statusReason, isNull);
      expect(r.pair.guest.status, TransportStatus.connected);
    });

    // -----------------------------------------------------------------------
    test('an event reaches BOTH peers — its author included — in ascending, '
        'contiguous seq order', () async {
      final r = await record(config);

      // Both directions, interleaved, so nothing can pass by only ever ordering
      // one writer's own appends.
      await r.pair.host.sendEvent(
          seq: 1, gameNo: 1, event: OpeningRollEvent(whiteDie: 6, blackDie: 3));
      await r.pair.guest
          .sendEvent(seq: 2, gameNo: 1, event: RollEvent(Player.black, 4, 2));
      await r.pair.host
          .sendEvent(seq: 3, gameNo: 1, event: DoubleEvent(Player.white));

      for (final side in ['host', 'guest']) {
        final frames = side == 'host' ? r.hostEvents : r.guestEvents;
        await waitFor(() => _bySeq(frames).length >= 3,
            reason: 'the $side never saw all three events');
        final seqs = _bySeq(frames).map((e) => e.seq).toList();
        expect(seqs, [1, 2, 3],
            reason: '$side: seq must be contiguous from 1, deduplicated');
        final byIndex = {for (final e in _bySeq(frames)) e.seq: e};
        // The device's OWN events come back to it too — the fold advances on
        // them, so a transport that suppressed them would stall its own writer.
        expect(byIndex[1]!.author, r.pair.hostSession.hostAuthor);
        expect(byIndex[2]!.author, r.pair.guestSession.guestAuthor);
        expect(byIndex[3]!.author, r.pair.hostSession.hostAuthor);
        expect(byIndex[1]!.event, isA<OpeningRollEvent>());
        expect(byIndex[2]!.event, isA<RollEvent>());
        expect(byIndex[3]!.event, isA<DoubleEvent>());
        expect(byIndex[1]!.gameNo, 1);
      }
    });

    // -----------------------------------------------------------------------
    test('eventsSince(0) is the WHOLE log and eventsSince(k) is exactly '
        'seq > k, ascending and contiguous', () async {
      final r = await record(config);
      for (var seq = 1; seq <= 4; seq++) {
        await r.pair.host.sendEvent(
            seq: seq, gameNo: 1, event: RollEvent(Player.white, 3, 1));
      }

      // The clause is scoped the way the contract scopes it: it fires when a
      // frame has ARRIVED with a seq beyond the fold, and the pull then has to be
      // exact. So wait for delivery first — a transport is entitled to answer
      // from a local mirror the stream fills (SocketTransport's guest does
      // exactly that, to avoid a round trip), and "authoritative" means "no
      // holes, no over-reach", not "ahead of its own delivery".
      await waitFor(() => r.guestEvents.any((e) => e.seq == 4),
          reason: 'the guest never saw the fourth event');

      for (final t in [r.pair.host, r.pair.guest]) {
        expect((await t.eventsSince(0)).map((e) => e.seq), [1, 2, 3, 4],
            reason: 'eventsSince(0) means the whole log — this is what primes a '
                'fold, and a transport with a 0-based native index must map onto '
                'it');
        expect((await t.eventsSince(2)).map((e) => e.seq), [3, 4],
            reason: 'strictly greater than afterSeq, with no gap');
        expect(await t.eventsSince(4), isEmpty);
      }
    });

    // -----------------------------------------------------------------------
    test('a taken seq is TransportContested, and the log is unharmed',
        () async {
      final r = await record(config);
      await r.pair.host
          .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 3, 1));

      await expectLater(
        r.pair.guest
            .sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.black, 5, 5)),
        throwsA(isA<TransportContested>()),
        reason: 'a lost race for a write-once index is contested, not rejected: '
            'the caller resyncs and retries at the next free index',
      );

      await waitFor(() => r.guestEvents.any((e) => e.seq == 1));
      final log = await r.pair.guest.eventsSince(0);
      expect(log.length, 1, reason: 'the loser must not have overwritten it');
      expect(log.single.author, r.pair.hostSession.hostAuthor);

      // …and the retry at the next index goes through.
      await r.pair.guest
          .sendEvent(seq: 2, gameNo: 1, event: RollEvent(Player.black, 5, 5));
      await waitFor(() => r.guestEvents.any((e) => e.seq == 2),
          reason: 'the retry at the next free index never landed');
      expect((await r.pair.guest.eventsSince(0)).length, 2);
      expect((await r.pair.host.eventsSince(0)).length, 2);
    });

    // -----------------------------------------------------------------------
    test('a roll walks committed → entropy → reveal, is RE-EMITTED at each '
        'phase, and fetchRoll/rollsSince agree with the frames', () async {
      final r = await record(config);
      final commit = 'aa' * 32;
      final entropy = 'bb' * 32;
      final reveal = 'cc' * 32;

      await r.pair.host.createRoll(1, commit);
      await waitFor(() => r.guestRolls.any((f) => f.n == 1),
          reason: 'the witness never saw the commitment');
      expect(await r.pair.guest.fetchRoll(1),
          isA<RollFrame>().having((f) => f.commit, 'commit', commit));
      expect((await r.pair.guest.fetchRoll(1))!.entropy, isNull);

      await r.pair.guest.sendEntropy(1, entropy);
      await waitFor(() => r.hostRolls.any((f) => f.n == 1 && f.entropy != null),
          reason: 'the roller never saw the entropy');

      await r.pair.host.sendReveal(1, reveal);
      await waitFor(() => r.guestRolls.any((f) => f.n == 1 && f.reveal != null),
          reason: 'the witness never saw the reveal');

      // The final state, pulled rather than streamed, must be identical.
      for (final t in [r.pair.host, r.pair.guest]) {
        final pulled = await t.fetchRoll(1);
        expect(pulled, isNotNull);
        expect(pulled!.commit, commit);
        expect(pulled.entropy, entropy);
        expect(pulled.reveal, reveal);
        expect(pulled.roller, r.pair.hostSession.hostAuthor,
            reason: 'the roller is the committer');
        expect(await t.fetchRoll(99), isNull,
            reason: 'a roll that does not exist yet is null, not a throw');
        final bulk = await t.rollsSince(1);
        expect(bulk.map((f) => f.n), [1],
            reason: 'rollsSince is the bulk companion a full replace needs');
        expect(bulk.single.reveal, reveal);
      }

      // Phases arrive in order within a roll — that is the only cross-frame
      // ordering promise the contract makes about rolls.
      final phases = r.guestRolls.where((f) => f.n == 1).toList();
      var seenEntropy = false;
      var seenReveal = false;
      for (final f in phases) {
        if (f.reveal != null) {
          seenReveal = true;
          expect(f.entropy, isNotNull,
              reason: 'a reveal frame must carry the entropy it is bound to');
        } else if (f.entropy != null) {
          expect(seenReveal, isFalse, reason: 'phases must not go backwards');
          seenEntropy = true;
        } else {
          expect(seenEntropy, isFalse, reason: 'phases must not go backwards');
        }
      }
      expect(seenReveal, isTrue);
    });

    // -----------------------------------------------------------------------
    test('a roll-phase write the authority refuses is TransportRejected, and '
        'inbound stays OPEN', () async {
      final r = await record(config);
      final commit = 'aa' * 32;
      final entropy = 'bb' * 32;

      await r.pair.host.createRoll(1, commit);

      // The roller contributing its OWN entropy is the one refusal every
      // backend must produce: it is what the commit-reveal protocol exists to
      // prevent (see fair_dice.dart), so it is enforced by the relay and by
      // firestore.rules alike.
      await expectLater(
        r.pair.host.sendEntropy(1, entropy),
        throwsA(isA<TransportRejected>()),
        reason: 'the roller cannot witness its own roll',
      );

      // A taken roll index is contested, exactly as a taken event seq is.
      await expectLater(
        r.pair.guest.createRoll(1, 'dd' * 32),
        throwsA(isA<TransportContested>()),
      );

      // A refusal is an ERROR RETURN, never a stream fault, and never a close.
      expect(r.hostClosed, isFalse);
      expect(r.guestClosed, isFalse);
      expect(r.pair.host.status, TransportStatus.connected,
          reason: 'a refused write is not a broken link');

      // And the honest continuation still works, which is the real point: a
      // rejection must leave the match playable.
      await r.pair.guest.sendEntropy(1, entropy);
      await waitFor(() => r.hostRolls.any((f) => f.n == 1 && f.entropy != null),
          reason: 'the refusal poisoned the handshake');
    });

    // -----------------------------------------------------------------------
    test('capabilities are self-consistent, and inboundCadence is a real '
        'number the controller can pace on', () async {
      final r = await record(config);

      // rejoinable implies durable: you cannot re-enter a match whose log did
      // not survive.
      if (r.pair.host.capabilities.rejoinable) {
        expect(r.pair.host.capabilities.durable, isTrue);
        expect(r.pair.hostSession.resumeToken, isNotNull,
            reason: 'a rejoinable transport must hand back something to rejoin '
                'with');
      }
      expect(r.pair.host.capabilities.rejoinable,
          r.pair.guest.capabilities.rejoinable,
          reason: 'both ends of one backend have the same capabilities');

      expect(r.pair.host.inboundCadence, isA<Duration>());
      expect(r.pair.host.inboundCadence.isNegative, isFalse);
      // Advisory in both directions; it must never throw or change the seam.
      r.pair.host.setPaceHint(fast: true);
      r.pair.host.setPaceHint(fast: false);
      expect(r.pair.host.status, TransportStatus.connected);
    });

    // -----------------------------------------------------------------------
    test('I/O before connect() is TransportUnavailable, not a silent no-op',
        () async {
      final factory = newUnconnected;
      if (factory == null) {
        markTestSkipped(
            '$name: no unconnected instance can be built in isolation');
        return;
      }
      final t = await factory();
      addTearDown(t.dispose);
      await expectLater(
        t.sendEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 3, 1)),
        throwsA(isA<TransportUnavailable>()),
        reason: 'the controller gates its UI on this await; a silent no-op '
            'would look like a committed write',
      );
    });
  }, skip: skip);
}

/// Frames sorted by seq with duplicates dropped — delivery is AT LEAST once, so
/// a duplicate is legal and must not fail an ordering assertion.
List<EventFrame> _bySeq(List<EventFrame> frames) {
  final byIndex = <int, EventFrame>{};
  for (final f in frames) {
    byIndex.putIfAbsent(f.seq, () => f);
  }
  final seqs = byIndex.keys.toList()..sort();
  return [for (final s in seqs) byIndex[s]!];
}

/// A pair with everything both endpoints emitted, recorded from the moment the
/// factory handed it over.
class _Rec {
  _Rec(this.pair) {
    _listen(pair.host, hostEvents, hostRolls, hostErrors, () => hostClosed = true);
    _listen(
        pair.guest, guestEvents, guestRolls, guestErrors, () => guestClosed = true);
  }

  final TransportPair pair;

  final hostEvents = <EventFrame>[];
  final guestEvents = <EventFrame>[];
  final hostRolls = <RollFrame>[];
  final guestRolls = <RollFrame>[];

  /// Inbound errors are COLLECTED rather than thrown, both so the "errors do not
  /// end the stream" clause can be asserted and so a transient blip on a real
  /// socket cannot fail an unrelated case.
  final hostErrors = <Object>[];
  final guestErrors = <Object>[];

  bool hostClosed = false;
  bool guestClosed = false;

  void _listen(
    MatchTransport t,
    List<EventFrame> events,
    List<RollFrame> rolls,
    List<Object> errors,
    void Function() onDone,
  ) {
    t.inbound.listen(
      (frame) {
        switch (frame) {
          case EventFrame():
            events.add(frame);
          case RollFrame():
            rolls.add(frame);
          case ResetFrame():
            // Legal at any moment and implementation-specific; the reset/replay
            // clause is tested per implementation.
            break;
        }
      },
      onError: errors.add,
      onDone: onDone,
    );
  }
}
