import 'dart:math' as math;

import 'color_model.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'homography.dart';
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
  final Homography homography;

  const FrameSampler(this.frame, this.homography);

  /// The pixel at board-space `(x, y)`, or null when that is outside the
  /// picture — including the non-finite coordinates a point on the horizon
  /// produces, which the range test subsumes.
  Rgb? at(double x, double y) {
    final p = homography.mapToImage(Pt(x, y));
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
        final p = homography.mapToImage(Pt(sx, sy));
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

  const RoiSampler(super.frame, super.homography, this.atlas);

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
  RoiScan interior(RoiId id) {
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
