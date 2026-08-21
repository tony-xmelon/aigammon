import 'package:backgammon_core/backgammon_core.dart';

import 'board_geometry.dart';
import 'board_verifier.dart';
import 'calibration.dart';
import 'dice_reader.dart';
import 'drift.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'occupancy.dart';
import 'play_matcher.dart';
import 'readability.dart';
import 'roi_atlas.dart';

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
  /// [proportions] is how wide this board's trays and bar are, as fractions of
  /// its width — measured by a person off the calibration frame, and left out
  /// for a board with ordinary bear-off wells. A folding-case board, which has
  /// no wells at all and a hinge for a bar, is a different board and says so
  /// here; see [BoardProportions].
  ///
  /// [dieSide] is how wide this session's dice are, in the same units, and it
  /// is the same kind of fact — see [BoardCalibration.dieSide] for why it is
  /// not a constant and where a session is meant to get it.
  ///
  /// Failure is a named, sentence-carrying [CalibrationResult], not an
  /// exception — every reason is something the user can act on, and the
  /// calibration screen shows the sentence as it stands.
  static CalibrationResult calibrate({
    required Frame frame,
    required BoardQuad corners,
    required BoardOrientation orientation,
    BoardProportions proportions = BoardProportions.standard,
    double dieSide = BoardCalibration.defaultDieSide,
  }) =>
      Calibrator.learnStartingPosition(
        frame: frame,
        corners: corners,
        orientation: orientation,
        proportions: proportions,
        dieSide: dieSide,
      );

  /// Learns a **folding-case** board from a frame of its starting position.
  ///
  /// The other door, for the board a great many homes actually have: a case
  /// that folds in half, with no bear-off wells and a raised hinge for a bar.
  /// Its two leaves are not coplanar — a case standing open on a table sits
  /// slightly tented — so no four corners describe it, however carefully they
  /// are dragged. Measured on the first real board, a single-plane fit lands
  /// mid-board columns half a column out and every gate here refuses it.
  ///
  /// So this asks for eight points instead of four: the same outer corners,
  /// plus the four seams where the hinge meets the board's far and near edges.
  /// See [FoldingCorners] — and note there is no `proportions` argument,
  /// because those eight points already say what shape the board is.
  ///
  /// Everything else is [calibrate]: same starting position, same colour
  /// learning, same read-back gate, same sentence-carrying failures.
  static CalibrationResult calibrateFolding({
    required Frame frame,
    required FoldingCorners corners,
    required BoardOrientation orientation,
    double dieSide = BoardCalibration.defaultDieSide,
  }) =>
      Calibrator.learnFoldingStartingPosition(
        frame: frame,
        corners: corners,
        orientation: orientation,
        dieSide: dieSide,
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

  /// The two settled dice in [frame], or null when there are not exactly two.
  ///
  /// Null is an answer, and the common one when a die is under a hand, off the
  /// board, or still rolling. The session's response is to wait for another
  /// stable frame and then to offer the manual dice pad — never to guess, since
  /// a wrong roll goes into the authoritative game state and stays there.
  DiceReading? readDice(Frame frame) =>
      DiceReader(calibration, frame).read();

  /// Which of [legalPlays] happened, from the change between two settled
  /// frames — the query the whole mode turns on.
  ///
  /// [before] is the position the game says the board was in and [beforeFrame]
  /// is the settled frame of it; [frame] is the settled frame after [mover]
  /// played. The answer is every candidate, ranked by fit — read
  /// [PlayMatch.plausible] and [PlayMatch.isAmbiguous] before reading
  /// [PlayMatch.play], and see [PlayMatcher.match] for the whole contract
  /// (ties, dances, and the first-class "none of these").
  ///
  /// **Both frames must come from the same calibration epoch** — recalibrate
  /// between them and the difference is noise shaped like a play, quietly and
  /// without an error. The session invalidates any held before-frame when
  /// calibration is invalidated; see [PlayMatcher] for the whole precondition.
  ///
  /// This convenience reads every region of both frames on every call. A
  /// session asking about the same before-frame more than once (waiting for a
  /// player to finish, say) should hold a [PlayMatcher] instead and call
  /// [PlayMatcher.match] on it.
  ///
  /// ## Why there are two frames here and one in the plan
  ///
  /// The plan pinned this as `matchLegalPlay(Frame, BoardState, Player,
  /// List<Move>)` — one frame, compared against what each candidate would
  /// produce. Phase 1 measured why that cannot be the instrument: per-region
  /// counts on a real board are biased, and the bias is a property of the seat
  /// the phone is in rather than of the frame, so it is the same in every shot
  /// of one session (Task 6: colour 0.954, colour-and-count 0.784, the misses
  /// all in the direction the perspective predicts). An absolute comparison
  /// pays that bias on every region; a difference between two frames of one
  /// session subtracts it from itself. So the settled frame from before the
  /// play is a required argument, and the positional signature is otherwise
  /// exactly the plan's. The session already holds that frame — it is the one
  /// the previous query ran on.
  List<PlayMatch> matchLegalPlay(
    Frame frame,
    BoardState before,
    Player mover,
    List<Move> legalPlays, {
    required Frame beforeFrame,
  }) =>
      PlayMatcher(calibration, beforeFrame: beforeFrame, afterFrame: frame)
          .match(before, mover, legalPlays);

  /// Does the board in [frame] hold [expected]?
  ///
  /// The other state-primed query, and the one behind two different moments of
  /// a session: **placement verification** — Buddy dictated a move and wants to
  /// know whether the man went where it said — and **drift recovery**, where
  /// the whole board is re-read against the authoritative state after something
  /// stopped adding up.
  ///
  /// Every region is checked against what [expected] puts there, and the answer
  /// is per-region: agrees, disagrees with a named kind and a confidence, or
  /// **unobservable** on a region this board does not have. Read
  /// [BoardDiscrepancies.agrees] first; a caller that wants to act on the
  /// disagreements wants [recoverFromDrift] instead, which says which side of
  /// each one to doubt.
  ///
  /// **This is a contradiction test, not a reading**, and the distinction is
  /// what makes it usable on a board the camera counts badly: it is handed K
  /// and only has to decide whether the picture says otherwise, so it agrees on
  /// a strict superset of the regions a blind count gets right. See
  /// [BoardVerifier] for the measurement behind that, and for the worn-hinge
  /// case it was built around.
  ///
  /// **[frame] must come from the same calibration epoch** — the same corners,
  /// the same learned colours, the same board in the same place. Nothing here
  /// can check it; the session invalidates held frames when calibration is
  /// invalidated, exactly as it does for [matchLegalPlay].
  ///
  /// This convenience builds a fresh reader on every call. A session checking
  /// one frame against more than one candidate position should hold a
  /// [BoardVerifier] instead.
  BoardDiscrepancies verifyExpectedBoard(Frame frame, BoardState expected) =>
      BoardVerifier(calibration, frame).verify(expected);

  /// Can this frame be read at all, and if not, why not?
  ///
  /// **The one query that is not asked about a position**, and the one the
  /// session runs on EVERY stable frame whether or not anything is pending.
  /// The spec makes calibration a session-long contract rather than a one-time
  /// gate: a board nudged, a lamp switched off, a phone slid, a hand left over
  /// the felt are all caught the moment they happen instead of the next time
  /// Buddy needs an answer.
  ///
  /// [motion] is what the phone's gyro says, injected because this package
  /// never touches a sensor — see [MotionHint].
  ///
  /// The answer carries a level, a named cause, and
  /// [Readability.requiresRecalibration], which is what the session routes on:
  /// true when the calibration itself is dead and the guided corner/confirm
  /// loop has to run again, false for everything that clears on its own. Read
  /// [ReadabilityMonitor] before changing any of it — the order of the checks
  /// is measured, not stylistic.
  ///
  /// Nothing here speaks, schedules or touches the game state. A readability
  /// outage suspends answers and nothing else; the authoritative position is
  /// untouched and play resumes exactly where it paused.
  Readability assessReadability(Frame frame, MotionHint motion) =>
      ReadabilityMonitor(calibration).assess(frame, motion);

  /// The same question, with what to do about each disagreement.
  ///
  /// What the spec's side-by-side "camera says / game says" screen is built
  /// from: every discrepancy carries a [DriftResolution] saying which side is
  /// likelier wrong, drawn from the pipeline's own measured error structure — a
  /// tall stack reading short is the camera, a colour that flipped is the
  /// board. See [DriftReport].
  DriftReport recoverFromDrift(Frame frame, BoardState expected) =>
      DriftReport.of(verifyExpectedBoard(frame, expected));
}
