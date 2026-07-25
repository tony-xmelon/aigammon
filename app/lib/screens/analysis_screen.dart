import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../board/board_view.dart';
import '../data/match_repository.dart';
import '../engine/engine_provider.dart';
import '../tutor/game_analyzer.dart';
import '../tutor/move_assessment.dart';
import '../tutor/tutor_service.dart';

/// Post-game replay + analysis for a single recorded game.
///
/// Loads the game's event log and any cached [GameAnalysis]; if none is cached
/// it runs a [GameAnalyzer] (showing a progress bar) and persists the result.
/// The board is a non-interactive [BoardView] driven by a cursor over the
/// replayed prefix states; when the cursor sits on an assessed move the move's
/// verdict is shown, and a blunder list jumps the cursor to each blunder.
class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({
    super.key,
    required this.gameId,
    this.repository,
    this.tutor,
  });

  final int gameId;

  /// The repository to load from; defaults to [matchRepositoryProvider].
  final MatchRepository? repository;

  /// The tutor used when analysis must be (re)computed; defaults to a
  /// [TutorService] over [engineFacadeProvider].
  final TutorService? tutor;

  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  /// Replayed prefix states: `_states[i]` is the state after events[0..i].
  List<GameState>? _states;

  /// The move analyses keyed by their event index (cursor position).
  Map<int, MoveAnalysis> _byEventIndex = const {};

  GameAnalysis? _analysis;
  int _cursor = 0;
  double _progress = 0;
  bool _loading = true;
  bool _analyzing = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  MatchRepository get _repo =>
      widget.repository ?? ref.read(matchRepositoryProvider);

  Future<void> _load() async {
    try {
      final repo = _repo;
      final row = await repo.loadGame(widget.gameId);
      final events = await repo.loadGameEvents(widget.gameId);
      final states = _replayPrefixes(events, row.isCrawford);

      final cached = await repo.loadAnalysis(widget.gameId);
      GameAnalysis analysis;
      if (cached != null) {
        analysis = GameAnalysis.fromJson(
            (jsonDecode(cached) as Map).cast<String, dynamic>());
      } else {
        if (mounted) setState(() => _analyzing = true);
        final tutor =
            widget.tutor ?? TutorService(ref.read(engineFacadeProvider));
        analysis = await GameAnalyzer(tutor).analyze(
          events,
          isCrawford: row.isCrawford,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
        );
        await repo.saveAnalysis(
            widget.gameId, jsonEncode(analysis.toJson()));
      }

      if (!mounted) return;
      setState(() {
        _states = states;
        _analysis = analysis;
        _byEventIndex = {for (final m in analysis.moves) m.eventIndex: m};
        _cursor = 0;
        _loading = false;
        _analyzing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _analyzing = false;
      });
    }
  }

  /// Folds [events] with a single running [Game], recording the state after
  /// each event. `result[i]` is the state after events[0..i].
  static List<GameState> _replayPrefixes(
      List<GameEvent> events, bool isCrawford) {
    if (events.isEmpty) return const [];
    var game = Game.start(events.first as OpeningRollEvent,
        isCrawfordGame: isCrawford);
    final states = <GameState>[game.state];
    for (var i = 1; i < events.length; i++) {
      game = game.append(events[i]);
      states.add(game.state);
    }
    return states;
  }

  void _setCursor(int i) {
    final states = _states;
    if (states == null || states.isEmpty) return;
    setState(() => _cursor = i.clamp(0, states.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analysis')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(child: Text('Failed to analyse game:\n$_error'));
    }
    if (_loading) {
      return _loadingView();
    }
    final states = _states!;
    if (states.isEmpty) {
      return const Center(child: Text('This game has no positions to show.'));
    }
    return _loaded(states);
  }

  Widget _loadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_analyzing) ...[
            const Text('Analysing game…'),
            const SizedBox(height: 16),
            SizedBox(
              width: 220,
              child: LinearProgressIndicator(value: _progress),
            ),
            const SizedBox(height: 8),
            Text('${(_progress * 100).round()}%'),
          ] else
            const CircularProgressIndicator(),
        ],
      ),
    );
  }

  Widget _loaded(List<GameState> states) {
    final analysis = _analysis!;
    final current = _byEventIndex[_cursor];
    return Column(
      children: [
        _SummaryHeader(analysis: analysis),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: BoardView(
                state: states[_cursor],
                interactive: false,
                onMoveCommitted: (_) {},
              ),
            ),
          ),
        ),
        if (current != null) _moveInfo(current),
        _cursorBar(states.length),
        _blunderList(analysis),
      ],
    );
  }

  Widget _cursorBar(int length) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous',
            icon: const Icon(Icons.chevron_left),
            onPressed: _cursor > 0 ? () => _setCursor(_cursor - 1) : null,
          ),
          Text('${_cursor + 1} / $length'),
          IconButton(
            tooltip: 'Next',
            icon: const Icon(Icons.chevron_right),
            onPressed:
                _cursor < length - 1 ? () => _setCursor(_cursor + 1) : null,
          ),
        ],
      ),
    );
  }

  Widget _moveInfo(MoveAnalysis m) {
    final a = m.assessment;
    final (color, label) = _markStyle(a.mark);
    final loss = a.equityLoss;
    final lossText =
        loss >= 0.001 ? '  −${loss.toStringAsFixed(3)}' : '  (best)';
    final best = a.best.checkerMoves.isEmpty ? '(no play)' : '${a.best}';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 8),
            Text('${_sideLabel(m.player)}: $label$lossText',
                style:
                    TextStyle(color: color, fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Flexible(
              child: Text('Best: $best', overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  Widget _blunderList(GameAnalysis analysis) {
    final blunders = analysis.moves
        .where((m) => m.assessment.mark == MoveMark.blunder)
        .toList();
    if (blunders.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 132),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Blunders (${blunders.length})',
              style: Theme.of(context).textTheme.titleSmall),
          Expanded(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final b in blunders)
                  ActionChip(
                    label: Text(
                        '${_sideLabel(b.player)} '
                        '−${b.assessment.equityLoss.toStringAsFixed(3)}: '
                        '${b.assessment.played}'),
                    onPressed: () => _setCursor(b.eventIndex),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (Color, String) _markStyle(MoveMark mark) => switch (mark) {
        MoveMark.best => (Colors.green.shade700, 'Best'),
        MoveMark.good => (Colors.green.shade600, 'Good'),
        MoveMark.dubious => (Colors.amber.shade800, 'Dubious'),
        MoveMark.error => (Colors.orange.shade800, 'Error'),
        MoveMark.blunder => (Colors.red.shade700, 'Blunder'),
      };
}

/// The per-player summary: error rate (mean equity loss) and blunder count.
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.analysis});

  final GameAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(child: _sideSummary(context, Player.white, 'White')),
            const SizedBox(width: 12),
            Expanded(child: _sideSummary(context, Player.black, 'Black')),
          ],
        ),
      ),
    );
  }

  Widget _sideSummary(BuildContext context, Player p, String label) {
    final rate = analysis.errorRate(p);
    final blunders = analysis.blunderCount(p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        Text('Error rate ${rate.toStringAsFixed(3)}'),
        Text('Blunders $blunders'),
      ],
    );
  }
}

String _sideLabel(Player p) => p == Player.white ? 'White' : 'Black';
