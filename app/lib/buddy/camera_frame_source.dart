import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:board_vision/board_vision.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

// -----------------------------------------------------------------------------
// The provisional numbers.
//
// None of the five constants below can be measured from this machine: they are
// properties of a phone's sensor, a phone's gyroscope and a room with a
// backgammon board in it, and there is no device in this environment. Each one
// therefore ships with the arithmetic that produced it, so the on-device
// protocol in Task 15 has something to disagree WITH rather than a number to
// re-guess from nothing.
// -----------------------------------------------------------------------------

/// Cells per side in the change-detection grid. 16 → 256 cells.
///
/// The grid, not the pixels: comparing full frames would be both slower and
/// worse, because per-pixel sensor noise is exactly the signal a change
/// detector must ignore. Averaging a cell divides that noise by the square root
/// of the sample count while leaving a hand-sized change untouched.
const int kSignatureGrid = 16;

/// Luma samples taken per cell, per axis (so up to 144 per cell).
///
/// Sets the noise floor. A decent sensor at office light has a per-pixel
/// temporal sigma around 2 grey levels; averaging 144 samples brings a cell's
/// sigma to ~0.17, and the difference of two cells to ~0.24 — call it 0.1% of
/// full scale, which is where [kSceneQuietThreshold] gets its headroom from.
/// Cost is 256 * 144 ≈ 37k byte reads per frame, on the platform thread, which
/// is nothing next to the conversion it is deciding whether to run.
const int kSignatureSamplesPerAxis = 12;

/// How much a frame may differ from the one before it and still count as quiet,
/// as a mean absolute luma difference over [kSignatureGrid]² cells, normalized
/// to 0..1.
///
/// **Provisional — Task 15's on-device protocol is where this gets measured.**
/// The derivation it ships with:
///
///  * *Noise floor* (must be BELOW this): ~0.001, per
///    [kSignatureSamplesPerAxis].
///  * *A hand over the board* (must be ABOVE this): an arm covering a quarter
///    of the picture and darkening it by ~100 levels is a mean difference of
///    0.25 * 100/255 ≈ 0.098 — a hundredfold margin. This is the case that
///    actually matters, because it is what the gate exists to wait out.
///  * *One checker moving* sits at roughly 0.002 (two cells of 256 changing by
///    ~60 levels), which is BELOW the bound on purpose: the gate's job is to
///    find a settled board, and a board that settled one checker ago is
///    settled. `matchLegalPlay` is what notices the checker.
///
/// 0.004 sits four times over the noise floor and twenty-five times under a
/// hand. The number is loose because the two things it separates are three
/// orders of magnitude apart; what would move it is a noisier sensor in a dim
/// room, which is the measurement Task 15 makes.
const double kSceneQuietThreshold = 0.004;

/// Consecutive quiet frames required before a scene counts as settled.
///
/// **Provisional.** One quiet pair is not enough: a hand pausing over the board
/// mid-placement produces one, and reading the board then would fold a
/// half-finished play. Three at [kObservationInterval] apart is ~0.75s of
/// nothing happening, which is longer than a pause and shorter than a user
/// waiting.
const int kQuietFramesRequired = 3;

/// Gyroscope magnitude, in radians per second, below which the phone counts as
/// held still.
///
/// **Provisional.** A phone resting on a stand reads sensor noise of roughly
/// 0.01–0.05 rad/s; a hand adjusting it is comfortably over 0.5. 0.12 rad/s
/// (~7°/s) sits between them with room on both sides.
const double kGyroStillRate = 0.12;

/// How long the gyro must stay under [kGyroStillRate] before the picture is
/// trusted.
///
/// **Provisional.** Motion blur outlives the motion that caused it — the
/// sensor's exposure window and the autofocus hunt that follows a nudge both
/// run on past the gyro going quiet. 350ms is a guess at the sum of a ~1/30s
/// exposure and a focus settle.
const Duration kMotionSettleTime = Duration(milliseconds: 350);

/// How often a frame is actually converted and published.
///
/// The camera delivers 30 a second and perception wants a handful; this is the
/// throttle that makes the difference someone else's problem. **Not**
/// provisional in the same way as the others — it is a deliberate budget rather
/// than a measurement — but Task 15 may still find that a readability light
/// updating four times a second feels twitchy.
const Duration kObservationInterval = Duration(milliseconds: 250);

// -----------------------------------------------------------------------------
// Pure: everything below here runs in `flutter test` with no device attached.
// -----------------------------------------------------------------------------

