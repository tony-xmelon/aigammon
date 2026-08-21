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
      expect(h.speaker.lines.first,
          BuddyLine('You rolled 6-3.', speech: 'You rolled 6 3.'),
          reason: 'both channels, byte for byte: the hyphen is the score '
              "sheet's and a TTS engine reads it as a subtraction");
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

    test('the seat says which of the two dice the user threw', () async {
      // The user sits by the phone and plays White; Buddy is Black. The die on
      // the NEAR half of the board is therefore White's, and it is the lower of
      // the two — so the opening goes to Black, which is the opposite of what
      // the left-to-right face order alone would say.
      final h = Harness(buddySide: Player.black, seat: BuddySeat.near);
      h.vision.willReadDice([diceAcrossTheBoard(near: 2, far: 5)]);

      h.start();
      await h.stableFrame();

      expect(h.opening.whiteDie, 2, reason: 'the near die is the user\'s');
      expect(h.opening.blackDie, 5);
      expect(h.opening.firstPlayer, Player.black);
      expect(h.policy.diceReads.single.$1, Player.black,
          reason: 'the spoken line and the game record agree by construction');
    });

    test('and the other seat reads the same throw the other way round',
        () async {
      final h = Harness(buddySide: Player.black, seat: BuddySeat.far);
      h.vision.willReadDice([diceAcrossTheBoard(near: 2, far: 5)]);

      h.start();
      await h.stableFrame();

      expect(h.opening.whiteDie, 5,
          reason: 'the user sits across the board now, so the FAR die is '
              'theirs — and they play White');
      expect(h.opening.firstPlayer, Player.white);
    });

    test('two dice on one half is not a seat question, and falls back',
        () async {
      // Level in y: the picture cannot say who threw which, so the convention
      // this file had before seats stands, rather than a coin flip dressed up
      // as a measurement.
      final h = Harness(buddySide: Player.black, seat: BuddySeat.far);
      h.vision.willReadDice([diceShowing(6, 3)]);

      h.start();
      await h.stableFrame();

      expect(h.opening.whiteDie, 6);
      expect(h.opening.firstPlayer, Player.white);
    });

    test('nor is a throw that came to rest on the seam', () async {
      // Opposite sides of the midline — by a hair. Two dice a fiftieth of the
      // board apart in a band that is only 0.16 deep are two dice that landed
      // together, and which of them crossed the line is a rounding rather than
      // a reading. The user sits near and plays White, so an attribution here
      // would hand the opening to Black.
      final h = Harness(buddySide: Player.black, seat: BuddySeat.near);
      h.vision.willReadDice([
        diceEitherSideOfTheMidline(
            near: 2, far: 5, clearance: kOpeningSeatMargin / 2),
      ]);

      h.start();
      await h.stableFrame();

      expect(h.opening.whiteDie, 5,
          reason: 'the pre-seat convention: White\'s die is the left one');
      expect(h.opening.firstPlayer, Player.white);
    });

    test('a throw clear of the seam by the margin IS a seat question',
        () async {
      // The other side of the same number, so the margin cannot quietly grow
      // into a refusal of ordinary throws.
      final h = Harness(buddySide: Player.black, seat: BuddySeat.near);
      h.vision.willReadDice([
        diceEitherSideOfTheMidline(
            near: 2, far: 5, clearance: kOpeningSeatMargin * 1.01),
      ]);

      h.start();
      await h.stableFrame();

      expect(h.opening.whiteDie, 2,
          reason: 'the near die is the user\'s, and the user plays White');
      expect(h.opening.firstPlayer, Player.black);
    });

    test('a typed opening roll has no felt to read, and falls back too',
        () async {
      final h = Harness(buddySide: Player.black, seat: BuddySeat.far);
      h.vision.willReadDice([null, null]);

      h.start();
      await h.pumpUntil(() => h.session.needsManualDice);
      h.session.enterDiceManually(Dice(6, 3));
      await h.settle();

      expect(h.opening.whiteDie, 6,
          reason: 'the pad reports two faces and nothing about where they lay');
      expect(h.opening.firstPlayer, Player.white);
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

      // ONE line names the roll, and the one after it is the play. Buddy's
      // dictation used to restate the dice — "I rolled 6-3." followed a beat
      // later by "I rolled 6-3 — play 13/8" — which is one throw said twice in
      // the channel that IS the user's record of the match.
      final buddyLines =
          h.speaker.lines.skipWhile((l) => l.text != 'I rolled 6-3.').toList();
      expect(buddyLines.where((l) => l.text.contains('6-3')), hasLength(1));
      expect(buddyLines[0].speech, 'I rolled 6 3.',
          reason: 'the roll renders for both channels: the hyphen is the score '
              "sheet's and a TTS engine reads it as a subtraction");
      expect(buddyLines[1].text, startsWith('Play '));
      expect(buddyLines[1].speech, startsWith('Play '));
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

  group('the belief mirror', () {
    test('is raised only once a wrong placement is a repetition', () async {
      expect(kPlacementAttemptsBeforeMirror, 3,
          reason: 'this test spells the escalation out frame by frame, so if '
              'the constant moves the frames below must move with it');

      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardDisagrees]);

      h.start();
      await h.stableFrame(); // the opening roll
      await h.stableFrame(); // the user's play, folded
      await h.stableFrame(); // buddy's dice, and the move it dictates
      expect(h.session.phase, BuddyPhase.verifyingPlacement);

      await h.stableFrame(); // the man goes to the wrong point
      expect(h.session.needsBeliefMirror, isFalse,
          reason: 'one failed check is a hand that has not finished');
      await h.stableFrame(); // and again
      expect(h.session.needsBeliefMirror, isFalse,
          reason: 'two is still not a repetition — the spec escalates on one');
      expect(h.session.phase, BuddyPhase.verifyingPlacement,
          reason: 'and all the while the corrective loop keeps asking');

      final verifiesBefore = h.vision.verifyCalls;
      await h.stableFrame(); // the third
      expect(h.session.needsBeliefMirror, isTrue,
          reason: "the spec's \"repetition escalates to the on-screen belief "
              'mirror with the discrepancy highlighted"');
      expect(h.vision.verifyCalls, greaterThan(verifiesBefore),
          reason: 'the mirror is an escalation, not a surrender: the query is '
              'still running and the board can still put itself right');
      expect(h.policy.placements.where((p) => !p.$1), hasLength(1),
          reason: 'and the correction is SAID once, not once per frame — the '
              'screen is what repeats, not the voice');
      expect(h.controller.game.events.whereType<MoveEvent>(), hasLength(2),
          reason: 'nothing about the authoritative state moved through any of '
              'it: the dictated play was applied once, at the start');

      h.vision.willVerify([boardAgrees]);
      await h.stableFrame();
      expect(h.session.needsBeliefMirror, isFalse,
          reason: 'the board caught up, so the mirror comes down with it');
      expect(h.session.phase, BuddyPhase.awaitingDice);
    });
  });

  // The transcript is the user's whole record of the match — it is the channel
  // that survives a loud room, a muted phone and a platform with no voice — so
  // what it repeats matters as much as what it says.
  group('one roll, one line', () {
    /// A real legal play, so no test here has to hand-build a [Move].
    Move play(Dice dice) =>
        MoveGenerator.legalMoves(BoardState.initial(), Player.black, dice)
            .first;

    ({BuddySpeaker speaker, OpponentPolicy policy}) buddy(
        [BuddyPhrasing phrasing = BuddyPhrasing.terse]) {
      final speaker = BuddySpeaker(phrasing: phrasing);
      addTearDown(speaker.dispose);
      return (
        speaker: speaker,
        policy: OpponentPolicy(speaker: speaker, buddySide: Player.black),
      );
    }

    test('a dictation leaves the roll to the line that already said it', () {
      final b = buddy();
      b.policy.onDiceRead(Player.black, Dice(6, 3), 0.9);
      b.policy.onBuddyMoveChosen(Dice(6, 3), play(Dice(6, 3)));

      final said = b.speaker.lines;
      expect(said.map((l) => l.text).where((t) => t.contains('6-3')),
          hasLength(1),
          reason: 'one throw, one mention — the pair used to read "I rolled '
              '6-3." and then "I rolled 6-3 — play 13/8" a beat later');
      expect(said.first.text, 'I rolled 6-3.');
      expect(said.last.text, startsWith('Play '));
      expect(said.last.speech, startsWith('Play '));
    });

    test('and states it when nothing has', () {
      // Not a path the session takes — it announces every roll as it is read —
      // but the dice are an argument of the method, and a caller that dictates
      // a play without a throw in front of it deserves a line that says which
      // throw it belongs to.
      final b = buddy();
      b.policy.onBuddyMoveChosen(Dice(6, 3), play(Dice(6, 3)));

      expect(b.speaker.lines.single.text, startsWith('I rolled 6-3 — play '));
      expect(b.speaker.lines.single.speech, startsWith('I rolled 6 3. Play '));
    });

    test("the user's own roll is not Buddy's, and does not spend the latch",
        () {
      final b = buddy();
      b.policy.onDiceRead(Player.white, Dice(6, 3), 0.9);
      b.policy.onBuddyMoveChosen(Dice(6, 3), play(Dice(6, 3)));

      expect(b.speaker.lines.first.text, 'You rolled 6-3.');
      expect(b.speaker.lines.last.text, startsWith('I rolled 6-3 — play '),
          reason: 'the roll the user threw is a different sentence about a '
              'different throw');
    });

    test('a dance says the roll once too', () {
      final b = buddy();
      b.policy.onDiceRead(Player.black, Dice(6, 3), 0.9);
      b.policy.onBuddyMoveChosen(Dice(6, 3), Move.none);

      expect(b.speaker.lines.last.text, 'No play, so it is back to you.');
    });

    test('the friendly phrasing dictates its own sentence, not a verb and one',
        () {
      // `describePlay` hands back a finished imperative in this phrasing, so a
      // verb in front of it reads "play Move one checker from 13 to 8".
      final b = buddy(BuddyPhrasing.friendly);
      b.policy.onDiceRead(Player.black, Dice(6, 3), 0.9);
      b.policy.onBuddyMoveChosen(Dice(6, 3), play(Dice(6, 3)));

      final dictated = b.speaker.lines.last.text;
      expect(dictated, startsWith('Move '));
      expect(dictated, isNot(contains('play Move')));
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
      expect(h.policy.cubeActions, hasLength(2),
          reason: 'one offer and one answer: a cube verb that happened is '
              'announced exactly once');
      expect(h.speech.where((l) => l == 'You drop.'), hasLength(1));
      expect(h.controller.state.phase, GamePhase.gameOver);
      expect(h.policy.gameEnds.single.winner, Player.black);
      expect(h.controller.match.blackScore, 1);
    });

    test('the user doubles, buddy takes, and the cube changes hands', () async {
      final h = Harness(matchLength: 3);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.pumpUntil(() => h.preRollFor(Player.white));

      h.session.offerDouble();
      await h.settle();

      expect(h.controller.state.cube.value, 2);
      expect(h.controller.state.cube.owner, h.buddySide,
          reason: 'the taker owns the cube afterwards');
      expect(h.policy.cubeActions, <(Player, BuddyCubeAction)>[
        (Player.white, BuddyCubeAction.offered),
        (Player.black, BuddyCubeAction.taken),
      ]);
      expect(h.speech, containsAllInOrder(<String>['You double.', 'I take.']));
    });

    // The two below are about a verb that did NOT happen. In this mode the
    // transcript is the user's record of the match and the physical cube is
    // their ritual, so a spoken line instructs a real-world action: "You
    // double." over a cube the game left where it was tells the user to turn
    // a doubling cube the game will disagree with for the rest of the match.
    // Announce after the controller has taken the verb, never before.
    test('a refused double says nothing and moves no cube', () async {
      final h = Harness(matchLength: 3);
      h.vision.willReadDice([diceShowing(6, 3)]);

      h.start();
      await h.stableFrame(); // the opening: white is mid-turn, not pre-roll
      expect(h.session.phase, BuddyPhase.awaitingPlay);
      final linesBefore = h.speech.length;

      expect(h.session.offerDouble, throwsStateError,
          reason: 'the controller stays the authority on when the cube moves');
      expect(h.policy.cubeActions, isEmpty);
      expect(h.speech, hasLength(linesBefore));
      expect(h.controller.state.cube.value, 1);
      expect(h.controller.state.phase, GamePhase.moving);
    });

    test('a refused answer says nothing and answers nothing', () async {
      final h = Harness(matchLength: 3);
      h.vision.willReadDice([diceShowing(6, 3)]);

      h.start();
      await h.stableFrame();
      final linesBefore = h.speech.length;

      expect(() => h.session.answerDouble(CubeAction.drop), throwsStateError,
          reason: 'nothing was offered, so there is nothing to answer');
      expect(h.policy.cubeActions, isEmpty);
      expect(h.speech, hasLength(linesBefore));
      expect(h.controller.state.phase, GamePhase.moving,
          reason: 'and the game is exactly where it was');
    });
  });

  group('the doubling predicate', () {
    // `BuddySession` holds the fifth copy of the controller's private
    // `_doublingLegal` — the house pattern, and the controller stays the
    // authority. But a drifted copy here fails SILENT: Buddy would simply stop
    // doubling, with nothing thrown and nothing logged. So the copy is pinned
    // against the authority on the states that separate them — whether Buddy
    // consulted the engine, versus whether the controller takes the verb, on
    // one and the same state.

    test('agrees with the controller on a centred cube', () async {
      final h = Harness(matchLength: 3);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.pumpUntil(() => h.preRollFor(h.buddySide));

      expect(h.engine.cubeConsiderations, 1,
          reason: "Buddy's copy says the cube is live, so the engine was asked");
      expect(controllerTakesDouble(h.controller), isTrue,
          reason: 'and the authority agrees');
    });

    test('agrees with the controller in the Crawford game', () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.pumpUntil(() => h.preRollFor(h.buddySide));

      expect(h.controller.state.isCrawfordGame, isTrue,
          reason: 'a 1-point match plays its only game as the Crawford game');
      expect(h.engine.cubeConsiderations, 0);
      expect(controllerTakesDouble(h.controller), isFalse);
    });

    test('agrees with the controller once buddy owns the cube', () async {
      final h = Harness(matchLength: 5);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.pumpUntil(() => h.preRollFor(Player.white));
      final consultedBefore = h.engine.cubeConsiderations;
      h.session.offerDouble();
      await h.settle();
      expect(h.controller.state.cube.owner, h.buddySide,
          reason: 'buddy took, so the redouble is now buddy\'s to make');

      await h.pumpUntil(() => h.preRollFor(h.buddySide));

      expect(h.engine.cubeConsiderations, greaterThan(consultedBefore),
          reason: 'an owned cube is live for its owner — the half of the '
              'owner clause a drifted copy would drop SILENTLY, since Buddy '
              'that has simply stopped redoubling throws nothing');
      expect(controllerTakesDouble(h.controller), isTrue);
    });

    test('agrees with the controller once the user owns the cube', () async {
      final h = Harness(matchLength: 3, buddyDoubles: true);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.pumpUntil(() => h.session.phase == BuddyPhase.awaitingCubeAnswer);
      h.session.answerDouble(CubeAction.take);
      await h.settle();
      expect(h.controller.state.cube.owner, h.session.userSide,
          reason: 'the taker owns the cube, so it is the user\'s now');
      final consultedBefore = h.engine.cubeConsiderations;

      await h.pumpUntil(() => h.preRollFor(h.buddySide));

      expect(h.engine.cubeConsiderations, consultedBefore,
          reason: 'the cube is not Buddy\'s to turn, so it is not asked about');
      expect(controllerTakesDouble(h.controller), isFalse);
    });

    test('agrees with the controller in a cubeless match', () async {
      final h = Harness(matchLength: 3, cubeless: true);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      await h.pumpUntil(() => h.preRollFor(h.buddySide));

      expect(h.engine.cubeConsiderations, 0,
          reason: 'the one clause of the copy that reads a session field '
              'rather than the game state');
      expect(controllerTakesDouble(h.controller), isFalse);
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

    // A roll request outlives a calibration outage: nothing cancels it, and
    // `_requestRoll` re-reads where the game has got to AFTER the await, so
    // whatever answers it lands on the right side of the right game. Both
    // halves are pinned here because the behaviour is load-bearing and was
    // never obviously deliberate — `BuddyDiceRoller.cancel` is disposal only.
    test('a roll asked for before an outage is answered after it, once',
        () async {
      final h = Harness();
      h.vision.willReadDice([diceShowing(6, 3)]);

      h.start(); // the opening throw is asked for, and nothing has answered
      h.vision.willSee([staleCalibrationReading]);
      await h.stableFrame();
      expect(h.session.phase, BuddyPhase.calibrating);
      expect(h.session.controller, isNull);

      final fresh = FakeVision()..willReadDice([diceShowing(5, 2)]);
      h.session.useCalibration(fresh);
      await h.settle();
      expect(h.session.phase, BuddyPhase.awaitingDice);

      await h.stableFrame();
      expect(h.controller.state.dice, Dice(5, 2));
      expect(h.policy.diceReads, hasLength(1),
          reason: 'one throw was asked for and one was answered: the outage '
              'neither abandoned the open request nor opened a second');
    });

    test('the pad still answers while the light is out', () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willSee([staleCalibrationReading]);

      h.start();
      await h.stableFrame();
      expect(h.session.phase, BuddyPhase.calibrating);

      h.session.enterDiceManually(Dice(5, 2));
      await h.settle();

      expect(h.controller.state.dice, Dice(5, 2),
          reason: 'the pad answers the USER, not the camera: an outage '
              'suspends what perception may claim, never what the user may do');
      expect(h.session.phase, BuddyPhase.calibrating);
      expect(h.session.needsRecalibration, isTrue,
          reason: 'and the session is still waiting for a calibration');
    });
  });

  group('the play fallback', () {
    test('a typed play folds as the user\'s own', () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesNothing])
        ..willVerify([boardAgrees]);

      h.start();
      await h.stableFrame(); // the opening roll
      expect(h.session.phase, BuddyPhase.awaitingPlay);
      final chosen = h.controller.state.legalMoves[3];

      await h.stableFrame(); // the picture cannot say what the hand did
      expect(h.controller.game.events.whereType<MoveEvent>(), isEmpty);

      h.session.enterPlayManually(chosen);
      await h.settle();

      final played = h.controller.game.events.whereType<MoveEvent>();
      expect(played, hasLength(1),
          reason: 'exactly one play, and no second one folded behind it');
      expect(played.single.move.sameAs(chosen), isTrue,
          reason: "the spec's tap-to-enter fallback: a play perception could "
              "not identify is still the user's play");
      expect(h.policy.observedPlays.single.$2.sameAs(chosen), isTrue,
          reason: 'and it is acknowledged exactly as a seen one is');
      expect(h.session.phase, BuddyPhase.awaitingDice,
          reason: 'the turn moves on, so the next roll may be asked for');
    });

    test('refuses a play when none is being waited for', () async {
      final h = Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);

      h.start();
      expect(() => h.session.enterPlayManually(Move.none), throwsStateError,
          reason: 'there is not even a game yet');

      await h.stableFrame(); // the opening roll
      await h.stableFrame(); // the play, folded by the camera
      expect(h.session.phase, BuddyPhase.awaitingDice);

      expect(() => h.session.enterPlayManually(Move.none), throwsStateError,
          reason: 'and a turn that is over cannot be played again');
      expect(h.controller.game.events.whereType<MoveEvent>(), hasLength(1));
    });
  });
}

