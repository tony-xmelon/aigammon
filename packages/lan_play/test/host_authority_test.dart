import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:lan_play/lan_play.dart';
import 'package:test/test.dart';

import 'host_harness.dart';

/// The standard 6-1 opening play for White: 13/7, 8/7 (indices 12>6, 7>6).
final opening61 =
    Move([const CheckerMove(12, 6), const CheckerMove(7, 6)]);

void main() {
  group('handshake', () {
    test('hello starts the match and welcomes the guest', () async {
      final h = HostHarness(length: 3, dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      expect(h.host.started, isFalse);
      expect(h.host.state, isNull);

      await h.hello(name: 'Bo');

      final welcome = h.sent.first.message as WelcomeMessage;
      expect(h.sent.first.to, HostDestination.guest);
      expect(welcome.config, const MatchConfig(length: 3, cubeless: false));
      expect(welcome.side, Player.black, reason: 'host takes white by default');
      expect(welcome.resume, h.host.resumeToken);
      expect(welcome.log, isEmpty, reason: 'the opening roll follows as an event');

      final opening = h.sent[1];
      expect(opening.to, HostDestination.both);
      final entry = (opening.message as EventMessage).entry;
      expect(entry.seq, 1, reason: 'seq starts at 1');
      expect(entry.gameNo, 1);
      expect(entry.event, const OpeningRollEvent(whiteDie: 6, blackDie: 1));
      expect(h.host.gameNumber, 1);
      expect(h.state.turn, Player.white);
      expect(h.state.phase, GamePhase.moving);
    });

    test('the host may play black; the guest is welcomed as white', () async {
      final h = HostHarness(hostSide: Player.black, dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      expect((h.sent.first.message as WelcomeMessage).side, Player.white);
      expect(h.host.guestSide, Player.white);
    });

    test('a resume hello replays the full log and changes nothing', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      final seqBefore = h.host.lastSeq;
      final stateBefore = h.state;

      final mark = h.mark;
      await h.hello(resume: h.host.resumeToken);

      final welcome = h.since(mark).single.message as WelcomeMessage;
      expect(welcome.log.map((e) => e.seq), [1, 2]);
      expect(welcome.log.last.event, MoveEvent(Player.white, opening61));
      expect(h.host.lastSeq, seqBefore, reason: 'a resume appends nothing');
      expect(h.state, stateBefore);
    });

    test('a ping is answered with a pong', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      h.host.onGuestMessage(const PingMessage());
      await h.pump();
      expect(h.sent.single.message, isA<PongMessage>());
      expect(h.sent.single.to, HostDestination.guest);
    });

    test('actions before the handshake are refused', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      await h.localRoll();
      expect(h.rejectSince(0).reason, contains('has not started'));
      expect(h.sent.single.to, HostDestination.local);
    });
  });

  group('roll authority', () {
    test('a roll request from the side on turn produces host dice', () async {
      final h = HostHarness(dice: [Dice(6, 1), Dice(5, 3)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      expect(h.state.turn, Player.black);

      final mark = h.mark;
      await h.guestRollRequest();
      final entry = (h.since(mark).single.message as EventMessage).entry;
      expect(entry.seq, 3);
      expect(entry.event, const RollEvent(Player.black, 5, 3));
      expect(h.since(mark).single.to, HostDestination.both);
      expect(h.state.phase, GamePhase.moving);
    });

    test('a roll request out of turn is refused', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      await h.guestRollRequest(); // white is on turn
      expect(h.rejectSince(mark).reason, contains('not your turn'));
      expect(h.sent.last.to, HostDestination.guest);
      expect(h.host.lastSeq, 1);
    });

    test('rolling twice is refused (already moving)', () async {
      final h = HostHarness(dice: [Dice(6, 1), Dice(5, 3)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      await h.guestRollRequest();
      final mark = h.mark;
      await h.guestRollRequest();
      expect(h.rejectSince(mark).reason, contains('not awaiting a roll'));
    });

    test('a guest cannot submit its own dice', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      final mark = h.mark;
      await h.guestSubmit(const RollEvent(Player.black, 6, 6));
      expect(h.rejectSince(mark).reason, contains('host-authoritative'));
      expect(h.host.lastSeq, 2);
    });
  });

  group('move validation', () {
    late HostHarness h;
    setUp(() async {
      h = HostHarness(dice: [Dice(6, 1), Dice(5, 3)]);
      addTearDown(h.dispose);
      await h.hello();
    });

    test('a legal move is applied and broadcast', () async {
      final mark = h.mark;
      await h.localSubmit(MoveEvent(Player.white, opening61));
      final out = h.since(mark).single;
      expect(out.to, HostDestination.both);
      expect((out.message as EventMessage).entry.seq, 2);
      expect(h.state.turn, Player.black);
      expect(h.state.phase, GamePhase.awaitingRoll);
    });

    test('hop ORDER does not matter', () async {
      await h.localSubmit(MoveEvent(
          Player.white,
          Move([const CheckerMove(7, 6), const CheckerMove(12, 6)])));
      expect(h.state.turn, Player.black, reason: 'the reversed move applied');
    });

    test('an illegal move is refused with the log to resync from', () async {
      final mark = h.mark;
      await h.localSubmit(
          MoveEvent(Player.white, Move([const CheckerMove(12, 9)])));
      final reject = h.rejectSince(mark);
      expect(reject.reason, contains('illegal move'));
      expect(reject.lastSeq, 1,
          reason: 'a rejection reports how far the host has got, not the log');
      expect(h.state.turn, Player.white, reason: 'nothing was applied');
    });

    test('plausible-but-wrong decompositions are refused', () async {
      // (a) two 6s when the dice are 6 and 1 — the classic extra-pips cheat.
      var mark = h.mark;
      await h.localSubmit(MoveEvent(
          Player.white,
          Move([const CheckerMove(23, 17), const CheckerMove(12, 6)])));
      expect(h.rejectSince(mark).reason, contains('illegal move'));
      expect(h.state.turn, Player.white, reason: 'nothing was applied');

      // (b) a 4 and a 1 on two different checkers: two hops, right shape,
      // reaches a position no legal 6-1 play reaches.
      mark = h.mark;
      await h.localSubmit(MoveEvent(
          Player.white,
          Move([const CheckerMove(12, 8), const CheckerMove(7, 6)])));
      expect(h.rejectSince(mark).reason, contains('illegal move'));
      expect(h.state.turn, Player.white);
    });

    test('a different route to the same position IS accepted', () async {
      // 13/9/6 walks one checker through point 9 instead of the generator's
      // 13/7/6, and lands on exactly the same position — a decomposition the
      // move generator deduped away, which a hop-by-hop UI can still produce.
      // The authority accepts it (matching GameState.play) and logs it as
      // submitted.
      await h.localSubmit(MoveEvent(
          Player.white,
          Move([const CheckerMove(12, 8), const CheckerMove(8, 5)])));
      expect(h.state.turn, Player.black, reason: 'the move was applied');
      expect(h.state.board.points[5], 6);
      expect(h.state.board.points[12], 4);
      expect(h.host.log.last.event, isA<MoveEvent>());
    });

    test('a partial move (one die of two) is refused', () async {
      final mark = h.mark;
      await h.localSubmit(
          MoveEvent(Player.white, Move([const CheckerMove(12, 6)])));
      expect(h.rejectSince(mark).reason, contains('illegal move'));
    });

    test('a pass when legal moves exist is refused', () async {
      final mark = h.mark;
      await h.localSubmit(MoveEvent(Player.white, Move.none));
      expect(h.rejectSince(mark).reason, contains('illegal move'));
    });

    test('the log records the ENGINE\'s hit flags, not the peer\'s claim',
        () async {
      // White opens 24/23, 24/18 leaving two blots; Black's 1-4 hits both.
      final h = HostHarness(dice: [Dice(6, 1), Dice(1, 4)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(
          Player.white,
          Move([
            // ... and lies about hitting, which must be scrubbed on the way in.
            const CheckerMove(23, 22, isHit: true),
            const CheckerMove(23, 17, isHit: true),
          ])));
      expect(
          (h.host.log.last.event as MoveEvent)
              .move
              .checkerMoves
              .any((c) => c.isHit),
          isFalse,
          reason: 'a hit was claimed where there was none');

      await h.guestRollRequest();
      final hitting = h.state.legalMoves.firstWhere(
          (m) => m.checkerMoves.any((c) => c.isHit),
          orElse: () => fail('setup produced no hitting play for Black'));
      // The same play, submitted with every hit flag switched OFF.
      final lying = Move([
        for (final c in hitting.checkerMoves) CheckerMove(c.from, c.to),
      ]);
      await h.guestSubmit(MoveEvent(Player.black, lying));

      expect(h.state.turn, Player.white, reason: 'the move was applied');
      final recorded = (h.host.log.last.event as MoveEvent).move;
      expect(recorded.toString(), hitting.toString(),
          reason: 'the log carries the engine\'s own rendering of the play');
      expect(recorded.checkerMoves.any((c) => c.isHit), isTrue);
      expect(h.state.board.blackBar + h.state.board.whiteBar, greaterThan(0));
    });

    test('a route through a blocked point is logged by the sanctioned route',
        () async {
      // Hops 13/12, 12/7 walk one checker THROUGH the point Black owns with
      // five checkers. The net position is the legal 13/7/6's, so the play
      // stands — but what goes in the log is the engine's route, never the
      // peer's. (This is the residual the position-equivalence fallback would
      // otherwise leave in the authoritative history.)
      await h.localSubmit(MoveEvent(
          Player.white,
          Move([const CheckerMove(12, 11), const CheckerMove(11, 5)])));
      expect(h.state.turn, Player.black, reason: 'the play was accepted');
      final recorded = (h.host.log.last.event as MoveEvent).move;
      expect(recorded.checkerMoves.any((c) => c.to == 11), isFalse,
          reason: 'the logged route does not touch the blocked point');
      expect(h.state.board.points[5], 6);
      expect(h.state.board.points[11], -5, reason: 'Black\'s point is intact');
    });

    test('a move out of turn is refused', () async {
      final mark = h.mark;
      await h.guestSubmit(MoveEvent(Player.black, Move.none));
      expect(h.rejectSince(mark).reason, contains('not your turn'));
    });

    test('submitting for the other side is refused', () async {
      // White is on turn AND is the host, so the actor check (not the turn
      // check) is what catches this.
      final mark = h.mark;
      await h.localSubmit(MoveEvent(Player.black, opening61));
      expect(h.rejectSince(mark).reason, contains('is not your side'));
    });

    test('resubmitting an accepted move is refused as stale', () async {
      await h.localSubmit(MoveEvent(Player.white, opening61));
      final mark = h.mark;
      await h.localSubmit(MoveEvent(Player.white, opening61));
      expect(h.rejectSince(mark).reason, contains('not your turn'));
      expect(h.host.lastSeq, 2, reason: 'no duplicate entry was appended');
    });

    test('a move before rolling is refused', () async {
      await h.localSubmit(MoveEvent(Player.white, opening61));
      final mark = h.mark;
      await h.guestSubmit(MoveEvent(Player.black, Move.none));
      expect(h.rejectSince(mark).reason, contains('moving phase'));
    });
  });

  group('cube', () {
    test('double / take moves the cube and hands the roll back', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));

      await h.guestSubmit(const DoubleEvent(Player.black));
      expect(h.state.phase, GamePhase.cubeOffered);
      expect(h.state.turn, Player.white, reason: 'the decider is on turn');

      await h.localSubmit(const TakeEvent(Player.white));
      expect(h.state.cube.value, 2);
      expect(h.state.cube.owner, Player.white);
      expect(h.state.turn, Player.black);
      expect(h.state.phase, GamePhase.awaitingRoll);
    });

    test('drop ends the game and scores the pre-double cube', () async {
      final h = HostHarness(length: 3, dice: [Dice(6, 1), Dice(4, 2)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      await h.guestSubmit(const DoubleEvent(Player.black));
      final mark = h.mark;
      await h.localSubmit(const DropEvent(Player.white));

      expect(h.host.match.blackScore, 1, reason: 'the doubler wins the stake');
      expect(h.host.match.whiteScore, 0);
      expect(h.host.matchOver, isFalse);
      // The drop AND the next game's opening roll were both broadcast.
      final events = h.eventsSince(mark);
      expect(events.map((e) => e.entry.event.toJson()['type']),
          ['drop', 'openingRoll']);
      expect(events.last.entry.gameNo, 2);
      expect(events.map((e) => e.entry.seq), [4, 5]);
      expect(h.host.gameNumber, 2);
    });

    test('doubling out of turn is refused', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      await h.guestSubmit(const DoubleEvent(Player.black)); // white's turn
      expect(h.rejectSince(mark).reason, contains('not your turn'));
    });

    test('doubling mid-turn is refused', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      await h.localSubmit(const DoubleEvent(Player.white)); // still moving
      expect(h.rejectSince(mark).reason, contains('before rolling'));
    });

    test('only the cube owner may double', () async {
      final h = HostHarness(dice: [Dice(6, 1), Dice(4, 2), Dice(3, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      await h.guestSubmit(const DoubleEvent(Player.black));
      await h.localSubmit(const TakeEvent(Player.white)); // white owns the cube
      await h.guestRollRequest();
      await h.guestSubmit(MoveEvent(Player.black, h.state.legalMoves.first));
      await h.localRoll();
      await h.localSubmit(MoveEvent(Player.white, h.state.legalMoves.first));
      // Black no longer owns the cube.
      final mark = h.mark;
      await h.guestSubmit(const DoubleEvent(Player.black));
      expect(h.rejectSince(mark).reason, contains('cube owner'));
    });

    test('a cubeless match refuses doubles outright', () async {
      final h = HostHarness(cubeless: true, dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      expect((h.sent.first.message as WelcomeMessage).config.cubeless, isTrue);
      await h.localSubmit(MoveEvent(Player.white, opening61));
      final mark = h.mark;
      await h.guestSubmit(const DoubleEvent(Player.black));
      expect(h.rejectSince(mark).reason, contains('without the cube'));
    });
  });

  group('resignation', () {
    test('a declined resignation restores the prior phase', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      // White offers from the MOVING phase; declining must restore it.
      await h.localSubmit(
          const ResignOfferEvent(Player.white, ResignValue.single));
      expect(h.state.phase, GamePhase.resignOffered);
      expect(h.state.turn, Player.black);

      await h.guestSubmit(const ResignDeclineEvent(Player.black));
      expect(h.state.phase, GamePhase.moving);
      expect(h.state.turn, Player.white);
      await h.localSubmit(MoveEvent(Player.white, opening61));
      expect(h.state.turn, Player.black);
    });

    test('an accepted gammon resignation scores twice the cube', () async {
      final h = HostHarness(length: 5, dice: [Dice(6, 1), Dice(4, 2)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      await h.guestSubmit(
          const ResignOfferEvent(Player.black, ResignValue.gammon));
      await h.localSubmit(const ResignAcceptEvent(Player.white));
      expect(h.host.match.whiteScore, 2);
      expect(h.host.match.blackScore, 0);
      expect(h.host.gameNumber, 2);
    });

    test('accepting a resignation nobody offered is refused', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      await h.localSubmit(const ResignAcceptEvent(Player.white));
      expect(h.rejectSince(mark).reason, contains('no resignation is pending'));
    });

    test('a bogus resign value never reaches the game', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      await h.guestRaw(jsonEncode({
        'v': 1,
        'type': 'submit',
        'payload': {
          'event': {
            'type': 'resignOffer',
            'player': 'black',
            'value': 'quintuple',
          }
        },
      }));
      final reject = h.rejectSince(mark);
      expect(reject.reason, contains('unreadable event'));
      expect(reject.lastSeq, 1);
      expect(h.host.lastSeq, 1);
    });
  });

  group('match flow', () {
    test('Crawford is applied to the game after someone reaches match-1',
        () async {
      final h = HostHarness(length: 3, dice: [Dice(6, 1), Dice(5, 2)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      // Black resigns a gammon: White reaches 2 in a 3-point match.
      await h.guestSubmit(
          const ResignOfferEvent(Player.black, ResignValue.gammon));
      await h.localSubmit(const ResignAcceptEvent(Player.white));
      expect(h.host.match.whiteScore, 2);
      expect(h.host.match.crawfordPlayed, isFalse);
      expect(h.state.isCrawfordGame, isTrue, reason: 'game 2 is Crawford');

      // No doubling in the Crawford game, from either side.
      await h.localSubmit(MoveEvent(Player.white, h.state.legalMoves.first));
      final mark = h.mark;
      await h.guestSubmit(const DoubleEvent(Player.black));
      expect(h.rejectSince(mark).reason, contains('Crawford'));

      // Finish the match: black resigns a single point.
      await h.guestSubmit(
          const ResignOfferEvent(Player.black, ResignValue.single));
      await h.localSubmit(const ResignAcceptEvent(Player.white));
      expect(h.host.match.whiteScore, 3);
      expect(h.host.match.crawfordPlayed, isTrue);
      expect(h.host.matchOver, isTrue);
      expect(h.host.match.winner, Player.white);
      expect(h.host.gameNumber, 2, reason: 'no game 3 is started');
      expect(h.host.log.last.event, const ResignAcceptEvent(Player.white));
    });

    test('everything is refused once the match is over', () async {
      final h = HostHarness(length: 1, dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      await h.localSubmit(MoveEvent(Player.white, opening61));
      await h.guestSubmit(
          const ResignOfferEvent(Player.black, ResignValue.single));
      await h.localSubmit(const ResignAcceptEvent(Player.white));
      expect(h.host.matchOver, isTrue);

      final mark = h.mark;
      await h.guestRollRequest();
      await h.guestSubmit(MoveEvent(Player.black, Move.none));
      final reasons = h.rejectsSince(mark).map((r) => r.reason);
      expect(reasons, everyElement(contains('match is over')));
      expect(reasons, hasLength(2));
    });

    test('a 1-point match is its own Crawford game', () async {
      final h = HostHarness(length: 1, dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      expect(h.state.isCrawfordGame, isTrue);
    });
  });

  group('hostile peers', () {
    test('host-only frames from a guest are refused, not applied', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      for (final m in <Envelope>[
        EventMessage(const LogEntry(
            seq: 99, gameNo: 1, event: RollEvent(Player.white, 6, 6))),
        const WelcomeMessage(
            config: MatchConfig(length: 99), side: Player.white, log: []),
        const RejectMessage(reason: 'you lose', lastSeq: 99),
        const BusyMessage(),
      ]) {
        h.host.onGuestMessage(m);
      }
      await h.pump();
      expect(h.rejectsSince(mark), hasLength(4));
      expect(h.rejectsSince(mark).first.reason, contains('host-only'));
      expect(h.host.lastSeq, 1);
      expect(h.host.config.length, 3, reason: 'config is the host\'s alone');
    });

    test('a v2 hello is refused with a version reason', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      await h.guestRaw(jsonEncode({
        'v': 2,
        'type': 'hello',
        'payload': {'name': 'from the future'},
      }));
      final reject = h.rejectSince(0);
      expect(reject.reason, contains('version'));
      expect(reject.lastSeq, 0, reason: 'nothing has happened yet');
      expect(h.host.started, isFalse, reason: 'no match was started');
    });

    test('an unknown message type is ignored, not answered', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      await h.guestRaw(jsonEncode({'v': 1, 'type': 'chat', 'payload': {}}));
      expect(h.since(mark), isEmpty);
    });

    test('rejections cannot amplify, however long the log is', () async {
      final h = HostHarness(length: 3);
      addTearDown(h.dispose);
      await h.hello();

      // A rejection while the log holds ONE entry, to size against later.
      h.host.onGuestMessage(SubmitMessage(MoveEvent(h.guestSide, Move.none)));
      await h.pump();
      final earlyReject = h.sent.last.message as RejectMessage;
      expect(earlyReject.lastSeq, 1);

      // Build a log worth stealing, then stop on the HOST's turn so every
      // guest submission below is guaranteed invalid.
      var guard = 0;
      while ((h.host.lastSeq < 40 || h.state.turn != h.hostSide) &&
          guard++ < 400) {
        final s = h.state;
        if (s.phase == GamePhase.awaitingRoll) {
          await h.rollForTurn();
        } else {
          final legal = s.legalMoves;
          await h.submitAsTurn((side) =>
              MoveEvent(side, legal.isEmpty ? Move.none : legal.first));
        }
      }
      expect(h.host.lastSeq, greaterThanOrEqualTo(40));
      final logBytes =
          WelcomeMessage(config: h.host.config, side: h.guestSide, log: h.host.log)
              .encode()
              .length;
      expect(logBytes, greaterThan(3000), reason: 'the log is worth stealing');

      final seqBefore = h.host.lastSeq;
      final mark = h.mark;
      const junk = 50;
      for (var i = 0; i < junk; i++) {
        h.host.onGuestMessage(SubmitMessage(MoveEvent(h.guestSide, Move.none)));
        h.host.onGuestRaw('not json at all');
      }
      await h.pump();

      final replies = h.since(mark);
      expect(replies, hasLength(junk * 2));
      expect(replies.every((o) => o.message is RejectMessage), isTrue);
      final bytes = replies.fold<int>(0, (n, o) => n + o.message.encode().length);
      expect(bytes, lessThan(junk * 2 * 200));
      // THE property: a rejection's size is independent of the log. With 40x
      // the log, the reply grew only by the extra digits in lastSeq — where
      // attaching the log would have grown it by thousands of bytes.
      final lateReject = replies
          .map((o) => o.message)
          .whereType<RejectMessage>()
          .firstWhere((m) => m.reason.contains('not your turn'));
      expect(lateReject.encode().length - earlyReject.encode().length,
          lessThanOrEqualTo(4));
      expect(logBytes - earlyReject.encode().length, greaterThan(3000),
          reason: 'the log really is the big thing being withheld');
      expect(h.host.lastSeq, seqBefore, reason: 'and nothing moved');
      expect((replies.first.message as RejectMessage).lastSeq, seqBefore,
          reason: 'a peer learns only how far the host has got');
    });

    test('close stops emission and is idempotent', () async {
      final h = HostHarness(dice: [Dice(6, 1)]);
      addTearDown(h.dispose);
      await h.hello();
      final mark = h.mark;
      h.host.close();
      h.host.close();
      await h.localRoll();
      await h.guestRaw('garbage');
      expect(h.since(mark), isEmpty);
    });
  });

  group('a full match, driven through the authority', () {
    test('plays 3 points out with a self-sufficient log', () async {
      final h = HostHarness(
        length: 3,
        roller: ScriptedDiceRoller(const [], fallback: RandomDiceRoller(
            // A fixed seed: this whole match is reproducible.
            _SeededRandom(20260726))),
      );
      addTearDown(h.dispose);
      await h.hello(name: 'Bo');

      var turns = 0;
      var alternates = 0;
      while (!h.host.matchOver) {
        if (++turns > 4000) fail('the match did not finish in 4000 half-turns');
        final s = h.state;
        switch (s.phase) {
          case GamePhase.awaitingRoll:
            await h.rollForTurn();
          case GamePhase.moving:
            final legal = s.legalMoves;
            var move = legal.isEmpty ? Move.none : legal.first;
            // Where a two-hop single-checker play has an equally valid
            // alternate route, submit THAT instead: the authority must accept
            // any decomposition that reaches the same position.
            final alt = _alternateRoute(s, move);
            if (alt != null) {
              move = alt;
              alternates++;
            }
            await h.submitAsTurn((side) => MoveEvent(side, move));
          case _:
            fail('unexpected phase ${s.phase} in a plain match');
        }
      }

      // This seed plays 3 games / 310 events; the bounds only guard against a
      // future change quietly turning this into a trivial match.
      expect(h.host.gameNumber, greaterThanOrEqualTo(2));
      expect(h.host.lastSeq, greaterThan(100));
      expect(h.host.matchOver, isTrue);
      expect(h.host.match.winner, isNotNull);
      expect(
          [h.host.match.whiteScore, h.host.match.blackScore].reduce(max),
          greaterThanOrEqualTo(3));
      expect(alternates, greaterThan(0),
          reason: 'the alternate-decomposition path was never exercised');

      // Not one submission was refused along the way.
      expect(h.sent.where((o) => o.message is RejectMessage), isEmpty);

      // Seqs are contiguous from 1 and every entry was broadcast to both peers.
      final log = h.host.log;
      expect(log.map((e) => e.seq), List.generate(log.length, (i) => i + 1));
      final broadcast = h.sent.where((o) => o.message is EventMessage).toList();
      expect(broadcast, hasLength(log.length));
      expect(broadcast.every((o) => o.to == HostDestination.both), isTrue);
      expect(log.map((e) => e.gameNo).toSet(),
          {for (var i = 1; i <= h.host.gameNumber; i++) i});

      // THE GUEST'S VIEW, END TO END: every broadcast event goes out through
      // encode(), comes back through decode(), and is folded exactly as Task 3
      // will fold it. Reproducing the host's game and score from that alone is
      // proof the WIRE (not just the in-memory log) carries everything a peer
      // needs.
      final wire = <LogEntry>[];
      for (final o in broadcast) {
        final raw = o.message.encode();
        final decoded = Envelope.decode(raw);
        expect(decoded, isA<DecodeOk>(),
            reason: 'a broadcast frame failed to decode: $raw');
        wire.add(((decoded as DecodeOk).envelope as EventMessage).entry);
      }
      expect(wire.map((e) => e.seq), log.map((e) => e.seq));
      expect(wire.map((e) => e.gameNo), log.map((e) => e.gameNo));
      final folded = _foldAsGuest(wire, h.host.config.length);
      expect(folded.match, h.host.match);
      expect(folded.game.state, h.state);
      expect(folded.gameNo, h.host.gameNumber);
    });
  });
}

/// An alternate hop decomposition of [move] that lands on the same position:
/// a single checker's two hops taken in the other die order, when the other
/// intermediate point is free of opposing checkers (so the resulting position
/// — hits included — is identical). Null when [move] has no such route.
Move? _alternateRoute(GameState s, Move move) {
  final hops = move.checkerMoves;
  if (hops.length != 2) return null;
  final a = hops[0], b = hops[1];
  if (a.to != b.from) return null; // not one checker's chain
  if (a.from == CheckerMove.bar || b.to == CheckerMove.off) return null;
  final d1 = a.to - a.from, d2 = b.to - b.from;
  if (d1 == d2) return null; // doubles: the routes coincide
  final mid = a.from + d2;
  if (mid < 0 || mid > 23) return null;
  final occupant = s.board.points[mid];
  // Free of opponents (not even a blot: a hit would change the position).
  if (s.turn == Player.white ? occupant < 0 : occupant > 0) return null;
  final alt = Move([CheckerMove(a.from, mid), CheckerMove(mid, b.to)]);
  // Only interesting when it is NOT already a legal move by hop multiset —
  // that is the decomposition the generator deduped away.
  if (s.legalMoves.any((m) => m.sameAs(alt))) return null;
  return alt;
}

class _Folded {
  _Folded(this.game, this.match, this.gameNo);
  final Game game;
  final MatchState match;
  final int gameNo;
}

/// Fold a wire log exactly as a guest controller will: an `openingRoll` starts
/// a new game (Crawford inferred from the score so far), everything else is
/// appended, and a terminal result advances the match.
_Folded _foldAsGuest(List<LogEntry> log, int matchLength) {
  var match = MatchState(matchLength: matchLength);
  Game? game;
  var gameNo = 0;
  for (final entry in log) {
    final e = entry.event;
    if (e is OpeningRollEvent) {
      game = Game.start(e, isCrawfordGame: match.isCrawfordNext);
      gameNo++;
      continue;
    }
    game = game!.append(e);
    final result = game.state.result;
    if (result != null) match = match.applyResult(result);
  }
  return _Folded(game!, match, gameNo);
}

/// A tiny deterministic PRNG so the "full match" test is byte-for-byte
/// reproducible on every platform (dart:math's Random is seeded but its
/// algorithm is an implementation detail; this one is ours).
class _SeededRandom implements Random {
  _SeededRandom(int seed) : _s = seed & 0x7FFFFFFF;
  int _s;

  @override
  int nextInt(int max) {
    // Park-Miller minimal standard.
    _s = (_s * 48271) % 0x7FFFFFFF;
    return _s % max;
  }

  @override
  bool nextBool() => nextInt(2) == 0;

  @override
  double nextDouble() => nextInt(1 << 24) / (1 << 24);
}
