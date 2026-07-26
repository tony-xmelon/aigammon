import 'dart:async';

import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/screens/settings_screen.dart';
import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/test_database.dart';

late AppDatabase _db;

/// The settings feed for the screen. Driven manually (not drift's watch) so the
/// widget test stays off drift's lingering watch-timer, while writes still land
/// in the real (overridden) [_db] where the tests probe them. [_refresh] mirrors
/// production: after a save, the persisted value is pushed back into the feed so
/// the screen's `settings` stay current across sequential edits.
late StreamController<AppSettings> _feed;

Widget _app() => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(_db),
        settingsProvider.overrideWith((ref) => _feed.stream),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );

Future<AppSettings> _persisted(WidgetTester t) async =>
    (await t.runAsync(() => SettingsRepository(_db).load()))!;

/// Pushes the live persisted settings into the screen's feed (as the real drift
/// stream would after a write), then pumps so the controls reflect them.
Future<void> _refresh(WidgetTester t) async {
  _feed.add(await _persisted(t));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    _db = newTestDatabase();
    _feed = StreamController<AppSettings>();
  });
  tearDown(() async {
    await _feed.close();
    await _db.close();
  });

  testWidgets('renders every setting section', (t) async {
    await t.pumpWidget(_app());
    _feed.add(AppSettings.defaults);
    await t.pumpAndSettle();

    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Animation speed'), findsOneWidget);
    // The dice-roll toggle qualifies the speed control, directly beneath it.
    expect(find.widgetWithText(SwitchListTile, 'Dice roll animation'),
        findsOneWidget);
    expect(find.text('Tumble the dice before each roll'), findsOneWidget);
    expect(find.text('Default match length'), findsOneWidget);
    expect(find.text('Default difficulty'), findsOneWidget);
    expect(find.text('Tutor mode default'), findsOneWidget);

    // The Gameplay section with its four option toggles.
    expect(find.text('Gameplay'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'Move highlights'),
        findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'Drag to move'), findsOneWidget);
    expect(
        find.widgetWithText(SwitchListTile, 'Combined moves'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'Show score'), findsOneWidget);
  });

  testWidgets('gameplay toggles reflect settings and autosave on change',
      (t) async {
    // A tall surface so the Gameplay section (bottom of the scroll view) is on
    // screen and its switches are tappable.
    await t.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_app());
    _feed.add(AppSettings.defaults);
    await t.pumpAndSettle();

    // Defaults (v4): highlights on, drag ON, combined on, scoring on.
    bool switchValue(String title) => t
        .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
        .value;
    expect(switchValue('Move highlights'), isTrue);
    expect(switchValue('Drag to move'), isTrue);
    expect(switchValue('Combined moves'), isTrue);
    expect(switchValue('Show score'), isTrue);

    // Toggle drag OFF (away from its new ON default) — it autosaves.
    final drag = find.widgetWithText(SwitchListTile, 'Drag to move');
    await t.ensureVisible(drag);
    await t.tap(drag);
    await _refresh(t);
    expect((await _persisted(t)).enableDrag, isFalse,
        reason: 'no save button — the switch writes on toggle');
    expect(switchValue('Drag to move'), isFalse);

    // Toggle highlights OFF — independent, does not clobber the drag edit.
    final hl = find.widgetWithText(SwitchListTile, 'Move highlights');
    await t.ensureVisible(hl);
    await t.tap(hl);
    await _refresh(t);
    final saved = await _persisted(t);
    expect(saved.showHighlights, isFalse);
    expect(saved.enableDrag, isFalse, reason: 'earlier edit preserved');

    // Toggle scoring OFF too.
    final score = find.widgetWithText(SwitchListTile, 'Show score');
    await t.ensureVisible(score);
    await t.tap(score);
    await _refresh(t);
    expect((await _persisted(t)).showScoring, isFalse);
  });

  testWidgets('the dice-roll animation toggle reflects settings and autosaves',
      (t) async {
    await t.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_app());
    _feed.add(AppSettings.defaults);
    await t.pumpAndSettle();

    final toggle = find.widgetWithText(SwitchListTile, 'Dice roll animation');
    expect(t.widget<SwitchListTile>(toggle).value, isTrue,
        reason: 'ON by default (schema v5)');

    await t.ensureVisible(toggle);
    await t.tap(toggle);
    await _refresh(t);
    final saved = await _persisted(t);
    expect(saved.diceRollAnimation, isFalse,
        reason: 'no save button — the switch writes on toggle');
    // And it lands where every consumer reads it: the timings lose their beat.
    expect(saved.timings.diceBeatEnabled, isFalse);
    expect(t.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets('the pass-device toggle is OFF by default and autosaves',
      (t) async {
    await t.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_app());
    _feed.add(AppSettings.defaults);
    await t.pumpAndSettle();

    final toggle = find.widgetWithText(SwitchListTile, 'Pass-device screen');
    expect(t.widget<SwitchListTile>(toggle).value, isFalse,
        reason: 'disabled by default, per the reported feedback');
    expect(find.text('Cover the board between hot-seat turns'), findsOneWidget);

    await t.ensureVisible(toggle);
    await t.tap(toggle);
    await _refresh(t);
    expect((await _persisted(t)).showPassDevice, isTrue);
    expect(t.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('every selector hides the selected checkmark', (t) async {
    await t.pumpWidget(_app());
    _feed.add(AppSettings.defaults);
    await t.pumpAndSettle();

    final segs = find.byWidgetPredicate((w) => w is SegmentedButton);
    expect(segs, findsWidgets);
    for (final w in t.widgetList(segs)) {
      expect((w as SegmentedButton).showSelectedIcon, isFalse,
          reason: 'a checkmark would squeeze/wrap the segment labels');
    }
  });

  testWidgets('each control autosaves immediately (probe the repo)', (t) async {
    // A tall surface: the page grew a row (the dice-roll toggle), which pushed
    // the tutor selector off an 800x600 default surface.
    await t.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_app());
    _feed.add(AppSettings.defaults);
    await t.pumpAndSettle();

    // Seeded defaults.
    expect((await _persisted(t)).themeMode, ThemeMode.system);

    await t.tap(find.text('Dark'));
    await _refresh(t);
    expect((await _persisted(t)).themeMode, ThemeMode.dark,
        reason: 'no save button — the change writes on selection');

    // A second, independent edit persists and does not clobber the first.
    await t.tap(find.text('Fast'));
    await _refresh(t);
    final saved = await _persisted(t);
    expect(saved.animationSpeed, AnimationSpeed.fast);
    expect(saved.themeMode, ThemeMode.dark, reason: 'earlier edit preserved');

    await t.tap(find.text('7'));
    await _refresh(t);
    await t.tap(find.text('Expert'));
    await _refresh(t);
    await t.tap(find.text('Off')); // tutor default -> off
    await _refresh(t);

    final all = await _persisted(t);
    expect(all.defaultMatchLength, 7);
    expect(all.defaultDifficulty, Difficulty.expert);
    expect(all.tutorOverride, isFalse);
  });

  testWidgets('reset restores the defaults', (t) async {
    // Pre-seed a fully non-default state into the store.
    await t.runAsync(() => SettingsRepository(_db).save(const AppSettings(
          themeMode: ThemeMode.dark,
          animationSpeed: AnimationSpeed.off,
          defaultMatchLength: 1,
          defaultDifficulty: Difficulty.expert,
          tutorOverride: true,
        )));

    await t.pumpWidget(_app());
    await _refresh(t); // surface the pre-seeded non-default state

    // The dark theme is currently selected.
    expect(
      t
          .widget<SegmentedButton<ThemeMode>>(
              find.byType(SegmentedButton<ThemeMode>))
          .selected,
      {ThemeMode.dark},
    );

    await t.tap(find.text('Reset'));
    await _refresh(t);

    expect(await _persisted(t), AppSettings.defaults);
    // The UI reflects the reset (System selected again).
    expect(
      t
          .widget<SegmentedButton<ThemeMode>>(
              find.byType(SegmentedButton<ThemeMode>))
          .selected,
      {ThemeMode.system},
    );
  });
}
