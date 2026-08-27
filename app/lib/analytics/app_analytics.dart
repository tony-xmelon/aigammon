import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'analytics_events.dart';

/// The app's observability seam: usage analytics.
///
/// **Why an interface at all.** The concrete backend is FlutterFire, which
/// exists only on Android and iOS in this app (see `firebase_config.dart` for
/// the platform guard and the reasoning). Every caller therefore talks to THIS,
/// never to `FirebaseAnalytics`, and gets a [NoopAnalytics] on Windows/Linux/
/// macOS and in every widget test. Two consequences worth stating plainly:
///
///  * no screen, controller or provider can crash because Firebase is missing;
///  * a test can assert on what WOULD have been reported by injecting a fake,
///    without a network, a `Firebase.initializeApp`, or a platform channel.
///
/// Deliberately narrow: two primitives, with the typed vocabulary layered on
/// top as an extension. A fake needs to implement two methods, and the event
/// schema lives in one file ([AnalyticsEvents]) instead of being spread across
/// an interface with a dozen bespoke signatures.
abstract interface class AppAnalytics {
  /// Records a custom event. [parameters] values must be `String`, `int`,
  /// `double` or `bool`; nulls are dropped by the implementation rather than
  /// sent, so callers may pass conditionally-absent params inline.
  void logEvent(String name, {Map<String, Object?> parameters});

  /// Records that [screenName] (one of [AnalyticsScreens]) came to the front.
  void logScreenView(String screenName);
}

/// The typed event vocabulary. Callers use these, not [AppAnalytics.logEvent],
/// so a parameter can never be misspelled at a call site.
extension AppAnalyticsEvents on AppAnalytics {
  /// A match has begun. [mode] is one of [AnalyticsModes].
  void logMatchStarted({
    required String mode,
    required int matchLength,
    Difficulty? difficulty,
    bool? cubeless,
    bool? tutor,
  }) {
    logEvent(AnalyticsEvents.matchStarted, parameters: {
      AnalyticsParams.mode: mode,
      AnalyticsParams.matchLength: matchLength,
      AnalyticsParams.difficulty: difficulty?.name,
      AnalyticsParams.cubeless: cubeless,
      AnalyticsParams.tutor: tutor,
    });
  }

  /// A match has been decided. [localWon] is from the perspective of the person
  /// holding this device; in hot-seat (where both sides are local) pass `null`.
  void logMatchCompleted({
    required String mode,
    required int matchLength,
    required bool? localWon,
    required int winnerScore,
    required int loserScore,
  }) {
    logEvent(AnalyticsEvents.matchCompleted, parameters: {
      AnalyticsParams.mode: mode,
      AnalyticsParams.matchLength: matchLength,
      AnalyticsParams.winner: switch (localWon) {
        true => 'local',
        false => 'opponent',
        null => 'shared_device',
      },
      AnalyticsParams.scoreWinner: winnerScore,
      AnalyticsParams.scoreLoser: loserScore,
    });
  }

  /// The hint panel was opened.
  void logTutorHintUsed({required String mode}) {
    logEvent(AnalyticsEvents.tutorHintUsed,
        parameters: {AnalyticsParams.mode: mode});
  }

  /// A resignation was offered. [value] is `single` | `gammon` | `backgammon`.
  void logResignOffered({required String mode, required String value}) {
    logEvent(AnalyticsEvents.resignOffered, parameters: {
      AnalyticsParams.mode: mode,
      AnalyticsParams.resignValue: value,
    });
  }

  /// The local player doubled. [cubeValue] is the face value BEFORE the double.
  void logCubeOffered({required String mode, required int cubeValue}) {
    logEvent(AnalyticsEvents.cubeOffered, parameters: {
      AnalyticsParams.mode: mode,
      AnalyticsParams.cubeValue: cubeValue,
    });
  }

  /// The local player answered a double. [action] is `take` | `drop`.
  void logCubeAnswered({
    required String mode,
    required String action,
    required int cubeValue,
  }) {
    logEvent(AnalyticsEvents.cubeAnswered, parameters: {
      AnalyticsParams.mode: mode,
      AnalyticsParams.cubeAction: action,
      AnalyticsParams.cubeValue: cubeValue,
    });
  }

  /// The feedback link was opened.
  void logFeedbackOpened() => logEvent(AnalyticsEvents.feedbackOpened);

  // --- Buddy Mode ------------------------------------------------------------

  /// A Buddy match began. [seat] is a `BuddySeat.name`, [phrasing] a
  /// `BuddyPhrasing.name`, and [micHint] whether the attention hint is enabled
  /// in Settings — not whether it ever ran, which is
  /// [logBuddySessionEnded]'s `micState`.
  void logBuddySessionStarted({
    required int matchLength,
    required String difficulty,
    required bool cubeless,
    required String seat,
    required String phrasing,
    required bool micHint,
  }) {
    logEvent(AnalyticsEvents.buddySessionStarted, parameters: {
      AnalyticsParams.mode: AnalyticsModes.buddy,
      AnalyticsParams.matchLength: matchLength,
      AnalyticsParams.difficulty: difficulty,
      AnalyticsParams.cubeless: cubeless,
      AnalyticsParams.buddySeat: seat,
      AnalyticsParams.buddyPhrasing: phrasing,
      AnalyticsParams.micHint: micHint,
    });
  }

