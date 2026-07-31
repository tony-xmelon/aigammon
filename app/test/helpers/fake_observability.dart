import 'package:aigammon_app/analytics/app_analytics.dart';

/// One reported analytics event, as the sink saw it.
class RecordedEvent {
  RecordedEvent(this.name, this.parameters);

  final String name;
  final Map<String, Object?> parameters;

  @override
  String toString() => '$name$parameters';
}

/// An [AppAnalytics] that remembers instead of reporting.
///
/// The widget-test counterpart of the Firebase implementation: a test overrides
/// `appAnalyticsProvider` with one of these and asserts on [events] — no
/// `Firebase.initializeApp`, no plugin channel, no network. Screen views land
/// in [events] as well (under [AnalyticsEvents.screenView]) so a test can make
/// one assertion about the whole ORDER of what a flow reported, which is where
/// the interesting bugs are (a duplicate, a missing one, the wrong order).
class RecordingAnalytics implements AppAnalytics {
  final List<RecordedEvent> events = [];

  /// Just the event names, in order — the common assertion.
  List<String> get names => [for (final e in events) e.name];

  /// The parameters of the single event named [name]. Fails loudly on 0 or 2+,
  /// because "which one did you mean" is never a question a test should guess.
  Map<String, Object?> paramsOf(String name) {
    final matches = [for (final e in events) if (e.name == name) e];
    if (matches.length != 1) {
      throw StateError(
          'expected exactly one "$name" event, found ${matches.length} in $names');
    }
    return matches.single.parameters;
  }

  int countOf(String name) => names.where((n) => n == name).length;

  @override
  void logEvent(String name, {Map<String, Object?> parameters = const {}}) {
    events.add(RecordedEvent(name, Map.of(parameters)));
  }

  @override
  void logScreenView(String screenName) {
    events.add(RecordedEvent('screen_view', {'screen_name': screenName}));
  }
}

/// An [AppPerformance] that records trace names and durations.
class RecordingPerformance implements AppPerformance {
  /// Names of traces that have been STARTED, in order.
  final List<String> started = [];

  /// Names of traces that have been STOPPED, in order. A trace that starts and
  /// never stops shows up as the difference between the two lists — which is
  /// exactly the leak worth catching.
  final List<String> stopped = [];

  /// Durations reported through [recordDuration].
  final Map<String, Duration> durations = {};

  @override
  Future<AppTrace> startTrace(String name) async {
    started.add(name);
    return _RecordingTrace(this, name);
  }

  @override
  Future<T> trace<T>(String name, Future<T> Function() body) async {
    final t = await startTrace(name);
    try {
      return await body();
    } finally {
      await t.stop();
    }
  }

  @override
  void recordDuration(String name, Duration duration) {
    durations[name] = duration;
  }
}

class _RecordingTrace implements AppTrace {
  _RecordingTrace(this._owner, this._name);

  final RecordingPerformance _owner;
  final String _name;
  final Map<String, int> metrics = {};
  final Map<String, String> attributes = {};

  @override
  void setMetric(String name, int value) => metrics[name] = value;

  @override
  void putAttribute(String name, String value) => attributes[name] = value;

  @override
  Future<void> stop() async => _owner.stopped.add(_name);
}

/// An [AppCrashReporter] that remembers what it was handed.
class RecordingCrashReporter implements AppCrashReporter {
  final List<(Object, StackTrace?, String?)> reports = [];

  List<Object> get errors => [for (final r in reports) r.$1];

  @override
  void recordError(Object error, StackTrace? stack, {String? reason}) {
    reports.add((error, stack, reason));
  }
}
