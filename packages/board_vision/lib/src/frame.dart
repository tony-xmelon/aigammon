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
  /// **BT.601, FULL range** (the JPEG/JFIF matrix), deliberately:
  ///
  /// * Android `camera2` `YUV_420_888` and iOS
  ///   `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` — what the `camera`
  ///   plugin requests on both platforms — are full-range 601;
  /// * the perception pipeline classifies colours *relatively* (a sample
  ///   against its own ROI background), so an absolute-accuracy error here
  ///   would mostly cancel — but a range mismatch (studio-range 16..235
  ///   decoded as full range) crushes contrast in exactly the dim conditions
  ///   the readability checks care about, so the choice is pinned rather than
  ///   left to taste.
  ///
  /// ```text
  /// R = Y + 1.402   * (V - 128)
  /// G = Y - 0.344136 * (U - 128) - 0.714136 * (V - 128)
  /// B = Y + 1.772   * (U - 128)
  /// ```
  ///
  /// Results are **rounded** (not truncated) and then clamped to 0..255.
  /// `test/frame_test.dart` asserts byte-exact output for hand-computed
  /// inputs, so both the matrix and the rounding are contractual: switching to
  /// truncation or to integer fixed-point would move bytes by one and fail
  /// there on purpose.
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
  factory Frame.fromYuv420({
    required Uint8List y,
    required Uint8List u,
    required Uint8List v,
    required int width,
    required int height,
    int? yRowStride,
    required int uvRowStride,
    required int uvPixelStride,
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

    final rgb = Uint8List(width * height * 3);
    var out = 0;
    for (var py = 0; py < height; py++) {
      final yRow = py * yStride;
      final uvRow = (py >> 1) * uvRowStride;
      for (var px = 0; px < width; px++) {
        final luma = y[yRow + px];
        final uvIndex = uvRow + (px >> 1) * uvPixelStride;
        final cb = u[uvIndex] - 128;
        final cr = v[uvIndex] - 128;
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
