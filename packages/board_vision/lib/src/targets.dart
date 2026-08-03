/// How accurate perception has to be, per the spec's table.
///
/// These five numbers are the contract Buddy Mode is measured against. They
/// come from **Provisional accuracy targets** in
/// `docs/superpowers/specs/2026-08-02-buddy-mode-design.md`, and they live here
/// — in one file, as constants — so that the corpus harness asserts the same
/// numbers the spec promises rather than a copy of them that drifted.
///
/// ## What is and is not a target
///
/// A target is a promise made to the *user* about a query the app asks: does
/// calibration complete, is the roll read right, was the play identified. It is
/// not a knob. Every threshold that shapes *how* an answer is computed — how
/// far apart two checker colours must be, how much of a region a checker has to
/// cover, how square a die's outline has to look — lives on the class that uses
/// it, next to the reasoning and the measurement behind it. Mixing the two
/// would put a number the spec fixed in the same list as a number the next
/// measurement moves, and the next person could not tell which was which.
///
/// ## When these change
///
/// Once, deliberately, with the user, at the plan's Task 6 gate — the point at
/// which the first real photographs say whether a classical-CV backbone can
/// hold these. Until then they are what the design was approved on. A number
/// here that quietly drops to match what the code happens to score is the one
/// way this file can be worse than useless.
library;

/// The spec's accuracy table, as thresholds the corpus harness asserts.
///
/// Every rate is measured **per attempt on corpus conditions** — one shot, one
/// question, one answer — not per session. A shot the corpus labels
/// expected-unreadable does not count as a failed attempt: refusing it
/// correctly is the answer, and [expectedRefusal] is the target that says so.
class PerceptionTargets {
  const PerceptionTargets._();

  /// Guided calibration completes: the four corners plus the starting position
  /// yield a usable [BoardCalibration]. Missed in play, the fallback is a retry
  /// with guidance, which is why this is the lowest of the four query targets:
  /// the user is present, looking at the screen, and being told what to fix.
  static const double calibrationSuccess = 0.95;

  /// A settled pair of dice, read from a stable frame. The highest target in
  /// the spec, and the sub-problem most likely to need the ML escape hatch: a
  /// roll is the one question that arrives unprimed, so there is no expected
  /// answer to match against and a wrong reading enters the authoritative game
  /// state. Missed in play, the fallback is the tap-to-enter dice pad.
  static const double dicePairRead = 0.98;

  /// The right legal play identified top-1 from the observed change. Below
  /// this the app prompts with the candidate list rather than guessing.
  /// Scored by the plan's Task 7, which owns the matcher.
  static const double legalPlayIdentification = 0.95;

  /// Buddy's dictated move verified as placed correctly. Missed in play, the
  /// belief mirror plus tap-correct takes over. Scored by the plan's Task 8.
  static const double placementVerification = 0.95;

  /// A whole board re-read against the expected position, for drift recovery.
  /// The most permissive target because the fallback — the side-by-side
  /// "camera says / game says" resolve — is the cheapest to fall back to and
  /// the attempt is repeatable on the next stable frame. Scored by Task 8.
  static const double fullBoardResync = 0.90;

  /// Shots the corpus labels expected-unreadable must be refused, every one.
  ///
  /// Not from the spec's table — the table is about answering — but the
  /// counterweight to all five: a pipeline that answers everything scores
  /// perfectly on questions it should have declined. A board half out of
  /// frame, a room too dark to separate the checkers, a phone knocked between
  /// two shots: the honest answer is a named refusal, and one confident wrong
  /// answer there costs more than the refusal ever saves. Hence 1.0, and hence
  /// no fallback column.
  static const double expectedRefusal = 1.0;
}
