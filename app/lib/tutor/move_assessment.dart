import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';

/// A quality mark for a played move (or a cube action), ranked from [best]
/// (the top-equity play) down to [blunder] (a large equity give-up).
enum MoveMark { best, good, dubious, error, blunder }

/// gnubg-inspired equity-loss thresholds, in cubeless equity points
/// (`[-3, 3]` scale). A move is marked by how much equity it gives up versus
/// the best play:
///
///  * `< best`    (`< 0.001`) -> [MoveMark.best]    — the top play (float fuzz).
///  * `< dubious` (`< 0.02`)  -> [MoveMark.good]     — a fine alternative.
///  * `< error`   (`< 0.05`)  -> [MoveMark.dubious]  — questionable ("?!").
///  * `< blunder` (`< 0.11`)  -> [MoveMark.error]    — an error ("?").
///  * `>= blunder`(`>= 0.11`) -> [MoveMark.blunder]  — a blunder ("??").
///
/// NOTE: an earlier plan sketch used slightly different bands; these are the
/// authoritative, documented values (close to gnubg's move-filter tiers).
class TutorThresholds {
  /// Below this the play is effectively the best (absorbs floating-point
  /// noise between two equal-equity plays).
  static const double best = 0.001;
  static const double dubious = 0.02;
  static const double error = 0.05;
  static const double blunder = 0.11;
}

/// Classifies an [equityLoss] (best-play equity minus played equity, always
/// `>= 0`) into a [MoveMark] using [TutorThresholds]. See that class for the
/// band definitions.
MoveMark markFor(double equityLoss) {
  if (equityLoss < TutorThresholds.best) return MoveMark.best;
  if (equityLoss < TutorThresholds.dubious) return MoveMark.good;
  if (equityLoss < TutorThresholds.error) return MoveMark.dubious;
  if (equityLoss < TutorThresholds.blunder) return MoveMark.error;
  return MoveMark.blunder;
}

// --- JSON helpers (shared by the assessment models) -------------------------
//
// Move is encoded as a list of [from, to, isHit] triples, mirroring the core
// event log (see GameEvent.moveToJson). Probabilities are a 5-double list in
// the canonical order [win, winGammon, winBackgammon, loseGammon,
// loseBackgammon].

List<List<Object>> _moveToJson(Move m) =>
    [for (final c in m.checkerMoves) [c.from, c.to, c.isHit]];

Move _moveFromJson(List<dynamic> hops) => Move([
      for (final h in hops)
        CheckerMove((h[0] as num).toInt(), (h[1] as num).toInt(),
            isHit: h[2] as bool),
    ]);

List<double> _probsToJson(Probabilities p) => [
      p.win,
      p.winGammon,
      p.winBackgammon,
      p.loseGammon,
      p.loseBackgammon,
    ];

Probabilities _probsFromJson(List<dynamic> l) => Probabilities(
      win: (l[0] as num).toDouble(),
      winGammon: (l[1] as num).toDouble(),
      winBackgammon: (l[2] as num).toDouble(),
      loseGammon: (l[3] as num).toDouble(),
      loseBackgammon: (l[4] as num).toDouble(),
    );

Map<String, dynamic> _scoredToJson(ScoredMove s) => {
      'move': _moveToJson(s.move),
      'probs': _probsToJson(s.probabilities),
    };

ScoredMove _scoredFromJson(Map<String, dynamic> j) => ScoredMove(
      move: _moveFromJson(j['move'] as List),
      probabilities: _probsFromJson(j['probs'] as List),
    );

/// The tutor's verdict on a single played move: what was played, the best
/// available play, the equity given up, the resulting [mark], and the full
/// ranking (for display).
class MoveAssessment {
  /// The move the player actually made.
  final Move played;

  /// The engine's top-ranked play. [Move.none] on a dance (no legal play).
  final Move best;

  /// Cubeless equity given up versus [best], always `>= 0`.
  final double equityLoss;

  /// The mark derived from [equityLoss] via [markFor].
  final MoveMark mark;

  /// The full engine ranking of candidate plays, best first (for display).
  final List<ScoredMove> ranked;

  MoveAssessment({
    required this.played,
    required this.best,
    required this.equityLoss,
    required this.ranked,
  }) : mark = markFor(equityLoss);

