import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/board/board_view.dart';
import 'package:aigammon_app/game/applied_move.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 600);

/// Wraps [child] so it occupies exactly [_size] with its top-left at the global
/// origin, so a board-local geometry offset equals a global tap offset. The
/// surface is set to [_size] and a same-size SizedBox anchors the board at
/// (0,0); 800x600 is an aspect of 1.33, inside the board's clamp, so the board
/// fills the box exactly.
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
  ValueNotifier<AppliedMove?> lastMove, {
  Duration hopDuration = const Duration(milliseconds: 150),
  Duration interHopDuration = Duration.zero,
  ValueListenable<bool>? holdMoveAnimation,
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
                holdMoveAnimation: holdMoveAnimation,
                hopDuration: hopDuration,
                interHopDuration: interHopDuration,
              ),
            ),
          ),
        ),
      ),
    );

/// Mounts an INTERACTIVE [BoardView] wired for both move entry (an
/// [entryControl] / [externalMove]) and move animation (a [lastMove]), with
/// `disableAnimations: false` so the ticker runs. Used to prove the entry-source
/// animation gate: a hand-entered commit must NOT replay, a staged one must.
Widget _interactiveAnimHarness(
  GameState state,
  ValueNotifier<AppliedMove?> lastMove, {
  required bool interactive,
  BoardEntryController? control,
  ValueListenable<Move?>? externalMove,
  ValueListenable<bool>? holdMoveAnimation,
  Duration hopDuration = const Duration(milliseconds: 150),
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
                interactive: interactive,
                onMoveCommitted: (_) {},
                lastMove: lastMove,
                externalMove: externalMove,
                holdMoveAnimation: holdMoveAnimation,
                entryControl: control,
                hopDuration: hopDuration,
              ),
            ),
          ),
        ),
      ),
    );

/// The same geometry the widget computes for an 800x600 board.
final _geometry = BoardGeometry(_size, whiteAtBottom: true);

