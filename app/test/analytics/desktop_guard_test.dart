import 'package:aigammon_app/analytics/analytics_events.dart';
import 'package:aigammon_app/analytics/app_analytics.dart';
import 'package:aigammon_app/analytics/firebase_config.dart';
import 'package:aigammon_app/analytics/firebase_observability.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard that keeps FlutterFire off this project's primary DEV platform.
///
/// All local development and testing happens on Windows, where Crashlytics and
/// Performance Monitoring have no implementation at all and `firebase_core`'s
/// support is partial. The rule is therefore absolute: on anything that is not
/// Android or iOS, the app must not initialize Firebase, must not call a
/// Firebase plugin channel, and must still hand every caller a working (no-op)
/// sink. This suite is what makes that a regression test rather than a comment.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('isFirebaseSupportedPlatform', () {
    test('is true only on Android and iOS', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final expected = platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS;
        expect(isFirebaseSupportedPlatform, expected,
            reason: 'unexpected support verdict for $platform');
      }
    });
  });

  group('initializeObservability on desktop', () {
    /// Records EVERY platform-channel message so the assertion can be about
    /// what was attempted, not merely about what was returned. A guard that
    /// returned the right object while still poking `Firebase.initializeApp`
    /// would pass a return-value-only test and crash on a real desktop build.
    late List<String> channelCalls;

    setUp(() {
      channelCalls = [];
      // There is no wildcard handler, so watch the channels FlutterFire
      // actually uses. Any message on one of these means the guard leaked.
      for (final channel in const [
        'plugins.flutter.io/firebase_core',
        'plugins.flutter.io/firebase_analytics',
        'plugins.flutter.io/firebase_performance',
        'plugins.flutter.io/firebase_crashlytics',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(channel), (call) async {
          channelCalls.add('$channel#${call.method}');
          return null;
        });
      }
    });

    for (final platform in const [
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      test('$platform gets no-op sinks and touches no Firebase channel',
          () async {
        debugDefaultTargetPlatformOverride = platform;

        final observability = await initializeObservability();

        expect(observability.isEnabled, isFalse);
        expect(observability.analytics, isA<NoopAnalytics>());
        expect(observability.performance, isA<NoopPerformance>());
        expect(observability.crashReporter, isA<NoopCrashReporter>());
        expect(channelCalls, isEmpty);
      });
    }

    test('the no-op sinks still satisfy every call without throwing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final o = await initializeObservability();

      o.analytics.logScreenView('home');
      o.analytics.logMatchStarted(mode: 'vsComputer', matchLength: 3);
      o.analytics.logCubeAnswered(mode: 'lan', action: 'take', cubeValue: 2);
      // Buddy Mode never runs on a desktop, but its sink calls have to be as
      // safe as everything else's: the guard is what keeps them quiet, and a
      // guard that only works because nobody calls it is not one.
      o.analytics
        ..logBuddySessionStarted(
          matchLength: 5,
          difficulty: 'medium',
          cubeless: false,
          seat: 'near',
          phrasing: 'terse',
          micHint: true,
        )
        ..logBuddySessionEnded(
          completed: true,
          readabilityRedRate: 0,
          micState: BuddyMicStates.unavailable,
          micHints: 0,
        )
        ..logBuddyCalibration(ok: true, recalibration: false)
        ..logBuddyRecalibrationEntered(calibrationLost: false)
        ..logBuddyFallbackUsed(BuddyFallbacks.dicePad);
      o.performance.recordDuration('cold_start', const Duration(seconds: 1));
      expect(await o.performance.trace('t', () async => 42), 42);
      final trace = await o.performance.startTrace('t');
      trace
        ..setMetric('m', 1)
        ..putAttribute('a', 'b');
      await trace.stop();
      o.crashReporter.recordError(StateError('x'), StackTrace.current);

      expect(channelCalls, isEmpty);
    });
  });

  group('FirebaseAppConfig', () {
    test('is null when the build carries no dart-defines', () {
      // The suite is compiled without any AIGAMMON_FIREBASE_* define, so this
      // is the honest "unconfigured build" case — and it must resolve to "no
      // telemetry", never to a partial config handed to initializeApp.
      expect(
        FirebaseAppConfig.fromEnvironment(platform: TargetPlatform.android),
        isNull,
      );
      expect(
        FirebaseAppConfig.fromEnvironment(platform: TargetPlatform.iOS),
        isNull,
      );
    });

    test('is null on a platform with no app id, even if defines were set', () {
      expect(
        FirebaseAppConfig.fromEnvironment(platform: TargetPlatform.windows),
        isNull,
      );
    });
  });
}
