import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_database.dart';

/// Builds a short but real, deterministic game: white opens (6,1) and plays a
/// legal move, black doubles, white drops. Produces a genuine [GameResult]
/// (black wins 1, a drop) with a full event log.
Game buildSampleGame() {
  final g0 = Game.start(
      const OpeningRollEvent(whiteDie: 6, blackDie: 1));
  final g1 = g0.append(MoveEvent(Player.white, g0.state.legalMoves.first));
  final g2 = g1.append(const DoubleEvent(Player.black));
  final g3 = g2.append(const DropEvent(Player.white));
  return g3;
}

void main() {
  late AppDatabase db;
  late MatchRepository repo;

  setUp(() {
    db = newTestDatabase();
    repo = MatchRepository(db);
  });

  tearDown(() => db.close());

  test('startMatch inserts a row and returns its id', () async {
    final id = await repo.startMatch(
      matchLength: 5,
      mode: 'vsComputer',
      whiteType: 'human',
      blackType: 'ai:expert',
    );
    expect(id, greaterThan(0));

    final rows = await repo.watchMatches().first;
    expect(rows, hasLength(1));
    expect(rows.single.matchLength, 5);
    expect(rows.single.mode, 'vsComputer');
    expect(rows.single.whiteType, 'human');
    expect(rows.single.blackType, 'ai:expert');
    expect(rows.single.whiteScore, 0);
    expect(rows.single.blackScore, 0);
    expect(rows.single.completed, isFalse);
    expect(rows.single.winner, isNull);
  });

  test('recordGame + loadGameEvents round-trip: replay reproduces the state',
      () async {
    final matchId = await repo.startMatch(
      matchLength: 1,
      mode: 'vsComputer',
      whiteType: 'human',
      blackType: 'ai:hard',
    );
    final game = buildSampleGame();
    final result = game.state.result!;

    final gameId = await repo.recordGame(
      matchId: matchId,
      gameNumber: 1,
      isCrawford: game.state.isCrawfordGame,
      events: game.events,
      result: result,
    );

    final loaded = await repo.loadGameEvents(gameId);
    expect(loaded, hasLength(game.events.length));

    // Replaying the persisted events reproduces the exact final state.
    final replayed = Game.replay(loaded);
    expect(replayed.state, game.state);
    expect(replayed.state.result, result);

    // The folded result was persisted alongside for cheap listing.
    final gameRows = await repo.gamesFor(matchId);
    expect(gameRows, hasLength(1));
    expect(gameRows.single.resultWinner, result.winner.name);
    expect(gameRows.single.resultPoints, result.points);
    expect(gameRows.single.resultOutcome, result.outcome.name);
    expect(gameRows.single.gameNumber, 1);
  });

  test('watchMatches emits newest-first', () async {
    final first = await repo.startMatch(
      matchLength: 3,
      mode: 'hotSeat',
      whiteType: 'human',
      blackType: 'human',
    );
    final second = await repo.startMatch(
      matchLength: 5,
      mode: 'vsComputer',
      whiteType: 'human',
      blackType: 'ai:medium',
    );

    final rows = await repo.watchMatches().first;
    expect(rows.map((r) => r.id).toList(), [second, first],
        reason: 'most recently created match comes first');
  });

  test('updateScore and completeMatch persist', () async {
    final matchId = await repo.startMatch(
      matchLength: 3,
      mode: 'vsComputer',
      whiteType: 'human',
      blackType: 'ai:easy',
    );

    await repo.updateScore(matchId: matchId, whiteScore: 2, blackScore: 1);
    var row = (await repo.watchMatches().first).single;
    expect(row.whiteScore, 2);
    expect(row.blackScore, 1);
    expect(row.completed, isFalse);

    await repo.completeMatch(matchId: matchId, winner: 'white');
    row = (await repo.watchMatches().first).single;
    expect(row.completed, isTrue);
    expect(row.winner, 'white');
  });

  test('analysis save/load round-trip', () async {
    final matchId = await repo.startMatch(
      matchLength: 1,
      mode: 'vsComputer',
      whiteType: 'human',
      blackType: 'ai:expert',
    );
    final game = buildSampleGame();
    final gameId = await repo.recordGame(
      matchId: matchId,
      gameNumber: 1,
      isCrawford: game.state.isCrawfordGame,
      events: game.events,
      result: game.state.result!,
    );

    expect(await repo.loadAnalysis(gameId), isNull);

    const payload = '{"blunders":2,"per_move":[0.01,0.2]}';
    await repo.saveAnalysis(gameId, payload);
    expect(await repo.loadAnalysis(gameId), payload);
  });

  group('history hygiene', () {
    Future<int> startMatch() => repo.startMatch(
          matchLength: 3,
          mode: 'vsComputer',
          whiteType: 'human',
          blackType: 'ai:expert',
        );

    Future<void> recordOneGame(int matchId) async {
      final game = buildSampleGame();
      await repo.recordGame(
        matchId: matchId,
        gameNumber: 1,
        isCrawford: game.state.isCrawfordGame,
        events: game.events,
        result: game.state.result!,
      );
    }

    test('deleteEmptyAbandonedMatches purges only gameless unfinished matches',
        () async {
      // Three abandoned matches with no games at all — the history litter.
      final empty = [for (var i = 0; i < 3; i++) await startMatch()];
      // An unfinished match that DID record a game: keeps its analysable game.
      final unfinishedWithGame = await startMatch();
      await recordOneGame(unfinishedWithGame);
      // A finished match.
      final completed = await startMatch();
      await recordOneGame(completed);
      await repo.completeMatch(matchId: completed, winner: 'white');

      final purged = await repo.deleteEmptyAbandonedMatches();
      expect(purged, 3, reason: 'exactly the gameless in-progress rows go');

      final ids = [for (final m in await repo.watchMatches().first) m.id];
      expect(ids, containsAll([unfinishedWithGame, completed]));
      for (final id in empty) {
        expect(ids, isNot(contains(id)));
      }
    });

    test('deleteEmptyAbandonedMatches is a no-op on a clean history', () async {
      final matchId = await startMatch();
      await recordOneGame(matchId);
      expect(await repo.deleteEmptyAbandonedMatches(), 0);
      expect(await repo.watchMatches().first, hasLength(1));
    });

    test('deleteMatch removes the match and cascades to its games', () async {
      final matchId = await startMatch();
      await recordOneGame(matchId);
      final keep = await startMatch();
      await recordOneGame(keep);

      await repo.deleteMatch(matchId);

      final rows = await repo.watchMatches().first;
      expect([for (final m in rows) m.id], [keep]);
      expect(await repo.gamesFor(matchId), isEmpty,
          reason: 'the cascade removes the deleted match\'s games');
      expect(await repo.gamesFor(keep), hasLength(1),
          reason: 'other matches are untouched');
    });
  });

  group('foreign-key hardening', () {
    test('games table DDL declares a REAL SQL foreign key with cascade',
        () async {
      final row = await db
          .customSelect(
              "SELECT sql FROM sqlite_master WHERE type='table' AND name='games'")
          .getSingle();
      final sql = row.read<String>('sql');
      expect(sql, contains('REFERENCES matches (id)'),
          reason: 'the DDL must carry a real SQL foreign key, not just a '
              'drift-side relation');
      expect(sql.toUpperCase(), contains('ON DELETE CASCADE'));
    });

    test('foreign_keys pragma is ON for the connection', () async {
      final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(row.read<int>('foreign_keys'), 1,
          reason: 'beforeOpen must enable FK enforcement');
    });

    test('deleting a match cascades to its games', () async {
      final matchId = await repo.startMatch(
        matchLength: 1,
        mode: 'vsComputer',
        whiteType: 'human',
        blackType: 'ai:expert',
      );
      final game = buildSampleGame();
      await repo.recordGame(
        matchId: matchId,
        gameNumber: 1,
        isCrawford: game.state.isCrawfordGame,
        events: game.events,
        result: game.state.result!,
      );
      expect(await repo.gamesFor(matchId), hasLength(1));

      await (db.delete(db.matches)..where((m) => m.id.equals(matchId))).go();

      expect(await repo.gamesFor(matchId), isEmpty,
          reason: 'ON DELETE CASCADE must remove the orphaned games');
    });
  });
}
