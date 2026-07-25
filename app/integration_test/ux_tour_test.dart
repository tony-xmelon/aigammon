@Tags(['ux_tour'])
library;

// UX screenshot tour: drives the REAL app on a phone-sized surface and writes a
// PNG at every UX checkpoint, so a reviewer can see every screen of the real
// build without installing it.
//
// It is a HARNESS, not an assertion suite: it plays a real 3-point match vs the
// real engine (tutor on, easy difficulty), captures whatever it reaches, and
// completes even when a checkpoint turns out to be unreachable in that run (a
// dice-dependent state, an AI that never doubles). Unreachable checkpoints are
// printed at the end rather than failing the run.
//
// * Surface: 390x844 logical @ devicePixelRatio 3 (a phone in portrait), via
//   `tester.view.physicalSize` / `devicePixelRatio` overrides.
// * Capture: a root [RepaintBoundary] wrapped around the app →
//   `toImage(pixelRatio: 2)` → PNG → `app/build/ux_tour/NN_name.png`, numbered
//   in visit order.
// * Animations are ON (the production `normal` preset) and frames are pumped in
//   real time, so mid-animation states (the opponent's dice tumble) can be
//   sampled deliberately instead of settled away.
//
// Not part of any automated suite: `flutter test` only walks `test/`, and CI
// never invokes `integration_test/`. Run it by hand from `app/`:
//
//   flutter test integration_test/ux_tour_test.dart -d windows
//
// (Set WILDBG_LIB_PATH if the repo-relative DLL walk-up cannot find the shim.)
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/game/match_controller.dart';
import 'package:aigammon_app/main.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:aigammon_app/screens/home_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../test/helpers/board_driving.dart';

/// Phone portrait logical size and pixel ratio of the captured surface.
const Size _phone = Size(390, 844);
const double _phoneDpr = 3.0;

/// Pixel ratio the PNGs are rasterised at (2x the logical size — readable in a
/// review without being 3x huge).
const double _shotPixelRatio = 2.0;

/// Wall-clock budget for the match loop. When it expires the tour stops playing
/// and goes on to the post-match screens with whatever it captured.
const Duration _matchBudget = Duration(minutes: 16);

/// The root capture boundary and the tour's output bookkeeping.
final GlobalKey _shotKey = GlobalKey();
late final Directory _outDir;
int _shotNo = 0;
final List<String> _written = <String>[];
final List<String> _skipped = <String>[];
DateTime _lastShotAt = DateTime.fromMillisecondsSinceEpoch(0);

/// Whether enough has happened since the last capture that an opportunistic
/// screenshot would show a genuinely different frame (two captures in one loop
/// iteration would otherwise write the same pixels twice).
bool _settledSinceShot() =>
    DateTime.now().difference(_lastShotAt) > const Duration(seconds: 1);

void _log(String message) {
  // ignore: avoid_print
  print('ux_tour: $message');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'UX screenshot tour (phone portrait, real engine)',
    (tester) async {
      final started = DateTime.now();
      _outDir = _resolveOutDir()..createSync(recursive: true);
      _log('writing to ${_outDir.path}');

      // The tour runs a debug build; suppress the DEBUG ribbon so the captures
      // show the UI a user would actually see.
      WidgetsApp.debugAllowBannerOverride = false;
      addTearDown(() => WidgetsApp.debugAllowBannerOverride = true);

      // A phone in portrait: 390x844 logical at DPR 3.
      tester.view.physicalSize =
          Size(_phone.width * _phoneDpr, _phone.height * _phoneDpr);
      tester.view.devicePixelRatio = _phoneDpr;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Real providers (real engine + real drift database), but with the tour's
      // deterministic starting preferences written first: light theme, the
      // production animation pacing, a 3-point easy match, tutor forced on, and
      // the one-time drag hint armed so checkpoint "drag hint" is reachable.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        await container.read(settingsRepositoryProvider).save(
              AppSettings.defaults.copyWith(
                themeMode: ThemeMode.light,
                animationSpeed: AnimationSpeed.normal,
                defaultMatchLength: 3,
                defaultDifficulty: Difficulty.easy,
                tutorOverride: true,
                dragHintShown: false,
              ),
            );
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(key: _shotKey, child: const AiGammonApp()),
        ),
      );
      await _beat(tester, const Duration(milliseconds: 800));

      // --- 01 Home ---------------------------------------------------------
      await _shot(tester, 'home');

      // --- 02 New-match setup (as opened) ----------------------------------
      await _tapText(tester, 'Play vs Computer');
      await _beat(tester, const Duration(milliseconds: 700));
      await _shot(tester, 'new_match_setup');

      // --- 03 Game screen, opening state -----------------------------------
      await _tapText(tester, 'Start match');
      // Captured as early as the route transition allows, so the opening
      // position is seen before the first move-entry affordances appear.
      await _beat(tester, const Duration(milliseconds: 500));
      await _shot(tester, 'game_opening');

      final controller =
          tester.widget<GameScreen>(find.byType(GameScreen)).controller;
      final human =
          controller.isLocalHuman(Player.white) ? Player.white : Player.black;
      _log('human plays ${human.name}');

      await _playMatch(tester, controller, human, started);

      // --- Post-match screens ----------------------------------------------
      await _leaveMatch(tester);
      await _historyAndAnalysis(tester);
      await _settings(tester);

      final elapsed = DateTime.now().difference(started);
      _log('tour finished in ${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s');
      _log('captured ${_written.length} screenshots:');
      for (final f in _written) {
        _log('  $f');
      }
      if (_skipped.isEmpty) {
        _log('every checkpoint was reached');
      } else {
        _log('unreachable checkpoints: ${_skipped.join(', ')}');
      }
      expect(_written, isNotEmpty, reason: 'the tour captured no screenshots');
    },
    timeout: const Timeout(Duration(minutes: 60)),
  );
}

