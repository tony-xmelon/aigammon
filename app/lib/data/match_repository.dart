import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';

/// Persists matches and their games (event logs) to the local [AppDatabase].
///
/// A game is stored as the core's JSON event log; replaying it with
/// [Game.replay] reproduces the exact final state, so the DB never stores
/// derived board state — only the folded [GameResult] alongside, for cheap
/// listing without a replay.
class MatchRepository {
  MatchRepository(this.db);

  final AppDatabase db;

  /// Creates the match row at match start and returns its generated id.
  Future<int> startMatch({
    required int matchLength,
    required String mode,
    required String whiteType,
    required String blackType,
  }) {
    return db.into(db.matches).insert(MatchesCompanion.insert(
          createdAt: DateTime.now(),
          matchLength: matchLength,
          mode: mode,
          whiteType: whiteType,
          blackType: blackType,
        ));
  }

  /// Appends one finished game's event log and its folded result. Returns the
  /// generated game id.
  Future<int> recordGame({
    required int matchId,
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
  }) {
    return db.into(db.games).insert(GamesCompanion.insert(
          matchId: matchId,
          gameNumber: gameNumber,
          isCrawford: isCrawford,
          eventsJson: _encodeEvents(events),
          resultWinner: Value(result.winner.name),
          resultPoints: Value(result.points),
          resultOutcome: Value(result.outcome.name),
        ));
  }

  /// Updates the running score for [matchId].
  Future<void> updateScore({
    required int matchId,
    required int whiteScore,
    required int blackScore,
  }) async {
    await (db.update(db.matches)..where((m) => m.id.equals(matchId))).write(
      MatchesCompanion(
        whiteScore: Value(whiteScore),
        blackScore: Value(blackScore),
      ),
    );
  }

  /// Marks [matchId] complete with the winning side ('white' | 'black').
  Future<void> completeMatch({
    required int matchId,
    required String winner,
  }) async {
    await (db.update(db.matches)..where((m) => m.id.equals(matchId))).write(
      MatchesCompanion(
        completed: const Value(true),
        winner: Value(winner),
      ),
    );
  }

  /// Deletes every UNFINISHED match that recorded no games at all, returning
  /// how many rows went.
  ///
  /// A match row is inserted the instant a match is LAUNCHED, so every match a
  /// user backs out of before finishing a single game leaves a permanent
  /// "White 0 — 0 Black" row in history. Those rows carry no information (no
  /// games, no score, and — since there is no resume — nothing to return to),
  /// so they are swept on every history load. Matches with at least one
  /// recorded game are kept: their games are analysable.
  ///
  /// Deliberately narrow: `completed = 0 AND no games AND older than [minAge]`.
  /// A completed match is never touched (a 0–0 completed match cannot occur),
  /// and an unfinished match with games survives as an "Unfinished" row.
  ///
  /// ## Why the age guard
  ///
  /// [recordGame] is fired and awaited OFF the UI thread's critical path, so a
  /// match can be gameless for a moment while its first game is mid-insert. A
  /// user who pops the game screen and reaches History fast enough would then
  /// race that insert: the purge deletes the match row, and the in-flight
  /// game insert either fails or is swept by the `ON DELETE CASCADE` — silently
  /// losing a real, analysable game. Only sweeping rows that have been sitting
  /// around for [minAge] puts the purge well clear of any live write; the
  /// litter it exists to clean is minutes-to-days old by the time anyone sees
  /// it. Tests pass [Duration.zero] to sweep deterministically.
  Future<int> deleteEmptyAbandonedMatches({
    Duration minAge = const Duration(minutes: 2),
  }) {
    final cutoff = DateTime.now().subtract(minAge);
    // `<=`, not `<`: created_at is stored at one-second resolution, so a match
    // created within the current second must still count as "at least minAge
    // old" when minAge is zero (the test sweep). At the two-minute default the
    // boundary is immaterial.
    return db.customUpdate(
      'DELETE FROM matches WHERE completed = 0 '
      'AND created_at <= ? '
      'AND id NOT IN (SELECT match_id FROM games)',
      variables: [Variable<DateTime>(cutoff)],
      updates: {db.matches},
      updateKind: UpdateKind.delete,
    );
  }

  /// Hard-deletes [matchId]. Its games go with it through the `ON DELETE
  /// CASCADE` foreign key on `games.match_id` (enforced because the database's
  /// `beforeOpen` turns `PRAGMA foreign_keys` on), so this single statement
  /// leaves no orphans. Irreversible — callers confirm first.
  Future<void> deleteMatch(int matchId) async {
    await (db.delete(db.matches)..where((m) => m.id.equals(matchId))).go();
  }

  /// All matches, newest first. Ties on [createdAt] break by descending id so
  /// the order is stable and still puts the most recently inserted row first.
  Stream<List<MatchRow>> watchMatches() {
    return (db.select(db.matches)
          ..orderBy([
            (m) => OrderingTerm.desc(m.createdAt),
            (m) => OrderingTerm.desc(m.id),
          ]))
        .watch();
  }

  /// The single match row for [matchId]. Throws if no such match exists.
  Future<MatchRow> loadMatch(int matchId) {
    return (db.select(db.matches)..where((m) => m.id.equals(matchId)))
        .getSingle();
  }

  /// The single game row for [gameId] (metadata: matchId, gameNumber,
  /// isCrawford, folded result). Throws if no such game exists.
  Future<GameRow> loadGame(int gameId) {
    return (db.select(db.games)..where((g) => g.id.equals(gameId)))
        .getSingle();
  }

  /// The games of [matchId] in play order.
  Future<List<GameRow>> gamesFor(int matchId) {
    return (db.select(db.games)
          ..where((g) => g.matchId.equals(matchId))
          ..orderBy([(g) => OrderingTerm.asc(g.gameNumber)]))
        .get();
  }

  /// Decodes the stored event log for [gameId] back into [GameEvent]s.
  Future<List<GameEvent>> loadGameEvents(int gameId) async {
    final row = await (db.select(db.games)..where((g) => g.id.equals(gameId)))
        .getSingle();
    return _decodeEvents(row.eventsJson);
  }

  /// Attaches (or replaces) the cached analysis payload for [gameId].
  Future<void> saveAnalysis(int gameId, String analysisJson) async {
    await (db.update(db.games)..where((g) => g.id.equals(gameId)))
        .write(GamesCompanion(analysisJson: Value(analysisJson)));
  }

  /// The cached analysis payload for [gameId], or null if none.
  Future<String?> loadAnalysis(int gameId) async {
    final row = await (db.select(db.games)..where((g) => g.id.equals(gameId)))
        .getSingle();
    return row.analysisJson;
  }

  static String _encodeEvents(List<GameEvent> events) =>
      jsonEncode([for (final e in events) e.toJson()]);

  static List<GameEvent> _decodeEvents(String json) => [
        for (final m in jsonDecode(json) as List)
          GameEvent.fromJson((m as Map).cast<String, dynamic>()),
      ];
}

/// The app-wide [MatchRepository] over the lazy [databaseProvider].
final matchRepositoryProvider = Provider<MatchRepository>((ref) {
  return MatchRepository(ref.watch(databaseProvider));
});

/// All matches, newest first, as a live stream (drift re-emits on write). The
/// history screen watches this.
final matchesProvider = StreamProvider<List<MatchRow>>((ref) {
  return ref.watch(matchRepositoryProvider).watchMatches();
});
