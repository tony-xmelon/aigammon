import 'dart:math';

import 'scored_move.dart';

/// AI strength levels. One engine serves all levels: lower levels sample
/// among near-best moves instead of always playing the best (design spec
/// §3). [equityWindow] caps how far below the best move a pick may be;
/// [temperature] controls how sharply better moves are preferred.
enum Difficulty {
  easy(equityWindow: 0.250, temperature: 0.080),
  medium(equityWindow: 0.120, temperature: 0.040),
  hard(equityWindow: 0.050, temperature: 0.020),
  expert(equityWindow: 0.0, temperature: 0.0);

  final double equityWindow;
  final double temperature;
  const Difficulty({required this.equityWindow, required this.temperature});
}

/// Picks a move from [ranked] (already sorted best-first) for [level].
/// Expert takes the top move. Others sample among moves within
/// [Difficulty.equityWindow] of the best, weighted by
/// exp(-(equityLoss) / temperature).
ScoredMove pickMove(List<ScoredMove> ranked, Difficulty level, Random rng) {
  if (ranked.isEmpty) {
    throw ArgumentError('ranked must not be empty');
  }
  if (level == Difficulty.expert || ranked.length == 1) {
    return ranked.first;
  }
  final best = ranked.first.equity;
  final candidates = [
    for (final s in ranked)
      if (best - s.equity <= level.equityWindow) s,
  ];
  final weights = [
    for (final s in candidates)
      exp(-(best - s.equity) / level.temperature),
  ];
  final total = weights.reduce((a, b) => a + b);
  var roll = rng.nextDouble() * total;
  for (var i = 0; i < candidates.length; i++) {
    roll -= weights[i];
    if (roll <= 0) return candidates[i];
  }
  return candidates.last;
}
