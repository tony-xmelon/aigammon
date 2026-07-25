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
    expect(find.text('Default match length'), findsOneWidget);
    expect(find.text('Default difficulty'), findsOneWidget);
    expect(find.text('Tutor mode default'), findsOneWidget);
  });

  testWidgets('each control autosaves immediately (probe the repo)', (t) async {
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