  /// A Buddy match ended. [readabilityRedRate] is 0..1 over the frames the
  /// session actually assessed; [micState] is one of [BuddyMicStates].
  void logBuddySessionEnded({
    required bool completed,
    required double readabilityRedRate,
    required String micState,
    required int micHints,
  }) {
    logEvent(AnalyticsEvents.buddySessionEnded, parameters: {
      AnalyticsParams.mode: AnalyticsModes.buddy,
      AnalyticsParams.buddyCompleted: completed,
      AnalyticsParams.readabilityRedRate: readabilityRedRate,
      AnalyticsParams.micState: micState,
      AnalyticsParams.micHints: micHints,
    });
  }

  /// One run of the guided corner flow. [recalibration] separates a mid-match
  /// rescue from the calibration that starts a session.
  void logBuddyCalibration({
    required bool ok,
    required bool recalibration,
  }) {
    logEvent(AnalyticsEvents.buddyCalibrationAttempted, parameters: {
      AnalyticsParams.calibrationOk: ok,
      AnalyticsParams.recalibration: recalibration,
    });
  }

  /// The aim is being fixed mid-match. [calibrationLost] is whether the light
  /// had already declared the calibration dead, as opposed to the user choosing
  /// to re-aim a working one.
  void logBuddyRecalibrationEntered({required bool calibrationLost}) {
    logEvent(AnalyticsEvents.buddyRecalibrationEntered, parameters: {
      AnalyticsParams.calibrationLost: calibrationLost,
    });
  }

  /// A perceptual input was answered by hand. [fallback] is one of
  /// [BuddyFallbacks].
  void logBuddyFallbackUsed(String fallback) {
    logEvent(AnalyticsEvents.buddyFallbackUsed, parameters: {
      AnalyticsParams.buddyFallback: fallback,
    });
  }
}

/// Does nothing, always. The implementation on every non-mobile platform, the
/// default in every widget test, and the fallback whenever Firebase
/// initialization fails.
@immutable
class NoopAnalytics implements AppAnalytics {
  const NoopAnalytics();

  @override
  void logEvent(String name, {Map<String, Object?> parameters = const {}}) {}

  @override
  void logScreenView(String screenName) {}
}

// --- Performance -------------------------------------------------------------

/// One in-flight performance trace.
abstract interface class AppTrace {
  /// Attaches a numeric metric to the trace. Ignored after [stop].
  void setMetric(String name, int value);

  /// Attaches a string attribute (a dimension to slice the trace by).
  void putAttribute(String name, String value);

  /// Ends the trace and queues it for upload. Idempotent.
  Future<void> stop();
}

/// The app's observability seam: performance traces. Same rationale as
/// [AppAnalytics] — see that class.
abstract interface class AppPerformance {
  /// Starts a custom trace named [name] (one of [PerfTraces]).
  Future<AppTrace> startTrace(String name);

  /// Runs [body] inside a trace, stopping it whether [body] succeeds or throws.
  ///
  /// Errors propagate unchanged: a trace must never swallow, delay or reorder
  /// the thing it is measuring.
  Future<T> trace<T>(String name, Future<T> Function() body);

  /// Records an already-measured [duration] as a trace carrying a
  /// [kDurationMetric] metric.
  ///
  /// The escape hatch for spans whose clock starts before the SDK is available
  /// — cold start being the only one today: the process is already several
  /// hundred milliseconds old by the time `Firebase.initializeApp` returns, so
  /// a trace started then would measure the wrong thing.
  void recordDuration(String name, Duration duration);
}

/// Does nothing, always. See [NoopAnalytics].
@immutable
class NoopPerformance implements AppPerformance {
  const NoopPerformance();

  @override
  Future<AppTrace> startTrace(String name) async => const NoopTrace();

  @override
  Future<T> trace<T>(String name, Future<T> Function() body) => body();

  @override
  void recordDuration(String name, Duration duration) {}
}

/// Does nothing, always.
@immutable
class NoopTrace implements AppTrace {
  const NoopTrace();

  @override
  void setMetric(String name, int value) {}

  @override
  void putAttribute(String name, String value) {}

  @override
  Future<void> stop() async {}
}

// --- Crash reporting ---------------------------------------------------------

/// The app's observability seam: crash/error reporting.
///
/// This is the REMOTE sink. It is added ALONGSIDE the on-device
/// `CrashLog` (`lib/diagnostics/crash_log.dart`), never instead of it: the
/// on-device log works offline, with no account, on Windows, and is the only
/// thing a tester can copy out by hand. Both are fed from the same funnel —
/// see `CrashLog.addSink`.
abstract interface class AppCrashReporter {
  /// Reports a non-fatal error. Never throws.
  void recordError(Object error, StackTrace? stack, {String? reason});
}

/// Does nothing, always. See [NoopAnalytics].
@immutable
class NoopCrashReporter implements AppCrashReporter {
  const NoopCrashReporter();

  @override
  void recordError(Object error, StackTrace? stack, {String? reason}) {}
}

// --- Injection ---------------------------------------------------------------

/// The app-wide analytics sink.
///
/// Defaults to [NoopAnalytics] and is OVERRIDDEN in `main()` when — and only
/// when — Firebase actually initialized (mobile, with a complete config). A
/// widget test that overrides nothing gets the no-op; a widget test that wants
/// to assert on events overrides this with a recording fake.
final appAnalyticsProvider =
    Provider<AppAnalytics>((ref) => const NoopAnalytics());

/// The app-wide performance-trace sink. See [appAnalyticsProvider].
final appPerformanceProvider =
    Provider<AppPerformance>((ref) => const NoopPerformance());

/// The app-wide crash reporter. See [appAnalyticsProvider].
final appCrashReporterProvider =
    Provider<AppCrashReporter>((ref) => const NoopCrashReporter());
