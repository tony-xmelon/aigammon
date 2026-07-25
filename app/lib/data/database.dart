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
  int get schemaVersion => 2;

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
            await m.createTable(settings);
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
