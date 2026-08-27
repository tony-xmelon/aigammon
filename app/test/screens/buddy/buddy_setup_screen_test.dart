import 'package:aigammon_app/buddy/buddy_session.dart';
import 'package:aigammon_app/buddy/speaker.dart';
import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/screens/buddy/buddy_setup_screen.dart';
import 'package:aigammon_app/screens/buddy/calibration_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../buddy/fake_calibration_seams.dart';
import '../../buddy/fake_vision.dart';

const AppSettings _settings = AppSettings(
  themeMode: ThemeMode.system,
  animationSpeed: AnimationSpeed.normal,
  defaultMatchLength: 5,
  defaultDifficulty: Difficulty.hard,
  tutorOverride: null,
);

void main() {
  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  group('the seat and the seating it implies', () {
    test('the user sitting by the phone puts their own home board near', () {
      // Asked of `orientationFor` directly, which is where the fact lives: the
      // two screens and the session all derive their coordinate frame through
      // it, and neither `BuddySetup` nor `CalibrationRequest` carries a copy —
      // a copy on the request would be the PRE-confirmation seat under a name
      // that reads like an answer.
      expect(orientationFor(Player.white, BuddySeat.near),
          BoardOrientation.whiteHomeNear);
      expect(orientationFor(Player.white, BuddySeat.far),
          BoardOrientation.whiteHomeFar);
      expect(orientationFor(Player.black, BuddySeat.near),
          BoardOrientation.whiteHomeFar,
          reason: 'the user plays Black now, so it is BLACK\'s home that is '
              'near');
      expect(orientationFor(Player.black, BuddySeat.far),
          BoardOrientation.whiteHomeNear);
    });

    test('and the setup names the side the user plays, not the one Buddy does',
        () {
      const setup = BuddySetup(
        matchLength: 1,
        cubeless: false,
        difficulty: Difficulty.easy,
        buddySide: Player.black,
        seat: BuddySeat.near,
        phrasing: BuddyPhrasing.terse,
      );
      expect(setup.userSide, Player.white);
      expect(setup.copyWith(buddySide: Player.white).userSide, Player.black);
      expect(setup.copyWith(seat: BuddySeat.far).seat, BuddySeat.far);
    });
  });

  group('the setup screen', () {
    testWidgets('starts from the settings the rest of the app starts from',
        (t) async {
      final h = _Harness();
      await h.pump(t);

      expect(_selected<int>(t, 5), isTrue);
      expect(_selected<Difficulty>(t, Difficulty.hard), isTrue);
    });

    testWidgets('takes the Buddy voice from Settings, not from a literal',
        (t) async {
      // The reconciliation this task owed: the per-match control was a
      // hard-coded `terse` while Settings had nothing to say about Buddy at
      // all, so a stored preference would have been a preference the screen it
      // applies to ignored. Seeded, not written back — per-match, exactly like
      // the match length and the difficulty above it.
      final h = _Harness(
        settings: _settings.copyWith(buddyPhrasing: BuddyPhrasing.friendly),
      );
      await h.pump(t);

      expect(_selected<BuddyPhrasing>(t, BuddyPhrasing.friendly), isTrue);
      expect(
          find.textContaining('Move one checker from 13 to 8'), findsOneWidget,
          reason: 'the example under the control follows the selection');

      await _tap(t, find.text('Terse'));
      await _tap(t, find.text('Calibrate the board'));
      await h.calibrate(t);
      expect(h.launched!.$1.phrasing, BuddyPhrasing.terse,
          reason: 'a per-match change wins for this match');
    });

    testWidgets('adds the two choices only Buddy Mode has', (t) async {
      final h = _Harness();
      await h.pump(t);

      expect(find.text('Your seat'), findsOneWidget);
      expect(find.text('How Buddy talks'), findsOneWidget);
      expect(_selected<BuddySeat>(t, BuddySeat.near), isTrue,
          reason: 'the phone propped at your own elbow is the ordinary case');
      expect(_selected<BuddyPhrasing>(t, BuddyPhrasing.terse), isTrue);
    });

    testWidgets('carries every choice through calibration to whoever launches '
        'the match', (t) async {
      final h = _Harness();
      await h.pump(t);

      await _tap(t, find.text('3'));
      await _tap(t, find.text('Opposite'));
      await _tap(t, find.text('Friendly'));
      await _tap(t, find.widgetWithText(SwitchListTile, 'Play without cube'));
      await _tap(t, find.text('Calibrate the board'));
      expect(find.byType(CalibrationScreen), findsOneWidget);

      await h.calibrate(t);

      expect(h.launched, isNotNull);
      final (setup, outcome) = h.launched!;
      expect(setup.matchLength, 3);
      expect(setup.seat, BuddySeat.far);
      expect(setup.phrasing, BuddyPhrasing.friendly);
      expect(setup.cubeless, isTrue);
      expect(setup.difficulty, Difficulty.hard);
      expect(outcome.vision, same(h.vision));

      // Buddy plays Black by default and the user sits opposite the phone, so
      // White's home is the FAR half — and that is what was calibrated.
      expect(h.learner.calls.single.orientation, BoardOrientation.whiteHomeFar);
    });

    testWidgets('the side Buddy plays is a choice, and it turns the board over',
        (t) async {
      // The one control the test above left on its default. It is half of what
      // fixes the coordinate frame — the seat is the other half — so a screen
      // that dropped it would number every point backwards for a user who
      // plays Black, on a board that calibrated and confirmed.
      final h = _Harness();
      await h.pump(t);

      await _tap(t, find.text('White'));
      await _tap(t, find.text('Opposite'));
      await _tap(t, find.text('Calibrate the board'));
      await h.calibrate(t);

      expect(h.launched!.$1.buddySide, Player.white);
      expect(h.launched!.$1.userSide, Player.black);
      expect(h.learner.calls.single.orientation, BoardOrientation.whiteHomeNear,
          reason: 'the user plays Black and sits opposite the phone, so it is '
              "BLACK's home that is far — which is White's home near");
    });
  });
}

/// The setup form is taller than a test viewport, so every control has to be
/// scrolled to before it can be tapped.
Future<void> _tap(WidgetTester t, Finder target) async {
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

bool _selected<T>(WidgetTester t, T value) => t
    .widget<SegmentedButton<T>>(find.byType(SegmentedButton<T>))
    .selected
    .contains(value);

class _Harness {
  _Harness({this.settings = _settings});

  /// What the persisted preferences say when this screen opens.
  final AppSettings settings;

  final FakeVision vision = FakeVision(calibration: fakeCalibration());
  late final FakeBoardLearner learner = FakeBoardLearner(vision);
  final FakeBuddyCamera camera = FakeBuddyCamera();
  (BuddySetup, CalibrationOutcome)? launched;

  Future<void> pump(WidgetTester t) async {
    final container = ProviderContainer(overrides: <Override>[
      settingsProvider.overrideWith((ref) => Stream.value(settings)),
      buddyCameraProvider.overrideWithValue(camera),
      boardLearnerProvider.overrideWithValue(learner),
    ]);
    addTearDown(container.dispose);
    addTearDown(camera.close);
    await container.read(settingsProvider.future);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: BuddySetupScreen(
          launch: (context, setup, outcome) => launched = (setup, outcome),
        ),
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

