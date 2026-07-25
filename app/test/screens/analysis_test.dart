import 'dart:convert';

import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/screens/analysis_screen.dart';
import 'package:aigammon_app/tutor/game_analyzer.dart';
import 'package:aigammon_app/tutor/tutor_service.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/test_database.dart';

const _surface = Size(900, 1500);

// --- Fixtures ----------------------------------------------------------------

/// A finished game with two assessed moves: White opens and moves, Black moves,
/// then White resigns and Black accepts (a real [GameResult]). Move events sit
/// at indices 1 (White) and 3 (Black).
({Game game, List<Move> played}) _finishedGame() {
  final g0 = Game.start(const OpeningRollEvent(whiteDie: 6, blackDie: 1));
  final w1 = g0.state.legalMoves.first;
  final g1 = g0.append(MoveEvent(Player.white, w1));
  final g2 = g1.append(const RollEvent(Player.black, 3, 2));
  final b1 = g2.state.legalMoves.first;
  final g3 = g2.append(MoveEvent(Player.black, b1));
  final g4 = g3.append(const ResignOfferEvent(Player.white, ResignValue.single));
  final g5 = g4.append(const ResignAcceptEvent(Player.black));
  return (game: g5, played: [w1, b1]);
}

Probabilities _probs(double equity) => Probabilities(
      win: (equity + 1) / 2,
      winGammon: 0,
      winBackgammon: 0,
      loseGammon: 0,
      loseBackgammon: 0,
    );

ScoredMove _scored(Move move, double equity) =>
    ScoredMove(move: move, probabilities: _probs(equity));

List<ScoredMove> _ranking(Move played, double loss) {
  if (loss == 0) return [_scored(played, 0.5)];
  final best = Move([...played.checkerMoves, const CheckerMove(23, 22)]);
  return [_scored(best, 0.5), _scored(played, 0.5 - loss)];
}

/// Serves canned rankings, one per rankMoves call (in move order).
class ScriptedEngine implements EngineFacade {
  ScriptedEngine(this.rankings);
  final List<List<ScoredMove>> rankings;
  int calls = 0;

  @override
  Future<List<ScoredMove>> rankMoves(
          BoardState board, Player mover, Dice dice) async =>
      rankings[calls++];

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async =>
      throw UnimplementedError();

  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      throw UnimplementedError();
}

/// A facade that ranks the real legal moves flat (played move on top → loss 0).
class FlatFacade implements EngineFacade {
  const FlatFacade();
  @override
  Future<List<ScoredMove>> rankMoves(
      BoardState board, Player mover, Dice dice) async {
    const flat = Probabilities(
        win: 0.5, winGammon: 0, winBackgammon: 0, loseGammon: 0, loseBackgammon: 0);
    return [
      for (final m in MoveGenerator.legalMoves(board, mover, dice))
        ScoredMove(move: m, probabilities: flat),
    ];
  }

  @override
  Future<Probabilities> evaluate(BoardState board, Player mover) async =>
      throw UnimplementedError();
  @override
  Future<CubeAdvice> cubeInfo(BoardState board, Player mover) async =>
      throw UnimplementedError();
}

// --- Board probes ------------------------------------------------------------

BoardPainter _painterOf(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .firstWhere((c) => c.painter is BoardPainter)
    .painter as BoardPainter;

// --- App harness -------------------------------------------------------------

late AppDatabase _db;
late MatchRepository _repo;

Widget _app(int gameId, {EngineFacade facade = const FlatFacade()}) =>
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(_db),
        engineFacadeProvider.overrideWithValue(facade),
      ],
      child: MaterialApp(home: AnalysisScreen(gameId: gameId)),
    );