// --- The match ---------------------------------------------------------------

/// Plays the match through the real UI, capturing the in-game checkpoints as
/// they become reachable. Returns when the match ends (or the budget expires).
Future<void> _playMatch(
  WidgetTester tester,
  MatchController c,
  Player human,
  DateTime started,
) async {
  final done = <String>{};
  final deadline = started.add(_matchBudget);
  var humanMoves = 0;
  var seenEvents = c.game.events.length;

  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 4));
    _drain(tester);

    // A fresh roll by the OPPONENT starts the dice-tumble beat; sample it
    // mid-animation (the beat runs ~840ms, so 400ms in is squarely inside it).
    final events = c.game.events;
    if (events.length < seenEvents) seenEvents = events.length; // new game
    if (events.length > seenEvents) {
      final fresh = events.sublist(seenEvents);
      seenEvents = events.length;
      if (!done.contains('dice_beat') &&
          fresh.any((e) => e is RollEvent && e.player != human)) {
        await _beat(tester, const Duration(milliseconds: 400));
        if (await _shot(tester, 'opponent_dice_beat')) done.add('dice_beat');
      }
    }

    // The collapsed history strip only carries a score in the window between a
    // tutor assessment landing and the next event overwriting the latest line,
    // so grab it opportunistically the moment a mark shows.
    if (!done.contains('strip') && _stripScored()) {
      if (await _shot(tester, 'history_strip_scored')) done.add('strip');
    }

    if (c.matchOver) {
      await _beat(tester, const Duration(milliseconds: 700));
      if (await _shot(tester, 'match_end_dialog')) done.add('match_end');
      break;
    }

    if (c.awaitingNextGame) {
      await _beat(tester, const Duration(milliseconds: 700));
      if (!done.contains('game_end')) {
        if (await _shot(tester, 'game_end_dialog')) done.add('game_end');
      }
      await _tapText(tester, 'Next game');
      await _beat(tester, const Duration(milliseconds: 600));
      continue;
    }

    // The AI doubled: capture the offer, then PASS. Dropping keeps the match
    // going over several short games (a taken double the greedy human then
    // loses gammoned can decide a 3-pointer in one game, which would put the
    // game-end dialog out of reach).
    if (c.pendingCubeOf(human).value != null) {
      await _beat(tester, const Duration(milliseconds: 800));
      if (!done.contains('cube')) {
        if (await _shot(tester, 'cube_offer_dialog')) done.add('cube');
      }
      await _tapText(tester, 'Pass');
      await _beat(tester, const Duration(milliseconds: 400));
      continue;
    }

    // The AI resigned: capture the offer, then accept.
    if (c.pendingResignOf(human).value != null) {
      await _beat(tester, const Duration(milliseconds: 800));
      if (!done.contains('resign')) {
        if (await _shot(tester, 'resign_offer_dialog')) done.add('resign');
      }
      await _tapText(tester, 'Accept');
      await _beat(tester, const Duration(milliseconds: 400));
      continue;
    }

    if (c.pendingMoveOf(human).value != null) {
      humanMoves++;
      await _humanMove(tester, done, humanMoves);
      continue;
    }

    if (c.awaitingHumanTurn) {
      final roll = find.widgetWithText(FilledButton, 'Roll');
      if (roll.evaluate().isNotEmpty && isButtonEnabled(tester, roll)) {
        // Only when nothing else was just captured, so this is not a duplicate
        // of a dice-beat frame sampled in the same iteration.
        if (!done.contains('pre_roll') && humanMoves >= 1 && _settledSinceShot()) {
          if (await _shot(tester, 'pre_roll_gate')) done.add('pre_roll');
        }
        await tester.tap(roll);
        await _beat(tester, const Duration(milliseconds: 300));
        // Both players' persistent dice pairs are on the board once the
        // opponent has rolled at least once.
        if (!done.contains('dice_pairs') && humanMoves >= 1) {
          if (await _shot(tester, 'dice_both_pairs')) done.add('dice_pairs');
        }
      }
    }
  }

  if (!done.contains('game_end')) _skipped.add('game-end dialog');
  if (!done.contains('match_end')) {
    _skipped.add('match-end dialog (match unfinished inside the time budget)');
  }
  if (!done.contains('strip')) {
    // Observed every run: `buildGameRecord` opens a new latest line on the
    // opponent's RollEvent, which lands before the tutor's assessment of the
    // human's move resolves — so the strip's mark, which only ever renders for
    // the LATEST line, is never on screen during a vs-AI match.
    _skipped.add('history strip with a score (the opponent rolls — and so '
        'appends a new latest line — before the tutor assessment for the human '
        'move lands)');
  }
  if (!done.contains('dice_beat')) _skipped.add('opponent dice beat');
  if (!done.contains('cube')) _skipped.add('cube-offer dialog (AI never doubled)');
  if (!done.contains('resign')) {
    _skipped.add('resign-offer dialog (AI never resigned)');
  }
  if (!done.contains('hint')) _skipped.add('hint panel');
  if (!done.contains('selection')) _skipped.add('move entry with a selection');
  if (!done.contains('drag_hint')) _skipped.add('drag-hint SnackBar');
  if (!done.contains('record')) _skipped.add('expanded history sheet');
}

