import 'dart:async';

import 'package:aigammon_app/lan/lan_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';

import 'lan_harness.dart';

/// A hand-driven [LanLink]: the test decides exactly what arrives and whether a
/// send leaves the device.
///
/// The recovery paths the fold has to get right — a seq GAP, a `reject` from
/// BEHIND, a send that never made it onto the wire — are the ones a healthy
/// socket never produces, so provoking them through a real connection would be
/// a race. Here they are one line each.
class FakeLink implements LanLink {
  final _out = StreamController<Envelope>();

  /// False models a link that is down: `send` returns false and the frame is
  /// dropped, exactly as [GuestClient.send] does while reconnecting.
  bool online = true;

  int resyncs = 0;
  int rollRequests = 0;
  final List<GameEvent> submitted = [];

  /// What the host would answer a [resync] with, if the test wants it automatic.
  List<LogEntry>? autoResyncLog;

  /// How many resync requests the host's `hello` limiter will swallow before
  /// answering. The send SUCCEEDS and nothing comes back — the failure mode a
  /// retry chain exists for.
  int dropResyncs = 0;

  /// The resume token every welcome carries: the fold's match identity.
  String resume = 'MATCH-A';

  @override
  Stream<Envelope> get inbound => _out.stream;

  @override
  bool requestRoll() {
    if (!online) return false;
    rollRequests++;
    return true;
  }

  @override
  bool submit(GameEvent event) {
    if (!online) return false;
    submitted.add(event);
    return true;
  }

  @override
  bool resync() {
    resyncs++;
    if (!online) return false;
    if (dropResyncs > 0) {
      dropResyncs--;
      return true; // accepted by the transport, dropped by the host
    }
    final log = autoResyncLog;
    if (log != null) welcome(log);
    return true;
  }

  @override
  Future<void> dispose() => _out.close();

  void push(Envelope message) => _out.add(message);

  void event(LogEntry entry) => push(EventMessage(entry));

  void welcome(List<LogEntry> log, {String? token}) => push(WelcomeMessage(
        config: const MatchConfig(length: 5),
        side: Player.black,
        resume: token ?? resume,
        log: log,
      ));
}

