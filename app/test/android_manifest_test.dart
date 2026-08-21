import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the shipping Android manifest.
///
/// These are pure file assertions — nothing here builds an APK — but they cover
/// a class of bug that no widget or unit test can reach: a permission that is
/// present in `src/debug` (so every development build works) and absent from
/// `src/main` (so the RELEASE build silently loses it). Both remote modes —
/// Play Online over Firestore and Play Nearby over LAN sockets — are dead
/// without INTERNET, and the failure only ever appears on a shipped build.
///
/// CAMERA is here for the same reason and by the same lesson: Play Nearby's QR
/// join asks for it at runtime, and a runtime request for a permission the
/// manifest never declared is refused without ever showing the user a prompt.
/// RECORD_AUDIO joins them for Buddy Mode's dice-roll listener.
void main() {
  const mainManifest = 'android/app/src/main/AndroidManifest.xml';
  const internet =
      '<uses-permission android:name="android.permission.INTERNET"/>';
  const camera = '<uses-permission android:name="android.permission.CAMERA"/>';
  const recordAudio =
      '<uses-permission android:name="android.permission.RECORD_AUDIO"/>';

  test('the MAIN manifest declares INTERNET (not just debug/profile)', () {
    final main = File(mainManifest).readAsStringSync();
    expect(main, contains(internet),
        reason: 'src/debug and src/profile are merged into debug/profile '
            'builds only — a release APK takes its permissions from src/main, '
            'and no plugin in this app contributes INTERNET by merging');
  });

  test('the MAIN manifest declares CAMERA (not just debug/profile)', () {
    final main = File(mainManifest).readAsStringSync();
    expect(main, contains(camera),
        reason: 'the QR scanner on the Join tab requests CAMERA at runtime; '
            'without the declaration in src/main the release build is denied '
            'the permission outright, with no prompt to the user');
  });

  test('the MAIN manifest declares RECORD_AUDIO (not just debug/profile)', () {
    final main = File(mainManifest).readAsStringSync();
    expect(main, contains(recordAudio),
        reason: "Buddy Mode's dice-roll listener requests RECORD_AUDIO at "
            'runtime; without the declaration in src/main the release build is '
            'denied the permission outright, with no prompt to the user');
  });

  test('the microphone is declared OPTIONAL hardware', () {
    // Exactly the CAMERA lesson again: RECORD_AUDIO makes
    // android.hardware.microphone an implicit Play Store filter unless the
    // feature is explicitly optional. The dice listener is an attention hint
    // that Buddy Mode works identically without, so a device with no usable
    // microphone must still be able to install.
    final main = File(mainManifest).readAsStringSync();
    expect(
      main,
      contains('<uses-feature android:name="android.hardware.microphone" '
          'android:required="false"/>'),
      reason: 'RECORD_AUDIO without an optional uses-feature hides the app '
          'from devices with no microphone',
    );
  });

  test('the camera is declared OPTIONAL hardware', () {
    // Declaring CAMERA makes the hardware an implicit Play Store filter unless
    // the feature is explicitly optional. Scanning is one of three ways into a
    // LAN game, so a camera-less device must still be able to install.
    final main = File(mainManifest).readAsStringSync();
    expect(
      main,
      contains('<uses-feature android:name="android.hardware.camera" '
          'android:required="false"/>'),
      reason: 'CAMERA without an optional uses-feature hides the app from '
          'devices with no camera',
    );
  });

  test('every build variant that exists still declares INTERNET', () {
    // The debug/profile copies are Flutter tooling defaults; keeping them is
    // harmless, but the point of the test above is that they are not LOAD
    // BEARING. Assert they are consistent rather than deleting them.
    for (final variant in const ['debug', 'profile']) {
      final file = File('android/app/src/$variant/AndroidManifest.xml');
      if (!file.existsSync()) continue;
      expect(file.readAsStringSync(), contains(internet),
          reason: '$variant manifest should keep the permission too');
    }
  });
}
