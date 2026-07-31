import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';

import 'analytics_events.dart';
import 'app_analytics.dart';
import 'firebase_config.dart';

/// The three observability sinks, resolved together.
///
/// They travel as one bundle because they share one lifecycle: either
/// `Firebase.initializeApp` succeeded and all three are real, or it did not run
/// (desktop, or no config compiled in) or failed, and all three are no-ops.
/// There is no partially-initialized state to reason about.
@immutable
class Observability {
  const Observability({
    required this.analytics,
    required this.performance,
    required this.crashReporter,
    required this.isEnabled,
  });

  /// The all-no-op bundle: desktop, tests, unconfigured builds, and any
  /// initialization failure.
  static const Observability disabled = Observability(
    analytics: NoopAnalytics(),
    performance: NoopPerformance(),
    crashReporter: NoopCrashReporter(),
    isEnabled: false,
  );

  final AppAnalytics analytics;
  final AppPerformance performance;
  final AppCrashReporter crashReporter;

  /// True only when a real Firebase app is behind these three.
  final bool isEnabled;
}

/// Initializes FlutterFire and returns the real sinks — or [Observability.disabled].
///
/// **This is the only function in the app that calls `Firebase.initializeApp`,
/// and the only place the platform guard is applied.** It returns
/// [Observability.disabled] WITHOUT touching any Firebase symbol when:
///
///  * the platform is not Android or iOS ([isFirebaseSupportedPlatform]) — the
///    Windows/Linux/macOS case, checked FIRST so no plugin channel is ever
///    consulted on a platform whose plugins are not registered;
///  * this build carries no complete Firebase config
///    ([FirebaseAppConfig.fromEnvironment] returns null) — a local `flutter
///    run`, or any fork;
///  * initialization itself throws — a bad key, a revoked app, an offline
///    first launch. Telemetry failing must never take the app down with it, so
///    the error is swallowed here (it is still recorded in the on-device crash
///    log by the caller if it matters).
Future<Observability> initializeObservability() async {
  if (!isFirebaseSupportedPlatform) return Observability.disabled;
  final config = FirebaseAppConfig.fromEnvironment();
  if (config == null) return Observability.disabled;

  try {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: config.apiKey,
        appId: config.appId,
        messagingSenderId: config.messagingSenderId,
        projectId: config.projectId,
      ),
    );
    return Observability(
      analytics: FirebaseAppAnalytics(FirebaseAnalytics.instance),
      performance: FirebaseAppPerformance(FirebasePerformance.instance),
      crashReporter: FirebaseAppCrashReporter(FirebaseCrashlytics.instance),
      isEnabled: true,
    );
  } catch (error, stack) {
    // Deliberately swallowed — see the doc comment. Surfaced in debug only, so
    // a misconfigured local build is visible to the developer who caused it.
    if (kDebugMode) {
      debugPrint('Firebase initialization failed; telemetry disabled: $error');
      debugPrintStack(stackTrace: stack);
    }
    return Observability.disabled;
  }
}

/// [AppAnalytics] over Firebase Analytics.
class FirebaseAppAnalytics implements AppAnalytics {
  FirebaseAppAnalytics(this._analytics);

  final FirebaseAnalytics _analytics;

  @override
  void logEvent(String name, {Map<String, Object?> parameters = const {}}) {
    // Fire-and-forget by design: an analytics write must never make a caller
    // await, and a failed write must never surface. The SDK buffers to disk and
    // uploads on its own schedule, so "await" would only measure the enqueue.
    unawaited(_analytics
        .logEvent(name: name, parameters: _sanitize(parameters))
        .catchError((Object _) {}));
  }

  @override
  void logScreenView(String screenName) {
    unawaited(_analytics
        .logScreenView(screenName: screenName)
        .catchError((Object _) {}));
  }

  /// Firebase accepts only `String` and `num` parameter values, and rejects the
  /// whole event if a value is anything else. Nulls are dropped (an absent
  /// parameter is the correct encoding of "not applicable" — `difficulty` on a
  /// hot-seat match, say) and bools are widened to their names, which read
  /// better than 0/1 in the console's filters.
  Map<String, Object>? _sanitize(Map<String, Object?> parameters) {
    if (parameters.isEmpty) return null;
    final out = <String, Object>{};
    parameters.forEach((key, value) {
      switch (value) {
        case null:
          break;
        case final bool b:
          out[key] = b.toString();
        case final num n:
          out[key] = n;
        default:
          out[key] = value.toString();
      }
    });
    return out.isEmpty ? null : out;
  }
}

/// [AppPerformance] over Firebase Performance Monitoring.
class FirebaseAppPerformance implements AppPerformance {
  FirebaseAppPerformance(this._performance);

  final FirebasePerformance _performance;

  @override
  Future<AppTrace> startTrace(String name) async {
    try {
      final trace = _performance.newTrace(name);
      await trace.start();
      return _FirebaseTrace(trace);
    } catch (_) {
      // A trace that cannot start is not a reason to fail the operation it was
      // measuring; the caller gets an inert handle instead.
      return const NoopTrace();
    }
  }

  @override
  Future<T> trace<T>(String name, Future<T> Function() body) async {
    final trace = await startTrace(name);
    try {
      return await body();
    } finally {
      // Stopped on the error path too, so a thrown operation still reports the
      // time it burned rather than leaking an open trace.
      unawaited(trace.stop());
    }
  }

  @override
  void recordDuration(String name, Duration duration) {
    Future<void> record() async {
      final trace = await startTrace(name);
      trace.setMetric(kDurationMetric, duration.inMilliseconds);
      await trace.stop();
    }

    unawaited(record().catchError((Object _) {}));
  }
}

class _FirebaseTrace implements AppTrace {
  _FirebaseTrace(this._trace);

  final Trace _trace;
  bool _stopped = false;

  @override
  void setMetric(String name, int value) {
    if (_stopped) return;
    try {
      _trace.setMetric(name, value);
    } catch (_) {}
  }

  @override
  void putAttribute(String name, String value) {
    if (_stopped) return;
    try {
      _trace.putAttribute(name, value);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _trace.stop();
    } catch (_) {}
  }
}

/// [AppCrashReporter] over Crashlytics.
class FirebaseAppCrashReporter implements AppCrashReporter {
  FirebaseAppCrashReporter(this._crashlytics);

  final FirebaseCrashlytics _crashlytics;

  @override
  void recordError(Object error, StackTrace? stack, {String? reason}) {
    try {
      // `fatal: false` throughout: these are Dart-level errors the process
      // survived. Real fatals — a native crash in the Rust engine `.so`, which
      // no Dart handler can ever see — are captured by the Crashlytics NDK/iOS
      // layer itself, which is the reason this sink exists at all.
      unawaited(_crashlytics
          .recordError(error, stack, reason: reason, fatal: false)
          .catchError((Object _) {}));
    } catch (_) {
      // A reporter that throws while reporting turns one bug into two.
    }
  }
}
