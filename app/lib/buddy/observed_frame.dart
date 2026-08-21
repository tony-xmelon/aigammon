import 'package:board_vision/board_vision.dart';
import 'package:flutter/foundation.dart';

/// One frame that made it through the gate, and what the gate thinks of it.
///
/// **In a file of its own, with no plugin in it.** This is the value type the
/// whole mode is wired with — `BuddySession` takes a `Stream<ObservedFrame>`,
/// `BuddyCamera` publishes one, and every test in `test/buddy/` builds them by
/// hand — and it used to live in `camera_frame_source.dart`, which owns
/// `package:camera` and `package:sensors_plus`. So `buddy_session.dart`
/// transitively imported two plugins for the sake of three fields and a
/// [Frame]. The seam held (the session's whole suite runs on a desktop with
/// neither), but a seam that holds by luck is one edit from not holding.
///
/// `camera_frame_source.dart` re-exports this, so nothing that already had a
/// frame source in scope has to know it moved.
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
  /// AND the picture has stopped changing for `kQuietFramesRequired` frames
  /// (see `camera_frame_source.dart`, which is what decides this).
  ///
  /// An unstable frame is still published, because the readability light is
  /// exactly what a user needs while things are unstable.
  final bool isStable;

  /// Measured difference from the previous frame, 0..1. 1.0 for the first
  /// frame of a session, which has nothing to be compared with.
  final double sceneChange;

  final Duration at;
}
