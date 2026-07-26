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
    final log = autoResyncLog;
    if (log != null) welcome(log);
    return true;
  }

  @override
  Future<void> dispose() => _out.close();

  void push(Envelope message) => _out.add(message);

  void event(LogEntry entry) => push(EventMessage(entry));

  void welcome(List<LogEntry> log) => push(WelcomeMessage(
        config: const MatchConfig(length: 5),
        side: Player.black,
        log: log,
      ));
}

void main() {
  ({FakeLink link, LanMatchController controller, RecordingPersistence rec})
      fixture({int length = 5, Player localSide = Player.white}) {
    final link = FakeLink();
    final rec = RecordingPersistence();
    final controller = LanMatchController.overLink(
      link: link,
      config: MatchConfig(length: length),
      localSide: localSide,
      persistence: rec,
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