void main() {
  ({FakeLink link, LanMatchController controller, RecordingPersistence rec})
      fixture({
    int length = 5,
    Player localSide = Player.white,
    LanTimings timings = LanTimings.defaults,
  }) {
    final link = FakeLink();
    final rec = RecordingPersistence();
    final controller = LanMatchController.overLink(
      link: link,
      config: MatchConfig(length: length),
      localSide: localSide,
      persistence: rec,
      timings: timings,
    );
    addTearDown(controller.disposeController);
    return (link: link, controller: controller, rec: rec);
  }

  /// Feed [entries] and let the fold run.
  Future<void> feed(FakeLink link, Iterable<LogEntry> entries) async {
    for (final e in entries) {
      link.event(e);
    }
    await pumpEventQueue();
  }

  test('a seq gap asks for the whole log and heals on the welcome', () async {
    final log = authorityLog(length: 5, maxEntries: 6);
    final f = fixture();

    await feed(f.link, log.take(2));
    expect(f.controller.lastSeq, 2);
    expect(f.controller.error, isNull);

    // Skip seq 3: nothing incremental can close a gap.
    await feed(f.link, [log[3]]);
    expect(f.link.resyncs, 1);
    expect(f.controller.lastSeq, 2, reason: 'the out-of-order entry is not folded');
    expect((f.controller.error! as LanMatchException).code, 'diverged');

    // The host answers with the whole log; the fold is REPLACED and heals.
    f.link.welcome(log);
    await pumpEventQueue();
    expect(f.controller.error, isNull);
    expect(f.controller.lastSeq, log.last.seq);
    expect(f.controller.game.events.length, log.length);
  });

  test('a replayed entry is ignored, not re-folded', () async {
    final log = authorityLog(length: 5, maxEntries: 4);
    final f = fixture();

    await feed(f.link, log);
    final events = f.controller.game.events.length;

    await feed(f.link, [log[1], log[2], log.last]);
    expect(f.controller.lastSeq, log.last.seq);
    expect(f.controller.game.events.length, events);
    expect(f.link.resyncs, 0);
    expect(f.controller.error, isNull);
  });

  test('a reject from BEHIND resyncs; one that is LEVEL surfaces the reason',
      () async {
    final log = authorityLog(length: 5, maxEntries: 4);
    final f = fixture();
    await feed(f.link, log);

    // Level: the host has nothing we are missing, so this is about the
    // submission itself.
    f.link.push(RejectMessage(reason: 'not your turn', lastSeq: log.last.seq));
    await pumpEventQueue();
    expect(f.link.resyncs, 0);
    expect((f.controller.error! as LanMatchException).code, 'rejected');
    expect((f.controller.error! as LanMatchException).message, 'not your turn');

    // Behind: the refusal is a symptom of drift, so ask for the log.
    f.link.push(RejectMessage(reason: 'not your turn', lastSeq: log.last.seq + 4));
    await pumpEventQueue();
    expect(f.link.resyncs, 1);
    expect((f.controller.error! as LanMatchException).code, 'diverged');
  });

  test('a send that never left the device keeps the gate open for a retry',
      () async {
    // Opening + the opener's move: the OTHER side then holds the pre-roll gate.
    final log = authorityLog(length: 5, maxEntries: 2);
    final opener = (log[1].event as MoveEvent).player;
    final f = fixture(localSide: opener.opponent);
    await feed(f.link, log);
    expect(f.controller.awaitingHumanTurn, isTrue);

    f.link.online = false;
    f.controller.rollDice();
    await pumpEventQueue();

    expect(f.link.rollRequests, 0, reason: 'the frame was dropped');
    expect((f.controller.error! as LanMatchException).code, 'offline');
    expect(f.controller.awaitingHumanTurn, isTrue,
        reason: 'a blip must never deadlock the pre-roll gate');

    // The link comes back; the very same action is retaken and lands.
    f.link.online = true;
    f.controller.rollDice();
    await pumpEventQueue();
    expect(f.link.rollRequests, 1);
    expect(f.controller.error, isNull);
    // ...and the gate is latched until the log answers.
    expect(f.controller.awaitingHumanTurn, isFalse);
  });

  test('a dropped submit is retried after the resync, not replayed by us',
      () async {
    final log = authorityLog(length: 5, maxEntries: 2);
    final opener = (log[1].event as MoveEvent).player;
    final f = fixture(localSide: opener.opponent);
    await feed(f.link, log);

    f.link.online = false;
    f.controller.submitMove(f.controller.localSide, Move.none);
    await pumpEventQueue();
    expect(f.link.submitted, isEmpty);

    // The reconnect's welcome replaces the fold; nothing stale is resent.
    f.link.online = true;
    f.link.welcome(log);
    await pumpEventQueue();
    expect(f.link.submitted, isEmpty);
    expect(f.controller.error, isNull);
    expect(f.controller.awaitingHumanTurn, isTrue);
  });

  test('a welcome replaces the fold WITHOUT re-persisting or re-pausing',
      () async {
    // A 1-point match: one finished game, and the log ends there (the match is
    // over, so no next opening follows).
    final oneGame = authorityLog(length: 1);
    final link = FakeLink();
    final rec = RecordingPersistence();
    final controller = LanMatchController.overLink(
      link: link,
      config: const MatchConfig(length: 1),
      localSide: Player.white,
      persistence: rec,
    );
    addTearDown(controller.disposeController);

    await feed(link, oneGame);
    await pumpEventQueue();
    expect(controller.matchOver, isTrue);
    expect(rec.games.length, 1);
    expect(rec.matchFinishedCalls, 1);

    // The same log again (a reconnect resync). Everything re-derives; nothing
    // is recorded twice.
    link.welcome(oneGame);
    await pumpEventQueue();
    expect(controller.matchOver, isTrue);
    expect(controller.lastSeq, oneGame.last.seq);
    expect(rec.games.length, 1, reason: 'the game was already persisted');
    expect(rec.matchFinishedCalls, 1);
  });

  test('a game that ended while we were away still pauses once, then not again',
      () async {
    // A 5-point match played until game 2 has begun: the log holds a finished
    // game 1 followed by game 2's opening roll.
    final log = authorityLog(length: 5);
    final endOfGameOne =
        log.indexWhere((e) => e.gameNo == 2); // the next game's opening
    expect(endOfGameOne, greaterThan(0), reason: 'the fixture spans two games');
    final throughGameTwoOpening = log.sublist(0, endOfGameOne + 1);

    final f = fixture();
    // Arrives all at once, as a resync welcome would after a disconnect.
    f.link.welcome(throughGameTwoOpening);
    await pumpEventQueue();

    expect(f.controller.awaitingNextGame, isTrue,
        reason: 'the game-over dialog is owed even for a game missed offline');
    expect(f.controller.state.phase, GamePhase.gameOver);
    expect(f.rec.games.length, 1);

    f.controller.continueToNextGame();
    await pumpEventQueue();
    expect(f.controller.awaitingNextGame, isFalse);
    expect(f.controller.gameNumber, 2);

    // A SECOND resync must not re-open the dialog the user just dismissed.
    f.link.welcome(throughGameTwoOpening);
    await pumpEventQueue();
    expect(f.controller.awaitingNextGame, isFalse);
    expect(f.controller.gameNumber, 2);
    expect(f.rec.games.length, 1);
  });

  test('a resync the host drops is retried until it is answered', () async {
    final log = authorityLog(length: 5, maxEntries: 6);
    // LanTimings.test compresses the host's hello limiter (200ms), so the retry
    // lands 300ms later instead of a second and a half.
    final f = fixture(timings: LanTimings.test);
    await feed(f.link, log.take(2));

    f.link.autoResyncLog = log;
    f.link.dropResyncs = 1; // the limiter eats the first ask
    await feed(f.link, [log[3]]); // the gap

    expect(f.link.resyncs, 1);
    expect(f.controller.lastSeq, 2, reason: 'still behind, and nothing answered');
    expect((f.controller.error! as LanMatchException).code, 'diverged');

    // Nothing further will ever arrive on its own (this is the case where the
    // peer is behind AND on turn), so only the retry can heal it.
    await waitFor(() => f.controller.lastSeq == log.last.seq,
        what: 'the retried resync to land');
    expect(f.link.resyncs, 2);
    expect(f.controller.error, isNull);
  });

  test('the retry chain is bounded and stops asking', () async {
    final log = authorityLog(length: 5, maxEntries: 6);
    final f = fixture(timings: LanTimings.test);
    await feed(f.link, log.take(2));

    f.link.dropResyncs = 1000; // a host that never answers
    await feed(f.link, [log[3]]);

    await waitFor(() => f.link.resyncs >= 5, what: 'the attempts to run out');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(f.link.resyncs, 5, reason: 'bounded — a dead host is not hammered');
    expect(f.controller.error, isNotNull, reason: 'the banner stays up');
  });

  test('a welcome from a DIFFERENT match voids the watermarks', () async {
    final matchA = authorityLog(length: 1);
    final f = fixture(length: 1);

    f.link.welcome(matchA);
    await pumpEventQueue();
    expect(f.controller.matchOver, isTrue);
    expect(f.rec.games.length, 1);
    expect(f.rec.matchFinishedCalls, 1);

    // The host restarted (or a four-digit room code collided) and we are now
    // folding a DIFFERENT authority's log: its game 1 has never been recorded
    // here, and its game numbers start again at 1.
    final matchB = authorityLog(length: 1, hostSide: Player.black);
    f.link.welcome(matchB, token: 'MATCH-B');
    await pumpEventQueue();

    expect(f.controller.matchOver, isTrue);
    expect(f.rec.games.length, 2, reason: 'the new match records its own game 1');
    expect(f.rec.games.last.gameNumber, 1);
    expect(f.rec.matchFinishedCalls, 2);
  });

  test('the submitting gate is published for the UI', () async {
    final log = authorityLog(length: 5, maxEntries: 3);
    final opener = (log[1].event as MoveEvent).player;
    final f = fixture(localSide: opener.opponent);

    final seen = <bool>[];
    f.controller.submitting
        .addListener(() => seen.add(f.controller.submitting.value));

    await feed(f.link, log.take(2));
    expect(f.controller.submitting.value, isFalse);
    expect(f.controller.awaitingHumanTurn, isTrue);

    f.controller.rollDice();
    expect(f.controller.submitting.value, isTrue,
        reason: 'the intent is on the wire and the log has not answered');
    expect(f.controller.awaitingHumanTurn, isFalse);

    await feed(f.link, [log[2]]); // the host's answering roll
    expect(f.controller.submitting.value, isFalse);
    expect(seen, [true, false]);
  });

  test('an intent nothing ever answers re-opens the gate on its deadline',
      () async {
    final log = authorityLog(length: 5, maxEntries: 2);
    final opener = (log[1].event as MoveEvent).player;
    // LanTimings.test puts the deadline at 250ms rather than five seconds.
    final f = fixture(localSide: opener.opponent, timings: LanTimings.test);
    await feed(f.link, log);
    expect(f.controller.awaitingHumanTurn, isTrue);

    // The send SUCCEEDS — and then the host silently drops it (over its rate
    // limit, or on a socket it is about to reap). Nothing will ever answer.
    f.controller.rollDice();
    expect(f.link.rollRequests, 1);
    expect(f.controller.submitting.value, isTrue);
    expect(f.controller.awaitingHumanTurn, isFalse);

    await waitFor(() => !f.controller.submitting.value,
        what: 'the latch deadline');
    expect(f.controller.awaitingHumanTurn, isTrue,
        reason: 'a dropped frame costs one timeout, not the match');
    expect((f.controller.error! as LanMatchException).code, 'offline');

    // Acting again works, and this time it is answered.
    f.controller.rollDice();
    expect(f.link.rollRequests, 2);
  });

  test('a full replace does not re-animate the moves it replays', () async {
    final log = authorityLog(length: 5, maxEntries: 8);
    final f = fixture();

    var fires = 0;
    f.controller.lastMove.addListener(() => fires++);

    await feed(f.link, log);
    final liveFires = fires;
    expect(liveFires, greaterThan(0), reason: 'live moves DO animate');

    f.link.welcome(log);
    await pumpEventQueue();
    expect(fires, liveFires,
        reason: 'a resync snaps to the position; it does not replay the game');
    expect(f.controller.lastSeq, log.last.seq);
  });

  test('a fold that disagrees with the host resyncs once, not in a loop',
      () async {
    final log = authorityLog(length: 5, maxEntries: 3);
    final f = fixture();
    await feed(f.link, log);

    // A contiguous but IMPOSSIBLE entry: a roll while the mover is mid-move.
    f.link.autoResyncLog = log;
    f.link.event(LogEntry(
        seq: log.last.seq + 1,
        gameNo: 1,
        event: RollEvent(f.controller.state.turn, 3, 4)));
    await pumpEventQueue();

    expect(f.link.resyncs, 1);
    expect(f.controller.lastSeq, log.last.seq, reason: 'rebuilt to the log');
    expect(f.controller.error, isNull, reason: 'the rebuild healed it');
  });
}
