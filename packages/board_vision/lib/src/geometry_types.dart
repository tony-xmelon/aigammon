/// A point with double precision, in whichever plane the surrounding API says.
///
/// Two planes exist in this package and they are never mixed silently:
///
/// * **image space** — pixels of a [Frame], x right / y down, origin at the
///   top-left pixel's centre-ish corner;
/// * **board space** — the playing field as the unit rectangle `(0,0)`–`(1,1)`
///   (see the ROI atlas), x toward White's right, y from the far edge to the
///   near edge.
///
/// The homography between them is what calibration produces.
class Pt {
  final double x;
  final double y;

  const Pt(this.x, this.y);

  @override
  bool operator ==(Object other) =>
      other is Pt && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Pt($x, $y)';
}

/// The four corners of the playing field, in image space.
///
/// This is what the user drags into place during calibration and what the
/// synthetic renderer reports as ground truth. Corner *identity* matters as
/// much as position: which physical corner is "top left" is what fixes the
/// board's rotation, and pairing it with a [BoardOrientation] is what fixes
/// the point numbering.
///
/// The corners are stored — and returned by [corners] — **clockwise starting
/// at the top left**, as seen in the frame.
class BoardQuad {
  final Pt topLeft;
  final Pt topRight;
  final Pt bottomRight;
  final Pt bottomLeft;

  const BoardQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  /// The quad of an axis-aligned [width] x [height] rectangle at the origin —
  /// the source quad of an un-warped top-down render.
  BoardQuad.rect(double width, double height)
      : topLeft = const Pt(0, 0),
        topRight = Pt(width, 0),
        bottomRight = Pt(width, height),
        bottomLeft = Pt(0, height);

  /// Rebuilds a quad from four points in [corners] order.
  factory BoardQuad.fromCorners(List<Pt> corners) {
    if (corners.length != 4) {
      throw ArgumentError('a quad needs exactly 4 corners, '
          'got ${corners.length}');
    }
    return BoardQuad(
      topLeft: corners[0],
      topRight: corners[1],
      bottomRight: corners[2],
      bottomLeft: corners[3],
    );
  }

  /// Clockwise from the top left: `[topLeft, topRight, bottomRight,
  /// bottomLeft]`. Homography solves consume this order on both sides.
  List<Pt> get corners => [topLeft, topRight, bottomRight, bottomLeft];

  @override
  bool operator ==(Object other) =>
      other is BoardQuad &&
      other.topLeft == topLeft &&
      other.topRight == topRight &&
      other.bottomRight == bottomRight &&
      other.bottomLeft == bottomLeft;

  @override
  int get hashCode => Object.hash(topLeft, topRight, bottomRight, bottomLeft);

  @override
  String toString() =>
      'BoardQuad($topLeft, $topRight, $bottomRight, $bottomLeft)';
}

/// Which end of the board White bears off toward, from the camera's point of
/// view.
///
/// The user's seat fixes this: the setup flow asks which side of the table
/// they sit on and which colour Buddy plays, and the calibration flow has them
/// confirm which half is their home board. Together with a [BoardQuad] it
/// pins the 24-point coordinate frame, so nothing downstream ever has to guess
/// the board's rotation from pixels.
enum BoardOrientation {
  /// White's home board is the near half of the frame (the bottom, and — with
  /// the standard layout — the bottom-right quadrant). Points 1..6 are
  /// bottom-right, 7..12 bottom-left, 13..18 top-left, 19..24 top-right.
  whiteHomeNear,

  /// The same board seen from the other side of the table: everything is
  /// rotated by 180 degrees, so White's home board is the far half.
  whiteHomeFar,
}
