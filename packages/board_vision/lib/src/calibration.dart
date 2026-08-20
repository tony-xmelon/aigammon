import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';

import 'board_geometry.dart';
import 'color_model.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'roi_atlas.dart';
import 'roi_sampler.dart';

/// What the board looked like when calibration accepted it.
///
/// Task 9 re-takes one of these on every stable frame and compares, because
/// the spec makes calibration a session-long contract rather than a one-time
/// gate: a nudged phone, a lamp switched off, a board slid across the table
/// all have to be caught the moment they happen. The two halves of the
/// comparison are deliberately separate, since they route differently — a
/// board that moved invalidates the geometry and sends the session to
/// recalibration, while a room that dimmed is a readability problem that
/// clears on its own.
///
/// Small and plain by design: a few dozen bytes of appearance and five
/// numbers, no frame kept alive, nothing that would stop this being written to
/// a log or a preference store.
class CalibrationFingerprint {
  /// Cells per side of each corner patch.
  static const int cornerCells = 3;

  /// How far a corner patch reaches outside the playing field, in board-space
  /// units. The board's own outline is the most informative thing near a
  /// corner — a patch entirely inside the frame's woodwork would look the same
  /// after a slide of two centimetres, which is exactly the movement worth
  /// catching.
  static const double cornerOutside = 0.03;

  /// How far a corner patch reaches inside the playing field.
  static const double cornerInside = 0.09;

  /// The average difference the corner patches may drift, relative to the
  /// frame's own mean brightness, before the geometry is called stale.
  ///
  /// Measured against the synthetic bed rather than guessed: a board that slid
  /// twenty pixels under a thousand-pixel-wide frame drifts 0.26, a board that
  /// did not move at all under sensor noise drifts 0.01, and a room dimmed to
  /// six tenths of its light — with nothing moved — drifts 0.07. Twenty pixels
  /// is about a fifth of a point's width, which is worth catching.
  static const double maxPatchDrift = 0.12;

  /// How far overall brightness may move, as a ratio either way.
  ///
  /// Sitting close to a cliff, and knowingly. Re-normalizing the colour model
  /// holds all the way down to a board at three tenths of its calibration
  /// light, because dimming only scales; upward it fails much sooner, because
  /// brightening also clips, and a board 40% over reads half its checkers
  /// wrong however well it is re-normalized. One symmetric ratio for both
  /// directions is therefore generous below and tight above — deliberately, to
  /// keep the number simple until the corpus says what real auto-exposure
  /// actually does between two frames.
  static const double maxExposureRatio = 1.3;

  /// How far the frame's colour cast may move.
  static const double maxCastDrift = 0.12;

  /// Four corner patches — top-left, top-right, bottom-right, bottom-left, in
  /// [BoardQuad.corners] order — each [cornerCells] x [cornerCells] cells of
  /// three channels, row-major within a corner. Each cell is an average of a
  /// small block, so noise in one pixel cannot move it.
  final List<int> cornerPatches;

  /// Mean BT.601 luma over the board's interior. The board only: the room
  /// around it is not what the session is exposed for.
  final double meanLuma;

  /// Standard deviation of that luma — the board's dynamic range, which
  /// collapses under glare or fog. Recorded for Task 9's readability checks
  /// rather than compared here, because how much range is *enough* is a
  /// readability threshold and not a "did the scene change" one.
  final double lumaSpread;

  /// Mean red over mean green, and mean blue over mean green: the frame's
  /// colour cast, which moves when the light source changes even if its
  /// brightness does not.
  final double redRatio;
  final double blueRatio;

  /// The share of the board's interior with at least one channel pinned at
  /// 255.
  ///
  /// The one exposure statistic that says whether a frame can be
  /// re-normalized at all. Clipping is not dimness — it is information the
  /// sensor threw away, and no amount of scaling brings it back. Measured on
  /// the synthetic bed: a board lit 40% over its calibration exposure clips a
  /// quarter of itself, and on a board with pale points the pale points and
  /// the white checkers clip to the *same* white, at which point no colour
  /// model on earth can tell one from the other. That is the readability cause
  /// Task 9 has to raise, and this is the number that raises it.
  final double clippedFraction;

  CalibrationFingerprint({
    required List<int> cornerPatches,
    required this.meanLuma,
    required this.lumaSpread,
    required this.redRatio,
    required this.blueRatio,
    required this.clippedFraction,
  }) : cornerPatches = List<int>.unmodifiable(cornerPatches);

  /// Takes a fingerprint of [frame] through the calibration's [geometry].
  ///
  /// Samples that fall outside the picture are clamped to its border rather
  /// than dropped: a fingerprint has to be the same size every time to be
  /// comparable, and a corner patch that reaches past the edge of the frame is
  /// itself stable information about where the board sits.
  ///
  /// The four corner patches are board space's own corners, which are the
  /// board's outer corners on a folding case as much as on a flat board — so
  /// this reads the same four places either way, through whichever geometry it
  /// is handed.
  factory CalibrationFingerprint.fromFrame(Frame frame, BoardGeometry geometry) {
    final sampler = FrameSampler(frame, geometry);
    final patches = <int>[];
    for (final corner in const <Pt>[Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)]) {
      final sx = corner.x == 0 ? 1.0 : -1.0;
      final sy = corner.y == 0 ? 1.0 : -1.0;
      final span = cornerOutside + cornerInside;
      final cell = span / cornerCells;
      for (var row = 0; row < cornerCells; row++) {
        final cy = corner.y + sy * (-cornerOutside + (row + 0.5) * cell);
        for (var col = 0; col < cornerCells; col++) {
          final cx = corner.x + sx * (-cornerOutside + (col + 0.5) * cell);
          final mean = sampler.blockMean(cx, cy, cell / 2, cell / 2);
          patches..add(mean.$1)..add(mean.$2)..add(mean.$3);
        }
      }
    }

    var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumL = 0.0, sumL2 = 0.0, n = 0.0;
    var clipped = 0.0;
    for (var iy = 0; iy < _lattice; iy++) {
      final y = _interiorAt(iy);
      for (var ix = 0; ix < _lattice; ix++) {
        final x = _interiorAt(ix);
        final sample = sampler.at(x, y);
        if (sample == null) continue;
        final luma = lumaOf(sample);
        sumR += sample.$1;
        sumG += sample.$2;
        sumB += sample.$3;
        sumL += luma;
        sumL2 += luma * luma;
        if (sample.$1 == 255 || sample.$2 == 255 || sample.$3 == 255) {
          clipped++;
        }
        n++;
      }
    }
    final meanLuma = n == 0 ? 0.0 : sumL / n;
    final variance =
        n == 0 ? 0.0 : math.max(0.0, sumL2 / n - meanLuma * meanLuma);
    final green = sumG <= 0 ? 1.0 : sumG;

