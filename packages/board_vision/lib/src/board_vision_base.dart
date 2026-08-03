import 'calibration.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'occupancy.dart';

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
  /// naming the regions that disagree.
  ///
  /// The last step of the calibration flow, and the cheapest possible test
  /// that the corners, the seat and the colours all came out right: a mirrored
  /// board or a half-turned one reads as its own diagonal twin and every point
  /// disagrees at once.
  ///
  /// **It checks colours, not counts.** Every point holds the right colour and
  /// the bar and trays are empty — a point holding two White where the game
  /// starts with five still agrees. Counting is occupancy's job (and stack
  /// verification's after it); see [ConfirmResult] for why that division is
  /// the right one here.
  ///
  /// [frame] may be lit differently from the frame that was calibrated — the
  /// colours are re-normalized for it, which matters more than it sounds,
  /// since a live preview's auto-exposure drifts between two frames of the
  /// same scene by enough to turn every empty point into a phantom checker.
  ConfirmResult confirmStartingPosition(Frame frame) =>
      Calibrator.confirm(frame, calibration);

  /// How many checkers of what colour each region holds, in [frame].
  ///
  /// The reader carries the frame and the colour model re-normalized for its
  /// light, so several regions can be asked about without re-measuring either.
  /// Read [OccupancyReader]'s own documentation before trusting a count above
  /// two: mid-game these are meant to be differenced against an expected
  /// position, never read as an answer on their own.
  OccupancyReader occupancyIn(Frame frame) =>
      OccupancyReader(calibration, frame);
}
