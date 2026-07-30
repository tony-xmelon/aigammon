import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One recorded unhandled error.
@immutable
class CrashLogEntry {
  const CrashLogEntry({
    required this.time,
    required this.source,
    required this.error,
    this.stack,
  });

  /// When it happened, in **UTC** — a log that gets copied out of the device
  /// and pasted into a bug report has no timezone context of its own.
  final DateTime time;

  /// Which handler caught it: `flutter` (widget/framework), `platform` (an
  /// unhandled asynchronous error on the platform dispatcher),
  /// `engine-isolate` (the neural-net worker isolate), or a caller-supplied
  /// label for a deliberately reported error.
  final String source;

  /// `error.toString()`. Deliberately not the object: entries outlive the
  /// error and must survive JSON.
  final String error;

  /// The stack trace, possibly truncated (see [CrashLog.maxStackChars]).
  final String? stack;

  Map<String, Object?> toJson() => {
        't': time.toIso8601String(),
        's': source,
        'e': error,
        if (stack != null) 'st': stack,
      };

  static CrashLogEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final t = DateTime.tryParse('${json['t']}');
    final e = json['e'];
    if (t == null || e is! String) return null;
    return CrashLogEntry(
      time: t.toUtc(),
      source: json['s'] is String ? json['s'] as String : 'unknown',
      error: e,
      stack: json['st'] is String ? json['st'] as String : null,
    );
  }
}

/// A rolling, on-device log of the last few unhandled errors.
///
/// **Why this exists.** Until this landed, an unhandled error in a shipped
/// build was invisible: no `FlutterError.onError`, no
/// `PlatformDispatcher.onError`, and errors thrown inside the engine isolate
/// don't reach either of those even when they are installed. A tester could
/// only report "it froze", with nothing to attach.
///
/// **What it is not.** There is no remote reporting. This is an on-device MVP:
/// the user has to reach Settings → Diagnostics and copy the log out. Adding
/// `firebase_crashlytics` would collect crashes automatically, symbolicate
/// them, and — the part that matters most for this app — capture *native*
/// crashes in the Rust engine `.so`, which a Dart-level handler can never see
/// because the process is already gone. That is deliberately deferred (it
/// costs a plugin plus an NDK symbol-upload step in CI); this closes the
/// "shipped build tells you nothing" gap in the meantime.
///
/// **Shape.** Entries live in memory (so the viewer is synchronous and a crash
/// before storage is ready is still captured) and are mirrored to a single
/// newline-delimited-JSON file. Three caps keep it bounded: [maxEntries],
/// [maxBytes] over the whole serialized log, and [maxStackChars] per stack so
/// one pathological trace cannot evict everything else.
///
/// **It must never make things worse.** Every disk operation swallows its own
/// errors: a diagnostics logger that throws while reporting a crash turns one
/// bug into two.
class CrashLog {
  CrashLog({
    this.maxEntries = 25,
    this.maxBytes = 64 * 1024,
    this.maxStackChars = 4000,
  });

  /// The process-wide log the global handlers write to.
  static final CrashLog instance = CrashLog();

  final int maxEntries;
  final int maxBytes;
  final int maxStackChars;

  final List<CrashLogEntry> _entries = [];
  File? _file;
  Future<void> _flushChain = Future.value();

  /// Oldest first.
  List<CrashLogEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  /// Records an error. Synchronous and non-throwing by contract — it is called
  /// from crash handlers, where anything else would be a second bug.
  void record(Object error, {StackTrace? stack, String source = 'unhandled'}) {
    var trace = stack?.toString();
    if (trace != null && trace.length > maxStackChars) {
      trace = '${trace.substring(0, maxStackChars)}\n… (truncated)';
    }
    _entries.add(CrashLogEntry(
      time: DateTime.now().toUtc(),
      source: source,
      error: error.toString(),
      stack: trace,
    ));
    _applyCaps();
    _scheduleFlush();
  }

