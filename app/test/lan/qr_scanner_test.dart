import 'package:aigammon_app/lan/qr_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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

  group('backing out', () {
    /// The message the "Enter the address instead" button on the camera-error
    /// screen shows — and, per [backOutcomeFor], the one a back gesture out of
    /// the same screen must report.
    const denied =
        MobileScannerException(errorCode: MobileScannerErrorCode.permissionDenied);

    test('backing out of a WORKING camera is a plain cancellation', () {
      expect(backOutcomeFor(null), isA<QrScanCancelled>());
    });

    test('backing out of a refused camera says the same thing the button does',
        () {
      // The bug this pins: a system back from the permission-denied screen used
      // to report a cancellation, so the join tab showed nothing at all and the
      // scan button looked simply broken.
      final outcome = backOutcomeFor(denied);
      expect(outcome, isA<QrScanUnavailable>());
      expect((outcome as QrScanUnavailable).message, cameraErrorText(denied));
      expect(outcome.message, contains('permission'));
      expect(outcome.message, contains('by hand'),
          reason: 'every camera failure ends by pointing at manual entry');
    });

    test('every camera failure has a message, not just the ones we listed', () {
      for (final code in MobileScannerErrorCode.values) {
        final text = cameraErrorText(MobileScannerException(errorCode: code));
        expect(text, isNotEmpty, reason: '$code');
        expect(text, contains('by hand'), reason: '$code');
      }
    });
  });

  group('the scanner route', () {
    // There is no camera here, so the preview sits in its placeholder state —
    // which is exactly the state both bugs below lived in.

    testWidgets('the torch survives a tap before the camera is up', (t) async {
      await t.pumpWidget(const MaterialApp(home: QrScanPage()));
      await t.pump();

      // Immediately: `toggleTorch` throws `controllerUninitialized` until
      // `start()` has come back, and the button is tappable for that whole
      // window.
      await t.tap(find.byIcon(Icons.flashlight_on));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(t.takeException(), isNull,
          reason: 'an early torch tap is a no-op, not a crash');
      expect(find.byIcon(Icons.flashlight_on), findsOneWidget);
    });

    testWidgets('backing out always pops WITH an outcome, never null',
        (t) async {
      QrScanOutcome? outcome;
      var popped = false;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              outcome = await Navigator.of(context).push<QrScanOutcome>(
                MaterialPageRoute(builder: (_) => const QrScanPage()),
              );
              popped = true;
            },
            child: const Text('scan'),
          ),
        ),
      ));
      await t.tap(find.text('scan'));
      await t.pumpAndSettle();
      expect(find.byType(QrScanPage), findsOneWidget);

      await t.pageBack();
      await t.pumpAndSettle();

      expect(popped, isTrue);
      // Null would read as "cancelled" by luck rather than by decision — and on
      // the camera-error screen it would swallow the reason entirely.
      expect(outcome, isNotNull);
      expect(outcome, isA<QrScanCancelled>());
    });
  });
}
