import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/match_repository.dart';
import 'package:aigammon_app/screens/history_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/test_database.dart';

const _surface = Size(900, 1500);

/// A finished one-move game (White drops Black's double): a real [GameResult].
Game _sampleGame() {
  final g0 = Game.start(const OpeningRollEvent(whiteDie: 6, blackDie: 1));
  final g1 = g0.append(MoveEvent(Player.white, g0.state.legalMoves.first));
  final g2 = g1.append(const DoubleEvent(Player.black));
  return g2.append(const DropEvent(Player.white));
}

MatchRow _matchRow(int id) => MatchRow(
      id: id,
      createdAt: DateTime(2026, 7, 24, 10, 30),
      matchLength: 1,
      mode: 'vsComputer',
      whiteType: 'human',
      blackType: 'ai:expert',
      whiteScore: 1,
      blackScore: 0,
      winner: 'white',
      completed: true,
    );

/// A finished row in [mode], with a score that makes each tile distinguishable
/// from its neighbours in a list of five.
MatchRow _modeRow(int id, String mode) => MatchRow(
      id: id,
      createdAt: DateTime(2026, 7, 24, 10, 30),
      matchLength: 1,
      mode: mode,
      whiteType: 'human',
      blackType: 'human',
      whiteScore: 1,
      blackScore: 0,
      winner: 'white',
      completed: true,
    );

/// An UNFINISHED match row (no winner, not completed) — the "Unfinished" badge.
MatchRow _unfinishedRow(int id) => MatchRow(
      id: id,
      createdAt: DateTime(2026, 7, 24, 11, 15),
      matchLength: 3,
      mode: 'vsComputer',
      whiteType: 'human',
      blackType: 'ai:expert',
      whiteScore: 0,
      blackScore: 1,
      completed: false,
    );

/// A repository whose delete always fails — a disk that has gone away under a
/// user who is watching the row swipe.
class _FailingDeleteRepo extends MatchRepository {
  _FailingDeleteRepo(super.db);

  @override
  Future<void> deleteMatch(int matchId) async {
    throw StateError('database is gone');
  }
}

late AppDatabase _db;
late MatchRepository _repo;

/// Builds the app over the in-memory db, with the matches list served by a
/// plain [Stream.value] (`matchesProvider` override). The real drift
/// `watchMatches` stream is covered in the repository test; overriding it here
/// keeps the widget test off drift's watch-timer (which otherwise lingers past
/// tree disposal in the fake-async test binding). Drill-down still hits the
/// real db via `gamesFor`.
Widget _app(Widget home,
        {required List<MatchRow> matches, MatchRepository? repo}) =>
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(_db),
        matchesProvider.overrideWith((ref) => Stream.value(matches)),
        if (repo != null) matchRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(home: home),
    );

