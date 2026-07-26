import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_view.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The P0 live-play regression suite: entering a move by TAPPING must work at the
/// rhythm and precision of a real thumb on a real phone.
///
/// Everything here runs in the SHIPPED configuration — a phone-shaped board, drag
/// enabled (the default in settings), the production 300ms double-tap window and
/// real wall-clock timing between taps (the tester issues them milliseconds
/// apart, so every pair is inside the window). The two bugs it pins down:
///
/// 1. **the stranded checker** — tap 13, tap 9 (playing the 4 of a 4-1), then tap
///    the SAME checker again to play the 1: "cannot make second move with the same
///    pip". `legalMoves` lists only one decomposition per resulting position, so
///    the 13/12 12/8 representative left a checker tapped onto the 9-point with
///    nothing to play. `MoveBuilder.forState` offers every decomposition.
/// 2. **the vanished tap** — a press that slides 18-36pt was rejected by the tap
///    recogniser and not yet claimed by the pan, so it did nothing at all.
///
/// Timing is deliberately NOT faked: `_consumeDoubleTap` reads `DateTime.now()`,
/// and consecutive `tapAt`s land well inside 300ms, which is exactly the live
/// hazard. The gap matrix at the end walks the window on the real clock.
void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  /// A phone-shaped slot (Pixel-class logical size, portrait): the board comes
  /// out taller than wide, with ~13pt checkers — small targets, 22pt forgiveness.
  const phone = Size(392, 712);

  BoardPainter painterOf(WidgetTester t) => t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((c) => c.painter is BoardPainter)
      .painter as BoardPainter;

  Rect boardRect(WidgetTester t) => t.getRect(find
      .byWidgetPredicate((w) => w is CustomPaint && w.painter is BoardPainter));

  /// Mounts the board as the app ships it: drag on, combined taps on, the
  /// production double-tap window.
  Future<BoardEntryController> mount(
    WidgetTester t,
    GameState state, {
    bool enableDrag = true,
    ValueChanged<bool>? onNoLegalSourceTap,
  }) async {
    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: phone.width,
            height: phone.height,
            child: BoardView(
              state: state,
              interactive: true,
              onMoveCommitted: (_) {},
              entryControl: control,
              onNoLegalSourceTap: onNoLegalSourceTap,
              interactionOptions: BoardInteractionOptions(enableDrag: enableDrag),
            ),
          ),
        ),
      ),
    ));
    return control;
  }

  /// White has two checkers on the 13-point (index 12) and 4-1 to play. The one
  /// checker run is listed as `13/12 12/8`; the user is going to tap it the other
  /// way round, 13/9 then 9/8.
  GameState chainState() {
    final pts = List<int>.filled(24, 0);
    pts[12] = 2;
    pts[5] = 5;
    pts[4] = 5;
    pts[3] = 3;
    pts[23] = -8;
    pts[22] = -5;
    pts[0] = -2;
    return GameState.testState(
      board: BoardState(points: pts),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(4, 1),
    );
  }

  group('the reported rhythm: move a checker, then move it again', () {
    testWidgets('tap 13, tap 9, tap 9, tap 8 — the 1 plays and Confirm enables',
        (t) async {
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      Future<void> tap(Offset o) async {
        await t.tapAt(r.topLeft + o);
        await t.pump();
      }

      await tap(g.checkerCenter(12, 1, 2)); // pick up the 13-point
      expect(painterOf(t).selectedCheckerLocation, 12);
      expect(painterOf(t).highlightedDestinations, {11, 8},
          reason: 'both dice are playable from the 13-point');

      await tap(g.pointRect(8).center); // 13/9 — the 4
      expect(painterOf(t).board.points[8], 1);
      expect(painterOf(t).selectedCheckerLocation, isNull,
          reason: 'the hop consumed the pickup');

      await tap(g.checkerCenter(8, 0, 1)); // pick the SAME checker up again
      expect(painterOf(t).selectedCheckerLocation, 8,
          reason: 'a re-tap on the landing point is a pickup, never a '
              'double-tap that gets eaten');
      expect(painterOf(t).highlightedDestinations, {7},
          reason: 'the 1 is still playable with this checker — the P0');
      expect(painterOf(t).board.points[8], 1, reason: 'nothing else moved');

      await tap(g.pointRect(7).center); // 9/8 — the 1
      expect(painterOf(t).board.points[7], 1);
      expect(painterOf(t).board.points[12], 1);
      expect(control.canConfirm, isTrue, reason: 'the turn is complete');
    });

    testWidgets('reverse die order: tap 13, tap 12, tap 12, tap 8', (t) async {
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      Future<void> tap(Offset o) async {
        await t.tapAt(r.topLeft + o);
        await t.pump();
      }

      await tap(g.checkerCenter(12, 1, 2));
      await tap(g.pointRect(11).center); // 13/12 — the 1
      expect(painterOf(t).board.points[11], 1);
      await tap(g.checkerCenter(11, 0, 1)); // pick it up again
      expect(painterOf(t).selectedCheckerLocation, 11);
      expect(painterOf(t).highlightedDestinations, {7});
      await tap(g.pointRect(7).center); // 12/8 — the 4
      expect(painterOf(t).board.points[7], 1);
      expect(control.canConfirm, isTrue);
    });

    testWidgets('a second checker from the SAME point still plays', (t) async {
      // 13/9 with one checker, then 13/12 with the other: two hops from one
      // point, which is the other reading of "the same pip".
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      Future<void> tap(Offset o) async {
        await t.tapAt(r.topLeft + o);
        await t.pump();
      }

      await tap(g.checkerCenter(12, 1, 2));
      await tap(g.pointRect(8).center); // 13/9
      await tap(g.checkerCenter(12, 0, 1)); // the remaining 13-point checker
      expect(painterOf(t).selectedCheckerLocation, 12);
      expect(painterOf(t).highlightedDestinations, contains(11));
      await tap(g.pointRect(11).center); // 13/12
      expect(control.canConfirm, isTrue);
      expect(painterOf(t).board.points[12], 0, reason: 'both checkers left');
    });

    testWidgets('the empty point behind a listed transit is NOT a source',
        (t) async {
      // `13/12 12/8` used to make the (empty) 12-point selectable, because a
      // permutation offered 12/8 as a first hop. Tapping it staged a phantom.
      await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      expect(painterOf(t).highlightedSources, isNot(contains(11)));
      await t.tapAt(r.topLeft + g.pointRect(11).center);
      await t.pump();
      expect(painterOf(t).selectedCheckerLocation, isNull);
      expect(painterOf(t).board, chainState().board,
          reason: 'no phantom hop staged');
    });

    testWidgets('bearing off: play the 5 first, then bring the checker off',
        (t) async {
      // All home, 5-1. Running one checker off the 6-point is listed as
      // `6/5 5/off`; the user plays the 5 first (6/1) and must still bear off.
      final pts = List<int>.filled(24, 0);
      pts[5] = 3;
      pts[2] = 6;
      pts[1] = 6;
      pts[23] = -15;
      final control = await mount(
        t,
        GameState.testState(
          board: BoardState(points: pts),
          turn: Player.white,
          phase: GamePhase.moving,
          dice: Dice(5, 1),
        ),
      );
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      Future<void> tap(Offset o) async {
        await t.tapAt(r.topLeft + o);
        await t.pump();
      }

      await tap(g.checkerCenter(5, 2, 3)); // the 6-point
      await tap(g.pointRect(0).center); // 6/1 — the 5
      expect(painterOf(t).board.points[0], 1);
      await tap(g.checkerCenter(0, 0, 1)); // pick that checker up again
      expect(painterOf(t).selectedCheckerLocation, 0);
      expect(painterOf(t).highlightedDestinations, contains(CheckerMove.off),
          reason: '1/off with the 1 completes the same play');
      await tap(g.offRect(Player.white).center);
      expect(control.canConfirm, isTrue);
    });
  });

  group('a press that slides is still a tap', () {
    /// Press at [at], slide [travel] pt sideways, release.
    Future<void> sloppyTap(WidgetTester t, Offset at, double travel) async {
      final gesture = await t.startGesture(at);
      await gesture.moveBy(Offset(travel, 0));
      await gesture.up();
      await t.pump();
    }

    // 18pt is Flutter's tap slop and 36pt its pan slop: the band between them was
    // the dead zone where a press was dropped by both recognisers.
    for (final travel in [0.0, 10.0, 19.0, 25.0, 35.0]) {
      testWidgets('${travel}pt of travel still enters the hop', (t) async {
        final control = await mount(t, chainState());
        final r = boardRect(t);
        final g = painterOf(t).geometry;

        await sloppyTap(t, r.topLeft + g.checkerCenter(12, 1, 2), travel);
        expect(painterOf(t).selectedCheckerLocation, 12,
            reason: 'the checker the finger came down on is picked up');

        await sloppyTap(t, r.topLeft + g.pointRect(8).center, travel);
        expect(painterOf(t).board.points[8], 1, reason: '13/9 was entered');
        expect(control.canUndo, isTrue);
      });
    }

    testWidgets('travelling past the pan threshold is a DRAG, not a tap',
        (t) async {
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      // 60pt sideways from the 13-point lands on nothing playable: the drag
      // snaps back, which is drag behaviour and not a lost tap.
      await sloppyTap(t, r.topLeft + g.checkerCenter(12, 1, 2), 60);
      expect(control.canUndo, isFalse);
      expect(painterOf(t).board, chainState().board);
    });

    testWidgets('with drag OFF a slide still taps its starting point',
        (t) async {
      await mount(t, chainState(), enableDrag: false);
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      await sloppyTap(t, r.topLeft + g.checkerCenter(12, 1, 2), 60);
      expect(painterOf(t).selectedCheckerLocation, 12);
    });
  });

  group('the double-tap detector can never eat a tap', () {
    testWidgets('a quick re-tap on the pickup still plays the higher die',
        (t) async {
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      final checker = r.topLeft + g.checkerCenter(12, 1, 2);
      await t.tapAt(checker);
      await t.pump();
      await t.tapAt(checker); // milliseconds later: a real double-tap
      await t.pump();
      expect(painterOf(t).board.points[8], 1, reason: '13/9 — the 4');
      expect(painterOf(t).board.points[11], 0, reason: 'not the 1');
      expect(control.canUndo, isTrue);
    });

    testWidgets('a destination tap is never claimed as the second tap',
        (t) async {
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      await t.tapAt(r.topLeft + g.checkerCenter(12, 1, 2));
      await t.pump();
      // The 1's destination is the very next column, well inside the 22pt
      // forgiveness radius of nothing but itself; tap its inner edge.
      final edge = Offset(g.pointRect(11).center.dx, g.pointRect(11).bottom - 2);
      await t.tapAt(r.topLeft + edge);
      await t.pump();
      expect(painterOf(t).board.points[11], 1, reason: 'the tapped 1 was played');
      expect(painterOf(t).board.points[8], 0, reason: 'not the 4');
      expect(control.canUndo, isTrue);
    });

    testWidgets('a dead checker tapped twice quickly reports twice and moves '
        'nothing', (t) async {
      // White's 7-point (index 6) is blocked on both dice, so no quick hop can
      // apply: the second tap must fall through to the hint, not be swallowed.
      final pts = List<int>.filled(24, 0);
      pts[6] = 2;
      pts[3] = 5;
      pts[2] = 5;
      pts[1] = 3;
      pts[0] = -2;
      pts[5] = -2;
      pts[4] = -2;
      pts[23] = -9;
      final state = GameState.testState(
        board: BoardState(points: pts),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(2, 1),
      );
      var reports = 0;
      await mount(t, state, onNoLegalSourceTap: (_) => reports++);
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      final dead = r.topLeft + g.checkerCenter(6, 1, 2);
      await t.tapAt(dead);
      await t.pump();
      await t.tapAt(dead);
      await t.pump();
      expect(reports, 2, reason: 'each dead tap is answered');
      expect(painterOf(t).board, state.board);
    });

    testWidgets('slow taps on a pickup deselect instead of playing a hop',
        (t) async {
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      final checker = r.topLeft + g.checkerCenter(12, 1, 2);
      await t.tapAt(checker);
      await t.pump();
      // Burn real wall-clock time so the second tap falls outside the 300ms
      // window (the detector reads DateTime.now(), not the test clock).
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 360)));
      await t.tapAt(checker);
      await t.pump();
      expect(painterOf(t).selectedCheckerLocation, isNull, reason: 'deselected');
      expect(control.canUndo, isFalse, reason: 'no hop was played');
    });

    testWidgets('a hop then an immediate re-tap of the landing point never '
        'double-taps', (t) async {
      // The arming rule: only a tap that SELECTED a source arms the detector, so
      // the tap that staged a hop cannot be the first half of a pair.
      final control = await mount(t, chainState());
      final r = boardRect(t);
      final g = painterOf(t).geometry;
      await t.tapAt(r.topLeft + g.checkerCenter(12, 1, 2));
      await t.pump();
      await t.tapAt(r.topLeft + g.pointRect(8).center); // 13/9 staged
      await t.pump();
      await t.tapAt(r.topLeft + g.checkerCenter(8, 0, 1)); // instantly after
      await t.pump();
      expect(painterOf(t).selectedCheckerLocation, 8);
      expect(control.canConfirm, isFalse, reason: 'only one hop is in');
      expect(painterOf(t).board.points[7], 0,
          reason: 'no second hop was played behind the user’s back');
    });
  });

  testWidgets('the whole turn also goes in by DRAG, twice with one checker',
      (t) async {
    final control = await mount(t, chainState());
    final r = boardRect(t);
    final g = painterOf(t).geometry;
    // A real drag arrives as many small moves; the pan claims it a few pt in,
    // which is where onPanStart reads the lifted checker from.
    Future<void> drag(Offset from, Offset to) async {
      final gesture = await t.startGesture(r.topLeft + from);
      const steps = 12;
      for (var i = 1; i <= steps; i++) {
        await gesture.moveTo(r.topLeft + Offset.lerp(from, to, i / steps)!);
      }
      await gesture.up();
      await t.pump();
    }

    await drag(g.checkerCenter(12, 1, 2), g.pointRect(8).center); // 13/9
    expect(painterOf(t).board.points[8], 1);
    await drag(g.checkerCenter(8, 0, 1), g.pointRect(7).center); // 9/8
    expect(painterOf(t).board.points[7], 1);
    expect(control.canConfirm, isTrue);
  });

  testWidgets('gesture wiring: the tap recogniser tolerates travel', (t) async {
    // Guards the mechanism itself, so a future refactor back to GestureDetector
    // (whose tap slop is not configurable) cannot silently reopen the dead zone.
    await mount(t, chainState());
    final raw = t.widget<RawGestureDetector>(find
        .ancestor(
          of: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is BoardPainter),
          matching: find.byType(RawGestureDetector),
        )
        .first);
    final tap = raw.gestures[TapGestureRecognizer];
    expect(tap, isNotNull, reason: 'taps are wired by hand');
    final recognizer =
        tap!.constructor() as TapGestureRecognizer; // ignore: avoid_dynamic_calls
    addTearDown(recognizer.dispose);
    expect(recognizer.preAcceptSlopTolerance, isNull);
    expect(recognizer.postAcceptSlopTolerance, isNull);
    expect(raw.gestures.containsKey(PanGestureRecognizer), isTrue,
        reason: 'drag is enabled, so the pan claims real drags');
  });
}
