import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Android Firebase **Gradle-plugin** wiring.
///
/// Sibling of `android_signing_test.dart`, same family and same bug class:
/// pure file assertions over build configuration that no widget or unit test
/// can reach and whose failure only ever shows up on a shipped build. Here the
/// failure is silent by construction — drop the plugins and the app still
/// builds, still runs, still reports Dart errors, and simply stops reporting
/// the crashes that kill the process. Nothing goes red; the console just goes
/// quiet, which is indistinguishable from "no crashes".
///
/// The scheme pinned down here: `android/app/google-services.json` is
/// git-ignored and generated (CI writes it from the same repo variables and
/// secret the telemetry dart-defines use; a developer downloads the real one
/// from the Firebase console), and its PRESENCE gates all three Firebase Gradle
/// plugins. Absent -> plugins are skipped and the build stays green with
/// Dart-only reporting. See `firebase/DEPLOY.md`.
void main() {
  const appGradlePath = 'android/app/build.gradle.kts';
  const settingsGradlePath = 'android/settings.gradle.kts';
  const gitignorePath = 'android/.gitignore';
  const workflowPath = '../.github/workflows/android.yml';
  const deployDocPath = '../firebase/DEPLOY.md';

  String read(String path) => File(path).readAsStringSync();

  test('the generated config file is git-ignored', () {
    // Not a secret — every value in it already ships inside the APK — but a
    // committed copy would make every fork report its crashes into this
    // project. Same reasoning, and the same tier, as key.properties.
    expect(read(gitignorePath), contains('app/google-services.json'),
        reason: 'a committed google-services.json points forks at our project');
  });

  test('the real config file is not in the working tree', () {
    expect(File('android/app/google-services.json').existsSync(), isFalse,
        reason: 'this file is generated, never committed — if it is here, '
            'check it did not sneak past .gitignore');
  });

  test('all three Firebase Gradle plugins are on the build classpath', () {
    final settings = read(settingsGradlePath);
    for (final id in const [
      'com.google.gms.google-services',
      'com.google.firebase.crashlytics',
      'com.google.firebase.firebase-perf',
    ]) {
      expect(settings, contains('id("$id")'),
          reason: 'the app script applies $id by id, which only resolves if '
              'settings.gradle.kts put it on the classpath');
    }
    // `apply false` throughout: whether they are APPLIED depends on a file the
    // restricted `plugins {}` block cannot inspect.
    expect(RegExp(r'com\.google\.[^\n]*apply false').allMatches(settings),
        hasLength(3));
  });

  test('the plugins are applied only when the config file exists', () {
    final gradle = read(appGradlePath);
    expect(gradle, contains('val hasFirebaseConfig'),
        reason: 'the gate must be an explicit, named presence check');
    for (final id in const [
      'com.google.gms.google-services',
      'com.google.firebase.crashlytics',
      'com.google.firebase.firebase-perf',
    ]) {
      expect(gradle, contains('apply(plugin = "$id")'));
    }
    // The applies must sit INSIDE the gate. An unconditional apply fails the
    // build of any clone that has no google-services.json — which is every
    // fresh clone.
    expect(
      gradle,
      contains(RegExp(
        r'if \(hasFirebaseConfig\) \{\s*'
        r'apply\(plugin = "com\.google\.gms\.google-services"\)\s*'
        r'apply\(plugin = "com\.google\.firebase\.crashlytics"\)\s*'
        r'apply\(plugin = "com\.google\.firebase\.firebase-perf"\)',
      )),
      reason: 'all three applies must be guarded by the presence check',
    );
  });

  test('native crash capture is actually wired, not just the plugin', () {
    final gradle = read(appGradlePath);
    // The Crashlytics Gradle plugin generates SYMBOLS. The artifact that
    // installs the native signal handlers is a separate dependency, and the
    // firebase_crashlytics Flutter plugin does not pull it in. Without it the
    // build would produce symbols for crashes nobody ever records.
    expect(gradle, contains('com.google.firebase:firebase-crashlytics-ndk'),
        reason: 'NDK capture needs the -ndk artifact, not just the plugin');
    expect(gradle, contains('nativeSymbolUploadEnabled = true'));
    // The engine .so arrives prebuilt from cargo-ndk rather than through an
    // externalNativeBuild, so the plugin cannot find the unstripped libs on
    // its own and must be pointed at the staging directory.
    expect(gradle, contains('unstrippedNativeLibsDir'));
    expect(gradle, contains('src/main/jniLibs'));
  });

  test('android.yml generates the config from the telemetry values', () {
    final workflow = read(workflowPath);
    expect(workflow, contains('app/android/app/google-services.json'),
        reason: 'CI must materialise the file Gradle gates on');
    for (final name in const [
      'AIGAMMON_FIREBASE_PROJECT',
      'AIGAMMON_FIREBASE_API_KEY',
      'AIGAMMON_FIREBASE_SENDER_ID',
      'FIREBASE_ANDROID_APP_ID',
    ]) {
      expect(workflow, contains(name),
          reason: 'the config is built from the SAME values as the telemetry '
              'dart-defines — a separate secret could only ever drift');
    }
    // The schema key is `mobilesdk_app_id`, one word, no underscore after
    // "mobile". Spelling it the intuitive way yields a file the plugin parses
    // without complaint and an app id it never finds.
    expect(workflow, contains('mobilesdk_app_id'));
  });

  test('the generated package_name matches the applicationId', () {
    // Gradle fails with "No matching client found for package name" when these
    // drift, and they live in two different files with no compiler between
    // them.
    final applicationId = RegExp(r'applicationId\s*=\s*"([^"]+)"')
        .firstMatch(read(appGradlePath))
        ?.group(1);
    expect(applicationId, isNotNull);
    expect(read(workflowPath), contains('"$applicationId"'),
        reason: 'android.yml writes package_name literally; it must be the '
            'applicationId this module declares');
  });

  test('DEPLOY.md tells a human how to get the file locally', () {
    final doc = read(deployDocPath);
    expect(doc, contains('google-services.json'));
    expect(doc, contains('uploadCrashlyticsSymbolFileRelease'),
        reason: 'the symbol-upload gap must stay documented for as long as it '
            'is a gap — capture without symbolication is a partial state, and '
            'an undocumented partial state reads as a bug');
  });
}
