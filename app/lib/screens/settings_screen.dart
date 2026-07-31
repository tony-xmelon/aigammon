import 'dart:async';

import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/analytics_events.dart';
import '../analytics/analytics_screen_view.dart';
import '../analytics/app_analytics.dart';
import '../branding/app_version.dart';
import '../data/app_settings.dart';
import '../data/settings_repository.dart';
import '../feedback/feedback_link.dart';
import 'diagnostics_screen.dart';

/// The preferences screen. Every control autosaves on change (there is no save
/// button); a "Reset to defaults" action in the app bar restores
/// [AppSettings.defaults]. All writes go through [SettingsRepository.save],
/// which the live [settingsProvider] re-emits, so the UI reflects the store.
///
/// Board-theme selection is intentionally omitted: only light/dark palettes
/// exist and they follow the app's brightness (the [themeMode] setting), so a
/// separate board-theme control would be redundant. It can be added later if
/// custom palettes land.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  // See [HomeScreen] for why every screen splits build/_build.
  Widget build(BuildContext context, WidgetRef ref) => AnalyticsScreenView(
        name: AnalyticsScreens.settings,
        child: _build(context, ref),
      );

  Widget _build(BuildContext context, WidgetRef ref) {
    // The row always exists; during the sub-frame initial load fall back to
    // defaults so the controls always have a concrete selection.
    final settings = ref.watch(settingsProvider).valueOrNull ?? AppSettings.defaults;
    final repo = ref.read(settingsRepositoryProvider);

    void save(AppSettings next) => repo.save(next);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: () => save(AppSettings.defaults),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Section(
                      label: 'Theme',
                      child: SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: ThemeMode.system, label: Text('System')),
                          ButtonSegment(
                              value: ThemeMode.light, label: Text('Light')),
                          ButtonSegment(
                              value: ThemeMode.dark, label: Text('Dark')),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (s) =>
                            save(settings.copyWith(themeMode: s.first)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _Section(
                      label: 'Animation speed',
                      child: SegmentedButton<AnimationSpeed>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: AnimationSpeed.off, label: Text('None')),
                          ButtonSegment(
                              value: AnimationSpeed.normal,
                              label: Text('Normal')),
                          ButtonSegment(
                              value: AnimationSpeed.fast, label: Text('Fast')),
                        ],
                        selected: {settings.animationSpeed},
                        onSelectionChanged: (s) =>
                            save(settings.copyWith(animationSpeed: s.first)),
                      ),
                    ),
                    // Sits directly under the speed control it qualifies: the
                    // speed paces the CHECKERS, this decides whether a roll
                    // tumbles at all. Disabled-looking is avoided deliberately —
                    // at speed "None" the switch still reflects the stored
                    // preference, it simply has no beat to run.
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Dice roll animation'),
                      subtitle:
                          const Text('Tumble the dice before each roll'),
                      value: settings.diceRollAnimation,
                      onChanged: (v) =>
                          save(settings.copyWith(diceRollAnimation: v)),
                    ),
                    const SizedBox(height: 24),
                    _Section(
                      label: 'Default match length',
                      child: SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 1, label: Text('1')),
                          ButtonSegment(value: 3, label: Text('3')),
                          ButtonSegment(value: 5, label: Text('5')),
                          ButtonSegment(value: 7, label: Text('7')),
                        ],
                        selected: {settings.defaultMatchLength},
                        onSelectionChanged: (s) =>
                            save(settings.copyWith(defaultMatchLength: s.first)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _Section(
                      label: 'Default difficulty',
                      child: SegmentedButton<Difficulty>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: Difficulty.easy, label: Text('Easy')),
                          ButtonSegment(
                              value: Difficulty.medium, label: Text('Medium')),
                          ButtonSegment(
                              value: Difficulty.hard, label: Text('Hard')),
                          ButtonSegment(
                              value: Difficulty.expert, label: Text('Expert')),
                        ],
                        selected: {settings.defaultDifficulty},
                        onSelectionChanged: (s) =>
                            save(settings.copyWith(defaultDifficulty: s.first)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _Section(
                      label: 'Tutor mode default',
                      child: SegmentedButton<_TutorChoice>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                              value: _TutorChoice.auto, label: Text('Auto')),
                          ButtonSegment(
                              value: _TutorChoice.on, label: Text('On')),
                          ButtonSegment(
                              value: _TutorChoice.off, label: Text('Off')),
                        ],
                        selected: {_TutorChoice.fromOverride(settings.tutorOverride)},
                        onSelectionChanged: (s) => save(settings.copyWith(
                            tutorOverride: s.first.toOverride())),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Auto follows the per-mode default: on for easy/medium vs '
                      'computer and for nearby/online play, off otherwise. On '
                      'and Off apply to every mode. The tutor only ever reads '
                      'your own moves, on this device.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    _Section(
                      label: 'Gameplay',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Move highlights'),
                            subtitle: const Text(
                                'Ring selectable checkers and light up '
                                'destinations'),
                            value: settings.showHighlights,
                            onChanged: (v) =>
                                save(settings.copyWith(showHighlights: v)),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Drag to move'),
                            subtitle: const Text(
                                'Drag a checker to its destination (taps always '
                                'work)'),
                            value: settings.enableDrag,
                            onChanged: (v) =>
                                save(settings.copyWith(enableDrag: v)),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Combined moves'),
                            subtitle: const Text(
                                'One tap runs a checker through both dice'),
                            value: settings.enableCombinedTaps,
                            onChanged: (v) =>
                                save(settings.copyWith(enableCombinedTaps: v)),
                          ),
                          // Hot-seat only, and OFF by default: "when playing
                          // person vs person, the default should be not
                          // flipping the board. People will share the device at
                          // each side ... and keep the board fixed". Off is the
                          // tabletop layout (fixed board, an action bar at each
                          // player's edge); on restores the pre-v7 flip, where
                          // the board turns to face whoever is on turn and the
                          // single bottom bar follows them.
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Rotate board between turns'),
                            subtitle: const Text(
                                'Hot-seat: flip the view for the active player'),
                            value: settings.rotateBoardHotSeat,
                            onChanged: (v) =>
                                save(settings.copyWith(rotateBoardHotSeat: v)),
                          ),
                          // Independent of the rotation above — it covers the
                          // hand-over in either layout: "do not show the pass
                          // the device screen, or at least make it a setting,
                          // disabled by default".
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Pass-device screen'),
                            subtitle: const Text(
                                'Cover the board between hot-seat turns'),
                            value: settings.showPassDevice,
                            onChanged: (v) =>
                                save(settings.copyWith(showPassDevice: v)),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Show score'),
                            subtitle: const Text(
                                'Display the running match score in the header'),
                            value: settings.showScoring,
                            onChanged: (v) =>
                                save(settings.copyWith(showScoring: v)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // The ONLY route to the on-device error log — the sink that
                    // works with no network and no Firebase config, and the
                    // only one a tester can read. Crashlytics reports the same
                    // errors remotely on mobile, but nothing here depends on
                    // it having been configured.
                    _Section(
                      label: 'Diagnostics',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.bug_report_outlined),
                            title: const Text('Error log'),
                            subtitle: const Text(
                                'Recent errors, ready to copy into a bug report'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const DiagnosticsScreen(),
                              ),
                            ),
                          ),
                          // Deliberately WITHOUT the error log attached: this
                          // is the "I have an idea" / "this feels wrong" route,
                          // and most of the time there is no crash to send. The
                          // Diagnostics screen has its own feedback action that
                          // does attach the log.
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.feedback_outlined),
                            title: const Text('Send feedback'),
                            subtitle: const Text(
                                'Opens a pre-filled issue on GitHub'),
                            trailing: const Icon(Icons.open_in_new, size: 18),
                            onTap: () => _sendFeedback(ref),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the pre-filled GitHub issue form.
///
/// Fire-and-forget, and failure is silent by design: if no browser can be
/// reached there is nothing the user can do about it from here, and a red
/// error under a "Send feedback" button is a poor joke.
void _sendFeedback(WidgetRef ref) {
  ref.read(appAnalyticsProvider).logFeedbackOpened();
  final uri = buildFeedbackIssueUri(
    appVersion: appVersion,
    platform: currentPlatformName(),
  );
  unawaited(ref.read(urlOpenerProvider)(uri).catchError((Object _) => false));
}

/// The tri-state tutor default as a segmented choice: auto (null), on, off.
enum _TutorChoice {
  auto,
  on,
  off;

  static _TutorChoice fromOverride(bool? override) => switch (override) {
        true => _TutorChoice.on,
        false => _TutorChoice.off,
        null => _TutorChoice.auto,
      };

  bool? toOverride() => switch (this) {
        _TutorChoice.on => true,
        _TutorChoice.off => false,
        _TutorChoice.auto => null,
      };
}

/// A labelled settings row: a caption above its control (mirrors the new-match
/// screen's section styling).
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}
