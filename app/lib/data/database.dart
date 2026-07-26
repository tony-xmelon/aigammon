import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'database.g.dart';

/// One match: setup metadata plus the running/final score.
///
/// The generated row class is named `MatchRow` (not `Match`) to avoid clashing
/// with any core game types when both are imported together.
@DataClassName('MatchRow')
class Matches extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get matchLength => integer()();

  /// 'vsComputer' | 'hotSeat'.
  TextColumn get mode => text()();

  /// Player identity strings, e.g. 'human' or 'ai:expert'.
  TextColumn get whiteType => text()();
  TextColumn get blackType => text()();

  IntColumn get whiteScore => integer().withDefault(const Constant(0))();
  IntColumn get blackScore => integer().withDefault(const Constant(0))();

  /// 'white' | 'black' once the match is decided; null while in progress.
  TextColumn get winner => text().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
}

/// One game within a match, stored as the core's JSON event log plus the
/// folded result. Replaying [eventsJson] with `Game.replay` reproduces the
/// exact final state.
@DataClassName('GameRow')
class Games extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// A REAL SQL foreign key (emitted via [customConstraint], so the generated
  /// DDL carries `REFERENCES matches (id) ON DELETE CASCADE`). drift's
  /// `.references()` only wires the Dart-side relation; it does not emit the SQL
  /// constraint, so a customConstraint is used to enforce integrity at the
  /// database level. Cascade delete relies on `PRAGMA foreign_keys = ON`, which
  /// [AppDatabase.migration] enables in `beforeOpen`. Because this column drops
  /// the default `NOT NULL`, it is restated here explicitly.
  IntColumn get matchId => integer().customConstraint(
      'NOT NULL REFERENCES matches (id) ON DELETE CASCADE')();
  IntColumn get gameNumber => integer()();
  BoolColumn get isCrawford => boolean()();

  /// A JSON array of `GameEvent.toJson()` maps (the full event log).
  TextColumn get eventsJson => text()();

  /// The folded [GameResult], flattened. Null only for an unfinished game
  /// (not persisted in v1 — games are recorded once complete).
  TextColumn get resultWinner => text().nullable()();
  IntColumn get resultPoints => integer().nullable()();
  TextColumn get resultOutcome => text().nullable()();

  /// Cached analysis payload (Task 8), attached lazily after the game ends.
  TextColumn get analysisJson => text().nullable()();
}

/// Single-row app preferences (schema v2). Exactly one row ever exists, pinned
/// to `id = 1` by a table-level `CHECK (id = 1)`; the app upserts that row.
///
/// Enum-valued settings are stored as their `Enum.name` strings ([themeMode],
/// [animationSpeed], [defaultDifficulty]); [tutorOverride] is a nullable
/// tri-state ('on' | 'off' | null). Every column carries a default so the row
/// can be seeded with just its id (see [AppDatabase.migration]).
@DataClassName('SettingsRow')
class Settings extends Table {
  /// Always 1 (enforced by [customConstraints]). Defaulted so a bare
  /// `INSERT (id) VALUES (1)` fills every other column from its default.
  IntColumn get id => integer().withDefault(const Constant(1))();

  TextColumn get themeMode => text().withDefault(const Constant('system'))();
  TextColumn get animationSpeed =>
      text().withDefault(const Constant('normal'))();
  IntColumn get defaultMatchLength => integer().withDefault(const Constant(5))();
  TextColumn get defaultDifficulty =>
      text().withDefault(const Constant('medium'))();

  /// 'on' | 'off' | null (null = per-mode tutor default).
  TextColumn get tutorOverride => text().nullable()();

  /// Gameplay option toggles (schema v3). Everything besides the base tap-to-move
  /// play is optional (see Plan 7 Task 5).

  /// Whether the board paints selection rings and destination highlights.
  BoolColumn get showHighlights =>
      boolean().withDefault(const Constant(true))();

  /// Whether drag-to-move is enabled. ON by default as of schema v4: drag was
  /// too easy to miss when it shipped opt-in (Plan 7 Task 4), so tap AND drag
  /// are both first-class now. Tap-to-move still works regardless.
  BoolColumn get enableDrag => boolean().withDefault(const Constant(true))();

  /// Whether combined (multi-hop, same-checker) landing taps are enabled.
  BoolColumn get enableCombinedTaps =>
      boolean().withDefault(const Constant(true))();

  /// Whether the HUD shows the running match score.
  BoolColumn get showScoring => boolean().withDefault(const Constant(true))();

  /// Whether each roll tumbles before it settles (schema v5). ON by default —
  /// the beat is the app's roll feedback, and its absence was reported as a
  /// regression ("there is no dice animation now"). Turning it off makes every
  /// roll appear settled immediately; checker travel is unaffected (that is
  /// [animationSpeed]).
  BoolColumn get diceRollAnimation =>
      boolean().withDefault(const Constant(true))();

  /// Whether the hot-seat "Pass the device" cover screen is shown between turns
  /// (schema v6). OFF by default, per the reported "when playing with two
  /// persons, do not show the pass the device screen, or at least make it a
  /// setting, disabled by default". With it off the board simply flips to the
  /// new actor — that rotation IS the hand-over cue — and nothing has to be
  /// tapped through. Only ever consulted in a hot-seat match.
  BoolColumn get showPassDevice =>
      boolean().withDefault(const Constant(false))();

