import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  const win2 = GameResult(
      winner: Player.white, points: 2, outcome: GameOutcome.single);

  test('scores accumulate and the match ends at the match length', () {
    var m = MatchState(matchLength: 3);
    m = m.applyResult(win2);
    expect(m.whiteScore, 2);
    expect(m.isMatchOver, isFalse);
    m = m.applyResult(win2);
    expect(m.isMatchOver, isTrue);
    expect(m.winner, Player.white);
  });

  test('reaching matchLength-1 makes the next game the Crawford game', () {
    var m = MatchState(matchLength: 3);
    expect(m.isCrawfordNext, isFalse);
    m = m.applyResult(win2); // white at 2 of 3
    expect(m.isCrawfordNext, isTrue);
    // Black wins the Crawford game 1 point; doubling returns afterwards.
    m = m.applyResult(const GameResult(
        winner: Player.black, points: 1, outcome: GameOutcome.single));
    expect(m.blackScore, 1);
    expect(m.isCrawfordNext, isFalse);
    expect(m.crawfordPlayed, isTrue);
  });

  test('crawford only triggers once even if the other player also reaches -1',
      () {
    var m = MatchState(matchLength: 3)
        .applyResult(win2) // white 2-0, next is crawford
        .applyResult(const GameResult(
            winner: Player.black, points: 2, outcome: GameOutcome.gammon));
    // black jumped to 2 as well, but crawford was already played
    expect(m.whiteScore, 2);
    expect(m.blackScore, 2);
    expect(m.isCrawfordNext, isFalse);
  });

  test('black can win the match, including past the match length', () {
    final m = MatchState(matchLength: 3, blackScore: 2).applyResult(
        const GameResult(
            winner: Player.black, points: 4, outcome: GameOutcome.gammon));
    expect(m.blackScore, 6); // overshoot past matchLength
    expect(m.isMatchOver, isTrue);
    expect(m.winner, Player.black);
  });

  test('value equality', () {
    expect(MatchState(matchLength: 5), MatchState(matchLength: 5));
    expect(MatchState(matchLength: 5),
        isNot(MatchState(matchLength: 5, whiteScore: 1)));
  });
}
