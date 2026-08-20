import 'dart:math' as math;

import 'board_geometry.dart';
import 'color_model.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'roi_atlas.dart';

/// Reading a frame in board space — the one instrument every query shares.
///
/// Calibration, occupancy and the dice reader all ask the same three things of
/// a frame: what colour is at this board-space spot, what does the whole of
/// this region look like, and what is standing on the foot of this point.
/// Having each of them answer those separately would mean three subtly
/// different lattices, three insets and three ideas of "outside the picture" —
/// and the day one of them was tuned against photographs the others would
/// quietly disagree with it. So there is one sampler, and the numbers that
/// shape it live here.
///
/// ## Numbers, provisionally
///
/// Every constant below was measured against the synthetic renderer, which
/// paints in flat colour. The corpus gate (the plan's Task 6) is where each is
/// asked again with photographs; nothing outside this file should hard-code
/// any of them.

/// A lattice of samples taken from one region, and how much of it landed
/// inside the picture.
class RoiScan {
  final List<Rgb> samples;

  /// How many samples were attempted, including those that fell outside the
  /// frame. [visibleFraction] is the ratio of the two.
  final int attempted;

  const RoiScan(this.samples, this.attempted);

  double get visibleFraction =>
      attempted == 0 ? 0.0 : samples.length / attempted;
}

/// Reads a frame at arbitrary board-space coordinates.
class FrameSampler {
  final Frame frame;

  /// How board space reaches the picture. The one seam: every sample below
  /// goes through it, so a board with two leaves and a hinge is read by
  /// exactly this code with a different [BoardGeometry] behind it.
  final BoardGeometry geometry;

  const FrameSampler(this.frame, this.geometry);

  /// The pixel at board-space `(x, y)`, or null when that is outside the
  /// picture — including the non-finite coordinates a point on the horizon
  /// produces, which the range test subsumes.
  Rgb? at(double x, double y) {
    final p = geometry.imagePointOf(Pt(x, y));
    if (!p.x.isFinite || !p.y.isFinite) return null;
    final px = p.x.round(), py = p.y.round();
    if (px < 0 || py < 0 || px >= frame.width || py >= frame.height) {
      return null;
    }
    return frame.pixelAt(px, py);
  }

  /// The mean of a small block of board space, with samples clamped into the
  /// picture rather than dropped. For the fingerprint, whose entries have to
  /// line up between two frames to be comparable.
  Rgb blockMean(double x, double y, double halfWidth, double halfHeight) {
    const lattice = 3;
    var r = 0, g = 0, b = 0, n = 0;
    for (var iy = 0; iy < lattice; iy++) {
      final sy = y + (2 * (iy + 0.5) / lattice - 1) * halfHeight;
      for (var ix = 0; ix < lattice; ix++) {
        final sx = x + (2 * (ix + 0.5) / lattice - 1) * halfWidth;
        final p = geometry.imagePointOf(Pt(sx, sy));
        if (!p.x.isFinite || !p.y.isFinite) continue;
        final px = p.x.round().clamp(0, frame.width - 1);
        final py = p.y.round().clamp(0, frame.height - 1);
        final sample = frame.pixelAt(px, py);
        r += sample.$1;
        g += sample.$2;
        b += sample.$3;
        n++;
      }
    }
    if (n == 0) return const (0, 0, 0);
    return (r ~/ n, g ~/ n, b ~/ n);
  }
}

/// Reads a frame region by region, through the atlas.
class RoiSampler extends FrameSampler {
  final RoiAtlas atlas;

  const RoiSampler(super.frame, super.geometry, this.atlas);

  /// Lattice per side for a region's interior.
  static const int interiorLattice = 20;

  /// How far in from a region's own boundary its interior lattice starts, as a
  /// fraction of the region's size.
  static const double interiorInset = 0.06;

  static const int checkerPatchAcross = 6;
  static const int checkerPatchDeep = 4;

  /// Half the checker patch's width, as a fraction of the column's width —
  /// narrow enough that a round checker still covers it at the patch's far
  /// end.
  static const double checkerPatchHalfWidth = 0.25;

