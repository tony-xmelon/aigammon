import 'game_state.dart';
import 'player.dart';

/// Score state of a match, between games. Immutable.
class MatchState {
  final int matchLength;
  final int whiteScore;
  final int blackScore;
  final bool crawfordPlayed;

  const MatchState({
    required this.matchLength,
    this.whiteScore = 0,
    this.blackScore = 0,
    this.crawfordPlayed = false,
  });

  bool get isMatchOver =>
      whiteScore >= matchLength || blackScore >= matchLength;

  Player? get winner => !isMatchOver
      ? null
      : (whiteScore >= matchLength ? Player.white : Player.black);

  /// True when the game about to be played is the Crawford game
  /// (no doubling allowed in it).
  bool get isCrawfordNext {
    if (crawfordPlayed || isMatchOver) return false;
    return whiteScore == matchLength - 1 || blackScore == matchLength - 1;
  }

  MatchState applyResult(GameResult r) {
    final crawfordJustPlayed = isCrawfordNext;
    return MatchState(
      matchLength: matchLength,
      whiteScore: whiteScore + (r.winner == Player.white ? r.points : 0),
      blackScore: blackScore + (r.winner == Player.black ? r.points : 0),
      crawfordPlayed: crawfordPlayed || crawfordJustPlayed,
    );
  }
}
