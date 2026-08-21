import 'dart:async';

import 'package:aigammon_app/buddy/buddy_session.dart';
import 'package:aigammon_app/buddy/camera_frame_source.dart';
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
      const white = BuddySetup(
        matchLength: 1,
        cubeless: false,
        difficulty: Difficulty.easy,
        buddySide: Player.black,
        seat: BuddySeat.near,
        phrasing: BuddyPhrasing.terse,
      );
      expect(white.userSide, Player.white);
      expect(white.orientation, BoardOrientation.whiteHomeNear);

      expect(
        white.copyWith(seat: BuddySeat.far).orientation,
        BoardOrientation.whiteHomeFar,
      );
      expect(
        white.copyWith(buddySide: Player.white).orientation,
        BoardOrientation.whiteHomeFar,
        reason: 'the user plays Black now, so it is BLACK\'s home that is near',
      );
      expect(
        white.copyWith(buddySide: Player.white, seat: BuddySeat.far).orientation,
        BoardOrientation.whiteHomeNear,
      );
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
  final FakeVision vision = FakeVision(calibration: fakeCalibration());
  late final FakeBoardLearner learner = FakeBoardLearner(vision);
  final FakeBuddyCamera camera = FakeBuddyCamera();
  (BuddySetup, CalibrationOutcome)? launched;

  Future<void> pump(WidgetTester t) async {
    final container = ProviderContainer(overrides: <Override>[
      settingsProvider.overrideWith((ref) => Stream.value(_settings)),
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

class FakeBuddyCamera implements BuddyCamera {
  final StreamController<ObservedFrame> _frames =
      StreamController<ObservedFrame>.broadcast();
  bool closed = false;

  @override
  Stream<ObservedFrame> get frames => _frames.stream;

  @override
  Future<CameraOpening> open() async => const CameraReady();

  @override
  Widget preview(BuildContext context) =>
      const ColoredBox(color: Color(0xFF202020));

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _frames.close();
  }

  void push(Frame frame) {
    if (closed) return;
    _frames.add(ObservedFrame(
      frame: frame,
      motion: MotionHint.still,
      isStable: true,
      sceneChange: 0,
      at: Duration.zero,
    ));
  }
}

class FakeBoardLearner implements BoardLearner {
  FakeBoardLearner(this._vision);

  final FakeVision _vision;
  final List<({BoardHandles handles, BoardOrientation orientation})> calls =
      <({BoardHandles handles, BoardOrientation orientation})>[];

  @override
  CalibrationResult learn({
    required Frame frame,
    required BoardHandles handles,
    required BoardOrientation orientation,
    required double dieSide,
  }) {
    calls.add((handles: handles, orientation: orientation));
    return CalibrationResult.success(_vision.calibration);
  }

  @override
  BoardVision visionFor(BoardCalibration calibration) => _vision;
}
