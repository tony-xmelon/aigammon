import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:board_vision/board_vision.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'observed_frame.dart';

/// Re-exported so every caller that already had a frame source in scope keeps
/// working — the value type moved out of this file to keep two plugins off the
/// session's import graph, which is a fact about packaging rather than about
/// anything a caller does. See `observed_frame.dart`.
export 'observed_frame.dart';

// -----------------------------------------------------------------------------
// The provisional numbers.
//
// Seven constants follow. FOUR of them — the quiet threshold, the quiet run,
// the gyro rate and the settle time — cannot be measured from this machine at
// all: they are properties of a phone's sensor, a phone's gyroscope and a room
// with a backgammon board in it, and there is no device in this environment.
// Each of those is marked **Provisional** and ships with the arithmetic that
// produced it, so the on-device protocol in Task 15 has something to disagree
// WITH rather than a number to re-guess from nothing. The observation interval
// says out loud that it is NOT provisional in that sense — it is a budget, not
// a measurement — and the two grid constants are derived here from noise
// arithmetic that needs no device.
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
/// half-finished play.
///
/// **What it gates is ~100ms, not the ~0.75s this doc used to claim.** The
/// quiet run is updated on every frame [FrameGate.offer] is handed, BEFORE the
/// throttle (rule 1 there) — so three of them is three frames at the CAMERA's
/// rate, which is 3/30 ≈ 0.1s on a phone, not the 0.75s that three frames
/// [kObservationInterval] apart would be. The old arithmetic counted the wrong
/// cadence, and no test caught it because every test in
/// `camera_frame_source_test.dart` offers frames exactly one observation
/// interval apart, which is the one rate at which the two readings coincide.
///
/// Left at 3 regardless, and the correction cuts in the attention nudge's
/// favour rather than against it: if a settled board is reachable a tenth of a
/// second after the dice stop, then the 250ms throttle rather than this run is
/// the dominant wait between a throw landing and a frame that can be read —
/// and that wait is exactly what [FrameGate.attend] removes. Moving the number
/// now would be trading a measurement nobody has for a different guess. What
/// SHOULD move it is Task 15's on-device protocol, which is the first place a
/// mid-placement pause can be timed against a real frame rate; whatever it
/// answers has to be written down with the sampling rate beside it, because
/// this constant is a count of frames and means nothing without one.
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

/// Consecutive conversion failures after which the pipeline stops calling it
/// bad luck and says so on [FrameGate.faults].
///
/// **Not provisional either** — it is a shape, not a measurement. One frame
/// that will not convert is a frame; five in a row at [kObservationInterval]
/// apart is 1.25 seconds in which nothing the camera produced could be read,
/// and every cause of that is systemic (the wrong pixel format, a plane layout
/// nobody anticipated, an isolate that will not spawn) rather than transient.
/// Low enough to fire long before a user gives up on a preview that is doing
/// nothing; high enough that a burst of odd frames during a resolution change
/// does not cry wolf.
const int kConversionFailureLimit = 5;

/// How often a frame is actually converted and published.
///
/// The camera delivers 30 a second and perception wants a handful; this is the
/// throttle that makes the difference someone else's problem. **Not**
/// provisional in the same way as the others — it is a deliberate budget rather
/// than a measurement — but Task 15 may still find that a readability light
/// updating four times a second feels twitchy.
const Duration kObservationInterval = Duration(milliseconds: 250);

/// How often frames are converted while the gate has been told to pay
/// attention. See [FrameGate.attend].
///
/// **A budget, not a measurement.** A third of [kObservationInterval], so the
/// gate looks around twelve times a second rather than four for as long as
/// something has just happened. It cannot run away with the device: the
/// pipeline underneath drops rather than queues (see [LatestOnlyPipeline]), so
/// offering faster than conversions complete costs dropped arrivals rather than
/// a growing backlog, and [kAttentionWindow] bounds the whole episode anyway.
const Duration kAttentionInterval = Duration(milliseconds: 80);

