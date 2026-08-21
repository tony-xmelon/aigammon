import 'dart:async';
import 'dart:typed_data';

import 'package:aigammon_app/buddy/camera_frame_source.dart';
import 'package:board_vision/board_vision.dart';
import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// A synthetic YUV420 frame whose luma is whatever [luma] says.
///
/// Chroma is left at 128 (neutral grey) throughout: every gate in this file
/// reads luma only, and a colour signal would just be noise in the assertions.
YuvFrame yuv({
  int width = 64,
  int height = 64,
  int yPadding = 0,
  required int Function(int x, int y) luma,
}) {
  final stride = width + yPadding;
  final y = Uint8List(stride * height);
  for (var py = 0; py < height; py++) {
    for (var px = 0; px < width; px++) {
      y[py * stride + px] = luma(px, py);
    }
    // Padding filled with a value NOTHING should ever read. If a stride bug
    // creeps in, the result shears visibly rather than degrading quietly.
    for (var px = width; px < stride; px++) {
      y[py * stride + px] = 255;
    }
  }
  final uvW = (width + 1) >> 1;
  final uvH = (height + 1) >> 1;
  return YuvFrame(
    y: y,
    u: Uint8List(uvW * uvH)..fillRange(0, uvW * uvH, 128),
    v: Uint8List(uvW * uvH)..fillRange(0, uvW * uvH, 128),
    width: width,
    height: height,
    yRowStride: stride,
    uvRowStride: uvW,
    uvPixelStride: 1,
  );
}

YuvFrame flat(int level, {int width = 64, int height = 64, int yPadding = 0}) =>
    yuv(width: width, height: height, yPadding: yPadding, luma: (_, _) => level);

/// A frame that is [level] everywhere except a [size]x[size] block at
/// (0, 0) — a stand-in for a checker, or a hand, depending on how big it is.
YuvFrame withBlock(int level, int blockLevel, int size) => yuv(
      luma: (x, y) => (x < size && y < size) ? blockLevel : level,
    );

