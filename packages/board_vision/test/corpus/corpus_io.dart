/// Reading and writing a corpus on disk: images in and out of [Frame], and
/// sidecars in and out of a directory.
///
/// Shared by the two generators, the prep tool and the harness, so that a
/// synthetic shot and a photograph reach the pipeline through exactly the same
/// decode. That is not a convenience — it is what makes the two corpora
/// comparable. A harness that decoded its own PNGs one way and the user's JPEGs
/// another would be scoring two different things and reporting one number.
///
/// **Test-and-tool only.** `package:image` never appears under `lib/`; on a
/// phone the frames arrive as raw planes from the camera and every byte of
/// decode is battery. See the pubspec's note.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:board_vision/board_vision.dart';
import 'package:image/image.dart' as img;

import 'capture_plan.dart';

/// The quality the corpus is committed at.
///
/// Measured rather than picked. At 1280x960 a synthetic shot costs about
/// 1.8 MB as a PNG and about 200 KB as a quality-95 JPEG; thirty-three PNGs
/// would be roughly sixty megabytes against a twenty-five megabyte budget, so
/// PNG is not available at this frame size whatever else is true. Quality 95
/// leaves every board calibrating and every roll readable; 92 begins to lose
/// the classic palette at the steepest viewpoint.
const int kCorpusJpegQuality = 95;

/// Chroma subsampling is **off**, and this is the sharpest edge in the whole
/// corpus pipeline.
///
/// Measured: at 4:2:0 — which is what almost every phone camera writes — the
/// classic palette stops calibrating at quality 95 and below, while at 4:4:4 it
/// is fine at 90. The colour model classifies per pixel against a per-region
/// reference, and 4:2:0 throws away three quarters of the colour resolution
/// before the model ever sees it; the board's near-black checkers are the first
/// thing to go.
///
/// The synthetic corpus therefore commits 4:4:4, and the prep tool re-encodes
/// photographs at 4:4:4 as well. What it cannot do is put back what the phone's
/// own encoder discarded at capture time, and that is a real limit on what the
/// real corpus can prove — recorded here because it is the sort of thing that
/// otherwise gets discovered twice.
const img.JpegChroma kCorpusChroma = img.JpegChroma.yuv444;

/// The longest side a committed corpus image may have, per the spec.
const int kMaxCorpusDimension = 1280;

/// A decoded image as the pipeline's own frame type.
Frame frameOfImage(img.Image image) {
  final rgb = Uint8List(image.width * image.height * 3);
  var i = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      rgb[i++] = p.r.toInt();
      rgb[i++] = p.g.toInt();
      rgb[i++] = p.b.toInt();
    }
  }
  return Frame(rgb, image.width, image.height);
}

/// A frame as something `package:image` can encode.
img.Image imageOfFrame(Frame frame) {
  final out = img.Image(width: frame.width, height: frame.height);
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      final p = frame.pixelAt(x, y);
      out.setPixelRgb(x, y, p.$1, p.$2, p.$3);
    }
  }
  return out;
}

/// The corpus's own encoding, in one place so that the synthetic corpus and a
/// prepared photograph are byte-compatible in format.
Uint8List encodeCorpusJpeg(img.Image image, {int quality = kCorpusJpegQuality}) =>
    img.encodeJpg(image, quality: quality, chroma: kCorpusChroma);

/// Decodes any image the corpus might hold — JPEG for both corpora today, PNG
/// tolerated so a hand-dropped file is not a mystery failure.
Frame decodeCorpusImage(File file) {
  final decoded = img.decodeImage(file.readAsBytesSync());
  if (decoded == null) {
    throw FormatException('cannot decode ${file.path} as an image');
  }
  return frameOfImage(decoded);
}

/// The same, from bytes already in hand.
img.Image decodeCorpusImageBytes(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('undecodable image bytes');
  return decoded;
}

/// Every sidecar in [directory], by shot id, in id order.
///
/// Missing directory means an empty corpus, which is a legitimate state — the
/// real corpus does not exist until someone has taken photographs — and the
/// harness says so out loud rather than passing quietly.
List<CorpusShot> loadSidecars(Directory directory) {
  if (!directory.existsSync()) return const <CorpusShot>[];
  final files = directory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.expected.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return <CorpusShot>[
    for (final file in files)
      CorpusShot.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      ),
  ];
}

/// Writes a sidecar beside its image, formatted so a person can read it.
void writeSidecar(Directory directory, CorpusShot shot) {
  const encoder = JsonEncoder.withIndent('  ');
  File('${directory.path}/${shot.sidecarName}')
      .writeAsStringSync('${encoder.convert(shot.toJson())}\n');
}

/// The image belonging to [shot] in [directory], whatever it was encoded as,
/// or null when the photograph has not been taken yet.
File? imageFileFor(Directory directory, CorpusShot shot) {
  for (final extension in const <String>['jpg', 'jpeg', 'png']) {
    final file = File('${directory.path}/${shot.id}.$extension');
    if (file.existsSync()) return file;
  }
  return null;
}

/// The total size of everything in [directory], in bytes.
int directoryBytes(Directory directory) {
  if (!directory.existsSync()) return 0;
  var total = 0;
  for (final entry in directory.listSync(recursive: true)) {
    if (entry is File) total += entry.lengthSync();
  }
  return total;
}

/// Bytes as megabytes, to one decimal, for the reports both tools print.
String megabytes(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
