import 'package:aigammon_app/buddy/buddy_session.dart';
import 'package:aigammon_app/buddy/speaker.dart';
import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/screens/buddy/buddy_game_screen.dart';
import 'package:aigammon_app/screens/buddy/buddy_setup_screen.dart';
import 'package:aigammon_app/screens/buddy/calibration_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../buddy/fake_calibration_seams.dart';
import '../../buddy/fake_vision.dart';
import '../../data/test_database.dart';
import '../../helpers/board_driving.dart';

/// A no-native [EngineFacade] that ranks the real legal moves with flat
/// equities — enough for [AiAgent] to play something valid, and, at
/// [Difficulty.expert], to play the FIRST of them every time.
///
/// The determinism is what makes a scripted match through this screen a test
/// rather than a lottery: `pickMove` returns `ranked.first` for expert, so
/// Buddy plays exactly what `matchesPlay(0)` says the user played, and a dice
/// script fixes the whole game.
class _FlatFacade implements EngineFacade {
  const _FlatFacade();

  static const Probabilities _even = Probabilities(
    win: 0.5,
    winGammon: 0,
    winBackgammon: 0,
    loseGammon: 0,
    loseBackgammon: 0,
  );

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async => _even;

  @override
  Future<List<ScoredMove>> rankMoves(
          BoardState board, Player mover, Dice dice) async =>
      [
        for (final move in MoveGenerator.legalMoves(board, mover, dice))
          ScoredMove(move: move, probabilities: _even),
      ];

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      const CubeAdvice(
        shouldDouble: false,
        shouldAccept: true,
        equityCubeless: 0,
        equityNoDouble: 0,
        equityDoubleTake: 0,
      );
}

