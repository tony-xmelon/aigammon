// Rasterises the AIGammon brand mark ([AppMarkPainter]) to the launcher-icon
// source PNGs that `flutter_launcher_icons` consumes.
//
// It lives under `tool/` rather than `test/` deliberately: `flutter test` only
// walks `test/`, so regenerating the artwork is an explicit, hand-run step and
// never a side effect of the suite. Run it from `app/`:
//
//   flutter test tool/generate_app_icon.dart
//   dart run flutter_launcher_icons
//
// Outputs (both 1024x1024, the size every platform downsamples from):
//   assets/icon/app_icon.png          full-bleed felt plate — iOS/Windows/legacy
//   assets/icon/app_icon_adaptive.png transparent, motif inside Android's
//                                     circular safe zone (adaptive foreground)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aigammon_app/branding/app_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Every platform's icon pipeline downsamples from this master size.
const int _size = 1024;

void main() {
  test('writes the launcher icon PNGs', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory(p.join('assets', 'icon'))
      ..createSync(recursive: true);

    // Full bleed, square: the board frame runs to the canvas edge, so the image
    // has NO transparency — iOS forbids an alpha channel, and a rounded source
    // would leave pale corners once flattened. iOS and Windows round it
    // themselves.
    await _write(
      p.join(dir.path, 'app_icon.png'),
      const AppMarkPainter(cornerRadiusFraction: 0),
    );

    // Android adaptive foreground: transparent around a rounded board, sized so
    // the frame's CORNERS stay inside the 66/108 circular safe zone whatever
    // mask a launcher applies, remembering that flutter_launcher_icons wraps
    // this drawable in a further 16%-per-side inset (see
    // mipmap-anydpi-v26/ic_launcher.xml), i.e. scales it to 0.68.
    //
    // The mark is now the whole board, so its ink is the frame's rounded square
    // — the extreme point is a corner arc, at
    //   sqrt(2) * (0.5 - r) + r = 0.649 of the board's side  (r = 0.14),
    // against 0.707 for a sharp square. So the ink half-extent on the launcher's
    // 108dp canvas is
    //   0.60 * 0.649 * 0.68 = 0.265  ->  28.6dp,
    // comfortably inside the 33dp safe radius (the ceiling would be 0.69). Kept
    // at 0.60: the frame is the silhouette, and a mark that grazes the mask edge
    // looks clipped even when it technically is not.
    await _write(
      p.join(dir.path, 'app_icon_adaptive.png'),
      const AppMarkPainter(cornerRadiusFraction: 0.14, contentScale: 0.60),
    );
  });
}

Future<void> _write(String path, CustomPainter painter) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(_size.toDouble(), _size.toDouble());
  painter.paint(canvas, size);
  final image = await recorder.endRecording().toImage(_size, _size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $path (${data.lengthInBytes} bytes)');
}