    return CalibrationFingerprint(
      cornerPatches: patches,
      meanLuma: meanLuma,
      lumaSpread: math.sqrt(variance),
      redRatio: sumR / green,
      blueRatio: sumB / green,
      clippedFraction: n == 0 ? 0.0 : clipped / n,
    );
  }

  /// Mean BT.601 luma over the board's interior in [frame], measured over the
  /// same lattice [meanLuma] is — the one number
  /// `ColorModel.renormalized` wants, without paying for the corner patches a
  /// full fingerprint also takes.
  ///
  /// Zero when none of the board falls inside the picture, which callers turn
  /// into "do not re-normalize" rather than a division by nothing.
  static double boardLuma(Frame frame, BoardGeometry geometry) {
    final sampler = FrameSampler(frame, geometry);
    var sum = 0.0, n = 0.0;
    for (var iy = 0; iy < _lattice; iy++) {
      final y = _interiorAt(iy);
      for (var ix = 0; ix < _lattice; ix++) {
        final sample = sampler.at(_interiorAt(ix), y);
        if (sample == null) continue;
        sum += lumaOf(sample);
        n++;
      }
    }
    return n == 0 ? 0.0 : sum / n;
  }

  /// The interior lattice both of the above walk: inset from the board's own
  /// edges so the room around it is never in the average.
  static const int _lattice = 24;
  static const double _inset = 0.05;

  static double _interiorAt(int index) =>
      _inset + (index + 0.5) / _lattice * (1 - 2 * _inset);

  /// Whether the board is still where calibration left it.
  ///
  /// Both patch sets are divided by their own frame's mean luma first, so a
  /// room that merely dimmed still matches: this asks about geometry, and
  /// [exposureMatches] asks about light.
  bool geometryMatches(CalibrationFingerprint other) {
    if (other.cornerPatches.length != cornerPatches.length) return false;
    final mine = math.max(meanLuma, 1.0);
    final theirs = math.max(other.meanLuma, 1.0);
    var sum = 0.0;
    for (var i = 0; i < cornerPatches.length; i++) {
      final d = cornerPatches[i] / mine - other.cornerPatches[i] / theirs;
      sum += d * d;
    }
    return math.sqrt(sum / cornerPatches.length) <= maxPatchDrift;
  }

  /// Whether the light is still what the colours were learned under.
  bool exposureMatches(CalibrationFingerprint other) {
    final ratio = math.max(meanLuma, 1.0) / math.max(other.meanLuma, 1.0);
    if (ratio > maxExposureRatio || ratio < 1 / maxExposureRatio) return false;
    if ((redRatio - other.redRatio).abs() > maxCastDrift) return false;
    if ((blueRatio - other.blueRatio).abs() > maxCastDrift) return false;
    return true;
  }

  /// Both of the above: the scene is the one that was calibrated.
  ///
  /// Every part of this is a comparison *against the calibration's own
  /// fingerprint*, so it detects drift and nothing else. It cannot tell you
  /// that a scene is badly lit — only that it is lit differently than it was.
  /// A session calibrated under a blazing lamp matches itself perfectly while
  /// being unreadable; that is what [clippedFraction] is for, and Task 9 needs
  /// both.
  bool matches(CalibrationFingerprint other) =>
      geometryMatches(other) && exposureMatches(other);

  @override
  String toString() => 'CalibrationFingerprint(luma '
      '${meanLuma.toStringAsFixed(1)}±${lumaSpread.toStringAsFixed(1)})';
}

/// Everything a session knows about the board in front of it.
class BoardCalibration {
  /// Board space into this frame's pixels — one plane on an ordinary board,
  /// three on a folding case. See [BoardGeometry].
  final BoardGeometry geometry;

  /// Which seat the board was calibrated from, which is what fixes the point
  /// numbering.
  final BoardOrientation orientation;

  /// This board's own colours, learned from its own starting position.
  final ColorModel colors;

  /// What the scene looked like, for the session-long re-validation.
  final CalibrationFingerprint fingerprint;

  /// How far one of this board's checkers reaches along a stack, learned from
  /// the eight stacks the starting position labels. What turns a measured
  /// length into a count; see [StackMetrics] for why it cannot be a constant.
  final StackMetrics stacks;

  /// This board's widths — what makes [atlas] describe THIS board rather than
  /// a standard one. Measured by hand off the calibration frame and handed to
  /// `BoardVision.calibrate`; see [BoardProportions].
  final BoardProportions proportions;

  /// How far across one of this session's dice is, as a fraction of the
  /// board's width — the same kind of fact as [proportions], and measured the
  /// same way: off the board, by whoever set the session up.
  ///
  /// **It cannot be a constant, and assuming one is what made the dice reader
  /// useless on real footage.** Every size-derived number in [DiceReader] —
  /// how large a blob has to be to be worth considering, how finely the band
  /// is sampled, how much of a blob's rim to shave before looking for pips —
  /// used to be written for the synthetic bed's dice, which are **0.075** of
  /// the board across. The first real footage's are **0.021**: three and a
  /// half times smaller, a fiftieth of the area, and every blob the reader
  /// found fell straight through its smallest-blob gate. It returned null on
  /// all seventy real windows.
  ///
  /// The default is the bed's own number, so nothing that worked moves.
  ///
  /// **Where a session gets it.** The corpus reads it from the sidecar, next
  /// to the widths. The product cannot ask a user to measure their dice, and
  /// should not: the plan's Task 12 has calibration watch the first roll,
  /// where two blobs that appear together in a band that was empty a second
  /// ago are dice by construction and their size is there to be measured. That
  /// is the intended source; this field is what it will fill in.
  final double dieSide;

  const BoardCalibration({
    required this.geometry,
    required this.orientation,
    required this.colors,
    required this.fingerprint,
    required this.stacks,
    this.proportions = BoardProportions.standard,
    this.dieSide = defaultDieSide,
  });

  /// The synthetic bed's die, as a fraction of the board's width.
  ///
  /// A default rather than a constant: it is what the bed draws and what every
  /// test written before dice had a size was measured against, so it keeps
  /// those honest. No real board is obliged to agree with it, and the first
  /// one measured did not.
  static const double defaultDieSide = 0.075;

  /// Where everything is, for this seating and this board.
  ///
  /// One atlas per calibration, built from the same [proportions] the colours
  /// and the stack pitch were learned through — nothing in this package builds
  /// an atlas any other way, because two atlases that disagreed about where
  /// the columns are would put the learned colours on the wrong felt.
  RoiAtlas get atlas =>
      RoiAtlas.forOrientation(orientation, proportions: proportions);

  /// How much brighter [frame]'s board is than the frame the colours were
  /// learned from.
  ///
  /// Every query that classifies a pixel needs this, because a background is
  /// measured once and a checker sitting on it can never be re-measured: let
  /// the light drift and the sample-over-background ratio stops cancelling.
  /// The drift does not have to be large to matter — a phone's auto-exposure
  /// moves this much between two frames of the same scene, well inside the
  /// fingerprint's own tolerance, which is why nothing flags it and why it has
  /// to be applied rather than watched for.
  ///
  /// One when the board is not in the picture at all, which leaves the model
  /// as learned rather than scaling it by nothing.
  double exposureIn(Frame frame) {
    final luma = CalibrationFingerprint.boardLuma(frame, geometry);
    if (luma <= 0 || fingerprint.meanLuma <= 0) return 1.0;
    return luma / fingerprint.meanLuma;
  }

  /// [colors], re-normalized for the light in [frame].
  ///
  /// The one-call form for a query that reads a single frame. A caller reading
  /// several answers from one frame should take [exposureIn] once and pass its
  /// result to `ColorModel.renormalized`, rather than re-measuring per query.
  ColorModel colorsIn(Frame frame) => colors.renormalized(exposureIn(frame));
}

/// Why a calibration attempt could not be made into a [BoardCalibration].
///
/// Every one of these is something the user can act on, which is the point:
/// the calibration screen shows [CalibrationResult.message] as it stands.
enum CalibrationProblem {
  /// The four corners do not describe a quadrilateral.
  cornersNotABoard,

  /// Part of the board is outside the picture.
  boardNotFullyVisible,

  /// A region is in the picture but nothing can be measured from it — covered,
  /// or lost in shadow or glare.
  regionUnreadable,

  /// So much light that the board's colours are running into each other at the
  /// top of the sensor's range. Distinct from
  /// [checkerColoursNotSeparable]: those colours are separable, the frame
  /// simply has no room left to hold them apart.
  boardOverExposed,

  /// The board is readable but the men are not where a game starts.
  checkersNotInStartingPosition,

  /// The board's colours cannot be told apart in this light — the two sets of
  /// checkers from each other, or a set of checkers from the board under it.
  checkerColoursNotSeparable,

  /// The board reads, but too few of the eight stacks the starting position
  /// labels measured for the checker pitch to be fitted — so how many men are
  /// on a point could not be answered for any point, all session.
  stackPitchNotMeasurable,
}

/// The outcome of a calibration attempt.
class CalibrationResult {
  /// What was learned, or null when [problem] says why not.
  final BoardCalibration? calibration;

