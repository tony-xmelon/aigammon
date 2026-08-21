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
///
/// ## The one change made so far, and who made it
///
/// **The user, at the gate follow-up on 2026-08-21**, reshaped the two
/// whole-board rows — and only their *shape*: both numbers are still 0.95 and
/// 0.90, and neither was lowered. What moved is what an attempt is.
///
/// The gate's evidence was that ≥0.95 and ≥0.90 *per whole board* are not the
/// promises the design actually needs, and are arithmetically out of reach on a
/// board read region by region: twenty-six regions at 0.986 apiece make a clean
/// board 0.69 of the time, so a whole-board 0.90 costs a per-region 0.996 that
/// nothing in this pipeline offers. Worse, they are not the questions a session
/// asks. After Buddy dictates a move, the session knows exactly which regions
/// the hand went to; a sweep of the other twenty is a query nobody made. So:
///
/// * [placementVerification] is scored on **the regions the play touches**,
///   one attempt per dictated turn — see `regionsTouchedBy`;
/// * [fullBoardResyncPerRegion] is scored **per region**, and the whole-board
///   rate stays in the report as a watched row that nothing is promised about.
///
/// The reshape is not the fix and was never sold as one. Measured on the day it
/// landed, it moved placement verification on the real corpus from 0/6 to
/// **2/6**, and the perception work behind it — deriving the profile's
/// bridgeable gap from a checker's own body rather than from a count of rows —
/// took it to **3/6** in the commit after.
///
/// **It reads 1/6 today, and every step of that fall was a truth fix rather
/// than a regression** — two corrections to the filmed ledger, on 2026-08-21
/// and again on 2026-08-22, the second by pixel measurement. What they exposed
/// is one mechanism: this corpus's folding case has a rim that stands proud of
/// the felt, so the man at the near end of a near-half point is three quarters
/// hidden and the reader returns *nothing* there rather than a short count.
/// Four of the five turns that miss are exactly that, and while the ledger had
/// those men on cells the camera sees well, none of it was visible. See the
/// plan's Task 8 notes and `kRealCorpusFloors`.
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

  /// Buddy's dictated move verified as placed correctly, **over the regions
  /// that play touches** — one attempt per dictated turn. Missed in play, the
  /// belief mirror plus tap-correct takes over. Scored by the plan's Task 8.
  ///
  /// The denominator is the session's own question and nothing wider: the hops
  /// name the regions, `regionsTouchedBy` turns them into the set, and
  /// `BoardDiscrepancies.agreesOn` answers about exactly those. A region the
  /// play never went near cannot fail this — it is not part of the claim the
  /// session made — and a whole-board sweep is still available and still
  /// reported, as [fullBoardResyncPerRegion]'s watched row.
  static const double placementVerification = 0.95;

  /// A board re-read against the expected position for drift recovery, scored
  /// **per region**.
  ///
  /// The most permissive target because the fallback — the side-by-side
  /// "camera says / game says" resolve — is the cheapest to fall back to and
  /// the attempt is repeatable on the next stable frame. Scored by Task 8.
  ///
  /// **Per region, because per board this number is arithmetic rather than a
  /// promise.** A resync sweep asks twenty-six regions on a folding case and
  /// twenty-eight on a cased one; at the synthetic corpus's measured 0.9869 a
  /// region, twenty-eight of them come back clean 0.69 of the time if the
  /// misses were independent and 0.733 as measured. Requiring 0.90 of the whole
  /// board is requiring 0.996 of every region — a number nobody chose and the
  /// spec never argued for. What the resolve screen actually consumes is the
  /// region list, one line per contradiction, so that is what is promised. The
  /// whole-board rate is still counted and still printed; nothing is promised
  /// about it.
  static const double fullBoardResyncPerRegion = 0.90;

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
