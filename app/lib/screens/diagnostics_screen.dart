import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../branding/app_version.dart';
import '../diagnostics/crash_log.dart';
import '../feedback/feedback_link.dart';

/// Shows the rolling on-device error log and lets the user get it OUT.
///
/// Two routes out, and they are for different people. **Copy to clipboard** is
/// the universal one — it works with no network, no GitHub account and no
/// Firebase config, and a tester can paste the result into any message.
/// ("Copy" rather than a share sheet deliberately: `share_plus` is not a
/// dependency and a plugin is not worth adding for one button.) **Report an
/// issue** opens a GitHub issue with the log already pasted in, for the user
/// who is willing to file one.
///
/// Crashlytics reports the same errors automatically on mobile, but this screen
/// does not depend on it: on desktop, and in any build without Firebase config,
/// this is still the whole delivery mechanism.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, this.log, this.openUrl});

  /// Injectable for tests; defaults to the process-wide log the global
  /// handlers write to.
  final CrashLog? log;

  /// How a URL is opened. Injectable for the same reason [log] is: this screen
  /// is mounted in tests WITHOUT a [ProviderScope], so it takes its
  /// collaborators as parameters rather than reading providers.
  final UrlOpener? openUrl;

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

  /// Opens a pre-filled GitHub issue carrying the log.
  ///
  /// The excerpt is the same human-readable report Copy produces, clamped by
  /// [buildFeedbackIssueUri] to something a URL can actually carry — the
  /// clipboard route stays the way to send a long log in full.
  void _reportIssue() {
    final uri = buildFeedbackIssueUri(
      appVersion: appVersion,
      platform: currentPlatformName(),
      diagnosticsExcerpt: _log.isEmpty ? null : _log.asText(),
    );
    final open = widget.openUrl ?? openExternally;
    // Silent on failure: there is no browser to fall back to, and an error
    // under a "report an issue" button is a poor joke.
    unawaited(open(uri).catchError((Object _) => false));
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
          // Always enabled, unlike Copy and Clear: "there is nothing in the log
          // and the app is still misbehaving" is a report worth sending, and
          // the version and platform go with it either way.
          IconButton(
            onPressed: _reportIssue,
            icon: const Icon(Icons.outgoing_mail),
            tooltip: 'Report an issue on GitHub',
          ),
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
