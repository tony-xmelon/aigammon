import 'dart:async';
import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';
import 'package:test/test.dart';

import 'socket_harness.dart';

/// The relay, end to end over a REAL loopback WebSocket: both directions, both
/// frame kinds, every typed error, and the resync a reconnect forces.
///
/// The transport contract lives in `packages/match_transport`; this suite proves
/// the socket implementation of it. What it does NOT test is game legality —
/// there is nothing here that could enforce any (that is the whole point of the
/// relay), and the controllers' side of the contract is proven in
/// `app/test/lan/lan_full_match_test.dart` over this very pair.
void main() {
  final commitA = _hex(0x11);
  final entropyB = _hex(0x22);
  final revealA = _hex(0x33);

  group('a live pair', () {
    late ServerFixture f;
    late GuestClient client;
    late SocketTransport hostTransport;
    late SocketTransport guestTransport;
    late List<InboundFrame> hostFrames;
    late List<InboundFrame> guestFrames;
    late List<Object> guestErrors;

    Future<TransportSession> open({int length = 3}) async {
      f = await ServerFixture.start(length: length);
      hostTransport = f.transport;
      hostFrames = [];
      hostTransport.inbound.listen(hostFrames.add);
      await hostTransport.connect();

      client = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        f.port,
        roomCode: testCode,
        name: 'Bo',
        timings: LanTimings.test,
      );
      guestTransport = SocketTransport.guest(client: client);
      guestFrames = [];
      guestErrors = [];
      guestTransport.inbound
          .listen(guestFrames.add, onError: (Object e) => guestErrors.add(e));
      return guestTransport.connect();
    }

    tearDown(() async {
      await guestTransport.dispose();
      await client.dispose();
      await f.dispose();
    });

    test('the handshake hands the joiner its seat, the config and the token',
        () async {
      final session = await open(length: 5);
      expect(session.assignedSide, Player.black);
      expect(session.isHost, isFalse);
      expect(session.config, const MatchConfig(length: 5));
      expect(session.matchCode, testCode);
      expect(session.localAuthor, MatchRelay.guestAuthor);
      expect(session.hostAuthor, MatchRelay.hostAuthor);
      expect(session.resumeToken, testToken);
      expect(session.sideOf(MatchRelay.hostAuthor), Player.white);
      expect(session.sideOf(MatchRelay.guestAuthor), Player.black);
      expect(session.sideOf('nobody'), isNull);

      // ...and the bound peer keeps white, with the same seat mapping.
      final hostSession = await hostTransport.connect();
      expect(hostSession.assignedSide, Player.white);
      expect(hostSession.isHost, isTrue);
      expect(hostSession.matchCode, testCode);
      expect(hostSession.resumeToken, testToken);

      expect(guestTransport.capabilities.durable, isFalse);
      expect(guestTransport.capabilities.rejoinable, isFalse);
      expect(hostTransport.capabilities.rejoinable, isFalse);
      expect(guestTransport.inboundCadence, Duration.zero);
      expect(hostTransport.inboundCadence, Duration.zero);
      // Advisory only, and a socket has one speed: it must not throw.
      guestTransport.setPaceHint(fast: true);
      hostTransport.setPaceHint(fast: false);
      expect(guestTransport.inboundCadence, Duration.zero);
    });

    test('the joiner is welcomed with a ResetFrame, not with silence', () async {
      await open();
      // The first welcome IS a "replay from the log" instruction: it arrives
      // before anyone can subscribe, which is exactly why the controller primes
      // with eventsSince(0) rather than trusting a replay.
      await waitFor(() => client.isConnected, what: 'the welcome');
      expect(guestTransport.opponentPresent, isTrue);
      expect(guestTransport.status, TransportStatus.connected);
      expect(guestTransport.statusReason, isNull);
    });

    test('events are relayed BOTH ways, and echoed back to their author',
        () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');

      // host -> guest
      await hostTransport.sendEvent(
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      await waitFor(() => guestFrames.whereType<EventFrame>().isNotEmpty,
          what: 'the host event to reach the guest');
      var seen = guestFrames.whereType<EventFrame>().last;
      expect(seen.seq, 1);
      expect(seen.author, MatchRelay.hostAuthor);
      // The host sees its own write too — the fold advances on the echo.
      expect(hostFrames.whereType<EventFrame>().single.seq, 1);

      // guest -> host, and back to the guest as an echo
      await guestTransport.sendEvent(
          seq: 2, gameNo: 1, event: const TakeEvent(Player.black));
      await waitFor(() => hostFrames.whereType<EventFrame>().length == 2,
          what: 'the guest event to reach the host');
      final atHost = hostFrames.whereType<EventFrame>().last;
      expect(atHost.seq, 2);
      expect(atHost.author, MatchRelay.guestAuthor,
          reason: 'the relay stamps the author from the connection');
      await waitFor(
          () => guestFrames.whereType<EventFrame>().length == 2,
          what: 'the echo of the guest\'s own event');
      seen = guestFrames.whereType<EventFrame>().last;
      expect(seen.seq, 2);
      expect(seen.author, MatchRelay.guestAuthor);
      expect(guestErrors, isEmpty);
    });

    test('a roll advances through its three phases on both peers', () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');

      // The host commits...
      await hostTransport.createRoll(1, commitA);
      await waitFor(() => guestFrames.whereType<RollFrame>().isNotEmpty,
          what: 'the commitment to reach the guest');
      expect(guestFrames.whereType<RollFrame>().last.phase,
          FairDicePhase.committed);

      // ...the guest witnesses...
      await guestTransport.sendEntropy(1, entropyB);
      await waitFor(
          () => hostFrames
              .whereType<RollFrame>()
              .any((r) => r.phase == FairDicePhase.entropy),
          what: 'the entropy to reach the host');

      // ...and the host reveals.
      await hostTransport.sendReveal(1, revealA);
      await waitFor(
          () => guestFrames
              .whereType<RollFrame>()
              .any((r) => r.phase == FairDicePhase.revealed),
          what: 'the reveal to reach the guest');

      final atGuest = await guestTransport.fetchRoll(1);
      expect(atGuest!.isComplete, isTrue);
      expect(atGuest.roller, MatchRelay.hostAuthor);
      expect(atGuest.commit, commitA);
      expect(atGuest.entropy, entropyB);
      expect(atGuest.reveal, revealA);
      expect((await hostTransport.fetchRoll(1))!.isComplete, isTrue);

      // The reverse direction: the GUEST rolls and the host witnesses.
      await guestTransport.createRoll(2, commitA);
      await waitFor(() => f.relay.roll(2) != null, what: 'the guest commitment');
      await hostTransport.sendEntropy(2, entropyB);
      await waitFor(() => f.relay.roll(2)!.entropy != null, what: 'the entropy');
      await guestTransport.sendReveal(2, revealA);
      await waitFor(() => f.relay.roll(2)!.isComplete, what: 'the reveal');
      expect((await guestTransport.fetchRoll(2))!.roller,
          MatchRelay.guestAuthor);
    });

    test('the joiner answers eventsSince/rollsSince exactly, from its mirror',
        () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');
      for (var seq = 1; seq <= 3; seq++) {
        await hostTransport.createRoll(seq, commitA);
        await hostTransport.sendEvent(
            seq: seq,
            gameNo: 1,
            event: seq == 1
                ? const OpeningRollEvent(whiteDie: 6, blackDie: 1)
                : RollEvent(Player.white, seq, 1));
      }
      await waitFor(() => guestFrames.whereType<EventFrame>().length == 3,
          what: 'all three events');

      expect((await guestTransport.eventsSince(0)).map((e) => e.seq), [1, 2, 3]);
      expect((await guestTransport.eventsSince(2)).map((e) => e.seq), [3]);
      expect(await guestTransport.eventsSince(3), isEmpty);
      expect((await guestTransport.rollsSince(1)).map((r) => r.n), [1, 2, 3]);
      expect((await guestTransport.rollsSince(3)).map((r) => r.n), [3]);
      expect(await guestTransport.fetchRoll(9), isNull);
      // And the same answers on the bound peer, straight out of the relay.
      expect((await hostTransport.eventsSince(1)).map((e) => e.seq), [2, 3]);
      expect((await hostTransport.rollsSince(2)).map((r) => r.n), [2, 3]);
    });

    test('a taken seq is CONTESTED, quoting the relay seq', () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');
      await hostTransport.sendEvent(
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      await waitFor(() => f.relay.lastSeq == 1, what: 'the opening roll');

      await expectLater(
        guestTransport.sendEvent(
            seq: 1, gameNo: 1, event: const TakeEvent(Player.black)),
        throwsA(isA<TransportContested>()
            .having((e) => e.peerLastSeq, 'peerLastSeq', 1)),
      );
      expect(f.relay.lastSeq, 1);

      // A taken ROLL index is contested too.
      await hostTransport.createRoll(1, commitA);
      await expectLater(guestTransport.createRoll(1, entropyB),
          throwsA(isA<TransportContested>()));
    });

    test('a refused roll phase is REJECTED and never retried', () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');
      await guestTransport.createRoll(1, commitA);
      await waitFor(() => f.relay.roll(1) != null, what: 'the commitment');

      // Its own roll: the roller may not contribute the entropy.
      await expectLater(guestTransport.sendEntropy(1, entropyB),
          throwsA(isA<TransportRejected>()));
      // And it may not reveal before the witness has answered.
      await expectLater(guestTransport.sendReveal(1, revealA),
          throwsA(isA<TransportRejected>()));
      // A phase write to a roll nobody created is refused as well.
      await expectLater(guestTransport.sendEntropy(7, entropyB),
          throwsA(isA<TransportRejected>()));
      expect(f.relay.roll(1)!.phase, FairDicePhase.committed);
    });

    test('a write with no link is UNAVAILABLE, not a silent success', () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');
      await f.server.stop(); // the relay is gone; the client starts retrying
      await waitFor(() => !client.isConnected, what: 'the guest to notice');

      await expectLater(
        guestTransport.sendEvent(
            seq: 1, gameNo: 1, event: const TakeEvent(Player.black)),
        throwsA(isA<TransportUnavailable>()),
      );
      expect(guestTransport.status, TransportStatus.reconnecting);
      expect(guestTransport.opponentPresent, isFalse,
          reason: 'a link that is down proves nothing about the other player');
    });

    test('the bound peer sees the joiner arrive and leave', () async {
      await open();
      await waitFor(() => hostTransport.opponentPresent,
          what: 'the host to see the guest');
      // The (re)join re-primes the host too — a guest may have written while the
      // host was not listening to it.
      expect(hostFrames.whereType<ResetFrame>(), isNotEmpty);
      expect(hostFrames.whereType<ResetFrame>().last.resumeToken, testToken);

      final presence = <bool>[];
      hostTransport.opponentPresence.listen(presence.add);
      await f.server.disconnectGuest('test drop');
      await waitFor(() => !hostTransport.opponentPresent,
          what: 'the host to see the guest leave');
      expect(presence, contains(false));
    });

    test('a reconnect replays the whole log and says so', () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');
      await hostTransport.sendEvent(
          seq: 1,
          gameNo: 1,
          event: const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      await hostTransport.createRoll(1, commitA);
      await waitFor(() => guestFrames.whereType<EventFrame>().isNotEmpty,
          what: 'the first event');
      final resetsBefore = guestFrames.whereType<ResetFrame>().length;

      // The link is cut, and the match moves on WITHOUT the guest.
      await f.server.disconnectGuest('abrupt drop');
      await waitFor(() => !client.isConnected, what: 'the drop');
      expect(guestTransport.status, TransportStatus.reconnecting);
      for (var seq = 2; seq <= 4; seq++) {
        await hostTransport.sendEvent(
            seq: seq,
            gameNo: 1,
            event: RollEvent(Player.white, seq, 1));
      }

      // It comes back on its own, and the welcome IS the resync.
      await waitFor(() => client.isConnected, what: 'the reconnect');
      await waitFor(
          () => guestFrames.whereType<ResetFrame>().length > resetsBefore,
          what: 'the ResetFrame');
      await waitForMirror(guestTransport, 4);
      expect((await guestTransport.eventsSince(0)).map((e) => e.seq),
          [1, 2, 3, 4],
          reason: 'contiguous, and complete — nothing was lost in the drop');
      expect((await guestTransport.rollsSince(1)).map((r) => r.n), [1]);
      expect(guestTransport.opponentPresent, isTrue);
      // The identity is unchanged, so the controller keeps its watermarks.
      expect(guestFrames.whereType<ResetFrame>().last.resumeToken, testToken);
    });

    test('a second joiner is told BUSY and keeps trying', () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the first guest');

      final second = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        f.port,
        roomCode: testCode,
        name: 'Cy',
        timings: LanTimings.test,
      );
      final secondTransport = SocketTransport.guest(client: second);
      addTearDown(() async {
        await secondTransport.dispose();
        await second.dispose();
      });
      final statuses = <TransportStatus>[];
      secondTransport.statusStream.listen((e) => statuses.add(e.status));

      await waitFor(() => secondTransport.status == TransportStatus.busy,
          what: 'the busy status');
      expect(statuses, contains(TransportStatus.busy));
      expect(secondTransport.statusReason, contains('already playing'));
      expect(secondTransport.opponentPresent, isFalse);
      expect(statuses, isNot(contains(TransportStatus.failed)),
          reason: 'busy is self-clearing, not terminal');
    });

    test('a wrong room code is a terminal REJECTION of connect', () async {
      f = await ServerFixture.start();
      hostTransport = f.transport;
      hostFrames = [];
      client = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        f.port,
        roomCode: '0000',
        name: 'Bo',
        timings: LanTimings.test,
      );
      guestTransport = SocketTransport.guest(client: client);
      guestFrames = [];
      guestErrors = [];
      await expectLater(
          guestTransport.connect(), throwsA(isA<TransportRejected>()));
      expect(guestTransport.status, TransportStatus.failed);
      expect(f.server.hasGuest, isFalse);
    });

    test('dispose leaves the link alone and refuses further work', () async {
      await open();
      await waitFor(() => f.server.hasGuest, what: 'the guest slot');
      await guestTransport.dispose();
      await guestTransport.dispose(); // idempotent

      expect(client.isConnected, isTrue,
          reason: 'the transport does not own the link — the screen does');
      expect(f.server.hasGuest, isTrue);
      await expectLater(guestTransport.eventsSince(0),
          throwsA(isA<TransportUnavailable>()));

      await hostTransport.dispose();
      await hostTransport.dispose(); // idempotent
      expect(f.server.hasGuest, isTrue,
          reason: 'the bound peer\'s server outlives its transport');
      await expectLater(
          hostTransport.sendEvent(
              seq: 1, gameNo: 1, event: const TakeEvent(Player.white)),
          throwsA(isA<TransportUnavailable>()));
    });
  });

  group('a joiner whose mirror falls behind', () {
    test('a gap is never published; the whole log is re-requested instead',
        () async {
      // A hand-written relay, so a MISSING frame can be produced on purpose —
      // the one thing a healthy socket never does, and the case the mirror's
      // contiguity rule exists for.
      final scripted = await _ScriptedRelay.start();
      addTearDown(scripted.stop);

      final client = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        scripted.port,
        roomCode: testCode,
        name: 'Bo',
        timings: LanTimings.test,
      );
      final transport = SocketTransport.guest(client: client);
      addTearDown(() async {
        await transport.dispose();
        await client.dispose();
      });
      final frames = <InboundFrame>[];
      transport.inbound.listen(frames.add);

      scripted.log = [
        _entry(1, MatchRelay.hostAuthor,
            const OpeningRollEvent(whiteDie: 6, blackDie: 1)),
        _entry(2, MatchRelay.hostAuthor, const RollEvent(Player.white, 3, 1)),
      ];
      await transport.connect();
      await waitFor(() => scripted.hellos == 1, what: 'the handshake');
      expect((await transport.eventsSince(0)).map((e) => e.seq), [1, 2]);

      // Now the relay "loses" seqs 3 and 4 and pushes 5.
      scripted.push(EventMessage(
          _entry(5, MatchRelay.guestAuthor, const TakeEvent(Player.black))));
      await waitFor(() => scripted.hellos == 2,
          what: 'the transport to ask for the whole log again');
      expect(frames.whereType<EventFrame>().map((e) => e.seq), isEmpty,
          reason: 'an orphan frame is never published — it would open a hole');
      expect((await transport.eventsSince(0)).map((e) => e.seq), [1, 2],
          reason: 'the mirror stayed contiguous');

      // The answer to that hello carries everything, and re-primes the fold.
      scripted.log = [
        for (var seq = 1; seq <= 5; seq++)
          _entry(seq, MatchRelay.hostAuthor,
              seq == 1
                  ? const OpeningRollEvent(whiteDie: 6, blackDie: 1)
                  : RollEvent(Player.white, 3, 1)),
      ];
      scripted.answerHello();
      await waitForMirror(transport, 5);
      expect((await transport.eventsSince(0)).map((e) => e.seq), [1, 2, 3, 4, 5]);
      expect(frames.whereType<ResetFrame>().length, greaterThanOrEqualTo(2));
    });

    test('a resync request is repeated until it is answered', () async {
      final scripted = await _ScriptedRelay.start(autoAnswerHello: false);
      addTearDown(scripted.stop);
      final client = GuestClient.connect(
        InternetAddress.loopbackIPv4.address,
        scripted.port,
        roomCode: testCode,
        name: 'Bo',
        timings: LanTimings.test,
      );
      final transport = SocketTransport.guest(client: client);
      addTearDown(() async {
        await transport.dispose();
        await client.dispose();
      });
      transport.inbound.listen((_) {});

      scripted.log = [
        _entry(1, MatchRelay.hostAuthor,
            const OpeningRollEvent(whiteDie: 6, blackDie: 1))
      ];
      scripted.answerHello(); // only the handshake is answered
      await transport.connect();

      // The relay now DROPS every hello (its rate limiter would, inside the
      // window), so one resync request is not enough.
      scripted.push(EventMessage(
          _entry(4, MatchRelay.guestAuthor, const TakeEvent(Player.black))));
      await waitFor(() => scripted.hellos >= 3,
          timeout: const Duration(seconds: 5),
          what: 'the transport to keep asking');
    });

    test('a welcome log that is not contiguous from 1 is REFUSED, not mirrored',
        () async {
      // The welcome used to be adopted wholesale, unchecked. The host is the
      // untrusted peer here, and the mirror IS this transport's answer to
      // [MatchTransport.eventsSince] — which the contract requires to be
      // ascending and contiguous. A hole (`[1, 2, 4]`) would hand a folder an
      // answer with a gap in it; a reordering (`[3, 1, 2]`) would pin the
      // mirror's lastSeq at 2 and livelock the resync loop at
      // `helloMinInterval` for the rest of the match.
      for (final bad in <List<int>>[
        [1, 2, 4],
        [3, 1, 2],
        [2, 3],
      ]) {
        final scripted = await _ScriptedRelay.start();
        addTearDown(scripted.stop);
        final client = GuestClient.connect(
          InternetAddress.loopbackIPv4.address,
          scripted.port,
          roomCode: testCode,
          name: 'Bo',
          timings: LanTimings.test,
        );
        final transport = SocketTransport.guest(client: client);
        addTearDown(() async {
          await transport.dispose();
          await client.dispose();
        });
        final frames = <InboundFrame>[];
        final errors = <Object>[];
        transport.inbound
            .listen(frames.add, onError: (Object e) => errors.add(e));

        scripted.log = [
          for (final seq in bad)
            _entry(seq, MatchRelay.hostAuthor,
                const OpeningRollEvent(whiteDie: 6, blackDie: 1)),
        ];
        await waitFor(() => errors.isNotEmpty,
            what: 'the refusal of $bad');

        expect(errors.first, isA<TransportRejected>(),
            reason: 'a deterministic protocol fault, never a retryable blip');
        expect((errors.first as TransportRejected).code, 'bad-welcome');
        // Deterministic, so the link is reported terminally failed rather than
        // left re-asking a question that has one answer.
        expect(transport.status, TransportStatus.failed);
        expect(await mirrorSeqs(transport), isEmpty,
            reason: 'the mirror was left alone rather than corrupted');
        expect(frames.whereType<ResetFrame>(), isEmpty,
            reason: 'nothing to replay from, so no replay is ordered');
        // …and connect() must FAIL on it too. The refusal above deliberately
        // leaves the mirror alone, so a connect that went on to mint a session
        // from the very welcome this transport just refused would hand the
        // controller a live, "connected" seat over an EMPTY log for a match the
        // host has been playing — a silent divergence instead of a failure.
        await expectLater(
          transport.connect(),
          throwsA(isA<TransportRejected>()
              .having((e) => e.code, 'code', 'bad-welcome')),
          reason: 'a refused welcome is no basis for a session',
        );
        expect(await mirrorSeqs(transport), isEmpty);
      }
    });
  });

  group('the bound peer and repeated hellos', () {
    test('a resync hello is answered with the log but does NOT reset the host',
        () async {
      // A `hello` is a join, a rejoin AND a plain resync request. Emitting a
      // ResetFrame on every one of them put the host into a permanent replace —
      // and each reset clears its in-flight submission gate, so a guest stuck
      // behind a gap (or a hostile one) could stop the host player from ever
      // completing a decision. The host's own fold cannot be missing anything a
      // replay would add: its writes go through the relay it is subscribed to.
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final hostFrames = <InboundFrame>[];
      f.transport.inbound.listen(hostFrames.add);
      await f.transport.connect();

      final guest = await RawGuest.connect(f.server, autoPong: true);
      addTearDown(guest.close);
      guest.hello();
      await waitFor(() => guest.gotWelcome, what: 'the welcome');
      await waitFor(() => hostFrames.whereType<ResetFrame>().length == 1,
          what: 'the join reset');

      // Two more hellos, spaced past the relay's hello limiter so both land.
      for (var i = 0; i < 2; i++) {
        await settle(250);
        guest.hello();
        await waitFor(() => guest.of<WelcomeMessage>().length >= i + 2,
            what: 'welcome ${i + 2}');
      }
      await settle(120);

      expect(guest.of<WelcomeMessage>().length, 3,
          reason: 'every hello is still answered with the whole log');
      expect(hostFrames.whereType<ResetFrame>().length, 1,
          reason: 'but only the (re)connection reset the host\'s own fold');
    });

    test('a guest that leaves and comes back DOES reset the host again',
        () async {
      final f = await ServerFixture.start();
      addTearDown(f.dispose);
      final hostFrames = <InboundFrame>[];
      f.transport.inbound.listen(hostFrames.add);
      await f.transport.connect();

      final first = await RawGuest.connect(f.server, autoPong: true);
      first.hello();
      await waitFor(() => first.gotWelcome, what: 'the first welcome');
      await waitFor(() => hostFrames.whereType<ResetFrame>().length == 1,
          what: 'the first join reset');

      await first.close();
      await waitFor(() => !f.server.hasGuest, what: 'the guest to leave');

      final second = await RawGuest.connect(f.server, autoPong: true);
      addTearDown(second.close);
      second.hello();
      await waitFor(() => second.gotWelcome, what: 'the second welcome');
      await waitFor(() => hostFrames.whereType<ResetFrame>().length == 2,
          what: 'the rejoin reset — a NEW connection may have written');
    });
  });
}

