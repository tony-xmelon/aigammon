import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/crash_log.dart';

/// Shows the rolling on-device error log and lets the user get it OUT.
///
/// There is no remote crash reporting (see [CrashLog]'s doc comment for why
/// that is deferred), so this screen is the whole delivery mechanism: a tester
/// who hits a bug taps Settings → Diagnostics → Copy and pastes the result
/// into a message. "Copy to clipboard" rather than a share sheet deliberately —
/// `share_plus` is not a dependency of this app and a plugin is not worth
/// adding for one button.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, this.log});

  /// Injectable for tests; defaults to the process-wide log the global
  /// handlers write to.
  final CrashLog? log;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  CrashLog get _log => widget.log ?? CrashLog.instance;

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _log.asText()));
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Diagnostics copied to clipboard')),
    );
  }

  Future<void> _clear() async {
    await _log.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entries = _log.entries.reversed.toList(growable: false);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            onPressed: entries.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy to clipboard',
          ),
          IconButton(
            onPressed: entries.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
          ),
        ],
      ),
      body: SafeArea(
        child: entries.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'No errors recorded.\n\nIf something goes wrong, it is '
                    'logged here — come back and copy the details into a bug '
                    'report.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const Divider(height: 24),
                itemBuilder: (context, i) {
                  final e = entries[i];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.time.toIso8601String()}  ·  ${e.source}',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(e.error,
                          style: theme.textTheme.bodyMedium),
                      if (e.stack != null) ...[
                        const SizedBox(height: 8),
                        // Stacks are wide; let them scroll sideways rather
                        // than wrap into an unreadable block.
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SelectableText(
                            e.stack!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }
}
