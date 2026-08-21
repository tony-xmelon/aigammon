import 'dart:typed_data';

/// One camera frame, as plain bytes.
///
/// The whole perception package speaks this and nothing else: no `dart:ui`,
/// no `CameraImage`, no plugin type ever crosses into `board_vision`. The app
/// owns the `camera` plugin and converts what it delivers (usually YUV420
/// planes) with [Frame.fromYuv420]; the corpus harness converts decoded JPEGs;
/// the synthetic renderer builds frames straight from its own drawing buffer.
/// That is what keeps this package buildable and testable on a desktop with no
/// camera attached.
class Frame {
  /// Row-major RGB888: three bytes per pixel, red first, no row padding.
  ///
  /// Pixel `(x, y)` starts at `(y * width + x) * 3`. Length is exactly
  /// `width * height * 3` — the constructor refuses anything else, because a
  /// stride mismatch here would silently shear every later measurement rather
  /// than fail.
  final Uint8List rgb;

  final int width;
  final int height;

  Frame(this.rgb, this.width, this.height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('frame dimensions must be positive, '
          'got ${width}x$height');
    }
    final expected = width * height * 3;
    if (rgb.length != expected) {
      throw ArgumentError('rgb must hold width * height * 3 = $expected bytes '
          'for a ${width}x$height frame, got ${rgb.length}');
    }
  }

  /// The `(r, g, b)` bytes of the pixel at [x], [y].
  (int, int, int) pixelAt(int x, int y) {
    assert(x >= 0 && x < width, 'x $x outside 0..${width - 1}');
    assert(y >= 0 && y < height, 'y $y outside 0..${height - 1}');
    final i = (y * width + x) * 3;
    return (rgb[i], rgb[i + 1], rgb[i + 2]);
  }

  /// Byte offset of the red channel of pixel [x], [y].
  int offsetOf(int x, int y) => (y * width + x) * 3;

  /// Converts the YUV420 planes a camera plugin delivers into RGB888.
  ///
  /// ## Colour convention
  ///
  /// **BT.601**, with the signal range chosen by the caller through
  /// [videoRange] — because the two platforms do not agree, and neither one
  /// lets the app pick:
  ///
  /// * **Android** (`camera2`/CameraX `YUV_420_888`) forwards the sensor's
  ///   planes as they come, which by convention is **full range** 0..255. That
  ///   is [videoRange] `false`, the default.
  /// * **iOS** is **studio (video) range**, 16..235 luma and 16..240 chroma.
  ///   `camera_avfoundation` hard-codes
  ///   `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` for its `yuv420`
  ///   format — there is no plugin API that asks for the FullRange twin — so
  ///   an iOS frame arrives on that scale whatever this package would prefer.
  ///   That is [videoRange] `true`.
  ///
  /// Getting it wrong is quiet rather than obvious, which is why it is a
  /// parameter and not an assumption. The pipeline classifies colours
  /// *relatively* (a sample against its own ROI background), so a plain
  /// absolute-accuracy error would mostly cancel — but a range mismatch does
  /// not cancel, it **compresses**: studio-range planes read as full range
  /// keep only 219 of 255 levels, a 14.1% loss of contrast margin taken in
  /// exactly the dim conditions the readability checks care about, and no
  /// channel can ever reach 255 — so `CalibrationFingerprint.clippedFraction`
  /// reads zero forever and `ReadabilityCause.tooBright` cannot fire.
  /// `test/frame_test.dart` pins both halves of that, in both directions.
  ///
  /// ```text
  /// full range (videoRange false)      studio range (videoRange true)
  /// R = Y + 1.402    * (V - 128)       R = 1.164383 * (Y-16) + 1.596027 * (V-128)
  /// G = Y - 0.344136 * (U - 128)       G = 1.164383 * (Y-16) - 0.391762 * (U-128)
  ///       - 0.714136 * (V - 128)             - 0.812968 * (V-128)
  /// B = Y + 1.772    * (U - 128)       B = 1.164383 * (Y-16) + 2.017232 * (U-128)
  /// ```
  ///
  /// The studio column is the **integrated** matrix — `255/219` folded into
  /// the luma term and `255/224` into the three chroma terms — not an expand-
  /// then-convert with a clamp in the middle, and that difference is
  /// deliberate. Clamping the expanded Y' to 0..255 before the matrix runs
  /// would throw away the footroom and headroom the studio range exists to
  /// carry, *before* chroma has had its say: a bright pixel whose chroma pulls
  /// green back down would come out ~17 levels dark. The standard's own
  /// conversion clamps once, at the end, on RGB. So does this one.
  ///
  /// Results are **rounded** (not truncated) and then clamped to 0..255.
  /// `test/frame_test.dart` asserts byte-exact output for hand-computed
  /// inputs, so both the matrix and the rounding are contractual: switching to
  /// truncation or to integer fixed-point would move bytes by one and fail
  /// there on purpose. Those expectations are all full-range and all still
  /// hold to the bit — the range lives in a lookup table the default fills
  /// with the identity, so the inner loop's arithmetic did not change.
  ///
  /// ## Plane layout
  ///
  /// [y] is addressed at a row stride of [yRowStride], which defaults to
  /// [width] (tightly packed). Android's `YUV_420_888` luma planes routinely
  /// carry per-row padding (`plane.bytesPerRow > width`) — pass that
  /// `bytesPerRow` here rather than repacking; a padded plane is LONGER than
  /// `width * height`, so a plain length guard cannot catch the mismatch and
  /// the result would silently shear diagonally. Padding *past* the last
  /// row's pixels is fine and ignored. Chroma is addressed as
  /// `(y >> 1) * uvRowStride + (x >> 1) * uvPixelStride`, which covers both
  /// layouts in the wild: planar I420 ([uvPixelStride] 1) and semi-planar
  /// NV12/NV21 ([uvPixelStride] 2, where [u] and [v] are overlapping views of
  /// one interleaved buffer offset by a byte).
  ///
  /// [videoRange] says which scale the planes are on — `false` (full range,
  /// 0..255) unless the caller knows otherwise, because that is what every
  /// non-camera producer in this package hands over: the synthetic renderer,
  /// the corpus harness's decoded JPEGs, and every test that builds planes by
  /// hand. The app's `YuvFrame.fromCameraImage` is the one place that sets it,
  /// from the plane count.
  factory Frame.fromYuv420({
    required Uint8List y,
    required Uint8List u,
    required Uint8List v,
    required int width,
    required int height,
    int? yRowStride,
    required int uvRowStride,
    required int uvPixelStride,
    bool videoRange = false,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('frame dimensions must be positive, '
          'got ${width}x$height');
    }
    final yStride = yRowStride ?? width;
    if (yStride < width) {
      throw ArgumentError(
          'yRowStride $yStride cannot be narrower than width $width');
    }
    if (uvRowStride <= 0 || uvPixelStride <= 0) {
      throw ArgumentError('uv strides must be positive, got '
          'row $uvRowStride / pixel $uvPixelStride');
    }
    // The last row needs only its width pixels, not its full stride.
    final lastLuma = (height - 1) * yStride + width;
    if (y.length < lastLuma) {
      throw ArgumentError('luma plane holds ${y.length} bytes, needs at least '
          '$lastLuma for a ${width}x$height frame at row stride $yStride');
    }
    final lastUv =
        ((height - 1) >> 1) * uvRowStride + ((width - 1) >> 1) * uvPixelStride;
    if (u.length <= lastUv || v.length <= lastUv) {
      throw ArgumentError('chroma planes must reach index $lastUv, got '
          'u ${u.length} / v ${v.length}');
    }

    // The range expansion lives in two 256-entry tables rather than in the
    // inner loop, so the loop runs the SAME three multiply-adds either way and
    // neither convention pays for the other's existence. Full range fills them
    // with the identity — `i` and `i - 128`, the exact values the loop used to
    // compute inline — which is why every byte-exact expectation in
    // `frame_test.dart` still holds to the bit.
    //
    // Neither table clamps: that is what makes the studio path the integrated
    // BT.601 matrix rather than an expand-then-convert, and the reason is in
    // the doc above. The single clamp is [_clampByte], on RGB, at the end.
    final lumaOf = Float64List(256);
    final chromaOf = Float64List(256);
    for (var i = 0; i < 256; i++) {
      lumaOf[i] = videoRange ? (i - 16) * (255 / 219) : i.toDouble();
      chromaOf[i] = (i - 128) * (videoRange ? 255 / 224 : 1.0);
    }

    final rgb = Uint8List(width * height * 3);
    var out = 0;
    for (var py = 0; py < height; py++) {
      final yRow = py * yStride;
      final uvRow = (py >> 1) * uvRowStride;
      for (var px = 0; px < width; px++) {
        final luma = lumaOf[y[yRow + px]];
        final uvIndex = uvRow + (px >> 1) * uvPixelStride;
        final cb = chromaOf[u[uvIndex]];
        final cr = chromaOf[v[uvIndex]];
        rgb[out++] = _clampByte(luma + 1.402 * cr);
        rgb[out++] = _clampByte(luma - 0.344136 * cb - 0.714136 * cr);
        rgb[out++] = _clampByte(luma + 1.772 * cb);
      }
    }
    return Frame(rgb, width, height);
  }

  static int _clampByte(double v) {
    final r = v.round();
    return r < 0
        ? 0
        : r > 255
            ? 255
            : r;
  }

  @override
  String toString() => 'Frame(${width}x$height)';
}
