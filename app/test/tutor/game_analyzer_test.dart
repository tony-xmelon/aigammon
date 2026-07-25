import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/tutor/game_analyzer.dart';
import 'package:aigammon_app/tutor/move_assessment.dart';
import 'package:aigammon_app/tutor/tutor_service.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gammonless probabilities whose cubeless equity equals [equity].
Probabilities _probs(double equity) => Probabilities(
      win: (equity + 1) / 2,
      winGammon: 0,
      winBackgammon: 0,
      loseGammon: 0,
      loseBackgammon: 0,
    );

ScoredMove _scored(Move move, double equity) =>
    ScoredMove(move: move, probabilities: _probs(equity));

/// A ranking for one [rankMoves] call: places [played] at a known equity below
/// a fabricated best (built from [played] plus one extra hop, so it can never
/// be `sameAs` [played]). A [loss] of 0 puts [played] on top, giving loss 0.
List<ScoredMove> _ranking(Move played, double loss, {double bestEq = 0.5}) {
  if (loss == 0) return [_scored(played, bestEq)];
  final best = Move([...played.checkerMoves, const CheckerMove(23, 22)]);
  return [_scored(best, bestEq), _scored(played, bestEq - loss)];
}

/// Serves canned rankings in order — one per [rankMoves] call, which occur once
/// per assessed [MoveEvent] in event order.
class ScriptedEngine implements EngineFacade {
  ScriptedEngine(this.rankings);
  final List<List<ScoredMove>> rankings;
  int calls = 0;

  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    return rankings[calls++];
  }

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async =>
      throw UnimplementedError();

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      throw UnimplementedError();
}

/// A short deterministic game with three moves: White (opening), Black, White.
/// Returns the events and the three played moves in order.
({List<GameEvent> events, List<Move> played}) _sampleGame() {
  final g0 = Game.start(const OpeningRollEvent(whiteDie: 6, blackDie: 1));
  final w1 = g0.state.legalMoves.first;
  final g1 = g0.append(MoveEvent(Player.white, w1));
  final g2 = g1.append(const RollEvent(Player.black, 3, 2));
  final b1 = g2.state.legalMoves.first;
  final g3 = g2.append(MoveEvent(Player.black, b1));
  final g4 = g3.append(const RollEvent(Player.white, 5, 4));
  final w2 = g4.state.legalMoves.first;
  final g5 = g4.append(MoveEvent(Player.white, w2));
  return (events: g5.events, played: [w1, b1, w2]);
}

void main() {
  test('assesses both players and computes per-side aggregates', () async {
    final game = _sampleGame();
    // White move 1: 0.20 loss (blunder). Black move: 0.06 loss (error).
    // White move 2: 0.00 loss (best).
    final engine = ScriptedEngine([
      _ranking(game.played[0], 0.20),
      _ranking(game.played[1], 0.06),
      _ranking(game.played[2], 0.0),
    ]);
    final analyzer = GameAnalyzer(TutorService(engine));

    final analysis =
        await analyzer.analyze(game.events, isCrawford: false);

    expect(analysis.moves, hasLength(3));
    expect(engine.calls, 3, reason: 'one ranking query per MoveEvent');

    // Move events sit at indices 1, 3, 5 in the log (rolls interleave).
    expect(analysis.moves.map((m) => m.eventIndex).toList(), [1, 3, 5]);
    expect(analysis.moves.map((m) => m.player).toList(),
        [Player.white, Player.black, Player.white]);

    expect(analysis.moves[0].assessment.equityLoss, closeTo(0.20, 1e-9));
    expect(analysis.moves[0].assessment.mark, MoveMark.blunder);
    expect(analysis.moves[1].assessment.equityLoss, closeTo(0.06, 1e-9));
    expect(analysis.moves[1].assessment.mark, MoveMark.error);
    expect(analysis.moves[2].assessment.equityLoss, closeTo(0.0, 1e-9));
    expect(analysis.moves[2].assessment.mark, MoveMark.best);

    // errorRate = mean loss over that side's moves.
    expect(analysis.errorRate(Player.white), closeTo((0.20 + 0.0) / 2, 1e-9));
    expect(analysis.errorRate(Player.black), closeTo(0.06, 1e-9));
    expect(analysis.blunderCount(Player.white), 1);
    expect(analysis.blunderCount(Player.black), 0);
  });

  test('errorRate is 0 for a side that never moved', () async {
    final analysis = GameAnalysis(const []);
    expect(analysis.errorRate(Player.white), 0);
    expect(analysis.blunderCount(Player.black), 0);
  });

  test('JSON round-trips (versioned)', () async {
    final game = _sampleGame();
    final engine = ScriptedEngine([
      _ranking(game.played[0], 0.20),
      _ranking(game.played[1], 0.06),
      _ranking(game.played[2], 0.0),
    ]);
    final analyzer = GameAnalyzer(TutorService(engine));
    final analysis = await analyzer.analyze(game.events, isCrawford: false);

    final json = analysis.toJson();
    expect(json['v'], GameAnalysis.version);

    final round = GameAnalysis.fromJson(json);
    expect(round.moves, hasLength(3));
    expect(round.moves[0].eventIndex, 1);
    expect(round.moves[0].player, Player.white);
    expect(round.moves[0].assessment.equityLoss, closeTo(0.20, 1e-9));
    expect(round.moves[0].assessment.mark, MoveMark.blunder);
    expect(round.errorRate(Player.white),
        closeTo(analysis.errorRate(Player.white), 1e-12));
    expect(round.moves[2].assessment.best.sameAs(game.played[2]), isTrue,
        reason: 'the best play (played on top) survives the round-trip');
  });

  test('fromJson rejects an unknown version', () {
    expect(() => GameAnalysis.fromJson({'v': 999, 'moves': const []}),
        throwsFormatException);
  });

  test('progress callback is monotonic from 0 to 1', () async {
    final game = _sampleGame();
    final engine = ScriptedEngine([
      _ranking(game.played[0], 0.20),
      _ranking(game.played[1], 0.06),
      _ranking(game.played[2], 0.0),
    ]);
    final analyzer = GameAnalyzer(TutorService(engine));

    final progress = <double>[];
    await analyzer.analyze(game.events,
        isCrawford: false, onProgress: progress.add);

    expect(progress.first, 0);
    expect(progress.last, 1);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]),
          reason: 'progress must never decrease');
    }
  });
}
