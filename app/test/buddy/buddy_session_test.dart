import 'dart:async';

import 'package:aigammon_app/buddy/buddy_policy.dart';
import 'package:aigammon_app/buddy/buddy_session.dart';
import 'package:aigammon_app/buddy/camera_frame_source.dart';
import 'package:aigammon_app/buddy/speaker.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/game/game_controller.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/test_database.dart';
import 'fake_vision.dart';

void main() {
  group('the opening', () {
    test('is read off the board and starts the match', () async {
      final h = Harness();
      h.vision.willReadDice([diceShowing(6, 3)]);

      h.start();
      expect(h.session.phase, BuddyPhase.awaitingDice,
          reason: 'the physical opening roll is the first thing asked for');
      expect(h.session.controller, isNull,
          reason: 'there is no game until the dice that start it are known');

      await h.stableFrame();

      expect(h.controller.state.dice, Dice(6, 3));
      expect(h.controller.state.turn, Player.white);
      expect(h.controller.state.phase, GamePhase.moving);
      expect(h.speech, contains(contains('6-3')));
    });

    test('re-rolls a double instead of starting a game with one', () async {
      final h = Harness();
      h.vision.willReadDice([diceShowing(4, 4), diceShowing(5, 2)]);

      h.start();
      await h.stableFrame();
      expect(h.session.controller, isNull,
          reason: 'a tie is re-rolled at a real board too');
      expect(h.speech.join(' ').toLowerCase(), contains('again'));

      await h.stableFrame();
      expect(h.controller.state.dice, Dice(5, 2));
      expect(h.controller.state.turn, Player.white);
    });
  });

  group('a turn end to end', () {
    test('dice read, play folded, buddy dictates, placement corrected',
        () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardDisagrees, boardAgrees]);

      h.start();
      await h.stableFrame(); // the opening roll

      expect(h.session.phase, BuddyPhase.awaitingPlay);
      final expectedPlay = h.controller.state.legalMoves.first;

      await h.stableFrame(); // the user's play, matched uniquely
      expect(h.policy.observedPlays.single.$1, Player.white);
      expect(h.policy.observedPlays.single.$2.sameAs(expectedPlay), isTrue);
      expect(h.controller.game.events.whereType<MoveEvent>(), hasLength(1),
          reason: 'a unique match folds straight into the authoritative state');

      // Buddy's side: its pre-roll gate, then its dice off the same board.
      expect(h.session.phase, BuddyPhase.awaitingDice);
      await h.stableFrame();

      expect(h.policy.buddyMoves, hasLength(1));
      expect(h.policy.buddyMoves.single.$1, Dice(6, 3));
      expect(h.session.phase, BuddyPhase.verifyingPlacement,
          reason: 'the man is dictated, not placed — the board must catch up');

      await h.stableFrame(); // the user puts it on the wrong point
      expect(h.policy.placements.single.$1, isFalse);
      expect(h.policy.placements.single.$2, isNotNull,
          reason: 'a wrong placement is named, not merely refused');
      expect(h.session.phase, BuddyPhase.verifyingPlacement);

      await h.stableFrame(); // corrected
      expect(h.policy.placements.last.$1, isTrue);
      expect(h.session.phase, BuddyPhase.awaitingDice,
          reason: 'placement verified, so the next roll may be asked for');

      expect(h.vision.verifyQueries.last, same(h.controller.state.board),
          reason: 'placement is a state-primed question: the position it is '
              'checked against is the one the game already holds');
    });

    test('holds the settled frame from before the play as the matcher needs',
        () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      final opening = blankFrame();
      await h.stableFrame(opening);
      await h.stableFrame();

      expect(h.vision.playQueries.single.beforeFrame, same(opening),
          reason: 'the frame the dice were read on is the position before the '
              'hand moved, and both frames must be one calibration epoch');
    });
  });

  group('an ambiguous play', () {
    test('surfaces its candidates and the pick folds it', () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesAmbiguously(0, 1)]);

      h.start();
      await h.stableFrame();
      final legal = h.controller.state.legalMoves;

      await h.stableFrame();
      expect(h.session.phase, BuddyPhase.disambiguating);
      expect(h.session.candidates, hasLength(2));
      expect(h.session.candidates.first.sameAs(legal[0]), isTrue);
      expect(h.session.candidates.last.sameAs(legal[1]), isTrue);
      expect(h.controller.game.events.whereType<MoveEvent>(), isEmpty,
          reason: 'nothing is folded while the answer is in doubt');

      h.session.pickCandidate(h.session.candidates.last);
      await h.settle();

      expect(h.controller.game.events.whereType<MoveEvent>(), hasLength(1));
      expect(h.controller.game.events.whereType<MoveEvent>().single.move
          .sameAs(legal[1]), isTrue);
      expect(h.session.candidates, isEmpty);
    });
  });

  group('an illegal play', () {
    test('is objected to, and the game does not move until the board is fixed',
        () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesNothing, matchesNothing, matchesPlay(0)])
        ..willVerify([boardDisagrees]);

      h.start();
      await h.stableFrame();
      final eventsBefore = h.controller.game.events.length;

      await h.stableFrame(); // nothing legal matches, and the board HAS moved
      expect(h.session.phase, BuddyPhase.objecting);
      expect(h.policy.objections, hasLength(1));
      expect(h.speech.join(' '), contains(h.policy.objections.single));
      expect(h.controller.game.events, hasLength(eventsBefore),
          reason: 'an objection is a sentence, not a state change');

      await h.stableFrame(); // still wrong: the objection is not repeated
      expect(h.policy.objections, hasLength(1));
      expect(h.controller.game.events, hasLength(eventsBefore));

      await h.stableFrame(); // the board is put right
      expect(h.session.phase, isNot(BuddyPhase.objecting));
      expect(h.session.objection, isNull);
      expect(h.controller.game.events.whereType<MoveEvent>(), hasLength(1));
    });

    test('covers a candidate that came back below the plausibility bar',
        () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesImplausibly(0)])
        ..willVerify([boardDisagrees]);

      h.start();
      await h.stableFrame();
      await h.stableFrame();

      expect(h.session.phase, BuddyPhase.objecting,
          reason: 'PlayMatch.plausible is read before PlayMatch.play — a '
              'best-of-a-bad-lot candidate is not an answer');
      expect(h.controller.game.events.whereType<MoveEvent>(), isEmpty);
    });

    test('is not raised while the hand simply has not moved yet', () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesNothing])
        ..willVerify([boardAgrees]);

      h.start();
      await h.stableFrame();
      await h.stableFrame();

      expect(h.policy.objections, isEmpty,
          reason: 'a board that still holds the position is a board mid-think');
      expect(h.session.phase, BuddyPhase.awaitingPlay);
    });
  });

  group('readability', () {
    test('red pauses the queries, and play resumes where it stopped', () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.stableFrame();
      expect(h.session.phase, BuddyPhase.awaitingPlay);

      h.vision.willSee([tooDarkReading]);
      final queriesBefore = h.vision.playCalls;
      await h.stableFrame();
      await h.stableFrame();

      expect(h.session.phase, BuddyPhase.paused);
      expect(h.vision.playCalls, queriesBefore,
          reason: 'answers are suppressed while the light is not green');
      expect(h.session.readability?.level, ReadabilityLevel.red);
      expect(h.policy.readings.last.cause, ReadabilityCause.tooDark);
      expect(h.controller.game.events.whereType<MoveEvent>(), isEmpty);

      h.vision
        ..willSee([greenReading])
        ..willMatchPlay([matchesNothing, matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.stableFrame();

      expect(h.session.phase, BuddyPhase.awaitingPlay,
          reason: 'the turn picks up exactly where it was interrupted');
      expect(h.vision.playCalls, greaterThan(queriesBefore),
          reason: 'and the question it picks up is the one it was asking');
      expect(h.controller.game.events.whereType<MoveEvent>(), isEmpty);

      await h.stableFrame();
      expect(h.controller.game.events.whereType<MoveEvent>(), hasLength(1));
    });

    test('a stale calibration parks the session without touching the game',
        () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.stableFrame();
      final eventsBefore = h.controller.game.events.length;

      h.vision.willSee([staleCalibrationReading]);
      await h.stableFrame();

      expect(h.session.phase, BuddyPhase.calibrating);
      expect(h.session.needsRecalibration, isTrue);
      expect(h.controller.game.events, hasLength(eventsBefore),
          reason: 'a readability outage never touches the authoritative state');

      final queriesBefore = h.vision.calls.length;
      await h.stableFrame();
      expect(h.vision.calls, hasLength(queriesBefore),
          reason: 'a dead calibration answers nothing at all, readability '
              'included — the guided flow owns the camera now');

      final fresh = FakeVision()..willMatchPlay([matchesPlay(0)]);
      h.session.useCalibration(fresh);
      expect(h.session.needsRecalibration, isFalse);
      expect(h.session.phase, BuddyPhase.awaitingPlay,
          reason: 'the turn resumes exactly where the outage caught it');

      final reAnchor = blankFrame();
      await h.stableFrame(reAnchor);
      expect(fresh.playCalls, 0,
          reason: 'the frame held from before the outage belongs to a dead '
              'epoch: differencing across two calibrations is noise shaped '
              'like a play, so the first clean frame only re-anchors');
      expect(h.controller.game.events, hasLength(eventsBefore));

      await h.stableFrame();
      expect(fresh.playQueries.single.beforeFrame, same(reAnchor));
      expect(h.controller.game.events.whereType<MoveEvent>(), hasLength(1),
          reason: 'the same turn finishes on the new calibration');
    });
  });

  group('the cube', () {
    test('buddy doubles by voice and the user answer folds', () async {
      final h = Harness(matchLength: 3, buddyDoubles: true);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.stableFrame(); // opening: the user is on roll
      await h.stableFrame(); // the user's play, folded

      expect(h.session.phase, BuddyPhase.awaitingCubeAnswer);
      expect(h.policy.cubeActions.single,
          (Player.black, BuddyCubeAction.offered));
      expect(h.speech.join(' ').toLowerCase(), contains('double'));
      expect(h.controller.state.phase, GamePhase.cubeOffered);

      h.session.answerDouble(CubeAction.drop);
      await h.settle();

      expect(h.policy.cubeActions.last, (Player.white, BuddyCubeAction.dropped));
      expect(h.controller.state.phase, GamePhase.gameOver);
      expect(h.policy.gameEnds.single.winner, Player.black);
      expect(h.controller.match.blackScore, 1);
    });
  });

  group('a whole game', () {
    test('plays out to a result and lands in history', () async {
      final db = newTestDatabase();
      addTearDown(db.close);
      final repo = MatchRepository(db);
      final matchId = await repo.startMatch(
        matchLength: 1,
        mode: 'buddy',
        whiteType: 'human',
        blackType: 'ai:hard',
      );

      final h = Harness(
        persistence: RepositoryPersistence(repo, Future<int>.value(matchId)),
      );
      h.vision
        ..willReadDice([diceShowing(6, 3), diceShowing(5, 2), diceShowing(4, 1)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      // Every frame answers whatever the phase is asking: a roll, a play, a
      // placement. Nothing else drives this — which is the point.
      for (var i = 0; i < 2000 && h.session.phase != BuddyPhase.over; i++) {
        await h.stableFrame();
      }

      expect(h.session.phase, BuddyPhase.over,
          reason: 'a match played entirely through the session reaches an end');
      expect(h.policy.gameEnds, hasLength(1));
      expect(h.policy.matchEnds, hasLength(1));
      expect(h.speech.last.toLowerCase(), contains('match'));

      final games = await repo.gamesFor(matchId);
      expect(games, hasLength(1));
      expect(games.single.resultWinner, h.policy.gameEnds.single.winner.name);

      // The record is the digital one: a replayable event log, reaching the
      // same result the session announced.
      final events = await repo.loadGameEvents(games.single.id);
      final replayed = Game.replay(events);
      expect(replayed.state.phase, GamePhase.gameOver);
      expect(replayed.state.result!.winner, h.policy.gameEnds.single.winner);
      expect(events.whereType<MoveEvent>().length, greaterThan(10),
          reason: 'a real game, not a two-move stub');
    });
  });

  group('persistence', () {
    test('a finished game lands in history through the standard path',
        () async {
      final db = newTestDatabase();
      addTearDown(db.close);
      final repo = MatchRepository(db);
      final matchId = await repo.startMatch(
        matchLength: 2,
        mode: 'buddy',
        whiteType: 'human',
        blackType: 'ai:hard',
      );

      final h = Harness(
        matchLength: 2,
        buddyDoubles: true,
        persistence: RepositoryPersistence(repo, Future<int>.value(matchId)),
      );
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.stableFrame();
      await h.stableFrame();
      h.session.answerDouble(CubeAction.drop);
      await h.settle();

      final games = await repo.gamesFor(matchId);
      expect(games, hasLength(1));
      expect(games.single.resultWinner, Player.black.name);
      expect(games.single.resultOutcome, GameOutcome.drop.name);
      final events = await repo.loadGameEvents(games.single.id);
      expect(events.first, isA<OpeningRollEvent>());

      final match = await repo.loadMatch(matchId);
      expect(match.blackScore, 1);
    });
  });

  group('the dice fallback', () {
    test('unreadable dice offer the pad, and manual entry folds', () async {
      final h = Harness();
      h.vision.willReadDice([null]);

      h.start();
      await h.stableFrame();
      expect(h.session.needsManualDice, isFalse,
          reason: 'one unreadable frame is a frame, not a failure');

      await h.stableFrame();
      expect(h.session.needsManualDice, isTrue);
      expect(h.session.controller, isNull);

      final callsBefore = h.vision.diceCalls;
      await h.stableFrame();
      expect(h.vision.diceCalls, callsBefore,
          reason: 'once the pad is offered, the camera stops guessing');

      h.session.enterDiceManually(Dice(5, 2));
      await h.settle();

      expect(h.controller.state.dice, Dice(5, 2));
      expect(h.session.needsManualDice, isFalse);
      expect(h.policy.diceReads.last.$3, isNull,
          reason: 'a typed roll carries no camera confidence');
    });
  });
}

/// One session, its fakes, and a frame pump.
class Harness {
  Harness({
    this.matchLength = 1,
    this.buddySide = Player.black,
    this.buddyDoubles = false,
    MatchPersistence persistence = const NoopPersistence(),
  }) {
    speaker = BuddySpeaker();
    policy = RecordingPolicy(
        OpponentPolicy(speaker: speaker, buddySide: buddySide));
    session = BuddySession(
      engine: ScriptedEngine(doubles: buddyDoubles),
      buddySide: buddySide,
      policy: policy,
      frames: frames.stream,
      matchLength: matchLength,
      persistence: persistence,
    );
    addTearDown(() async {
      session.dispose();
      await frames.close();
      await speaker.dispose();
    });
  }

  final int matchLength;
  final Player buddySide;
  final bool buddyDoubles;
  final FakeVision vision = FakeVision();
  final StreamController<ObservedFrame> frames =
      StreamController<ObservedFrame>.broadcast();
  late final BuddySpeaker speaker;
  late final RecordingPolicy policy;
  late final BuddySession session;

  GameController get controller => session.controller!;
  List<String> get speech => speaker.lines.map((l) => l.text).toList();

  void start() => session.useCalibration(vision);

  /// Pushes one settled frame and lets everything it set off finish.
  Future<void> stableFrame([Frame? frame]) async {
    frames.add(ObservedFrame(
      frame: frame ?? blankFrame(),
      motion: MotionHint.still,
      isStable: true,
      sceneChange: 0,
      at: Duration.zero,
    ));
    await settle();
  }

  /// Drains the microtask queue enough times for a controller step, an agent
  /// future and a persistence hook to have run.
  Future<void> settle([int rounds = 16]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// Buddy's decision-maker, without an engine isolate: it plays the first legal
/// move and doubles exactly when the test says so.
class ScriptedEngine implements PlayerAgent {
  ScriptedEngine({this.doubles = false, this.takes = true});

  final bool doubles;
  final bool takes;
  bool _doubled = false;

  @override
  bool get wantsDoublePrompts => true;

  @override
  Future<Move> chooseMove(GameState state) async =>
      state.legalMoves.isEmpty ? Move.none : state.legalMoves.first;

  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) async {
    if (!doubles || _doubled) return false;
    _doubled = true;
    return true;
  }

  @override
  Future<CubeAction> chooseCubeResponse(GameState state, MatchContext ctx) async =>
      takes ? CubeAction.take : CubeAction.drop;

  @override
  Future<bool> chooseResignResponse(
          GameState state, ResignValue value, MatchContext ctx) async =>
      true;

  @override
  void dispose() {}
}

/// The real [OpponentPolicy], with every event it received written down.
class RecordingPolicy implements BuddyPolicy {
  RecordingPolicy(this.inner);

  final BuddyPolicy inner;

  final List<(Player, Dice, double?)> diceReads = [];
  final List<(Player, Move)> observedPlays = [];
  final List<String> objections = [];
  final List<(Dice, Move)> buddyMoves = [];
  final List<(bool, String?)> placements = [];
  final List<(Player, BuddyCubeAction)> cubeActions = [];
  final List<Readability> readings = [];
  final List<GameResult> gameEnds = [];
  final List<Player> matchEnds = [];

  @override
  void onDiceRead(Player roller, Dice dice, double? confidence) {
    diceReads.add((roller, dice, confidence));
    inner.onDiceRead(roller, dice, confidence);
  }

  @override
  void onPlayObserved(Player mover, Move play) {
    observedPlays.add((mover, play));
    inner.onPlayObserved(mover, play);
  }

  @override
  void onIllegalPlayObserved(String reason) {
    objections.add(reason);
    inner.onIllegalPlayObserved(reason);
  }

  @override
  void onBuddyMoveChosen(Dice dice, Move play) {
    buddyMoves.add((dice, play));
    inner.onBuddyMoveChosen(dice, play);
  }

  @override
  void onPlacementVerified(bool correct, String? fix) {
    placements.add((correct, fix));
    inner.onPlacementVerified(correct, fix);
  }

  @override
  void onCubeAction(Player actor, BuddyCubeAction action) {
    cubeActions.add((actor, action));
    inner.onCubeAction(actor, action);
  }

  @override
  void onReadability(Readability state) {
    readings.add(state);
    inner.onReadability(state);
  }

  @override
  void onGameEnd(GameResult result) {
    gameEnds.add(result);
    inner.onGameEnd(result);
  }

  @override
  void onMatchEnd(Player winner) {
    matchEnds.add(winner);
    inner.onMatchEnd(winner);
  }

  @override
  void onOpeningRerolled(Dice tied) {
    inner.onOpeningRerolled(tied);
  }
}