/// Drives one human move: the one-time hint SnackBar, the expanded record
/// sheet, the tutor hint panel, a mid-entry selection, then the commit.
Future<void> _humanMove(
  WidgetTester tester,
  Set<String> done,
  int moveNumber,
) async {
  await _waitForEntry(tester);

  // The one-time drag/tap hint surfaces on the FIRST human move of the match.
  // It is dismissed straight after its capture: the SnackBar outlives its
  // 6-second duration under the test binding's clock and would otherwise sit
  // over every later screenshot, including other routes.
  if (!done.contains('drag_hint')) {
    await _beat(tester, const Duration(milliseconds: 600));
    if (find.textContaining('drag checkers').evaluate().isNotEmpty) {
      if (await _shot(tester, 'drag_hint_snackbar')) done.add('drag_hint');
      final gotIt = find.descendant(
        of: find.byType(SnackBarAction),
        matching: find.text('Got it'),
      );
      if (gotIt.evaluate().isNotEmpty) {
        await tester.tap(gotIt.first);
        await _beat(tester, const Duration(milliseconds: 400));
      }
    }
  }

  // The expanded record sheet, once a few lines (and ideally a mark) exist.
  if (!done.contains('record') && moveNumber >= 3) {
    final strip = find.byKey(const ValueKey('historyStrip'));
    if (strip.evaluate().isNotEmpty) {
      await tester.tap(strip);
      await _beat(tester, const Duration(milliseconds: 600));
      if (await _shot(tester, 'history_sheet_expanded')) done.add('record');
      final close = find.byTooltip('Close');
      if (close.evaluate().isNotEmpty) {
        await tester.tap(close.first);
      } else {
        await tester.tapAt(Offset(_phone.width / 2, 60));
      }
      await _beat(tester, const Duration(milliseconds: 400));
    }
  }

  // The tutor hint panel + tap-to-apply, once the engine is warm.
  if (!done.contains('hint') && moveNumber >= 4) {
    final hint = find.widgetWithText(OutlinedButton, 'Hint');
    if (hint.evaluate().isNotEmpty) {
      await tester.tap(hint);
      await _beat(tester, const Duration(milliseconds: 400));
      await _waitFor(tester, () => find.text('1.').evaluate().isNotEmpty,
          const Duration(seconds: 25));
      if (await _shot(tester, 'hint_panel_top_plays')) done.add('hint');
      // Tap-to-apply: the top play is staged onto the interactive board. The
      // ROW (a full-width InkWell) is the tap target — the "1." label itself is
      // a 20px box and misses under the scaled test view.
      final topRow =
          find.ancestor(of: find.text('1.'), matching: find.byType(InkWell));
      if (topRow.evaluate().isNotEmpty) {
        await tester.tap(topRow.first);
        await _beat(tester, const Duration(milliseconds: 900));
        await _shot(tester, 'hint_applied_to_board');
      }
      await _dismissHintPanel(tester);
    }
  }

  // A checker selected, with its destinations lit.
  if (!done.contains('selection') && !_confirmReady(tester)) {
    final sources = boardPainterOf(tester).highlightedSources;
    if (sources.isNotEmpty) {
      await tapBoardPoint(tester, sources.first);
      await _beat(tester, const Duration(milliseconds: 350));
      if (boardPainterOf(tester).highlightedDestinations.isNotEmpty) {
        if (await _shot(tester, 'move_entry_selected')) done.add('selection');
      }
    }
  }

  await _finishMove(tester);
  await _beat(tester, const Duration(milliseconds: 200));
}

