import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the shipping iOS `Info.plist`, for the same reason
/// `android_manifest_test.dart` guards the Android manifest.
///
/// iOS is stricter than Android about this and fails later: a build that links
/// a privacy-sensitive API without the matching usage string does not merely
/// get the permission denied — the OS terminates the process the instant the
/// API is touched, and App Review rejects the binary before that. Neither
/// failure is reachable from a Windows dev machine or from `flutter test`, and
/// the only cheap defence is a file assertion.
///
/// The strings themselves are asserted for *substance*, not wording: a string
/// that names no reason is what Review sends back, so each key is required to
/// mention the thing it is asking for.
void main() {
  const plistPath = 'ios/Runner/Info.plist';

  String plist() => File(plistPath).readAsStringSync();

  /// The `<string>` immediately following [key] in the plist, or null.
  String? valueOf(String key) {
    final match = RegExp(
      '<key>$key</key>\\s*<string>(.*?)</string>',
      dotAll: true,
    ).firstMatch(plist());
    return match?.group(1);
  }

  test('NSCameraUsageDescription is present and explains BOTH camera uses', () {
    final value = valueOf('NSCameraUsageDescription');
    expect(value, isNotNull,
        reason: 'the app links a camera API (QR join, and Buddy Mode watching '
            'the board); iOS kills the process on first use without this key');
    // Two features now share one prompt, and iOS shows it once. A string that
    // only mentions QR codes would be a lie the second time it appears — in
    // Buddy Mode, where no QR code is involved at all.
    expect(value!.toLowerCase(), contains('qr'),
        reason: 'the QR join still asks for the camera');
    expect(value.toLowerCase(), contains('board'),
        reason: 'Buddy Mode points the camera at the physical board, and the '
            'user sees this same string when it does');
  });

  test('NSMicrophoneUsageDescription is present and says what it listens for',
      () {
    final value = valueOf('NSMicrophoneUsageDescription');
    expect(value, isNotNull,
        reason: "Buddy Mode's dice-roll listener links an audio-input API; "
            'iOS terminates the app on first use without this key');
    expect(value!.toLowerCase(), contains('dice'),
        reason: 'a usage string that does not name the reason is what App '
            'Review rejects');
  });

  test('NSLocalNetworkUsageDescription survives (Play Nearby still needs it)',
      () {
    expect(valueOf('NSLocalNetworkUsageDescription'), isNotNull);
  });
}
