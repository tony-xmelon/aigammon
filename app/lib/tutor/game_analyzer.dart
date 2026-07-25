import 'package:backgammon_core/backgammon_core.dart';

import 'move_assessment.dart';
import 'tutor_service.dart';

/// The tutor's verdict on one played move within a recorded game, tagged with
/// its position in the event log ([eventIndex]) and the [player] who moved.
class MoveAnalysis {
  /// Index of the assessed [MoveEvent] in the game's event list. Doubles as the
  /// cursor position the analysis screen jumps to.
  final int eventIndex;

  /// The side that played the move.
  final Player player;

  /// The move quality verdict (equity loss, mark, best play, full ranking).
  final MoveAssessment assessment;

  const MoveAnalysis({
    required this.eventIndex,
    required this.player,
    required this.assessment,
  });

  Map<String, dynamic> toJson() => {
        'eventIndex': eventIndex,
        'player': player.name,
        'assessment': assessment.toJson(),
      };

  factory MoveAnalysis.fromJson(Map<String, dynamic> j) => MoveAnalysis(
        eventIndex: (j['eventIndex'] as num).toInt(),
        player: Player.values.byName(j['player'] as String),
        assessment:
            MoveAssessment.fromJson((j['assessment'] as Map).cast<String, dynamic>()),
      );
}

/// The full move-by-move analysis of one game: every [MoveEvent] (for BOTH
/// players) assessed against the best available play. The analysis screen
/// filters by side for display; the aggregate helpers ([errorRate],
/// [blunderCount]) do their own per-player filtering.
class GameAnalysis {
  /// Serialized JSON schema version, so a future format change is detectable.
  static const int version = 1;

  final List<MoveAnalysis> moves;

  const GameAnalysis(this.moves);

  /// Mean equity loss across every move [p] played (0 when [p] made no moves).
  /// Dance moves count as 0-loss moves (they still divide the mean), matching
  /// how [TutorService.assess] scores a forced pass.
  double errorRate(Player p) {
    final own = moves.where((m) => m.player == p).toList();
    if (own.isEmpty) return 0;
    final total =
        own.fold<double>(0, (sum, m) => sum + m.assessment.equityLoss);
    return total / own.length;
  }

  /// Number of [MoveMark.blunder] moves [p] played.
  int blunderCount(Player p) => moves
      .where((m) => m.player == p && m.assessment.mark == MoveMark.blunder)
      .length;

  Map<String, dynamic> toJson() => {
        'v': version,
        'moves': [for (final m in moves) m.toJson()],
      };

  /// Rebuilds from [toJson]. Throws [FormatException] on an unknown version.
  factory GameAnalysis.fromJson(Map<String, dynamic> j) {
    final v = (j['v'] as num?)?.toInt();
    if (v != version) {
      throw FormatException('unsupported GameAnalysis version: $v');
    }
    return GameAnalysis([
      for (final m in (j['moves'] as List))
        MoveAnalysis.fromJson((m as Map).cast<String, dynamic>()),
    ]);
  }
}

/// Replays a recorded event log and assesses every played move with a
/// [TutorService], producing a [GameAnalysis].
class GameAnalyzer {
  GameAnalyzer(this.tutor);

  final TutorService tutor;

  /// Replays [events] once, incrementally, capturing the pre-move state before
  /// each [MoveEvent] and assessing the move against it. Both players' moves are
  /// assessed (the analysis screen filters for display).
  ///
  /// The event log is folded with a single running [Game] (seed with the
  /// leading [OpeningRollEvent] via [Game.start], then [Game.append] the rest),
  /// so this is O(n) appends rather than O(n) full replays.
  ///
  /// [onProgress] (if given) is called with a value in `[0, 1]`, monotonically
  /// non-decreasing, starting at 0 and ending at 1.
  Future<GameAnalysis> analyze(
    List<GameEvent> events, {
    required bool isCrawford,
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(0);
    if (events.isEmpty) {
      onProgress?.call(1);
      return const GameAnalysis([]);
    }

    final opening = events.first as OpeningRollEvent;
    var game = Game.start(opening, isCrawfordGame: isCrawford);

    final moves = <MoveAnalysis>[];
    final total = events.length - 1; // events appended after the opening roll
    for (var i = 1; i < events.length; i++) {
      final event = events[i];
      if (event is MoveEvent) {
        // The running game's state is exactly the moving-phase state this move
        // was played from.
        final before = game.state;
        final assessment = await tutor.assess(before, event.move);
        moves.add(MoveAnalysis(
          eventIndex: i,
          player: event.player,
          assessment: assessment,
        ));
      }
      game = game.append(event);
      onProgress?.call(total == 0 ? 1 : i / total);
    }
    onProgress?.call(1);
    return GameAnalysis(moves);
  }
}