/// Whether the action bar's Confirm is present and enabled (the move is
/// already complete — e.g. a hint was applied).
bool _confirmReady(WidgetTester tester) {
  final confirm = find.widgetWithText(FilledButton, 'Confirm');
  return confirm.evaluate().isNotEmpty && isButtonEnabled(tester, confirm);
}

/// Completes whatever move entry is open: greedily walks the first offered
/// destination (or source) until Confirm lights up, then commits — or takes the
/// "No moves — pass" affordance during a dance.
Future<void> _finishMove(WidgetTester tester) async {
  // A still-open hint panel would eat every board tap through its scrim.
  await _dismissHintPanel(tester);
  for (var i = 0; i < 10; i++) {
    if (_confirmReady(tester)) {
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pump();
      return;
    }
    final pass = find.text('No moves — pass');
    if (pass.evaluate().isNotEmpty) {
      await tester.tap(pass);
      await tester.pump();
      return;
    }
    final painter = boardPainterOf(tester);
    // Destinations are only non-empty while a source is selected, so this walks
    // select → land → select → land until the move is complete.
    if (painter.highlightedDestinations.isNotEmpty) {
      await tapBoardPoint(tester, painter.highlightedDestinations.first);
    } else if (painter.highlightedSources.isNotEmpty) {
      await tapBoardPoint(tester, painter.highlightedSources.first);
    }
    await _beat(tester, const Duration(milliseconds: 160));
  }
  _log('warning: move entry did not complete after 10 taps');
}

/// Closes the hint bottom panel if it is open (its ✕, else its scrim).
Future<void> _dismissHintPanel(WidgetTester tester) async {
  if (find.text('Top plays').evaluate().isEmpty) return;
  final close = find.byTooltip('Close');
  if (close.evaluate().isNotEmpty) {
    await tester.tap(close.first);
  } else {
    await tester.tapAt(Offset(_phone.width / 2, 80));
  }
  await _beat(tester, const Duration(milliseconds: 350));
}

/// Waits until the board actually shows move-entry affordances (the controller
/// sets the pending move between frames).
Future<void> _waitForEntry(WidgetTester tester) => _waitFor(
      tester,
      () =>
          boardPainterOf(tester).highlightedSources.isNotEmpty ||
          find.text('No moves — pass').evaluate().isNotEmpty ||
          _confirmReady(tester),
      const Duration(seconds: 20),
    );

/// Whether the collapsed history strip currently shows an assessment mark.
bool _stripScored() {
  final strip = find.byKey(const ValueKey('historyStrip'));
  if (strip.evaluate().isEmpty) return false;
  for (final mark in ['Best', 'Good', 'Dubious', 'Error', 'Blunder']) {
    final hit = find.descendant(of: strip, matching: find.textContaining(mark));
    if (hit.evaluate().isNotEmpty) return true;
  }
  return false;
}

// --- Post-match screens ------------------------------------------------------

/// Dismisses whatever end-of-match modal is up and returns to the home screen.
Future<void> _leaveMatch(WidgetTester tester) async {
  for (final label in ['Done', 'Next game']) {
    final action = find.text(label);
    if (action.evaluate().isNotEmpty) {
      await tester.tap(action);
      await _beat(tester, const Duration(milliseconds: 700));
      break;
    }
  }
  await _backToHome(tester);
}