/// Pumps [app] and drives its async load (drift I/O + any analysis) to
/// completion. Each `_load` `await` resumes on the (fake-async) test zone's
/// microtask queue, so real I/O (runAsync) and a pump must alternate to advance
/// the chain step by step; a single runAsync is not enough.
Future<void> _pumpLoaded(WidgetTester t, Widget app) async {
  await t.pumpWidget(app);
  for (var i = 0; i < 60; i++) {
    if (find.textContaining('Error rate').evaluate().isNotEmpty) break;
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await t.pump();
  }
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    _db = newTestDatabase();
    _repo = MatchRepository(_db);
  });
  tearDown(() => _db.close());

  testWidgets('cached analysis: renders summary, steps the board, jumps blunder',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    late int gameId;
    await t.runAsync(() async {
      final matchId = await _repo.startMatch(
        matchLength: 1,
        mode: 'vsComputer',
        whiteType: 'human',
        blackType: 'ai:expert',
      );
      final fx = _finishedGame();
      gameId = await _repo.recordGame(
        matchId: matchId,
        gameNumber: 1,
        isCrawford: fx.game.state.isCrawfordGame,
        events: fx.game.events,
        result: fx.game.state.result!,
      );
      // Cache an analysis where White's move is a blunder (0.20) and Black's is
      // best (0.0), computed by a scripted engine over the same events.
      final engine = ScriptedEngine([
        _ranking(fx.played[0], 0.20),
        _ranking(fx.played[1], 0.0),
      ]);
      final analysis = await GameAnalyzer(TutorService(engine))
          .analyze(fx.game.events, isCrawford: false);
      await _repo.saveAnalysis(gameId, jsonEncode(analysis.toJson()));
    });

    await _pumpLoaded(t, _app(gameId));

    // Summary header shows both players' error rates and the blunder count.
    expect(find.text('Analysis'), findsOneWidget);
    expect(find.textContaining('Error rate'), findsNWidgets(2));
    expect(find.text('Blunders 1'), findsOneWidget); // White's summary
    expect(find.textContaining('Blunders (1)'), findsOneWidget); // list header

    // Cursor starts at position 0 (opening roll — not an assessed move), so the
    // post-event board is shown and there is no pre-move caption.
    const caption = 'Showing position before the move';
    final boardAt0 = _painterOf(t).board;
    expect(find.text('1 / 6'), findsOneWidget);
    expect(find.text(caption), findsNothing);

    // Next lands on White's move (event index 1). It is an assessed move, so the
    // PRE-move board is framed: the position BEFORE the move — which, for the
    // first move of the game, is exactly the opening position (states[0]). The
    // verdict and the caption both show.
    await t.tap(find.byTooltip('Next'));
    await t.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    expect(_painterOf(t).board, equals(boardAt0),
        reason: 'an assessed move frames the precomputed pre-move (states[0])');
    expect(find.text(caption), findsOneWidget);
    expect(find.textContaining('White: Blunder'), findsOneWidget);
    expect(find.textContaining('Best:'), findsOneWidget);

    // Next again lands on Black's roll event (index 2) — NOT an assessed move —
    // so the post-event board shows (differs from the opening) and no caption.
    await t.tap(find.byTooltip('Next'));
    await t.pumpAndSettle();
    expect(find.text('3 / 6'), findsOneWidget);
    final boardAt2 = _painterOf(t).board;
    expect(boardAt2, isNot(equals(boardAt0)),
        reason: 'a roll event shows its post-event board');
    expect(find.text(caption), findsNothing);

    // Back to the opening position.
    await t.tap(find.byTooltip('Previous'));
    await t.tap(find.byTooltip('Previous'));
    await t.pumpAndSettle();
    expect(find.text('1 / 6'), findsOneWidget);
    expect(_painterOf(t).board, equals(boardAt0));
    expect(find.text(caption), findsNothing);

    // Tapping the blunder chip jumps the cursor onto White's move: pre-move
    // framing again (board == states[0]) with the caption.
    await t.tap(find.byType(ActionChip));
    await t.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    expect(_painterOf(t).board, equals(boardAt0));
    expect(find.text(caption), findsOneWidget);
  });

  testWidgets('no cache: runs the analyzer and persists the analysis',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    late int gameId;
    await t.runAsync(() async {
      final matchId = await _repo.startMatch(
        matchLength: 1,
        mode: 'vsComputer',
        whiteType: 'human',
        blackType: 'ai:expert',
      );
      final fx = _finishedGame();
      gameId = await _repo.recordGame(
        matchId: matchId,
        gameNumber: 1,
        isCrawford: fx.game.state.isCrawfordGame,
        events: fx.game.events,
        result: fx.game.state.result!,
      );
      expect(await _repo.loadAnalysis(gameId), isNull,
          reason: 'precondition: nothing cached yet');
    });

    await _pumpLoaded(t, _app(gameId));

    // The summary rendered, so analysis completed.
    expect(find.textContaining('Error rate'), findsNWidgets(2));

    // And it was written back to the DB.
    String? saved;
    await t.runAsync(() async {
      saved = await _repo.loadAnalysis(gameId);
    });
    expect(saved, isNotNull,
        reason: 'the no-cache path must saveAnalysis after analyzing');
    final decoded = jsonDecode(saved!) as Map<String, dynamic>;
    expect(decoded['v'], GameAnalysis.version);
  });
}