  /// Whether the one-time "you can drag OR tap checkers" discoverability hint
  /// has already been surfaced (schema v4). Flipped true the first time the hint
  /// shows, so it never appears twice. Starts false on a fresh install.
  BoolColumn get dragHintShown =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => const ['CHECK (id = 1)'];
}

/// The app's local SQLite database (matches + event-sourced games + the
/// single-row [Settings] preferences).
@DriftDatabase(tables: [Matches, Games, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  // Games.matchId is a SQL-level foreign key with ON DELETE CASCADE, but SQLite
  // only ENFORCES foreign keys when the per-connection `foreign_keys` pragma is
  // on (it defaults off). `beforeOpen` runs on every connection open, so the
  // pragma is applied for the app and for every test database. The Matches/Games
  // FK was added to v1 directly (pre-release, no bump); the Settings table is
  // the project's first real migration, added in v2.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1 -> v2: add the single-row Settings table. Its default row is
          // seeded by `beforeOpen` below (which runs right after this), so the
          // same upsert-if-absent covers both fresh creates and upgrades.
          if (from < 2) {
            // Fresh create of the settings table. `createTable` uses the CURRENT
            // (v6) table definition, so it already includes every gameplay
            // column, `drag_hint_shown`, `dice_roll_animation` AND
            // `show_pass_device` — the version-gated `addColumn` blocks below
            // must NOT re-add them (hence each is gated on an explicit range of
            // `from`, never `from < N+1`).
            await m.createTable(settings);
          }
          // v2 -> v3: add the four gameplay-option columns to the EXISTING v2
          // settings row. Each has a column default, so the pre-existing (seeded
          // or user-edited) row gains the new fields at their defaults while its
          // other values are preserved. Only runs when the table already existed
          // at v2 (a v1 -> v6 jump created it whole above).
          if (from == 2) {
            await m.addColumn(settings, settings.showHighlights);
            await m.addColumn(settings, settings.enableDrag);
            await m.addColumn(settings, settings.enableCombinedTaps);
            await m.addColumn(settings, settings.showScoring);
          }
          // v3 -> v4: add the `drag_hint_shown` column. It is absent from BOTH
          // the v2 and v3 table shapes (v2 had none of the gameplay columns; v3
          // had the four above but not this one), so add it whenever the table
          // existed pre-v4 — i.e. any upgrade from 2 or 3. A v1 -> v6 jump created
          // the table whole above, so this is skipped there.
          if (from == 2 || from == 3) {
            await m.addColumn(settings, settings.dragHintShown);
          }
          // v4 -> v5: add the `dice_roll_animation` column. Absent from every
          // pre-v5 table shape (v2, v3 and v4 alike), so add it whenever the
          // table already existed — i.e. any upgrade from 2, 3 or 4. Its column
          // default (ON) fills the migrated row, so an upgrading user gets the
          // beat back exactly as a fresh install does.
          if (from >= 2 && from <= 4) {
            await m.addColumn(settings, settings.diceRollAnimation);
          }
          // v5 -> v6: add the `show_pass_device` column, absent from every
          // pre-v6 table shape (v2..v5), so add it for any upgrade from 2..5.
          //
          // This got its OWN version rather than being folded into v5 even
          // though v5 was never released: v5 databases exist on the development
          // machines this branch is being played on, and a schemaVersion that
          // does not move leaves those installs with a table the code writes a
          // column into that is not there — every settings save then throws
          // `no column named show_pass_device`, which is exactly how this was
          // found. A version bump costs one migration branch and covers them.
          if (from >= 2 && from <= 5) {
            await m.addColumn(settings, settings.showPassDevice);
          }
          // v3 -> v4 one-time default flip: drag-to-move becomes ON by default.
          // Applied UNCONDITIONALLY to the existing settings row (not just when
          // it still holds the old default), so anyone who deliberately turned
          // drag OFF loses that here. Deliberate: the opt-out toggle shipped to
          // testers only hours before this flip, so the blast radius is a handful
          // of installs, and the alternative (drag silently missing) was the
          // exact feedback that motivated the flip. New installs get the ON
          // default from the column definition; this only rewrites upgraded rows.
          // Runs after the column-creation blocks above so `enable_drag` always
          // exists (for a v1 jump it was just created, and the row it targets is
          // seeded afterwards in `beforeOpen`, so the UPDATE is a harmless no-op
          // there). Gated on `from < 4` so a later upgrade never re-flips it.
          if (from < 4) {
            await customStatement('UPDATE settings SET enable_drag = 1');
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          // Ensure the single settings row exists. Idempotent (INSERT OR
          // IGNORE keyed on the id=1 primary key), so it is a no-op once seeded
          // and covers fresh onCreate databases and upgraded ones alike.
          await customStatement(
            'INSERT OR IGNORE INTO settings (id) VALUES (1)',
          );
        },
      );
}

/// The app-wide lazy database, opened on first use under the app-support
/// directory via drift_flutter. Closed when the [ProviderScope] is torn down.
///
/// Tests override this with `AppDatabase(NativeDatabase.memory())`.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(driftDatabase(name: 'aigammon'));
  ref.onDispose(db.close);
  return db;
});