String _hex(int fill) => fill.toRadixString(16).padLeft(kHexLength, '0');

EventFrame _entry(int seq, String author, GameEvent event) =>
    EventFrame(seq: seq, gameNo: 1, author: author, event: event);

/// The seqs [t]'s mirror currently holds.
Future<List<int>> mirrorSeqs(MatchTransport t) async =>
    [for (final e in await t.eventsSince(0)) e.seq];

/// Poll [t]'s mirror until it ends at [lastSeq]. The pulls are asynchronous, so
/// this cannot go through [waitFor]'s synchronous predicate.
Future<void> waitForMirror(
  MatchTransport t,
  int lastSeq, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final seqs = await mirrorSeqs(t);
    if (seqs.isNotEmpty && seqs.last == lastSeq) return;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('the mirror never reached seq $lastSeq (saw $seqs)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
}

/// A relay written by hand: it speaks the protocol but does exactly what a test
/// tells it to, including losing frames and ignoring hellos.
class _ScriptedRelay {
  _ScriptedRelay(this._server, {required this.autoAnswerHello}) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      socket.listen((Object? data) {
        if (data is! String) return;
        final result = Envelope.decode(data);
        if (result is! DecodeOk) return;
        final message = result.envelope;
        if (message is HelloMessage) {
          hellos++;
          if (autoAnswerHello || _answerNext) {
            _answerNext = false;
            answerHelloNow();
          }
        }
      }, onError: (Object _) {}, cancelOnError: true);
    }, onError: (Object _) {});
  }

  static Future<_ScriptedRelay> start({bool autoAnswerHello = true}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ScriptedRelay(server, autoAnswerHello: autoAnswerHello);
  }

  final HttpServer _server;
  final bool autoAnswerHello;

  WebSocket? _socket;
  bool _answerNext = false;

  /// The log the next welcome will carry.
  List<EventFrame> log = [];

  /// Roll documents the next welcome will carry.
  List<RollFrame> rolls = [];

  /// How many hellos have arrived.
  int hellos = 0;

  int get port => _server.port;

  /// Answer the NEXT hello (or, when the current log is already what we want,
  /// answer right now if one is outstanding).
  void answerHello() {
    _answerNext = true;
    if (hellos > 0) answerHelloNow();
  }

  void answerHelloNow() {
    _answerNext = false;
    push(WelcomeMessage(
      config: const MatchConfig(length: 3),
      side: Player.black,
      resume: testToken,
      log: log,
      rolls: rolls,
    ));
  }

  void push(Envelope message) {
    try {
      _socket?.add(message.encode());
    } catch (_) {
      // gone
    }
  }

  Future<void> stop() async {
    try {
      await _socket?.close();
    } catch (_) {
      // gone
    }
    await _server.close(force: true);
  }
}
