import 'calibration.dart';
import 'frame.dart';
import 'geometry_types.dart';

/// The perception core, as the app sees it.
///
/// One session holds one of these, built from the calibration the setup flow
/// produced, and asks it the small discrete questions the game state
/// generates. It is deliberately a thin front: every answer is computed in one
/// of the modules under `src/`, and this class exists so the app has a single
/// object to hold, fake in tests, and hand to a worker isolate.
///
/// The two questions calibration asks are here now; the ones play asks —
/// which legal play happened, are the settled dice a six and a three, does
/// this point still hold the four checkers the game expects — arrive with the
/// tasks that build them.
class BoardVision {
  /// What this session knows about the board in front of it.
  final BoardCalibration calibration;

  BoardVision(this.calibration);

  /// Learns a board from a frame of its **starting position**.
  ///
  /// [corners] are the playing field's four corners in the frame, as the user
  /// dragged them (or as auto-detection proposed), and [orientation] is the
  /// seat they were dragged from. The men have to be set up for the start of a
  /// game: that is what labels the thirty checker samples and the sixteen bare
  /// points this board's colours are learned from.
  ///
  /// Failure is a named, sentence-carrying [CalibrationResult], not an
  /// exception — every reason is something the user can act on, and the
  /// calibration screen shows the sentence as it stands.
  static CalibrationResult calibrate({
    required Frame frame,
    required BoardQuad corners,
    required BoardOrientation orientation,
  }) =>
      Calibrator.learnStartingPosition(
        frame: frame,
        corners: corners,
        orientation: orientation,
      );

  /// Checks the board in [frame] against the position every game starts from,
  /// naming the points that disagree.
  ///
  /// The last step of the calibration flow, and the cheapest possible test
  /// that the corners, the seat and the colours all came out right: a mirrored
  /// board or a half-turned one reads as its own diagonal twin and every point
  /// disagrees at once.
  ConfirmResult confirmStartingPosition(Frame frame) =>
      Calibrator.confirm(frame, calibration);
}
