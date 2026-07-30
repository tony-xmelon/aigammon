import 'dart:io';

import 'package:aigammon_app/diagnostics/crash_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('aigammon_crashlog_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File logFile() => File('${dir.path}${Platform.pathSeparator}errors.log');

  group('in-memory recording', () {
    test('records error, stack and source', () {
      final log = CrashLog();
      log.record(StateError('boom'),
          stack: StackTrace.fromString('#0 someFrame'), source: 'flutter');

      expect(log.entries, hasLength(1));
      final e = log.entries.single;
      expect(e.error, contains('boom'));
      expect(e.stack, contains('someFrame'));
      expect(e.source, 'flutter');
      expect(e.time.isUtc, isTrue, reason: 'timestamps are stored in UTC so a '
          'log shared across timezones is unambiguous');
    });

    test('keeps only the newest maxEntries, oldest first', () {
      final log = CrashLog(maxEntries: 3);
      for (var i = 0; i < 6; i++) {
        log.record('err$i');
      }
      expect(log.entries.map((e) => e.error), ['err3', 'err4', 'err5']);
    });

    test('truncates a pathological stack instead of letting it evict the log',
        () {
      final log = CrashLog(maxEntries: 5, maxStackChars: 100);
      log.record('boom', stack: StackTrace.fromString('x' * 5000));
      expect(log.entries.single.stack!.length, lessThan(200));
      expect(log.entries.single.stack, contains('truncated'));
    });

    test('drops the oldest entries until the log fits maxBytes', () {
      final log = CrashLog(maxEntries: 100, maxBytes: 400);
      for (var i = 0; i < 40; i++) {
        log.record('error number $i with some padding text');
      }
      expect(log.entries.length, lessThan(40));
      expect(log.entries, isNotEmpty, reason: 'the newest error always stays');
      expect(log.entries.last.error, contains('number 39'));
      expect(log.serialize().length, lessThanOrEqualTo(400));
    });
  });

  group('persistence', () {
    test('round-trips through a file', () async {
      final a = CrashLog();
      await a.attachFile(logFile());
      a.record('first', source: 'flutter');
      a.record('second', stack: StackTrace.fromString('#0 frame'));
      await a.flush();

      expect(logFile().existsSync(), isTrue);

      final b = CrashLog();
      await b.attachFile(logFile());
      expect(b.entries.map((e) => e.error), ['first', 'second']);
      expect(b.entries.first.source, 'flutter');
      expect(b.entries.last.stack, contains('frame'));
    });

    test('errors recorded BEFORE the file is attached still persist', () async {
      // main() installs the handlers synchronously and resolves the app-support
      // directory asynchronously; a crash in that window must not be lost.
      final a = CrashLog();
      a.record('early');
      await a.attachFile(logFile());

      final b = CrashLog();
      await b.attachFile(logFile());
      expect(b.entries.map((e) => e.error), contains('early'));
    });

    test('attaching merges the newest entries and re-applies the cap',
        () async {
      final a = CrashLog(maxEntries: 3);
      await a.attachFile(logFile());
      for (var i = 0; i < 3; i++) {
        a.record('old$i');
      }
      await a.flush();

      final b = CrashLog(maxEntries: 3);
      b.record('new0');
      b.record('new1');
      await b.attachFile(logFile());

      // Disk entries are older than the in-memory ones, so the cap keeps the
      // newest three overall.
      expect(b.entries.map((e) => e.error), ['old2', 'new0', 'new1']);
    });

    test('a corrupt file degrades to an empty log rather than throwing',
        () async {
      logFile().writeAsStringSync('not json\n{"broken":\n');
      final log = CrashLog();
      await log.attachFile(logFile());
      expect(log.entries, isEmpty);

      // …and is still writable afterwards.
      log.record('after corruption');
      await log.flush();
      final reread = CrashLog();
      await reread.attachFile(logFile());
      expect(reread.entries.single.error, 'after corruption');
    });

    test('clear() empties memory and disk', () async {
      final log = CrashLog();
      await log.attachFile(logFile());
      log.record('boom');
      await log.flush();
      await log.clear();

      expect(log.entries, isEmpty);
      final reread = CrashLog();
      await reread.attachFile(logFile());
      expect(reread.entries, isEmpty);
    });

    test('the file never exceeds maxBytes across many sessions', () async {
      for (var session = 0; session < 5; session++) {
        final log = CrashLog(maxEntries: 50, maxBytes: 600);
        await log.attachFile(logFile());
        for (var i = 0; i < 20; i++) {
          log.record('session $session error $i padded out a bit');
        }
        await log.flush();
      }
      expect(logFile().lengthSync(), lessThanOrEqualTo(600));
    });
  });

  group('sharing', () {
    test('asText renders a human-readable report', () {
      final log = CrashLog();
      log.record(StateError('kaboom'),
          stack: StackTrace.fromString('#0 frameOne'), source: 'engine-isolate');
      final text = log.asText();
      expect(text, contains('AIGammon'));
      expect(text, contains('kaboom'));
      expect(text, contains('engine-isolate'));
      expect(text, contains('frameOne'));
    });

    test('asText says so when there is nothing to report', () {
      expect(CrashLog().asText(), contains('No errors'));
    });
  });
}
