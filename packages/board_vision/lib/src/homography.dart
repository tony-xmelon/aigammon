import 'dart:typed_data';

import 'geometry_types.dart';

/// The projective map between a frame's pixels and the unit board square.
///
/// A backgammon board is flat and a camera is a pinhole, so the two planes are
/// related by a homography: eight degrees of freedom, exactly determined by
/// four point correspondences. Calibration supplies those four — the playing
/// field's corners as the user placed them (or as auto-detection proposed) —
/// and everything downstream addresses the board in the unit square
/// `(0,0)`–`(1,1)` described by [RoiAtlas], never in pixels.
///
/// Solved by the direct linear transform: each correspondence contributes two
/// linear equations in the eight unknowns (the ninth entry is fixed at 1,
/// which is legitimate for any map that does not send the board's plane
/// through the camera's centre), and the 8x8 system is solved by Gaussian
/// elimination with partial pivoting. No package dependency, deliberately —
/// this is thirty lines of arithmetic and the alternative is a linear-algebra
/// dependency in a package that must stay pure Dart.
///
/// The synthetic test-bed under `test/synthetic/` carries a second, smaller
/// solver written the other way round. That duplication is on purpose: the
/// atlas and calibration tests would otherwise be checking a solver against
/// itself.
///
/// **Points on the horizon.** A homography sends one line of the image plane
/// to infinity. [mapToBoard] and [mapToImage] return non-finite coordinates
/// for points on (or across) it rather than throwing — callers sampling near
/// the frame's edges should reject non-finite results, which is cheaper than
/// an exception on a hot sampling loop.
class Homography {
  /// Row-major 3x3, image pixels to board space.
  final Float64List _toBoard;

  /// Row-major 3x3, board space to image pixels — the inverse of [_toBoard].
  final Float64List _toImage;

  Homography._(this._toBoard, this._toImage);

  /// The map taking [imageCorners] onto the unit board square.
  ///
  /// Corner identity is the contract: [BoardQuad.topLeft] becomes `(0,0)`,
  /// [BoardQuad.topRight] `(1,0)`, [BoardQuad.bottomRight] `(1,1)` and
  /// [BoardQuad.bottomLeft] `(0,1)`. Which physical corner is "top left" is
  /// what fixes the board's rotation in the frame; pairing it with a
  /// [BoardOrientation] is what fixes the point numbering.
  ///
  /// Throws [ArgumentError] when the four corners do not define a projective
  /// map — any three of them collinear, any two coincident, or a coordinate
  /// that is not finite. Convexity is *not* required: a quad whose corners
  /// were labelled in the wrong order still solves, it simply produces a
  /// mirrored or twisted board, which is a calibration-flow problem rather
  /// than an arithmetic one.
  factory Homography.fromQuad(BoardQuad imageCorners) {
    final corners = imageCorners.corners;
    _rejectDegenerate(imageCorners, corners);
    final toBoard = _solveToUnitSquare(corners);
    return Homography._(toBoard, _invert(toBoard, imageCorners));
  }

  /// Where the pixel [imagePoint] falls on the board, in board space.
  Pt mapToBoard(Pt imagePoint) => _apply(_toBoard, imagePoint);

  /// Which pixel the board-space point [boardPoint] was photographed at.
  Pt mapToImage(Pt boardPoint) => _apply(_toImage, boardPoint);

  static Pt _apply(Float64List m, Pt p) {
    final w = m[6] * p.x + m[7] * p.y + m[8];
    return Pt(
      (m[0] * p.x + m[1] * p.y + m[2]) / w,
      (m[3] * p.x + m[4] * p.y + m[5]) / w,
    );
  }

  /// The unit square's corners, in [BoardQuad.corners] order.
  static const List<Pt> _unitSquare = <Pt>[
    Pt(0, 0),
    Pt(1, 0),
    Pt(1, 1),
    Pt(0, 1),
  ];

  /// The DLT proper: eight rows of
  ///
  /// ```text
  /// u * (h20 x + h21 y + 1) = h00 x + h01 y + h02
  /// v * (h20 x + h21 y + 1) = h10 x + h11 y + h12
  /// ```
  ///
  /// rearranged so each is linear in the eight unknowns.
  static Float64List _solveToUnitSquare(List<Pt> corners) {
    final a = Float64List(64);
    final b = Float64List(8);
    for (var i = 0; i < 4; i++) {
      final x = corners[i].x, y = corners[i].y;
      final u = _unitSquare[i].x, v = _unitSquare[i].y;
      final row = i * 2 * 8;
      a[row] = x;
      a[row + 1] = y;
      a[row + 2] = 1;
      a[row + 6] = -x * u;
      a[row + 7] = -y * u;
      b[i * 2] = u;
      final next = row + 8;
      a[next + 3] = x;
      a[next + 4] = y;
      a[next + 5] = 1;
      a[next + 6] = -x * v;
      a[next + 7] = -y * v;
      b[i * 2 + 1] = v;
    }
    final h = _solve(a, b, 8);
    return Float64List.fromList(<double>[
      h[0], h[1], h[2], //
      h[3], h[4], h[5], //
      h[6], h[7], 1.0, //
    ]);
  }

