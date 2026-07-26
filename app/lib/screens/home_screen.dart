import 'package:flutter/material.dart';

import '../branding/app_mark.dart';
import '../branding/app_version.dart';
import 'history_screen.dart';
import 'lan_screen.dart';
import 'new_match_screen.dart';
import 'online_screen.dart';
import 'settings_screen.dart';

/// The app's landing screen: the brand mark, the app's name and promise, and
/// the match-mode entry points. Each mode button pushes a [NewMatchScreen] (as
/// a route) configured for its mode.
///
/// Layout: a settings row on top, the identity + buttons cluster centred in the
/// space that remains, and the version pinned to the bottom. The cluster is
/// scrollable so a short window (a landscape phone, a small desktop window)
/// degrades to a scroll rather than an overflow.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                // Biased slightly above centre: the settings row already sits
                // above the cluster, so a true centre reads as low, and this
                // keeps the identity (mark + name + promise) in the upper third
                // with the buttons following it.
                alignment: const Alignment(0, -0.28),
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            label: 'AIGammon',
                            child: const AppMark(size: 140),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'AIGammon',
                            style: theme.textTheme.displaySmall,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Backgammon with a neural-net engine',
                            style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 40),
                          _ModeButton(
                            label: 'Play vs Computer',
                            icon: Icons.smart_toy_outlined,
                            onPressed: () => _open(context, vsComputer: true),
                          ),
                          const SizedBox(height: 12),
                          _ModeButton(
                            label: 'Two Players',
                            icon: Icons.people_outline,
                            onPressed: () => _open(context, vsComputer: false),
                          ),
                          const SizedBox(height: 12),
                          _ModeButton(
                            label: 'Play Nearby',
                            icon: Icons.wifi_tethering,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const LanScreen(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          _ModeButton(
                            label: 'Play Online',
                            icon: Icons.public,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const OnlineScreen(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const HistoryScreen(),
                                ),
                              ),
                              icon: const Icon(Icons.history),
                              label: const Text('History'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 4),
              child: Text(
                'v$appVersion',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
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

/// A large, full-width entry button used for the home modes.
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
          padding: const EdgeInsets.symmetric(vertical: 18),
          textStyle: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}
