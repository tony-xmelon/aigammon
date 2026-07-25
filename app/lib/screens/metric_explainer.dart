import 'package:flutter/material.dart';

/// Opens the plain-language [MetricExplainerDialog].
///
/// Shared by every surface that shows equity numbers: the analysis screen's
/// app-bar ⓘ and the in-game hint sheet's ⓘ. One explanation, one place to edit.
void showMetricExplainer(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => const MetricExplainerDialog(),
  );
}

/// Plain-language explainer for the analysis metrics: equity, equity loss (the
/// "−0.016" number), the per-game error rate, and the mark scale with its
/// thresholds. Deliberately non-jargon.
class MetricExplainerDialog extends StatelessWidget {
  const MetricExplainerDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Understanding the metrics'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Equity', style: text.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'Equity is how many points a position is worth on average — the '
              'expected result with the cube at 1. +1.0 means you expect to win '
              'one point; −0.5 means you expect to lose half a point.',
            ),
            const SizedBox(height: 12),
            Text('Equity loss (e.g. −0.016)', style: text.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'For each move we compare what you played against the engine\'s '
              'best play. The equity loss is how much expected value your move '
              'gave up. −0.016 means the move was only 0.016 points worse than '
              'the best — a tiny slip. 0.000 means you found the best play.',
            ),
            const SizedBox(height: 12),
            Text('Error rate', style: text.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'Your error rate is the average equity loss across all your moves '
              'this game. Lower is better: a rate near 0 means you played close '
              'to perfectly; a larger rate means costlier mistakes on average.',
            ),
            const SizedBox(height: 12),
            Text('Move marks', style: text.titleSmall),
            const SizedBox(height: 4),
            const Text('Each move is graded by how much equity it gave up:'),
            const SizedBox(height: 8),
            _threshold(context, Colors.green.shade700, 'Best', 'lost < 0.001'),
            _threshold(context, Colors.green.shade600, 'Good', 'lost < 0.020'),
            _threshold(
                context, Colors.amber.shade800, 'Dubious', 'lost < 0.050'),
            _threshold(context, Colors.orange.shade800, 'Error', 'lost < 0.110'),
            _threshold(
                context, Colors.red.shade700, 'Blunder', 'lost ≥ 0.110'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }

  Widget _threshold(
      BuildContext context, Color color, String label, String range) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ),
          Text(range, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
