import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_settings.dart';
import '../data/settings_repository.dart';

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
  Widget build(BuildContext context, WidgetRef ref) {
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
                    const SizedBox(height: 24),
                    _Section(
                      label: 'Default match length',
                      child: SegmentedButton<int>(
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
                      'Auto follows the per-mode default (on for easy/medium vs '
                      'computer, off otherwise).',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
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
