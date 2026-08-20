import 'dart:math' as math;

import 'calibration.dart';
import 'color_model.dart';
import 'frame.dart';
import 'roi_atlas.dart';
import 'roi_sampler.dart';

/// What one region of the board holds, as far as a single frame can say.
class RegionOccupancy {
  final RoiId region;

  /// Whose checkers are there, or [CheckerColor.none] when the region reads
  /// bare. Never a guess between the two: the colours are what calibration
  /// learned from this board, and a region showing neither of them reads as
  /// nothing rather than as the nearer one.
  final CheckerColor color;

  /// How many checkers of [color]. Zero exactly when [color] is
  /// [CheckerColor.none].
  final int count;

  /// How much this reading is worth, from 0 to 1.
  ///
  /// Not a probability, and deliberately not calibrated as one — it is a
  /// product of the things that are known to make a reading worse, so that
  /// Task 7's diff-matching can weigh two regions against each other. What
  /// pushes it down: a tall stack (the count is a length divided by a pitch,
  /// so its error grows with the length), a length that lands between two
  /// whole numbers of checkers, a region whose bare appearance calibration
  /// only ever borrowed, and a region part of which is outside the picture.
  final double confidence;

  /// How far the run of checkers reached, in board-space units — the raw
  /// measurement [count] was rounded from. Kept for the harness, which scores
  /// counting error and wants to see where the rounding went.
  final double reach;

  /// Share of the region's profile that read as [color].
  final double mass;

  const RegionOccupancy({
    required this.region,
    required this.color,
    required this.count,
    required this.confidence,
    required this.reach,
    required this.mass,
  });

  bool get isEmpty => count == 0;

  @override
  String toString() => 'RegionOccupancy(${region.name}: ${color.name} x$count '
      '@${confidence.toStringAsFixed(2)})';
}

/// How many checkers of what colour each region holds, from one frame.
///
/// ## Why a blind count is only trusted to two
///
/// A count here is a length divided by a length: how far a run of checker-
/// coloured rows reaches along the region's stack axis, over how far one
/// checker reaches (which calibration measured from the starting position).
/// Both are measured through a perspective warp, on regions the far half of
/// the board renders small, and the numerator's error does not shrink as the
/// stack grows — so the quotient's error grows roughly with the stack. Zero,
/// one and two are separated by whole checkers of margin; five and six are
/// separated by the same absolute margin over five times the length.
///
/// **This is the right instrument anyway**, because the design never asks it
/// an open question. Mid-game, the app holds the authoritative state, so the
/// question is always "which of these enumerated legal plays happened?" — and
/// the expected deltas there are ±1 or ±2 on a handful of named regions, which
/// is precisely the range a blind count is good at. Task 7's play matcher
/// consumes these as differences against an expected board, and Task 8's stack
/// verifier checks a *specific* K rather than asking for one. A whole-board
/// blind read exists only for the start-of-session confirmation and for drift
/// recovery, both of which are primed by an expected position too.
///
/// The one direction the error is known to run: `ColorModel.classify` breaks
/// ties toward "checker" on purpose, so a pale point in bright light adds
/// checker-coloured rows rather than losing them, and mass-based occupancy
/// over-counts rather than under-counts as the light climbs. That is a
/// deliberate trade — a checker that vanishes is worse than one that appears,
/// because the appearing one contradicts an expected state and gets asked
/// about.
///
/// ## Numbers, provisionally
///
/// Every threshold on this class was measured against the synthetic renderer.
/// Real checkers are discs with height, stacked so their rims show and their
/// tops lean toward the camera; the corpus gate (the plan's Task 6) is where
/// each of these is asked again with photographs.
class OccupancyReader {
  /// The board this is reading, and the colours it learned.
  final BoardCalibration calibration;

  final Frame frame;

  /// [calibration]'s colours, re-normalized for [frame]'s own light.
  ///
  /// Taken once here rather than per region: every query in this class reads
  /// the same frame, and a background measured at calibration under a
  /// different light stops cancelling in the ratio the model is built on. A
  /// caller who classified against the raw model would inherit exactly the
  /// auto-exposure bug the calibration flow already had to close.
  final ColorModel colors;

  final RoiSampler _sampler;

  OccupancyReader(this.calibration, this.frame)
      : colors = calibration.colorsIn(frame),
        _sampler = RoiSampler(frame, calibration.h, calibration.atlas);

  /// What share of a region's profile has to read as one colour before a
  /// checker is called there.
  ///
  /// One checker covers between a twentieth and a seventh of its region's
  /// profile depending on the region — a point's column is narrow and its
  /// profile short, the bar's and a tray's are wider and longer. This sits
  /// under the smallest of those by a good margin and far above what a stray
  /// misclassified sample produces.
  static const double minPresenceMass = 0.03;

  /// How much doubt each checker past the first adds, as a fraction. A five
  /// stack therefore keeps under two thirds of the confidence a single checker
  /// gets, which is the "trusted only to two" rule expressed as a number
  /// rather than a comment.
  static const double doubtPerChecker = 0.15;

  /// What is left of a reading's confidence when the measured length lands
  /// squarely between two whole checkers.
  static const double worstFractionalFit = 0.2;

