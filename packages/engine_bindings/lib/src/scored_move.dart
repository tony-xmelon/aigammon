import 'package:backgammon_core/backgammon_core.dart';

/// Cubeless evaluation from the evaluated player's perspective.
/// Cumulative semantics (wildbg): win includes gammon+bg wins; winGammon
/// includes backgammon wins.
class Probabilities {
  final double win;
  final double winGammon;
  final double winBackgammon;
  final double loseGammon;
  final double loseBackgammon;

  const Probabilities({
    required this.win,
    required this.winGammon,
    required this.winBackgammon,
    required this.loseGammon,
    required this.loseBackgammon,
  });

  /// Cubeless equity in [-3, 3].
  double get equity =>
      2 * win - 1 + winGammon + winBackgammon - loseGammon - loseBackgammon;

  /// The same position seen by the opponent.
  Probabilities get inverted => Probabilities(
        win: 1 - win,
        winGammon: loseGammon,
        winBackgammon: loseBackgammon,
        loseGammon: winGammon,
        loseBackgammon: winBackgammon,
      );

  @override
  String toString() =>
      'P(win $win, wg $winGammon, wbg $winBackgammon, lg $loseGammon, lbg $loseBackgammon)';
}

class ScoredMove {
  final Move move;
  final Probabilities probabilities; // mover's perspective, after the move
  double get equity => probabilities.equity;
  const ScoredMove({required this.move, required this.probabilities});
}

/// wildbg cube advice (Janowski-based internally), money or match-aware.
class CubeAdvice {
  final bool shouldDouble;
  final bool shouldAccept;
  final double equityCubeless;
  final double equityNoDouble;
  final double equityDoubleTake;
  const CubeAdvice({
    required this.shouldDouble,
    required this.shouldAccept,
    required this.equityCubeless,
    required this.equityNoDouble,
    required this.equityDoubleTake,
  });
}
