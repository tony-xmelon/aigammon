import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/analytics_events.dart';
import '../analytics/analytics_screen_view.dart';
import '../data/database.dart';
import '../data/match_repository.dart';
import 'analysis_screen.dart';

/// The match-history list: every recorded match, newest first, tapping through
/// to its games ([MatchDetailScreen]) and, from there, to the per-game
/// [AnalysisScreen].
///
/// ## History is not a landfill
///
/// A match row is written the moment a match is launched, so every abandoned
/// setup used to accumulate forever as an unresumable "White 0 — 0 Black · In
/// progress" row. Two things keep the list meaningful:
///
/// * on every load the screen sweeps the **empty** abandoned matches
///   ([MatchRepository.deleteEmptyAbandonedMatches]) — those with zero recorded
///   games carry no information at all. The sweep skips matches younger than a
///   couple of minutes, so it can never race a game that is still being
///   written (see that method's age-guard note);
/// * every remaining row can be **swiped away** (right-to-left) behind a
///   confirmation dialog, which hard-deletes the match and, by cascade, its
///   games.
///
/// An unfinished match that DID record games is kept and badged "Unfinished"
/// (not "In progress": no live match survives an app restart) — its games are
/// still analysable.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  /// Ids deleted from THIS screen, hidden immediately rather than waiting for
  /// the watch stream to re-emit. Keeps the swipe feeling instant and makes the
  /// row's disappearance independent of the stream (so a test may serve a fixed
  /// list). The delete itself has already committed when an id lands here.
  final Set<int> _deleted = {};

  @override
  void initState() {
    super.initState();
    // Fire-and-forget purge of the empty abandoned matches. The watch stream
    // re-emits when rows go, so no explicit refresh is needed; a failure just
    // leaves the rows listed (they are deletable by hand).
    unawaited(ref.read(matchRepositoryProvider).deleteEmptyAbandonedMatches());
  }

  @override
  // See [HomeScreen] for why every screen splits build/_build.
  Widget build(BuildContext context) => AnalyticsScreenView(
        name: AnalyticsScreens.history,
        child: _build(context),
      );

  Widget _build(BuildContext context) {
    final matches = ref.watch(matchesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Match history')),
      body: matches.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load history:\n$e')),
        data: (all) {
          final rows = [
            for (final row in all)
              if (!_deleted.contains(row.id)) row,
          ];
          if (rows.isEmpty) {
            return const Center(child: Text('No matches played yet.'));
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _MatchTile(
              match: rows[i],
              onDeleteRequested: () => _confirmDelete(rows[i]),
            ),
          );
        },
      ),
    );
  }

  /// Confirms and performs the hard delete of [match].
  ///
  /// Always resolves `false` — the [Dismissible] is told NOT to dismiss, because
  /// a confirmed delete has already removed the row from the list (via
  /// [_deleted]) by the time this returns, and a "dismissed" widget that is
  /// still in the tree trips a framework assertion. A cancelled delete simply
  /// springs the row back.
  Future<bool> _confirmDelete(MatchRow match) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this match?'),
        content: Text(
          '${_scoreLine(match)}\n\n'
          'The match and every game recorded in it are removed permanently. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    await ref.read(matchRepositoryProvider).deleteMatch(match.id);
    if (mounted) setState(() => _deleted.add(match.id));
    return false;
  }
}

class _MatchTile extends StatelessWidget {
  const _MatchTile({required this.match, required this.onDeleteRequested});

  final MatchRow match;

  /// Runs the confirm-then-delete flow; resolves whether the [Dismissible]
  /// should complete its dismissal (always `false` — see
  /// [_HistoryScreenState._confirmDelete]).
  final Future<bool> Function() onDeleteRequested;

