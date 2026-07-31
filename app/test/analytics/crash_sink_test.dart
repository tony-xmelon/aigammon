import 'package:aigammon_app/diagnostics/crash_log.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_observability.dart';

/// The seam Crashlytics hangs off: [CrashLog.addSink].
///
/// The property that matters is that the REMOTE sink is additive. The
/// on-device log is what a tester can copy out with no network and no Firebase
/// config, so it must keep every entry it would have kept, whatever the sink
/// does — including throwing.
void main() {
  late CrashLog log;
  late RecordingCrashReporter reporter;

  /// Exactly the wiring `main()` installs.
  CrashSink crashlyticsSink(RecordingCrashReporter r) =>
      (error, stack, source) => r.recordError(error, stack, reason: source);

  setUp(() {
    log = CrashLog();
    reporter = RecordingCrashReporter();
  });

  test('a registered sink sees every recorded error, with its source', () {
    log.addSink(crashlyticsSink(reporter));

    log.record(StateError('widget blew up'),
        stack: StackTrace.current, source: 'flutter');
    log.record('async boom', source: 'platform');
    log.record(ArgumentError('bad net'), source: 'engine-isolate');

    expect(reporter.reports.length, 3);
    expect([for (final r in reporter.reports) r.$3],
        ['flutter', 'platform', 'engine-isolate']);
    // Crucially including the engine isolate, which reaches NEITHER
    // FlutterError.onError nor PlatformDispatcher.onError — routing the sink
    // through record() is what picks it up.
    expect(reporter.reports.last.$1, isA<ArgumentError>());
  });

  test('the on-device log still holds everything the sink saw', () {
    log.addSink(crashlyticsSink(reporter));
    log.record(StateError('boom'), source: 'flutter');

    expect(log.entries.single.error, contains('boom'));
    expect(log.entries.single.source, 'flutter');
    expect(reporter.errors.single, isA<StateError>());
  });

  test('a sink that throws does not cost the on-device entry', () {
    log.addSink((_, _, _) => throw StateError('the reporter is broken'));
    log.addSink(crashlyticsSink(reporter));

    expect(() => log.record(StateError('boom')), returnsNormally);

    expect(log.entries, hasLength(1));
    // And the sink AFTER the broken one still ran: one bad reporter must not
    // silence the rest.
    expect(reporter.reports, hasLength(1));
  });

  test('errors recorded before a sink is added are not replayed to it', () {
    // The real ordering: handlers install synchronously at the top of main(),
    // Firebase resolves several hundred milliseconds later. Anything in that
    // gap is already safe in the on-device log, and replaying it would report
    // stale errors against a fresh session.
    log.record(StateError('early'), source: 'flutter');
    log.addSink(crashlyticsSink(reporter));
    log.record(StateError('late'), source: 'flutter');

    expect(log.entries, hasLength(2));
    expect(reporter.reports, hasLength(1));
    expect('${reporter.errors.single}', contains('late'));
  });

  test('a removed sink stops receiving', () {
    final sink = crashlyticsSink(reporter);
    log
      ..addSink(sink)
      ..record(StateError('one'))
      ..removeSink(sink)
      ..record(StateError('two'));

    expect(log.entries, hasLength(2));
    expect(reporter.reports, hasLength(1));
  });

  test('no sink at all is the normal desktop case and records fine', () {
    log.record(StateError('boom'), source: 'flutter');
    expect(log.entries, hasLength(1));
  });
}
