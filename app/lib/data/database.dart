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
  IntColumn get matchId =>
      integer().references(Matches, #id, onDelete: KeyAction.cascade)();
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

/// The app's local SQLite database (matches + event-sourced games).
@DriftDatabase(tables: [Matches, Games])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;
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
