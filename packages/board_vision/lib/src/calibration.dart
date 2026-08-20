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

  const BoardCalibration({
    required this.geometry,
    required this.orientation,
    required this.colors,
    required this.fingerprint,
    required this.stacks,
    this.proportions = BoardProportions.standard,
  });

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
    final where = _describe(region);
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
    final patches = <int, List<Rgb>>{};
    for (final index in occupied.keys) {
      final scan = sampler.checkerPatch(index);
      if (scan.visibleFraction < RoiSampler.minVisibleFraction) {
        return _notVisible(RoiId.point(index));
      }
      patches[index] = scan.samples;
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
        RoiId.point(index): <Rgb>[_medianRgb(patches[index]!)],
      // The band has no checkers of its own; what reaches into it are the tops
      // of the four tallest stacks, each of which is one of these.
      RoiId.diceZone: <Rgb>[
        for (final index in occupied.keys) _medianRgb(patches[index]!),
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
    final pooledColor = _medianRgb(pooled);

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
          'I cannot make out ${_describe(id)} — something may be resting on '
          'it, or that corner of the board may be too dark to read. Clear it, '
          'or add some light, and try again.',
          <RoiId>[id],
        );
      }
      // With some of itself showing but not much, the region has too little to
      // anchor its own exposure and borrows the board's instead;
      // [RoiBackground.fullyMeasured] records which happened.
      final enough = samples.length >= minBackgroundSamples;
      final color = enough ? _medianRgb(samples) : pooledColor;
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
          _medianRgb(patches[index]!),
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
          'the tray and bar widths it was measured with are probably not '
          "this board's.",
          <RoiId>[RoiId.point(entry.key)],
        );
      }
    }

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
                colors,
              )
              .reachOf(entry.value),
        ),
    ]);

    final fingerprint = CalibrationFingerprint.fromFrame(frame, geometry);
    final calibration = BoardCalibration(
      geometry: geometry,
      orientation: orientation,
      colors: colors,
      fingerprint: fingerprint,
      stacks: stacks,
      proportions: proportions,
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
        'up right, the tray and bar widths it was measured with are probably '
        "not this board's.",
        readBack.discrepancies.map((d) => d.region).toList(),
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

      final scan = sampler.checkerPatch(i);
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
    for (final id in <RoiId>[
      RoiId.bar,
      if (atlas.hasTrays) ...<RoiId>[RoiId.offWhite, RoiId.offBlack],
    ]) {
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
            '${_describe(outOfPicture)} is outside the picture. Line the '
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

  static CalibrationResult _notVisible(RoiId id) => CalibrationResult.failure(
        CalibrationProblem.boardNotFullyVisible,
        'I cannot see the whole board — ${_describe(id)} is outside the '
        'picture. Move the phone back, or drag the corners onto the playing '
        'field.',
        <RoiId>[id],
      );

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

/// A region in words, for a sentence the user reads. Shared by the failure
/// messages and by [PointDiscrepancy.message], so nothing user-facing ever
/// says `offWhite`.
String _describe(RoiId id) {
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

Rgb _medianRgb(List<Rgb> samples) {
  final r = <int>[], g = <int>[], b = <int>[];
  for (final s in samples) {
    r.add(s.$1);
    g.add(s.$2);
    b.add(s.$3);
  }
  r.sort();
  g.sort();
  b.sort();
  return (r[r.length ~/ 2], g[g.length ~/ 2], b[b.length ~/ 2]);
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
