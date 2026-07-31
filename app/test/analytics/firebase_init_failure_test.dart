import 'package:aigammon_app/analytics/firebase_config.dart';
import 'package:aigammon_app/analytics/firebase_observability.dart';
import 'package:aigammon_app/diagnostics/crash_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// What happens when `Firebase.initializeApp` fails on a device.
///
/// The failure is deliberately swallowed — telemetry dying must never take the
/// app down with it — but "swallowed" used to mean "invisible": a `debugPrint`
/// under `kDebugMode` and nothing else, so on the release build that actually
/// matters a revoked key or a malformed app id produced a binary that silently
/// reported nothing, forever, with no way to tell that apart from a build that
/// was never configured. The on-device crash log is the one diagnostic channel
/// that works without telemetry, which makes it exactly the right place for it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = FirebaseAppConfig(
    projectId: 'p',
    apiKey: 'k',
    appId: '1:1:android:1',
    messagingSenderId: '1',
  );

  late List<String> recorded;
  late CrashSink sink;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    recorded = [];
    sink = (error, stack, source) => recorded.add('$source: $error');
    CrashLog.instance.addSink(sink);
  });

  tearDown(() {
    CrashLog.instance.removeSink(sink);
    debugDefaultTargetPlatformOverride = null;
  });

  test('a failed initialization is recorded in the on-device log', () async {
    final observability = await initializeObservability(
      configOverride: config,
      initializer: (_) async => throw StateError('revoked api key'),
    );

    expect(observability.isEnabled, isFalse,
        reason: 'a failed init must still yield working no-op sinks');
    expect(recorded, ['firebase-init: Bad state: revoked api key']);
  });

  test('an unconfigured build records nothing at all', () async {
    // The overwhelmingly common case — a local build, or a fork. It is not an
    // error and must never look like one in the log.
    final observability = await initializeObservability();

    expect(observability.isEnabled, isFalse);
    expect(recorded, isEmpty);
  });
}