  /// The checker patch's near and far depth from the board's outer edge, in
  /// board-space units. Clear of the warp's sliver of room at the near end and
  /// inside the first checker at the far end.
  static const double checkerPatchNear = 0.02;
  static const double checkerPatchFar = 0.045;

  /// How much of a lattice has to land inside the picture before the region
  /// counts as visible at all. Effectively "all of it": the lattice is already
  /// inset from the region's own boundary, so a sample outside the frame means
  /// the board itself is over the edge.
  static const double minVisibleFraction = 0.98;

  /// An inset lattice over the whole of [id].
  ///
  /// [skip] leaves parts of the region out by board-space position. Skipped
  /// spots are not counted as attempted either, so [RoiScan.visibleFraction]
  /// still means "how much of what was asked for is in the picture" rather
  /// than being dragged down by a deliberate omission.
  RoiScan interior(RoiId id, {bool Function(double x, double y)? skip}) {
    final b = boundsOf(atlas.roi(id));
    final insetX = (b.maxX - b.minX) * interiorInset;
    final insetY = (b.maxY - b.minY) * interiorInset;
    final x0 = b.minX + insetX, x1 = b.maxX - insetX;
    final y0 = b.minY + insetY, y1 = b.maxY - insetY;

    final samples = <Rgb>[];
    var attempted = 0;
    for (var iy = 0; iy < interiorLattice; iy++) {
      final y = y0 + (iy + 0.5) / interiorLattice * (y1 - y0);
      for (var ix = 0; ix < interiorLattice; ix++) {
        final x = x0 + (ix + 0.5) / interiorLattice * (x1 - x0);
        if (skip != null && skip(x, y)) continue;
        attempted++;
        final sample = at(x, y);
        if (sample != null) samples.add(sample);
      }
    }
    return RoiScan(samples, attempted);
  }

  /// The block the checker nearest the board's edge covers on point [index].
  RoiScan checkerPatch(int index) {
    final b = boundsOf(atlas.roi(RoiId.point(index)));
    // Which board edge this point stacks from: its region runs from that edge
    // to the midline, so whichever end is not the midline is the edge.
    final fromTop = b.maxY <= RoiAtlas.midline + 1e-9;
    final centreX = (b.minX + b.maxX) / 2;
    final halfWidth = (b.maxX - b.minX) * checkerPatchHalfWidth;

    final samples = <Rgb>[];
    var attempted = 0;
    for (var iy = 0; iy < checkerPatchDeep; iy++) {
      final depth = checkerPatchNear +
          (iy + 0.5) / checkerPatchDeep * (checkerPatchFar - checkerPatchNear);
      final y = fromTop ? depth : 1 - depth;
      for (var ix = 0; ix < checkerPatchAcross; ix++) {
        final x = centreX +
            ((ix + 0.5) / checkerPatchAcross - 0.5) * 2 * halfWidth;
        attempted++;
        final sample = at(x, y);
        if (sample != null) samples.add(sample);
      }
    }
    return RoiScan(samples, attempted);
  }

  /// Rows along a stack axis. Enough that one checker spans about twenty of
  /// them, so the end of a run is placed to a fiftieth of a checker.
  static const int stackRows = 120;

  /// Samples across the column on each row. A dozen resolves the width of a
  /// round checker well enough to say whether the row is under one, without
  /// paying for a fourth of the samples the whole board would otherwise cost.
  static const int stackColumns = 12;

  /// How far in from the column's own sides the profile samples, as a fraction
  /// of the column's width. Just enough to keep the neighbouring column's
  /// paint out; a checker is very nearly as wide as its column, so insetting
  /// far would measure the checker rather than the row.
  static const double stackInsetX = 0.04;

  /// What share of a row has to read as one colour before that row counts as
  /// standing under a checker of it.
  ///
  /// A round checker covers its whole row at the widest and tapers to nothing
  /// at its ends, so this threshold decides where a checker is judged to start
  /// and stop. The number itself hardly matters to the count — whatever it
  /// shaves off each end, it shaves off equally at calibration, and the fit's
  /// origin absorbs it. What it must do is sit well above the stray sample or
  /// two a shadow produces.
  static const double minRowCoverage = 0.35;

