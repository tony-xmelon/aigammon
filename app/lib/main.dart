import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'analytics/analytics_events.dart';
import 'analytics/app_analytics.dart';
import 'analytics/firebase_observability.dart';
import 'data/app_settings.dart';
import 'data/settings_repository.dart';
import 'diagnostics/crash_log.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  // The cold-start clock starts HERE — before the binding, before Firebase,
  // before the first widget — because that is the wait a user actually feels.
  // It is reported as a duration metric once the first frame is up, since the
  // SDK that would host a live trace does not exist yet at this line.
  final startup = Stopwatch()..start();

  // Binding first: the crash handlers touch PlatformDispatcher, and storage
  // resolution goes through a platform channel.
  WidgetsFlutterBinding.ensureInitialized();

  // Installed SYNCHRONOUSLY and before anything else can fail, so an error in
  // startup itself is captured. Storage attaches asynchronously; anything
  // recorded in the gap is merged in when it does (see CrashLog.attachFile).
  CrashLog.installGlobalHandlers();
  unawaited(CrashLog.initializeStorage());

  // Telemetry. On Windows/Linux/macOS — and in any build without a complete
  // Firebase config — this returns the all-no-op bundle WITHOUT touching a
  // single Firebase symbol, so nothing below changes shape by platform: the
  // providers are always overridden, just sometimes with no-ops.
  final observability = await initializeObservability();

  // Crashlytics becomes a SECOND sink on the crash funnel, never a
  // replacement. All three sources — FlutterError.onError,
  // PlatformDispatcher.onError and the engine isolate's onIsolateError — go
  // through CrashLog.record, so this one line covers all of them, and the
  // on-device log keeps working offline and on desktop exactly as before.
  // Attached only when there is a real reporter behind it: registering a no-op
  // sink would just add a call per error for nothing.
  if (observability.isEnabled) {
    final reporter = observability.crashReporter;
    CrashLog.instance.addSink((error, stack, source) {
      reporter.recordError(error, stack, reason: source);
    });
  }

  runApp(ProviderScope(
    overrides: [
      appAnalyticsProvider.overrideWithValue(observability.analytics),
      appPerformanceProvider.overrideWithValue(observability.performance),
      appCrashReporterProvider.overrideWithValue(observability.crashReporter),
    ],
    child: AiGammonApp(startup: startup),
  ));
}

class AiGammonApp extends ConsumerStatefulWidget {
  const AiGammonApp({super.key, this.startup});

  /// The clock started at the top of [main], stopped and reported at the first
  /// frame. Null in tests and harnesses that mount this widget directly — there
  /// is no meaningful cold start to measure there.
  final Stopwatch? startup;

  @override
  ConsumerState<AiGammonApp> createState() => _AiGammonAppState();
}

class _AiGammonAppState extends ConsumerState<AiGammonApp> {
  @override
  void initState() {
    super.initState();
    final startup = widget.startup;
    if (startup == null) return;
    // `addPostFrameCallback` fires after the first frame has been BUILT and
    // laid out, which is the closest a Dart-side measurement gets to
    // "something appeared". Reported as a metric rather than a live trace
    // because the clock predates Firebase (see main()).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      startup.stop();
      ref
          .read(appPerformanceProvider)
          .recordDuration(PerfTraces.coldStart, startup.elapsed);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Follow the persisted theme preference; fall back to system while the
    // (sub-frame) initial load resolves.
    final themeMode =
        ref.watch(settingsProvider).valueOrNull?.themeMode ??
            AppSettings.defaults.themeMode;
    return MaterialApp(
      title: 'AI Gammon',
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
