/// Turns a folder of photographs into the committed real corpus.
///
/// ```
/// dart run tool/prepare_corpus.dart --in <folder of photos>
///                                   [--out test/corpus/real]
///                                   [--kit corpus]
///                                   [--corners <file>]
///                                   [--proportions <file>]
/// ```
///
/// For each shot in the capture plan it finds `NNN.<ext>` in `--in`, shrinks it
/// so its long side is at most 1280 px, writes it as `NNN.jpg`, and copies the
/// sidecar beside it. Then it prints the total against the spec's 25 MB budget.
///
/// ## Why it shrinks, and why to that number
///
/// The spec asks for the corpus committed downsampled at ≤1280 px. A phone
/// photograph is four times that on its long side and eight times the bytes,
/// and a corpus nobody can clone is a corpus nobody runs. 1280 is also what a
/// camera preview delivers, so the corpus is scored at roughly the resolution
/// the app will actually see.
///
/// ## The corners, and the one manual step in the pipeline
///
/// Perception is handed the playing field's four corners — in the app the user
/// drags them onto a preview, and there is nothing here that can honestly do
/// that for a photograph. So this tool does not pretend to: it writes
/// `corners: null` and prints what to do.
///
/// Only the shots that carry their own calibration need them — six sessions
/// plus any shot marked unreadable that is its own calibration attempt — so it
/// is four taps per session rather than four per photograph. Read them off the
/// **prepared** JPEG (not the original: this tool has resized it) in any viewer
/// that shows pixel coordinates, put them in `corners.json` clockwise from the
/// top left as the picture shows them, and run the tool again.
///
/// ## The other measurement: what shape the board is
///
/// The ROI atlas used to assume one set of tray, bar and column widths. The
/// first real board is a folding case with **no bear-off wells at all** and a
/// hinge for a bar, which puts its outermost points most of a column away from
/// where those widths look. So a session may carry its own — measured off the
/// prepared calibration frame, in `proportions.json` beside `corners.json`,
/// keyed by session name; see [readProportions]. A session that says nothing
/// is read as a board of the usual shape.
///
/// It goes through this tool rather than into a sidecar by hand because every
/// run rewrites every sidecar from the live plan, and a number typed straight
/// into a sidecar would be wiped the next time somebody re-prepared the corpus.
///
/// ## Encoding
///
/// Quality 95, chroma **4:4:4**, the same as the synthetic corpus — see
/// [kCorpusChroma] for the measurement that makes the second of those matter
/// more than it looks. What this cannot undo is the subsampling a phone's own
/// encoder already applied; that limit belongs in the gate's notes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:board_vision/board_vision.dart';
import 'package:image/image.dart' as img;

import '../test/corpus/capture_plan.dart';
import '../test/corpus/corpus_io.dart';

Future<void> main(List<String> args) async {
  final inPath = _option(args, '--in');
  if (inPath == null) {
    stdout.writeln('usage: dart run tool/prepare_corpus.dart --in <folder> '
        '[--out test/corpus/real] [--kit corpus] [--corners <file>]');
    exitCode = 2;
    return;
  }
  final source = Directory(inPath);
  if (!source.existsSync()) {
    stdout.writeln('no such folder: $inPath');
    exitCode = 2;
    return;
  }

  final out = Directory(_option(args, '--out') ?? 'test/corpus/real');
  final cornersPath = _option(args, '--corners') ?? '${source.path}/corners.json';
  final shapePath =
      _option(args, '--proportions') ?? '${source.path}/proportions.json';
  final measured = readProportions(File(shapePath));
  final report = prepareCorpus(
    source: source,
    destination: out,
    corners: readCorners(File(cornersPath)),
    proportions: measured,
  );

  stdout
    ..writeln(report.summary)
    ..writeln(measured.isEmpty
        ? '  Every session is being read as a board of the usual shape. If '
            'yours is a folding case — no bear-off wells, a hinge for a bar — '
            'measure its widths and put them in $shapePath; see '
            'readProportions.'
        : '  ${measured.length} sessions carry measured board widths: '
            '${measured.entries.map((e) => '${e.key} ${e.value}').join(', ')}')
    ..writeln(kChromaCaveat);
  if (report.needCorners.isNotEmpty) {
    final template = File('${source.path}/corners.template.json');
    template.writeAsStringSync(cornersTemplate(report.needCorners));
    stdout
      ..writeln()
      ..writeln('  ${report.needCorners.length} shots still need their four '
          'corners. A template listing them is at ${template.path}: fill it '
          'in from the PREPARED jpegs in ${out.path}, save it as '
          '$cornersPath, and run this again.')
      ..writeln('  Until then the harness skips those sessions and says so.');
  }
}

