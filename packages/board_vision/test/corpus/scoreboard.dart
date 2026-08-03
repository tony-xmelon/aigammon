/// Counting what the corpus said, and deciding whether it was good enough.
///
/// Kept apart from the harness that produces the numbers so that the arithmetic
/// can be tested on numbers nobody photographed: `corpus_harness_test.dart`
/// feeds it a fixture with a failure planted on purpose and checks that the
/// right target goes red. A harness that has never been seen to fail is a
/// harness nobody should trust.
///
/// ## Adding a metric
///
/// Tasks 7 and 8 bring two more questions — which legal play happened, and is
/// the board what the game expects. Adding one is: a value in [CorpusMetric], a
/// row in [kMetricTargets] (null while it has no target yet), and a call to
/// [Scoreboard.record] in the harness. Nothing else moves, and a metric with no
/// target still prints, which is how a number gets watched before it is
/// promised.
library;

import 'package:board_vision/board_vision.dart';

/// One question the corpus asks of every shot it applies to.
enum CorpusMetric {
  /// Guided calibration produced a usable [BoardCalibration]. One attempt per
  /// session, since a session calibrates once and reads everything else
  /// through it — exactly as a Buddy session does.
  calibration('calibration'),

  /// The starting position was confirmed on the frame it was learned from.
  /// No target of its own: the spec folds it into calibration completing, and
  /// `Calibrator` already refuses a calibration that cannot read itself back.
  /// Scored anyway, because it is free and it is the first thing to move if
  /// the confirmation path regresses.
  startConfirmed('start position confirmed'),

  /// The settled pair was read, and read right. The spec's highest target.
  dicePair('dice pair read'),

  /// A board with no dice on it read as no dice. Not from the spec's table —
  /// it is the same counterweight [CorpusMetric.expectedRefusal] is, one step
  /// smaller: an invented roll enters the authoritative game state exactly as
  /// a misread one does.
  diceAbsence('no dice read as no dice'),

  /// A shot the corpus labels unreadable was refused. Never scored as an
  /// answer; see `PerceptionTargets.expectedRefusal`.
  expectedRefusal('unreadable shot refused'),

  /// One region's colour and count, against the position the sidecar says is
  /// on the board. Informational: mid-game counts are never trusted in
  /// isolation by design — they feed Task 7's diff-matching against an
  /// enumerated set of legal plays, and it is that top-1 rate the spec sets a
  /// target for.
  regionOccupancy('region colour and count'),

  /// The same, colour only. Separated because the two fail for different
  /// reasons and a single number hides which: a wrong colour is a broken
  /// colour model, a wrong count on the right colour is a stack measured
  /// short.
  regionColour('region colour alone');

  const CorpusMetric(this.label);

  /// What the scoreboard calls it.
  final String label;
}

/// The threshold each metric is held to, or null while it is only watched.
///
/// Every number here is a reference into `PerceptionTargets`, never a literal:
/// the spec's table is the contract and this file is not allowed a private
/// opinion about it.
const Map<CorpusMetric, double?> kMetricTargets = <CorpusMetric, double?>{
  CorpusMetric.calibration: PerceptionTargets.calibrationSuccess,
  CorpusMetric.dicePair: PerceptionTargets.dicePairRead,
  CorpusMetric.diceAbsence: PerceptionTargets.expectedRefusal,
  CorpusMetric.expectedRefusal: PerceptionTargets.expectedRefusal,
  CorpusMetric.startConfirmed: null,
  CorpusMetric.regionOccupancy: null,
  CorpusMetric.regionColour: null,
};

/// How many attempts, and how many of them went right.
class Tally {
  int attempts = 0;
  int successes = 0;

  void add({required bool ok}) {
    attempts++;
    if (ok) successes++;
  }

  /// The rate, or null when nothing was attempted — which is a different thing
  /// from zero and must never be rounded into one.
  double? get rate => attempts == 0 ? null : successes / attempts;

  @override
  String toString() => '$successes/$attempts';
}

/// A running summary of a number the harness watches but does not judge.
class Stats {
  int n = 0;
  double sum = 0;
  double worst = 0;
  double? least;

  void add(double value) {
    n++;
    sum += value;
    if (value > worst) worst = value;
    if (least == null || value < least!) least = value;
  }

  double get mean => n == 0 ? 0 : sum / n;

  @override
  String toString() => n == 0
      ? 'none'
      : 'n=$n mean=${mean.toStringAsFixed(3)} '
          'min=${least!.toStringAsFixed(3)} max=${worst.toStringAsFixed(3)}';
}

/// What one shot could not be scored on, and why.
class SkippedShot {
  final String id;
  final String reason;

  const SkippedShot(this.id, this.reason);

  @override
  String toString() => '$id: $reason';
}

/// Everything the harness counted, sliced the ways the spec asks about.
class Scoreboard {
  /// What this scoreboard is of — "synthetic", "real", a fixture's name.
  final String name;

  /// How many individual misses a metric lists before the report gives up and
  /// says how many more there were. Enough to see a pattern, few enough that a
  /// broken run does not bury the totals.
  static const int maxListedMisses = 12;

  final Map<CorpusMetric, Tally> _totals = <CorpusMetric, Tally>{};
  final Map<CorpusMetric, Map<String, Map<String, Tally>>> _slices =
      <CorpusMetric, Map<String, Map<String, Tally>>>{};
  final Map<CorpusMetric, List<String>> _misses =
      <CorpusMetric, List<String>>{};
  final Map<String, Stats> _signals = <String, Stats>{};
  final List<SkippedShot> skipped = <SkippedShot>[];
  final List<String> notes = <String>[];

  int shots = 0;
  int sessions = 0;
  int bytes = 0;

