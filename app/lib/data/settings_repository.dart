import 'package:drift/drift.dart';
import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';
import 'database.dart';

/// Reads and writes the single-row [Settings] preferences as [AppSettings].
///
/// The row is guaranteed to exist by [AppDatabase]'s `beforeOpen` (an
/// idempotent seed), so [load]/[watch] never face an empty table. Writes upsert
/// row 1, so [save] works whether or not the row was touched before.
class SettingsRepository {
  SettingsRepository(this.db);

  final AppDatabase db;

  /// The current settings (the single row, always present).
  Future<AppSettings> load() async {
    final row = await db.select(db.settings).getSingle();
    return _fromRow(row);
  }

  /// Upserts row 1 with [settings]. Enums persist by their `.name`.
  Future<void> save(AppSettings settings) async {
    await db.into(db.settings).insertOnConflictUpdate(_toCompanion(settings));
  }

  /// A live stream of the settings, re-emitting on every write (drift watch).
  Stream<AppSettings> watch() =>
      db.select(db.settings).watchSingle().map(_fromRow);

  static AppSettings _fromRow(SettingsRow row) => AppSettings(
        themeMode: _themeModeFromName(row.themeMode),
        animationSpeed: _animationSpeedFromName(row.animationSpeed),
        defaultMatchLength: row.defaultMatchLength,
        defaultDifficulty: _difficultyFromName(row.defaultDifficulty),
        tutorOverride: _tutorFromText(row.tutorOverride),
        showHighlights: row.showHighlights,
        enableDrag: row.enableDrag,
        enableCombinedTaps: row.enableCombinedTaps,
        showScoring: row.showScoring,
      );

  static SettingsCompanion _toCompanion(AppSettings s) => SettingsCompanion(
        id: const Value(1),
        themeMode: Value(s.themeMode.name),
        animationSpeed: Value(s.animationSpeed.name),
        defaultMatchLength: Value(s.defaultMatchLength),
        defaultDifficulty: Value(s.defaultDifficulty.name),
        tutorOverride: Value(_tutorToText(s.tutorOverride)),
        showHighlights: Value(s.showHighlights),
        enableDrag: Value(s.enableDrag),
        enableCombinedTaps: Value(s.enableCombinedTaps),
        showScoring: Value(s.showScoring),
      );

  // --- Enum <-> string codecs (tolerant of unknown values) -------------------

  static ThemeMode _themeModeFromName(String name) => ThemeMode.values
      .firstWhere((m) => m.name == name, orElse: () => ThemeMode.system);

  static AnimationSpeed _animationSpeedFromName(String name) =>
      AnimationSpeed.values
          .firstWhere((a) => a.name == name, orElse: () => AnimationSpeed.normal);

  static Difficulty _difficultyFromName(String name) => Difficulty.values
      .firstWhere((d) => d.name == name, orElse: () => Difficulty.medium);

  static bool? _tutorFromText(String? text) => switch (text) {
        'on' => true,
        'off' => false,
        _ => null,
      };

  static String? _tutorToText(bool? override) => switch (override) {
        true => 'on',
        false => 'off',
        null => null,
      };
}

/// The app-wide [SettingsRepository] over the lazy [databaseProvider].
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(databaseProvider));
});

/// The live app settings.
///
/// A [StreamProvider] over [SettingsRepository.watch]: the single row always
/// exists (seeded on open), so this emits an [AppSettings] on first frame and
/// re-emits on every save. Design note — a stream (not a caching Notifier) is
/// used so that a save from ANY surface (settings screen, a future deep link)
/// propagates to every consumer through drift's own change notification, with
/// no shared in-memory cache to keep coherent. Consumers that need a value
/// during the initial (sub-frame) load fall back to [AppSettings.defaults] via
/// `valueOrNull`.
final settingsProvider = StreamProvider<AppSettings>((ref) {
  return ref.watch(settingsRepositoryProvider).watch();
});
