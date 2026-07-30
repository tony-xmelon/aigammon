import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Android RELEASE signing configuration.
///
/// Same family as `android_manifest_test.dart`: pure file assertions, no APK is
/// built. The bug class they cover is identical — a release-only build setting
/// that no widget or unit test can reach, whose failure only ever appears on a
/// shipped build. Here it is worse than a missing permission: an APK signed
/// with Flutter's *debug* keystore is rejected by the Play Store, and every
/// developer machine has a different debug key, so a build that slips out
/// signed with one can never be updated by a build signed with another.
///
/// The scheme these tests pin down is credential-GATED, mirroring the existing
/// `AIGAMMON_FIREBASE_*` / iOS-signing gates: `key.properties` (git-ignored,
/// written by CI from repo secrets) selects a real `release` signing config
/// when present, and the build falls back to the debug key with a loud warning
/// when it is absent. See `android/KEYSTORE_SETUP.md`.
void main() {
  const gradlePath = 'android/app/build.gradle.kts';
  const gitignorePath = 'android/.gitignore';
  const setupDocPath = 'android/KEYSTORE_SETUP.md';
  const workflowPath = '../.github/workflows/android.yml';

  String read(String path) => File(path).readAsStringSync();

  test('the release build type reads signing credentials from key.properties',
      () {
    final gradle = read(gradlePath);
    expect(gradle, contains('key.properties'),
        reason: 'the release signing config must be driven by a git-ignored '
            'key.properties, not by hard-coded credentials or the debug key');
    expect(gradle, contains('signingConfigs.getByName("release")'),
        reason: 'a real `release` signing config must exist and be selected '
            'for the release build type when credentials are present');
  });

  test('the stale scaffold TODO is gone', () {
    // Flutter\'s `create` template ships:
    //   // TODO: Add your own signing config for the release build.
    // Leaving it in place is how a debug-signed release ships unnoticed.
    final gradle = read(gradlePath);
    expect(gradle, isNot(contains('TODO: Add your own signing config')),
        reason: 'the scaffold TODO must be removed once signing is wired');
  });

  test('debug signing survives only as an explicit, gated FALLBACK', () {
    // The fallback is deliberate (CI must stay green before the user adds the
    // secrets), but it must be reachable only through the presence check —
    // never as the unconditional value of `release { signingConfig = ... }`.
    final gradle = read(gradlePath);
    expect(
      gradle,
      isNot(contains(RegExp(
          r'release\s*\{\s*(//[^\n]*\n\s*)*signingConfig\s*=\s*'
          r'signingConfigs\.getByName\("debug"\)'))),
      reason: 'the release build type must not unconditionally take the debug '
          'signing config',
    );
    expect(gradle, contains('hasReleaseSigning'),
        reason: 'the debug fallback must be guarded by the credential '
            'presence check');
  });

  test('keystore material and credentials are git-ignored', () {
    final ignore = read(gitignorePath);
    for (final pattern in const [
      'key.properties',
      '**/*.jks',
      '**/*.jks.base64.txt',
    ]) {
      expect(ignore, contains(pattern),
          reason: 'committing $pattern would publish the signing identity');
    }
  });

  test('KEYSTORE_SETUP.md documents every secret the CI step reads', () {
    final doc = read(setupDocPath);
    final workflow = read(workflowPath);
    for (final secret in const [
      'ANDROID_KEYSTORE_BASE64',
      'ANDROID_KEYSTORE_PASSWORD',
      'ANDROID_KEY_ALIAS',
      'ANDROID_KEY_PASSWORD',
    ]) {
      expect(doc, contains(secret),
          reason: 'the setup doc is the only place the user learns the exact '
              'secret names');
      expect(workflow, contains(secret),
          reason: 'android.yml must consume the secret the doc advertises');
    }
  });

  test('android.yml writes key.properties and tolerates missing secrets', () {
    final workflow = read(workflowPath);
    expect(workflow, contains('key.properties'),
        reason: 'CI must materialise the credentials Gradle reads');
    expect(workflow, contains('base64 --decode'),
        reason: 'the keystore travels as a base64 secret');
    expect(workflow, contains('KEYSTORE_SETUP.md'),
        reason: 'the skip path must point at the setup instructions');
  });
}
