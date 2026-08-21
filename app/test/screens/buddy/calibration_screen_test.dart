import 'package:aigammon_app/buddy/buddy_session.dart';
import 'package:aigammon_app/screens/buddy/calibration_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
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

    testWidgets('the dice size the session carries is what the board is '
        'learned with', (t) async {
      // Not a constant, and the gap is measured: the first real board's dice
      // are 0.021 of it across against a synthetic bed's 0.075, and every gate
      // in the dice reader is derived from this number. A screen that dropped
      // it would calibrate for the bed's dice on anybody's board.
      final h = _Harness(
        request: const CalibrationRequest(
          userSide: Player.white,
          seat: BuddySeat.near,
          dieSide: 0.021,
        ),
      );
      await h.pump(t);
      await h.capture(t);

      expect(h.learner.calls.single.dieSide, closeTo(0.021, 1e-9));
    });

    testWidgets('the confirm step shows what board_vision saw, and start over '
        'keeps the corners', (t) async {
      final h = _Harness();
      h.vision.willConfirm(<ConfirmResult>[startPositionDisagrees]);
      await h.pump(t);
      await h.capture(t);

      expect(find.text(startPositionDisagrees.message), findsOneWidget);
      expect(_belief(t).offending, <RoiId>{RoiId.point5},
          reason: 'the sentence names the 6-point and the overlay has to ring '
              'it — a message about a point the picture does not mark is the '
              'user hunting for what is wrong');
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

    testWidgets('the belief keeps asking, once per settled frame', (t) async {
      // The claim the step is built on: a user who sees Buddy disagree with
      // the board moves a checker, and the answer has to follow the board
      // rather than stay frozen on the frame it was learned from.
      final h = _Harness();
      await h.pump(t);
      await h.capture(t);
      expect(h.vision.confirmCalls, 1,
          reason: 'the frame it was learned from answers immediately');

      h.camera.push(_frame());
      await t.pumpAndSettle();
      expect(h.vision.confirmCalls, 2);

      h.camera.push(_frame(), stable: false);
      await t.pumpAndSettle();
      expect(h.vision.confirmCalls, 2,
          reason: 'an unsettled picture is a board mid-move, and is asked '
              'nothing on any step');
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

  group('CameraHold', () {
    // The count two screens share one camera through. It is the half of
    // `PhoneBuddyCamera` that is decidable without a device, and the half with
    // a bug in it: before there was a count, whichever of the two screens
    // disposed second took the camera away from the one still using it, and
    // the failure was a preview that went black with nothing logged anywhere.

    test('one screen in, one screen out', () {
      final hold = CameraHold();
      hold.acquire();
      expect(hold.users, 1);
      expect(hold.release(), isTrue,
          reason: 'nobody else is holding it, so this close is the teardown');
      expect(hold.users, 0);
    });

    test('the handover: the second close is the one that tears down', () {
      // Both directions of the overlap look like this. The calibration route
      // pops INTO the game screen, which opens before the popped route
      // disposes; the game screen pushes the route BACK, which closes as it
      // pops under a screen still playing a match.
      final hold = CameraHold()
        ..acquire()
        ..acquire();

      expect(hold.release(), isFalse,
          reason: 'the screen that is going away must tear nothing down while '
              'another one is still looking through the camera');
      expect(hold.users, 1);
      expect(hold.release(), isTrue);
      expect(hold.users, 0);
    });

    test('an unbalanced close cannot drive the count negative', () {
      final hold = CameraHold();

      expect(hold.release(), isTrue,
          reason: 'nothing is held, so there is nothing left to keep alive');
      expect(hold.users, 0,
          reason: 'a count below zero would swallow the NEXT real close and '
              'leave the camera running with no screen on it');

      hold.acquire();
      expect(hold.release(), isTrue);
    });

    test('the provider teardown does not wait for a screen that leaked', () {
      final hold = CameraHold()
        ..acquire()
        ..acquire();

      hold.releaseAll();
      expect(hold.users, 0);
      expect(hold.release(), isTrue,
          reason: 'shutDown releases everyone and then closes, and that close '
              'has to be the one that turns the camera off');
    });
  });

  // A handle that can only be dragged is a handle only some people can place,
  // on the screen whose whole subject is placing one precisely.
  group('accessibility', () {
    testWidgets('the arrow keys place a handle without a finger on it',
        (t) async {
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);

      final box = t.getSize(find.byKey(const Key('buddy-board-outline')));
      final before = _outline(t).handles.outer[0];

      await t.tap(_handleFinder());
      await t.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();

      const step = CalibrationHandle.nudgeStep;
      final after = _outline(t).handles.outer[0];
      expect(after.dx - before.dx, closeTo(3 * step / box.width, 1e-9));
      expect(after.dy - before.dy, closeTo(-step / box.height, 1e-9),
          reason: 'up is towards the top of the picture, as it is everywhere '
              'else');
    });

    testWidgets('an arrow key moves the handle rather than the focus',
        (t) async {
      // `WidgetsApp`'s own shortcuts read arrow keys as directional focus
      // traversal, so a handle that did not claim them would hand the next
      // press to a different corner.
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);
      final box = t.getSize(find.byKey(const Key('buddy-board-outline')));
      final before = _outline(t).handles;

      await t.tap(_handleFinder());
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();

      final after = _outline(t).handles;
      expect(after.outer[0].dx - before.outer[0].dx,
          closeTo(2 * CalibrationHandle.nudgeStep / box.width, 1e-9));
      expect(after.outer.sublist(1), before.outer.sublist(1),
          reason: 'the other three did not move');
    });

    testWidgets('and the same four moves are offered as semantic actions',
        (t) async {
      // Disposed inside the test body: the end-of-test check for a live
      // SemanticsHandle runs BEFORE tearDowns.
      final handle = t.ensureSemantics();
      final h = _Harness();
      await h.pump(t);
      await h.toCorners(t);

      final box = t.getSize(find.byKey(const Key('buddy-board-outline')));
      final before = _outline(t).handles.outer[0];
      final node = t.getSemantics(_handleFinder());
      expect(node.label, 'Board corner 1 of 4');

      final actions = <String, int>{
        for (final id
            in node.getSemanticsData().customSemanticsActionIds ?? const <int>[])
          CustomSemanticsAction.getAction(id)!.label!: id,
      };
      expect(actions.keys,
          containsAll(<String>['Nudge left', 'Nudge right', 'Nudge up',
              'Nudge down']));

      node.owner!.performAction(
          node.id, SemanticsAction.customAction, actions['Nudge down']);
      await t.pumpAndSettle();

      expect(_outline(t).handles.outer[0].dy - before.dy,
          closeTo(CalibrationHandle.nudgeStep / box.height, 1e-9),
          reason: 'the action a screen reader offers has to move the handle, '
              'not merely be listed');

      handle.dispose();
    });
  });

  group('BeliefPainter', () {
    test('stacks the men at the pitch the calibration measured, from the '
        'origin it measured', () {
      // The overlay exists to be disagreed with: a person looks at thirty
      // drawn men and says whether they are where the real ones are. Drawn
      // through a nominal pitch it would look right on any board whose
      // checkers happen to sit a nominal distance apart, and wrong on the one
      // it was calibrated from — which is the only board it is ever over.
      const stacks =
          StackMetrics(pitch: 0.06, origin: 0.03, wellConditioned: true);

      // Every distinct depth a checker was drawn at, measured back out of the
      // picture. The starting position has stacks of 2, 3 and 5, so across the
      // whole board the drawn depths are exactly the first five.
      final depths = _stackDepths(stacks);

      expect(depths, hasLength(5));
      for (final (k, depth) in depths.indexed) {
        expect(depth, closeTo(stacks.origin + (k + 0.5) * stacks.pitch, 1e-6),
            reason: 'checker $k sits at origin + (k + 0.5) * pitch, which is '
                'the same arithmetic occupancy counts backwards with');
      }
    });

    test('and a different fit moves them', () {
      // Causation, not coincidence: the same painter over the same geometry,
      // with only the calibration's own stack fit changed.
      final wide = _stackDepths(
          const StackMetrics(pitch: 0.09, origin: 0, wellConditioned: true));
      final tight = _stackDepths(
          const StackMetrics(pitch: 0.03, origin: 0, wellConditioned: true));

      expect(wide.last, closeTo(4.5 * 0.09, 1e-6));
      expect(tight.last, closeTo(4.5 * 0.03, 1e-6));
    });

    test('repaints when the same NUMBER of regions is a different set of them',
        () {
      // point5 → point7 is one flagged region either way, and a length-only
      // comparison keeps the old red rings under a fresh sentence: the picture
      // says one point is wrong and names another.
      // One calibration for both painters, so what is being compared is the
      // flagged set and nothing else.
      final calibration = fakeCalibration();
      BeliefPainter painterFor(Set<RoiId> offending) => BeliefPainter(
            calibration: calibration,
            frame: _beliefBox,
            offending: offending,
            wrong: const Color(0xFFFF0000),
          );

      expect(
        painterFor(<RoiId>{RoiId.point7})
            .shouldRepaint(painterFor(<RoiId>{RoiId.point5})),
        isTrue,
      );
      expect(
        painterFor(<RoiId>{RoiId.point5})
            .shouldRepaint(painterFor(<RoiId>{RoiId.point5})),
        isFalse,
        reason: 'the same set is the same picture',
      );
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

BeliefPainter _belief(WidgetTester t) =>
    t.widget<CustomPaint>(find.byKey(const Key('buddy-belief'))).painter!
        as BeliefPainter;

Frame _frame() => blankFrame(width: 64, height: 48);

/// Every distinct depth [BeliefPainter] drew a checker at, in BOARD space,
/// sorted and measured back out of the picture it painted.
///
/// The fake calibration's geometry is the unit square scaled to [_beliefBox],
/// so a pixel `y` is `depth` on the far half and `1 - depth` on the near one.
List<double> _stackDepths(StackMetrics stacks) {
  final canvas = TestRecordingCanvas();
  BeliefPainter(
    calibration: fakeCalibration(stacks: stacks),
    frame: _beliefBox,
    offending: const <RoiId>{},
    wrong: const Color(0xFFFF0000),
  ).paint(canvas, _beliefBox);
  final depths = <double>{};
  for (final call in canvas.invocations) {
    if (call.invocation.memberName != #drawCircle) continue;
    final centre = call.invocation.positionalArguments.first as Offset;
    final y = centre.dy / _beliefBox.height;
    depths.add(double.parse((y > 0.5 ? 1 - y : y).toStringAsFixed(9)));
  }
  return depths.toList()..sort();
}

const Size _beliefBox = Size(640, 480);

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

