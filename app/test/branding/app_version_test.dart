import 'dart:io';

import 'package:aigammon_app/branding/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appVersion matches the pubspec version', () {
    // The home footer renders [appVersion] as a const, so this guard is what
    // keeps it honest: bump pubspec's `version:` and the suite fails until the
    // const follows.
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    // `version: 0.5.0+5` -> `0.5.0` (the build number is not user-facing).
    final pubspecVersion = line.split(':')[1].trim().split('+').first;
    expect(appVersion, pubspecVersion);
  });
}
