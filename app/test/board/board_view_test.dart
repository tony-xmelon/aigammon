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

/// Mounts a non-interactive [BoardView] wired for move animation, forcing
/// `disableAnimations: false` so the ticker runs under test.
Widget _animHarness(
  GameState state,
  ValueNotifier<MoveEvent?> lastMove, {
  Duration animationDuration = const Duration(milliseconds: 150),
}) =>
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: false),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: _size.width,
              height: _size.height,
              child: BoardView(
                state: state,
                interactive: false,
                onMoveCommitted: (_) {},
                lastMove: lastMove,
                animationDuration: animationDuration,
              ),
            ),
          ),
        ),
      ),
    );

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
    final control = BoardEntryController();
    addTearDown(control.dispose);
    Move? committed;
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (m) => committed = m,
      entryControl: control,
    )));

    // Initially all legal sources are highlighted, nothing selected.
    expect(_painterOf(t).selectedCheckerLocation, isNull);
    expect(_painterOf(t).highlightedSources, contains(7));

    // Pick up the 8-point: destinations for its two dice light up.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedCheckerLocation, 7);
    expect(_painterOf(t).highlightedDestinations, contains(4)); // die 3
    expect(_painterOf(t).highlightedSources, isEmpty);

    // Drop on the 5-point → hop 8/5 recorded, selection cleared.
    await tapPoint(t, 4);
    expect(_painterOf(t).selectedCheckerLocation, isNull);

    // Pick up the 6-point and drop on the 5-point → hop 6/5.
    await tapPoint(t, 5);
    expect(_painterOf(t).selectedCheckerLocation, 5);
    await tapPoint(t, 4);

    // Confirm is now enabled (surfaced via the entry controller); committing
    // yields the canonical golden move.
    expect(control.canConfirm, isTrue);
    control.confirm();
    await t.pump();
    expect(committed, isNotNull);
    expect(committed!.sameAs(goldenMove), isTrue,
        reason: 'committed $committed should equal $goldenMove');
  });

  testWidgets('undo reverts the preview board', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (_) {},
      entryControl: control,
    )));

    // One hop 8/5: preview diverges from the base board, Undo becomes live.
    await tapPoint(t, 7);
    await tapPoint(t, 4);
    expect(_painterOf(t).board, isNot(goldenState.board));
    expect(control.canUndo, isTrue);

    // Undo removes the hop; preview returns to the base board.
    control.undo();
    await t.pump();
    expect(_painterOf(t).board, goldenState.board);
    expect(control.canUndo, isFalse);
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
    expect(_painterOf(t).selectedCheckerLocation, 7);
    // Re-tap the same source → deselect.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedCheckerLocation, isNull);

    // Select again, then tap the empty middle band (null location) → clear.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedCheckerLocation, 7);
    await t.tapAt(Offset(_size.width * 0.1, _size.height / 2));
    await t.pump();
    expect(_painterOf(t).selectedCheckerLocation, isNull);
  });

  testWidgets('bar entry: the bar is a selectable source and its checker '
      'highlights when selected', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    // White has a checker on the bar; Black's home (White's entry board,
    // indices 18..23) is open, so entry with 6-4 is legal.
    final pts = List<int>.filled(24, 0);
    pts[0] = 14; // White's other checkers at home
    pts[23] = -15; // Black stacked off White's entry board
    final barState = GameState.testState(
      board: BoardState(points: pts, whiteBar: 1),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(6, 4),
    );
    expect(barState.legalMoves, isNotEmpty);

    await t.pumpWidget(_harness(BoardView(
      state: barState,
      interactive: true,
      onMoveCommitted: (_) {},
    )));

    // The bar is offered as a selectable source; the painter knows the mover so
    // it can ring the correct bar half.
    final painter = _painterOf(t);
    expect(painter.highlightedSources, contains(CheckerMove.bar));
    expect(painter.movingPlayer, Player.white);
    expect(painter.selectedCheckerLocation, isNull);

    // Tapping the beaten checker on the bar selects it (the beaten-chip fix).
    await t.tapAt(_geometry.barCheckerCenter(Player.white, 0, 1));
    await t.pump();
    expect(_painterOf(t).selectedCheckerLocation, CheckerMove.bar);
    // Its entry destinations now light up.
    expect(_painterOf(t).highlightedDestinations, isNotEmpty);
  });

  testWidgets('forgiving tap: a near-miss selects the source; a far tap does not',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (_) {},
    )));

    final r = _geometry.checkerRadius;
    // Top checker of the 8-point (index 7 holds 3 White checkers in the opening).
    final anchor = _geometry.checkerCenter(7, 2, 3);

    // A tap 1.5r off the checker centre — landing OUTSIDE the point's own hit
    // region, over the neighbouring (index 8) column which is NOT a selectable
    // source — is forgiven to the nearest source checker and selects it.
    await t.tapAt(anchor + Offset(-1.5 * r, 0));
    await t.pump();
    expect(_painterOf(t).selectedCheckerLocation, 7);

    // Clear (tap the empty middle band), then tap 3r away: too far, no selection.
    await t.tapAt(Offset(_size.width * 0.2, _size.height * 0.5));
    await t.pump();
    expect(_painterOf(t).selectedCheckerLocation, isNull);
    await t.tapAt(anchor + Offset(-3.0 * r, 0));
    await t.pump();
    expect(_painterOf(t).selectedCheckerLocation, isNull);
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

    final control = BoardEntryController();
    addTearDown(control.dispose);
    Move? committed;
    await t.pumpWidget(_harness(BoardView(
      state: danceState,
      interactive: true,
      onMoveCommitted: (m) => committed = m,
      entryControl: control,
    )));

    // The controller reports a dance with no confirmable move; the board itself
    // draws no controls (they live in the external bar).
    expect(control.isDance, isTrue);
    expect(control.canConfirm, isFalse);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);

    control.pass();
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
    expect(painter.selectedCheckerLocation, isNull);

    // Taps are ignored (no GestureDetector) — nothing changes or commits.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedCheckerLocation, isNull);
    expect(committed, isNull);
  });

  testWidgets('external move stages the play; Confirm commits the canonical move',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final external = ValueNotifier<Move?>(null);
    addTearDown(external.dispose);
    final control = BoardEntryController();
    addTearDown(control.dispose);
    Move? committed;
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (m) => committed = m,
      externalMove: external,
      entryControl: control,
    )));

    // Nothing staged yet: base board, Confirm disabled.
    expect(_painterOf(t).board, goldenState.board);
    expect(control.canConfirm, isFalse);

    // Fire the full golden move: it is staged (preview applied, Confirm on) but
    // NOT committed.
    external.value = goldenMove;
    await t.pump();
    expect(_painterOf(t).board, isNot(goldenState.board),
        reason: 'staged move should show the play applied in the preview');
    expect(_painterOf(t).selectedCheckerLocation, isNull);
    expect(committed, isNull, reason: 'staging must not auto-commit');
    expect(control.canConfirm, isTrue);

    // Confirm commits the SAME canonical move.
    control.confirm();
    await t.pump();
    expect(committed, isNotNull);
    expect(committed!.sameAs(goldenMove), isTrue,
        reason: 'committed $committed should equal $goldenMove');
  });

  testWidgets('a stale/illegal external move is ignored without crashing',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final external = ValueNotifier<Move?>(null);
    addTearDown(external.dispose);
    final control = BoardEntryController();
    addTearDown(control.dispose);
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (_) {},
      externalMove: external,
      entryControl: control,
    )));

    // A bogus move never offered by the builder: point 2 is empty in the
    // opening, so 2/1 is not a selectable source (addHop throws ArgumentError).
    external.value = Move(const [CheckerMove(2, 1)]);
    await t.pump();

    // Builder reset, no crash: base board, nothing selected, Confirm disabled,
    // and the legal sources are still offered for fresh entry.
    expect(_painterOf(t).board, goldenState.board);
    expect(_painterOf(t).selectedCheckerLocation, isNull);
    expect(control.canConfirm, isFalse);
    expect(_painterOf(t).highlightedSources, contains(7));
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
    expect(_painterOf(t).selectedCheckerLocation, isNull);
  });

  // --- Move animation --------------------------------------------------------

  // Post-move fixtures shared by the animation tests: White plays the golden
  // 3-1, leaving a board distinct from the pre-move opening.
  final postBoard = goldenState.board.applyMove(Player.white, goldenMove);
  final postState = GameState.testState(
    board: postBoard,
    turn: Player.black,
    phase: GamePhase.awaitingRoll,
  );

  testWidgets('mid-animation shows a travelling overlay checker', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<MoveEvent?>(null);
    addTearDown(lastMove.dispose);

    // Mount PRE-move, then fire the move (the controller fires lastMove BEFORE
    // notifying, so state is still pre-move at fire time) and rebuild POST-move.
    await t.pumpWidget(_animHarness(goldenState, lastMove));
    expect(_painterOf(t).overlayChecker, isNull);
    lastMove.value = MoveEvent(Player.white, goldenMove);
    await t.pumpWidget(_animHarness(postState, lastMove));

    // 75ms into the 300ms (2 hops × 150ms) travel: an overlay checker is drawn
    // and the painted board is NOT yet the post-move board.
    await t.pump(const Duration(milliseconds: 75));
    expect(_painterOf(t).overlayChecker, isNotNull);
    expect(_painterOf(t).board, isNot(postBoard));

    await t.pumpAndSettle(); // let the ticker finish before teardown
  });

  testWidgets('animation completes to the post-move board with no overlay',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<MoveEvent?>(null);
    addTearDown(lastMove.dispose);

    await t.pumpWidget(_animHarness(goldenState, lastMove));
    lastMove.value = MoveEvent(Player.white, goldenMove);
    await t.pumpWidget(_animHarness(postState, lastMove));

    // After settling, the overlay is gone and the post-move board is shown.
    await t.pumpAndSettle();
    expect(_painterOf(t).overlayChecker, isNull);
    expect(_painterOf(t).board, postBoard);
  });

  testWidgets('Duration.zero disables animation: post board snaps in',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<MoveEvent?>(null);
    addTearDown(lastMove.dispose);

    await t.pumpWidget(
        _animHarness(goldenState, lastMove, animationDuration: Duration.zero));
    lastMove.value = MoveEvent(Player.white, goldenMove);
    await t.pumpWidget(
        _animHarness(postState, lastMove, animationDuration: Duration.zero));
    await t.pump();

    // No animation ever ran: no overlay, board is immediately post-move.
    expect(_painterOf(t).overlayChecker, isNull);
    expect(_painterOf(t).board, postBoard);
  });

  testWidgets('entry controller reports active only in the moving phase',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);

    // Non-interactive: no entry is active.
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: false,
      onMoveCommitted: (_) {},
      entryControl: control,
    )));
    expect(control.active, isFalse);

    // Interactive moving phase: entry becomes active, nothing entered yet.
    await t.pumpWidget(_harness(BoardView(
      state: goldenState,
      interactive: true,
      onMoveCommitted: (_) {},
      entryControl: control,
    )));
    await t.pump();
    expect(control.active, isTrue);
    expect(control.canUndo, isFalse);
    expect(control.canConfirm, isFalse);
    expect(control.isDance, isFalse);
  });
}
