import 'dart:convert';

import 'package:aigammon_app/board/board_painter.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/engine/engine_provider.dart';
import 'package:aigammon_app/game/game_record.dart';
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

const _surface = Size(900, 1600);

// --- Fixtures ----------------------------------------------------------------

/// A finished game with two assessed moves: White opens (6-1) and moves, Black
/// rolls (3-2) and moves, then White resigns and Black accepts (a real
/// [GameResult]). Move events sit at indices 1 (White) and 3 (Black); the
/// Black roll is event 2.
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

/// Builds a canned ranking whose best play differs from [played] by an extra,
/// deliberately impossible hop (from index 0 — a point White never holds at the
/// opening — so the best-move overlay's SOURCE set provably differs from the
/// played move's). The played move is resolved by hop multiset, so the synthetic
/// best is never applied to a board (see [TutorService.assess]).
List<ScoredMove> _ranking(Move played, double loss) {
  if (loss == 0) return [_scored(played, 0.5)];
  final best = Move([...played.checkerMoves, const CheckerMove(0, 5)]);
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

Widget _app(
  int gameId, {
  EngineFacade facade = const FlatFacade(),
  double textScale = 1.0,
}) =>
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(_db),
        engineFacadeProvider.overrideWithValue(facade),
      ],
      child: MaterialApp(
        // Applied through `builder` so the override lands INSIDE the app's own
        // MediaQuery (which supplies the surface size) rather than replacing it.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: AnalysisScreen(gameId: gameId),
      ),
    );

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

/// Records [fx] and caches an analysis where White's move is a blunder (0.20,
/// best differs from played) and Black's is best (0.0). Returns the game id.
Future<int> _seedCachedBlunder(WidgetTester t) async {
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
    final engine = ScriptedEngine([
      _ranking(fx.played[0], 0.20),
      _ranking(fx.played[1], 0.0),
    ]);
    final analysis = await GameAnalyzer(TutorService(engine))
        .analyze(fx.game.events, isCrawford: false);
    await _repo.saveAnalysis(gameId, jsonEncode(analysis.toJson()));
  });
  return gameId;
}