  /// The widest gap, in rows, a stack may have inside it and still be one run.
  ///
  /// Tangent discs pinch to nothing where they touch, so a synthetic stack is
  /// a chain of runs rather than one; a photograph of real checkers shows a
  /// rim there instead, which is darker again. Six rows is under a third of a
  /// checker — enough to bridge either, and far too little to swallow a die
  /// sitting in a point's headroom.
  static const int maxProfileGap = 6;

  /// Walks [axis] from its origin and reports what stands on it.
  ///
  /// One pass, both colours, because the bar carries both and because the
  /// wrong colour showing up on a point is exactly what a confidence needs to
  /// know. Classification goes through [colors], which the caller is
  /// responsible for having re-normalized for this frame's light — see
  /// `BoardCalibration.colorsIn`.
  StackMeasurement measureStack(StackAxis axis, ColorModel colors) {
    final background = colors.backgroundOf(axis.region);
    final insetX = (axis.maxX - axis.minX) * stackInsetX;
    final x0 = axis.minX + insetX, x1 = axis.maxX - insetX;

    final whiteRows = List<double>.filled(stackRows, 0);
    final blackRows = List<double>.filled(stackRows, 0);
    var whiteTotal = 0, blackTotal = 0, seen = 0;

    for (var r = 0; r < stackRows; r++) {
      final y = axis.yAt((r + 0.5) / stackRows * axis.reach);
      var white = 0, black = 0, taken = 0;
      for (var c = 0; c < stackColumns; c++) {
        final sample = at(x0 + (c + 0.5) / stackColumns * (x1 - x0), y);
        if (sample == null) continue;
        taken++;
        switch (colors.classify(sample, background)) {
          case CheckerColor.white:
            white++;
          case CheckerColor.black:
            black++;
          case CheckerColor.none:
            break;
        }
      }
      seen += taken;
      whiteTotal += white;
      blackTotal += black;
      if (taken == 0) continue;
      whiteRows[r] = white / taken;
      blackRows[r] = black / taken;
    }

    final attempted = stackRows * stackColumns;
    final rowDepth = axis.reach / stackRows;
    return StackMeasurement(
      whiteMass: seen == 0 ? 0.0 : whiteTotal / seen,
      blackMass: seen == 0 ? 0.0 : blackTotal / seen,
      whiteReach: _runReach(whiteRows, rowDepth),
      blackReach: _runReach(blackRows, rowDepth),
      visibleFraction: attempted == 0 ? 0.0 : seen / attempted,
    );
  }

  /// How far the run of covered rows starting at the origin reaches.
  static double _runReach(List<double> coverage, double rowDepth) {
    var last = -1;
    for (var r = 0; r < coverage.length; r++) {
      if (coverage[r] < minRowCoverage) continue;
      if (r - last > maxProfileGap + 1) break;
      last = r;
    }
    return last < 0 ? 0.0 : (last + 0.5) * rowDepth;
  }
}

/// The line a region's checkers stack along, in board space.
///
/// Every region on a backgammon board is a queue with a known end. A point's
/// stack grows from that point's own edge of the board toward the middle; a
/// bear-off tray's grows from the outer edge inward; the bar's grows from the
/// middle *outward*, each colour toward its own player's edge, which is the
/// one case where the axis depends on whose checkers are being asked about.
/// Depth is measured from wherever the first checker sits, so a stack of one
/// looks the same on all four kinds of region.
class StackAxis {
  /// Which region this axis belongs to — carried so a measurement can look up
  /// that region's learned background.
  final RoiId region;

  /// Board-space y the first checker of a stack sits against.
  final double startY;

  /// `+1` when depth grows with y, `-1` when it shrinks.
  final double directionY;

  /// How far the region reaches along the axis, in board-space units.
  final double reach;

  /// The column the stack occupies, in board space.
  final double minX;
  final double maxX;

  const StackAxis({
    required this.region,
    required this.startY,
    required this.directionY,
    required this.reach,
    required this.minX,
    required this.maxX,
  });