void main() {
  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  group('a match played through the screen', () {
    testWidgets('the opening throw, the play, and the move Buddy dictates',
        (t) async {
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.pump(t);

      // Nothing has been thrown yet, so the screen asks for the one throw that
      // starts a match: one die each.
      expect(_prompt(t), contains('opening'));
      expect(find.byKey(const Key('buddy-camera-preview')), findsOneWidget);

      await h.frame(t); // the opening roll, read off the felt
      expect(_transcript(t), contains('You rolled 6-3.'));
      expect(boardPainterOf(t).whiteDice, Dice(6, 3),
          reason: 'the mirror carries the roll Buddy read, so a misread one is '
              'visible as well as audible');
      expect(_prompt(t).toLowerCase(), contains('your play'));

      final before = boardPainterOf(t).board;
      await h.frame(t); // the user's play, matched uniquely
      expect(boardPainterOf(t).board, isNot(before),
          reason: 'the belief mirror follows the authoritative state');
      expect(_transcript(t), contains('24/21, 24/18'),
          reason: "the user's own play is acknowledged in the score sheet's "
              'own notation');

      await h.frame(t); // Buddy's dice, and the move it dictates
      expect(_prompt(t).toLowerCase(), contains("buddy's move"),
          reason: 'a dictated move is not a made one — the board has to catch '
              'up before the next roll is asked for');
    });

    testWidgets('says the roll ONCE a turn, not twice', (t) async {
      // The stutter: `onDiceRead` announced "I rolled 6-6." and
      // `onBuddyMoveChosen` followed it immediately with "I rolled 6-6 — play
      // …". Two lines about one throw, a second apart, in the channel that is
      // the user's whole record of the match.
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(5, 1), diceShowing(6, 6)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.pump(t);

      await h.frame(t); // the opening
      await h.frame(t); // the user's play
      await h.frame(t); // Buddy's roll and its dictated move

      final said = _lines(t);
      expect(said.where((l) => l.contains('6-6')), hasLength(1),
          reason: 'exactly one line names the roll Buddy just made');
      expect(said, contains('I rolled 6-6.'));
      expect(said.singleWhere((l) => l.startsWith('Play ')), isNotEmpty,
          reason: 'and the dictation is the play, since the roll is already '
              'on the screen above it');
    });

    testWidgets('a dance is announced and passed with no board to show',
        (t) async {
      // Task 11 implemented the auto-pass and could not test it: the session
      // builds its controller from the standard starting position and cannot be
      // handed one with men on the bar. It does not need to be — the dice are
      // scripted and both sides play their first legal move, so the whole game
      // is deterministic, and 5-1 then 6-6 puts the user on the bar against a
      // home board they cannot enter.
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(5, 1), diceShowing(6, 6)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.pump(t);

      for (var i = 0; i < 6; i++) {
        await h.frame(t);
        if (_lines(t).contains('No play — your turn passes.')) break;
      }

      expect(_lines(t), contains('No play — your turn passes.'),
          reason: 'the digital game auto-passes a dance, and so does this — '
              'there is nothing for a hand to do and nothing for a camera to '
              'see');
      expect(_lines(t).where((l) => l == 'No play — your turn passes.'),
          hasLength(1),
          reason: 'said once, not once per frame');
    });
  });

  group('the readability light', () {
    testWidgets('names its cause, and perception goes quiet behind it',
        (t) async {
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);
      await h.pump(t);
      await h.frame(t);
      expect(_readability(t), 'I can see the board.');

      h.vision.willSee([tooDarkReading]);
      final playsBefore = h.vision.playCalls;
      await h.frame(t);
      await h.frame(t);

      expect(_readability(t), 'It is too dark to read the board.',
          reason: "Readability.message is written to be shown as it stands, so "
              'the light names the cause rather than merely going red');
      expect(h.vision.playCalls, playsBefore,
          reason: "every PERCEPTION answer is suppressed while the light is "
              'not green');
      expect(_prompt(t).toLowerCase(), contains('tap it out'),
          reason: 'the suppression is the camera\'s, not the user\'s: the '
              'question the user was already being asked is still the question '
              'on the screen, and its answer is still a tap away');
    });

    testWidgets('and with nothing open for the user, the prompt says the match '
        'is waiting rather than stuck', (t) async {
      // The other half of the line above. When the only thing outstanding IS
      // something the camera has to answer — here a dictated move whose
      // placement is being checked — there is no user question to show, and
      // the outage sentence is what belongs in the slot.
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // the user's play, folded
      await h.frame(t); // Buddy's roll, and the move it dictates
      expect(_prompt(t).toLowerCase(), contains("buddy's move"));

      h.vision.willSee([tooDarkReading]);
      await h.frame(t);

      expect(_prompt(t), 'Waiting for a picture Buddy can read. Nothing is '
          'lost.');
    });

    testWidgets('a stale calibration routes to the corner flow with the '
        'corners already on them', (t) async {
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);
      await h.pump(t);
      await h.frame(t); // the opening roll: the user's play is now awaited
      final board = boardPainterOf(t).board;

      h.vision.willSee([staleCalibrationReading]);
      await h.frame(t);
      expect(_readability(t), 'The board is not where it was when I learned it.');

      await t.tap(find.text('Fix the aim'));
      await t.pumpAndSettle();
      final request =
          t.widget<CalibrationScreen>(find.byType(CalibrationScreen)).request;
      expect(request.seededHandles, same(h.handles),
          reason: 'a phone that got nudged is a nudge to fix, not a setup to '
              'repeat');

      h.vision.willSee([greenReading]);
      await h.recalibrate(t);

      expect(find.byType(CalibrationScreen), findsNothing);
      expect(boardPainterOf(t).board, same(board),
          reason: 'an outage never touched the authoritative state');
      expect(_prompt(t).toLowerCase(), contains('your play'),
          reason: 'play resumes exactly where it paused');

      await h.frame(t); // re-anchors on the new epoch
      await h.frame(t); // and the same turn finishes on the new calibration
      expect(boardPainterOf(t).board, isNot(board));
    });
  });

  group('the fallbacks', () {
    testWidgets('the dice pad answers a roll the camera could not read',
        (t) async {
      final h = _Harness();
      h.vision.willReadDice([null]);
      await h.pump(t);

      await h.frame(t);
      await h.frame(t);
      expect(_prompt(t).toLowerCase(), contains('type the roll'));

      await t.tap(find.byKey(const Key('buddy-dice-button')));
      await t.pumpAndSettle();
      // The opening is the one throw whose two faces belong to two different
      // people, and a pad that said "in any order" would be inviting the user
      // to decide who starts by accident.
      expect(find.text("White's die"), findsOneWidget);
      expect(find.text("Black's die"), findsOneWidget);
      await h.pickRoll(t, 5, 2);

      expect(_transcript(t), contains('You rolled 5-2.'));
      expect(boardPainterOf(t).whiteDice, Dice(5, 2));
    });

    testWidgets('and it answers one while the light is RED', (t) async {
      // A deliberate decision, not an inherited one. The pad answers the USER,
      // not the camera: an outage suspends what perception may claim, never
      // what a person at the board may do. The worst case Buddy Mode degrades
      // to is a slightly assisted hot seat, and it only degrades that far if
      // the manual route stays open while the camera is out.
      final h = _Harness();
      h.vision.willSee([staleCalibrationReading]);
      await h.pump(t);
      await h.frame(t);

      expect(_readability(t), 'The board is not where it was when I learned it.',
          reason: 'the banner stays up, so the user knows why Buddy is quiet');
      await h.enterRoll(t, 5, 2);

      expect(_transcript(t), contains('You rolled 5-2.'),
          reason: 'the roll the user typed started the match, red light or no');
      expect(find.text('Fix the aim'), findsWidgets,
          reason: 'and the way back to a working camera is still one tap away');
    });

    testWidgets('and on every other throw the two faces are just two faces',
        (t) async {
      // The other half of the labelling. Only the OPENING throw has two dice
      // belonging to two different people; on every roll after it both faces
      // are the same player's and their order is nothing at all, so a pad
      // still naming colours would be inviting the user to answer a question
      // nobody asked.
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.pump(t);
      for (var i = 0; i < 4; i++) {
        await h.frame(t); // opening, play, Buddy's move, placement verified
      }
      expect(_prompt(t).toLowerCase(), contains('throw your dice'));

      await t.tap(find.byKey(const Key('buddy-dice-button')));
      await t.pumpAndSettle();
      expect(find.text('One die'), findsOneWidget);
      expect(find.text('The other'), findsOneWidget);
      expect(find.text("White's die"), findsNothing);
      expect(find.textContaining('either order'), findsOneWidget,
          reason: 'and the caption says so, rather than leaving the user to '
              'infer it from two labels that stopped mentioning colours');

      await h.pickRoll(t, 5, 2);
      expect(_transcript(t), contains('You rolled 5-2.'));
    });

    testWidgets('an ambiguous play is resolved by picking a candidate',
        (t) async {
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesAmbiguously(0, 1)]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // two legal plays leave the same position

      expect(_prompt(t).toLowerCase(), contains('which play'));
      final buttons = find.descendant(
        of: find.byKey(const Key('buddy-candidates')),
        matching: find.byType(OutlinedButton),
      );
      expect(buttons, findsNWidgets(2),
          reason: 'the picture cannot separate them, so the user does');

      final board = boardPainterOf(t).board;
      await t.tap(buttons.last);
      await t.pumpAndSettle();
      expect(boardPainterOf(t).board, isNot(board));
      expect(find.byKey(const Key('buddy-candidates')), findsNothing);
    });

    testWidgets('a play perception could not identify is tapped out on the '
        'mirror', (t) async {
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesNothing])
        ..willVerify([boardAgrees]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // the picture cannot say what the hand did

      final board = boardPainterOf(t).board;
      await commitFirstMove(t);
      await h.settle(t);

      expect(boardPainterOf(t).board, isNot(board),
          reason: "the spec's tap-to-enter fallback: a play perception could "
              "not identify is still the user's play, and it folds through the "
              'session rather than mutating a board');
      expect(_transcript(t), isNotEmpty);
    });
  });

  group('an outage suppresses perception, never the user', () {
    // The decision the dice pad already ships — see [BuddySession.awaitingRoll]
    // — applied to every other user verb. A readability outage suspends what
    // perception may CLAIM about the board and nothing whatever about what a
    // person sitting at it may DO, so each probe here drops ONE non-green frame
    // into the middle of a question the user was already being asked and checks
    // that the answer is still there to give.

    testWidgets('Take and Drop answer a double through a dark frame',
        (t) async {
      final h = _Harness(matchLength: 3, buddyDoubles: true);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // the user's play, folded — and Buddy's cube question
      expect(_prompt(t).toLowerCase(), contains('take or drop'));

      h.vision.willSee([tooDarkReading]);
      await h.frame(t);

      expect(_readability(t), 'It is too dark to read the board.',
          reason: 'the light is out, so the session has stopped asking');
      expect(find.widgetWithText(OutlinedButton, 'Drop'), findsOneWidget,
          reason: 'the cube is on the table and the user has not answered — a '
              'camera that cannot see is not a reason to take the answer away');
      expect(find.widgetWithText(FilledButton, 'Take'), findsOneWidget);
      expect(_prompt(t).toLowerCase(), contains('take or drop'),
          reason: 'and the sentence over two live buttons is the question they '
              'answer, not "waiting for a picture"');

      await t.tap(find.widgetWithText(FilledButton, 'Take'));
      await h.settle(t);
      expect(_lines(t), contains('You take.'),
          reason: 'the answer is not merely rendered, it lands');
    });

    testWidgets('the candidate picker survives a dark frame', (t) async {
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesAmbiguously(0, 1)]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // two legal plays leave the same position

      final buttons = find.descendant(
        of: find.byKey(const Key('buddy-candidates')),
        matching: find.byType(OutlinedButton),
      );
      expect(buttons, findsNWidgets(2));

      h.vision.willSee([tooDarkReading]);
      await h.frame(t);

      expect(buttons, findsNWidgets(2),
          reason: 'the two plays perception could not separate are still the '
              'two the user can separate');
      expect(_prompt(t).toLowerCase(), contains('which play'));

      final board = boardPainterOf(t).board;
      await t.tap(buttons.last);
      await t.pumpAndSettle();
      expect(boardPainterOf(t).board, isNot(board),
          reason: 'and picking one still folds it');
    });

    testWidgets('Double stays live, because doubling is the user speaking',
        (t) async {
      // A 3-point match, so the cube is live rather than dead for Crawford —
      // the state the gated-button test deliberately does NOT use.
      final h = _Harness(matchLength: 3);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.pump(t);
      for (var i = 0; i < 4; i++) {
        await h.frame(t); // opening, play, Buddy's move, placement verified
      }

      final button = find.widgetWithText(OutlinedButton, 'Double');
      expect(_prompt(t).toLowerCase(), contains('throw your dice'),
          reason: 'the pre-roll gate: the one moment the cube is a verb');
      expect(isButtonEnabled(t, button), isTrue);

      h.vision.willSee([tooDarkReading]);
      await h.frame(t);

      expect(isButtonEnabled(t, button), isTrue,
          reason: 'the cube in the middle of the table is the user\'s to turn '
              'whatever the camera can see');

      await t.tap(button);
      await h.settle(t);
      expect(_lines(t), contains('You double.'));
    });

    testWidgets('a half-tapped correction survives a dark frame', (t) async {
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesNothing]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // the picture cannot say what the hand did

      // ONE hop of a two-hop play: staged on the mirror, not committed.
      await tapBoardPoint(t, boardPainterOf(t).highlightedSources.first);
      await tapBoardPoint(t, boardPainterOf(t).highlightedDestinations.first);
      final undo = find.widgetWithText(OutlinedButton, 'Undo');
      expect(isButtonEnabled(t, undo), isTrue,
          reason: 'one hop is staged, so there is something to undo');

      h.vision.willSee([tooDarkReading]);
      await h.frame(t);

      expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget,
          reason: 'the entry is still open — the bar has not swapped back to '
              'Dice and Double');
      expect(isButtonEnabled(t, undo), isTrue,
          reason: '"Nothing is lost." is a promise about the half-finished '
              'play the user has already tapped out, and a 350ms nudge is '
              'exactly when it gets tested');
    });
  });

  group('what the screen writes down', () {
    testWidgets('a Buddy match is in History from the moment it starts',
        (t) async {
      // The screen's own three lines, and the reason they are the screen's:
      // without them the one mode played on a real board would be the one mode
      // that left no record. The session's persistence hook is tested against
      // a repository elsewhere; what is untested without this is whether the
      // SCREEN opens a row at all, and with what in it.
      final h = _Harness(matchLength: 3);
      await h.pump(t);

      // Through `runAsync`, because the row is written by real sqlite I/O and
      // a `testWidgets` clock does not let real I/O complete on its own. The
      // rest of this file never notices — nothing else in it asks the database
      // a question.
      final rows = (await t.runAsync(
        () => MatchRepository(h.db).watchMatches().first,
      ))!;
      expect(rows, hasLength(1));
      expect(rows.single.mode, 'buddy',
          reason: 'History tells the modes apart by this, and a Buddy match '
              'that filed itself as a digital one is a lie about how it was '
              'played');
      expect(rows.single.matchLength, 3);
      expect(rows.single.blackType, 'ai:expert',
          reason: 'Buddy plays Black in this harness, at the difficulty setup '
              'chose');
      expect(rows.single.whiteType, 'human');
    });
  });

  group('the camera two screens share', () {
    testWidgets('survives the handover from calibration into the match',
        (t) async {
      // The direction the recalibration test does not cover. There, the game
      // screen pushes the corner flow and takes it back; here the corner flow
      // hands over to a game screen that opens BEFORE the popped route
      // disposes. Both are a close arriving under a screen that is still
      // looking through the camera, and before the hold was counted whichever
      // one disposed second turned it off.
      final h = _HandoverHarness();
      await h.pump(t);

      await t.ensureVisible(find.text('Calibrate the board'));
      await t.pumpAndSettle();
      await t.tap(find.text('Calibrate the board'));
      await t.pumpAndSettle();
      await h.calibrate(t);

      expect(find.byType(BuddyGameScreen), findsOneWidget,
          reason: 'the calibration handed over to a match');
      expect(h.camera.closed, isFalse,
          reason: 'the route that popped gave up ITS hold, not the camera');

      // The proof that it is alive rather than merely un-flagged: a frame
      // pushed now still reaches the session behind the new screen.
      h.camera.push(blankFrame(width: 64, height: 48));
      for (var i = 0; i < 24; i++) {
        await t.pump();
      }
      expect(h.vision.readabilityCalls, greaterThan(0),
          reason: 'frames are still arriving on the far side of the handover');
    });
  });

  group('the screen holds together at a large text size', () {
    // The digital game screen ships this regression for its header, and this
    // one needs it more: two of the six bands are SENTENCES in flexible slots,
    // and a sentence is exactly what grows when a user asks for bigger text.
    // Both were measured overflowing at TextScaler 2.0 on a 420x900 phone.

    // A test per scale rather than a loop inside one, because each harness
    // opens its own database and three live at once is a drift warning about
    // a race this test is not about.
    for (final scale in <double>[1.0, 1.3, 2.0]) {
      testWidgets('the mirror placeholder fits at text scale $scale',
          (t) async {
        final h = _Harness();
        await h.pump(t, textScale: scale);

        // Before the opening throw there is no game, so the mirror slot holds
        // the longest-lived placeholder on the screen.
        expect(find.textContaining('waiting for the throw'), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('so does a camera that will not open, at text scale $scale',
          (t) async {
        // The longer of the two: the permission refusal, plus the paragraph
        // telling the user the match is still playable by hand.
        final h = _Harness(
          camera: FakeBuddyCamera(
            opening: const CameraUnavailable(
              'AIGammon does not have permission to use the camera. Allow '
              'camera access in your device settings and try again.',
            ),
          ),
        );
        await h.pump(t, textScale: scale);

        expect(find.textContaining('dice pad'), findsOneWidget,
            reason: 'the fallback paragraph is shown, not clipped away');
        expect(t.takeException(), isNull);
      });
    }
  });

  group('the cube', () {
    testWidgets('Buddy doubles by voice, and the answer is two buttons',
        (t) async {
      final h = _Harness(matchLength: 3, buddyDoubles: true);
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // the user's play, folded — and Buddy's cube question

      expect(_transcript(t), contains('I double — take or drop?'));
      expect(_prompt(t).toLowerCase(), contains('take or drop'));
      expect(find.widgetWithText(OutlinedButton, 'Drop'), findsOneWidget,
          reason: 'both of the two words Buddy just said out loud are on the '
              'screen — a spoken question with only one of its answers under '
              'it is a question the user has to guess the rest of');

      await t.tap(find.widgetWithText(FilledButton, 'Take'));
      await h.settle(t);

      expect(_lines(t), contains('You take.'));
      expect(find.widgetWithText(FilledButton, 'Take'), findsNothing);
    });

    testWidgets('the Double button is gated like the digital game and says why',
        (t) async {
      // A 1-point match plays its only game as the Crawford game, where the
      // cube is dead — the same sentence the digital screens show, through the
      // same [TapWhenDisabled].
      final h = _Harness();
      h.vision
        ..willReadDice([diceShowing(6, 3)])
        ..willMatchPlay([matchesPlay(0)])
        ..willVerify([boardAgrees]);
      await h.pump(t);
      await h.frame(t); // the opening roll
      await h.frame(t); // the user's play, folded
      await h.frame(t); // Buddy's roll and the move it dictates
      await h.frame(t); // the placement verified: the user's pre-roll gate

      expect(_prompt(t).toLowerCase(), contains('throw your dice'),
          reason: 'the one moment in a turn at which the cube is a verb');
      final button = find.widgetWithText(OutlinedButton, 'Double');
      expect(button, findsOneWidget);
      expect(isButtonEnabled(t, button), isFalse);

      await t.tap(button);
      await t.pump();
      expect(find.textContaining('Crawford'), findsOneWidget,
          reason: 'a dead button cannot say why it is dead');
    });
  });
}

// --- reading the screen ------------------------------------------------------

String _readability(WidgetTester t) =>
    t.widget<Text>(find.byKey(const Key('buddy-readability'))).data ?? '';

String _prompt(WidgetTester t) =>
    t.widget<Text>(find.byKey(const Key('buddy-prompt'))).data ?? '';

/// Every line the on-screen transcript is showing, oldest first — which is the
/// order it renders them in, and the order a person reads them.
List<String> _lines(WidgetTester t) => t
    .widgetList<Text>(find.descendant(
      of: find.byKey(const Key('buddy-transcript')),
      matching: find.byType(Text),
    ))
    .map((w) => w.data ?? '')
    .toList();

String _transcript(WidgetTester t) => _lines(t).join(' | ');

// --- the harness -------------------------------------------------------------

class _Harness {
  _Harness({
    this.matchLength = 1,
    this.buddyDoubles = false,
    FakeBuddyCamera? camera,
  }) : camera = camera ?? FakeBuddyCamera();

  final int matchLength;

  /// Whether the engine is asked for the cube at all. A 1-point match is the
  /// Crawford game and never is; a 3-point one is, and this makes it say yes.
  final bool buddyDoubles;

  final FakeVision vision = FakeVision(calibration: fakeCalibration());
  final FakeBuddyCamera camera;
  late final FakeBoardLearner learner = FakeBoardLearner(vision);
  final BoardHandles handles = BoardHandles.seed(folding: false);
  late final AppDatabase db;

  BuddySetup get setup => BuddySetup(
        matchLength: matchLength,
        cubeless: false,
        difficulty: Difficulty.expert,
        buddySide: Player.black,
        seat: BuddySeat.near,
        phrasing: BuddyPhrasing.terse,
      );

  Future<void> pump(WidgetTester t, {double textScale = 1.0}) async {
    await t.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    db = newTestDatabase();
    addTearDown(db.close);
    addTearDown(camera.close);

    await t.pumpWidget(ProviderScope(
      overrides: <Override>[
        databaseProvider.overrideWithValue(db),
        engineFacadeProvider.overrideWithValue(
            buddyDoubles ? const _AlwaysDoubles() : const _FlatFacade()),
        buddyCameraProvider.overrideWithValue(camera),
        boardLearnerProvider.overrideWithValue(learner),
        buddyTtsProvider.overrideWithValue(const SilentBuddyTts()),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: BuddyGameScreen(
            setup: setup,
            outcome: CalibrationOutcome(
              vision: vision,
              handles: handles,
              seat: BuddySeat.near,
            ),
          ),
        ),
      ),
    ));
    await settle(t);
  }

  /// One settled frame, and everything it sets off.
  Future<void> frame(WidgetTester t) async {
    camera.push(blankFrame(width: 64, height: 48));
    await settle(t);
  }

  /// Drains the microtask chains a controller step, an agent future and a
  /// persistence hook take, pumping a frame each time so every `setState` they
  /// cause is built before the test looks.
  Future<void> settle(WidgetTester t, [int rounds = 24]) async {
    for (var i = 0; i < rounds; i++) {
      await t.pump();
    }
  }

  /// Opens the manual pad and types one roll.
  Future<void> enterRoll(WidgetTester t, int a, int b) async {
    await t.tap(find.byKey(const Key('buddy-dice-button')));
    await t.pumpAndSettle();
    await pickRoll(t, a, b);
  }

  /// The pad's own three taps, once it is open.
  Future<void> pickRoll(WidgetTester t, int a, int b) async {
    await t.tap(find.byKey(Key('buddy-die-a-$a')));
    await t.pump();
    await t.tap(find.byKey(Key('buddy-die-b-$b')));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Enter roll'));
    await t.pumpAndSettle();
    await settle(t);
  }

  /// Drives the calibration screen the game screen just pushed, which opens on
  /// the corners because they were seeded.
  Future<void> recalibrate(WidgetTester t) async {
    camera.push(blankFrame(width: 64, height: 48));
    await t.pumpAndSettle();
    await t.tap(find.text('Next')); // corners -> seat
    await t.pumpAndSettle();
    await t.tap(find.text('Capture'));
    await t.pumpAndSettle();
    camera.push(blankFrame(width: 64, height: 48));
    await t.pumpAndSettle();
    await t.tap(find.text('Looks right'));
    await t.pumpAndSettle();
    await settle(t);
  }
}

/// The setup screen, the calibration flow and the game screen, in the order
/// production puts them in.
///
/// Separate from [_Harness] because the point is the ROUTES: the game screen
/// arrives by being launched from a calibration that is popping, which is the
/// moment the shared camera changes hands.
class _HandoverHarness {
  final FakeVision vision = FakeVision(calibration: fakeCalibration());
  final FakeBuddyCamera camera = FakeBuddyCamera();
  late final FakeBoardLearner learner = FakeBoardLearner(vision);
  late final AppDatabase db;

  Future<void> pump(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    db = newTestDatabase();
    addTearDown(db.close);
    addTearDown(camera.close);

    final container = ProviderContainer(overrides: <Override>[
      databaseProvider.overrideWithValue(db),
      settingsProvider.overrideWith((ref) => Stream.value(_kSettings)),
      engineFacadeProvider.overrideWithValue(const _FlatFacade()),
      buddyCameraProvider.overrideWithValue(camera),
      boardLearnerProvider.overrideWithValue(learner),
      buddyTtsProvider.overrideWithValue(const SilentBuddyTts()),
    ]);
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);

    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      // The REAL launcher, because the handover is what this is about.
      child: const MaterialApp(
        home: BuddySetupScreen(launch: openBuddyGame),
      ),
    ));
    await t.pumpAndSettle();
  }

  /// Drives the calibration screen the setup screen just pushed.
  Future<void> calibrate(WidgetTester t) async {
    camera.push(blankFrame(width: 64, height: 48));
    await t.pumpAndSettle();
    await t.tap(find.text('Next')); // checklist -> corners
    await t.pumpAndSettle();
    await t.tap(find.text('Next')); // corners -> seat
    await t.pumpAndSettle();
    await t.tap(find.text('Capture'));
    await t.pumpAndSettle();
    camera.push(blankFrame(width: 64, height: 48));
    await t.pumpAndSettle();
    await t.tap(find.text('Looks right'));
    await t.pumpAndSettle();
  }
}

const AppSettings _kSettings = AppSettings(
  themeMode: ThemeMode.system,
  animationSpeed: AnimationSpeed.normal,
  defaultMatchLength: 1,
  defaultDifficulty: Difficulty.expert,
  tutorOverride: null,
);

/// The flat facade with the one answer that turns the cube on.
///
/// 70% wins with a tenth of them gammons, which `MatchCubeAdvisor` calls a
/// double-and-take at 3-away/3-away. Chosen rather than something lopsided
/// because a position too GOOD to double is also not a double — 85% with a
/// fifth gammons comes back `double false`, which is right and would have made
/// this a test about nothing.
class _AlwaysDoubles extends _FlatFacade {
  const _AlwaysDoubles();

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async =>
      const Probabilities(
        win: 0.70,
        winGammon: 0.1,
        winBackgammon: 0,
        loseGammon: 0,
        loseBackgammon: 0,
      );
}