void main() {
  group('moveHighlights (true origins/landings only)', () {
    test('multi-hop single checker marks only the true origin and landing', () {
      // 24/18/13: one checker via two dice — 18 is a transit point, not a
      // landing, and not an origin.
      final (sources, destinations) = moveHighlights(Move(const [
        CheckerMove(23, 17),
        CheckerMove(17, 12),
      ]));
      expect(sources, {23});
      expect(destinations, {12});
      expect(destinations.contains(17), isFalse,
          reason: 'the pass-through point is not a landing');
      expect(sources.contains(17), isFalse,
          reason: 'the pass-through point is not an origin');
    });

    test('two checkers sharing a point mark it as both origin and landing', () {
      // One checker leaves 13 (13/7) while another arrives on 13 (24/13); in
      // notation order the arrival opens its own chain, so 13 is both.
      final (sources, destinations) = moveHighlights(Move(const [
        CheckerMove(12, 6),
        CheckerMove(23, 12),
      ]));
      expect(sources, {12, 23});
      expect(destinations, {6, 12});
      expect(sources.contains(12), isTrue);
      expect(destinations.contains(12), isTrue);
    });
  });

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    _db = newTestDatabase();
    _repo = MatchRepository(_db);
  });
  tearDown(() => _db.close());

  testWidgets(
      'stepped move: shows historical dice, played-move highlights, and the '
      'Played/Best toggle swaps the overlay', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final gameId = await _seedCachedBlunder(t);
    final played = _finishedGame().played[0];
    final (playedSrcs, playedDests) = moveHighlights(played);

    await _pumpLoaded(t, _app(gameId));

    // Summary header shows both players' error rates and the blunder count.
    expect(find.text('Analysis'), findsOneWidget);
    expect(find.textContaining('Error rate'), findsNWidgets(2));
    expect(find.text('Blunders 1'), findsOneWidget); // White

    // Step onto White's move (event index 1): the PRE-move (opening) position is
    // framed, so the dice are White's opening roll 6-1 and Black has not rolled.
    await t.tap(find.byTooltip('Next'));
    await t.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    expect(find.text('Showing position before the move'), findsOneWidget);

    final onPlayed = _painterOf(t);
    expect(onPlayed.whiteDice, Dice(6, 1),
        reason: 'the mover\'s roll shows on White\'s pair');
    expect(onPlayed.blackDice, isNull,
        reason: 'Black has not rolled by this step');
    expect(onPlayed.movingPlayer, Player.white);

    // The played move is drawn: its origins wear the STRONG selection ring (not
    // the thin "could be picked up" source ring, which is left empty here), its
    // landings the destination highlights. Source index 0 is never in a legal
    // White opening move, so it stays out of the played overlay.
    expect(onPlayed.strongHighlightLocations, playedSrcs);
    expect(onPlayed.highlightedSources, isEmpty,
        reason: 'the replay overlay must not use the weak source ring');
    expect(onPlayed.highlightedDestinations, playedDests);
    expect(onPlayed.strongHighlightLocations.contains(0), isFalse);

    // The toggle is offered (best differs from played). Switch to Best: the
    // overlay swaps to the best move's hops, whose source set includes 0.
    final toggle = find.byType(SegmentedButton<bool>);
    expect(toggle, findsOneWidget);
    await t.tap(find.descendant(of: toggle, matching: find.text('Best')));
    await t.pumpAndSettle();

    final onBest = _painterOf(t);
    expect(onBest.strongHighlightLocations.contains(0), isTrue,
        reason: 'the best-move overlay differs from the played one');
    expect(onBest.strongHighlightLocations,
        isNot(onPlayed.strongHighlightLocations));
  });

  testWidgets('the board NEVER resizes as the rows below it come and go',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final gameId = await _seedCachedBlunder(t);
    await _pumpLoaded(t, _app(gameId));

    Rect boardRect() => t.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is BoardPainter));

    final rects = <int, Rect>{0: boardRect()};
    // The six steps cover every combination: a bare opening / roll / resign
    // step (no caption, no toggle, no verdict), White's blunder (all three),
    // and Black's best move (caption + verdict but NO Played/Best toggle,
    // since its best play IS what was played).
    final seen = <int, ({bool caption, bool toggle})>{};
    for (var step = 1; step < 6; step++) {
      await t.tap(find.byTooltip('Next'));
      await t.pumpAndSettle();
      rects[step] = boardRect();
      seen[step] = (
        caption: find.textContaining('position before the move')
            .evaluate()
            .isNotEmpty,
        toggle: find.byType(SegmentedButton<bool>).evaluate().isNotEmpty,
      );
    }

    expect(seen[1], (caption: true, toggle: true),
        reason: "White's blunder shows caption + Played/Best");
    expect(seen[2], (caption: false, toggle: false),
        reason: 'the bare roll step shows neither');
    expect(seen[3], (caption: true, toggle: false),
        reason: "Black's best move shows the caption but no toggle");

    for (var step = 1; step < 6; step++) {
      expect(rects[step], rects[0],
          reason: 'the board must not change size stepping to $step '
              '(caption/toggle/verdict rows are reserved space)');
    }
  });

  for (final scale in [1.6, 3.0]) {
    testWidgets(
        'system text at ${scale}x: the reserved rows absorb it and the board '
        'still holds still', (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      final gameId = await _seedCachedBlunder(t);
      await _pumpLoaded(t, _app(gameId, textScale: scale));

      Rect boardRect() => t.getRect(find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is BoardPainter));

      // Step onto White's blunder: caption + Played/Best + verdict all present.
      await t.tap(find.byTooltip('Next'));
      await t.pumpAndSettle();
      expect(find.byType(SegmentedButton<bool>), findsOneWidget);
      expect(t.takeException(), isNull,
          reason: 'the fixed slots must not overflow at ${scale}x');

      // Everything actually ends up inside its reserved slot on screen.
      // `getRect` applies the scale-down transform, so this is what the user
      // sees, not what the row asked for.
      expect(t.getRect(find.byType(SegmentedButton<bool>)).height,
          lessThanOrEqualTo(56.5));
      final verdict = find.byKey(const ValueKey('moveVerdictRow'));
      expect(t.getRect(verdict).height, lessThanOrEqualTo(40.5));

      // At 3x the verdict row genuinely outgrows its 40pt slot, so this is the
      // case that proves the slot SCALES its content rather than squeezing it:
      // the laid-out height (measured unbounded inside the FittedBox) exceeds
      // the slot, while the on-screen height does not.
      if (scale >= 3.0) {
        final laidOut = t.getSize(verdict).height;
        expect(laidOut, greaterThan(40),
            reason: 'premise: 3x text outgrows the verdict slot');
        expect(t.getRect(verdict).height, lessThan(laidOut),
            reason: 'the row is scaled down, not clipped');
      }

      final withRows = boardRect();

      // Step to the bare roll step (none of the three rows).
      await t.tap(find.byTooltip('Next'));
      await t.pumpAndSettle();
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(boardRect(), withRows,
          reason: 'reserved space holds the board still at ${scale}x too');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('move list: all moves listed, current highlighted, tap jumps',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final gameId = await _seedCachedBlunder(t);
    final lines = buildGameRecord(_finishedGame().game.events);

    await _pumpLoaded(t, _app(gameId));

    // Every recorded line is shown (opening, White move, Black move, resign
    // offer, accept — the bare roll produces no line).
    for (final line in lines) {
      expect(find.text(line.text), findsOneWidget,
          reason: 'move list must list every line: ${line.text}');
    }

    // Tap the Black-move row (event index 3): the cursor jumps there and the
    // pre-move position is framed.
    final blackLine = lines.firstWhere((l) => l.eventIndex == 3);
    await t.tap(find.text(blackLine.text));
    await t.pumpAndSettle();
    expect(find.text('4 / 6'), findsOneWidget);
    expect(find.text('Showing position before the move'), findsOneWidget);

    // The current row is emphasised (bold).
    final rowText = t.widget<Text>(find.text(blackLine.text));
    expect(rowText.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('metric explainer names equity, error rate and the thresholds',
      (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final gameId = await _seedCachedBlunder(t);
    await _pumpLoaded(t, _app(gameId));

    await t.tap(find.byTooltip('What do these numbers mean?'));
    await t.pumpAndSettle();

    expect(find.text('Understanding the metrics'), findsOneWidget);
    expect(find.text('Equity'), findsOneWidget);
    expect(find.text('Error rate'), findsOneWidget);
    // The mark scale with its thresholds.
    expect(find.textContaining('lost < 0.001'), findsOneWidget);
    expect(find.textContaining('lost < 0.020'), findsOneWidget);
    expect(find.textContaining('lost < 0.050'), findsOneWidget);
    expect(find.textContaining('lost < 0.110'), findsOneWidget);
    expect(find.textContaining('lost ≥ 0.110'), findsOneWidget);
  });

  testWidgets('non-move step degrades: no overlay and no toggle', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final gameId = await _seedCachedBlunder(t);
    await _pumpLoaded(t, _app(gameId));

    // Step to the Black roll event (index 2) — not an assessed move.
    await t.tap(find.byTooltip('Next'));
    await t.tap(find.byTooltip('Next'));
    await t.pumpAndSettle();
    expect(find.text('3 / 6'), findsOneWidget);
    expect(find.text('Showing position before the move'), findsNothing);

    final painter = _painterOf(t);
    expect(painter.highlightedSources, isEmpty,
        reason: 'a roll step has no move to overlay');
    expect(painter.highlightedDestinations, isEmpty);
    expect(find.byType(SegmentedButton<bool>), findsNothing,
        reason: 'no Played/Best toggle off an assessed move');
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

    expect(find.textContaining('Error rate'), findsNWidgets(2));

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
