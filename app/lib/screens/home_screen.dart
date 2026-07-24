import 'package:flutter/material.dart';

import 'new_match_screen.dart';

/// The app's landing screen: a title and the two match-mode entry points.
/// Each button pushes a [NewMatchScreen] (as a route) configured for its mode.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('AIGammon', style: theme.textTheme.displaySmall),
                  const SizedBox(height: 8),
                  Text(
                    'Backgammon with a neural-net engine',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 48),
                  _ModeButton(
                    label: 'Play vs Computer',
                    icon: Icons.smart_toy_outlined,
                    onPressed: () => _open(context, vsComputer: true),
                  ),
                  const SizedBox(height: 16),
                  _ModeButton(
                    label: 'Two Players',
                    icon: Icons.people_outline,
                    onPressed: () => _open(context, vsComputer: false),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, {required bool vsComputer}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NewMatchScreen(vsComputer: vsComputer),
      ),
    );
  }
}

/// A large, full-width entry button used for the two home modes.
class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 20),
          textStyle: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}
