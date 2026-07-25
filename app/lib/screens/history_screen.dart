import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/match_repository.dart';
import 'analysis_screen.dart';

/// The match-history list: every recorded match, newest first, tapping through
/// to its games ([MatchDetailScreen]) and, from there, to the per-game
/// [AnalysisScreen].
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matches = ref.watch(matchesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Match history')),
      body: matches.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load history:\n$e')),
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(child: Text('No matches played yet.'));
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _MatchTile(match: rows[i]),
          );
        },
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  const _MatchTile({required this.match});

  final MatchRow match;

  @override
  Widget build(BuildContext context) {
    final subtitle =
        '${_modeLabel(match.mode)} · ${_formatDate(match.createdAt)}';
    return ListTile(
      title: Text(_scoreLine(match)),
      subtitle: Text(subtitle),
      trailing: match.completed
          ? _StatusBadge(
              label: match.winner == null
                  ? 'Complete'
                  : '${_sideLabel(match.winner!)} won',
              tone: _BadgeTone.done,
            )
          : const _StatusBadge(label: 'In progress', tone: _BadgeTone.pending),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MatchDetailScreen(match: match),
        ),
      ),
    );
  }
}

/// The games of one match, in play order, tapping through to the analysis
/// screen. Games are loaded once via the repository's [MatchRepository.gamesFor].
class MatchDetailScreen extends ConsumerWidget {
  const MatchDetailScreen({super.key, required this.match});

  final MatchRow match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
