import 'geometry_types.dart';
import 'homography.dart';

/// Where a board-space point was photographed — the one seam between board
/// space and pixels.
///
/// ## Why this exists rather than a bare [Homography]
///
/// Everything downstream of calibration addresses the board as the unit square
/// the ROI atlas describes: the colour model, the sampler, occupancy, the dice
/// reader, the start-position check and the fingerprint all say "board space"
/// and never "pixels". Exactly one arrow crosses that line — *which pixel is
/// this board-space point?* — and until now that arrow was a homography,
/// because a flat board photographed by a pinhole is a homography and nothing
/// else.
///
/// A folding-case board is not flat. Its two leaves hinge, and a case standing
/// on a table sits very slightly tented: measured on the first real board, a
/// single homography fitted to the four outer corners rectifies the two halves
/// to column pitches 13% apart, which is physically impossible for two
/// identical leaves and is the signature of the tent. Each leaf on its own
/// rectifies cleanly. So the map is not one projective map, it is one *per
/// plane* — and the seam has to be the map, not the matrix.
///
/// Everything on the other side of the seam is unchanged by that, which is the
/// whole point of putting the abstraction here: the atlas still describes one
/// unit square, the colour model still learns one board, occupancy still walks
/// one stack axis. Only this one call knows how many planes the board has.
abstract interface class BoardGeometry {
  /// Which pixel the board-space point [boardPoint] was photographed at.
  ///
  /// NEVER throws, including for points a projective map sends to infinity:
  /// the result is non-finite there, and callers on a hot sampling loop reject
  /// by range instead. See [Homography] for why.
  Pt imagePointOf(Pt boardPoint);
}

/// A board that is flat, which is every board but a folding case: one
/// [Homography] over the whole playing field.
///
/// Behaviourally this is the bare homography it wraps and nothing else — it
/// exists so that the flat board and the folding one are the same kind of
/// thing to every consumer.
class PlanarBoardGeometry implements BoardGeometry {
  /// The map this geometry is. Exposed because a caller that genuinely wants
  /// the inverse — image pixels back into board space — can only have one on a
  /// board with a single plane, and asking for it should not be indirect.
  final Homography homography;

  const PlanarBoardGeometry(this.homography);

  /// The geometry of a board whose playing field has [corners] in the frame.
  ///
  /// Throws [ArgumentError] on four corners that do not define a projective
  /// map, exactly as [Homography.fromQuad] does.
  factory PlanarBoardGeometry.fromQuad(BoardQuad corners) =>
      PlanarBoardGeometry(Homography.fromQuad(corners));

  @override
  Pt imagePointOf(Pt boardPoint) => homography.mapToImage(boardPoint);

  @override
  String toString() => 'PlanarBoardGeometry($homography)';
}