  final CalibrationProblem? problem;

  /// A sentence for the user. Written to be shown as it is.
  final String message;

  /// The regions the problem is about, when it is about particular ones.
  final List<RoiId> offending;

  CalibrationResult._({
    this.calibration,
    this.problem,
    required this.message,
    List<RoiId> offending = const <RoiId>[],
  }) : offending = List<RoiId>.unmodifiable(offending);

  factory CalibrationResult.success(BoardCalibration calibration) =>
      CalibrationResult._(
        calibration: calibration,
        message: 'The board is calibrated.',
      );

  factory CalibrationResult.failure(
    CalibrationProblem problem,
    String message, [
    List<RoiId> offending = const <RoiId>[],
  ]) =>
      CalibrationResult._(
        problem: problem,
        message: message,
        offending: offending,
      );

  bool get ok => calibration != null;

  @override
  String toString() =>
      ok ? 'CalibrationResult(ok)' : 'CalibrationResult($message)';
}

/// One region that does not hold what the starting position says it should.
///
/// Usually a point, hence the name, but the bar and the two bear-off trays get
/// checked as well — they start empty, and a checker sitting in one would
/// otherwise be folded into the authoritative game state as though the board
/// were correct. [pointNumber] is null for those three.
class PointDiscrepancy {
  final RoiId region;

  /// The point as White numbers it — `BoardState.points[i]` is White's point
  /// `i + 1`, and that is the number the app speaks and prints. Null when
  /// [region] is not a point.
  final int? pointNumber;

  final CheckerColor expected;
  final CheckerColor observed;

  const PointDiscrepancy({
    required this.region,
    required this.pointNumber,
    required this.expected,
    required this.observed,
  });

  /// A clause for the user, ready to be joined into a sentence.
  String get message {
    final where = describeRegion(region);
    if (observed == CheckerColor.none) {
      return '$where looks empty, but the game starts with '
          '${_side(expected)} there';
    }
    if (expected == CheckerColor.none) {
      return '$where has ${_side(observed)} on it, but the game starts with '
          'it empty';
    }
    return '$where has ${_side(observed)} on it, where the game starts with '
        '${_side(expected)}';
  }

  static String _side(CheckerColor colour) =>
      colour == CheckerColor.white ? 'White' : 'Black';

  @override
  String toString() => 'PointDiscrepancy($message)';
}

/// Whether the board in front of the camera is the starting position.
///
/// **What [agrees] does and does not claim.** Every one of the twenty-four
/// points holds the colour the starting position puts there, and the bar and
/// both trays are empty — the trays only on a board that has any; a
/// folding-case board is checked on its points and its bar alone. It does NOT
/// claim the counts are right: a point
/// showing two White where the game starts with five agrees here, because
/// counting checkers is occupancy's job and stack verification's after it.
/// For the calibration flow that is the right division — a mis-set count is
/// something the user sees on their own board, while a mirrored or half-turned
/// board is not, and that is what this catches.
class ConfirmResult {
  final bool agrees;

  /// The regions that disagree: points first in White's numbering order, then
  /// the bar and the trays.
  final List<PointDiscrepancy> discrepancies;

  /// A sentence for the user, naming the offenders.
  final String message;

  ConfirmResult({
    required this.agrees,
    required List<PointDiscrepancy> discrepancies,
    required this.message,
  }) : discrepancies = List<PointDiscrepancy>.unmodifiable(discrepancies);

  @override
  String toString() => 'ConfirmResult($message)';
}

/// Learning a board from its starting position, and checking one against it.
///
/// The public door is `BoardVision`; this is where the work happens.
///
/// ## Why the starting position
///
/// It is the one moment perception is handed labels for free. Thirty checkers
/// sit where the rules put them, so eight points are labelled colour samples
/// and sixteen are labelled samples of this board's bare surface — enough to
/// learn two checker distributions and a background for every region without
/// asking the user for anything beyond four corner handles.
///
/// ## What is sampled where
///
/// Two shapes, both taken by the shared [RoiSampler] — a **checker patch**
/// across the foot of a point's stack, and a **region interior** over the
/// whole of an ROI. Their geometry and the reasoning behind it live with the
/// sampler, which occupancy and the dice reader use too, so that every query
/// in the package measures a region the same way.
///
/// ## Numbers, provisionally
///
/// Every threshold on this class was measured against the synthetic renderer,
/// and each says what it was measured against. Photographs are a different
/// thing entirely — grain, gloss, shadow, checkers that are not flat discs —
/// so the corpus gate (the plan's Task 6) is where all of them get asked
/// again, and where the ones that turn out to be wrong get changed here, in
/// the one place they live.
class Calibrator {
  const Calibrator._();

  /// How many checker-free samples a region needs before its own background is
  /// trusted over the board-wide one. The tightest case in the starting
  /// position is a five-stack, which leaves 76 to 107 of its 400 lattice
  /// samples showing across the three palettes — so this floor is a long way
  /// below what a board in good order produces, and it is reached only when
  /// something is wrong.
  static const int minBackgroundSamples = 16;

  /// What share of a covered region's visible surface has to be ONE surface
  /// before that region's own reference colour is trusted over the board's.
  ///
  /// Measured on the bed, over the eight points the starting position covers:
  /// with the stacks flush against their edges the dominant surface takes 71%
  /// to 84% of what is left showing, and with them sitting a sixteenth of the
  /// board back it falls to 43% to 68% as the triangles' bases come out from
  /// under the stacks. This sits in that gap.
  static const double minSurfaceShare = 0.7;

  /// How near a sample has to be to the checkers standing on its own region,
  /// in the model's feature space, before it is thrown out of that region's
  /// background. Generous on purpose: leaving a checker in the background is
  /// far worse than leaving out a little felt, since the region would go on to
  /// take the checker for part of itself.
  ///
  /// Measured: the closest any of the three palettes puts a point's own paint
  /// to its checkers is 0.28 (pale points against white checkers on the
  /// blue-red board), and felt to checkers is 0.70 at the tightest. So this
  /// keeps the felt of every palette and, on the hardest one, takes the paint
  /// with the checkers — which is harmless, the felt being the majority of
  /// what is left.
  static const double checkerExclusionRadius = 0.30;

  /// What fraction of a patch has to agree before a point is called read.
  /// Short of it the answer is "no checker", which sends a doubtful point to
  /// the user as something to look at rather than into the game state as a
  /// fact.
  static const double patchMajority = 0.6;

  /// How much of the bar or a bear-off tray has to come out one colour before
  /// a checker is called there. A single checker on the bar covers about a
  /// twentieth of it and one in a tray about a tenth, so this sits well under
  /// the smallest thing worth seeing while staying clear of a region that
  /// reads a stray sample or two.
  static const double minRegionCoverage = 0.02;

  /// How many rounds of extra surfaces a known-empty region may be given
  /// before the calibrator stops looking — see [_settleEmptyRegions].
  ///
  /// Each round splits whatever still reads as a checker into at most two more
  /// surfaces, so three rounds is room for six beyond the two every region
  /// starts with. A region still showing checkers after them falls through to
  /// the read-back gate, which refuses it, which is the right end for a board
  /// nobody can model.
  ///
  /// ## What is measured, and where
  ///
  /// **From below** — how many rounds a real worn spine costs. The first real
  /// folding board's needed one. The bed's worn spine needs **two**: set this
  /// to 0 or 1 and 'a spine worn the way a real one is' refuses the blue-red
  /// case for having White on the bar, which is the very failure
  /// [_settleEmptyRegions] exists to cure. So three is one round of margin
  /// over the worst thing either board has shown.
  ///
  /// **From above, and this is the half that decides the number.** The cap is
  /// a SAFETY limit rather than a convergence budget: every extra round is one
  /// more chance for a region to explain away something that is genuinely
  /// standing in it. Measured against the first real corpus frame during the
  /// corner sweep — where the same photograph is calibrated through many
  /// slightly different corner placements — **26** corner sets were accepted
  /// at three rounds and **48** at eight. Nearly twice as many, and the extra
  /// ones were not better placements: some came from the bar band, given
  /// enough rounds, swallowing a slice of the neighbouring stack that a
  /// mis-set corner had pushed into it. A calibration that accepts a corner
  /// placement it should have refused is exactly what this package must not
  /// do, so the cap stays where the real frame put it.
  ///
  /// That measurement is not reproducible from this repository — it is the one
  /// number here taken against a photograph the committed tests do not have,
  /// and the corpus gate (the plan's Task 6) is where it can be taken again.
  static const int maxSurfaceRounds = 3;

