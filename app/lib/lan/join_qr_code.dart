import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'qr_payload.dart';

/// The host's address, port and room code as one thing to point a camera at.
///
/// Its own widget, and public, for two reasons: the host tab stays about
/// hosting, and a test can read [payload] back off the built widget — the QR
/// image itself keeps its data private, and asserting on pixels would prove
/// nothing anyway.
///
/// Rebuilt from [payload] every time, so a session that comes back on a
/// different port — or an address that arrives a moment after hosting starts —
/// repaints rather than showing a code for a host that no longer exists.
class JoinQrCode extends StatelessWidget {
  const JoinQrCode({required this.payload, this.size = 180, super.key});

  /// Exactly what a scanning device will read.
  final QrJoinPayload payload;

  /// Edge length of the symbol in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text('Scan to join', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Center(
          // The white plate and its margin are part of the SYMBOL, not
          // decoration: the quiet zone is what tells a scanner where the code
          // ends, and a dark-theme host painting dark modules on a dark surface
          // is unreadable to most of them.
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: encodeQrJoin(payload),
              version: QrVersions.auto,
              size: size,
              backgroundColor: Colors.white,
              // The payload is short, so even the strongest error correction
              // leaves a coarse symbol — which is what survives a phone held at
              // an angle across a table, or a screen with a fingerprint on it.
              errorCorrectionLevel: QrErrorCorrectLevel.H,
              semanticsLabel: 'QR code to join this game',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'On the other device, open Play Nearby → Join → Scan QR code.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