/// Alternates real I/O (runAsync) and pumps so the seeded-stream emission and
/// the drift-backed `gamesFor` future resolve, then settles animations.
Future<void> _settle(WidgetTester t, {int cycles = 30}) async {
  for (var i = 0; i < cycles; i++) {
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

  testWidgets('lists a seeded match and drills into its games', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    late int matchId;
    await t.runAsync(() async {
      matchId = await _repo.startMatch(
        matchLength: 1,
        mode: 'vsComputer',
        whiteType: 'human',
        blackType: 'ai:expert',
      );
      await _repo.updateScore(matchId: matchId, whiteScore: 1, blackScore: 0);
      await _repo.completeMatch(matchId: matchId, winner: 'white');
      final game = _sampleGame();
      await _repo.recordGame(
        matchId: matchId,
        gameNumber: 1,
        isCrawford: game.state.isCrawfordGame,
        events: game.events,
        result: game.state.result!,
      );
    });

    await t.pumpWidget(
        _app(const HistoryScreen(), matches: [_matchRow(matchId)]));
    await _settle(t);

    // The match tile: score line, mode, and a completed badge.
    expect(find.textContaining('White 1 — 0 Black'), findsOneWidget);
    expect(find.textContaining('vs Computer'), findsOneWidget);
    expect(find.text('White won'), findsOneWidget);

    // Drill into the match → its games list (loaded from the real db).
    await t.tap(find.textContaining('White 1 — 0 Black'));
    await _settle(t);
    expect(find.byType(MatchDetailScreen), findsOneWidget);
    expect(find.text('Game 1'), findsOneWidget);
    expect(find.textContaining('Black wins 1'), findsOneWidget);
  });

  testWidgets('every mode a match can be saved under has a name', (t) async {
    // **The failure this catches is silent by construction.** `_modeLabel`
    // falls through to the raw column value, so a mode with no case shows its
    // database spelling in the subtitle beside four modes that read like
    // English — which is exactly what "lan" and "buddy" were doing.
    //
    // The list is the set of strings `MatchRepository.startMatch` is actually
    // called with: `mode:` in `game_screen.dart` (vsComputer/hotSeat),
    // `lan_screen.dart` ('lan', twice), `online_screen.dart` ('online') and
    // `buddy_game_screen.dart` ('buddy'). A new mode added without a label
    // reddens here rather than shipping its column name.
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    const modes = <String, String>{
      'vsComputer': 'vs Computer',
      'hotSeat': 'Two players',
      'online': 'Online',
      'lan': 'Play Nearby',
      'buddy': 'Buddy',
    };
    await t.pumpWidget(_app(
      const HistoryScreen(),
      matches: <MatchRow>[
        for (final (i, mode) in modes.keys.indexed)
          _modeRow(100 + i, mode),
      ],
    ));
    await _settle(t);

    for (final entry in modes.entries) {
      expect(find.textContaining(entry.value), findsOneWidget,
          reason: '"${entry.key}" is saved by a real screen and must not show '
              'its column name in the list');
    }
  });

  testWidgets('empty history shows a placeholder', (t) async {
    await t.binding.setSurfaceSize(_surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(_app(const HistoryScreen(), matches: const []));
    await _settle(t);

    expect(find.text('No matches played yet.'), findsOneWidget);
  });

  group('history hygiene', () {
    testWidgets('loading the screen purges the gameless abandoned matches',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      late int litter;
      late int keptWithGame;
      await t.runAsync(() async {
        // Two abandoned matches that never recorded a game, plus one that did.
        litter = await _repo.startMatch(
          matchLength: 1,
          mode: 'vsComputer',
          whiteType: 'human',
          blackType: 'ai:expert',
        );
        await _repo.startMatch(
          matchLength: 1,
          mode: 'vsComputer',
          whiteType: 'human',
          blackType: 'ai:expert',
        );
        keptWithGame = await _repo.startMatch(
          matchLength: 3,
          mode: 'vsComputer',
          whiteType: 'human',
          blackType: 'ai:expert',
        );
        final game = _sampleGame();
        await _repo.recordGame(
          matchId: keptWithGame,
          gameNumber: 1,
          isCrawford: game.state.isCrawfordGame,
          events: game.events,
          result: game.state.result!,
        );
        // Age every row past the sweep's two-minute guard (created_at is unix
        // seconds). Real litter is minutes-to-days old; the guard only exists
        // to keep the sweep clear of a game that is still being written.
        await _repo.db
            .customStatement('UPDATE matches SET created_at = created_at - 600');
      });

      await t.pumpWidget(_app(const HistoryScreen(),
          matches: [_unfinishedRow(keptWithGame), _unfinishedRow(litter)]));
      await _settle(t);

      final remaining = await t.runAsync(() => _repo.watchMatches().first);
      expect([for (final m in remaining!) m.id], [keptWithGame],
          reason: 'only the match with a recorded game survives the purge');
    });

    testWidgets('an unfinished match is badged "Unfinished", not "In progress"',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      await t.pumpWidget(
          _app(const HistoryScreen(), matches: [_unfinishedRow(7)]));
      await _settle(t);

      expect(find.text('Unfinished'), findsOneWidget);
      expect(find.text('In progress'), findsNothing);
    });

    testWidgets('swipe + confirm deletes the row and its database rows',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      late int matchId;
      await t.runAsync(() async {
        matchId = await _repo.startMatch(
          matchLength: 1,
          mode: 'vsComputer',
          whiteType: 'human',
          blackType: 'ai:expert',
        );
        await _repo.updateScore(matchId: matchId, whiteScore: 1, blackScore: 0);
        await _repo.completeMatch(matchId: matchId, winner: 'white');
        final game = _sampleGame();
        await _repo.recordGame(
          matchId: matchId,
          gameNumber: 1,
          isCrawford: game.state.isCrawfordGame,
          events: game.events,
          result: game.state.result!,
        );
      });

      await t.pumpWidget(
          _app(const HistoryScreen(), matches: [_matchRow(matchId)]));
      await _settle(t);
      expect(find.textContaining('White 1 — 0 Black'), findsOneWidget);

      // Swipe the row from its trailing edge → the confirmation dialog.
      await t.drag(find.textContaining('White 1 — 0 Black'),
          const Offset(-600, 0));
      await t.pumpAndSettle();
      expect(find.text('Delete this match?'), findsOneWidget);

      // Cancel first: nothing is deleted and the row springs back.
      await t.tap(find.text('Cancel'));
      await _settle(t);
      expect(find.textContaining('White 1 — 0 Black'), findsOneWidget);
      var games = await t.runAsync(() => _repo.gamesFor(matchId));
      expect(games, hasLength(1), reason: 'cancel deletes nothing');

      // Swipe again and confirm.
      await t.drag(find.textContaining('White 1 — 0 Black'),
          const Offset(-600, 0));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Delete'));
      await _settle(t);

      expect(find.textContaining('White 1 — 0 Black'), findsNothing,
          reason: 'the confirmed row leaves the list immediately');
      expect(find.text('No matches played yet.'), findsOneWidget);
      final rows = await t.runAsync(() => _repo.watchMatches().first);
      expect(rows, isEmpty, reason: 'the match row is gone from the database');
      games = await t.runAsync(() => _repo.gamesFor(matchId));
      expect(games, isEmpty, reason: 'its games cascade away with it');
    });
    testWidgets('a delete that fails says so and leaves the row listed',
        (t) async {
      await t.binding.setSurfaceSize(_surface);
      addTearDown(() => t.binding.setSurfaceSize(null));

      // The user asked for this and watched the row swipe away, so a silent
      // failure reads as the delete having taken when it has not.
      await t.pumpWidget(_app(const HistoryScreen(),
          matches: [_matchRow(1)], repo: _FailingDeleteRepo(_db)));
      await _settle(t);

      await t.drag(find.textContaining('White 1 — 0 Black'),
          const Offset(-600, 0));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Delete'));
      await _settle(t);

      expect(find.text('Could not delete that match.'), findsOneWidget);
      expect(find.textContaining('White 1 — 0 Black'), findsOneWidget,
          reason: 'the row is still there, because the match still is');
    });
  });
}