  @override
  Widget build(BuildContext context) {
    final subtitle =
        '${_modeLabel(match.mode)} · ${_formatDate(match.createdAt)}';
    return Dismissible(
      key: ValueKey('match-${match.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => onDeleteRequested(),
      background: const _DeleteBackground(),
      child: ListTile(
        title: Text(_scoreLine(match)),
        subtitle: Text(subtitle),
        trailing: match.completed
            ? _StatusBadge(
                label: match.winner == null
                    ? 'Complete'
                    : '${_sideLabel(match.winner!)} won',
                tone: _BadgeTone.done,
              )
            // Not "In progress": nothing is in progress after the app restarts —
            // the match cannot be resumed, only its games reviewed.
            : const _StatusBadge(label: 'Unfinished', tone: _BadgeTone.pending),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MatchDetailScreen(match: match),
          ),
        ),
      ),
    );
  }
}

/// What shows behind a row as it is swiped: a delete affordance on the trailing
/// edge (the swipe direction), so the gesture reads before it commits.
class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('Delete',
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
            const SizedBox(width: 8),
            Icon(Icons.delete_outline, color: scheme.onErrorContainer),
          ],
        ),
      ),
    );
  }
}

/// The games of one match, in play order, tapping through to the analysis
/// screen. Games are loaded once via the repository's [MatchRepository.gamesFor].
///
/// Reached two ways: from the history list with the [match] row already in hand,
/// or from the game screen's post-match "Match summary" button with only a
/// [matchId] (the row is then loaded via [MatchRepository.loadMatch]). Exactly
/// one of [match] / [matchId] must be provided.
class MatchDetailScreen extends ConsumerWidget {
  const MatchDetailScreen({super.key, this.match, this.matchId})
      : assert(match != null || matchId != null,
            'provide a match row or a matchId');

  /// The pre-loaded match row (from the history list), or null when only a
  /// [matchId] is known (from the post-match summary link).
  final MatchRow? match;

  /// The match id to load the row for, when [match] is null.
  final int? matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = match;
    if (row != null) return _detail(context, ref, row);
    final repo = ref.watch(matchRepositoryProvider);
    return FutureBuilder<MatchRow>(
      future: repo.loadMatch(matchId!),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Match')),
            body: Center(child: Text('Failed to load match:\n${snap.error}')),
          );
        }
        if (!snap.hasData) {
          return Scaffold(
            appBar: AppBar(title: const Text('Match')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        return _detail(context, ref, snap.data!);
      },
    );
  }

  Widget _detail(BuildContext context, WidgetRef ref, MatchRow match) {
    final repo = ref.watch(matchRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_scoreLine(match))),
      body: FutureBuilder<List<GameRow>>(
        future: repo.gamesFor(match.id),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Failed to load games:\n${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final games = snap.data!;
          if (games.isEmpty) {
            return const Center(child: Text('No games recorded yet.'));
          }
          return ListView.separated(
            itemCount: games.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _GameTile(game: games[i]),
          );
        },
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.game});

  final GameRow game;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(child: Text('${game.gameNumber}')),
      title: Text('Game ${game.gameNumber}'),
      subtitle: Text(_gameResultLine(game)),
      trailing: game.isCrawford
          ? const _StatusBadge(label: 'Crawford', tone: _BadgeTone.info)
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AnalysisScreen(gameId: game.id),
        ),
      ),
    );
  }
}

// --- Formatting --------------------------------------------------------------

String _scoreLine(MatchRow m) =>
    'White ${m.whiteScore} — ${m.blackScore} Black  (to ${m.matchLength})';

String _modeLabel(String mode) => switch (mode) {
      'vsComputer' => 'vs Computer',
      'hotSeat' => 'Two players',
      'online' => 'Online',
      final other => other,
    };

String _sideLabel(String winner) =>
    winner.isEmpty ? winner : winner[0].toUpperCase() + winner.substring(1);

String _gameResultLine(GameRow g) {
  final winner = g.resultWinner;
  if (winner == null) return 'In progress';
  final points = g.resultPoints ?? 0;
  final outcome = g.resultOutcome ?? 'single';
  return '${_sideLabel(winner)} wins $points ($outcome)';
}

String _formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

// --- Badges ------------------------------------------------------------------

enum _BadgeTone { done, pending, info }

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.tone});

  final String label;
  final _BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _BadgeTone.done => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _BadgeTone.pending => (
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
      _BadgeTone.info => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12)),
    );
  }
}