  Scoreboard(this.name);

  /// One attempt at [metric]. [slices] are the dimensions this attempt belongs
  /// to — palette, lighting, board half, seating — each of which gets its own
  /// breakdown in the report.
  ///
  /// [detail] names the attempt in words when it goes wrong: which shot, what
  /// was expected, what came back. A rate on its own is a number to argue
  /// about; a rate with its misses listed is something to go and look at, and
  /// the Task 6 gate is a conversation about exactly those.
  void record(
    CorpusMetric metric, {
    required bool ok,
    Map<String, String> slices = const <String, String>{},
    String? detail,
  }) {
    (_totals[metric] ??= Tally()).add(ok: ok);
    if (!ok && detail != null) {
      (_misses[metric] ??= <String>[]).add(detail);
    }
    final byDimension =
        _slices[metric] ??= <String, Map<String, Tally>>{};
    for (final entry in slices.entries) {
      final buckets = byDimension[entry.key] ??= <String, Tally>{};
      (buckets[entry.value] ??= Tally()).add(ok: ok);
    }
  }

  /// A number worth watching that nothing is promised about.
  void signal(String name, double value) {
    (_signals[name] ??= Stats()).add(value);
  }

  void skip(String id, String reason) => skipped.add(SkippedShot(id, reason));

  Tally totalFor(CorpusMetric metric) => _totals[metric] ?? Tally();

  Map<String, Tally> sliceOf(CorpusMetric metric, String dimension) =>
      _slices[metric]?[dimension] ?? const <String, Tally>{};

  Stats signalOf(String name) => _signals[name] ?? Stats();

  /// What went wrong, in the order it went wrong.
  List<String> missesOf(CorpusMetric metric) =>
      List<String>.unmodifiable(_misses[metric] ?? const <String>[]);

  /// Every target this scoreboard misses, each as a sentence naming the number.
  ///
  /// A metric with no attempts is **not** a violation: an empty corpus has not
  /// failed anything, it has been asked nothing, and turning "no photographs
  /// yet" into a red build would train everyone to ignore the red. The harness
  /// says so separately, out loud.
  List<String> targetViolations() {
    final out = <String>[];
    for (final entry in kMetricTargets.entries) {
      final target = entry.value;
      if (target == null) continue;
      final tally = totalFor(entry.key);
      final rate = tally.rate;
      if (rate == null) continue;
      if (rate + 1e-9 < target) {
        out.add('$name: ${entry.key.label} scored '
            '${rate.toStringAsFixed(3)} ($tally), '
            'target ${target.toStringAsFixed(3)}');
      }
    }
    return out;
  }

  /// The scoreboard as a person reads it. Printed by the harness whether it
  /// passes or fails — a number nobody sees when the build is green is a
  /// number nobody notices moving.
  String report() {
    final out = StringBuffer()
      ..writeln()
      ..writeln('=== $name corpus ${'=' * (58 - name.length)}')
      ..writeln('$shots shots in $sessions sessions'
          '${bytes > 0 ? ', ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB' : ''}')
      ..writeln();

    out.writeln('  ${'metric'.padRight(28)}${'n'.padLeft(5)}'
        '${'ok'.padLeft(6)}${'rate'.padLeft(8)}   target');
    for (final metric in CorpusMetric.values) {
      final tally = totalFor(metric);
      if (tally.attempts == 0) continue;
      final target = kMetricTargets[metric];
      final rate = tally.rate!;
      final verdict = target == null
          ? '(watched)'
          : rate + 1e-9 < target
              ? 'MISS  >= ${target.toStringAsFixed(3)}'
              : 'pass  >= ${target.toStringAsFixed(3)}';
      out.writeln('  ${metric.label.padRight(28)}'
          '${tally.attempts.toString().padLeft(5)}'
          '${tally.successes.toString().padLeft(6)}'
          '${rate.toStringAsFixed(3).padLeft(8)}   $verdict');
    }

    for (final metric in CorpusMetric.values) {
      final misses = _misses[metric];
      if (misses == null || misses.isEmpty) continue;
      out
        ..writeln()
        ..writeln('  ${metric.label} — what missed');
      for (final miss in misses.take(maxListedMisses)) {
        out.writeln('    $miss');
      }
      if (misses.length > maxListedMisses) {
        out.writeln('    (and ${misses.length - maxListedMisses} more)');
      }
    }

    for (final metric in CorpusMetric.values) {
      final dimensions = _slices[metric];
      if (dimensions == null || dimensions.isEmpty) continue;
      if (totalFor(metric).attempts == 0) continue;
      out
        ..writeln()
        ..writeln('  ${metric.label} by slice');
      final names = dimensions.keys.toList()..sort();
      for (final dimension in names) {
        final buckets = dimensions[dimension]!;
        final keys = buckets.keys.toList()..sort();
        out.writeln('    $dimension');
        for (final key in keys) {
          final tally = buckets[key]!;
          out.writeln('      ${key.padRight(24)}'
              '${tally.toString().padLeft(10)}'
              '${tally.rate!.toStringAsFixed(3).padLeft(8)}');
        }
      }
    }

    if (_signals.isNotEmpty) {
      out
        ..writeln()
        ..writeln('  raw signals (nothing is promised about these)');
      final names = _signals.keys.toList()..sort();
      for (final name in names) {
        out.writeln('    ${name.padRight(30)}${_signals[name]}');
      }
    }

    if (skipped.isNotEmpty) {
      out
        ..writeln()
        ..writeln('  not scored (${skipped.length})');
      for (final entry in skipped) {
        out.writeln('    $entry');
      }
    }
    for (final note in notes) {
      out.writeln('  $note');
    }
    out.writeln('=' * 64);
    return out.toString();
  }
}