void main() {
  group('YuvFrame → Frame', () {
    test('a padded luma plane converts without shearing', () {
      // The bug this exists for: Android's YUV_420_888 luma routinely carries
      // per-row padding, and a padded plane is LONGER than width * height — so
      // Frame's length guard cannot catch a stride mistake, and the picture
      // would skew diagonally instead of failing.
      final frame = flat(120, width: 8, height: 8, yPadding: 5).toFrame();

      expect(frame.width, 8);
      expect(frame.height, 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          expect(frame.pixelAt(x, y), (120, 120, 120),
              reason: 'padding leaked into pixel ($x, $y)');
        }
      }
    });

    test('luma detail survives the round trip', () {
      final frame = withBlock(60, 200, 16).toFrame();
      expect(frame.pixelAt(2, 2).$1, 200);
      expect(frame.pixelAt(40, 40).$1, 60);
    });
  });

  group('YuvFrame.fromCameraImage', () {
    CameraImagePlane plane(Uint8List bytes, int bytesPerRow, {int? perPixel}) =>
        CameraImagePlane(
          bytes: bytes,
          bytesPerRow: bytesPerRow,
          bytesPerPixel: perPixel,
        );

    CameraImage image(List<CameraImagePlane> planes, int w, int h) =>
        CameraImage.fromPlatformInterface(CameraImageData(
          format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
          planes: planes,
          width: w,
          height: h,
        ));

    test('Android three-plane YUV_420_888 keeps the luma row stride', () {
      // The whole reason this conversion is not a one-liner: bytesPerRow on the
      // luma plane is the number Frame.fromYuv420 needs, and dropping it is
      // silent.
      const w = 8, h = 8, stride = 12;
      final frame = YuvFrame.fromCameraImage(image([
        plane(Uint8List(stride * h)..fillRange(0, stride * h, 90), stride,
            perPixel: 1),
        plane(Uint8List(4 * 4)..fillRange(0, 16, 128), 4, perPixel: 1),
        plane(Uint8List(4 * 4)..fillRange(0, 16, 128), 4, perPixel: 1),
      ], w, h));

      expect(frame.yRowStride, stride);
      expect(frame.uvRowStride, 4);
      expect(frame.uvPixelStride, 1);
      expect(frame.toFrame().pixelAt(7, 7), (90, 90, 90));
    });

    test('Android semi-planar chroma (pixel stride 2) is carried through', () {
      const w = 8, h = 8;
      final uv = Uint8List(4 * 8)..fillRange(0, 32, 128);
      final frame = YuvFrame.fromCameraImage(image([
        plane(Uint8List(w * h)..fillRange(0, w * h, 90), w, perPixel: 1),
        plane(uv, 8, perPixel: 2),
        plane(Uint8List.sublistView(uv, 1), 8, perPixel: 2),
      ], w, h));

      expect(frame.uvPixelStride, 2);
      expect(frame.uvRowStride, 8);
    });

    test('iOS two-plane NV12 is split into overlapping U and V views', () {
      // iOS delivers ONE interleaved CbCr plane, not two. Frame.fromYuv420
      // already understands that layout (pixel stride 2, V offset one byte
      // into the same buffer) — but only if this conversion builds the views
      // instead of throwing on planes.length != 3.
      const w = 8, h = 8;
      final uv = Uint8List(8 * 4);
      for (var i = 0; i < uv.length; i++) {
        uv[i] = i.isEven ? 100 : 200; // Cb = 100, Cr = 200
      }
      final frame = YuvFrame.fromCameraImage(image([
        plane(Uint8List(w * h)..fillRange(0, w * h, 90), w),
        plane(uv, 8),
      ], w, h));

      expect(frame.uvPixelStride, 2, reason: 'NV12 is interleaved');
      expect(frame.u[0], 100);
      expect(frame.v[0], 200, reason: 'V is the same buffer, offset by a byte');
      // And it must actually convert — the V plane is one byte shorter than U,
      // which is exactly where Frame's length guard bites if the views are
      // built wrong.
      expect(frame.toFrame().width, w);
    });

    test('a format that is not YUV420 is refused, loudly', () {
      expect(
        () => YuvFrame.fromCameraImage(CameraImage.fromPlatformInterface(
          CameraImageData(
            format: const CameraImageFormat(ImageFormatGroup.bgra8888,
                raw: 1111970369),
            planes: [plane(Uint8List(64), 8)],
            width: 8,
            height: 8,
          ),
        )),
        throwsArgumentError,
      );
    });
  });

  group('FrameSignature', () {
    test('an identical frame differs by nothing', () {
      final a = FrameSignature.of(flat(120));
      final b = FrameSignature.of(flat(120));
      expect(a.difference(b), 0);
    });

    test('padding never reaches the signature', () {
      // The padding bytes are 255; if they were sampled, a padded frame would
      // look brighter than the same frame unpadded.
      expect(
        FrameSignature.of(flat(120, yPadding: 7))
            .difference(FrameSignature.of(flat(120))),
        0,
      );
    });

    test('a hand-sized change is far above the quiet bound', () {
      // A quarter of the frame turning dark: what an arm reaching over the
      // board looks like.
      final quiet = FrameSignature.of(flat(120));
      final covered = FrameSignature.of(withBlock(120, 20, 32));
      expect(quiet.difference(covered), greaterThan(kSceneQuietThreshold * 10));
    });

    test('sensor-noise-sized jitter stays under the quiet bound', () {
      // ±2 grey levels of uncorrelated noise, which is a fair sensor at decent
      // light. The gate must not read that as "something moved" or it would
      // never admit a frame at all.
      var seed = 7;
      int noisy(int _, int _) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return 120 + (seed % 5) - 2;
      }

      final a = FrameSignature.of(yuv(width: 256, height: 256, luma: noisy));
      final b = FrameSignature.of(yuv(width: 256, height: 256, luma: noisy));
      expect(a.difference(b), lessThan(kSceneQuietThreshold));
    });

    test('signatures of different frame sizes still compare', () {
      // The camera can hand over a different resolution after a restart; the
      // grid is fixed, so the comparison stays meaningful.
      final small = FrameSignature.of(flat(120, width: 64, height: 64));
      final big = FrameSignature.of(flat(120, width: 128, height: 128));
      expect(small.difference(big), 0);
    });
  });

  group('MotionTracker', () {
    test('with no gyro at all, the phone counts as still', () {
      // A device with no gyroscope, or a build where the sensor stream failed
      // to start, must not be a device Buddy refuses to look at. The
      // inter-frame difference is the backstop, and it catches a moving phone
      // easily — a moving camera changes every cell at once.
      final tracker = MotionTracker();
      expect(tracker.stillAt(const Duration(seconds: 5)), isTrue);
    });

    test('a sample above the rate bound marks the phone as moving', () {
      final tracker = MotionTracker()
        ..sample(kGyroStillRate * 3, Duration.zero);
      expect(tracker.stillAt(Duration.zero), isFalse);
    });

    test('stillness is only claimed after the settle time has elapsed', () {
      final tracker = MotionTracker()
        ..sample(kGyroStillRate * 3, Duration.zero);

      // Motion blur outlives the motion, so the instant the gyro goes quiet is
      // too early to trust the picture.
      expect(tracker.stillAt(kMotionSettleTime ~/ 2), isFalse);
      expect(tracker.stillAt(kMotionSettleTime + const Duration(seconds: 1)),
          isTrue);
    });

    test('quiet samples do not reset the settle clock', () {
      final tracker = MotionTracker()..sample(kGyroStillRate * 3, Duration.zero);
      for (var ms = 10; ms < kMotionSettleTime.inMilliseconds; ms += 10) {
        tracker.sample(0.001, Duration(milliseconds: ms));
      }
      expect(tracker.stillAt(kMotionSettleTime + const Duration(seconds: 1)),
          isTrue);
    });
  });

  group('FrameGate', () {
    /// A converter that never actually converts: it returns a 1x1 frame whose
    /// single pixel encodes the mean luma it was handed, so a test can tell
    /// WHICH frame came out the far end without doing real colour work.
    Future<Frame> tinyConvert(YuvFrame planes) async {
      final level = planes.y[0];
      return Frame(Uint8List.fromList([level, level, level]), 1, 1);
    }

    test('the first frame is never stable — there is nothing to compare it to',
        () async {
      final gate = FrameGate(converter: tinyConvert);
      addTearDown(gate.dispose);
      final seen = <ObservedFrame>[];
      gate.frames.listen(seen.add);

      gate.offer(flat(120), Duration.zero);
      await pumpEventQueue();

      expect(seen.single.isStable, isFalse);
      expect(seen.single.sceneChange, 1.0);
    });

    test('a quiet run of frames becomes stable, and says the phone is still',
        () async {
      final gate = FrameGate(converter: tinyConvert);
      addTearDown(gate.dispose);
      final seen = <ObservedFrame>[];
      gate.frames.listen(seen.add);

      for (var i = 0; i <= kQuietFramesRequired + 1; i++) {
        gate.offer(flat(120), kObservationInterval * i);
        await pumpEventQueue();
      }

      expect(seen.last.isStable, isTrue);
      expect(seen.last.motion.deviceStill, isTrue);
      expect(seen.first.isStable, isFalse);
      // The run has to be built up, not granted on the second frame: a hand
      // held motionless mid-placement would otherwise read as a settled board.
      expect(seen.take(kQuietFramesRequired).every((f) => !f.isStable), isTrue);
    });

    test('a hand over the board breaks the run and rebuilds it', () async {
      final gate = FrameGate(converter: tinyConvert);
      addTearDown(gate.dispose);
      final seen = <ObservedFrame>[];
      gate.frames.listen(seen.add);

      var t = Duration.zero;
      Future<void> offer(YuvFrame f) async {
        gate.offer(f, t);
        t += kObservationInterval;
        await pumpEventQueue();
      }

      for (var i = 0; i <= kQuietFramesRequired + 1; i++) {
        await offer(flat(120));
      }
      expect(seen.last.isStable, isTrue);

      await offer(withBlock(120, 20, 32));
      expect(seen.last.isStable, isFalse,
          reason: 'the scene changed under a still phone');
      expect(seen.last.motion.deviceStill, isTrue,
          reason: 'the PHONE did not move — the message the user needs is '
              'about the hand, not about holding still');

      for (var i = 0; i <= kQuietFramesRequired; i++) {
        await offer(withBlock(120, 20, 32));
      }
      expect(seen.last.isStable, isTrue,
          reason: 'the new scene settled, so it is readable again');
    });

    test('a moving phone still produces frames — the light needs them',
        () async {
      // assessReadability turns MotionHint(deviceStill: false) into the amber
      // "hold still" cause. It can only do that if it is GIVEN the frame, so
      // the gate must label unstable frames rather than swallow them.
      final gate = FrameGate(converter: tinyConvert);
      addTearDown(gate.dispose);
      final seen = <ObservedFrame>[];
      gate.frames.listen(seen.add);

      var t = Duration.zero;
      for (var i = 0; i < 4; i++) {
        gate.onGyro(kGyroStillRate * 4, t);
        gate.offer(flat(120), t);
        t += kObservationInterval;
        await pumpEventQueue();
      }

      expect(seen, isNotEmpty);
      expect(seen.every((f) => !f.motion.deviceStill), isTrue);
      expect(seen.every((f) => !f.isStable), isTrue);
    });

    test('stableFrames is the filtered view the session subscribes to',
        () async {
      final gate = FrameGate(converter: tinyConvert);
      addTearDown(gate.dispose);
      final stable = <ObservedFrame>[];
      gate.stableFrames.listen(stable.add);

      for (var i = 0; i <= kQuietFramesRequired + 2; i++) {
        gate.offer(flat(120), kObservationInterval * i);
        await pumpEventQueue();
      }

      expect(stable, isNotEmpty);
      expect(stable.every((f) => f.isStable), isTrue);
    });

    test('frames arriving faster than the observation interval are thinned',
        () async {
      final gate = FrameGate(converter: tinyConvert);
      addTearDown(gate.dispose);
      final seen = <ObservedFrame>[];
      gate.frames.listen(seen.add);

      // A camera at 30fps over one observation interval.
      for (var i = 0; i < 30; i++) {
        gate.offer(flat(120), kObservationInterval ~/ 30 * i);
        await pumpEventQueue();
      }

      expect(seen.length, 1,
          reason: 'converting 30 frames a second is work nobody asked for');
    });

    test('the quiet run is measured on EVERY frame, not just converted ones',
        () async {
      // The thinning above must not blind the gate: a hand that appears and
      // disappears between two converted frames still has to break the run.
      final gate = FrameGate(converter: tinyConvert);
      addTearDown(gate.dispose);
      final seen = <ObservedFrame>[];
      gate.frames.listen(seen.add);

      var t = Duration.zero;
      for (var i = 0; i <= kQuietFramesRequired + 2; i++) {
        t = kObservationInterval * i;
        gate.offer(flat(120), t);
        await pumpEventQueue();
      }
      expect(seen.last.isStable, isTrue);

      // A hand appears a quarter of an interval after the last converted
      // frame — too soon to be converted, so nothing is published for it.
      final before = seen.length;
      gate.offer(withBlock(120, 20, 32), t + kObservationInterval ~/ 4);
      await pumpEventQueue();
      expect(seen.length, before,
          reason: 'that frame was thinned away, as intended');

      // The next frame a full interval later IS converted — and it must come
      // out unstable, because the run was broken by a frame nobody converted.
      // Read the signature AFTER the throttle and this frame looks identical
      // to the last one anybody saw, and the gate hands the session a board it
      // never actually watched settle.
      gate.offer(flat(120), t + kObservationInterval);
      await pumpEventQueue();

      expect(seen.length, before + 1);
      expect(seen.last.isStable, isFalse,
          reason: 'the run was broken by a frame nobody converted');
    });
  });

  group('the drop policy', () {
    test('while one conversion is in flight, only the NEWEST arrival waits',
        () async {
      final started = <int>[];
      final gates = <Completer<void>>[];
      final pipeline = LatestOnlyPipeline<int, int>((n) async {
        started.add(n);
        final c = Completer<void>();
        gates.add(c);
        await c.future;
        return n;
      });
      addTearDown(pipeline.close);

      final out = <int>[];
      pipeline.output.listen(out.add);

      pipeline.submit(1);
      await pumpEventQueue();
      expect(started, [1]);

      pipeline.submit(2);
      pipeline.submit(3);
      pipeline.submit(4);
      await pumpEventQueue();

      expect(started, [1], reason: 'nothing starts while 1 is in flight');
      expect(pipeline.dropped, 2, reason: '2 and 3 were superseded by 4');

      gates.removeAt(0).complete();
      await pumpEventQueue();

      expect(started, [1, 4], reason: 'the newest arrival wins, not the oldest');
      gates.removeAt(0).complete();
      await pumpEventQueue();
      expect(out, [1, 4]);
    });

    test('a conversion that throws does not wedge the pipeline', () async {
      var calls = 0;
      final pipeline = LatestOnlyPipeline<int, int>((n) async {
        calls++;
        if (n == 1) throw StateError('bad frame');
        return n;
      });
      addTearDown(pipeline.close);

      final out = <int>[];
      pipeline.output.listen(out.add);

      pipeline.submit(1);
      await pumpEventQueue();
      pipeline.submit(2);
      await pumpEventQueue();

      expect(calls, 2);
      expect(out, [2]);
      expect(pipeline.failures, 1);
    });

    test('nothing is emitted after close', () async {
      final pipeline = LatestOnlyPipeline<int, int>((n) async => n);
      final out = <int>[];
      pipeline.output.listen(out.add);
      await pipeline.close();
      pipeline.submit(1);
      await pumpEventQueue();
      expect(out, isEmpty);
    });
  });

  group('the real isolate converter', () {
    test('converts off the main isolate and comes back byte-identical',
        () async {
      // The one test that actually spawns. The point of the isolate is that a
      // 1280x720 YUV→RGB pass is ~900k pixels of floating-point work, which on
      // the UI thread is a visible hitch every observation interval.
      final planes = withBlock(60, 200, 16);
      final viaIsolate = await convertFrameInIsolate(planes);
      final direct = planes.toFrame();

      expect(viaIsolate.width, direct.width);
      expect(viaIsolate.height, direct.height);
      expect(viaIsolate.rgb, direct.rgb);
    });
  });
}
