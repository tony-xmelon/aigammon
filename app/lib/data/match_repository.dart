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