  /// How many regions may read back wrong from the very frame they were
  /// learned on before the calibration is refused.
  ///
  /// Zero, and the zero is the argument: a model that cannot read its own
  /// calibration frame will tell the user their board is set up wrongly one
  /// screen later, and they will stand there looking at a board that is
  /// exactly right. Better to fail now, while the message can still name the
  /// light. Whether real photographs can hold to zero is a Task 6 question —
  /// if they cannot, this is the knob, and raising it trades that misleading
  /// message back in one region at a time.
  static const int maxLearningMisreads = 0;

  /// How much of the board may be pinned at the top of the sensor's range
  /// before over-exposure is named as the reason a calibration would not read
  /// back. A diagnostic threshold, not a gate: the gate is whether the board
  /// reads back at all.
  static const double maxClippedFraction = 0.05;

  /// Learns [frame]'s board, which must be in the starting position.
  ///
  /// [proportions] is this board's own geometry — leave it out for a board
  /// with ordinary bear-off wells. Get it wrong and this refuses rather than
  /// hands over a calibration that reads the wrong columns: the read-back gate
  /// at the end is measured to catch it, because the outermost points move
  /// most and they are the ones the starting position labels.
  static CalibrationResult learnStartingPosition({
    required Frame frame,
    required BoardQuad corners,
    required BoardOrientation orientation,
    BoardProportions proportions = BoardProportions.standard,
    double dieSide = BoardCalibration.defaultDieSide,
  }) {
    final BoardGeometry geometry;
    try {
      geometry = PlanarBoardGeometry.fromQuad(corners);
    } on ArgumentError {
      return CalibrationResult.failure(
        CalibrationProblem.cornersNotABoard,
        'Those four corners do not outline a board. Drag each handle onto a '
        'corner of the playing field and try again.',
      );
    }
    return _learn(
      frame: frame,
      geometry: geometry,
      orientation: orientation,
      proportions: proportions,
      dieSide: dieSide,
      misfitHint: 'the tray and bar widths it was measured with are probably '
          "not this board's",
    );
  }

  /// The same, for a board that folds — see [FoldingBoardGeometry] for why
  /// such a board needs its own entry point rather than better corners.
  ///
  /// Nothing downstream of here knows the difference: the atlas, the colour
  /// model, the stack pitch and the read-back gate are the ones above, run
  /// over a board space that happens to reach the picture through three planes
  /// instead of one. The proportions are not a parameter because there is
  /// nothing left to measure — [FoldingCorners] derives them.
  static CalibrationResult learnFoldingStartingPosition({
    required Frame frame,
    required FoldingCorners corners,
    required BoardOrientation orientation,
    double dieSide = BoardCalibration.defaultDieSide,
  }) {
    final FoldingBoardGeometry geometry;
    try {
      geometry = FoldingBoardGeometry(corners);
    } on ArgumentError {
      return CalibrationResult.failure(
        CalibrationProblem.cornersNotABoard,
        'Those eight points do not outline a folding board. Four go on the '
        'corners of the playing field and four on the seams where the hinge '
        'meets the far and near edges — left seam then right seam on each. '
        'Drag them there and try again.',
      );
    }
    return _learn(
      frame: frame,
      geometry: geometry,
      orientation: orientation,
      proportions: geometry.proportions,
      dieSide: dieSide,
      misfitHint: 'the eight points it was measured through — four corners '
          'and the four hinge seams — are probably not quite on it',
    );
  }