/// How long one nudge keeps the gate at [kAttentionInterval].
///
/// **A budget, not a measurement**, derived from what a hand does after a
/// throw: the dice have landed, and what stands between the gate and a settled
/// frame is the arm withdrawing from over the board. A second and a half covers
/// an unhurried withdrawal and stops well short of the user's thinking time,
/// which is the part of a turn there is nothing to watch for.
const Duration kAttentionWindow = Duration(milliseconds: 1500);

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
    this.videoRange = false,
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

  /// Whether these planes are on the STUDIO scale (luma 16..235) rather than
  /// the full 0..255 one — true on iOS, false on Android.
  ///
  /// Not a setting and not a guess: `camera_avfoundation` hard-codes
  /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` for its `yuv420` format
  /// and exposes no way to ask for the FullRange twin, while Android forwards
  /// `YUV_420_888` as the sensor produced it, which is full range by
  /// convention. So the flag is derived from the plane count in
  /// [YuvFrame.fromCameraImage] — two planes IS the bi-planar VideoRange
  /// format — and defaults false everywhere else, because every other producer
  /// of these planes (tests, the synthetic renderer) works in full range.
  ///
  /// Getting it wrong loses 14% of the contrast margin and permanently
  /// disables `ReadabilityCause.tooBright`; `Frame.fromYuv420` carries the
  /// measurement.
  final bool videoRange;

  /// Reads a `CameraImage` without copying a byte.
  ///
  /// Handles both layouts the plugin delivers, which are not the same shape:
  ///
  ///  * **Android** (`YUV_420_888`) gives THREE planes. Chroma may be planar
  ///    (`bytesPerPixel` 1) or semi-planar (2); the luma plane carries
  ///    `bytesPerRow` padding often enough that ignoring it is the classic
  ///    version of this bug — the picture shears diagonally and every later
  ///    measurement is quietly wrong.
  ///  * **iOS** (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) gives TWO:
  ///    luma, and one interleaved CbCr plane. `Frame.fromYuv420` already
  ///    understands that layout, as pixel stride 2 with V a one-byte-offset
  ///    VIEW of the same buffer — so this builds the views rather than
  ///    repacking, and `Uint8List.sublistView` makes that free.
  ///
  /// The plane count carries a second fact besides the layout: it is also how
  /// the SIGNAL RANGE is known. Two planes means the bi-planar iOS format,
  /// which `camera_avfoundation` only ever creates in its VideoRange flavour;
  /// three means Android's `YUV_420_888`, full range by convention. See
  /// [videoRange].
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
        videoRange: true,
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
      videoRange: false,
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
        videoRange: videoRange,
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
  LatestOnlyPipeline(this._convert, {this.failureLimit = kConversionFailureLimit});

  /// Consecutive failures that constitute a [FrameConversionFault].
  final int failureLimit;

  final Future<O> Function(I) _convert;
  final _out = StreamController<O>.broadcast();
  final _faults = StreamController<FrameConversionFault>.broadcast();

  /// At most one element. A list rather than an `I?` because `I` may itself be
  /// nullable, and "no pending frame" must not alias "a pending null".
  final List<I> _pending = [];

  bool _busy = false;
  bool _closed = false;
  int _dropped = 0;
  int _failures = 0;
  int _streak = 0;

  /// Arrivals thrown away because a newer one landed first.
  int get dropped => _dropped;

  /// Conversions that threw. They are absorbed, not propagated: one unreadable
  /// frame must not end the session.
  int get failures => _failures;

  /// Failures since the last conversion that worked. Readable at any time, so
  /// a caller that attached after the fault fired can still find out.
  int get consecutiveFailures => _streak;

  Stream<O> get output => _out.stream;

  /// Fires once when [consecutiveFailures] reaches [failureLimit], and not
  /// again until a conversion succeeds and breaks the streak.
  ///
  /// **Once per episode, not once per frame.** A pipeline that is broken is
  /// broken at four frames a second, and a fault repeated at that rate is a
  /// log to scroll past rather than a signal to act on. Separate from [output]
  /// rather than an error event on it, because a listener that only wants
  /// frames must not have to write an `onError` to avoid an uncaught
  /// asynchronous error.
  Stream<FrameConversionFault> get faults => _faults.stream;

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
          _streak = 0;
          if (!_closed && !_out.isClosed) _out.add(result);
        } catch (error, stack) {
          _failures++;
          _streak++;
          if (kDebugMode) {
            debugPrint('frame conversion failed: $error\n$stack');
          }
          if (_streak == failureLimit && !_closed && !_faults.isClosed) {
            _faults.add(FrameConversionFault(
              error: error,
              stackTrace: stack,
              consecutiveFailures: _streak,
            ));
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
    await _faults.close();
  }
}

/// Said once when a run of [kConversionFailureLimit] frames in a row failed to
/// convert — the signal that the camera pipeline is not merely unlucky.
///
/// Deliberately plumbing rather than a screen: what a session DOES about it
/// (say something, offer recalibration, fall back to manual entry) is Task 11's
/// and Task 13's to decide. What this file owes them is that the condition is
/// observable at all, because the alternative — the per-frame `catch` on its
/// own — prints in debug mode and is perfectly silent in the build a user has.
@immutable
class FrameConversionFault {
  const FrameConversionFault({
    required this.error,
    required this.stackTrace,
    required this.consecutiveFailures,
  });

  /// What the most recent conversion threw.
  final Object error;
  final StackTrace stackTrace;

  /// How many in a row had failed when this was raised.
  final int consecutiveFailures;

  @override
  String toString() =>
      'FrameConversionFault($consecutiveFailures in a row: $error)';
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
///
/// Rule 2 is the only one [attend] touches, and that is the whole safety
/// argument for the microphone: a nudge can make the gate look SOONER and never
/// make it believe more.
class FrameGate {
  FrameGate({
    FrameConverter? converter,
    MotionTracker? motion,
    this.quietThreshold = kSceneQuietThreshold,
    this.quietFramesRequired = kQuietFramesRequired,
    this.observationInterval = kObservationInterval,
    this.attentionInterval = kAttentionInterval,
    this.attentionWindow = kAttentionWindow,
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
  final Duration attentionInterval;
  final Duration attentionWindow;

  final MotionTracker _motion;
  final LatestOnlyPipeline<_Pending, ObservedFrame> _pipeline;

  FrameSignature? _previous;
  int _quietRun = 0;
  Duration? _lastConverted;

  /// A nudge that has arrived and not yet met a frame. See [attend].
  bool _attentionPending = false;

  /// When the current attention window runs out, on the frame clock.
  Duration? _attentionUntil;

  /// Every published frame, stable or not. The readability light wants the
  /// unstable ones — they are what it has to explain.
  Stream<ObservedFrame> get frames => _pipeline.output;

  /// The filtered view a perception query subscribes to.
  Stream<ObservedFrame> get stableFrames =>
      frames.where((f) => f.isStable);

  /// Frames dropped by the newest-wins policy.
  int get dropped => _pipeline.dropped;

  /// Raised when [kConversionFailureLimit] frames in a row fail to convert.
  /// See [LatestOnlyPipeline.faults].
  Stream<FrameConversionFault> get faults => _pipeline.faults;

  /// Conversion failures since the last one that worked.
  int get consecutiveFailures => _pipeline.consecutiveFailures;

  /// Feeds one gyroscope reading. Magnitude in rad/s.
  void onGyro(double magnitude, Duration at) => _motion.sample(magnitude, at);

  /// "Look now." Something outside the camera thinks the board is worth a
  /// glance sooner than the throttle was going to give it one.
  ///
  /// **It shortens a WAIT and changes nothing else.** The next frame offered is
  /// converted whatever [observationInterval] would have said, and for
  /// [attentionWindow] after it the gate converts at [attentionInterval]
  /// instead. What a frame SAYS is untouched: the signature, the quiet run and
  /// the gyro all run on every frame regardless (rule 1 above), so `isStable`
  /// is computed exactly as it would have been and a nudge can only publish a
  /// verdict the gate had already reached — never manufacture one. That is the
  /// invariant that lets the microphone be wrong for free, and
  /// `camera_frame_source_test.dart` pins it.
  ///
  /// Deliberately clock-free. The gate has no clock of its own — every time it
  /// knows comes in on a frame — so a nudge is a flag the next [offer] picks
  /// up rather than a timestamp a caller has to be able to produce.
  ///
  /// Safe from anywhere and safe to call at any rate: the only caller today is
  /// the dice-sound trigger, whose refractory bounds how often it can, and a
  /// gate nobody calls this on behaves exactly as it did before the method
  /// existed.
  void attend() => _attentionPending = true;

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

    // A nudge that has been waiting takes effect HERE, after the signature and
    // the quiet run and before the throttle — the one rule it is allowed to
    // touch. See [attend].
    if (_attentionPending) {
      _attentionPending = false;
      _attentionUntil = at + attentionWindow;
      _lastConverted = null;
    }
    final until = _attentionUntil;
    if (until != null && at > until) _attentionUntil = null;
    final interval = _attentionUntil == null ? observationInterval : attentionInterval;

    final last = _lastConverted;
    if (last != null && at - last < interval) return;
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

  /// Raised when the conversion has failed [kConversionFailureLimit] times in
  /// a row. See [LatestOnlyPipeline.faults].
  Stream<FrameConversionFault> get faults => gate.faults;

  /// Starts streaming from an already-initialized [controller].
  ///
  /// The controller is the caller's: the calibration screen needs the same one
  /// for its preview, and two controllers on one camera is a platform error on
  /// both OSes. That is also why the format has to be CHECKED here rather than
  /// set here — see [checkBuddyImageFormat], which runs before anything else
  /// in this method touches a plugin.
  Future<void> start(CameraController controller) async {
    checkBuddyImageFormat(controller.imageFormatGroup);
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

/// Throws unless [group] is [kBuddyImageFormat].
///
/// Split out of [CameraFrameSource.start] so the rule is reachable from
/// `flutter test`, where a `CameraController` can be constructed but never
/// initialized. Throws rather than asserts, deliberately: an assert is removed
/// from the build where this failure is invisible, which is the only build
/// where it matters.
///
/// A null [group] is refused with the rest. It means "whatever the platform
/// defaults to", and the platform default is `bgra8888` on iOS — so the one
/// value that looks like "no opinion" is in fact the wrong answer on half the
/// devices Buddy Mode runs on.
void checkBuddyImageFormat(ImageFormatGroup? group) {
  if (group == kBuddyImageFormat) return;
  throw ArgumentError.value(
    group,
    'imageFormatGroup',
    'Buddy Mode reads $kBuddyImageFormat; a controller built with anything '
        'else produces frames YuvFrame.fromCameraImage cannot convert, one '
        'per frame, silently in release',
  );
}

/// The image format Buddy Mode asks the camera for.
///
/// `yuv420` on both platforms, which is what [YuvFrame.fromCameraImage] and
/// `Frame.fromYuv420` are written against — Android delivers `YUV_420_888`
/// (three planes, full range) and iOS
/// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (two planes, studio
/// range), and the conversion handles both. NOT `bgra8888`: it would skip a
/// conversion, but it also triples the bytes crossing the platform boundary
/// thirty times a second.
///
/// **[CameraFrameSource.start] refuses a controller built with anything else**,
/// which is the whole reason this constant is not merely advice. A mismatched
/// controller does not fail at `start`: it fails once per frame, forever,
/// inside a `catch` that only prints in debug mode — so a release build would
/// show a live preview and never produce a single [ObservedFrame], with
/// nothing anywhere saying why.
const ImageFormatGroup kBuddyImageFormat = ImageFormatGroup.yuv420;
