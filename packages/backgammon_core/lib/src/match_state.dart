import 'game_state.dart';
import 'player.dart';

/// Score state of a match, between games. Immutable.
///
/// matchLength is not validated (const constructor); callers supply positive
/// lengths. A 1-point match correctly treats its only game as the Crawford
/// game.
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

  @override
  bool operator ==(Object other) =>
      other is MatchState &&
      other.matchLength == matchLength &&
      other.whiteScore == whiteScore &&
      other.blackScore == blackScore &&
      other.crawfordPlayed == crawfordPlayed;

  @override
  int get hashCode =>
      Object.hash(matchLength, whiteScore, blackScore, crawfordPlayed);
}