/// Whether the controller — the authority — takes a double right now.
///
/// Attempting the verb is the only honest way to ask, since
/// `GameController._doublingLegal` is private, which is exactly why
/// `BuddySession` carries a copy of it. **Succeeding moves the cube**, so this
/// belongs at the end of whatever it is asked about.
bool controllerTakesDouble(GameController c) {
  try {
    c.offerDouble();
    return true;
  } on StateError {
    return false;
  }
}

/// One session, its fakes, and a frame pump.
class Harness {
  Harness({
    this.matchLength = 1,
    this.buddySide = Player.black,
    this.buddyDoubles = false,
    this.cubeless = false,
    this.seat = BuddySeat.near,
    MatchPersistence persistence = const NoopPersistence(),
  }) {
    speaker = BuddySpeaker();
    policy = RecordingPolicy(
        OpponentPolicy(speaker: speaker, buddySide: buddySide));
    engine = ScriptedEngine(doubles: buddyDoubles);
    session = BuddySession(
      engine: engine,
      buddySide: buddySide,
      seat: seat,
      policy: policy,
      frames: frames.stream,
      matchLength: matchLength,
      cubeless: cubeless,
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
  final bool cubeless;
  final BuddySeat seat;
  final FakeVision vision = FakeVision();
  final StreamController<ObservedFrame> frames =
      StreamController<ObservedFrame>.broadcast();
  late final BuddySpeaker speaker;
  late final RecordingPolicy policy;
  late final ScriptedEngine engine;
  late final BuddySession session;

  GameController get controller => session.controller!;

  /// The throw that started the match, as the authoritative record holds it:
  /// White's die and Black's, in that order. What the seat decides.
  OpeningRollEvent get opening =>
      controller.game.events.first as OpeningRollEvent;
  List<String> get speech => speaker.lines.map((l) => l.text).toList();

  void start() => session.useCalibration(vision);

  /// Whether the controller is parked on [side]'s pre-roll gate — the one
  /// moment in a turn at which the cube is a legal verb, and therefore the
  /// only state on which Buddy's doubling predicate and the controller's own
  /// can be compared.
  ///
  /// The session's own phase is part of the question, and deliberately: the
  /// controller races ahead of the board, so `awaitingHumanTurn` alone is also
  /// true while a dictated move is still being placed.
  bool preRollFor(Player side) =>
      session.controller != null &&
      session.phase == BuddyPhase.awaitingDice &&
      controller.awaitingHumanTurn &&
      controller.state.turn == side &&
      controller.state.phase == GamePhase.awaitingRoll;

  /// Pushes settled frames until [ready] holds.
  ///
  /// The session answers whatever the current phase is asking on every frame,
  /// so "play on until the game reaches X" is a pump rather than a script —
  /// the same property the whole-game test leans on, named so that a test
  /// about one moment need not count the frames that lead to it.
  Future<void> pumpUntil(bool Function() ready, {int limit = 60}) async {
    for (var i = 0; i < limit && !ready(); i++) {
      await stableFrame();
    }
    if (!ready()) {
      fail('the session never reached the state this test is about');
    }
  }

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

  /// How many times Buddy has been asked whether to double.
  ///
  /// The session only asks when its own `_doublingLegal` says the cube is a
  /// legal verb, so this counter IS that private predicate, observed from
  /// outside — see the "the doubling predicate" group.
  int cubeConsiderations = 0;

  @override
  bool get wantsDoublePrompts => true;

  @override
  Future<Move> chooseMove(GameState state) async =>
      state.legalMoves.isEmpty ? Move.none : state.legalMoves.first;

  @override
  Future<bool> considerDouble(GameState state, MatchContext ctx) async {
    cubeConsiderations++;
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
