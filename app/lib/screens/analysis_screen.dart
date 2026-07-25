import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../board/board_view.dart';
import '../data/match_repository.dart';
import '../engine/engine_provider.dart';
import '../game/game_record.dart';
import '../tutor/game_analyzer.dart';
import '../tutor/move_assessment.dart';
import '../tutor/tutor_service.dart';
import 'metric_explainer.dart';

/// Post-game replay + analysis for a single recorded game.
///
/// Loads the game's event log and any cached [GameAnalysis]; if none is cached
/// it runs a [GameAnalyzer] (showing a progress bar) and persists the result.
/// The board is a non-interactive [BoardView] driven by a cursor over the
/// replayed prefix states. It shows, at each step:
///
///  * BOTH players' persistent dice pairs as of that step (the historical roll,
///    folded from the event log via [persistentDice]);
///  * for a [MoveEvent] step, the recorded move drawn ON the board — origins as
///    source rings, destinations as triangle highlights, over the PRE-move
///    position — with a Played/Best toggle that swaps the overlay to the engine's
///    best play when it differs;
///  * a scrollable list of EVERY move with its mark + equity loss, the current
///    step highlighted and tappable to jump; and
///  * an ⓘ explainer for the metrics (equity, equity loss, error rate, marks).
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

  /// The game's event log, kept so the historical dice and the record lines can
  /// be reconstructed at any step.
  List<GameEvent> _events = const [];

  /// Rendered move-history lines (one per event that produces a line).
  List<RecordLine> _lines = const [];

  /// The move analyses keyed by their event index (cursor position).
  Map<int, MoveAnalysis> _byEventIndex = const {};

  GameAnalysis? _analysis;
  int _cursor = 0;

  /// When the cursor sits on an assessed move whose best play differs from the
  /// played one, whether the board overlay shows the BEST move (`true`) instead
  /// of the played move (`false`). Reset to `false` on every cursor move.
  bool _showBest = false;

  double _progress = 0;
  bool _loading = true;
  bool _analyzing = false;
  Object? _error;

  /// Scrolls the move list; a per-row key lets the current row be brought into
  /// view when the cursor changes (manual scrolls between changes are respected —
  /// we only auto-scroll on a cursor move).
  final ScrollController _listScroll = ScrollController();

  /// Stable per-event-index row keys, allocated once in [_load] and NEVER
  /// reminted on rebuild, so [Scrollable.ensureVisible] keeps a valid anchor.
  final Map<int, GlobalKey> _rowKeys = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _listScroll.dispose();
    super.dispose();
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
      final lines = buildGameRecord(events);
      setState(() {
        _states = states;
        _events = events;
        _lines = lines;
        _analysis = analysis;
        _byEventIndex = {for (final m in analysis.moves) m.eventIndex: m};
        // Allocate a stable per-row key once the record is known (this screen
        // loads one game, so the record identity never changes afterward). Row
        // keys must NOT be reminted on rebuild or auto-scroll would lose its
        // anchor.
        _rowKeys
          ..clear()
          ..addEntries([
            for (final line in lines)
              if (line.eventIndex != null)
                MapEntry(line.eventIndex!, GlobalKey()),
          ]);
        _cursor = 0;
        _showBest = false;
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
    final clamped = i.clamp(0, states.length - 1);
    setState(() {
      _cursor = clamped;
      _showBest = false; // a fresh position starts on the played move
    });
    _scrollCurrentRowIntoView();
  }

  /// Brings the row for the current cursor into view after the frame lays out.
  /// Only invoked on a cursor move, so a manual scroll in between is respected.
  void _scrollCurrentRowIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _rowKeys[_cursor];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200), alignment: 0.5);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analysis'),
        actions: [
          IconButton(
            tooltip: 'What do these numbers mean?',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showMetricExplainer(context),
          ),
        ],
      ),
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
    // When the cursor sits on an assessed move, frame the PRE-move position: the
    // board as it stood BEFORE the move, so both the played and best overlays
    // read against the choice that was faced. `_states[i]` is the state after
    // events[0..i], so the pre-move state for the move at event `i` is
    // `_states[i-1]` (the post-roll state — its dice are already set). Assessed
    // moves are never at index 0 (the opening roll), so `_cursor - 1` is valid.
    final preMove = current != null && _cursor > 0;
    final shownState = preMove ? states[_cursor - 1] : states[_cursor];

    // Historical dice for the shown position: both players' persistent pairs as
    // folded up to the shown state's event (the pre-move state is after
    // events[0.._cursor-1]; a plain step is after events[0.._cursor]).
    final foldThrough = preMove ? _cursor - 1 : _cursor;
    final (whiteDice, blackDice) = persistentDice(_events, through: foldThrough);

    // The move overlay (only on an assessed move): source rings + destination
    // triangles for either the played move or, when toggled, the engine's best.
    final a = current?.assessment;
    final hasBest = a != null &&
        a.best.checkerMoves.isNotEmpty &&
        !a.best.sameAs(a.played);
    final overlayMove = (a == null)
        ? null
        : (_showBest && hasBest ? a.best : a.played);
    final (srcs, dests) = overlayMove == null
        ? (const <int>{}, const <int>{})
        : moveHighlights(overlayMove);

    return Column(
      children: [
        _SummaryHeader(analysis: analysis),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: BoardView(
                state: shownState,
                interactive: false,
                onMoveCommitted: (_) {},
                whiteDice: whiteDice,
                blackDice: blackDice,
                highlightedSources: srcs,
                highlightedDestinations: dests,
                highlightMovingPlayer:
                    overlayMove == null ? null : current!.player,
              ),
            ),
          ),
        ),
        if (preMove) _preMoveCaption(showingBest: _showBest && hasBest),
        if (hasBest) _playedBestToggle(),
        if (current != null) _moveInfo(current),
        _cursorBar(states.length),
        Expanded(child: _moveList()),
      ],
    );
  }

  Widget _preMoveCaption({required bool showingBest}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.visibility_outlined,
              size: 14, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 6),
          Text(
            showingBest
                ? 'Showing the best move on the position before the move'
                : 'Showing position before the move',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// The Played / Best segmented toggle: swaps the board overlay between the
  /// move that was played and the engine's best play. Shown only when the two
  /// differ (see [_loaded]).
  Widget _playedBestToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, label: Text('Played')),
          ButtonSegment(value: true, label: Text('Best')),
        ],
        selected: {_showBest},
        onSelectionChanged: (s) => setState(() => _showBest = s.first),
      ),
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

  /// The scrollable full move history: every recorded line, with its mark dot +
  /// word + equity loss for assessed moves. The current step is highlighted and
  /// kept in view; any row taps to jump the cursor to that event.
  Widget _moveList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text('Moves', style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: ListView.builder(
            controller: _listScroll,
            itemCount: _lines.length,
            itemBuilder: (context, i) => _moveRow(_lines[i]),
          ),
        ),
      ],
    );
  }

  Widget _moveRow(RecordLine line) {
    final index = line.eventIndex;
    final analysis = index == null ? null : _byEventIndex[index];
    final isCurrent = index != null && index == _cursor;
    final key = index == null ? null : _rowKeys[index];
    final scheme = Theme.of(context).colorScheme;
    final mono = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

    return Container(
      key: key,
      color: isCurrent ? scheme.primaryContainer : null,
      child: InkWell(
        onTap: index == null ? null : () => _setCursor(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(line.text,
                    style: isCurrent
                        ? mono?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer)
                        : mono),
              ),
              if (analysis != null) ...[
                const SizedBox(width: 8),
                _markChip(analysis.assessment),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// A mark-coloured dot + word (+ loss) for a move-list row — the shared P8
  /// idiom, so the mark reads without relying on colour alone.
  Widget _markChip(MoveAssessment a) {
    final (color, label) = _markStyle(a.mark);
    final loss = a.equityLoss;
    final lossText = loss >= 0.001 ? ' −${loss.toStringAsFixed(3)}' : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 4),
        Text('$label$lossText',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ],
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

/// The origin (source-ring) and FINAL-landing (destination-highlight) point sets
/// for a recorded [move], derived by following same-checker chains.
///
/// Hops are consumed greedily into chains: a hop that STARTS where an existing
/// chain currently ENDS extends that chain (its end advances); any other hop
/// opens a new chain. A chain's start is a true origin; its end is a true
/// landing. A chain's intermediate pass-through points are neither — so a
/// multi-hop single-checker move like `24/18/13` marks only `24` (origin) and
/// `13` (landing), never the transit point `18` (which would read as a false
/// destination).
///
/// With multiset hops a single checker's chain cannot always be told apart from
/// two different checkers; this greedy heuristic matches how [MoveBuilder] chains
/// hops and how the notation reads. A point that is genuinely BOTH a landing of
/// one chain and the origin of another (two checkers, one departing where the
/// other arrives, in notation order) correctly appears in both sets.
(Set<int> sources, Set<int> destinations) moveHighlights(Move move) {
  final starts = <int>[];
  final ends = <int>[];
  for (final hop in move.checkerMoves) {
    var extended = false;
    // Extend the most recently opened chain whose current end matches the hop's
    // origin (later chains take precedence, mirroring hop-by-hop entry).
    for (var i = ends.length - 1; i >= 0; i--) {
      if (ends[i] == hop.from) {
        ends[i] = hop.to;
        extended = true;
        break;
      }
    }
    if (!extended) {
      starts.add(hop.from);
      ends.add(hop.to);
    }
  }
  return ({...starts}, {...ends});
}
