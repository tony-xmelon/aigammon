import 'package:aigammon_app/buddy/buddy_session.dart';
import 'package:aigammon_app/screens/buddy/calibration_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../buddy/fake_calibration_seams.dart';
import '../../buddy/fake_vision.dart';

void main() {
  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  group('the aim step', () {
    testWidgets('says to take the dice off the board, and why', (t) async {
      final h = _Harness();
      await h.pump(t);

      // The single most expensive mistake a first-time user can make: a die
      // left on the felt is learned as part of the board's surface and is
      // invisible for the rest of the session.
      expect(find.textContaining('dice off the board'), findsOneWidget);
      expect(
        find.textContaining('learn'),
        findsWidgets,
        reason: 'the warning has to say WHY, or it reads as tidiness',
      );
    });

    testWidgets('asks what kind of board this is before it asks for corners',
        (t) async {
      final h = _Harness();
      await h.pump(t);

      expect(find.text('Flat board'), findsOneWidget);
      expect(find.text('Folding case'), findsOneWidget);
    });
  });

  group('the corner step', () {
    testWidgets('names the felt boundary rather than the rim', (t) async {
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);

      final caption = find.textContaining('felt');
      expect(caption, findsOneWidget);
      expect(
        (t.widget<Text>(caption).data ?? '').toLowerCase(),
        contains('rim'),
        reason: 'the measured mistake is a handle on the wooden rim, so the '
            'sentence has to name the thing NOT to aim at',
      );
    });

    testWidgets('a flat board gets four handles, a folding case gets eight',
        (t) async {
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);
      expect(_handles(t), 4);

      await h.restart(t);
      await h.chooseFolding(t);
      await h.toCorners(t);
      expect(_handles(t), 8,
          reason: 'calibrateFolding needs the four hinge seams as well');
    });

    testWidgets('the folding hinge handles are seeded on the edge midpoints',
        (t) async {
      final h = _Harness();
      await h.pump(t);
      await h.chooseFolding(t);
      await h.toCorners(t);

      final handles = _outline(t).handles;
      expect(handles.hinge, hasLength(4));
      final far = handles.hinge[0];
      final alsoFar = handles.hinge[1];
      expect(far.dy, closeTo(handles.outer[0].dy, 0.001),
          reason: 'a hinge seam sits ON the far edge, between its corners');
      expect((far.dx + alsoFar.dx) / 2,
          closeTo((handles.outer[0].dx + handles.outer[1].dx) / 2, 0.001),
          reason: 'the strip is centred on the edge, ready to be nudged');
    });

    testWidgets('the derived columns are drawn over the live frame, and follow '
        'the handles', (t) async {
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);

      final before = _outline(t);
      expect(before.columns, hasLength(25),
          reason: 'twenty-four point columns and the bar — a person can see a '
              'column that misses its stack instantly, and cannot see a corner '
              'that is 3% out');

      await t.drag(find.byKey(const Key('buddy-handle-0')), const Offset(40, 0));
      await t.pumpAndSettle();

      final after = _outline(t);
      expect(after.handles.outer[0].dx, greaterThan(before.handles.outer[0].dx));
      expect(after.columns.first, isNot(before.columns.first),
          reason: 'the overlay is derived from the handles, not decoration');
    });

    testWidgets('a handle keeps every delta the finger gave it, not just the '
        'last one before a frame', (t) async {
      // A touch screen reports moves faster than a phone draws frames, so
      // several `onPanUpdate`s arrive between two builds as a matter of course.
      // A handle that rebases each of them on the position it had at BUILD time
      // keeps only the last, and the mark under the finger lags it and stops
      // short — on the precision screen, under the loupe.
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);

      final box = t.getSize(find.byKey(const Key('buddy-board-outline')));
      final gesture =
          await t.startGesture(t.getCenter(_handleFinder()));
      // Past the drag slop and settled, so the three moves below are the whole
      // of what this measures.
      await gesture.moveBy(const Offset(0, 40));
      await t.pumpAndSettle();
      final start = _outline(t).handles.outer[0];

      for (var i = 0; i < 3; i++) {
        await gesture.moveBy(const Offset(10, 0));
      }
      await gesture.up();
      await t.pumpAndSettle();

      expect(_outline(t).handles.outer[0].dx - start.dx,
          closeTo(30 / box.width, 1e-9),
          reason: 'three ten-pixel moves are thirty pixels, whether or not a '
              'frame happened to be drawn between them');
      expect(_outline(t).handles.outer[0].dy, closeTo(start.dy, 1e-9));
    });

    testWidgets('a handle under the finger raises a magnifier', (t) async {
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);
      expect(find.byType(RawMagnifier), findsNothing);

      final gesture =
          await t.startGesture(t.getCenter(find.byKey(const Key('buddy-handle-0'))));
      await gesture.moveBy(const Offset(24, 12));
      await t.pump();
      expect(find.byType(RawMagnifier), findsOneWidget,
          reason: 'the accepting corner region is narrow; a fingertip covering '
              'the handle is the reason a person cannot land in it');

      await gesture.up();
      await t.pumpAndSettle();
      expect(find.byType(RawMagnifier), findsNothing);
    });
  });

  group('the whole flow', () {
    testWidgets('drag the corners, confirm the seat, capture, confirm the '
        'belief — and a calibration comes out', (t) async {
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);

      await t.drag(find.byKey(const Key('buddy-handle-0')), const Offset(-30, -24));
      await t.pumpAndSettle();
      final dragged = _outline(t).handles;

      await t.tap(find.text('Next')); // the seat question
      await t.pumpAndSettle();
      expect(find.textContaining('home board'), findsWidgets);

      await t.tap(find.text('Capture'));
      await t.pumpAndSettle();
      expect(h.learner.calls, isEmpty,
          reason: 'a calibration is learned from a SETTLED frame, not from '
              'whatever the preview happened to be showing when a button was '
              'pressed');

      h.camera.push(_frame());
      await t.pumpAndSettle();

      expect(h.learner.calls, hasLength(1));
      final call = h.learner.calls.single;
      expect(call.handles.outer, dragged.outer,
          reason: 'what was learned is exactly what the user dragged');
      expect(call.orientation, BoardOrientation.whiteHomeNear);

      // The belief over the preview is the safety net, and it is only reached
      // once there is a geometry to draw it through.
      expect(find.byKey(const Key('buddy-belief')), findsOneWidget);
      expect(h.outcome, isNull, reason: 'nothing is handed over unconfirmed');

      await t.tap(find.text('Looks right'));
      await t.pumpAndSettle();

      expect(h.outcome, isNotNull);
      expect(h.outcome!.handles.outer, dragged.outer,
          reason: 'the handles come back out so the next recalibration can '
              'pre-seed them');
    });

    testWidgets('the confirm step shows what board_vision saw, and start over '
        'keeps the corners', (t) async {
      final h = _Harness();
      h.vision.willConfirm(<ConfirmResult>[startPositionDisagrees]);
      await h.pump(t);
      await h.capture(t);

      expect(find.text(startPositionDisagrees.message), findsOneWidget);
      final before = _outline(t).handles;

      await t.tap(find.text('Start over'));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('buddy-handle-0')), findsOneWidget,
          reason: 'a mis-detection restarts at the corners, not at the top');
      expect(_outline(t).handles.outer, before.outer,
          reason: 'the cheap restart is the fast path of NUDGING the existing '
              'corners');
      expect(h.outcome, isNull);
    });

    testWidgets('a refused calibration shows the sentence board_vision wrote',
        (t) async {
      final h = _Harness();
      h.learner.willAnswer(<CalibrationResult>[
        CalibrationResult.failure(
          CalibrationProblem.regionUnreadable,
          'I cannot make out the 6-point — something may be resting on it.',
          const <RoiId>[RoiId.point5],
        ),
      ]);
      await h.pump(t);
      await h.capture(t);

      expect(
        find.text('I cannot make out the 6-point — something may be resting '
            'on it.'),
        findsOneWidget,
        reason: 'CalibrationResult.message is written to be shown as it is',
      );
      expect(find.byKey(const Key('buddy-handle-0')), findsOneWidget,
          reason: 'a refusal lands back on the corners with them intact');
      expect(h.outcome, isNull);
    });
  });

  group('recalibration', () {
    testWidgets('pre-seeds the corners and opens on them', (t) async {
      const seeded = BoardHandles(outer: <Offset>[
        Offset(0.05, 0.11),
        Offset(0.94, 0.13),
        Offset(0.96, 0.88),
        Offset(0.04, 0.86),
      ]);
      final h = _Harness(
        request: const CalibrationRequest(
          userSide: Player.white,
          seat: BuddySeat.far,
          seededHandles: seeded,
        ),
      );
      await h.pump(t);

      expect(find.text('Capture'), findsNothing);
      expect(find.byKey(const Key('buddy-handle-0')), findsOneWidget,
          reason: 'a session that lost its calibration mid-match opens on the '
              'corners, not on the setup checklist');
      expect(_outline(t).handles.outer, seeded.outer);

      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      await t.tap(find.text('Capture'));
      await t.pumpAndSettle();
      h.camera.push(_frame());
      await t.pumpAndSettle();

      expect(h.learner.calls.single.orientation, BoardOrientation.whiteHomeFar,
          reason: 'the seat the session already knows is not asked again from '
              'scratch');
    });

    testWidgets('handles that are not a board explain themselves rather than '
        'going dead', (t) async {
      const collapsed = BoardHandles(outer: <Offset>[
        Offset(0.5, 0.5),
        Offset(0.5, 0.5),
        Offset(0.5, 0.5),
        Offset(0.5, 0.5),
      ]);
      final h = _Harness(
        request: const CalibrationRequest(
          userSide: Player.white,
          seat: BuddySeat.near,
          seededHandles: collapsed,
        ),
      );
      await h.pump(t);

      expect(_outline(t).columns, isEmpty,
          reason: 'there is no geometry to derive columns through');
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
          .onPressed, isNull);

      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      expect(find.textContaining('do not outline a board'), findsOneWidget,
          reason: 'a disabled Material button cannot say why it is disabled');
    });
  });

  group('the camera', () {
    testWidgets('that will not open says so instead of showing a dead preview',
        (t) async {
      final h = _Harness(
        opening: const CameraUnavailable(
          'AIGammon does not have permission to use the camera.',
        ),
      );
      await h.pump(t);

      expect(
        find.text('AIGammon does not have permission to use the camera.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('buddy-handle-0')), findsNothing);
    });

    testWidgets('is closed when the screen goes away', (t) async {
      final h = _Harness();
      await h.pump(t);
      expect(h.camera.closed, isFalse);

      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      expect(h.camera.closed, isTrue);
    });
  });

  group('BoardHandles', () {
    test('scales into the frame it is calibrated against', () {
      const handles = BoardHandles(outer: <Offset>[
        Offset(0.1, 0.2),
        Offset(0.9, 0.2),
        Offset(0.9, 0.8),
        Offset(0.1, 0.8),
      ]);
      final quad = handles.quadIn(const Size(1280, 720));
      expect(quad.topLeft.x, closeTo(128, 0.001));
      expect(quad.topLeft.y, closeTo(144, 0.001));
      expect(quad.bottomRight.x, closeTo(1152, 0.001));
    });

    test('a folding board hands over eight points in the named order', () {
      final handles = BoardHandles.seed(folding: true);
      final corners = handles.foldingIn(const Size(1000, 1000));
      expect(corners.hingeFarLeft.x, lessThan(corners.hingeFarRight.x));
      expect(corners.barWidth, greaterThan(0));
      expect(corners.barWidth, lessThan(1));
    });

    test('four points that are not a board have no geometry to draw with', () {
      const collapsed = BoardHandles(outer: <Offset>[
        Offset(0.5, 0.5),
        Offset(0.5, 0.5),
        Offset(0.5, 0.5),
        Offset(0.5, 0.5),
      ]);
      expect(collapsed.geometry, isNull);
      expect(BoardHandles.seed(folding: false).geometry, isNotNull);
    });
  });
}

// -----------------------------------------------------------------------------

int _handles(WidgetTester t) =>
    t.widgetList(find.byType(CalibrationHandle)).length;

Finder _handleFinder() => find.byKey(const Key('buddy-handle-0'));

BoardOutlinePainter _outline(WidgetTester t) =>
    t.widget<CustomPaint>(find.byKey(const Key('buddy-board-outline'))).painter!
        as BoardOutlinePainter;

Frame _frame() => blankFrame(width: 64, height: 48);

class _Harness {
  _Harness({
    this.opening = const CameraReady(),
    this.request = const CalibrationRequest(
      userSide: Player.white,
      seat: BuddySeat.near,
    ),
  });

  final CameraOpening opening;
  final CalibrationRequest request;
  late final FakeBuddyCamera camera = FakeBuddyCamera(opening: opening);
  final FakeVision vision = FakeVision(calibration: fakeCalibration());
  late final FakeBoardLearner learner = FakeBoardLearner(vision);
  CalibrationOutcome? outcome;

  Future<void> pump(WidgetTester t) async {
    final container = ProviderContainer(overrides: <Override>[
      buddyCameraProvider.overrideWithValue(camera),
      boardLearnerProvider.overrideWithValue(learner),
    ]);
    addTearDown(container.dispose);
    addTearDown(camera.close);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: CalibrationScreen(
          request: request,
          onCalibrated: (o) => outcome = o,
        ),
      ),
    ));
    await t.pumpAndSettle();
    if (opening is CameraReady) {
      camera.push(_frame());
      await t.pumpAndSettle();
    }
  }

  /// Past the checklist and onto the handles.
  Future<void> toCorners(WidgetTester t) async {
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();
    expect(_handleFinder(), findsOneWidget);
  }

  /// Back to the checklist from wherever we are.
  Future<void> restart(WidgetTester t) async {
    await t.tap(find.text('Back'));
    await t.pumpAndSettle();
  }

  /// The checklist is taller than a test viewport, so the board-type control
  /// has to be scrolled to before it can be tapped.
  Future<void> chooseFolding(WidgetTester t) async {
    final segment = find.text('Folding case');
    await t.ensureVisible(segment);
    await t.pumpAndSettle();
    await t.tap(segment);
    await t.pumpAndSettle();
  }

  /// The whole way to a learned calibration on a settled frame.
  Future<void> capture(WidgetTester t) async {
    await toCorners(t);
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();
    await t.tap(find.text('Capture'));
    await t.pumpAndSettle();
    camera.push(_frame());
    await t.pumpAndSettle();
  }
}

