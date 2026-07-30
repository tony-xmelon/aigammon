import 'dart:ui' show PlatformDispatcher;

import 'package:aigammon_app/diagnostics/crash_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A widget whose build deliberately throws — the controlled stand-in for the
/// class of failure that used to vanish silently in a release build.
class _Exploding extends StatelessWidget {
  const _Exploding();

  @override
  Widget build(BuildContext context) => throw StateError('deliberate boom');
}

void main() {
  setUp(() => CrashLog.instance.clear());

  testWidgets('a throw during build reaches the crash log', (tester) async {
    final restore = CrashLog.installGlobalHandlers();
    addTearDown(restore);

    await tester.pumpWidget(const _Exploding());

    // The framework still sees the error (the handler chains, it does not
    // swallow) — this is what keeps test failures reportable.
    expect(tester.takeException(), isA<StateError>());

    expect(CrashLog.instance.entries, isNotEmpty);
    final entry = CrashLog.instance.entries.last;
    expect(entry.error, contains('deliberate boom'));
    expect(entry.source, 'flutter');
    expect(entry.stack, isNotNull);
  });

  testWidgets('the platform-dispatcher handler records async errors',
      (tester) async {
    final restore = CrashLog.installGlobalHandlers();
    addTearDown(restore);

    final handler = PlatformDispatcher.instance.onError;
    expect(handler, isNotNull,
        reason: 'installGlobalHandlers must claim the platform dispatcher — '
            'unhandled asynchronous errors reach nothing else');

    final handled =
        handler!(ArgumentError('async boom'), StackTrace.fromString('#0 f'));
    expect(handled, isFalse,
        reason: 'we observe, we do not suppress: returning false keeps the '
            'default reporting');

    final entry = CrashLog.instance.entries.last;
    expect(entry.error, contains('async boom'));
    expect(entry.source, 'platform');
  });

  testWidgets('installing twice does not stack handlers', (tester) async {
    final restore = CrashLog.installGlobalHandlers();
    addTearDown(restore);
    CrashLog.installGlobalHandlers();

    PlatformDispatcher.instance.onError!(
        StateError('once'), StackTrace.fromString('#0 f'));
    expect(CrashLog.instance.entries.where((e) => e.error.contains('once')),
        hasLength(1));
  });

  testWidgets('restoring puts the previous handlers back', (tester) async {
    final beforeFlutter = FlutterError.onError;
    final beforePlatform = PlatformDispatcher.instance.onError;
    CrashLog.installGlobalHandlers()();
    expect(FlutterError.onError, same(beforeFlutter));
    expect(PlatformDispatcher.instance.onError, same(beforePlatform));
  });
}