/// The one caveat this tool cannot fix, printed every run.
///
/// It lives in the output rather than only in a doc comment on purpose. The
/// person who needs it is looking at a corpus that will not calibrate, at the
/// Task 6 gate, deciding whether a classical-CV backbone is viable — and the
/// failure it predicts looks exactly like the algorithm not working. A comment
/// three files away does not reach that conversation.
const String kChromaCaveat = '''
  NOTE — colour, and what a phone threw away before you ran this.
  Phone cameras write JPEG at 4:2:0: colour is stored at a quarter of the
  detail of brightness. Classification here is per pixel and per colour, so
  that loss lands on exactly what perception is doing. Measured on the
  synthetic boards: a brown board with cream points and near-black checkers
  stops calibrating at 4:2:0 quality 95, and is fine at the same quality
  without the subsampling. Dark checkers on a warm board are the case at risk.
  This tool re-encodes at 4:4:4 and cannot put back what was already gone.
  A session that will not calibrate may be this rather than the pipeline.''';

/// What a run of the tool did.
class PrepareReport {
  final List<String> written;
  final List<String> missing;
  final List<String> needCorners;
  final int bytes;

  const PrepareReport({
    required this.written,
    required this.missing,
    required this.needCorners,
    required this.bytes,
  });

  bool get overBudget => bytes > kCorpusByteBudget;

  String get summary {
    final out = StringBuffer()
      ..writeln('Prepared ${written.length} shots, '
          '${megabytes(bytes)} of ${megabytes(kCorpusByteBudget)} '
          '(${(100 * bytes / kCorpusByteBudget).round()}% of the budget).');
    if (missing.isNotEmpty) {
      out.writeln('  ${missing.length} shots have no photograph yet: '
          '${missing.join(", ")}');
    }
    if (overBudget) {
      out.writeln('  WARNING: over the spec\'s corpus budget. Drop the '
          'weakest shots rather than the resolution — a corpus of blurry '
          'thumbnails scores nothing.');
    }
    return out.toString();
  }
}

