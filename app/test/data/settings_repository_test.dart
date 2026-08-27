import 'package:aigammon_app/buddy/phrasing.dart';
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
    expect(s.rotateBoardHotSeat, isFalse,
        reason: 'the v7 hot-seat board rotation is OFF out of the box — two '
            'players share a FIXED board, one action bar per edge');
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
      rotateBoardHotSeat: true,
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
    expect(loaded.rotateBoardHotSeat, isTrue);
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
    expect(again.rotateBoardHotSeat, isTrue);
    expect(again.dragHintShown, isTrue);
  });

  test('tutorOverride false persists distinctly from null', () async {
    await repo.save(AppSettings.defaults.copyWith(tutorOverride: false));
    expect((await repo.load()).tutorOverride, isFalse);
    await repo.save(AppSettings.defaults.copyWith(tutorOverride: null));
    expect((await repo.load()).tutorOverride, isNull);
  });

  group('markDragHintShown', () {
    test('latches the flag', () async {
      expect((await repo.load()).dragHintShown, isFalse);
      await repo.markDragHintShown();
      expect((await repo.load()).dragHintShown, isTrue);
    });

    test('does not clobber a field changed since the snapshot was read',
        () async {
      // What the game screen actually holds: the settings as they were when
      // the match STARTED.
      final snapshot = await repo.load();

      // Meanwhile the player visits the settings screen and changes things.
      await repo.save(snapshot.copyWith(
        themeMode: ThemeMode.dark,
        defaultDifficulty: Difficulty.expert,
        enableDrag: false,
      ));

      // Only now does the hint fire, from that stale snapshot's screen.
      await repo.markDragHintShown();

      final after = await repo.load();
      expect(after.dragHintShown, isTrue, reason: 'the latch still landed');
      expect(after.themeMode, ThemeMode.dark);
      expect(after.defaultDifficulty, Difficulty.expert);
      expect(after.enableDrag, isFalse,
          reason: 'the concurrent change survived the latch');

      // For contrast, the write this replaced: a full-row save of the stale
      // snapshot puts every one of those fields back.
      await repo.save(snapshot.copyWith(dragHintShown: true));
      final clobbered = await repo.load();
      expect(clobbered.themeMode, ThemeMode.system);
      expect(clobbered.defaultDifficulty, Difficulty.medium);
      expect(clobbered.enableDrag, isTrue);
    });

    test('is idempotent', () async {
      await repo.markDragHintShown();
      await repo.markDragHintShown();
      expect((await repo.load()).dragHintShown, isTrue);
    });
  });

  group('the Buddy settings', () {
    test('a fresh database talks in notation and may ask for the microphone',
        () async {
      final settings = await repo.load();
      expect(settings.buddyPhrasing, BuddyPhrasing.terse);
      expect(settings.buddyMicHint, isTrue,
          reason: 'the hint is available until somebody refuses it');
      expect(AppSettings.defaults.buddyPhrasing, BuddyPhrasing.terse,
          reason: 'the Dart-side defaults mirror the seeded row');
      expect(AppSettings.defaults.buddyMicHint, isTrue);
    });

    test('save + load round-trips both, independently', () async {
      final base = await repo.load();
      await repo.save(base.copyWith(
        buddyPhrasing: BuddyPhrasing.friendly,
        buddyMicHint: false,
      ));
      final saved = await repo.load();
      expect(saved.buddyPhrasing, BuddyPhrasing.friendly);
      expect(saved.buddyMicHint, isFalse);

      await repo.save(saved.copyWith(buddyMicHint: true));
      final again = await repo.load();
      expect(again.buddyMicHint, isTrue);
      expect(again.buddyPhrasing, BuddyPhrasing.friendly,
          reason: 'each field persists independently');
    });

    test('an unknown phrasing on disk reads as the default, never throws',
        () async {
      // The tolerant codec every enum column in this table uses: a row written
      // by a future build, or corrupted, must not make the app unlaunchable.
      await db.customStatement(
          "UPDATE settings SET buddy_phrasing = 'shakespearean'");
      expect((await repo.load()).buddyPhrasing, BuddyPhrasing.terse);
    });

    test('markBuddyMicRefused latches the hint off', () async {
      expect((await repo.load()).buddyMicHint, isTrue);
      await repo.markBuddyMicRefused();
      expect((await repo.load()).buddyMicHint, isFalse);
      await repo.markBuddyMicRefused();
      expect((await repo.load()).buddyMicHint, isFalse, reason: 'idempotent');
    });

    test('markBuddyMicRefused does not clobber a concurrent settings edit',
        () async {
      // The session's snapshot was read when the match started; the refusal
      // arrives at the first throw, which may be a settings visit later.
      final snapshot = await repo.load();
      await repo.save(snapshot.copyWith(
        themeMode: ThemeMode.dark,
        buddyPhrasing: BuddyPhrasing.friendly,
      ));

      await repo.markBuddyMicRefused();

      final after = await repo.load();
      expect(after.buddyMicHint, isFalse, reason: 'the latch still landed');
      expect(after.themeMode, ThemeMode.dark);
      expect(after.buddyPhrasing, BuddyPhrasing.friendly,
          reason: 'the concurrent change survived the latch');
    });

    test('turning the hint back on is a plain save, so a refusal is not final',
        () async {
      // The reason a refusal and the preference are ONE column: a user who
      // granted the permission in system settings needs something to switch.
      await repo.markBuddyMicRefused();
      final settings = await repo.load();
      await repo.save(settings.copyWith(buddyMicHint: true));
      expect((await repo.load()).buddyMicHint, isTrue);
    });
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