  /// The axis [region]'s stacks grow along, for [color]'s checkers.
  ///
  /// [color] matters only on the bar, where the two colours stack away from
  /// each other; everywhere else a region holds one queue and the colour is
  /// what the queue turns out to be.
  factory StackAxis.forRegion(
    RoiAtlas atlas,
    RoiId region, {
    CheckerColor color = CheckerColor.white,
  }) {
    final b = boundsOf(atlas.roi(region));
    if (region == RoiId.bar) {
      // Which edge is "White's own" is what the seating says, and the atlas
      // carries the seating.
      final whiteNear = atlas.orientation == BoardOrientation.whiteHomeNear;
      final towardNear = (color == CheckerColor.white) == whiteNear;
      return StackAxis(
        region: region,
        startY: RoiAtlas.midline,
        directionY: towardNear ? 1.0 : -1.0,
        reach: RoiAtlas.midline,
        minX: b.minX,
        maxX: b.maxX,
      );
    }
    // A point or a tray runs from one board edge to the midline; whichever end
    // is not the midline is the edge its stack sits against.
    final fromFarEdge = b.maxY <= RoiAtlas.midline + 1e-9;
    return StackAxis(
      region: region,
      startY: fromFarEdge ? b.minY : b.maxY,
      directionY: fromFarEdge ? 1.0 : -1.0,
      reach: b.maxY - b.minY,
      minX: b.minX,
      maxX: b.maxX,
    );
  }

  /// The board-space y at [depth] along the axis.
  double yAt(double depth) => startY + directionY * depth;

  @override
  String toString() => 'StackAxis(${region.name}, from '
      '${startY.toStringAsFixed(2)} by ${directionY.toStringAsFixed(0)})';
}

/// What one stack axis showed, for both colours at once.
///
/// Both colours are measured in the same pass because the bar holds both and
/// because a point that reads a little of the wrong colour is exactly the case
/// a confidence has to know about.
class StackMeasurement {
  /// Share of the profile's samples that read as each colour.
  final double whiteMass;
  final double blackMass;

  /// How far each colour's run reaches from the stack's origin, in board-space
  /// units. Zero when that colour was not found at the origin end at all.
  ///
  /// A *run*, not a scattering: the walk starts at the origin and stops at the
  /// first gap wider than [maxProfileGap]. A blob floating in the middle of a
  /// region — a die in a point's headroom, a hand's shadow — is therefore not
  /// counted as part of the stack unless it is touching it.
  final double whiteReach;
  final double blackReach;

  /// How much of the profile landed inside the picture.
  final double visibleFraction;

  const StackMeasurement({
    required this.whiteMass,
    required this.blackMass,
    required this.whiteReach,
    required this.blackReach,
    required this.visibleFraction,
  });

  double massOf(CheckerColor color) => switch (color) {
        CheckerColor.white => whiteMass,
        CheckerColor.black => blackMass,
        CheckerColor.none => 0.0,
      };

  double reachOf(CheckerColor color) => switch (color) {
        CheckerColor.white => whiteReach,
        CheckerColor.black => blackReach,
        CheckerColor.none => 0.0,
      };

  /// Whichever colour covers more of the profile, or [CheckerColor.none] when
  /// neither covers enough to be a checker.
  CheckerColor dominant(double minMass) {
    if (whiteMass < minMass && blackMass < minMass) return CheckerColor.none;
    return whiteMass >= blackMass ? CheckerColor.white : CheckerColor.black;
  }

  @override
  String toString() => 'StackMeasurement(white ${whiteMass.toStringAsFixed(3)}'
      '/${whiteReach.toStringAsFixed(3)}, black '
      '${blackMass.toStringAsFixed(3)}/${blackReach.toStringAsFixed(3)})';
}

