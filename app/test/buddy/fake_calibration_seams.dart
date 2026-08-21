import 'dart:async';

import 'package:aigammon_app/screens/buddy/calibration_screen.dart';
import 'package:aigammon_app/buddy/camera_frame_source.dart';
import 'package:board_vision/board_vision.dart';
import 'package:flutter/material.dart';

import 'fake_vision.dart';

/// The calibration screen's two seams, scripted — beside [FakeVision], and for
/// the same reason.
///
/// `CalibrationScreen` declares exactly two things a widget test cannot have:
/// the camera and `BoardVision.calibrate`. Both screens that reach the flow —
/// the calibration screen itself and the setup screen that pushes it — need
/// the same two doubles, and they had one each: two `FakeBuddyCamera`s with
/// different fields and two `FakeBoardLearner`s recording different things. A
/// double that exists twice drifts, and the half that drifts is whichever half
/// a fix was not applied to. So there is one of each, here.

/// The camera, scripted. Nothing here is a plugin.
class FakeBuddyCamera implements BuddyCamera {
  FakeBuddyCamera({this.opening = const CameraReady()});

  final CameraOpening opening;
  final StreamController<ObservedFrame> _frames =
      StreamController<ObservedFrame>.broadcast();

  bool opened = false;
  bool closed = false;

  /// Balanced with [PhoneBuddyCamera]'s own count, and for the same reason: a
  /// recalibration pushed from the game screen opens this camera a second time
  /// and closes it as it pops, under a screen that is still playing a match.
  /// A fake that shut the frame stream on the first close would make that
  /// resume untestable — and untested is how the real one would have shipped.
  int _users = 0;

  @override
  Stream<ObservedFrame> get frames => _frames.stream;

  @override
  Future<CameraOpening> open() async {
    _users++;
    opened = true;
    return opening;
  }

  @override
  Widget preview(BuildContext context) =>
      const ColoredBox(color: Color(0xFF202020));

  @override
  Future<void> close() async {
    if (_users > 0) _users--;
    if (_users > 0 || closed) return;
    closed = true;
    await _frames.close();
  }

  /// One frame from the gate. An UNSETTLED one is how a test says "the phone
  /// moved": the screen publishes it as the preview and asks it nothing.
  void push(Frame frame, {bool stable = true}) {
    if (closed) return;
    _frames.add(ObservedFrame(
      frame: frame,
      motion: MotionHint.still,
      isStable: stable,
      sceneChange: 0,
      at: Duration.zero,
    ));
  }
}

/// `BoardVision.calibrate` is a static over a photograph; this is the seam that
/// lets a widget test say what it answered.
class FakeBoardLearner implements BoardLearner {
  FakeBoardLearner(this._vision);

  final FakeVision _vision;
  final List<LearnCall> calls = <LearnCall>[];
  late final List<CalibrationResult> _answers = <CalibrationResult>[
    CalibrationResult.success(_vision.calibration),
  ];

  /// The next `learn` answers, in order; the last one repeats, as every script
  /// beside [FakeVision]'s does.
  void willAnswer(List<CalibrationResult> answers) => _answers
    ..clear()
    ..addAll(answers);

  @override
  CalibrationResult learn({
    required Frame frame,
    required BoardHandles handles,
    required BoardOrientation orientation,
    required double dieSide,
  }) {
    calls.add(LearnCall(handles, orientation, dieSide));
    return _answers.length == 1 ? _answers.first : _answers.removeAt(0);
  }

  @override
  BoardVision visionFor(BoardCalibration calibration) => _vision;
}

/// Everything one `learn` was handed. All four arguments, because all four are
/// things the screen decides and none of them is checkable any other way.
class LearnCall {
  LearnCall(this.handles, this.orientation, this.dieSide);

  final BoardHandles handles;
  final BoardOrientation orientation;
  final double dieSide;
}
