import 'dart:typed_data';

import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

/// Reference conversion for the expected values below, worked out by hand in
/// the test comments rather than by calling the implementation — a test that
/// re-derives the same formula would only prove the code agrees with itself.
void main() {
  group('Frame', () {
    test('accepts a buffer of exactly width * height * 3 bytes', () {
      final frame = Frame(Uint8List(2 * 3 * 3), 2, 3);
      expect(frame.width, 2);
      expect(frame.height, 3);
      expect(frame.rgb, hasLength(18));
    });

    test('throws ArgumentError when the buffer is too short', () {
      expect(
        () => Frame(Uint8List(17), 2, 3),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError when the buffer is too long', () {
      expect(
        () => Frame(Uint8List(19), 2, 3),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError on non-positive dimensions', () {
      expect(() => Frame(Uint8List(0), 0, 3), throwsA(isA<ArgumentError>()));
      expect(() => Frame(Uint8List(0), 2, 0), throwsA(isA<ArgumentError>()));
      expect(() => Frame(Uint8List(0), -2, 3), throwsA(isA<ArgumentError>()));
    });

    test('pixelAt reads the three bytes of the requested pixel', () {
      final rgb = Uint8List.fromList([
        1, 2, 3, 4, 5, 6, // row 0
        7, 8, 9, 10, 11, 12, // row 1
      ]);
      final frame = Frame(rgb, 2, 2);
      expect(frame.pixelAt(0, 0), (1, 2, 3));
      expect(frame.pixelAt(1, 0), (4, 5, 6));
      expect(frame.pixelAt(0, 1), (7, 8, 9));
      expect(frame.pixelAt(1, 1), (10, 11, 12));
    });
  });

  group('Frame.fromYuv420', () {
    // The same 4x2 picture is expressed twice below — once as fully planar
    // I420 (uvPixelStride 1) and once as NV21-style interleaved chroma
    // (uvPixelStride 2) — so both layouts must produce these exact bytes.
    //
    // Luma:   row 0 = [  0,  64, 128, 255]
    //         row 1 = [ 16, 100, 200, 250]
    // Chroma: one 2x1 chroma row. Left pair  U=128 V=128 (neutral grey).
    //                             Right pair U=200 V= 60.
    //
    // BT.601 FULL range (JPEG/JFIF), which is what Android's camera2
    // YUV_420_888 and iOS's kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    // deliver:
    //   R = Y + 1.402   * (V - 128)
    //   G = Y - 0.344136 * (U - 128) - 0.714136 * (V - 128)
    //   B = Y + 1.772   * (U - 128)
    //
    // Neutral chroma leaves R = G = B = Y, giving the first two pixels of each
    // row unchanged. For the right pair, Cb = +72 and Cr = -68:
    //   R = Y - 95.336        G = Y + 23.783456        B = Y + 127.584
    // so, with `round()` then clamp to 0..255 (the rounding this package
    // pins — `floor()` would give 32/151/159 instead of 33/152/160):
    //   Y=128 -> ( 32.664, 151.783, 255.584) -> ( 33, 152, 255)
    //   Y=255 -> (159.664, 278.783, 382.584) -> (160, 255, 255)
    //   Y=200 -> (104.664, 223.783, 327.584) -> (105, 224, 255)
    //   Y=250 -> (154.664, 273.783, 377.584) -> (155, 255, 255)
    final expectedRgb = <int>[
      0, 0, 0, //          (0,0) Y=0   neutral
      64, 64, 64, //       (1,0) Y=64  neutral
      33, 152, 255, //     (2,0) Y=128
      160, 255, 255, //    (3,0) Y=255
      16, 16, 16, //       (0,1) Y=16  neutral
      100, 100, 100, //    (1,1) Y=100 neutral
      105, 224, 255, //    (2,1) Y=200
      155, 255, 255, //    (3,1) Y=250
    ];

    test('converts planar I420 (uvPixelStride 1) byte-exactly', () {
      final frame = Frame.fromYuv420(
        y: Uint8List.fromList([0, 64, 128, 255, 16, 100, 200, 250]),
        u: Uint8List.fromList([128, 200]),
        v: Uint8List.fromList([128, 60]),
        width: 4,
        height: 2,
        uvRowStride: 2,
        uvPixelStride: 1,
      );
      expect(frame.width, 4);
      expect(frame.height, 2);
      expect(frame.rgb, expectedRgb);
    });

    test('converts interleaved NV21-style chroma (uvPixelStride 2)', () {
      // NV21 packs chroma as V0 U0 V1 U1 in ONE buffer; the camera plugin
      // hands that buffer over as two overlapping plane views, the V plane
      // starting at byte 0 and the U plane at byte 1. uvRowStride is then the
      // interleaved row width (2 chroma samples x 2 bytes = 4).
      final interleaved = Uint8List.fromList([128, 128, 60, 200]);
      final frame = Frame.fromYuv420(
        y: Uint8List.fromList([0, 64, 128, 255, 16, 100, 200, 250]),
        u: Uint8List.sublistView(interleaved, 1),
        v: Uint8List.sublistView(interleaved, 0),
        width: 4,
        height: 2,
        uvRowStride: 4,
        uvPixelStride: 2,
      );
      expect(frame.rgb, expectedRgb);
    });

    test('clamps rather than wrapping at both ends of the range', () {
      // Y=0 with maximum Cr drives R well above 255 and G well below 0.
      final frame = Frame.fromYuv420(
        y: Uint8List.fromList([0, 0, 0, 0]),
        u: Uint8List.fromList([0]),
        v: Uint8List.fromList([255]),
        width: 2,
        height: 2,
        uvRowStride: 1,
        uvPixelStride: 1,
      );
      // R = 0 + 1.402 * 127 = 178.054 -> 178
      // G = 0 - 0.344136 * -128 - 0.714136 * 127 = 44.049 - 90.695 = -46.6 -> 0
      // B = 0 + 1.772 * -128 = -226.8 -> 0
      expect(frame.pixelAt(0, 0), (178, 0, 0));
      expect(frame.pixelAt(1, 1), (178, 0, 0));
    });

    test('throws when the luma plane is shorter than width * height', () {
      expect(
        () => Frame.fromYuv420(
          y: Uint8List(7),
          u: Uint8List(2),
          v: Uint8List(2),
          width: 4,
          height: 2,
          uvRowStride: 2,
          uvPixelStride: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when a chroma plane cannot cover the last pixel', () {
      expect(
        () => Frame.fromYuv420(
          y: Uint8List(8),
          u: Uint8List(2),
          v: Uint8List(1), // needs index 1
          width: 4,
          height: 2,
          uvRowStride: 2,
          uvPixelStride: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on non-positive strides', () {
      expect(
        () => Frame.fromYuv420(
          y: Uint8List(8),
          u: Uint8List(2),
          v: Uint8List(2),
          width: 4,
          height: 2,
          uvRowStride: 0,
          uvPixelStride: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => Frame.fromYuv420(
          y: Uint8List(8),
          u: Uint8List(2),
          v: Uint8List(2),
          width: 4,
          height: 2,
          uvRowStride: 2,
          uvPixelStride: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('tolerates a luma plane padded past width * height', () {
      // Camera planes routinely carry trailing padding; only a SHORT plane is
      // an error.
      final frame = Frame.fromYuv420(
        y: Uint8List.fromList([10, 20, 30, 40, 0, 0, 0]),
        u: Uint8List.fromList([128]),
        v: Uint8List.fromList([128]),
        width: 2,
        height: 2,
        uvRowStride: 1,
        uvPixelStride: 1,
      );
      expect(frame.rgb, [10, 10, 10, 20, 20, 20, 30, 30, 30, 40, 40, 40]);
    });

    test('honours a padded luma ROW stride (Android row padding)', () {
      // Android YUV_420_888 luma planes routinely carry per-ROW padding
      // (plane.bytesPerRow > width). Without yRowStride the plane is LONGER
      // than width * height, passes the length guard, and every row after the
      // first shears — the exact silent failure this parameter exists to
      // prevent. Here each 2-pixel row sits in a 4-byte stride with 99s as
      // padding: correct output ignores every 99.
      final frame = Frame.fromYuv420(
        y: Uint8List.fromList([10, 20, 99, 99, 30, 40, 99, 99]),
        u: Uint8List.fromList([128]),
        v: Uint8List.fromList([128]),
        width: 2,
        height: 2,
        yRowStride: 4,
        uvRowStride: 1,
        uvPixelStride: 1,
      );
      expect(frame.rgb, [10, 10, 10, 20, 20, 20, 30, 30, 30, 40, 40, 40]);
    });

    test('throws when a padded luma plane cannot cover its last row', () {
      expect(
        () => Frame.fromYuv420(
          y: Uint8List.fromList([10, 20, 99, 99, 30]), // last row cut short
          u: Uint8List.fromList([128]),
          v: Uint8List.fromList([128]),
          width: 2,
          height: 2,
          yRowStride: 4,
          uvRowStride: 1,
          uvPixelStride: 1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a yRowStride narrower than the frame', () {
      expect(
        () => Frame.fromYuv420(
          y: Uint8List.fromList([10, 20, 30, 40]),
          u: Uint8List.fromList([128]),
          v: Uint8List.fromList([128]),
          width: 2,
          height: 2,
          yRowStride: 1,
          uvRowStride: 1,
          uvPixelStride: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Frame.fromYuv420 signal range', () {
    // ── One picture, written out twice ──────────────────────────────────────
    //
    // The same 8x2 image expressed in both conventions a camera plugin can
    // hand over. The studio-range copy is built by the standard's own scaling,
    // rounded to a byte exactly as a sensor's output is:
    //
    //   Y' = 16  + Y       * 219/255      (0..255 -> 16..235)
    //   C' = 128 + (C-128) * 224/255      (0..255 -> 16..240 about 128)
    //
    // Chroma sits on four column pairs. The OUTER two are neutral, so the luma
    // extremes can be read with no colour in the way; the middle two are warm
    // (U=96, V=200) and cool (U=160, V=60), so the chroma half of the scaling
    // is exercised rather than assumed.
    int studioLuma(int y) => (16 + y * 219 / 255).round();
    int studioChroma(int c) => (128 + (c - 128) * 224 / 255).round();

    final fullY = Uint8List.fromList([
      0, 255, 96, 160, 96, 160, 64, 192, // row 0: both luma extremes, neutral
      8, 247, 128, 128, 128, 128, 32, 224, // row 1
    ]);
    final fullU = Uint8List.fromList([128, 96, 160, 128]);
    final fullV = Uint8List.fromList([128, 200, 60, 128]);

    final studioY = Uint8List.fromList(fullY.map(studioLuma).toList());
    final studioU = Uint8List.fromList(fullU.map(studioChroma).toList());
    final studioV = Uint8List.fromList(fullV.map(studioChroma).toList());

    Frame decode(Uint8List y, Uint8List u, Uint8List v,
            {bool videoRange = false}) =>
        Frame.fromYuv420(
          y: y,
          u: u,
          v: v,
          width: 8,
          height: 2,
          uvRowStride: 4,
          uvPixelStride: 1,
          videoRange: videoRange,
        );

    test('studio-range planes decoded as full range are measurably crushed',
        () {
      // The bug, pinned from the direction it actually bites. iOS is the
      // platform that ships this: `camera_avfoundation` hard-codes
      // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange for `yuv420` and
      // offers no way to ask for the full-range flavour, so every iOS frame
      // arrives on the studio scale whatever this package would prefer.
      final full = decode(fullY, fullU, fullV);
      final naive = decode(studioY, studioU, studioV);

      // The neutral column pair, where luma is the whole story: black lifts
      // off the floor and white falls off the ceiling by exactly the footroom
      // and headroom the studio range reserves.
      expect(full.pixelAt(0, 0), (0, 0, 0));
      expect(naive.pixelAt(0, 0), (16, 16, 16));
      expect(full.pixelAt(1, 0), (255, 255, 255));
      expect(naive.pixelAt(1, 0), (235, 235, 235));

      // 219 levels of contrast where the picture holds 255 — a 14.1% loss of
      // margin, taken in exactly the dim rooms the readability checks exist
      // for.
      expect((235 - 16) / 255, closeTo(0.8588, 0.0001));

      // And the consequence with a name in this package:
      // `CalibrationFingerprint.clippedFraction` counts channels AT 255, and
      // `ReadabilityMonitor` raises `tooBright` from it. Nothing in the crushed
      // decode can ever reach 255, so that cause is structurally dead on iOS —
      // a board under a blazing lamp would report itself perfectly lit.
      expect(full.rgb.where((b) => b == 255), hasLength(4));
      expect(naive.rgb.where((b) => b == 255), isEmpty);
    });

    test('videoRange: true recovers the full-range picture', () {
      // The whole of the fix: the same photons, decoded through either
      // convention, must land on the same RGB. Only the round trip's own
      // byte quantization may survive — a studio byte covers 255/219 of a full
      // one in luma and 255/224 in chroma, and the matrix amplifies the chroma
      // half by up to 1.772.
      final full = decode(fullY, fullU, fullV);
      final fixed = decode(studioY, studioU, studioV, videoRange: true);

      var worst = 0;
      for (var i = 0; i < full.rgb.length; i++) {
        final delta = (full.rgb[i] - fixed.rgb[i]).abs();
        if (delta > worst) worst = delta;
      }
      // Measured: ONE level, over all 48 bytes. The arithmetic bound is a
      // little over two — half a studio luma byte is 255/219/2 = 0.58 of a
      // full one, half a chroma byte is 255/224/2 = 0.57, the blue term
      // amplifies that by 1.772, and the final round adds another half — so
      // the pin is the measurement, not the bound. Before the fix this same
      // comparison read **20**.
      expect(worst, 1, reason: 'worst per-byte deviation was $worst');
    });
  });

  group('Pt', () {
    test('has value equality and a stable hashCode', () {
      expect(const Pt(1.5, -2.25), const Pt(1.5, -2.25));
      expect(const Pt(1.5, -2.25).hashCode, const Pt(1.5, -2.25).hashCode);
      expect(const Pt(1.5, -2.25), isNot(const Pt(1.5, 2.25)));
    });

    test('prints both coordinates', () {
      expect(const Pt(1.5, -2.25).toString(), contains('1.5'));
      expect(const Pt(1.5, -2.25).toString(), contains('-2.25'));
    });
  });

  group('BoardQuad', () {
    const quad = BoardQuad(
      topLeft: Pt(0, 0),
      topRight: Pt(10, 1),
      bottomRight: Pt(11, 8),
      bottomLeft: Pt(-1, 9),
    );

    test('has value equality', () {
      expect(
        quad,
        const BoardQuad(
          topLeft: Pt(0, 0),
          topRight: Pt(10, 1),
          bottomRight: Pt(11, 8),
          bottomLeft: Pt(-1, 9),
        ),
      );
      expect(
        quad,
        isNot(const BoardQuad(
          topLeft: Pt(0, 0),
          topRight: Pt(10, 1),
          bottomRight: Pt(11, 8),
          bottomLeft: Pt(-1, 8),
        )),
      );
    });

    test('hashCode agrees with equality', () {
      expect(
        quad.hashCode,
        const BoardQuad(
          topLeft: Pt(0, 0),
          topRight: Pt(10, 1),
          bottomRight: Pt(11, 8),
          bottomLeft: Pt(-1, 9),
        ).hashCode,
      );
    });

    test('corners are clockwise from the top left', () {
      expect(quad.corners, [
        const Pt(0, 0),
        const Pt(10, 1),
        const Pt(11, 8),
        const Pt(-1, 9),
      ]);
    });

    test('fromCorners round-trips corners', () {
      expect(BoardQuad.fromCorners(quad.corners), quad);
    });

    test('fromCorners rejects a list that is not four points', () {
      expect(
        () => BoardQuad.fromCorners(const [Pt(0, 0), Pt(1, 1), Pt(2, 2)]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rect builds the axis-aligned quad of a w x h image', () {
      expect(
        BoardQuad.rect(4, 3),
        const BoardQuad(
          topLeft: Pt(0, 0),
          topRight: Pt(4, 0),
          bottomRight: Pt(4, 3),
          bottomLeft: Pt(0, 3),
        ),
      );
    });
  });

  group('BoardOrientation', () {
    test('names the two seatings a session can be calibrated in', () {
      expect(BoardOrientation.values, [
        BoardOrientation.whiteHomeNear,
        BoardOrientation.whiteHomeFar,
      ]);
    });
  });
}
