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

  // --- Combined-move taps ----------------------------------------------------

  Widget viewWith(
    GameState state, {
    required BoardInteractionOptions options,
    BoardEntryController? control,
    ValueChanged<Move>? onCommitted,
  }) =>
      _harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: onCommitted ?? (_) {},
        entryControl: control,
        interactionOptions: options,
      ));

  testWidgets('combined tap: one tap on a chained landing enters the whole '
      'chain (2 hops) and shows dimmer highlights', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    Move? committed;
    await t.pumpWidget(viewWith(goldenState,
        options: const BoardInteractionOptions(enableCombinedTaps: true),
        control: control,
        onCommitted: (m) => committed = m));

    // Pick up a back checker (24-point, index 23). Its direct singles are 22
    // and 20; the combined landing (running both dice with one checker) is 19.
    await tapPoint(t, 23);
    expect(_painterOf(t).selectedCheckerLocation, 23);
    expect(_painterOf(t).highlightedDestinations, containsAll(<int>[22, 20]));
    expect(_painterOf(t).combinedDestinations, contains(19),
        reason: 'the combined landing is highlighted (dimmer variant)');
    expect(_painterOf(t).combinedDestinations,
        isNot(anyElement(isIn(_painterOf(t).highlightedDestinations))),
        reason: 'combined and direct highlight sets are disjoint');

    // ONE tap on the chained landing enters BOTH hops: for a 3-1 that is the
    // whole turn, so Confirm turns on (chosenHops == 2).
    await tapPoint(t, 19);
    expect(_painterOf(t).selectedCheckerLocation, isNull);
    expect(control.canConfirm, isTrue,
        reason: 'a two-hop chain is a complete 3-1 turn');

    // The preview shows one back checker having run 24 -> 19 (the intermediate
    // points 22/20 are untouched — a single checker moved through).
    final preview = _painterOf(t).board;
    expect(preview.points[23], 1, reason: 'one back checker left 24');
    expect(preview.points[19], 1, reason: 'it landed on 20 (index 19)');

    control.confirm();
    await t.pump();
    expect(committed, isNotNull);
    expect(committed!.checkerMoves, hasLength(2));
    // The committed move runs a single checker from 23 and ends on 19.
    final froms = committed!.checkerMoves.map((c) => c.from).toSet();
    final tos = committed!.checkerMoves.map((c) => c.to).toSet();
    expect(froms, contains(23));
    expect(tos, contains(19));
  });

  testWidgets('combined taps OFF: no dimmer highlights, a chained-landing tap '
      'does nothing', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    await t.pumpWidget(viewWith(goldenState,
        options: const BoardInteractionOptions(enableCombinedTaps: false),
        control: control));

    await tapPoint(t, 23);
    expect(_painterOf(t).selectedCheckerLocation, 23);
    expect(_painterOf(t).combinedDestinations, isEmpty,
        reason: 'combined highlights are suppressed when the toggle is off');

    // Tapping the (would-be) chained landing does NOT enter a chain: point 19
    // is not a direct destination and combined is off, so it is treated as a
    // near-miss (no hop is recorded, Confirm stays off).
    await tapPoint(t, 19);
    expect(control.canConfirm, isFalse);
    expect(_painterOf(t).board, goldenState.board,
        reason: 'no hops entered: preview equals the base board');
  });

  // --- Drag-to-move ----------------------------------------------------------

  testWidgets('drag lifts a checker (ghost during pan) and a drop on a '
      'destination commits the hop', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    await t.pumpWidget(viewWith(goldenState,
        options: const BoardInteractionOptions(enableDrag: true),
        control: control));

    // Lift the 8-point's top checker (index 7 holds 3 White) and drag it toward
    // the 5-point (index 4, the die-3 destination).
    final start = _geometry.checkerCenter(7, 2, 3);
    final end = _geometry.pointRect(4).center;
    final g = await t.startGesture(start);
    await t.pump();
    // A first move past the touch slop wins the arena for the pan recogniser,
    // then travel to the destination.
    await g.moveBy(const Offset(0, 40));
    await t.pump();
    await g.moveTo(end);
    await t.pump();

    // Mid-drag: the source top checker is hidden and a travelling ghost is drawn.
    expect(_painterOf(t).hiddenChecker, isNotNull);
    expect(_painterOf(t).overlayChecker, isNotNull);
    expect(_painterOf(t).hiddenChecker!.location, 7);

    // Drop on the 5-point → the hop 8/5 is recorded (Undo becomes live) and the
    // preview shows the checker moved.
    await g.up();
    await t.pump();
    expect(control.canUndo, isTrue, reason: 'a hop was committed by the drop');
    expect(_painterOf(t).overlayChecker, isNull, reason: 'ghost cleared on drop');
    expect(_painterOf(t).board.points[4], 1, reason: 'a checker landed on 5');
  });

  testWidgets('drag: a drop on nothing snaps back (no hop recorded)', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    await t.pumpWidget(viewWith(goldenState,
        options: const BoardInteractionOptions(enableDrag: true),
        control: control));

    final start = _geometry.checkerCenter(7, 2, 3);
    // Release over the empty middle gap (left of the bar): locationAt is null
    // and no destination is near, so the drop must snap back.
    final empty = Offset(_size.width * 0.15, _size.height / 2);
    final g = await t.startGesture(start);
    await t.pump();
    await g.moveBy(const Offset(0, 40));
    await t.pump();
    await g.moveTo(empty);
    await t.pump();
    expect(_painterOf(t).overlayChecker, isNotNull, reason: 'lifted mid-drag');
    await g.up();
    await t.pump();

    // Snap-back: ghost cleared, nothing committed, base board unchanged.
    expect(_painterOf(t).overlayChecker, isNull);
    expect(control.canUndo, isFalse);
    expect(_painterOf(t).board, goldenState.board);
  });

  testWidgets('drag disabled: a pan does nothing (no lift, no hop)', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    await t.pumpWidget(viewWith(goldenState,
        options: const BoardInteractionOptions(enableDrag: false),
        control: control));

    final start = _geometry.checkerCenter(7, 2, 3);
    final end = _geometry.pointRect(4).center;
    final g = await t.startGesture(start);
    await t.pump();
    await g.moveTo(end);
    await t.pump();
    // No pan recognisers attached: no ghost is ever lifted.
    expect(_painterOf(t).overlayChecker, isNull);
    await g.up();
    await t.pump();
    expect(control.canUndo, isFalse);
    expect(_painterOf(t).selectedCheckerLocation, isNull);
    expect(_painterOf(t).board, goldenState.board);
  });

  // --- Highlights toggle -----------------------------------------------------

  testWidgets('highlights OFF: painter gets empty highlight sets, but taps '
      'still select and enter moves', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    Move? committed;
    await t.pumpWidget(viewWith(goldenState,
        options: const BoardInteractionOptions(showHighlights: false),
        control: control,
        onCommitted: (m) => committed = m));

    // With highlights off nothing is painted as a source, even though the
    // builder is active and offers legal sources.
    expect(control.active, isTrue);
    expect(_painterOf(t).highlightedSources, isEmpty,
        reason: 'no source rings when highlights are off');

    // A tap still SELECTS the 8-point (internal state advances), but the painter
    // draws no selection ring and no destination fills.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedCheckerLocation, isNull,
        reason: 'no selection ring painted when highlights are off');
    expect(_painterOf(t).highlightedDestinations, isEmpty);
    expect(_painterOf(t).combinedDestinations, isEmpty);

    // Yet the tap-to-move flow still works: complete the golden 3-1 by tapping
    // through destinations (forgiving geometry), and Confirm commits it.
    await tapPoint(t, 4); // 8/5
    await tapPoint(t, 5); // pick up 6-point
    await tapPoint(t, 4); // 6/5
    expect(control.canConfirm, isTrue,
        reason: 'move entry works even with highlights hidden');
    control.confirm();
    await t.pump();
    expect(committed, isNotNull);
    expect(committed!.sameAs(goldenMove), isTrue);
  });

  testWidgets('interactionOptions are forwarded to the BoardView unchanged',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    const options = BoardInteractionOptions(
      showHighlights: false,
      enableDrag: true,
      enableCombinedTaps: false,
    );
    await t.pumpWidget(viewWith(goldenState, options: options));
    final view = t.widget<BoardView>(find.byType(BoardView));
    expect(view.interactionOptions, options,
        reason: 'the options object reaches the board verbatim');
  });

  testWidgets('tap still works when drag is enabled', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final control = BoardEntryController();
    addTearDown(control.dispose);
    Move? committed;
    await t.pumpWidget(viewWith(goldenState,
        options: const BoardInteractionOptions(enableDrag: true),
        control: control,
        onCommitted: (m) => committed = m));

    // A static press+release (no movement) is routed to the tap handler by the
    // gesture arena even though pan recognisers are attached.
    await tapPoint(t, 7);
    expect(_painterOf(t).selectedCheckerLocation, 7);
    await tapPoint(t, 4); // 8/5
    await tapPoint(t, 5); // pick up 6-point
    await tapPoint(t, 4); // 6/5
    expect(control.canConfirm, isTrue);
    control.confirm();
    await t.pump();
    expect(committed, isNotNull);
    expect(committed!.sameAs(goldenMove), isTrue);
  });

  // UX-round-1 bear-off investigation: the user reported being unable to bear a
  // checker off with a higher die than needed. These drive the FULL UI chain
  // (select source -> off strip lights -> tap strip -> bear off) for the legal
  // overshoot cases, confirming the new full-width tray strip (Task 2) accepts
  // the bear-off tap.
  group('bear-off overshoot (higher die than needed)', () {
    GameState offState(Map<int, int> whitePts,
        {required int whiteOff, required Dice dice}) {
      final pts = List<int>.filled(24, 0);
      whitePts.forEach((k, v) => pts[k] = v);
      return GameState.testState(
        board: BoardState(points: pts, whiteOff: whiteOff, blackOff: 15),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: dice,
      );
    }

    testWidgets('selecting the 4-point lights the off strip and tapping it '
        'bears off (die 6 > point 4)', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      // Lone White checker on the 4-point (index 3); 6-5 both overshoot it.
      final state = offState({3: 1}, whiteOff: 14, dice: Dice(6, 5));
      expect(state.legalMoves, isNotEmpty);
      Move? committed;
      await t.pumpWidget(_harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: (m) => committed = m,
        entryControl: control,
      )));

      // Select the checker on the 4-point.
      await tapPoint(t, 3);
      final painter = _painterOf(t);
      expect(painter.selectedCheckerLocation, 3);
      // The off strip is a highlighted destination and the mover is known, so
      // the painter fills the whole bottom tray — the rule is made legible.
      expect(painter.highlightedDestinations, contains(CheckerMove.off),
          reason: 'a legal overshoot bear-off must light the off strip');
      expect(painter.movingPlayer, Player.white);

      // Tap anywhere on the (full-width) off strip → the bear-off is entered.
      await t.tapAt(_geometry.offRect(Player.white).center);
      await t.pump();
      expect(control.canConfirm, isTrue,
          reason: 'tapping the off strip must stage the overshoot bear-off');
      control.confirm();
      await t.pump();
      expect(committed, isNotNull);
      expect(committed!.checkerMoves.single.to, CheckerMove.off);
    });

    testWidgets('a corner tap on the off strip still bears off (generous hit '
        'area, unlike the old right-column tray)', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      final state = offState({3: 1}, whiteOff: 14, dice: Dice(6, 5));
      await t.pumpWidget(_harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: (_) {},
        entryControl: control,
      )));
      await tapPoint(t, 3);
      // Tap the far-left edge of the bottom strip — the old narrow tray would
      // have missed this; the new full-width strip accepts it.
      final tray = _geometry.offRect(Player.white);
      await t.tapAt(Offset(tray.left + 8, tray.center.dy));
      await t.pump();
      expect(control.canConfirm, isTrue);
    });

    testWidgets('two checkers on the 4-point bear off sequentially on 6-6 via '
        'repeated off-strip taps', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      final state = offState({3: 2}, whiteOff: 13, dice: Dice(6, 6));
      Move? committed;
      await t.pumpWidget(_harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: (m) => committed = m,
        entryControl: control,
      )));

      // First checker: select 4-point, tap the off strip.
      await tapPoint(t, 3);
      expect(_painterOf(t).highlightedDestinations, contains(CheckerMove.off));
      await t.tapAt(_geometry.offRect(Player.white).center);
      await t.pump();
      // Second checker is still on the 4-point and still bears off.
      await tapPoint(t, 3);
      expect(_painterOf(t).highlightedDestinations, contains(CheckerMove.off),
          reason: 'the second checker on the 4-point still overshoots off');
      await t.tapAt(_geometry.offRect(Player.white).center);
      await t.pump();

      expect(control.canConfirm, isTrue);
      control.confirm();
      await t.pump();
      expect(committed, isNotNull);
      expect(
          committed!.checkerMoves.where((c) => c.to == CheckerMove.off).length,
          2);
    });

    testWidgets('maximal-dice chain: tapping the off strip on 6-2 enters the '
        'whole 4/2/off run (combined taps)', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      // Lone checker on the 4-point, 6-2: the maximal turn is 4/2 then 2/off,
      // so off is a COMBINED (chained) landing, not a direct one. Combined taps
      // are on by default, so tapping the strip enters both hops at once.
      final state = offState({3: 1}, whiteOff: 14, dice: Dice(6, 2));
      Move? committed;
      await t.pumpWidget(_harness(BoardView(
        state: state,
        interactive: true,
        onMoveCommitted: (m) => committed = m,
        entryControl: control,
      )));

      await tapPoint(t, 3);
      final painter = _painterOf(t);
      // off is a combined landing here, not a direct destination.
      expect(painter.highlightedDestinations, isNot(contains(CheckerMove.off)));
      expect(painter.combinedDestinations, contains(CheckerMove.off),
          reason: 'the overshoot bear-off is a two-die chain on 6-2');

      await t.tapAt(_geometry.offRect(Player.white).center);
      await t.pump();
      expect(control.canConfirm, isTrue,
          reason: 'tapping the strip must enter the whole chain to bear off');
      control.confirm();
      await t.pump();
      expect(committed, isNotNull);
      expect(committed!.checkerMoves.any((c) => c.to == CheckerMove.off), isTrue);
    });
  });
}