  /// What is left when a region reads bare but calibration never saw it bare —
  /// the eight points the starting position covers and the dice band. Their
  /// idea of "board surface" is the board's general vocabulary rather than
  /// their own, so "nothing here" is a weaker claim there than elsewhere.
  static const double borrowedBackgroundTrust = 0.6;

  /// The same, for a region that reads as *holding* checkers: a positive
  /// reading leans on the checker distributions, which were measured properly,
  /// so it loses much less.
  static const double borrowedBackgroundTrustOccupied = 0.9;

  /// What is left when the pitch behind the count was a single ratio rather
  /// than a regression over several stack heights.
  static const double poorlyConditionedTrust = 0.6;

  /// What [region] holds — whichever colour covers more of it.
  ///
  /// On the bar, where both colours stack away from each other at once, this
  /// reports the one with more of the region and [readFor] gives each
  /// separately. Task 7 wants both, since every hit routes through there.
  RegionOccupancy read(RoiId region) {
    if (region == RoiId.bar) {
      final white = readFor(region, CheckerColor.white);
      final black = readFor(region, CheckerColor.black);
      if (white.count == 0 && black.count == 0) return white;
      return white.mass >= black.mass ? white : black;
    }
    final measured = _sampler.measureStack(
      StackAxis.forRegion(calibration.atlas, region),
      colors,
    );
    return _resolve(region, measured, measured.dominant(minPresenceMass));
  }

  /// What [region] holds of [color] alone.
  ///
  /// The bar is the reason this exists: its two stacks grow in opposite
  /// directions from the middle, so each has its own axis and neither can be
  /// read off the other's profile.
  RegionOccupancy readFor(RoiId region, CheckerColor color) {
    if (color == CheckerColor.none) {
      return RegionOccupancy(
        region: region,
        color: CheckerColor.none,
        count: 0,
        confidence: 0,
        reach: 0,
        mass: 0,
      );
    }
    final measured = _sampler.measureStack(
      StackAxis.forRegion(calibration.atlas, region, color: color),
      colors,
    );
    final present = measured.massOf(color) >= minPresenceMass;
    return _resolve(
      region,
      measured,
      present ? color : CheckerColor.none,
      only: color,
    );
  }

  /// Every region a game is played on: the twenty-four points, the bar, and
  /// both trays on a board that has them.
  ///
  /// A folding-case board has no bear-off wells — borne-off checkers leave it
  /// — so this yields twenty-five regions there rather than twenty-seven. It
  /// asks the atlas rather than the enum for exactly that reason.
  Map<RoiId, RegionOccupancy> readAll() => <RoiId, RegionOccupancy>{
        for (final id in calibration.atlas.regions)
          if (id != RoiId.diceZone) id: read(id),
      };

  RegionOccupancy _resolve(
    RoiId region,
    StackMeasurement measured,
    CheckerColor color, {
    CheckerColor? only,
  }) {
    final background = colors.backgroundOf(region);
    if (color == CheckerColor.none) {
      return RegionOccupancy(
        region: region,
        color: CheckerColor.none,
        count: 0,
        confidence: _confidenceOfEmpty(background, measured),
        reach: 0,
        mass: only == null
            ? math.max(measured.whiteMass, measured.blackMass)
            : measured.massOf(only),
      );
    }

    final reach = measured.reachOf(color);
    final height = calibration.stacks.heightOf(reach);
    final count = math.max(1, height.round());
    final fractional = (height - height.roundToDouble()).abs();

    var confidence = 1.0;
    confidence *= 1 / (1 + (count - 1) * doubtPerChecker);
    confidence *= math.max(
      worstFractionalFit,
      1 - 2 * fractional * (1 - worstFractionalFit),
    );
    if (!background.fullyMeasured) {
      confidence *= borrowedBackgroundTrustOccupied;
    }
    if (!calibration.stacks.wellConditioned) {
      confidence *= poorlyConditionedTrust;
    }
    confidence *= _visibility(measured);

    return RegionOccupancy(
      region: region,
      color: color,
      count: count,
      confidence: confidence.clamp(0.0, 1.0),
      reach: reach,
      mass: measured.massOf(color),
    );
  }

  double _confidenceOfEmpty(
    RoiBackground background,
    StackMeasurement measured,
  ) {
    var confidence = 1.0;
    if (!background.fullyMeasured) confidence *= borrowedBackgroundTrust;
    // Whatever checker colour there IS in the region, short of a whole
    // checker's worth, is the strongest argument against "bare".
    final stray = math.max(measured.whiteMass, measured.blackMass);
    confidence *= math.max(0.0, 1 - stray / minPresenceMass);
    confidence *= _visibility(measured);
    return confidence.clamp(0.0, 1.0);
  }

  /// A region hanging over the edge of the picture cannot be read, and saying
  /// so through the confidence is better than inventing a count: the app's
  /// readability light is what tells the user, and Task 9 owns that.
  double _visibility(StackMeasurement measured) =>
      measured.visibleFraction >= RoiSampler.minVisibleFraction
          ? 1.0
          : measured.visibleFraction * measured.visibleFraction;
}