/// How a stack of *this* board's checkers grows, in board-space units.
///
/// The one number that turns a measured length into a count, and it is
/// **learned, never written down**. Board space is a unit square whichever
/// shape the physical board is, so how far one checker reaches along a stack
/// axis depends on the board's proportions — a number the atlas cannot supply
/// and a constant here would get wrong for every board but one.
///
/// Calibration measures it from the only frame that comes with labels: the
/// starting position stands stacks of two, three and five on both halves, so
/// fitting reach against known height is a three-point regression with the
/// board's own checkers.
///
/// **What this does not model.** A real checker is a disc with height, and a
/// tall stack's top leans toward the camera, so its footprint in board space
/// grows a little faster than linearly. The synthetic bed paints flat discs
/// and cannot show that; the corpus gate (the plan's Task 6) is where it turns
/// up, and a quadratic term is the obvious answer if it does.
class StackMetrics {
  /// Board-space depth one more checker adds.
  final double pitch;

  /// The depth a stack of no checkers would reach — the gap between the board
  /// edge and where the first checker's own edge starts, plus whatever the
  /// coverage threshold shaves off each end. Absorbed here so that
  /// `count = (reach - origin) / pitch`.
  final double origin;

  /// Whether the fit had enough distinct stack heights behind it to be worth
  /// trusting. False means [pitch] is a single ratio rather than a regression,
  /// and occupancy says so in its confidence.
  final bool wellConditioned;

  const StackMetrics({
    required this.pitch,
    required this.origin,
    required this.wellConditioned,
  });

  /// Narrower than this and a "pitch" is noise; wider and it is not a stack of
  /// checkers. A point's region is half the board deep and five checkers very
  /// nearly fill it, which puts the true value near a tenth either side.
  static const double minPitch = 0.02;
  static const double maxPitch = 0.15;

  /// Least squares through `(height, reach)` pairs.
  ///
  /// Falls back to the median of `reach / height` when the heights on offer do
  /// not span enough to fit a line — one ratio is a worse instrument than a
  /// regression, but it is a great deal better than refusing to count.
  factory StackMetrics.fit(List<(int height, double reach)> samples) {
    final usable = samples.where((s) => s.$1 > 0 && s.$2 > 0).toList();
    if (usable.isEmpty) {
      return const StackMetrics(pitch: 0, origin: 0, wellConditioned: false);
    }
    final heights = usable.map((s) => s.$1).toSet();
    if (heights.length >= 2) {
      var meanK = 0.0, meanR = 0.0;
      for (final s in usable) {
        meanK += s.$1;
        meanR += s.$2;
      }
      meanK /= usable.length;
      meanR /= usable.length;
      var num = 0.0, den = 0.0;
      for (final s in usable) {
        final dk = s.$1 - meanK;
        num += dk * (s.$2 - meanR);
        den += dk * dk;
      }
      final pitch = den == 0 ? 0.0 : num / den;
      if (pitch >= minPitch && pitch <= maxPitch) {
        return StackMetrics(
          pitch: pitch,
          origin: meanR - pitch * meanK,
          wellConditioned: heights.length >= 3 && usable.length >= 4,
        );
      }
    }
    final ratios = usable.map((s) => s.$2 / s.$1).toList()..sort();
    return StackMetrics(
      pitch: ratios[ratios.length ~/ 2],
      origin: 0,
      wellConditioned: false,
    );
  }

  /// How many checkers a run of [reach] is, before any rounding.
  double heightOf(double reach) =>
      pitch <= 0 ? 0.0 : (reach - origin) / pitch;

  @override
  String toString() => 'StackMetrics(pitch ${pitch.toStringAsFixed(4)}, '
      'origin ${origin.toStringAsFixed(4)}'
      '${wellConditioned ? '' : ', poorly conditioned'})';
}

/// A region's extent in board space, as an axis-aligned box.
typedef BoardBounds = ({double minX, double minY, double maxX, double maxY});

/// The axis-aligned box [quad] fits inside, in whatever plane it was given in.
BoardBounds boundsOf(BoardQuad quad) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final c in quad.corners) {
    minX = math.min(minX, c.x);
    minY = math.min(minY, c.y);
    maxX = math.max(maxX, c.x);
    maxY = math.max(maxY, c.y);
  }
  return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
}

/// BT.601 luma of a sample — the one brightness number the package uses, so
/// the fingerprint's exposure statistics and the dice reader's contrast are
/// measured on the same scale.
double lumaOf(Rgb sample) =>
    0.299 * sample.$1 + 0.587 * sample.$2 + 0.114 * sample.$3;
