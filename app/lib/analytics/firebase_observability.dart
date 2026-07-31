import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';

import '../diagnostics/crash_log.dart';
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
///    the error is swallowed rather than rethrown — but it IS written to
///    [CrashLog], which is the only diagnostic channel that still works when
///    the remote one is what broke. Without that, a release build with a
///    revoked key is indistinguishable from a build that was never configured.
///
/// [configOverride] and [initializer] exist for `test/analytics/
/// firebase_init_failure_test.dart`: the dart-defines are compile-time
/// constants and `Firebase.initializeApp` needs a platform channel, so the
/// failure path is unreachable in a test process without a seam. Production
/// calls this with neither.
Future<Observability> initializeObservability({
  @visibleForTesting FirebaseAppConfig? configOverride,
  @visibleForTesting FirebaseInitializer? initializer,
}) async {
  if (!isFirebaseSupportedPlatform) return Observability.disabled;
  final config = configOverride ?? FirebaseAppConfig.fromEnvironment();
  if (config == null) return Observability.disabled;

  try {
    await (initializer ?? _initializeFirebaseApp)(
      FirebaseOptions(
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
    // Not rethrown — see the doc comment — but not silent either. The
    // on-device log survives a dead telemetry backend and is reachable from
    // the Diagnostics screen and from a "Send feedback" issue, so a broken
    // Firebase config can be diagnosed from a release build in the field.
    CrashLog.instance.record(error, stack: stack, source: 'firebase-init');
    if (kDebugMode) {
      debugPrint('Firebase initialization failed; telemetry disabled: $error');
      debugPrintStack(stackTrace: stack);
    }
    return Observability.disabled;
  }
}

/// How [initializeObservability] brings up the Firebase app. A typedef so a
/// test can substitute one that throws.
typedef FirebaseInitializer = Future<void> Function(FirebaseOptions options);

/// **The only call to `Firebase.initializeApp` in the app.**
Future<void> _initializeFirebaseApp(FirebaseOptions options) =>
    Firebase.initializeApp(options: options);

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
///
/// **What this actually captures, precisely.** Everything that reaches
/// [recordError] is a Dart-level error the process survived. Native crashes —
/// a SIGSEGV inside the Rust engine `.so`, which no Dart handler can ever
/// see — are a different mechanism entirely, and they are captured on ONE of
/// the two platforms:
///
///  * **iOS: yes.** The `FirebaseCrashlytics` pod installs its signal and
///    NSException handlers when `Firebase.initializeApp` runs, so a native
///    crash after that point is reported. It arrives UNSYMBOLICATED, though:
///    that needs an `upload-symbols` run-script build phase in
///    `Runner.xcodeproj`, which this project does not have — see the Telemetry
///    section of `firebase/DEPLOY.md`.
///  * **Android: no.** NDK capture requires the `firebase-crashlytics-ndk`
///    artifact and the Crashlytics Gradle plugin, and the Gradle plugin reads
///    the app id out of the resource that `com.google.gms.google-services`
///    generates from `google-services.json`. This project deliberately ships
///    no `google-services.json` (every Firebase value is a `--dart-define`;
///    see `firebase_config.dart`), so applying the plugin would break the
///    Android build rather than fix anything. A native crash in the engine
///    `.so` on Android is therefore NOT reported to Crashlytics today. The
///    trade-off — adopt the config file, or accept Dart-only reporting — is
///    written up in `firebase/DEPLOY.md`.
///
/// So on Android this sink is not a second-best copy of native capture; it is
/// the ONLY remote crash reporting there is.
class FirebaseAppCrashReporter implements AppCrashReporter {
  FirebaseAppCrashReporter(this._crashlytics);

  final FirebaseCrashlytics _crashlytics;

  @override
  void recordError(Object error, StackTrace? stack, {String? reason}) {
    try {
      // `fatal: false` throughout: these are Dart-level errors the process
      // survived, and marking a survived error fatal would corrupt the
      // crash-free-users metric. Genuine process-killing crashes are the
      // native layer's business — see the class doc for exactly which platform
      // reports those and which does not.
      unawaited(_crashlytics
          .recordError(error, stack, reason: reason, fatal: false)
          .catchError((Object _) {}));
    } catch (_) {
      // A reporter that throws while reporting turns one bug into two.
    }
  }
}