  /// Everything both entry points do once they have a geometry.
  ///
  /// [misfitHint] is the clause the two "this does not read as a start"
  /// failures end on: what a user should suspect about their measurements when
  /// the board itself looks right to them. It differs between the two paths
  /// because what was measured differs.
  static CalibrationResult _learn({
    required Frame frame,
    required BoardGeometry geometry,
    required BoardOrientation orientation,
    required BoardProportions proportions,
    required String misfitHint,
    double dieSide = BoardCalibration.defaultDieSide,
  }) {
    final atlas =
        RoiAtlas.forOrientation(orientation, proportions: proportions);
    final sampler = RoiSampler(frame, geometry, atlas);
    final start = BoardState.initial();
    final occupied = <int, CheckerColor>{
      for (var i = 0; i < 24; i++)
        if (start.points[i] != 0)
          i: start.points[i] > 0 ? CheckerColor.white : CheckerColor.black,
    };

    // --- what is even in the picture
    //
    // Where each stack actually sits is found rather than assumed: a person's
    // starting position leaves its outermost checkers a little way off their
    // own edges, by different amounts on different points. See
    // [RoiSampler.findChecker], which exists because a real board's frame said
    // so.
    final patches = <int, List<Rgb>>{};
    final feet = <int, double>{};
    for (final index in occupied.keys) {
      final found = sampler.findChecker(index);
      if (found.scan.visibleFraction < RoiSampler.minVisibleFraction) {
        return _notVisible(RoiId.point(index));
      }
      patches[index] = found.scan.samples;
      feet[index] = found.depth;
    }
    // The dice band is the one region that keeps out of the way of the
    // checkers standing in it, rather than filtering them out afterwards. The
    // difference matters and was measured: a filter works on colour, so it
    // removes a checker but leaves the RIM of one — the pixels where a
    // checker's edge blends into the felt — and the band's surface model then
    // learns that blend as though it were a surface the board has. It is not,
    // and on two of the three synthetic palettes it is very nearly the colour
    // of a die. The dice reader, looking for what the band's surfaces do not
    // account for, would find no dice at all.
    //
    // Keeping clear of every occupied column costs the band about a fifth of
    // its samples (400 -> 320, still twenty times minBackgroundSamples's
    // floor) and gains it a true reading of both the surfaces it does have,
    // the felt and the bar's wood — which the contaminated model also got
    // wrong, since one spurious cluster leaves only one for two real ones.
    final occupiedColumns = <(double, double)>[
      for (final index in occupied.keys)
        () {
          final b = boundsOf(atlas.roi(RoiId.point(index)));
          return (b.minX, b.maxX);
        }(),
    ];
    bool underAStack(double x, double y) {
      for (final (left, right) in occupiedColumns) {
        if (x >= left && x <= right) return true;
      }
      return false;
    }

    // Every region THIS board has. A folding-case board has no bear-off wells,
    // so there is nothing there to measure a background from and nothing later
    // that will ask — see [RoiAtlas.regions].
    final interiors = <RoiId, List<Rgb>>{};
    for (final id in atlas.regions) {
      final scan = sampler.interior(
        id,
        skip: id == RoiId.diceZone ? underAStack : null,
      );
      if (scan.visibleFraction < RoiSampler.minVisibleFraction) {
        return _notVisible(id);
      }
      interiors[id] = scan.samples;
    }

    // --- every region's bare surface
    //
    // Only regions the starting position covers get their samples filtered by
    // colour, and the dice band with them as a backstop behind the columns it
    // already keeps clear of. Filtering everywhere would be worse than useless:
    // on a board whose pale
    // points are nearly the colour of its white checkers it would throw away
    // exactly the surface an empty point most needs to have measured.
    //
    // What each region is filtered AGAINST is the colour of the checkers
    // standing on that same region, sampled a moment ago — not a board-wide
    // average of them. Light is never even across a real board, and a pooled
    // colour compared absolutely fails at whichever end of the table is
    // darker: its checkers no longer look like the average, so none of them
    // are removed, the region takes them for part of its own surface, and it
    // will afterwards read its own checkers as bare board. A five-stack in the
    // dim corner would go further and take the checker colour for its
    // reference outright. Measured on a board lit from one side, this is the
    // difference between reading it and refusing it.
    final filtered = <RoiId, List<Rgb>>{
      for (final index in occupied.keys)
        RoiId.point(index): <Rgb>[medianRgb(patches[index]!)],
      // The band has no checkers of its own; what reaches into it are the tops
      // of the four tallest stacks, each of which is one of these.
      RoiId.diceZone: <Rgb>[
        for (final index in occupied.keys) medianRgb(patches[index]!),
      ],
    };
    final free = <RoiId, List<Rgb>>{};
    for (final id in atlas.regions) {
      final against = filtered[id];
      free[id] = against == null
          ? interiors[id]!
          : interiors[id]!
              .where((s) => !_looksLikeChecker(s, against))
              .toList();
    }
    final pooled = <Rgb>[
      for (final id in atlas.regions)
        if (free[id]!.length >= minBackgroundSamples) ...free[id]!,
    ];
    if (pooled.isEmpty) {
      return CalibrationResult.failure(
        CalibrationProblem.regionUnreadable,
        'I cannot make out the board itself — every part of it is covered, or '
        'lost in shadow or glare. Clear the board, add some light, and try '
        'again.',
      );
    }
    final pooledColor = medianRgb(pooled);

    final backgrounds = <RoiId, RoiBackground>{};
    for (final id in atlas.regions) {
      final samples = free[id]!;
      if (samples.isEmpty) {
        // Nothing in the region could be told apart from the checkers standing
        // on it. Either something is lying on the board that should not be, or
        // that corner is dark enough that the board and the men on it have
        // squeezed into the same few values — the two are not distinguishable
        // from here, so the message names both.
        return CalibrationResult.failure(
          CalibrationProblem.regionUnreadable,
          'I cannot make out ${describeRegion(id)} — something may be '
          'resting on it, or that corner of the board may be too dark to '
          'read. Clear it, or add some light, and try again.',
          <RoiId>[id],
        );
      }
      // With some of itself showing but not much, the region has too little to
      // anchor its own exposure and borrows the board's instead;
      // [RoiBackground.fullyMeasured] records which happened.
      //
      // "Not much" is two conditions, and the second one arrived with stacks
      // that are not flush against their edges. A point with a stack on it
      // shows whatever the stack does not cover, and where the stack sits back
      // from its edge what it uncovers is the WIDE base of the triangle — so
      // the region's visible surface splits nearly evenly between felt and
      // paint. A per-channel median of an even mixture is not either of them
      // and is often a colour the board does not have anywhere: measured on
      // the bed at an inset of a sixteenth of the board, a point whose
      // surfaces are (110,74,42) and (142,43,28) produced a reference of
      // (110,43,28). The region then goes on to measure its own checkers
      // against a colour that does not exist, their feature lands outside the
      // cloud the other three points of that colour agree on, and calibration
      // reports a stack of five as an empty point.
      //
      // So a region that cannot say what its own surface IS borrows the
      // board's, exactly as one that has barely any surface showing does.
      final enough = samples.length >= minBackgroundSamples &&
          (!filtered.containsKey(id) || _mostlyOneSurface(samples));
      final color = enough ? medianRgb(samples) : pooledColor;
      final surfaces = _surfaces(
        <List<double>>[
          for (final s in samples) ColorModel.feature(s, color),
        ],
      );
      backgrounds[id] = RoiBackground(
        color: color,
        modes: surfaces.modes,
        spread: surfaces.spread,
        sampleCount: samples.length,
        fullyMeasured: !filtered.containsKey(id) && enough,
      );
    }

    // --- the checker colours, relative to where they were sitting
    final features = <int, List<double>>{
      for (final index in occupied.keys)
        index: ColorModel.feature(
          medianRgb(patches[index]!),
          backgrounds[RoiId.point(index)]!.color,
        ),
    };
    final white = _distributionOf(occupied, features, CheckerColor.white);
    final black = _distributionOf(occupied, features, CheckerColor.black);

    final boardModes = <List<double>>[
      for (final entry in backgrounds.entries)
        if (entry.value.fullyMeasured) ...entry.value.modes,
    ];
    final boardSpread = _medianSpread(<List<double>>[
      for (final entry in backgrounds.entries)
        if (entry.value.fullyMeasured) entry.value.spread,
    ]);

    final colors = ColorModel(
      white: white,
      black: black,
      backgrounds: backgrounds,
      boardModes: boardModes,
      boardSpread: boardSpread,
    );

    if (colors.separation < ColorModel.minSeparation) {
      return CalibrationResult.failure(
        CalibrationProblem.checkerColoursNotSeparable,
        'The two sets of checkers look too much alike from here. More light, '
        'or an angle with less glare on the board, usually fixes it.',
      );
    }

    // Every stack must read as the colour the starting position puts there.
    // The distributions are medians across four points each, so one point of
    // the wrong colour does not drag them — it stands out instead, which is
    // what this catches.
    for (final entry in occupied.entries) {
      final f = features[entry.key]!;
      final toOwn = (entry.value == CheckerColor.white ? white : black)
          .distanceTo(f);
      final toOther = (entry.value == CheckerColor.white ? black : white)
          .distanceTo(f);
      if (toOther < toOwn) {
        final number = entry.key + 1;
        return CalibrationResult.failure(
          CalibrationProblem.checkersNotInStartingPosition,
          'The checkers are not in the starting position — the $number-point '
          'is holding the wrong colour. Set the board up for the start of a '
          'game, then calibrate again. If the board is already set up right, '
          '$misfitHint.',
          <RoiId>[RoiId.point(entry.key)],
        );
      }
    }

    // --- the regions the starting position says are empty
    //
    // See [_settleEmptyRegions]. This is the last thing learned because it is
    // the only thing that needs the checker colours in order to be learned at
    // all.
    final settled = _settleEmptyRegions(
      sampler: sampler,
      atlas: atlas,
      colors: colors,
      interiors: interiors,
      // The eight medians the starting position labelled — this board's own
      // checkers, in plain sensor levels.
      checkers: <Rgb>[
        for (final index in occupied.keys) medianRgb(patches[index]!),
      ],
    );
    if (settled.refused != null) return settled.refused!;
    final model = settled.colors;

    // Last, calibration reads the board back out of the frame it just learned
    // from. Everything above says the model is self-consistent; this says it
    // works. The two come apart in exactly one measured way — a board lit hard
    // enough that its pale points and its white checkers both clip to the same
    // 255 learns two perfectly separable checker colours and then reads
    // phantom White on half its empty points — and handing that calibration
    // over would push the failure one screen along, where it arrives as "your
    // board is set up wrong" and sends the user to move checkers that are
    // already right.
    // The other thing the starting position labels for free: eight stacks of
    // known height, on both halves, at three different heights. That is a
    // regression, and it is where the checker pitch occupancy counts with
    // comes from — measured on this board rather than assumed from any board's
    // proportions.
    final stacks = StackMetrics.fit(<(int, double)>[
      for (final entry in occupied.entries)
        (
          start.points[entry.key].abs(),
          sampler
              .measureStack(
                StackAxis.forRegion(atlas, RoiId.point(entry.key)),
                model,
              )
              .reachOf(entry.value),
        ),
    ]);

    final fingerprint = CalibrationFingerprint.fromFrame(frame, geometry);
    final calibration = BoardCalibration(
      geometry: geometry,
      orientation: orientation,
      colors: model,
      fingerprint: fingerprint,
      stacks: stacks,
      proportions: proportions,
      dieSide: dieSide,
    );
    final readBack = confirm(frame, calibration);
    if (readBack.discrepancies.length > maxLearningMisreads) {
      if (fingerprint.clippedFraction >= maxClippedFraction) {
        return CalibrationResult.failure(
          CalibrationProblem.boardOverExposed,
          'There is so much light on the board that its colours are washing '
          'into each other. Dim the light, or move the phone so the lamp is '
          'not shining straight back at it.',
          readBack.discrepancies.map((d) => d.region).toList(),
        );
      }
      return CalibrationResult.failure(
        CalibrationProblem.checkersNotInStartingPosition,
        'I can read this board, but not as a game about to start: '
        '${readBack.discrepancies.first.message}. Set the men up for the '
        'start of a game, then calibrate again. If the board is already set '
        'up right, $misfitHint.',
        readBack.discrepancies.map((d) => d.region).toList(),
      );
    }

    // Said last, because it is the least likely and the least actionable: the
    // board is set up right and its colours read back, but not enough of its
    // eight labelled stacks measured for the pitch to be a regression.
    //
    // **Handing this over would be the worst thing this class can do.** The
    // pitch divides every count for the whole session, so a bad one is not one
    // wrong region — it is every region wrong at once, on a board that
    // calibrated and confirmed and gave the user no reason to doubt it. That
    // is exactly the failure `StackMetrics.fit` was measured against, and the
    // conditioning flag is what it hands out when its own filtering could not
    // save the fit.
    //
    // **Nothing on the bed reaches this, and that is the honest state of it.**
    // Swept over 432 frames — three palettes, three light levels, four
    // viewpoints from level to steeply off-axis, blur to five sigma, and
    // stacks left up to a sixteenth of the board in — and the pitch was never
    // the first thing to give out: every frame degraded enough to lose three
    // of its eight stacks had already lost its colours, and one of the gates
    // above caught it. So this is defence in depth rather than a measured
    // limit, and what pins its trigger is the unit test over
    // `StackMetrics.fit`'s conditioning rather than any frame. If a real
    // photograph ever lands here, it will be the first.
    if (!stacks.wellConditioned) {
      return CalibrationResult.failure(
        CalibrationProblem.stackPitchNotMeasurable,
        'I can read this board, but I cannot make out how far one checker '
        'sits behind another from here — so I would get the numbers wrong. '
        'A little more light on the near points, or a slightly higher camera '
        'angle, usually fixes it.',
      );
    }

    return CalibrationResult.success(calibration);
  }

