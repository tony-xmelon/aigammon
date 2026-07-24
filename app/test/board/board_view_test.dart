import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_view.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 600);

/// Wraps [child] so it occupies exactly [_size] with its top-left at the global
/// origin, so a board-local geometry offset equals a global tap offset. The
/// surface is set to [_size] and a same-size SizedBox anchors the board at
/// (0,0); AspectRatio 4:3 within an 800x600 box yields exactly 800x600.
Widget _harness(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _size.width,
            height: _size.height,
            child: child,
          ),
        ),
      ),
    );

/// The BoardView's painter (the only [BoardPainter] in the tree).
BoardPainter _painterOf(WidgetTester t) {
  final cp = t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((c) => c.painter is BoardPainter);
  return cp.painter as BoardPainter;
}

/// The same geometry the widget computes for an 800x600 board.
final _geometry = BoardGeometry(_size, whiteAtBottom: true);

void main() {
  // The golden-point opening: White plays 3-1 as 8/5 6/5.
  // 8-point == index 7, 6-point == index 5, 5-point == index 4.
  final goldenState =
      GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));
  final goldenMove = Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]);

  Future<void> tapPoint(WidgetTester t, int index) async {
    await t.tapAt(_geometry.pointRect(index).center);
    await t.pump();
  }

  testWidgets('geometry assumption: interactive board is exactly 800x600',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (_) {},
    )));
    expect(_painterOf(t).geometry.size, _size);
  });

  testWidgets('golden-point entry commits the canonical move', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    Move? committed;
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (m) => committed = m,
    )));

    // Initially all legal sources are highlighted, nothing selected.
    expect(_painterOf(t).selectedSource, isNull);
    expect(_painterOf(t).highlightedSources, contains(7));

    // Pick up the 8-point: destinations for its two dice light up.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedSource, 7);
    expect(_painterOf(t).highlightedDestinations, contains(4)); // die 3
    expect(_painterOf(t).highlightedSources, isEmpty);

    // Drop on the 5-point → hop 8/5 recorded, selection cleared.
    await tapPoint(t, 4);
    expect(_painterOf(t).selectedSource, isNull);

    // Pick up the 6-point and drop on the 5-point → hop 6/5.
    await tapPoint(t, 5);
    expect(_painterOf(t).selectedSource, 5);
    await tapPoint(t, 4);

    // Confirm is now enabled; committing yields the canonical golden move.
    final confirm = find.widgetWithText(FilledButton, 'Confirm');
    expect(_isEnabled(t, confirm), isTrue);
    await t.tap(confirm);
    await t.pump();
    expect(committed, isNotNull);
    expect(committed!.sameAs(goldenMove), isTrue,
        reason: 'committed $committed should equal $goldenMove');
  });

  testWidgets('undo reverts the preview board', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (_) {},
    )));

    // One hop 8/5: preview diverges from the base board.
    await tapPoint(t, 7);
    await tapPoint(t, 4);
    expect(_painterOf(t).board, isNot(goldenState.board));

    // Undo removes the hop; preview returns to the base board.
    await t.tap(find.widgetWithText(TextButton, 'Undo'));
    await t.pump();
    expect(_painterOf(t).board, goldenState.board);
  });

  testWidgets('re-tapping a source deselects; tapping empty space clears',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (_) {},
    )));

    await tapPoint(t, 7);
    expect(_painterOf(t).selectedSource, 7);
    // Re-tap the same source → deselect.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedSource, isNull);

    // Select again, then tap the empty middle band (null location) → clear.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedSource, 7);
    await t.tapAt(Offset(_size.width * 0.1, _size.height / 2));
    await t.pump();
    expect(_painterOf(t).selectedSource, isNull);
  });

  testWidgets('a dance shows Pass and commits Move.none', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    // White on the bar, Black's home fully closed (from game_state_test).
    final pts = List<int>.filled(24, 0);
    for (var i = 18; i < 24; i++) {
      pts[i] = -2;
    }
    pts[0] = -3;
    pts[12] = 14;
    final danceState = GameState.testState(
      board: BoardState(points: pts, whiteBar: 1),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(6, 2),
    );
    expect(danceState.legalMoves, isEmpty);

    Move? committed;
    await t.pumpWidget(_harness(BoardView(
      state: danceState,
      interactive: true,
      onMoveCommitted: (m) => committed = m,
    )));

    final pass = find.text('No moves — pass');
    expect(pass, findsOneWidget);
    // No Confirm/Undo controls during a dance.
    expect(find.text('Confirm'), findsNothing);
    expect(find.text('Undo'), findsNothing);

    await t.tap(pass);
    await t.pump();
    expect(committed, isNotNull);
    expect(committed!.checkerMoves, isEmpty); // Move.none
  });

  testWidgets('non-interactive: no overlay, taps do nothing, no preview',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    Move? committed;
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: false,
      onMoveCommitted: (m) => committed = m,
    )));

    // No control buttons at all.
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);

    // Board is painted as-is: no highlights, no selection.
    final painter = _painterOf(t);
    expect(painter.board, goldenState.board);
    expect(painter.highlightedSources, isEmpty);
    expect(painter.highlightedDestinations, isEmpty);
    expect(painter.selectedSource, isNull);

    // Taps are ignored (no GestureDetector) — nothing changes or commits.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedSource, isNull);
    expect(committed, isNull);
  });

  testWidgets('a new game state resets in-progress entry', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final stateA = goldenState;
    final stateB =
        GameState.opening(firstPlayer: Player.white, openingDice: Dice(6, 4));
    expect(stateA == stateB, isFalse);

    Widget view(GameState s) => BoardView(
          state: s,
          interactive: true,
          onMoveCommitted: (_) {},
        );

    await t.pumpWidget(_harness(view(stateA)));
    // Enter a hop under state A.
    await tapPoint(t, 7);
    await tapPoint(t, 4);
    expect(_painterOf(t).board, isNot(stateA.board));

    // Pump a DIFFERENT state → builder rebuilt, chosen hops dropped, so the
    // preview equals state B's untouched board.
    await t.pumpWidget(_harness(view(stateB)));
    await t.pump();
    expect(_painterOf(t).board, stateB.board);
    expect(_painterOf(t).selectedSource, isNull);
  });
}

/// Whether the button found by [finder] is currently enabled.
bool _isEnabled(WidgetTester t, Finder finder) {
  final w = t.widget(finder);
  if (w is FilledButton) return w.onPressed != null;
  if (w is TextButton) return w.onPressed != null;
  return false;
}
