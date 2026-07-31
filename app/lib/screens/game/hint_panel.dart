import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';

import '../metric_explainer.dart';

/// The tutor hint panel's state: whether it is open, whether its ranking is
/// still resolving, and what came back.
///
/// A [ChangeNotifier] rather than screen state so the panel's own comings and
/// goings are one object's business. It notifies exactly where the screen used
/// to call `setState`: on open, when the ranking lands, and on close.
///
/// The caller supplies the ranking as a thunk ([open]) rather than a
/// [TutorService], so this holds no engine dependency at all — and an engine
/// failure that comes back as an empty list is rendered by the panel as "no
/// suggestion", which is why the spinner stops either way and the panel can
/// never be left loading forever.
class HintController extends ChangeNotifier {
  /// Full move to STAGE into the interactive board (tap-to-apply hint). Fired
  /// when a hint row is tapped; the `BoardView` resets its builder and re-enters
  /// the move's hops, leaving it complete but uncommitted for the user's Confirm.
  final ValueNotifier<Move?> stagedMove = ValueNotifier<Move?>(null);

  bool get isOpen => _open;
  bool _open = false;

  bool get isLoading => _loading;
  bool _loading = false;

  List<ScoredMove>? get moves => _moves;
  List<ScoredMove>? _moves;

  /// Fences a superseded request (a panel reopened, or closed and reopened)
  /// against a ranking that is still in flight.
  int _seq = 0;

  bool _disposed = false;

  /// Opens the panel and asks [request] for the ranking to fill it with.
  void open(Future<List<ScoredMove>> Function() request) {
    _open = true;
    _loading = true;
    _moves = null;
    // Clear any prior staged move so re-tapping the same play in a later panel
    // is a fresh null→move transition (and thus fires the board listener).
    stagedMove.value = null;
    notifyListeners();
    final seq = ++_seq;
    unawaited(request().then((moves) {
      if (_disposed || seq != _seq) return;
      _loading = false;
      _moves = moves;
      notifyListeners();
    }));
  }

  void close() {
    _open = false;
    _loading = false;
    _moves = null;
    _seq++;
    notifyListeners();
  }

  /// Stages [move] onto the interactive board and closes the panel. [stage] is
  /// false when no human move is pending — the board is not interactive then and
  /// would ignore it, so the tap simply closes the panel.
  void apply(Move move, {required bool stage}) {
    if (stage) stagedMove.value = move;
    close();
  }

  @override
  void dispose() {
    _disposed = true;
    stagedMove.dispose();
    super.dispose();
  }
}

/// The in-tree hint bottom panel: top-5 plays with equity and delta, or a
/// loading spinner while the ranking resolves.
class HintPanel extends StatelessWidget {
  const HintPanel({
    super.key,
    required this.loading,
    required this.moves,
    required this.onClose,
    required this.onApply,
  });

  final bool loading;
  final List<ScoredMove>? moves;
  final VoidCallback onClose;

  /// Tap-to-apply: stage the play onto the interactive board and close the
  /// panel.
  final void Function(Move) onApply;

  /// Width of each of the panel's number columns, shared by the header and the
  /// rows so the labels sit exactly over their figures.
  static const double _numberColumn = 64;

  @override
  Widget build(BuildContext context) {
    final ranked = moves ?? const <ScoredMove>[];
    final bestEq = ranked.isEmpty ? 0.0 : ranked.first.equity;
    final top = ranked.take(5).toList();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const ColoredBox(color: Colors.black54),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Top plays',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                        ),
                        IconButton(
                          tooltip: 'What do these numbers mean?',
                          icon: const Icon(Icons.info_outline, size: 20),
                          onPressed: () => showMetricExplainer(context),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (top.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No hints available.'),
                      )
                    else ...[
                      _columnHeader(context),
                      for (var i = 0; i < top.length; i++)
                        _row(context, i, top[i], bestEq),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Names the panel's two bare number columns ("Equity" / "Loss"), right-
  /// aligned over them at the same widths the rows use, so the figures are not
  /// left for the reader to guess at. The ⓘ in the header explains what they
  /// mean.
  Widget _columnHeader(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          const Spacer(),
          SizedBox(
            width: _numberColumn,
            child: Text('Equity', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: _numberColumn,
            child: Text('Loss', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, int i, ScoredMove sm, double bestEq) {
    final delta = i == 0 ? '—' : (sm.equity - bestEq).toStringAsFixed(3);
    final mono = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return InkWell(
      onTap: () => onApply(sm.move),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Text('${i + 1}.', style: mono),
            ),
            Expanded(child: Text('${sm.move}', style: mono)),
            const SizedBox(width: 8),
            SizedBox(
              width: _numberColumn,
              child: Text(sm.equity.toStringAsFixed(3),
                  style: mono, textAlign: TextAlign.right),
            ),
            SizedBox(
              width: _numberColumn,
              child: Text(delta, style: mono, textAlign: TextAlign.right),
            ),
          ],
        ),
      ),
    );
  }
}