/// One camera image reduced to plain bytes, with the plugin left behind.
///
/// The seam between `package:camera` and `package:board_vision`. Everything
/// downstream — the gate, the signature, the isolate — speaks this, so all of
/// it is testable from synthetic planes.
@immutable
class YuvFrame {
  const YuvFrame({
    required this.y,
    required this.u,
    required this.v,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });

  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int width;
  final int height;

  /// Bytes per luma row, which on Android is routinely GREATER than [width].
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  /// Reads a `CameraImage` without copying a byte.
  ///
  /// Handles both layouts the plugin delivers, which are not the same shape:
  ///
  ///  * **Android** (`YUV_420_888`) gives THREE planes. Chroma may be planar
  ///    (`bytesPerPixel` 1) or semi-planar (2); the luma plane carries
  ///    `bytesPerRow` padding often enough that ignoring it is the classic
  ///    version of this bug — the picture shears diagonally and every later
  ///    measurement is quietly wrong.
  ///  * **iOS** (`kCVPixelFormatType_420YpCbCr8BiPlanar…`) gives TWO: luma, and
  ///    one interleaved CbCr plane. `Frame.fromYuv420` already understands that
  ///    layout, as pixel stride 2 with V a one-byte-offset VIEW of the same
  ///    buffer — so this builds the views rather than repacking, and
  ///    `Uint8List.sublistView` makes that free.
  factory YuvFrame.fromCameraImage(CameraImage image) {
    if (image.format.group != ImageFormatGroup.yuv420) {
      throw ArgumentError.value(
        image.format.group,
        'image.format.group',
        'Buddy Mode requests yuv420 from the camera; this frame is a format '
            'board_vision cannot read',
      );
    }
    final planes = image.planes;
    final luma = planes.first;
    if (planes.length == 2) {
      final uv = planes[1];
      return YuvFrame(
        y: luma.bytes,
        u: uv.bytes,
        v: Uint8List.sublistView(uv.bytes, 1),
        width: image.width,
        height: image.height,
        yRowStride: luma.bytesPerRow,
        uvRowStride: uv.bytesPerRow,
        uvPixelStride: 2,
      );
    }
    if (planes.length < 3) {
      throw ArgumentError('a yuv420 image needs 2 or 3 planes, '
          'got ${planes.length}');
    }
    return YuvFrame(
      y: luma.bytes,
      u: planes[1].bytes,
      v: planes[2].bytes,
      width: image.width,
      height: image.height,
      yRowStride: luma.bytesPerRow,
      uvRowStride: planes[1].bytesPerRow,
      uvPixelStride: planes[1].bytesPerPixel ?? 1,
    );
  }

  /// The RGB frame `board_vision` reads. ~900k pixels of floating-point work at
  /// 1280x720 — see [convertFrameInIsolate] for where it should actually run.
  Frame toFrame() => Frame.fromYuv420(
        y: y,
        u: u,
        v: v,
        width: width,
        height: height,
        yRowStride: yRowStride,
        uvRowStride: uvRowStride,
        uvPixelStride: uvPixelStride,
      );

  /// The luma byte at [x], [y], honouring [yRowStride].
  int lumaAt(int x, int py) => y[py * yRowStride + x];
}

/// A frame boiled down to [kSignatureGrid]² cell averages, for change detection.
///
/// Deliberately resolution-independent: the grid divides whatever picture it is
/// given, so a camera that comes back at a different resolution after a restart
/// still produces comparable signatures instead of a spurious "everything
/// moved".
@immutable
class FrameSignature {
  const FrameSignature._(this.cells);

  final Float32List cells;

  factory FrameSignature.of(YuvFrame frame) {
    final cells = Float32List(kSignatureGrid * kSignatureGrid);
    var c = 0;
    for (var gy = 0; gy < kSignatureGrid; gy++) {
      final y0 = gy * frame.height ~/ kSignatureGrid;
      final y1 = math.max(y0 + 1, (gy + 1) * frame.height ~/ kSignatureGrid);
      final rows = math.min(y1 - y0, kSignatureSamplesPerAxis);
      for (var gx = 0; gx < kSignatureGrid; gx++) {
        final x0 = gx * frame.width ~/ kSignatureGrid;
        final x1 = math.max(x0 + 1, (gx + 1) * frame.width ~/ kSignatureGrid);
        final cols = math.min(x1 - x0, kSignatureSamplesPerAxis);
        var sum = 0;
        for (var r = 0; r < rows; r++) {
          // Sampled at cell centres rather than corners so a cell that is one
          // pixel tall still lands INSIDE itself.
          final py = y0 + ((2 * r + 1) * (y1 - y0)) ~/ (2 * rows);
          for (var col = 0; col < cols; col++) {
            final px = x0 + ((2 * col + 1) * (x1 - x0)) ~/ (2 * cols);
            sum += frame.lumaAt(px, py);
          }
        }
        cells[c++] = sum / (rows * cols);
      }
    }
    return FrameSignature._(cells);
  }

