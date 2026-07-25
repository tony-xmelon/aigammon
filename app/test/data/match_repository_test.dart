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
}