/// Downsamples every photograph in [source] that the capture plan names, and
/// writes it with its sidecar into [destination].
///
/// Split out of `main` so the tests can drive it: everything above is argument
/// parsing and everything below is the work.
PrepareReport prepareCorpus({
  required Directory source,
  required Directory destination,
  Map<String, BoardQuad> corners = const <String, BoardQuad>{},
  Map<String, BoardProportions> proportions =
      const <String, BoardProportions>{},
  int maxDimension = kMaxCorpusDimension,
  int quality = kCorpusJpegQuality,
}) {
  if (!destination.existsSync()) destination.createSync(recursive: true);

  final written = <String>[];
  final missing = <String>[];
  final needCorners = <String>[];

  for (final shot in flatten(buildCapturePlan())) {
    final photo = _photographOf(source, shot.id);
    if (photo == null) {
      missing.add(shot.id);
      continue;
    }
    final decoded = img.decodeImage(photo.readAsBytesSync());
    if (decoded == null) {
      throw FormatException('cannot decode ${photo.path}');
    }

    final longest =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    final scale = longest <= maxDimension ? 1.0 : maxDimension / longest;
    final resized = scale == 1.0
        ? decoded
        : img.copyResize(
            decoded,
            width: (decoded.width * scale).round(),
            height: (decoded.height * scale).round(),
            interpolation: img.Interpolation.average,
          );

    File('${destination.path}/${shot.id}.jpg')
        .writeAsBytesSync(encodeCorpusJpeg(resized, quality: quality));

    // Corners are given in the PREPARED image's pixels, so a re-run at a
    // different size would invalidate them. Saying so here is cheaper than
    // debugging a corpus whose homographies are all slightly wrong.
    final tapped = corners[shot.id];
    if (shot.needsCorners && tapped == null) needCorners.add(shot.id);

    // Measured per session, because a session is one board — and written by
    // this tool rather than into a sidecar by hand, since every run rewrites
    // every sidecar from the live plan and would wipe anything typed in.
    writeSidecar(
      destination,
      shot.copyWith(
        corners: tapped,
        proportions: proportions[shot.session],
      ),
    );
    written.add(shot.id);
  }

  return PrepareReport(
    written: written,
    missing: missing,
    needCorners: needCorners,
    bytes: directoryBytes(destination),
  );
}

/// Hand-tapped corners, keyed by shot id.
///
/// Four `[x, y]` pairs, clockwise from the top left as the prepared photograph
/// shows them — the order [BoardQuad] promises. An entry that is null or
/// missing means "not done yet", which the harness reports rather than guesses
/// around.
Map<String, BoardQuad> readCorners(File file) {
  if (!file.existsSync()) return const <String, BoardQuad>{};
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, BoardQuad>{};
  for (final entry in json.entries) {
    final value = entry.value;
    if (value == null) continue;
    final points = value as List<dynamic>;
    if (points.length != 4) {
      throw FormatException('shot ${entry.key} needs four corners, '
          'got ${points.length}');
    }
    out[entry.key] = BoardQuad.fromCorners(<Pt>[
      for (final p in points)
        Pt(
          ((p as List<dynamic>)[0] as num).toDouble(),
          (p[1] as num).toDouble(),
        ),
    ]);
  }
  return out;
}

/// How wide each session's board is, keyed by **session name**.
///
/// The second thing a person measures off a calibration frame, and the only
/// other input the pipeline cannot work out for itself. An entry is
/// `{"trayWidth": 0.0, "barWidth": 0.03}` as a fraction of the playing field's
/// width — read off the PREPARED jpeg the same way the corners are — and an
/// entry that is null or missing means "a board of the usual shape", which is
/// what the harness then reads that session as.
///
/// Keyed by session rather than by shot because a session is one board: the
/// widths do not change between two photographs taken seconds apart, and
/// asking for them thirty-three times would invite thirty-three answers.
Map<String, BoardProportions> readProportions(File file) {
  if (!file.existsSync()) return const <String, BoardProportions>{};
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, BoardProportions>{};
  for (final entry in json.entries) {
    final value = entry.value;
    if (value == null) continue;
    out[entry.key] =
        BoardProportions.fromJson(value as Map<String, dynamic>);
  }
  return out;
}

/// A `corners.json` with every shot that needs one and nothing filled in.
String cornersTemplate(List<String> ids) {
  final out = StringBuffer()..writeln('{');
  for (final (index, id) in ids.indexed) {
    out.writeln('  "$id": null${index == ids.length - 1 ? '' : ','}');
  }
  out.writeln('}');
  return out.toString();
}

File? _photographOf(Directory source, String id) {
  for (final extension in const <String>[
    'jpg',
    'jpeg',
    'JPG',
    'JPEG',
    'png',
    'PNG',
  ]) {
    final file = File('${source.path}/$id.$extension');
    if (file.existsSync()) return file;
  }
  return null;
}

String? _option(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