/// History list → match detail → per-game analysis (with the Played/Best
/// toggle, the metric explainer and a mid-game cursor row).
Future<void> _historyAndAnalysis(WidgetTester tester) async {
  final history = find.widgetWithText(OutlinedButton, 'History');
  if (history.evaluate().isEmpty) {
    _skipped.add('history screen (no History entry on home)');
    return;
  }
  await tester.tap(history);
  await _beat(tester, const Duration(milliseconds: 900));
  await _shot(tester, 'history_screen');

  final matches = find.byType(ListTile);
  if (matches.evaluate().isEmpty) {
    _skipped.add('match detail (history is empty)');
    return;
  }
  await tester.tap(matches.first);
  await _beat(tester, const Duration(milliseconds: 900));
  await _shot(tester, 'match_detail');

  final games = find.byType(ListTile);
  if (games.evaluate().isEmpty) {
    _skipped.add('analysis screen (match has no recorded games)');
    return;
  }
  await tester.tap(games.first);
  await _beat(tester, const Duration(milliseconds: 900));

  // A freshly recorded game has no cached analysis, so the analyzer runs with a
  // progress bar — worth a screenshot of its own.
  if (find.textContaining('Analysing').evaluate().isNotEmpty) {
    await _shot(tester, 'analysis_computing');
  }
  final loaded = await _waitFor(
    tester,
    () => find.text('Moves').evaluate().isNotEmpty,
    const Duration(minutes: 10),
  );
  if (!loaded) {
    _skipped.add('analysis screen (analysis did not finish in time)');
    return;
  }
  await _beat(tester, const Duration(milliseconds: 400));
  await _shot(tester, 'analysis_initial');

  // Step the replay cursor to roughly mid-game: the current move row highlights
  // and is scrolled into view.
  final total = _cursorTotal(tester);
  if (total != null) {
    await _stepCursor(tester, total ~/ 2);
    await _shot(tester, 'analysis_midgame_row_highlighted');
  } else {
    _skipped.add('analysis mid-game cursor (no cursor bar found)');
  }

  // Walk forward until a move whose best play differs from the played one — the
  // only positions that offer the Played/Best toggle.
  var steps = 0;
  while (find.text('Played').evaluate().isEmpty && steps < 80) {
    if (!await _stepOnce(tester)) break;
    steps++;
  }
  if (find.text('Played').evaluate().isNotEmpty) {
    await _shot(tester, 'analysis_played_overlay');
    final best = find.descendant(
      of: find.byType(SegmentedButton<bool>),
      matching: find.text('Best'),
    );
    if (best.evaluate().isNotEmpty) {
      await tester.tap(best.first);
      await _beat(tester, const Duration(milliseconds: 500));
      await _shot(tester, 'analysis_best_overlay');
    }
  } else {
    _skipped.add('analysis Played/Best toggle (no differing best play found)');
  }

  final explainer = find.byTooltip('What do these numbers mean?');
  if (explainer.evaluate().isNotEmpty) {
    await tester.tap(explainer);
    await _beat(tester, const Duration(milliseconds: 700));
    await _shot(tester, 'metric_explainer_dialog');
    // Scoped to the dialog: "Got it" is also the drag-hint SnackBar's action.
    final gotIt = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Got it'),
    );
    if (gotIt.evaluate().isNotEmpty) await tester.tap(gotIt.first);
    await _beat(tester, const Duration(milliseconds: 500));
  } else {
    _skipped.add('metric explainer dialog');
  }
}

/// Home → Settings.
Future<void> _settings(WidgetTester tester) async {
  await _backToHome(tester);
  final gear = find.byTooltip('Settings');
  if (gear.evaluate().isEmpty) {
    _skipped.add('settings screen (no Settings entry on home)');
    return;
  }
  await tester.tap(gear);
  await _beat(tester, const Duration(milliseconds: 800));
  await _shot(tester, 'settings');
}

/// Pops routes until the home screen is the visible one.
Future<void> _backToHome(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    if (find.byType(HomeScreen).evaluate().isNotEmpty) return;
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    if (!navigator.canPop()) return;
    navigator.pop();
    await _beat(tester, const Duration(milliseconds: 600));
    _drain(tester);
  }
}