/// The global rect of the board's paint surface (which, since the board is
/// centred in its slot, is not necessarily the slot's own rect).
Rect _boardRect(WidgetTester t) => t.getRect(find
    .byWidgetPredicate((w) => w is CustomPaint && w.painter is BoardPainter));

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

  group('responsive sizing', () {
    /// Mounts the board in a slot of exactly [slot] and returns the size the
    /// painter was actually given (the board's own paint surface).
    Future<Size> boardIn(WidgetTester t, Size slot) async {
      await t.binding.setSurfaceSize(slot);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: slot.width,
            height: slot.height,
            child: BoardView(
              state: goldenState,
              interactive: true,
              onMoveCommitted: (_) {},
            ),
          ),
        ),
      ));
      return _painterOf(t).geometry.size;
    }

    testWidgets('an EXTREMELY tall slot: the board hits the min aspect',
        (t) async {
      // Taller than even the relaxed 0.55 clamp allows, so the clamp binds and
      // the board letterboxes rather than stretching further.
      const slot = Size(374, 800);
      final board = await boardIn(t, slot);
      expect(board.width, closeTo(slot.width, 0.01),
          reason: 'the board takes the full width of a tall slot');
      expect(board.width / board.height, closeTo(BoardView.minAspect, 1e-6),
          reason: 'it elongates down to the clamp, not beyond');
      expect(board.height, greaterThan(board.width),
          reason: 'a phone board is TALLER than it is wide');
      expect(board.height, lessThan(slot.height),
          reason: 'the clamp letterboxes what it will not stretch into');
      // The CustomPaint really is that size on screen (not just the geometry).
      final painted = t.getSize(find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is BoardPainter));
      expect(painted.width, closeTo(board.width, 0.01));
      expect(painted.height, closeTo(board.height, 0.01));
    });

    testWidgets("a real phone's board slot is filled EXACTLY (no letterbox)",
        (t) async {
      // The game screen's slot on a 390pt phone: aspect ~0.58, inside the 0.55
      // clamp, so the board takes every pixel of it — no dead margin above or
      // below (the "we need every pixel of screen space" fix).
      const slot = Size(390, 677);
      final board = await boardIn(t, slot);
      expect(board.width, closeTo(slot.width, 0.01));
      expect(board.height, closeTo(slot.height, 0.01));
    });

    testWidgets('a very wide slot: the board stops at the max aspect',
        (t) async {
      const slot = Size(1600, 700);
      final board = await boardIn(t, slot);
      expect(board.height, closeTo(slot.height, 0.01),
          reason: 'height binds in a wide slot');
      expect(board.width / board.height, closeTo(BoardView.maxAspect, 1e-6));
      expect(board.width, lessThan(slot.width));
    });

    testWidgets('a slot within the bounds is filled exactly', (t) async {
      const slot = Size(900, 900); // aspect 1.0, comfortably inside the clamp
      final board = await boardIn(t, slot);
      expect(board.width, closeTo(slot.width, 0.01));
      expect(board.height, closeTo(slot.height, 0.01));
    });

    test('boardSizeFor survives unbounded and degenerate constraints', () {
      final unbounded = BoardView.boardSizeFor(const BoxConstraints());
      expect(unbounded.width, greaterThan(0));
      expect(unbounded.height, greaterThan(0));
      final onlyWidth = BoardView.boardSizeFor(
          const BoxConstraints(maxWidth: 360));
      expect(onlyWidth.width, 360);
      expect(onlyWidth.height,
          closeTo(360 / BoardView.naturalAspect, 1e-6));
      final zero = BoardView.boardSizeFor(BoxConstraints.tight(Size.zero));
      expect(zero.width, greaterThan(0), reason: 'never a zero-sized board');
      expect(zero.height, greaterThan(0));
    });

    testWidgets('the tap tolerance never falls below a 44pt target', (t) async {
      // A narrow phone board: its checkers are ~21pt across, so the
      // proportional tolerance (1.8 radii = 19pt) is BELOW the 22pt the 44pt
      // minimum touch target needs — only the floor makes this tap land.
      final board = await boardIn(t, const Size(300, 600));
      final g = BoardGeometry(board, whiteAtBottom: true);
      expect(g.checkerRadius * 2, lessThan(44),
          reason: 'the premise: a phone checker is far smaller than 44pt');
      expect(g.checkerRadius * 1.8, lessThan(21),
          reason: 'the premise: the proportional tolerance alone would miss');
      // White's 13-point (index 12) holds five checkers; the column beside it
      // (index 13) is empty and not a legal origin, so only forgiveness can
      // resolve a tap that lands there.
      final n = BoardState.initial().points[12].abs();
      final anchor = _boardRect(t).topLeft + g.checkerCenter(12, n - 1, n);
      await t.tapAt(anchor + const Offset(21, 0));
      await t.pump();
      expect(_painterOf(t).selectedCheckerLocation, 12,
          reason: 'a 21pt miss (a 42pt-wide target) still selects');
    });
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
      // Deselect-on-re-tap is what a SLOW second tap does; with the detector
      // live a fast one would play a hop instead (see the double-tap group).
      // Wall-clock timing is not controllable from a widget test, so the
      // detector is switched off here to isolate the deselect semantics.
      doubleTapWindow: Duration.zero,
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
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);

    // Mount PRE-move, then fire the move (the controller fires lastMove BEFORE
    // notifying, so state is still pre-move at fire time) and rebuild POST-move.
    await t.pumpWidget(_animHarness(goldenState, lastMove));
    expect(_painterOf(t).overlayChecker, isNull);
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
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
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);

    await t.pumpWidget(_animHarness(goldenState, lastMove));
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
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
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);

    await t.pumpWidget(
        _animHarness(goldenState, lastMove, hopDuration: Duration.zero));
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    await t.pumpWidget(
        _animHarness(postState, lastMove, hopDuration: Duration.zero));
    await t.pump();

    // No animation ever ran: no overlay, board is immediately post-move.
    expect(_painterOf(t).overlayChecker, isNull);
    expect(_painterOf(t).board, postBoard);
  });

  testWidgets('holdMoveAnimation defers the travel: no overlay while held, '
      'the move plays after release', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);
    final hold = ValueNotifier<bool>(true);
    addTearDown(hold.dispose);

    // Mount PRE-move (held), fire the move, then rebuild POST-move — exactly as
    // the game screen does while the opponent dice beat is still presenting.
    await t.pumpWidget(
        _animHarness(goldenState, lastMove, holdMoveAnimation: hold));
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    await t.pumpWidget(
        _animHarness(postState, lastMove, holdMoveAnimation: hold));

    // While held, pumping past a full travel window shows NO travelling overlay
    // and the board is FROZEN at the pre-move position (the checker sits at its
    // source), even though lastMove already fired.
    await t.pump(const Duration(milliseconds: 500));
    expect(_painterOf(t).overlayChecker, isNull,
        reason: 'the move must not travel while held');
    expect(_painterOf(t).board, goldenState.board,
        reason: 'the board is frozen pre-move during the hold');

    // Release the hold: the queued move now begins travelling.
    hold.value = false;
    await t.pump(const Duration(milliseconds: 75));
    expect(_painterOf(t).overlayChecker, isNotNull,
        reason: 'releasing the hold starts the queued travel');
    expect(_painterOf(t).board, isNot(postBoard));

    await t.pumpAndSettle();
    expect(_painterOf(t).overlayChecker, isNull);
    expect(_painterOf(t).board, postBoard);
  });

  testWidgets('inter-hop pause: the overlay is stationary between hops',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);

    // 2 hops × 100ms travel with a 100ms pause between them → 300ms total.
    // Timeline: hop0 [0,100], pause [100,200], hop1 [200,300].
    await t.pumpWidget(_animHarness(goldenState, lastMove,
        hopDuration: const Duration(milliseconds: 100),
        interHopDuration: const Duration(milliseconds: 100)));
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    await t.pumpWidget(_animHarness(postState, lastMove,
        hopDuration: const Duration(milliseconds: 100),
        interHopDuration: const Duration(milliseconds: 100)));

    // Mid hop0 travel (~t=50).
    await t.pump(const Duration(milliseconds: 50));
    final travelling = _painterOf(t).overlayChecker!.center;

    // Two probes INSIDE the inter-hop pause (~t=120 and ~t=180): the overlay
    // must sit at the same spot (hop0's landing) — stationary between hops.
    await t.pump(const Duration(milliseconds: 70));
    final pauseA = _painterOf(t).overlayChecker!.center;
    await t.pump(const Duration(milliseconds: 60));
    final pauseB = _painterOf(t).overlayChecker!.center;

    expect((pauseA - pauseB).distance, lessThan(0.5),
        reason: 'the overlay is stationary during the inter-hop pause');
    expect((travelling - pauseA).distance, greaterThan(1.0),
        reason: 'the mid-travel position differs from the paused position');

    await t.pumpAndSettle();
  });

  testWidgets('no total cap: a multi-hop move travels for the full '
      'n·hop + (n-1)·interHop', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);

    // 2 hops × 400ms = 800ms total — deliberately past the old 600ms cap.
    await t.pumpWidget(_animHarness(goldenState, lastMove,
        hopDuration: const Duration(milliseconds: 400)));
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    await t.pumpWidget(_animHarness(postState, lastMove,
        hopDuration: const Duration(milliseconds: 400)));

    // At 700ms the old cap (600ms) would have finished; with no cap the move is
    // still travelling.
    await t.pump(const Duration(milliseconds: 700));
    expect(_painterOf(t).overlayChecker, isNotNull,
        reason: 'an 800ms move is still animating at 700ms (no 600ms cap)');
    expect(_painterOf(t).board, isNot(postBoard));

    await t.pumpAndSettle();
    expect(_painterOf(t).board, postBoard);
  });

  testWidgets('a shorter hop duration (fast) settles sooner than a longer one',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);

    // Fast: 2 hops × 100ms = 200ms total → settled by 260ms.
    await t.pumpWidget(_animHarness(goldenState, lastMove,
        hopDuration: const Duration(milliseconds: 100)));
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    await t.pumpWidget(_animHarness(postState, lastMove,
        hopDuration: const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 260));
    expect(_painterOf(t).overlayChecker, isNull,
        reason: 'a fast (200ms) move has settled by 260ms');
    expect(_painterOf(t).board, postBoard);
  });

  // --- Entry-source animation gate (no self-replay) --------------------------

  testWidgets('a HAND-ENTERED commit is NOT replayed as an animation',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);
    final control = BoardEntryController();
    addTearDown(control.dispose);

    // Enter the golden 3-1 by HAND (tap both hops) on the interactive board.
    await t.pumpWidget(_interactiveAnimHarness(goldenState, lastMove,
        interactive: true, control: control));
    await tapPoint(t, 7);
    await tapPoint(t, 4); // 8/5
    await tapPoint(t, 5);
    await tapPoint(t, 4); // 6/5
    expect(control.canConfirm, isTrue);

    // Confirm, then fire the SAME move as lastMove and rebuild post-move /
    // non-interactive — the exact sequence the controller drives after a commit.
    control.confirm();
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    await t.pumpWidget(_interactiveAnimHarness(postState, lastMove,
        interactive: false, control: control));

    // No travelling overlay EVER appears: the move the user just performed live
    // is not replayed. The post-move board snaps in.
    await t.pump(const Duration(milliseconds: 75));
    expect(_painterOf(t).overlayChecker, isNull,
        reason: 'a hand-entered move must not animate');
    await t.pump(const Duration(milliseconds: 400));
    expect(_painterOf(t).overlayChecker, isNull);
    expect(_painterOf(t).board, postBoard,
        reason: 'the post-move board is shown without a replay');
  });

  testWidgets(
      "a commit followed IMMEDIATELY by the opponent's held reply keeps the "
      'confirmed position painted (no revert)', (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);
    final hold = ValueNotifier<bool>(false);
    addTearDown(hold.dispose);
    final control = BoardEntryController();
    addTearDown(control.dispose);

    // Black's reply from the post-commit position, and the board it leaves.
    final blackMove =
        MoveGenerator.legalMoves(postBoard, Player.black, Dice(6, 5)).first;
    final finalBoard = postBoard.applyMove(Player.black, blackMove);
    final finalState = GameState.testState(
      board: finalBoard,
      turn: Player.white,
      phase: GamePhase.awaitingRoll,
    );

    // Enter the golden 3-1 by HAND and confirm it.
    await t.pumpWidget(_interactiveAnimHarness(goldenState, lastMove,
        interactive: true, control: control, holdMoveAnimation: hold));
    await tapPoint(t, 7);
    await tapPoint(t, 4); // 8/5
    await tapPoint(t, 5);
    await tapPoint(t, 4); // 6/5
    expect(control.canConfirm, isTrue);
    control.confirm();

    // The controller now runs the WHOLE opponent turn inside the commit's
    // microtask chain — no frame is painted in between, so the view is still
    // mounted with the PRE-commit state when both moves fire. The commit fires
    // first (suppressed: the user just played it live), then the opponent's roll
    // holds the animation and its reply fires.
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    hold.value = true;
    lastMove.value = AppliedMove(MoveEvent(Player.black, blackMove), postBoard);
    await t.pumpWidget(_interactiveAnimHarness(finalState, lastMove,
        interactive: false, control: control, holdMoveAnimation: hold));

    // While the opponent's dice are presented the board is frozen at the
    // CONFIRMED position — the user's own move must not un-happen.
    await t.pump(const Duration(milliseconds: 500));
    expect(_painterOf(t).overlayChecker, isNull,
        reason: 'the reply must not travel while held');
    expect(_painterOf(t).board, postBoard,
        reason: 'the held board keeps the confirmed move applied');

    // Releasing the hold plays ONLY the opponent's reply, still on top of the
    // confirmed position, and settles on the full post-reply board.
    hold.value = false;
    await t.pump(const Duration(milliseconds: 75));
    expect(_painterOf(t).overlayChecker, isNotNull,
        reason: 'releasing the hold starts the queued reply');
    expect(_painterOf(t).board, postBoard,
        reason: "the reply's first hop travels from the confirmed position");

    await t.pumpAndSettle();
    expect(_painterOf(t).overlayChecker, isNull);
    expect(_painterOf(t).board, finalBoard);
  });

  testWidgets('an externally-STAGED (tap-to-apply hint) commit STILL animates',
      (t) async {
    await t.binding.setSurfaceSize(_size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final lastMove = ValueNotifier<AppliedMove?>(null);
    addTearDown(lastMove.dispose);
    final external = ValueNotifier<Move?>(null);
    addTearDown(external.dispose);
    final control = BoardEntryController();
    addTearDown(control.dispose);

    await t.pumpWidget(_interactiveAnimHarness(goldenState, lastMove,
        interactive: true, externalMove: external, control: control));

    // Stage the WHOLE play programmatically (a hint), not hop-by-hop, then
    // confirm and fire the move as the controller would.
    external.value = goldenMove;
    await t.pump();
    expect(control.canConfirm, isTrue);
    control.confirm();
    lastMove.value =
        AppliedMove(MoveEvent(Player.white, goldenMove), goldenState.board);
    await t.pumpWidget(_interactiveAnimHarness(postState, lastMove,
        interactive: false, externalMove: external, control: control));

    // The staged move was not hand-entered, so it animates: a travelling overlay
    // appears mid-flight before settling to the post-move board.
    await t.pump(const Duration(milliseconds: 75));
    expect(_painterOf(t).overlayChecker, isNotNull,
        reason: 'a programmatically-staged (hint) move still animates');
    expect(_painterOf(t).board, isNot(postBoard));
    await t.pumpAndSettle();
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

  testWidgets('drag disabled: a pan lifts nothing and enters no hop — it reads '
      'as a TAP on the checker it started from', (t) async {
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
    expect(control.canUndo, isFalse, reason: 'a pan can never enter a hop here');
    expect(_painterOf(t).board, goldenState.board);
    // With no pan to claim the gesture, the tap survives its travel (see
    // `_BoardViewState._tapDownPosition`) and picks up where the finger landed —
    // which beats the old behaviour of dropping the press on the floor.
    expect(_painterOf(t).selectedCheckerLocation, 7);
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

  // --- Tap the dice to roll ---------------------------------------------------

  group('tap the dice to roll', () {
    /// A pre-roll gate board: NOT interactive (no move is pending) but wired
    /// with an [onDiceTap], exactly as the game screen wires it at the gate.
    Widget preRoll(GameState state, VoidCallback? onDiceTap) => _harness(
          BoardView(
            state: state,
            interactive: false,
            onMoveCommitted: (_) {},
            onDiceTap: onDiceTap,
          ),
        );

    testWidgets('a tap on EITHER pair rolls while the gate is open', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      var rolls = 0;
      await t.pumpWidget(preRoll(goldenState, () => rolls++));

      final mover = goldenState.turn;
      await t.tapAt(_geometry.diceRect(mover, mover: mover).center);
      await t.pump();
      expect(rolls, 1, reason: "the mover's own pair rolls");

      await t.tapAt(_geometry.diceRect(mover.opponent, mover: mover).center);
      await t.pump();
      expect(rolls, 2, reason: 'the waiting pair rolls too');
    });

    testWidgets('a near miss inside the padded target still rolls', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      var rolls = 0;
      await t.pumpWidget(preRoll(goldenState, () => rolls++));

      final mover = goldenState.turn;
      final target = _geometry.diceTapRect(mover, mover: mover);
      // Just inside the padded box's corner — outside the dice themselves.
      await t.tapAt(target.bottomRight - const Offset(1, 1));
      await t.pump();
      expect(rolls, 1);
    });

    testWidgets('a tap elsewhere on the board does NOT roll', (t) async {
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      var rolls = 0;
      await t.pumpWidget(preRoll(goldenState, () => rolls++));

      await t.tapAt(_geometry.pointRect(0).center);
      await t.pump();
      await t.tapAt(_geometry.barRect(Player.white).center);
      await t.pump();
      expect(rolls, 0);
    });

    testWidgets('with no callback the dice area falls through to move entry',
        (t) async {
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

      // Pick up a source, then tap the (empty) dice area: with no dice-tap
      // callback that is just a tap on nothing actionable, which clears the
      // selection — the pre-existing behaviour, unchanged.
      await tapPoint(t, 7);
      expect(_painterOf(t).selectedCheckerLocation, 7);
      final mover = goldenState.turn;
      await t.tapAt(_geometry.diceRect(mover, mover: mover).center);
      await t.pump();
      expect(_painterOf(t).selectedCheckerLocation, isNull);
    });

    testWidgets('move entry keeps working while a dice tap is wired',
        (t) async {
      // Defensive: even if both were ever live at once, a tap on a checker
      // still enters the move rather than rolling.
      await t.binding.setSurfaceSize(_size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final control = BoardEntryController();
      addTearDown(control.dispose);
      var rolls = 0;
      await t.pumpWidget(_harness(BoardView(
        state: goldenState,
        interactive: true,
        onMoveCommitted: (_) {},
        entryControl: control,
        onDiceTap: () => rolls++,
      )));

      await tapPoint(t, 7);
      expect(_painterOf(t).selectedCheckerLocation, 7);
      expect(rolls, 0);
    });
  });
}
