import 'package:aigammon_app/board/board_geometry.dart';
import 'package:aigammon_app/board/board_painter.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared widget-test helpers for driving the interactive [BoardView].
///
/// These are used by both the widget suite (`test/screens/game_screen_test.dart`)
/// and the desktop end-to-end integration test
/// (`integration_test/desktop_e2e_test.dart`), so the two exercise the board
/// through the exact same tap geometry and commit flow.

/// Pumps frames until [cond] holds (the controller loop advances on the
/// microtasks each pump flushes), failing if it never does.
Future<void> pumpUntil(
  WidgetTester t,
  bool Function() cond, {
  int maxFrames = 800,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (cond()) {
      await t.pump(); // flush the pending setState rebuild before asserting
      return;
    }
    await t.pump(const Duration(milliseconds: 1));
  }
  fail('condition not met after $maxFrames frames');
}

/// The board's painter (the only [BoardPainter] in the tree).
BoardPainter boardPainterOf(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .firstWhere((c) => c.painter is BoardPainter)
    .painter as BoardPainter;

/// The global rect of the board's paint surface.
Rect boardRect(WidgetTester t) => t.getRect(
    find.byWidgetPredicate((w) => w is CustomPaint && w.painter is BoardPainter));

/// Taps the centre of board location [index] (white-at-bottom geometry).
///
/// [index] is a point (0..23), [CheckerMove.bar] (24) when entering from the
/// bar, or [CheckerMove.off] (-1) when bearing off — the latter two arise with
/// real unseeded dice (a hit sends a checker to the bar; a home-board race bears
/// off). `pointRect` only accepts 0..23, so route the bar/off sentinels to their
/// strips instead. `locationAt` claims the whole bar/off columns (any row), so
/// White's half is a valid tap target regardless of which side is on the bar.
Future<void> tapBoardPoint(WidgetTester t, int index) async {
  final r = boardRect(t);
  final g = BoardGeometry(r.size, whiteAtBottom: true);
  final Rect target = index == CheckerMove.bar
      ? g.barRect(Player.white)
      : index == CheckerMove.off
          ? g.offRect(Player.white)
          : g.pointRect(index);
  await t.tapAt(r.topLeft + target.center);
  await t.pump();
}

/// Whether [f] resolves to an enabled [ButtonStyleButton].
bool isButtonEnabled(WidgetTester t, Finder f) {
  final w = t.widget(f);
  return w is ButtonStyleButton && w.onPressed != null;
}

/// Drives the interactive board greedily (first highlighted source → first
/// destination) until Confirm is enabled, then commits — or takes the "No moves
/// — pass" affordance during a dance.
///
/// Greedy entry always completes: under the maximal-dice rule every prefix the
/// [MoveBuilder] offers extends to a full-length legal move (see MoveBuilder's
/// class doc), so first-source/first-destination reaches `isComplete`.
Future<void> commitFirstMove(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    final confirm = find.widgetWithText(FilledButton, 'Confirm');
    if (confirm.evaluate().isNotEmpty && isButtonEnabled(t, confirm)) break;
    final pass = find.text('No moves — pass');
    if (pass.evaluate().isNotEmpty) {
      await t.tap(pass);
      await t.pump();
      return;
    }
    final src = boardPainterOf(t).highlightedSources.first;
    await tapBoardPoint(t, src);
    final dst = boardPainterOf(t).highlightedDestinations.first;
    await tapBoardPoint(t, dst);
  }
  await t.tap(find.widgetWithText(FilledButton, 'Confirm'));
  await t.pump();
}
