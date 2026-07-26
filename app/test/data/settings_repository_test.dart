import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository repo;

  setUp(() {
    db = newTestDatabase();
    repo = SettingsRepository(db);
  });

  tearDown(() => db.close());

  test('load returns the seeded defaults on a fresh database', () async {
    final settings = await repo.load();
    expect(settings, AppSettings.defaults);
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.animationSpeed, AnimationSpeed.normal);
    expect(settings.defaultMatchLength, 5);
    expect(settings.defaultDifficulty, Difficulty.medium);
    expect(settings.tutorOverride, isNull);
    expect(settings.timings, AnimationTimings.normal);
    expect(settings.timings.hop, const Duration(milliseconds: 350));
  });

  test('save + load round-trips every field (incl. null tutor override)',
      () async {
    const custom = AppSettings(
      themeMode: ThemeMode.dark,
      animationSpeed: AnimationSpeed.fast,
      defaultMatchLength: 7,
      defaultDifficulty: Difficulty.expert,
      tutorOverride: true,
    );
    await repo.save(custom);
    expect(await repo.load(), custom);

    // Overwriting the single row (not inserting a second) — tutorOverride back
    // to null, other fields changed.
    const other = AppSettings(
      themeMode: ThemeMode.light,
      animationSpeed: AnimationSpeed.off,
      defaultMatchLength: 1,
      defaultDifficulty: Difficulty.easy,
      tutorOverride: null,
    );
    await repo.save(other);
    expect(await repo.load(), other);

    // Still exactly one row.
    final rows = await db.select(db.settings).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, 1);
  });

  test('load returns the gameplay-option defaults on a fresh database',
      () async {
    final s = await repo.load();
    expect(s.showHighlights, isTrue);
    expect(s.enableDrag, isTrue, reason: 'drag-to-move is ON by default (v4)');
    expect(s.enableCombinedTaps, isTrue);
    expect(s.showScoring, isTrue);
    expect(s.diceRollAnimation, isTrue,
        reason: 'the v5 dice-roll animation is ON out of the box');
    expect(s.showPassDevice, isFalse,
        reason: 'the v5 hot-seat pass-device cover is OFF out of the box');
    expect(s.dragHintShown, isFalse,
        reason: 'the one-time drag hint has not been shown on a fresh install');
    // The Dart-side defaults mirror the seeded row.
    expect(AppSettings.defaults.enableDrag, isTrue);
    expect(AppSettings.defaults.dragHintShown, isFalse);
  });

  test('save + load round-trips the gameplay-option fields', () async {
    // Flip every gameplay toggle away from its default (drag off, hint shown).
    final flipped = AppSettings.defaults.copyWith(
      showHighlights: false,
      enableDrag: false,
      enableCombinedTaps: false,
      showScoring: false,
      diceRollAnimation: false,
      showPassDevice: true,
      dragHintShown: true,
    );
    await repo.save(flipped);
    final loaded = await repo.load();
    expect(loaded, flipped);
    expect(loaded.showHighlights, isFalse);
    expect(loaded.enableDrag, isFalse);
    expect(loaded.enableCombinedTaps, isFalse);
    expect(loaded.showScoring, isFalse);
    expect(loaded.diceRollAnimation, isFalse);
    expect(loaded.showPassDevice, isTrue);
    expect(loaded.dragHintShown, isTrue);

    // Each field persists independently (toggle just one back).
    await repo.save(loaded.copyWith(enableDrag: true));
    final again = await repo.load();
    expect(again.enableDrag, isTrue);
    expect(again.showHighlights, isFalse, reason: 'others unchanged');
    expect(again.enableCombinedTaps, isFalse);
    expect(again.showScoring, isFalse);
    expect(again.diceRollAnimation, isFalse);
    expect(again.showPassDevice, isTrue);
    expect(again.dragHintShown, isTrue);
  });

  test('tutorOverride false persists distinctly from null', () async {
    await repo.save(AppSettings.defaults.copyWith(tutorOverride: false));
    expect((await repo.load()).tutorOverride, isFalse);
    await repo.save(AppSettings.defaults.copyWith(tutorOverride: null));
    expect((await repo.load()).tutorOverride, isNull);
  });

  test('watch emits the current settings and re-emits on save', () async {
    final emissions = <AppSettings>[];
    final sub = repo.watch().listen(emissions.add);

    // First emission: the seeded defaults.
    await Future<void>.delayed(Duration.zero);
    expect(emissions.last, AppSettings.defaults);

    await repo.save(AppSettings.defaults.copyWith(themeMode: ThemeMode.dark));
    await Future<void>.delayed(Duration.zero);
    expect(emissions.last.themeMode, ThemeMode.dark);

    await repo.save(
        AppSettings.defaults.copyWith(animationSpeed: AnimationSpeed.off));
    await Future<void>.delayed(Duration.zero);
    expect(emissions.last.animationSpeed, AnimationSpeed.off);

    await sub.cancel();
  });
}