  /// Mean absolute per-cell difference, normalized to 0..1 — the number
  /// [kSceneQuietThreshold] is a bound on.
  double difference(FrameSignature other) {
    var total = 0.0;
    for (var i = 0; i < cells.length; i++) {
      total += (cells[i] - other.cells[i]).abs();
    }
    return total / (cells.length * 255);
  }
}

/// Gyro history, reduced to the one bit `board_vision` asks for.
///
/// **A device with no gyroscope reads as STILL**, not as moving. A missing
/// sensor, a stream that failed to start, a permission-free platform that
/// simply has none: any of those, treated as "moving", would leave Buddy
/// refusing to look at the board forever. The inter-frame difference is a
/// perfectly good backstop for a moving phone — a camera in motion changes
/// every cell of the signature at once — so the sensor is an accelerator here,
/// not a dependency.
class MotionTracker {
  MotionTracker({
    this.stillRate = kGyroStillRate,
    this.settleTime = kMotionSettleTime,
  });

  final double stillRate;
  final Duration settleTime;

  Duration? _lastMotion;

  /// Feeds one gyroscope reading: [magnitude] in rad/s, [at] on the frame
  /// clock.
  void sample(double magnitude, Duration at) {
    if (magnitude >= stillRate) _lastMotion = at;
  }

  /// Whether the phone counts as held still as of [now].
  bool stillAt(Duration now) {
    final last = _lastMotion;
    return last == null || now - last >= settleTime;
  }

  MotionHint hintAt(Duration now) => MotionHint(deviceStill: stillAt(now));
}

/// One frame that made it through the gate, and what the gate thinks of it.
@immutable
class ObservedFrame {
  const ObservedFrame({
    required this.frame,
    required this.motion,
    required this.isStable,
    required this.sceneChange,
    required this.at,
  });

  /// The RGB frame, ready for any `BoardVision` query.
  final Frame frame;

  /// What the GYRO says — nothing else. Handed straight to
  /// `BoardVision.assessReadability`, which turns a false [MotionHint] into the
  /// amber "hold still" cause. Deliberately not folded together with
  /// [sceneChange]: a hand moving over a phone that never budged must not tell
  /// the user to hold the phone still.
  final MotionHint motion;

  /// Whether this frame may answer a perception QUERY: the phone was still
  /// AND the picture has stopped changing for [kQuietFramesRequired] frames.
  ///
  /// An unstable frame is still published, because the readability light is
  /// exactly what a user needs while things are unstable.
  final bool isStable;

  /// Measured difference from the previous frame, 0..1. 1.0 for the first
  /// frame of a session, which has nothing to be compared with.
  final double sceneChange;

  final Duration at;
}

/// Converts [YuvFrame]s, running at most one at a time and keeping only the
/// NEWEST arrival while it is busy.
///
/// **Drop, never queue.** Perception is slower than the camera by an order of
/// magnitude, so a queue would grow without bound and hand the session frames
/// describing a board that has since been played on — the worst possible input
/// for a system whose whole job is to say what the board looks like NOW. When
/// something is in flight, a new arrival replaces the one waiting behind it and
/// [dropped] counts the loss; a stale frame is worth less than nothing.
class LatestOnlyPipeline<I, O> {
  LatestOnlyPipeline(this._convert);

  final Future<O> Function(I) _convert;
  final _out = StreamController<O>.broadcast();

  /// At most one element. A list rather than an `I?` because `I` may itself be
  /// nullable, and "no pending frame" must not alias "a pending null".
  final List<I> _pending = [];

  bool _busy = false;
  bool _closed = false;
  int _dropped = 0;
  int _failures = 0;

  /// Arrivals thrown away because a newer one landed first.
  int get dropped => _dropped;

  /// Conversions that threw. They are absorbed, not propagated: one unreadable
  /// frame must not end the session.
  int get failures => _failures;

  Stream<O> get output => _out.stream;

  void submit(I input) {
    if (_closed) return;
    if (_pending.isNotEmpty) {
      _pending.clear();
      _dropped++;
    }
    _pending.add(input);
    if (!_busy) unawaited(_drain());
  }

