import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_view.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 600);

/// The same 800x600 geometry the widget computes, anchored at the origin (see
/// [_harness]), so a geometry offset is also a global tap offset.
final _geometry = BoardGeometry(_size, whiteAtBottom: true);

Widget _harness(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: _size.width, height: _size.height, child: child),
        ),
      ),
    );

BoardPainter _painterOf(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .firstWhere((c) => c.painter is BoardPainter)
    .painter as BoardPainter;

Future<void> _tapPoint(WidgetTester t, int index) async {
  await t.tapAt(_geometry.pointRect(index).center);
  await t.pump();
}

/// A window long enough that two taps issued back-to-back by the tester always
/// pair up, however slowly the machine runs.
const _forcedDoubleTap = Duration(seconds: 30);

/// White to play 2-1 with two checkers on the 7-point (index 6) and the rest at
/// home; Black holds an anchor on White's 1-point (index 0).
///
/// [blockSeven] additionally gives Black the 5- and 6-points (indices 4 and 5),
/// which is what makes the 7-point checkers completely immobile — the shape
/// behind the reported "why am I not able to move the 7?" confusion.
GameState _sevenPointState({required bool blockSeven}) {
  final pts = List<int>.filled(24, 0);
  pts[6] = 2; // White's 7-point — the checkers in question
  pts[3] = 5;
  pts[2] = 5;
  pts[1] = 3; // 15 White checkers in total
  pts[0] = -2; // Black's anchor on White's 1-point
  if (blockSeven) {
    pts[5] = -2; // blocks 7/6 (the 1)
    pts[4] = -2; // blocks 7/5 (the 2)
    pts[23] = -9;
  } else {
    pts[23] = -13;
  }
  return GameState.testState(
    board: BoardState(points: pts),
    turn: Player.white,
    phase: GamePhase.moving,
    dice: Dice(2, 1),
  );
}

void main() {
  final goldenState =
      GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  group('played dice read as spent', () {
    testWidgets('staging a hop dims THAT die; undo brings it back', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      await t.pumpWidget(_harness(BoardView(
        state: goldenState, // 3-1: die1 = 3, die2 = 1
        interactive: true,
        onMoveCommitted: (_) {},
        entryControl: control,
      )));

      expect(_painterOf(t).usedDiceSlots, isEmpty,
          reason: 'nothing staged: both dice are live');

      // 8/5 spends the 3 — slot 0 only.
      await _tapPoint(t, 7);
      await _tapPoint(t, 4);
      expect(_painterOf(t).usedDiceSlots, {0});

      // 6/5 spends the 1 as well.
      await _tapPoint(t, 5);
      await _tapPoint(t, 4);
      expect(_painterOf(t).usedDiceSlots, {0, 1});

      // Undo returns the last die to full brightness.
      control.undo();
      await t.pump();
      expect(_painterOf(t).usedDiceSlots, {0});
      control.undo();
      await t.pump();
      expect(_painterOf(t).usedDiceSlots, isEmpty);
    });

    testWidgets('doubles dim progressively: die 1 at two hops, die 2 at four',
        (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final doublesState = GameState.testState(
        board: BoardState.initial(),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(2, 2),
      );
      await t.pumpWidget(_harness(BoardView(
        state: doublesState,
        interactive: true,
        onMoveCommitted: (_) {},
      )));

      // Four times 13/11 (index 12 → 10).
      for (var hop = 1; hop <= 4; hop++) {
        await _tapPoint(t, 12);
        await _tapPoint(t, 10);
        final expected = <int>{if (hop >= 2) 0, if (hop >= 4) 1};
        expect(_painterOf(t).usedDiceSlots, expected,
            reason: 'after $hop hop(s) of a doubles turn');
      }
    });

    testWidgets("the waiting player's pair is never marked as spent", (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_harness(BoardView(
        state: goldenState,
        interactive: true,
        onMoveCommitted: (_) {},
        whiteDice: Dice(3, 1),
        blackDice: Dice(6, 5),
        activeDiceSide: Player.white,
      )));
      await _tapPoint(t, 7);
      await _tapPoint(t, 4);
      // The slot set is the MOVER's; the painter gates the dimming on the ACTIVE
      // pair, so Black's memento pair keeps its own (waiting) opacity.
      expect(_painterOf(t).usedDiceSlots, {0});
      expect(_painterOf(t).activeDiceSide, Player.white);
    });
  });

  group('double-tap plays a hop', () {
    testWidgets('a double-tap on a checker plays the HIGHER die', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      await t.pumpWidget(_harness(BoardView(
        state: goldenState, // 3-1; the 8-point can play either die
        interactive: true,
        onMoveCommitted: (_) {},
        entryControl: control,
        doubleTapWindow: _forcedDoubleTap,
      )));

      await _tapPoint(t, 7);
      await _tapPoint(t, 7);

      final board = _painterOf(t).board;
      expect(board.points[4], 1, reason: '8/5 played — the 3, not the 1');
      expect(board.points[6], 0, reason: '8/7 (the 1) was NOT played');
      expect(board.points[7], 2, reason: 'exactly one checker left the 8-point');
      expect(control.canUndo, isTrue);
      expect(_painterOf(t).selectedCheckerLocation, isNull,
          reason: 'the hop consumed the pickup');
      expect(_painterOf(t).usedDiceSlots, {0});
    });

    testWidgets('a single tap still selects instantly (no recogniser delay)',
        (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_harness(BoardView(
        state: goldenState,
        interactive: true,
        onMoveCommitted: (_) {},
        // The production default: even so, the FIRST tap must resolve on the
        // very next frame rather than waiting out the double-tap window.
      )));

      await t.tapAt(_geometry.pointRect(7).center);
      await t.pump();
      expect(_painterOf(t).selectedCheckerLocation, 7);
      expect(_painterOf(t).board, goldenState.board,
          reason: 'a single tap picks up; it does not move anything');
    });

    testWidgets('completing a hop and starting the next from the SAME point is '
        'not a double-tap', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      // 2-2 from the opening: 13/11 then 11/9 runs one checker onward, so the
      // landing of the first hop is the source of the second.
      await t.pumpWidget(_harness(BoardView(
        state: GameState.testState(
          board: BoardState.initial(),
          turn: Player.white,
          phase: GamePhase.moving,
          dice: Dice(2, 2),
        ),
        interactive: true,
        onMoveCommitted: (_) {},
        entryControl: control,
        doubleTapWindow: _forcedDoubleTap,
      )));

      await _tapPoint(t, 12); // pick up the 13-point
      await _tapPoint(t, 10); // land on the 11-point (hop 1)
      await _tapPoint(t, 10); // pick it up again — a PICKUP, not a double-tap
      expect(_painterOf(t).selectedCheckerLocation, 10,
          reason: 'the second tap on the landing point must select it');
      expect(control.canUndo, isTrue);
      expect(_painterOf(t).board.points[10], 1,
          reason: 'still exactly one hop played');
    });

    testWidgets('a quick tap on an ADJACENT DESTINATION plays that die, not the '
        'double-tap hop', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      // White has a blot on the 9-point (index 8) which 6-1 can play either way:
      // index 2 (the 6) or the NEIGHBOURING column index 7 (the 1). Black owns
      // index 1, so nothing can continue from index 7 — index 7 is therefore a
      // destination and NOT itself a source, which is exactly the case where
      // tap-forgiveness resolves a tap on the 1's triangle back to the blot. A
      // naive double-tap detector then claims the tap and plays the 6 instead.
      final pts = List<int>.filled(24, 0);
      pts[8] = 1; // the blot
      pts[12] = 1; // keeps White off the bear-off (so index 0 offers nothing)
      pts[0] = 13;
      pts[1] = -2; // Black blocks 8/2, so no hop continues from index 7
      pts[23] = -13;
      final state = GameState.testState(
        board: BoardState(points: pts),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(6, 1),
      );
      final sources = MoveBuilder.forState(state).selectableSources;
      expect(sources, contains(8), reason: 'precondition: the blot is a source');
      expect(sources, isNot(contains(7)),
          reason: 'precondition: the 1-destination is NOT itself a source');

      await t.pumpWidget(_harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: (_) {},
        entryControl: control,
        doubleTapWindow: _forcedDoubleTap,
      )));

      // Pick the blot up; both destinations light.
      final blot = _geometry.checkerCenter(8, 0, 1);
      await t.tapAt(blot);
      await t.pump();
      expect(_painterOf(t).selectedCheckerLocation, 8);
      expect(_painterOf(t).highlightedDestinations, {2, 7});

      // Tap the 1-destination's triangle a hair inside its edge — the nearest
      // point of it to the blot.
      final edge = Offset(_geometry.pointRect(7).left + 1, blot.dy);
      expect(_geometry.locationAt(edge), 7,
          reason: 'precondition: the raw hit really is the destination');
      await t.tapAt(edge);
      await t.pump();

      final board = _painterOf(t).board;
      expect(board.points[7], 1, reason: 'the tapped 1 (9/8) was played');
      expect(board.points[2], 0, reason: 'the 6 (9/3) was NOT played');
      expect(_painterOf(t).usedDiceSlots, {1},
          reason: 'die2 (the 1) is the spent one');
    });

    testWidgets('double-tapping a dead checker reports it instead of moving',
        (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final state = _sevenPointState(blockSeven: true);
      var calls = 0;
      await t.pumpWidget(_harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: (_) {},
        onNoLegalSourceTap: (_) => calls++,
        doubleTapWindow: _forcedDoubleTap,
      )));

      await _tapPoint(t, 6);
      await _tapPoint(t, 6);
      expect(_painterOf(t).board, state.board, reason: 'nothing moved');
      expect(calls, 2, reason: 'each dead tap is answered');
    });
  });

  group('tapping a checker that cannot move', () {
    testWidgets('reports once, with no staged move', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final state = _sevenPointState(blockSeven: true);
      final staged = <bool>[];
      await t.pumpWidget(_harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: (_) {},
        onNoLegalSourceTap: staged.add,
      )));

      await _tapPoint(t, 6);
      expect(staged, [false]);
      expect(_painterOf(t).selectedCheckerLocation, isNull,
          reason: 'a dead checker is not picked up');
      expect(_painterOf(t).highlightedSources, isNotEmpty,
          reason: 'the tap changes nothing: the real sources stay ringed');
      expect(_painterOf(t).highlightedDestinations, isEmpty);
    });

    testWidgets('a legal source is silent', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final staged = <bool>[];
      await t.pumpWidget(_harness(BoardView(
        state: _sevenPointState(blockSeven: true),
        interactive: true,
        onMoveCommitted: (_) {},
        onNoLegalSourceTap: staged.add,
      )));

      await _tapPoint(t, 3); // a real source with 2-1
      expect(_painterOf(t).selectedCheckerLocation, 3);
      expect(staged, isEmpty);
    });

    testWidgets("the opponent's checkers and empty felt stay silent", (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final staged = <bool>[];
      await t.pumpWidget(_harness(BoardView(
        state: _sevenPointState(blockSeven: true),
        interactive: true,
        onMoveCommitted: (_) {},
        onNoLegalSourceTap: staged.add,
      )));

      await _tapPoint(t, 23); // Black's stack
      await t.tapAt(Offset(_size.width * 0.1, _size.height / 2)); // empty felt
      await t.pump();
      expect(staged, isEmpty);
    });

    testWidgets('with a partial move staged, the report says so', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final staged = <bool>[];
      await t.pumpWidget(_harness(BoardView(
        state: _sevenPointState(blockSeven: true),
        interactive: true,
        onMoveCommitted: (_) {},
        onNoLegalSourceTap: staged.add,
      )));

      await _tapPoint(t, 3); // 4/2 — spends the 2
      await _tapPoint(t, 1);
      await _tapPoint(t, 6); // still dead
      expect(staged, [true], reason: 'the caller can now suggest Undo');
    });
  });

  group('the 7-point investigation (regression guard)', () {
    test('with the 5- and 6-points open, the 7-point IS offered', () {
      final state = _sevenPointState(blockSeven: false);
      final builder = MoveBuilder.forState(state);
      expect(builder.selectableSources, contains(6),
          reason: 'both 7/5 (the 2) and 7/6 (the 1) are available');
      expect(builder.destinationsFor(6), containsAll(<int>{4, 5}));
    });

    test('spending the 2 elsewhere can legitimately RETIRE the 7-point', () {
      // Black owns the 6-point (index 5), so the 7-point can only ever play the
      // 2. Once the 2 has gone somewhere else, no full legal move still moves
      // that checker — the maximal-play rule, not a bug.
      final pts = List<int>.filled(24, 0);
      pts[6] = 2;
      pts[3] = 5;
      pts[2] = 5;
      pts[1] = 3;
      pts[0] = -2;
      pts[5] = -2; // blocks 7/6 (the 1) only
      pts[23] = -11;
      final state = GameState.testState(
        board: BoardState(points: pts),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(2, 1),
      );

      final builder = MoveBuilder.forState(state);
      expect(builder.selectableSources, contains(6),
          reason: 'before anything is staged the 7-point can play the 2');

      // Play the 2 as 4/2 (index 3 → 1) instead.
      builder.addHop(3, 1);
      expect(builder.selectableSources, isNot(contains(6)),
          reason: 'only the 1 is left, and 7/6 is blocked — correct behaviour');
      expect(builder.selectableSources, isNotEmpty,
          reason: 'other checkers can still play the 1');

      // Undo restores the offer: nothing was lost, it was a consequence of the
      // hop the user chose. This is exactly what the new hint tells them.
      builder.undoHop();
      expect(builder.selectableSources, contains(6));
    });

    test('with both landing points blocked the 7-point is never a source', () {
      final builder = MoveBuilder.forState(_sevenPointState(blockSeven: true));
      expect(builder.selectableSources, isNot(contains(6)));
      expect(builder.selectableSources, isNotEmpty,
          reason: 'the turn is playable — just not with those checkers');
    });
  });
}