  /// Points the log at [file], merging whatever it already holds.
  ///
  /// On-disk entries are treated as OLDER than anything already in memory,
  /// which is exactly right for the one case this ordering matters: the app
  /// starts, the handlers are installed synchronously, an early error is
  /// recorded, and only then does `getApplicationSupportDirectory()` resolve.
  Future<void> attachFile(File file) async {
    _file = file;
    final fromDisk = await _readFile(file);
    _entries.insertAll(0, fromDisk);
    _applyCaps();
    await flush();
  }

  /// Writes the current entries out. Failures are swallowed.
  Future<void> flush() {
    final file = _file;
    if (file == null) return Future.value();
    final payload = serialize();
    _flushChain = _flushChain.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(payload, flush: true);
      } catch (_) {
        // Disk full, permissions, the directory vanished mid-test — none of
        // these are worth escalating from a diagnostics writer.
      }
    });
    return _flushChain;
  }

  /// Empties memory and disk.
  Future<void> clear() async {
    _entries.clear();
    await flush();
  }

  /// The exact on-disk representation: one JSON object per line.
  String serialize() =>
      _entries.map((e) => jsonEncode(e.toJson())).join('\n');

  /// A human-readable report, for the clipboard.
  String asText() {
    if (_entries.isEmpty) {
      return 'AIGammon diagnostics\nNo errors recorded.';
    }
    final buffer = StringBuffer()
      ..writeln('AIGammon diagnostics')
      ..writeln('${_entries.length} error(s), oldest first. Times are UTC.')
      ..writeln();
    for (final e in _entries) {
      buffer
        ..writeln('[${e.time.toIso8601String()}] ${e.source}')
        ..writeln(e.error);
      if (e.stack != null) buffer.writeln(e.stack);
      buffer.writeln('---');
    }
    return buffer.toString();
  }

  void _applyCaps() {
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    // Keep at least the newest entry even if it alone exceeds the byte cap:
    // the crash you are holding is the one worth reporting.
    while (_entries.length > 1 &&
        utf8.encode(serialize()).length > maxBytes) {
      _entries.removeAt(0);
    }
  }

  void _scheduleFlush() {
    if (_file == null) return;
    unawaited(flush());
  }

  Future<List<CrashLogEntry>> _readFile(File file) async {
    try {
      if (!await file.exists()) return const [];
      final lines = (await file.readAsString()).split('\n');
      final out = <CrashLogEntry>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final entry = CrashLogEntry.fromJson(jsonDecode(line));
          if (entry != null) out.add(entry);
        } catch (_) {
          // A torn last line (killed mid-write) or hand-edited garbage: skip
          // the line, keep the rest.
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // --- Global wiring --------------------------------------------------------

  static bool _handlersInstalled = false;

  /// Installs [FlutterError.onError] and [PlatformDispatcher.instance.onError]
  /// so unhandled errors reach [instance]. Idempotent.
  ///
  /// Both handlers CHAIN to the previous behaviour rather than replacing it:
  /// the framework's own reporting (and, under `flutter_test`, the binding's
  /// failure plumbing) must keep working. Recording is a side effect, not a
  /// takeover.
  ///
  /// Returns a callback that restores the previous handlers — used by tests.
  static VoidCallback installGlobalHandlers() {
    if (_handlersInstalled) return () {};
    _handlersInstalled = true;
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;

    FlutterError.onError = (details) {
      instance.record(details.exception,
          stack: details.stack, source: 'flutter');
      previousFlutter?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      instance.record(error, stack: stack, source: 'platform');
      // false = "not handled", so the default reporting still runs. We are
      // observing, not suppressing.
      return previousPlatform?.call(error, stack) ?? false;
    };

    return () {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
      _handlersInstalled = false;
    };
  }

  /// Resolves the app-support directory and attaches [instance] to
  /// `errors.log` inside it. Safe to call after the handlers are installed —
  /// anything recorded in between is merged in. Never throws.
  static Future<void> initializeStorage() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await instance.attachFile(File(p.join(dir.path, 'errors.log')));
    } catch (_) {
      // No storage (a platform without path_provider, a sandboxed test): the
      // in-memory log still works for the current session.
    }
  }
}