  /// Checks [frame] against the position every game starts from.
  ///
  /// Colour presence, region by region: White's, Black's or nothing at the
  /// foot of each point's stack, and nothing at all on the bar or in either
  /// tray. How MANY checkers are on a point is a different question with a
  /// different instrument — occupancy and the stack verifier — and this one
  /// deliberately does not pretend to answer it.
  ///
  /// Classification runs through a model re-normalized for this frame's own
  /// light: the calibration shot and the confirmation frame are seconds apart
  /// on a live preview, and a phone's auto-exposure moves between them by more
  /// than enough to turn every empty point into a phantom checker.
  static ConfirmResult confirm(Frame frame, BoardCalibration calibration) {
    final atlas = calibration.atlas;
    final sampler = RoiSampler(frame, calibration.geometry, atlas);
    final colors = calibration.colorsIn(frame);
    final start = BoardState.initial();
    final discrepancies = <PointDiscrepancy>[];
    var expectedButEmpty = 0, expectedOccupied = 0;
    RoiId? outOfPicture;

    for (var i = 0; i < 24; i++) {
      final expected = start.points[i] > 0
          ? CheckerColor.white
          : start.points[i] < 0
              ? CheckerColor.black
              : CheckerColor.none;
      if (expected != CheckerColor.none) expectedOccupied++;

      // With the colours already learned, the walk can stop at a checker
      // standing alone — which is exactly what a point that should be empty
      // has on it when something is wrong.
      final scan = sampler.findChecker(i, colors: colors).scan;
      if (scan.visibleFraction < RoiSampler.minVisibleFraction) {
        outOfPicture ??= RoiId.point(i);
        continue;
      }
      final observed = _majorityColor(
        <CheckerColor>[
          for (final sample in scan.samples)
            colors.classifyIn(RoiId.point(i), sample),
        ],
      );
      if (observed == expected) continue;
      if (expected != CheckerColor.none && observed == CheckerColor.none) {
        expectedButEmpty++;
      }
      discrepancies.add(PointDiscrepancy(
        region: RoiId.point(i),
        pointNumber: i + 1,
        expected: expected,
        observed: observed,
      ));
    }

    // The bar and the trays start empty, and a checker in one of them is worse
    // than a checker on the wrong point: nothing downstream ever asks about
    // them again until it matters, so it would be folded into the
    // authoritative game state and every position after it would be wrong.
    // These are areas rather than stacks with a known foot — the bar grows
    // outward from the middle, a tray inward from the edge — so they are
    // judged by how much of the region is checker-coloured at all.
    //
    // On a board with no bear-off wells the tray half of this check simply
    // does not run: there is no felt to leave a checker on, and the reason
    // this check exists — a stray checker being folded into the authoritative
    // state — cannot happen where there is nowhere for one to sit.
    for (final id in emptyAtStart(atlas)) {
      final scan = sampler.interior(id);
      if (scan.visibleFraction < RoiSampler.minVisibleFraction) {
        outOfPicture ??= id;
        continue;
      }
      final observed = _dominantColor(
        <CheckerColor>[
          for (final sample in scan.samples) colors.classifyIn(id, sample),
        ],
      );
      if (observed == CheckerColor.none) continue;
      discrepancies.add(PointDiscrepancy(
        region: id,
        pointNumber: null,
        expected: CheckerColor.none,
        observed: observed,
      ));
    }

    // Said first: a board that has drifted out of the picture would otherwise
    // be reported as a board set up wrong, which sends the user to fix the
    // wrong thing.
    if (outOfPicture != null) {
      return ConfirmResult(
        agrees: false,
        discrepancies: discrepancies,
        message: 'I cannot see the whole board any more — '
            '${describeRegion(outOfPicture)} is outside the picture. Line the '
            'camera up again, or re-check the corners.',
      );
    }
    if (discrepancies.isEmpty) {
      return ConfirmResult(
        agrees: true,
        discrepancies: const <PointDiscrepancy>[],
        // "Looks like", because that is the whole of what was checked: the
        // right colour in the right places, not the right number of them.
        message: 'That looks like the starting position.',
      );
    }
    // Every starting point bare and no checker anywhere it should not be: the
    // board is empty, which deserves saying rather than a list of two dozen
    // points that are individually wrong.
    if (expectedButEmpty == expectedOccupied &&
        discrepancies.length == expectedButEmpty) {
      return ConfirmResult(
        agrees: false,
        discrepancies: discrepancies,
        message: 'I cannot see a checker anywhere the game starts. Set the men '
            'up for the start of a game and try again.',
      );
    }
    final named = discrepancies.take(2).map((d) => d.message).join('; ');
    final rest = discrepancies.length - 2;
    return ConfirmResult(
      agrees: false,
      discrepancies: discrepancies,
      message: 'The board is not set up for the start of a game: $named'
          '${rest > 0 ? ' (and $rest more)' : ''}.',
    );
  }

  /// The regions the starting position guarantees hold nothing at all.
  ///
  /// The bar always, and the two bear-off trays on a board that has any — a
  /// folding case has no wells, and borne-off checkers leave such a board
  /// altogether, so there is nowhere for a checker to be left. See
  /// [RoiAtlas.hasTrays].
  ///
  /// One definition, used twice and for opposite purposes: [_settleEmptyRegions]
  /// leans on the guarantee at calibration, and [confirm] checks it on every
  /// frame afterwards.
  static List<RoiId> emptyAtStart(RoiAtlas atlas) => <RoiId>[
        RoiId.bar,
        if (atlas.hasTrays) ...<RoiId>[RoiId.offWhite, RoiId.offBlack],
      ];

