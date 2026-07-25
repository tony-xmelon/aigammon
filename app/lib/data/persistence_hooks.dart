import 'package:backgammon_core/backgammon_core.dart';

import 'match_repository.dart';

/// Controller-facing persistence seam. The [GameController] calls these hooks
/// as a match progresses; the default binding is a [NoopPersistence] so play
/// works with persistence off (and tests need no database).
///
/// Implementations must be robust: the controller wraps every call in a
/// try/catch and treats a throw as non-fatal, so a failing persistence layer
/// never stops a match.
abstract interface class MatchPersistence {
  /// Called right after a game ends, with that game's full event log, its
  /// folded [result], and the [matchAfter] state (score already updated).
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  });

  /// Called once the match is decided, with its final score state.
  Future<void> onMatchFinished(MatchState finalState);
}

/// Persistence disabled: every hook is a no-op. The controller's default.
class NoopPersistence implements MatchPersistence {
  const NoopPersistence();

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {}

  @override
  Future<void> onMatchFinished(MatchState finalState) async {}
}

/// Persists match progress through a [MatchRepository].
///
/// The match row is created before the controller starts (by the setup
/// screen); its id arrives via [matchIdFuture], which every hook awaits so a
/// slow initial insert never drops a game.
class RepositoryPersistence implements MatchPersistence {
  RepositoryPersistence(this.repo, this.matchIdFuture);

  final MatchRepository repo;
  final Future<int> matchIdFuture;

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {
    final matchId = await matchIdFuture;
    await repo.recordGame(
      matchId: matchId,
      gameNumber: gameNumber,
      isCrawford: isCrawford,
      events: events,
      result: result,
    );
    await repo.updateScore(
      matchId: matchId,
      whiteScore: matchAfter.whiteScore,
      blackScore: matchAfter.blackScore,
    );
  }

  @override
  Future<void> onMatchFinished(MatchState finalState) async {
    final matchId = await matchIdFuture;
    final winner = finalState.winner;
    if (winner == null) return;
    await repo.completeMatch(matchId: matchId, winner: winner.name);
  }
}
