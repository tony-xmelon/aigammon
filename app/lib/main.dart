import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_settings.dart';
import 'data/settings_repository.dart';
import 'diagnostics/crash_log.dart';
import 'screens/home_screen.dart';

void main() {
  // Binding first: the crash handlers touch PlatformDispatcher, and storage
  // resolution goes through a platform channel.
  WidgetsFlutterBinding.ensureInitialized();

  // Installed SYNCHRONOUSLY and before anything else can fail, so an error in
  // startup itself is captured. Storage attaches asynchronously; anything
  // recorded in the gap is merged in when it does (see CrashLog.attachFile).
  CrashLog.installGlobalHandlers();
  unawaited(CrashLog.initializeStorage());

  runApp(const ProviderScope(child: AiGammonApp()));
}

class AiGammonApp extends ConsumerWidget {
  const AiGammonApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Follow the persisted theme preference; fall back to system while the
    // (sub-frame) initial load resolves.
    final themeMode =
        ref.watch(settingsProvider).valueOrNull?.themeMode ??
            AppSettings.defaults.themeMode;
    return MaterialApp(
      title: 'AIGammon',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: themeMode,
      home: const HomeScreen(),
    );
  }
}

/// The app theme for one brightness: the brown-seeded Material 3 scheme, plus
/// the app-wide segmented-button treatment.
ThemeData _theme(Brightness brightness) {
  final scheme =
      ColorScheme.fromSeed(seedColor: Colors.brown, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // Segmented buttons carry most of this app's choices (match length,
    // difficulty, side, theme, animation speed, Played/Best). Material's
    // default selected fill is `secondaryContainer`, which on a brown seed is
    // a pale peach barely a shade off the surface — at a glance you cannot
    // tell which segment is on. Selected segments therefore use the PRIMARY
    // pair, the same weight as a filled button, so the current choice is
    // unmistakable at arm's length and identical on every screen.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.primary : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.disabled)
              ? null
              : states.contains(WidgetState.selected)
                  ? scheme.onPrimary
                  : scheme.onSurface,
        ),
      ),
    ),
  );
}