  /// Settles the regions the starting position labels empty, and refuses the
  /// frame when one of them is not.
  ///
  /// ## The principle
  ///
  /// This is the same free labelling the rest of calibration runs on, applied
  /// to the three regions nobody thinks of as labelled. Thirty checkers sit
  /// where the rules put them; the bar and the trays are therefore **empty**,
  /// by construction, in every frame calibration is ever handed. So a sample
  /// there that comes back looking like a checker is not a checker. It is a
  /// surface this board has and the model has not been given room for — and
  /// the honest thing to do with it is to give it room.
  ///
  /// The first real folding board is why this exists. Its hinge is a worn
  /// ridge: a near-black crack down the middle, a pale rubbed crown either
  /// side of it, plain wood on the flanks. Three surfaces, and a region gets
  /// two — the crack is the furthest thing from the wood so it takes the
  /// second mode, and the crown is left with nowhere to sit. 168 of the bar's
  /// 400 samples classified as checkers, 115 of them White, and a board set up
  /// perfectly was refused for having a checker on the bar.
  ///
  /// ## The risk, and what actually separates the two cases
  ///
  /// Absorbing carelessly would be worse than the refusal it cures: make the
  /// pale crown part of the bar and a cream checker standing on that crown
  /// mid-game goes silently missing. And a checker genuinely left in a tray
  /// while the user calibrates has to STAY a refusal — that one they can fix,
  /// and if it is folded into the board instead the session begins with three
  /// men already borne off.
  ///
  /// Colour cannot tell those apart; on the real board the crown sits 1.40
  /// spreads from the White cloud, which is where a checker sits. What tells
  /// them apart is that a checker is an OBJECT: a disc with one colour across
  /// its face and a body behind it. So each region is walked with the same
  /// instrument every point is walked with — [RoiSampler.findAlong], which
  /// takes the first coherent block that holds — and only a region where
  /// nothing stands is absorbed. Measured on the real frame: every block down
  /// its worn spine scatters 20 to 43 levels against a coherence floor of 18,
  /// because a block laid across the strip catches the crack and the flanks
  /// along with the crown. Nothing there is an object, and nothing there is
  /// mistaken for one.
  ///
  /// This also closes a hole that predates the worn spine and was silent: a
  /// tray with checkers in it shows exactly two surfaces, its felt and the
  /// men, which is exactly what the region model has room for. Both were
  /// learned, the read-back agreed, and the calibration was handed over.
  static ({CalibrationResult? refused, ColorModel colors}) _settleEmptyRegions({
    required RoiSampler sampler,
    required RoiAtlas atlas,
    required ColorModel colors,
    required Map<RoiId, List<Rgb>> interiors,
    required List<Rgb> checkers,
  }) {
    final backgrounds = <RoiId, RoiBackground>{
      for (final id in atlas.regions) id: colors.backgroundOf(id),
    };
    var changed = false;

    for (final id in emptyAtStart(atlas)) {
      if (_standingIn(sampler, atlas, id, checkers)) {
        return (
          refused: CalibrationResult.failure(
            CalibrationProblem.checkersNotInStartingPosition,
            'I can see a checker where the game starts with none — '
            '${describeRegion(id)}. Take it off the board and calibrate again.',
            <RoiId>[id],
          ),
          colors: colors,
        );
      }

      var background = backgrounds[id]!;
      final samples = interiors[id]!;
      final features = <List<double>>[
        for (final sample in samples)
          ColorModel.feature(sample, background.color),
      ];
      for (var round = 0; round < maxSurfaceRounds; round++) {
        final strays = <List<double>>[
          for (var i = 0; i < samples.length; i++)
            if (colors.classify(samples[i], background) != CheckerColor.none)
              features[i],
        ];
        // Under what a checker would cover, nothing downstream would call this
        // region occupied anyway — so there is nothing to absorb and no reason
        // to disturb a model that is working.
        if (strays.length <= minRegionCoverage * samples.length) break;
        final extra = _surfaces(strays);
        if (extra.modes.isEmpty) break;
        final modes = <List<double>>[...background.modes, ...extra.modes];
        background = RoiBackground(
          color: background.color,
          modes: modes,
          // Re-measured, and this is the half of the fix that keeps a real
          // checker visible. A region's spread is the scatter of its samples
          // about the surfaces it was given, so a region modelled with one
          // surface too few carries the MISSING surface's whole distance in
          // its spread — the bed's worn spine came out at (0.15, 0.22, 0.36)
          // against a floor of 0.15. A spread that wide reaches out past the
          // crown to where a cream checker standing on it sits, and swallows
          // it. Split the surfaces properly and each sample is near one of
          // them, so the same measurement over the same samples collapses back
          // to the floor and the checker is outside it again.
          spread: _spreadAbout(features, modes),
          sampleCount: background.sampleCount,
          fullyMeasured: background.fullyMeasured,
        );
        changed = true;
      }
      backgrounds[id] = background;
    }

    if (!changed) return (refused: null, colors: colors);
    return (
      refused: null,
      colors: ColorModel(
        white: colors.white,
        black: colors.black,
        backgrounds: backgrounds,
        // Deliberately NOT the absorbed vocabulary. What a hinge's spine looks
        // like is the hinge's business; lending it to the eight points that
        // were under checkers would make their own checkers vanish.
        boardModes: colors.boardModes,
        boardSpread: colors.boardSpread,
      ),
    );
  }

  /// Whether one of this board's own checkers is STANDING in [id].
  ///
  /// Judged against [checkers] — the eight medians the starting position
  /// labelled a moment ago — rather than through the region's learned surface,
  /// because that surface is precisely what cannot be trusted here: a tray
  /// with men in it shows two surfaces, its felt and the men, and two is
  /// exactly what the region model has room for. Asked through it, the tray
  /// answers that its checkers are part of the tray.
  ///
  /// The bar is asked twice because it is the one region with two ends: its
  /// two colours stack away from each other from the midline, so a checker on
  /// it sits at the origin of one axis or the other. A tray has one.
  static bool _standingIn(
    RoiSampler sampler,
    RoiAtlas atlas,
    RoiId id,
    List<Rgb> checkers,
  ) {
    bool isChecker(Rgb median) => _looksLikeChecker(median, checkers);
    final axes = id == RoiId.bar
        ? <StackAxis>[
            StackAxis.forRegion(atlas, id, color: CheckerColor.white),
            StackAxis.forRegion(atlas, id, color: CheckerColor.black),
          ]
        : <StackAxis>[StackAxis.forRegion(atlas, id)];
    for (final axis in axes) {
      final found = sampler.findAlong(axis, isChecker: isChecker);
      // Settling is the whole test. The walk only settles on a block that is
      // one colour across its face and holds that colour for a checker's body,
      // and it only accepts one whose colour is a checker's — so a stripe worn
      // down a hinge, which is neither, comes back unsettled. Measured on the
      // real board: every block down its spine scatters 20 to 43 sensor levels
      // against a coherence floor of 18, because a block laid across the strip
      // catches the crack and the flanks along with the crown.
      if (!found.settled) continue;
      if (isChecker(medianRgb(found.scan.samples))) return true;
    }
    return false;
  }

  /// Per-channel scatter of [features] about whichever of [modes] each is
  /// nearest, floored like every other spread in the model.
  static List<double> _spreadAbout(
    List<List<double>> features,
    List<List<double>> modes,
  ) {
    if (modes.isEmpty) return List<double>.filled(3, ColorModel.minSpread);
    final deviations = <List<double>>[];
    for (final f in features) {
      var nearest = modes.first;
      var best = double.infinity;
      for (final mode in modes) {
        final d = _euclid(f, mode);
        if (d < best) {
          best = d;
          nearest = mode;
        }
      }
      deviations.add(<double>[
        f[0] - nearest[0],
        f[1] - nearest[1],
        f[2] - nearest[2],
      ]);
    }
    return _trimmedSpread(deviations, const <double>[0, 0, 0]);
  }

  static CalibrationResult _notVisible(RoiId id) => CalibrationResult.failure(
        CalibrationProblem.boardNotFullyVisible,
        'I cannot see the whole board — ${describeRegion(id)} is outside the '
        'picture. Move the phone back, or drag the corners onto the playing '
        'field.',
        <RoiId>[id],
      );