  Future<void> _drain() async {
    _busy = true;
    try {
      while (_pending.isNotEmpty && !_closed) {
        final next = _pending.removeLast();
        try {
          final result = await _convert(next);
          if (!_closed && !_out.isClosed) _out.add(result);
        } catch (error, stack) {
          _failures++;
          if (kDebugMode) {
            debugPrint('frame conversion failed: $error\n$stack');
          }
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    await _out.close();
  }
}

/// How a [FrameGate] turns planes into a frame. A seam so tests need no
/// isolate and the isolate needs no test double.
typedef FrameConverter = Future<Frame> Function(YuvFrame planes);

/// Converts on a worker isolate. The production [FrameConverter].
///
/// One `Isolate.run` per admitted frame rather than a long-lived worker,
/// because the gate upstream admits ~4 frames a second (see
/// [kObservationInterval]) and a spawn is well under a millisecond against a
/// conversion that is closer to ten. Both the planes in and the RGB out are
/// copied across the boundary; at 1280x720 that is ~1.4MB each way per frame,
/// which is the price of keeping ~900k pixels of float work off the thread that
/// draws the camera preview. `TransferableTypedData` would remove the copies
/// and is the obvious thing to reach for if Task 15 measures a problem.
Future<Frame> convertFrameInIsolate(YuvFrame planes) =>
    Isolate.run(planes.toFrame);

/// The stable-frame gate: everything about the camera pipeline EXCEPT the two
/// plugins.
///
/// Fed by [CameraFrameSource] on a device and by a synthetic stream in tests,
/// which is the whole point of the split — the gating rules are where the bugs
/// live and the subscription wiring is where the plugins live, and only one of
/// those can be exercised here.
///
/// The rules, in order:
///
/// 1. **Every** offered frame updates the signature and the quiet run. Thinning
///    happens after this, so a hand that appears between two converted frames
///    still breaks the run.
/// 2. A frame closer than [kObservationInterval] to the last converted one is
///    dropped — the camera's 30fps is thirty times what perception wants.
/// 3. Survivors are converted (off-thread) and published on [frames], carrying
///    a [MotionHint] from the gyro and an `isStable` bit that is gyro-still AND
///    scene-quiet.
class FrameGate {
  FrameGate({
    FrameConverter? converter,
    MotionTracker? motion,
    this.quietThreshold = kSceneQuietThreshold,
    this.quietFramesRequired = kQuietFramesRequired,
    this.observationInterval = kObservationInterval,
  })  : _motion = motion ?? MotionTracker(),
        _pipeline = LatestOnlyPipeline<_Pending, ObservedFrame>(
          (pending) async => ObservedFrame(
            frame: await (converter ?? convertFrameInIsolate)(pending.planes),
            motion: pending.motion,
            isStable: pending.isStable,
            sceneChange: pending.sceneChange,
            at: pending.at,
          ),
        );

  final double quietThreshold;
  final int quietFramesRequired;
  final Duration observationInterval;

  final MotionTracker _motion;
  final LatestOnlyPipeline<_Pending, ObservedFrame> _pipeline;

  FrameSignature? _previous;
  int _quietRun = 0;
  Duration? _lastConverted;

  /// Every published frame, stable or not. The readability light wants the
  /// unstable ones — they are what it has to explain.
  Stream<ObservedFrame> get frames => _pipeline.output;

  /// The filtered view a perception query subscribes to.
  Stream<ObservedFrame> get stableFrames =>
      frames.where((f) => f.isStable);

  /// Frames dropped by the newest-wins policy.
  int get dropped => _pipeline.dropped;

  /// Feeds one gyroscope reading. Magnitude in rad/s.
  void onGyro(double magnitude, Duration at) => _motion.sample(magnitude, at);

  /// Feeds one camera frame. Cheap, and safe to call at the camera's full rate.
  void offer(YuvFrame planes, Duration at) {
    // The signature and the quiet run are updated on EVERY frame, BEFORE the
    // thinning below. A hand that appears and vanishes between two converted
    // frames still has to break the run; read the signature after the throttle
    // instead and the gate hands the session a board it never watched settle.
    final signature = FrameSignature.of(planes);
    final previous = _previous;
    // The first frame of a session has nothing behind it, so it is maximally
    // changed by definition — never stable, which is the honest answer.
    final change = previous == null ? 1.0 : signature.difference(previous);
    _previous = signature;
    _quietRun = change <= quietThreshold ? _quietRun + 1 : 0;

    final last = _lastConverted;
    if (last != null && at - last < observationInterval) return;
    _lastConverted = at;

    _pipeline.submit(_Pending(
      planes: planes,
      motion: _motion.hintAt(at),
      isStable: _motion.stillAt(at) && _quietRun >= quietFramesRequired,
      sceneChange: change,
      at: at,
    ));
  }

  Future<void> dispose() => _pipeline.close();
}

/// A frame on its way through the pipeline, with the verdict already attached.
///
/// The verdict is computed BEFORE the conversion and carried along, not
/// recomputed after: by the time the isolate comes back the gate has seen more
/// frames, and re-deriving stability then would answer a question about a
/// different moment than the picture shows.
@immutable
class _Pending {
  const _Pending({
    required this.planes,
    required this.motion,
    required this.isStable,
    required this.sceneChange,
    required this.at,
  });

  final YuvFrame planes;
  final MotionHint motion;
  final bool isStable;
  final double sceneChange;
  final Duration at;
}

// -----------------------------------------------------------------------------
// The plugin edge. Nothing below here runs in `flutter test`.
// -----------------------------------------------------------------------------

/// Wires `package:camera` and `package:sensors_plus` into a [FrameGate].
///
/// Deliberately thin, and deliberately the only untested code in this file: it
/// subscribes to two streams, converts what they deliver into plugin-free
/// values, and hands them over. Every decision — what is stable, what is
/// dropped, what a frame is worth — lives in [FrameGate] above, where a test
/// can reach it. The camera plugin cannot start in a test process at all, so
/// the alternative to this split is not a better test; it is no test.
///
/// The gyroscope's magnitude is the L2 norm of its three axes, and the frame
/// clock is the source's own stopwatch: the camera plugin does not hand over a
/// timestamp on either platform, and the sensor stream's own timestamps are on
/// a different base again, so one monotonic clock read at arrival is the only
/// thing the two streams can honestly share.
class CameraFrameSource {
  CameraFrameSource({FrameGate? gate}) : gate = gate ?? FrameGate();

  final FrameGate gate;
  final _clock = Stopwatch();

  StreamSubscription<GyroscopeEvent>? _gyro;
  CameraController? _controller;

  Stream<ObservedFrame> get frames => gate.frames;
  Stream<ObservedFrame> get stableFrames => gate.stableFrames;

  /// Starts streaming from an already-initialized [controller].
  ///
  /// The controller is the caller's: the calibration screen needs the same one
  /// for its preview, and two controllers on one camera is a platform error on
  /// both OSes.
  Future<void> start(CameraController controller) async {
    if (_controller != null) return;
    _controller = controller;
    _clock.start();
    _gyro = gyroscopeEventStream().listen(
      (event) => gate.onGyro(
        math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z),
        _clock.elapsed,
      ),
      // A phone with no gyroscope is a phone Buddy still works on — see
      // [MotionTracker]. Losing the stream must not be louder than that.
      onError: (Object error) {
        if (kDebugMode) debugPrint('gyroscope unavailable: $error');
      },
      cancelOnError: true,
    );
    await controller.startImageStream(_onImage);
  }

  void _onImage(CameraImage image) {
    try {
      gate.offer(YuvFrame.fromCameraImage(image), _clock.elapsed);
    } catch (error) {
      // A frame in an unexpected format is one frame, not a session. The
      // readability light is what tells the user something is wrong, and it
      // needs the source to still be alive to do it.
      if (kDebugMode) debugPrint('unreadable camera frame: $error');
    }
  }

  Future<void> stop() async {
    await _gyro?.cancel();
    _gyro = null;
    final controller = _controller;
    _controller = null;
    _clock.stop();
    if (controller != null && controller.value.isStreamingImages) {
      try {
        await controller.stopImageStream();
      } catch (_) {
        // Stopping a stream on a controller the platform already tore down
        // throws; there is nothing left to clean up if it does.
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    await gate.dispose();
  }
}

/// The image format Buddy Mode asks the camera for.
///
/// `yuv420` on both platforms, which is what [YuvFrame.fromCameraImage] and
/// `Frame.fromYuv420` are written against — Android delivers `YUV_420_888` and
/// iOS the bi-planar full-range flavour, and the conversion handles both. NOT
/// `bgra8888`: it would skip a conversion, but it also triples the bytes
/// crossing the platform boundary thirty times a second.
const ImageFormatGroup kBuddyImageFormat = ImageFormatGroup.yuv420;
