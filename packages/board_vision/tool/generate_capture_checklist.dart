/// Writes the capture kit: the checklist a person follows, and one sidecar per
/// shot carrying that shot's ground truth.
///
/// ```
/// dart run tool/generate_capture_checklist.dart [--out corpus] [--seed 4242]
/// ```
///
/// Both outputs come from the same call to `buildCapturePlan`, which is the
/// whole point: the truth in a sidecar is what the checklist *asked for*, so
/// nobody ever labels a photograph by looking at it. Re-running with the same
/// seed rewrites byte-identical files.
///
/// Changing the seed changes every position and every roll and therefore
/// invalidates any photographs already taken against the old kit. The tool says
/// so rather than assuming you meant it.
library;

import 'dart:convert';
import 'dart:io';

import '../test/corpus/capture_plan.dart';
import '../test/corpus/checklist.dart';

Future<void> main(List<String> args) async {
  final outPath = _option(args, '--out') ?? 'corpus';
  final seed = int.parse(_option(args, '--seed') ?? '$kCorpusSeed');

  final sessions = buildCapturePlan(seed: seed);
  final shots = flatten(sessions);

  final out = Directory(outPath);
  if (!out.existsSync()) out.createSync(recursive: true);

  File('${out.path}/CHECKLIST.md')
      .writeAsStringSync(renderChecklist(sessions, seed: seed));

  const encoder = JsonEncoder.withIndent('  ');
  for (final shot in shots) {
    File('${out.path}/${shot.sidecarName}')
        .writeAsStringSync('${encoder.convert(shot.toJson())}\n');
  }

  stdout
    ..writeln('Wrote ${out.path}/CHECKLIST.md and ${shots.length} sidecars.')
    ..writeln();
  for (final session in sessions) {
    stdout.writeln('  ${session.name.padRight(12)} '
        '${session.shots.length} shots  '
        '(${session.shots.first.id}-${session.shots.last.id})  '
        '${session.conditions}');
  }
  stdout
    ..writeln()
    ..writeln('  ${shots.where((s) => s.kind == ShotKind.calibration).length} '
        'calibration, '
        '${shots.where((s) => s.kind == ShotKind.position).length} mid-game, '
        '${shots.where((s) => s.kind == ShotKind.dice).length} dice, '
        '${shots.where((s) => s.kind == ShotKind.degraded).length} '
        'deliberately unreadable');
  if (seed != kCorpusSeed) {
    stdout
      ..writeln()
      ..writeln('  NOTE: seed $seed is not the plan\'s $kCorpusSeed. Every '
          'position and roll differs, so photographs shot against the other '
          'kit no longer match these sidecars.');
  }
}

String? _option(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