  Map<String, dynamic> toJson() => {
        'played': _moveToJson(played),
        'best': _moveToJson(best),
        'equityLoss': equityLoss,
        'mark': mark.name,
        'ranked': [for (final s in ranked) _scoredToJson(s)],
      };

  /// Rebuilds from [toJson]. [mark] is recomputed from [equityLoss] (the
  /// stored `mark` string is display metadata and is not trusted here).
  factory MoveAssessment.fromJson(Map<String, dynamic> j) => MoveAssessment(
        played: _moveFromJson(j['played'] as List),
        best: _moveFromJson(j['best'] as List),
        equityLoss: (j['equityLoss'] as num).toDouble(),
        ranked: [
          for (final s in (j['ranked'] as List))
            _scoredFromJson(s as Map<String, dynamic>),
        ],
      );
}

/// The tutor's verdict on a pre-roll cube decision: what the player did (or
/// considered), the advisor's verdict, and the match-equity given up.
///
/// CAVEAT ON SCALE. [MoveAssessment.equityLoss] is a cubeless equity in
/// `[-3, 3]`; the cube [equityLoss] here is a MATCH-WINNING-PROBABILITY loss
/// in `[0, 1]` (the [MatchCubeAdvice] equities are match-win probabilities).
/// The two are NOT the same unit. We deliberately reuse the SAME [markFor]
/// bands as a documented v1 approximation: a match-equity swing of, say, 0.05
/// is a real error, so the bands read sensibly, but they are not calibrated to
/// match-play theory. A future refinement may use cube-specific thresholds.
class CubeAssessment {
  /// What the player did (or is considering): `true` = doubled, `false` =
  /// rolled on without doubling.
  final bool actionWasDouble;

  /// The advisor's verdict for this decision point.
  final MatchCubeAdvice advice;

  const CubeAssessment({
    required this.actionWasDouble,
    required this.advice,
  });

  /// The mover's match-winning probability after the OPTIMAL double, i.e. the
  /// branch the opponent would choose (the worse one for the mover):
  /// `min(equityDoubleTake, equityDoubleDrop)`.
  double get bestDoubledEquity =>
      advice.equityDoubleTake < advice.equityDoubleDrop
          ? advice.equityDoubleTake
          : advice.equityDoubleDrop;

  /// Match-equity given up by the player's action versus the advisor's verdict.
  ///
  ///  * Advisor says DOUBLE but the player rolled on:
  ///    `bestDoubledEquity - equityNoDouble` (positive — doubling was better).
  ///  * Advisor says NO-DOUBLE but the player doubled:
  ///    `equityNoDouble - bestDoubledEquity` (positive — holding was better).
  ///  * The action matches the advice: `0`.
  double get equityLoss {
    if (advice.shouldDouble && !actionWasDouble) {
      return bestDoubledEquity - advice.equityNoDouble;
    }
    if (!advice.shouldDouble && actionWasDouble) {
      return advice.equityNoDouble - bestDoubledEquity;
    }
    return 0;
  }

  /// The mark derived from [equityLoss] via [markFor] (see the class caveat on
  /// the match-equity scale).
  MoveMark get mark => markFor(equityLoss);

  Map<String, dynamic> toJson() => {
        'actionWasDouble': actionWasDouble,
        'advice': {
          'shouldDouble': advice.shouldDouble,
          'shouldTake': advice.shouldTake,
          'equityNoDouble': advice.equityNoDouble,
          'equityDoubleTake': advice.equityDoubleTake,
          'equityDoubleDrop': advice.equityDoubleDrop,
        },
      };

  factory CubeAssessment.fromJson(Map<String, dynamic> j) {
    final a = j['advice'] as Map<String, dynamic>;
    return CubeAssessment(
      actionWasDouble: j['actionWasDouble'] as bool,
      advice: MatchCubeAdvice(
        shouldDouble: a['shouldDouble'] as bool,
        shouldTake: a['shouldTake'] as bool,
        equityNoDouble: (a['equityNoDouble'] as num).toDouble(),
        equityDoubleTake: (a['equityDoubleTake'] as num).toDouble(),
        equityDoubleDrop: (a['equityDoubleDrop'] as num).toDouble(),
      ),
    );
  }
}