  /// Whether [samples] are mostly one surface rather than a mixture of two.
  ///
  /// Two-means in plain sensor levels — this runs before there is a reference
  /// to measure a feature against, which is the whole reason it is here. The
  /// share is what matters, not which surface won: a region showing four
  /// fifths felt and a fifth of paint has a reference; one showing half of
  /// each does not.
  static bool _mostlyOneSurface(List<Rgb> samples) {
    if (samples.length < 2) return true;
    var a = samples.first;
    var b = samples.first;
    var furthest = -1.0;
    for (final s in samples) {
      final d = _rgbGap(s, a);
      if (d > furthest) {
        furthest = d;
        b = s;
      }
    }
    var inA = samples.length, inB = 0;
    for (var round = 0; round < 6; round++) {
      final groupA = <Rgb>[], groupB = <Rgb>[];
      for (final s in samples) {
        (_rgbGap(s, a) <= _rgbGap(s, b) ? groupA : groupB).add(s);
      }
      if (groupA.isEmpty || groupB.isEmpty) return true;
      inA = groupA.length;
      inB = groupB.length;
      a = medianRgb(groupA);
      b = medianRgb(groupB);
    }
    return math.max(inA, inB) >= minSurfaceShare * samples.length;
  }

  static double _rgbGap(Rgb a, Rgb b) {
    final dr = (a.$1 - b.$1).toDouble();
    final dg = (a.$2 - b.$2).toDouble();
    final db = (a.$3 - b.$3).toDouble();
    return dr * dr + dg * dg + db * db;
  }

  static bool _looksLikeChecker(Rgb sample, List<Rgb> checkers) {
    for (final checker in checkers) {
      final f = ColorModel.feature(sample, checker);
      if (math.sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]) <
          checkerExclusionRadius) {
        return true;
      }
    }
    return false;
  }

  static ColorDistribution _distributionOf(
    Map<int, CheckerColor> occupied,
    Map<int, List<double>> features,
    CheckerColor colour,
  ) {
    final mine = <List<double>>[
      for (final entry in occupied.entries)
        if (entry.value == colour) features[entry.key]!,
    ];
    final mean = _medianFeature(mine);
    return ColorDistribution(
      mean: mean,
      spread: _trimmedSpread(mine, mean),
      sampleCount: mine.length,
    );
  }

  /// The one or two surfaces a set of samples shows, by two-means in feature
  /// space seeded at the reference colour and at the sample furthest from it.
  ///
  /// A single average would describe neither of a felt-and-triangle region:
  /// the middle of two surfaces is a colour the board does not have anywhere,
  /// and a spread wide enough to cover both swallows the checkers too.
  static ({List<List<double>> modes, List<double> spread}) _surfaces(
    List<List<double>> features,
  ) {
    if (features.isEmpty) {
      return (
        modes: const <List<double>>[],
        spread: List<double>.filled(3, ColorModel.minSpread),
      );
    }

    var a = <double>[0, 0, 0];
    var b = features.first;
    var furthest = -1.0;
    for (final f in features) {
      final d = _euclid(f, a);
      if (d > furthest) {
        furthest = d;
        b = f;
      }
    }

    var groupA = features, groupB = <List<double>>[];
    for (var round = 0; round < 6; round++) {
      final nextA = <List<double>>[], nextB = <List<double>>[];
      for (final f in features) {
        (_euclid(f, a) <= _euclid(f, b) ? nextA : nextB).add(f);
      }
      if (nextA.isEmpty || nextB.isEmpty) {
        groupA = nextA.isEmpty ? nextB : nextA;
        groupB = const <List<double>>[];
        break;
      }
      groupA = nextA;
      groupB = nextB;
      a = _medianFeature(nextA);
      b = _medianFeature(nextB);
    }

    final modes = <List<double>>[];
    final deviations = <List<double>>[];
    for (final group in <List<List<double>>>[groupA, groupB]) {
      if (group.isEmpty) continue;
      final centre = _medianFeature(group);
      modes.add(centre);
      for (final f in group) {
        deviations.add(<double>[
          f[0] - centre[0],
          f[1] - centre[1],
          f[2] - centre[2],
        ]);
      }
    }
    return (
      modes: modes,
      spread: _trimmedSpread(deviations, const <double>[0, 0, 0]),
    );
  }

  /// The colour covering enough of a region for a checker to be in it, for
  /// regions with no stack foot to sample.
  static CheckerColor _dominantColor(List<CheckerColor> labels) {
    if (labels.isEmpty) return CheckerColor.none;
    var white = 0, black = 0;
    for (final label in labels) {
      if (label == CheckerColor.white) white++;
      if (label == CheckerColor.black) black++;
    }
    final whiteShare = white / labels.length;
    final blackShare = black / labels.length;
    if (whiteShare < minRegionCoverage && blackShare < minRegionCoverage) {
      return CheckerColor.none;
    }
    return whiteShare >= blackShare ? CheckerColor.white : CheckerColor.black;
  }

  static CheckerColor _majorityColor(List<CheckerColor> labels) {
    if (labels.isEmpty) return CheckerColor.none;
    final counts = <CheckerColor, int>{};
    for (final label in labels) {
      counts[label] = (counts[label] ?? 0) + 1;
    }
    var best = CheckerColor.none;
    var bestCount = 0;
    for (final entry in counts.entries) {
      if (entry.value > bestCount) {
        best = entry.key;
        bestCount = entry.value;
      }
    }
    // Short of a clear majority the honest answer is "no checker": a half-read
    // point is a point to look at again, not a checker to fold into the game.
    return bestCount >= labels.length * patchMajority
        ? best
        : CheckerColor.none;
  }
}

/// A region in words, for a sentence the user reads.
///
/// Shared by the calibration failure messages, by [PointDiscrepancy.message]
/// and by the verifier's own "camera says / game says" sentences, so nothing
/// user-facing ever says `offWhite`. Public for that third caller: a second
/// copy of this switch is how one screen ends up calling the hinge "the bar"
/// and another calling it "bar".
String describeRegion(RoiId id) {
  if (id.pointIndex >= 0) return 'the ${id.pointIndex + 1}-point';
  return switch (id) {
    RoiId.bar => 'the bar',
    RoiId.offWhite => "White's bear-off tray",
    RoiId.offBlack => "Black's bear-off tray",
    RoiId.diceZone => 'the middle of the board, where the dice land',
    _ => id.name,
  };
}

// --- small robust statistics ------------------------------------------------

double _euclid(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var c = 0; c < 3; c++) {
    final d = a[c] - b[c];
    sum += d * d;
  }
  return math.sqrt(sum);
}

List<double> _medianFeature(List<List<double>> features) {
  final out = <double>[];
  for (var c = 0; c < 3; c++) {
    final values = <double>[for (final f in features) f[c]]..sort();
    out.add(values[values.length ~/ 2]);
  }
  return out;
}

/// Per-channel scatter about [centre], ignoring the widest fifth of the
/// samples so that one region of the wrong colour — or one glare spot —
/// cannot inflate a distribution into uselessness. Floored at
/// [ColorModel.minSpread].
List<double> _trimmedSpread(
  List<List<double>> features,
  List<double> centre, {
  double keep = 0.8,
}) {
  if (features.isEmpty) return List<double>.filled(3, ColorModel.minSpread);
  final out = <double>[];
  for (var c = 0; c < 3; c++) {
    final deviations = <double>[
      for (final f in features) (f[c] - centre[c]).abs(),
    ]..sort();
    final n = math.max(1, (deviations.length * keep).round());
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += deviations[i] * deviations[i];
    }
    out.add(math.max(ColorModel.minSpread, math.sqrt(sum / n)));
  }
  return out;
}

List<double> _medianSpread(List<List<double>> spreads) {
  if (spreads.isEmpty) return List<double>.filled(3, ColorModel.minSpread);
  return _medianFeature(spreads);
}