/// The analysis cursor bar's total step count, parsed from its "i / n" label.
int? _cursorTotal(WidgetTester tester) {
  final pattern = RegExp(r'^(\d+) / (\d+)$');
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final data = text.data;
    if (data == null) continue;
    final match = pattern.firstMatch(data);
    if (match != null) return int.parse(match.group(2)!);
  }
  return null;
}

/// The analysis cursor's current index (1-based), or null.
int? _cursorIndex(WidgetTester tester) {
  final pattern = RegExp(r'^(\d+) / (\d+)$');
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final data = text.data;
    if (data == null) continue;
    final match = pattern.firstMatch(data);
    if (match != null) return int.parse(match.group(1)!);
  }
  return null;
}

/// Advances the analysis cursor to (about) [target].
Future<void> _stepCursor(WidgetTester tester, int target) async {
  for (var i = 0; i < target + 5; i++) {
    final current = _cursorIndex(tester);
    if (current == null || current >= target) return;
    if (!await _stepOnce(tester)) return;
  }
}

/// Taps the analysis cursor bar's ▶ once. Returns false when it is gone or
/// disabled (the finder targets the IconButton itself — a Tooltip finder would
/// never report an enabled button).
Future<bool> _stepOnce(WidgetTester tester) async {
  final next = find.widgetWithIcon(IconButton, Icons.chevron_right);
  if (next.evaluate().isEmpty) return false;
  if (tester.widget<IconButton>(next.first).onPressed == null) return false;
  await tester.tap(next.first);
  await _beat(tester, const Duration(milliseconds: 110));
  return true;
}

// --- Capture + timing plumbing ----------------------------------------------

/// Rasterises the root boundary to `NN_<name>.png`. Returns false (and logs)
/// when the boundary is not capturable, so the tour can carry on.
Future<bool> _shot(WidgetTester tester, String name) async {
  await tester.pump();
  final object = _shotKey.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) {
    _log('skipped "$name": no capture boundary in the tree');
    return false;
  }
  Uint8List? png;
  await tester.runAsync(() async {
    final image = await object.toImage(pixelRatio: _shotPixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    png = data?.buffer.asUint8List();
  });
  final bytes = png;
  if (bytes == null || bytes.isEmpty) {
    _log('skipped "$name": the boundary produced no PNG bytes');
    return false;
  }
  final file = File(p.join(
    _outDir.path,
    '${(++_shotNo).toString().padLeft(2, '0')}_$name.png',
  ));
  file.writeAsBytesSync(bytes);
  _lastShotAt = DateTime.now();
  _written.add(file.path);
  _log('wrote ${p.basename(file.path)} (${bytes.length} bytes)');
  return true;
}

/// Pumps real frames for [duration] of wall-clock time.
///
/// The integration binding pumps against the real clock, so this both advances
/// animations at their true pace and lets engine-isolate replies land — while
/// keeping the sampling point deterministic (unlike `pumpAndSettle`, which
/// never returns while the thinking indicator or a dice beat repeats).
Future<void> _beat(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  do {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 4));
  } while (DateTime.now().isBefore(end));
}

/// Pumps until [condition] holds or [limit] elapses. Returns whether it held.
Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  Duration limit,
) async {
  final end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    if (condition()) {
      await tester.pump();
      return true;
    }
    await _beat(tester, const Duration(milliseconds: 60));
    _drain(tester);
  }
  return false;
}

/// Taps a text affordance, tolerating duplicates (takes the first).
Future<void> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) {
    _log('warning: "$label" not found');
    return;
  }
  await tester.tap(finder.first);
  await tester.pump();
}

/// Drains and logs any framework exception so a stray overflow or transient
/// error cannot abort the tour before it has written its screenshots.
void _drain(WidgetTester tester) {
  final error = tester.takeException();
  if (error != null) _log('framework exception (continuing): $error');
}

/// `<repo>/app/build/ux_tour`, found by walking up from the runtime CWD (the
/// same idiom the engine uses to find its staged DLL).
Directory _resolveOutDir() {
  var dir = Directory.current;
  for (var i = 0; i <= 4; i++) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir.path, 'integration_test')).existsSync()) {
      return Directory(p.join(dir.path, 'build', 'ux_tour'));
    }
    if (File(p.join(dir.path, 'app', 'pubspec.yaml')).existsSync()) {
      return Directory(p.join(dir.path, 'app', 'build', 'ux_tour'));
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory(p.join(Directory.current.path, 'build', 'ux_tour'));
}
