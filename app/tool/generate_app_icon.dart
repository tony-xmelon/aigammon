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

    // Full bleed, square: the base image must have NO transparency — iOS
    // forbids an alpha channel and a rounded source would leave pale corners
    // once flattened. iOS and Windows round/mask it themselves.
    await _write(
      p.join(dir.path, 'app_icon.png'),
      const AppMarkPainter(cornerRadiusFraction: 0, contentScale: 0.76),
    );

    // Android adaptive foreground: transparent plate, motif sized so its ink
    // stays inside the 66/108 circular safe zone whatever mask a launcher
    // applies. The mark's ink is near-square, so the limit is its DIAGONAL —
    // and flutter_launcher_icons wraps this drawable in a further 16% inset
    // (see mipmap-anydpi-v26/ic_launcher.xml), which the size below accounts
    // for: 0.64 * 0.70 (half-diagonal) * 0.68 (inset) lands on the safe circle.
    await _write(
      p.join(dir.path, 'app_icon_adaptive.png'),
      const AppMarkPainter(background: false, contentScale: 0.64),
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