  /// Gaussian elimination with partial pivoting, then back substitution.
  /// [a] is row-major `n x n` and is consumed; [b] likewise.
  static Float64List _solve(Float64List a, Float64List b, int n) {
    // Pivots are judged against the system's own magnitude: image coordinates
    // run to thousands, so an absolute epsilon would mean something different
    // for a 4K frame than for a preview-sized one.
    var scale = 0.0;
    for (final value in a) {
      final m = value.abs();
      if (m > scale) scale = m;
    }
    final tiny = scale * 1e-12;

    for (var col = 0; col < n; col++) {
      var pivot = col;
      var best = a[col * n + col].abs();
      for (var r = col + 1; r < n; r++) {
        final v = a[r * n + col].abs();
        if (v > best) {
          best = v;
          pivot = r;
        }
      }
      if (best <= tiny) {
        throw ArgumentError('degenerate quad: the four corners do not '
            'determine a projective map');
      }
      if (pivot != col) {
        for (var c = col; c < n; c++) {
          final t = a[col * n + c];
          a[col * n + c] = a[pivot * n + c];
          a[pivot * n + c] = t;
        }
        final t = b[col];
        b[col] = b[pivot];
        b[pivot] = t;
      }
      final p = a[col * n + col];
      for (var r = col + 1; r < n; r++) {
        final f = a[r * n + col] / p;
        if (f == 0) continue;
        a[r * n + col] = 0;
        for (var c = col + 1; c < n; c++) {
          a[r * n + c] -= f * a[col * n + c];
        }
        b[r] -= f * b[col];
      }
    }

    final x = Float64List(n);
    for (var r = n - 1; r >= 0; r--) {
      var sum = b[r];
      for (var c = r + 1; c < n; c++) {
        sum -= a[r * n + c] * x[c];
      }
      x[r] = sum / a[r * n + r];
    }
    return x;
  }

  /// Adjugate over determinant. A homography is only defined up to scale, so
  /// the division is cosmetic — it keeps `m[8]` near 1 and the numbers
  /// readable in a debugger.
  static Float64List _invert(Float64List m, BoardQuad quad) {
    final c00 = m[4] * m[8] - m[5] * m[7];
    final c01 = m[5] * m[6] - m[3] * m[8];
    final c02 = m[3] * m[7] - m[4] * m[6];
    final det = m[0] * c00 + m[1] * c01 + m[2] * c02;
    if (det == 0 || !det.isFinite) {
      throw ArgumentError.value(
          quad, 'imageCorners', 'corners produce a singular map');
    }
    return Float64List.fromList(<double>[
      c00 / det,
      (m[2] * m[7] - m[1] * m[8]) / det,
      (m[1] * m[5] - m[2] * m[4]) / det,
      c01 / det,
      (m[0] * m[8] - m[2] * m[6]) / det,
      (m[2] * m[3] - m[0] * m[5]) / det,
      c02 / det,
      (m[1] * m[6] - m[0] * m[7]) / det,
      (m[0] * m[4] - m[1] * m[3]) / det,
    ]);
  }

  /// Refuses corners that cannot define a map, *before* the solver has to
  /// discover it from a vanishing pivot — a geometric test gives the caller a
  /// message about corners rather than about arithmetic, and the calibration
  /// flow shows that message to a user dragging handles.
  static void _rejectDegenerate(BoardQuad quad, List<Pt> corners) {
    for (final c in corners) {
      if (!c.x.isFinite || !c.y.isFinite) {
        throw ArgumentError.value(
            quad, 'imageCorners', 'corner $c is not a finite point');
      }
    }

    // The quad's own size, as a squared distance, so the collinearity
    // threshold below is relative to it (both are areas).
    var scale = 0.0;
    for (var i = 0; i < 4; i++) {
      for (var j = i + 1; j < 4; j++) {
        final dx = corners[i].x - corners[j].x;
        final dy = corners[i].y - corners[j].y;
        final d = dx * dx + dy * dy;
        if (d > scale) scale = d;
      }
    }
    if (scale == 0) {
      throw ArgumentError.value(
          quad, 'imageCorners', 'all four corners are the same point');
    }

    for (var i = 0; i < 4; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % 4];
      final c = corners[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
      if (cross.abs() <= scale * 1e-9) {
        throw ArgumentError.value(
            quad,
            'imageCorners',
            'corners $a, $b and $c are collinear (or coincident); a '
                'homography needs four corners in general position');
      }
    }
  }

  @override
  String toString() => 'Homography(image->board '
      '[${_toBoard.map((v) => v.toStringAsPrecision(6)).join(', ')}])';
}
