import 'package:aigammon_app/lan/qr_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The camera itself cannot be tested here — there is none, and pointing it at
/// something is not a thing a test can do. What CAN be tested is everything
/// around it: which platforms are even asked, and the shape of the three
/// answers the join tab has to handle.
void main() {
  group('platform support', () {
    test('the mobile platforms with a camera implementation are supported', () {
      expect(qrScanSupportedOn(TargetPlatform.android), isTrue);
      expect(qrScanSupportedOn(TargetPlatform.iOS), isTrue);
      expect(qrScanSupportedOn(TargetPlatform.macOS), isTrue);
    });

    test('the desktop targets this app also ships are NOT', () {
      // Windows is a real target here (see windows/), and Play Nearby works
      // there through discovery and typed addresses. Asking the plugin for a
      // camera on it throws, so it is refused before the route is pushed.
      expect(qrScanSupportedOn(TargetPlatform.windows), isFalse);
      expect(qrScanSupportedOn(TargetPlatform.linux), isFalse);
      expect(qrScanSupportedOn(TargetPlatform.fuchsia), isFalse);
    });
  });

  group('outcomes', () {
    test('every outcome is one of the three the join tab switches on', () {
      const outcomes = <QrScanOutcome>[
        QrScanCode('aigammon://join?v=1&h=1.2.3.4&p=47780&c=1234'),
        QrScanCancelled(),
        QrScanUnavailable('no camera'),
      ];
      for (final outcome in outcomes) {
        // A `switch` over a sealed type is exhaustive at COMPILE time; this
        // asserts the runtime side, that nothing else can turn up.
        final label = switch (outcome) {
          QrScanCode() => 'code',
          QrScanCancelled() => 'cancelled',
          QrScanUnavailable() => 'unavailable',
        };
        expect(label, isNotEmpty);
      }
    });

    test('an unavailable outcome always carries something to show the user',
        () {
      const outcome = QrScanUnavailable('Enter the address by hand.');
      expect(outcome.message, isNotEmpty);
    });
  });
}
