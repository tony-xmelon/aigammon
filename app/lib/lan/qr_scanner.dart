import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'qr_payload.dart';

/// The camera, behind one method.
///
/// [LanScreen] never touches `mobile_scanner` directly; it asks a [QrScanner]
/// for a string and deals with the three answers below. That is what makes the
/// join flow testable on a machine with no camera — a widget test overrides
/// [qrScannerProvider] with a scripted scanner and drives the whole path from
/// "user tapped Scan" to "the guest session was opened".
///
/// The seam is deliberately COARSE (one call, one outcome) rather than a stream
/// of frames: everything about running a camera — permissions, lifecycle,
/// torch, ignoring the poster on the wall behind the other player — belongs on
/// the far side of it.
abstract interface class QrScanner {
  /// Open a scanner over [context] and wait for it to finish.
  ///
  /// Never throws: a camera that cannot be opened comes back as
  /// [QrScanUnavailable], not as an exception.
  Future<QrScanOutcome> scan(BuildContext context);
}

/// How a scan ended.
sealed class QrScanOutcome {
  const QrScanOutcome();
}

/// A code was read. [raw] is UNVALIDATED text — the caller decodes it with
/// [tryDecodeQrJoin] and must be ready for null.
final class QrScanCode extends QrScanOutcome {
  const QrScanCode(this.raw);

  final String raw;
}

/// The user backed out. Nothing to say; the join tab simply stays where it was.
final class QrScanCancelled extends QrScanOutcome {
  const QrScanCancelled();
}

/// No camera to scan with — permission refused, no camera on the device, or the
/// platform refused to start one. [message] is user-facing and always points at
/// the manual-entry fallback, because a scan that cannot happen must never be a
/// dead end.
final class QrScanUnavailable extends QrScanOutcome {
  const QrScanUnavailable(this.message);

  final String message;
}

/// Whether `mobile_scanner` has a camera implementation for [platform].
///
/// Android, iOS and macOS only. Windows and Linux — where this app also runs,
/// and where Play Nearby is perfectly usable through discovery and typed
/// addresses — have no implementation, and asking for one there throws rather
/// than returning empty. Keeping the list here (rather than at the call site)
/// means the join tab has exactly one story for "no camera", however the
/// device got there.
bool qrScanSupportedOn(TargetPlatform platform) => switch (platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS =>
        true,
      TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.fuchsia =>
        false,
    };

/// The production scanner: a full-screen camera preview.
///
/// It filters on this app's own payload — a foreign QR code (a poster, a Wi-Fi
/// card, a receipt) is reported inline and the camera KEEPS RUNNING, so the
/// user just moves the phone rather than starting over. The route pops on the
/// first valid AIGammon code and only that.
class MobileScannerQrScanner implements QrScanner {
  const MobileScannerQrScanner();

  @override
  Future<QrScanOutcome> scan(BuildContext context) async {
    // Checked BEFORE the route is pushed: on a platform the plugin does not
    // implement, building the preview throws from inside the widget tree,
    // where the join tab could neither catch it nor say anything useful.
    if (!qrScanSupportedOn(defaultTargetPlatform)) {
      return const QrScanUnavailable(
        'This device cannot scan QR codes. Enter the address shown on the '
        'other device by hand.',
      );
    }
    final outcome = await Navigator.of(context).push<QrScanOutcome>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    // A swipe-back or the system back button pops with no value.
    return outcome ?? const QrScanCancelled();
  }
}

/// The scanner route. Public only so a manual/integration run can push it.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  late final MobileScannerController _controller = MobileScannerController(
    // QR only: the detector has less to do, and a stray barcode on a coffee cup
    // never even reaches the filter.
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );

  /// Set the instant a valid code is accepted.
  ///
  /// The detector fires many times a second, and a code held in frame produces
  /// a burst of identical results. Without this latch the route would pop once
  /// per frame — and the join flow would start twice.
  bool _handled = false;

  /// Shown when something scanned but was not ours.
  String? _hint;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      if (tryDecodeQrJoin(raw) == null) continue;
      _handled = true;
      Navigator.of(context).pop(QrScanCode(raw));
      return;
    }
    // Nothing in this frame was ours. Say so once, quietly, and keep scanning.
    if (_hint == null && capture.barcodes.isNotEmpty) {
      setState(() => _hint = 'That is not an AIGammon game code. Point the '
          'camera at the QR code on the other device\'s Host screen.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan the host\'s code'),
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on),
            onPressed: () => unawaited(_controller.toggleTorch()),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // A camera error is a message and a way out, never a black screen
            // the user has to guess their way off.
            errorBuilder: (context, error) => _CameraProblem(
              message: _cameraErrorText(error),
              onDismiss: () => Navigator.of(context)
                  .pop(QrScanUnavailable(_cameraErrorText(error))),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: _ScanCaption(hint: _hint),
          ),
        ],
      ),
    );
  }
}

/// Turn a scanner failure into something a person can act on. Every branch ends
/// by pointing at manual entry.
String _cameraErrorText(MobileScannerException error) =>
    switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'AIGammon does not have permission to use the camera. Allow camera '
            'access in your device settings, or enter the address shown on the '
            'other device by hand.',
      MobileScannerErrorCode.unsupported =>
        'This device cannot scan QR codes. Enter the address shown on the '
            'other device by hand.',
      _ => 'The camera could not be started. Enter the address shown on the '
          'other device by hand.',
    };

class _CameraProblem extends StatelessWidget {
  const _CameraProblem({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 40),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onDismiss,
                child: const Text('Enter the address instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line under the viewfinder: what to point at, or why the last thing did
/// not count.
class _ScanCaption extends StatelessWidget {
  const _ScanCaption({required this.hint});

  final String? hint;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          hint ?? 'Point the camera at the QR code on the other device.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

/// The scanner [LanScreen] uses. Overridden in widget tests with a scripted one.
final qrScannerProvider = Provider<QrScanner>(
  (ref) => const MobileScannerQrScanner(),
);
