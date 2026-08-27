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

  test('the merged camera.any feature is beaten back to OPTIONAL', () {
    // **The one entry in this manifest that has to override a plugin rather
    // than merely add to it.** `camera_android_camerax` — the Android
    // implementation `camera` pulls in for Buddy Mode — contributes
    // `<uses-feature android:name="android.hardware.camera.any" />` with no
    // `required` attribute, and the attribute DEFAULTS TO TRUE. It is a
    // different feature name from `android.hardware.camera`, so the optional
    // declaration pinned above does not cancel it, and the merged release
    // manifest would make a camera a hard install requirement for an app whose
    // camera is optional in both modes that use one. That is a regression
    // against master, whose only camera plugin declares its own feature
    // optional.
    //
    // **`tools:replace` is pinned here because it is the mechanism.** The
    // merger combines two same-named `uses-feature` nodes by OR-ing their
    // `required` flags, so a plain `android:required="false"` loses to the
    // plugin's implicit true — silently, with nothing logged. Only
    // `tools:replace="android:required"` makes this node's value win. A future
    // tidy-up that drops the attribute as noise would restore the bug and
    // nothing else in this repository would notice, which is exactly what this
    // assertion is for.
    //
    // **What this test canNOT do is verify the merge.** It reads the SOURCE
    // manifest; the merger runs in Gradle, which needs an Android toolchain
    // this environment does not have. The true verification is `aapt dump
    // badging` on the APK `android.yml` builds — expect
    // `uses-feature-not-required:'android.hardware.camera.any'` and no bare
    // `uses-feature:'android.hardware.camera.any'` — or the Play Console's
    // device catalogue on the uploaded artifact. It is item 4 of
    // `docs/buddy-mode-test-protocol.md`.
    final main = File(mainManifest).readAsStringSync();
    expect(
      main,
      contains('xmlns:tools="http://schemas.android.com/tools"'),
      reason: 'tools:replace below is inert without the namespace, and an '
          'undeclared prefix fails the Gradle merge outright',
    );
    // The entry spans three lines and this file is CRLF on disk, so the match
    // is made on whitespace-collapsed text: what is being pinned is the three
    // attributes and their values, not the indentation somebody may reflow.
    final flat = main.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      flat,
      contains('<uses-feature android:name="android.hardware.camera.any" '
          'android:required="false" tools:replace="android:required"/>'),
      reason: 'camera_android_camerax merges in android.hardware.camera.any '
          'with required defaulting to TRUE; without this override — and '
          'without tools:replace, which is what beats the OR-merge — '
          'camera-less devices lose install eligibility',
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
