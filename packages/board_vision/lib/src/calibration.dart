import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';

import 'color_model.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'homography.dart';
import 'roi_atlas.dart';

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

  /// Takes a fingerprint of [frame] through the calibration's [homography].
  ///
  /// Samples that fall outside the picture are clamped to its border rather
  /// than dropped: a fingerprint has to be the same size every time to be
  /// comparable, and a corner patch that reaches past the edge of the frame is
  /// itself stable information about where the board sits.
  factory CalibrationFingerprint.fromFrame(Frame frame, Homography homography) {
    final sampler = _FrameSampler(frame, homography);
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
    const inset = 0.05, lattice = 24;
    for (var iy = 0; iy < lattice; iy++) {
      final y = inset + (iy + 0.5) / lattice * (1 - 2 * inset);
      for (var ix = 0; ix < lattice; ix++) {
        final x = inset + (ix + 0.5) / lattice * (1 - 2 * inset);
        final sample = sampler.at(x, y);
        if (sample == null) continue;
        final luma = _luma(sample);
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
  bool matches(CalibrationFingerprint other) =>
      geometryMatches(other) && exposureMatches(other);

  @override
  String toString() => 'CalibrationFingerprint(luma '
      '${meanLuma.toStringAsFixed(1)}±${lumaSpread.toStringAsFixed(1)})';
}

/// Everything a session knows about the board in front of it.
class BoardCalibration {
  /// Image pixels to board space and back.
  final Homography h;

  /// Which seat the board was calibrated from, which is what fixes the point
  /// numbering.
  final BoardOrientation orientation;

  /// This board's own colours, learned from its own starting position.
  final ColorModel colors;

  /// What the scene looked like, for the session-long re-validation.
  final CalibrationFingerprint fingerprint;

  const BoardCalibration({
    required this.h,
    required this.orientation,
    required this.colors,
    required this.fingerprint,
  });

  /// Where everything is, for this seating.
  RoiAtlas get atlas => RoiAtlas.forOrientation(orientation);
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

  /// The board is readable but the men are not where a game starts.
  checkersNotInStartingPosition,

  /// The two sets of checkers cannot be told apart in this light.
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

/// One point that does not hold what the starting position says it should.
class PointDiscrepancy {
  final RoiId region;

  /// The point as White numbers it — `BoardState.points[i]` is White's point
  /// `i + 1`, and that is the number the app speaks and prints.
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
    final where = pointNumber == null ? region.name : 'the $pointNumber-point';
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
class ConfirmResult {
  final bool agrees;

  /// The points that disagree, in White's numbering order.
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
/// Two shapes, both in board space and both kept well clear of edges. The
/// perspective warp lays the room over the outermost pixel of the board, and
/// on a dark-framed board that sliver of room classifies as a black checker,
/// so every lattice here is inset.
///
/// * A **checker patch** is a small block a fraction of the way in from the
///   board's outer edge, across the middle of a point's column. Whatever else
///   a stack does, its first checker sits against that edge and is about as
///   wide as the column, so the patch is on the checker for any board
///   proportions worth photographing — no assumption about how deep a checker
///   is, which board space cannot supply.
/// * A **region interior** is an inset lattice over the whole ROI, which is
///   what the bare surface is measured from.
class Calibrator {
  const Calibrator._();

  /// Lattice per side for a region's interior.
  static const int interiorLattice = 20;

  /// How far in from a region's own boundary its interior lattice starts, as a
  /// fraction of the region's size.
  static const double interiorInset = 0.06;

  static const int checkerPatchAcross = 6;
  static const int checkerPatchDeep = 4;

  /// Half the patch's width, as a fraction of the column's width — narrow
  /// enough that a round checker still covers it at the patch's far end.
  static const double checkerPatchHalfWidth = 0.25;

  /// The patch's near and far depth from the board's outer edge, in board-space
  /// units. Clear of the warp's sliver of room at the near end and inside the
  /// first checker at the far end.
  static const double checkerPatchNear = 0.02;
  static const double checkerPatchFar = 0.045;

  /// How much of a lattice has to land inside the picture before the region
  /// counts as visible at all.
  static const double minVisibleFraction = 0.98;

  /// How many checker-free samples a region needs before its own background is
  /// trusted over the board-wide one.
  static const int minBackgroundSamples = 16;

  /// How near a sample has to be to a checker's measured colour, in the model's
  /// feature space, before it is thrown out of a covered region's background.
  /// Generous on purpose: leaving a checker in the background is far worse than
  /// leaving out a little felt.
  static const double checkerExclusionRadius = 0.30;

  /// What fraction of a patch has to agree before a point is called read.
  static const double patchMajority = 0.6;

  /// Learns [frame]'s board, which must be in the starting position.
  static CalibrationResult learnStartingPosition({
    required Frame frame,
    required BoardQuad corners,
    required BoardOrientation orientation,
  }) {
    final Homography homography;
    try {
      homography = Homography.fromQuad(corners);
    } on ArgumentError {
      return CalibrationResult.failure(
        CalibrationProblem.cornersNotABoard,
        'Those four corners do not outline a board. Drag each handle onto a '
        'corner of the playing field and try again.',
      );
    }

    final atlas = RoiAtlas.forOrientation(orientation);
    final sampler = _RoiSampler(frame, homography, atlas);
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
      if (scan.visibleFraction < minVisibleFraction) {
        return _notVisible(RoiId.point(index));
      }
      patches[index] = scan.samples;
    }
    final interiors = <RoiId, List<Rgb>>{};
    for (final id in RoiId.values) {
      final scan = sampler.interior(id);
      if (scan.visibleFraction < minVisibleFraction) return _notVisible(id);
      interiors[id] = scan.samples;
    }

    // --- the two checker colours, as bytes, before anything relative
    final rawWhite =
        _medianOfRegionMedians(occupied, patches, CheckerColor.white);
    final rawBlack =
        _medianOfRegionMedians(occupied, patches, CheckerColor.black);

    // --- every region's bare surface
    //
    // Only regions the starting position covers get their samples filtered by
    // colour, and the dice band with them since four stacks reach into it.
    // Filtering everywhere would be worse than useless: on a board whose pale
    // points are nearly the colour of its white checkers it would throw away
    // exactly the surface an empty point most needs to have measured.
    final filtered = <RoiId>{
      for (final index in occupied.keys) RoiId.point(index),
      RoiId.diceZone,
    };
    final free = <RoiId, List<Rgb>>{};
    for (final id in RoiId.values) {
      free[id] = filtered.contains(id)
          ? interiors[id]!
              .where((s) => !_looksLikeChecker(s, rawWhite, rawBlack))
              .toList()
          : interiors[id]!;
    }
    final pooled = <Rgb>[
      for (final id in RoiId.values)
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
    for (final id in RoiId.values) {
      final samples = free[id]!;
      if (samples.isEmpty) {
        // Every one of the region's samples looked like a checker. In the
        // starting position no stack is tall enough to bury a whole region, so
        // something is on the board that should not be.
        return CalibrationResult.failure(
          CalibrationProblem.regionUnreadable,
          'I cannot see any of ${_describe(id)} — something is resting on it. '
          'Clear the board and try again.',
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
        fullyMeasured: !filtered.contains(id) && enough,
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
          'game, then calibrate again.',
          <RoiId>[RoiId.point(entry.key)],
        );
      }
    }

    return CalibrationResult.success(BoardCalibration(
      h: homography,
      orientation: orientation,
      colors: colors,
      fingerprint: CalibrationFingerprint.fromFrame(frame, homography),
    ));
  }

  /// Checks [frame] against the position every game starts from.
  ///
  /// Colour presence, point by point: is White's, Black's or nothing at the
  /// foot of each stack. How MANY checkers are there is a different question
  /// with a different instrument — occupancy and the stack verifier — and this
  /// one deliberately does not pretend to answer it.
  static ConfirmResult confirm(Frame frame, BoardCalibration calibration) {
    final sampler = _RoiSampler(frame, calibration.h, calibration.atlas);
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
      if (scan.visibleFraction < minVisibleFraction) {
        outOfPicture ??= RoiId.point(i);
        continue;
      }
      final observed = _majorityColor(
        <CheckerColor>[
          for (final sample in scan.samples)
            calibration.colors.classifyIn(RoiId.point(i), sample),
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
        message: 'That is the starting position.',
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

  /// A region in words, for a sentence the user reads.
  static String _describe(RoiId id) {
    if (id.pointIndex >= 0) return 'the ${id.pointIndex + 1}-point';
    return switch (id) {
      RoiId.bar => 'the bar',
      RoiId.offWhite => 'the tray White bears off into',
      RoiId.offBlack => 'the tray Black bears off into',
      RoiId.diceZone => 'the middle of the board, where the dice land',
      _ => id.name,
    };
  }

  static bool _looksLikeChecker(Rgb sample, Rgb white, Rgb black) {
    for (final checker in <Rgb>[white, black]) {
      final f = ColorModel.feature(sample, checker);
      if (math.sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]) <
          checkerExclusionRadius) {
        return true;
      }
    }
    return false;
  }

  static Rgb _medianOfRegionMedians(
    Map<int, CheckerColor> occupied,
    Map<int, List<Rgb>> patches,
    CheckerColor colour,
  ) =>
      _medianRgb(<Rgb>[
        for (final entry in occupied.entries)
          if (entry.value == colour) _medianRgb(patches[entry.key]!),
      ]);

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

// --- sampling ---------------------------------------------------------------

/// A lattice of samples taken from one region, and how much of it landed
/// inside the picture.
class _Scan {
  final List<Rgb> samples;
  final int attempted;

  const _Scan(this.samples, this.attempted);

  double get visibleFraction =>
      attempted == 0 ? 0.0 : samples.length / attempted;
}

/// Reads a frame in board space.
class _FrameSampler {
  final Frame frame;
  final Homography homography;

  const _FrameSampler(this.frame, this.homography);

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

/// Reads a frame region by region.
class _RoiSampler extends _FrameSampler {
  final RoiAtlas atlas;

  const _RoiSampler(super.frame, super.homography, this.atlas);

  /// An inset lattice over the whole of [id].
  _Scan interior(RoiId id) {
    final b = _boundsOf(atlas.roi(id));
    final insetX = (b.maxX - b.minX) * Calibrator.interiorInset;
    final insetY = (b.maxY - b.minY) * Calibrator.interiorInset;
    final x0 = b.minX + insetX, x1 = b.maxX - insetX;
    final y0 = b.minY + insetY, y1 = b.maxY - insetY;

    final samples = <Rgb>[];
    var attempted = 0;
    for (var iy = 0; iy < Calibrator.interiorLattice; iy++) {
      final y = y0 + (iy + 0.5) / Calibrator.interiorLattice * (y1 - y0);
      for (var ix = 0; ix < Calibrator.interiorLattice; ix++) {
        final x = x0 + (ix + 0.5) / Calibrator.interiorLattice * (x1 - x0);
        attempted++;
        final sample = at(x, y);
        if (sample != null) samples.add(sample);
      }
    }
    return _Scan(samples, attempted);
  }

  /// The block the checker nearest the board's edge covers on point [index].
  _Scan checkerPatch(int index) {
    final b = _boundsOf(atlas.roi(RoiId.point(index)));
    // Which board edge this point stacks from: its region runs from that edge
    // to the midline, so whichever end is not the midline is the edge.
    final fromTop = b.maxY <= RoiAtlas.midline + 1e-9;
    final centreX = (b.minX + b.maxX) / 2;
    final halfWidth = (b.maxX - b.minX) * Calibrator.checkerPatchHalfWidth;

    final samples = <Rgb>[];
    var attempted = 0;
    for (var iy = 0; iy < Calibrator.checkerPatchDeep; iy++) {
      final depth = Calibrator.checkerPatchNear +
          (iy + 0.5) /
              Calibrator.checkerPatchDeep *
              (Calibrator.checkerPatchFar - Calibrator.checkerPatchNear);
      final y = fromTop ? depth : 1 - depth;
      for (var ix = 0; ix < Calibrator.checkerPatchAcross; ix++) {
        final x = centreX +
            ((ix + 0.5) / Calibrator.checkerPatchAcross - 0.5) *
                2 *
                halfWidth;
        attempted++;
        final sample = at(x, y);
        if (sample != null) samples.add(sample);
      }
    }
    return _Scan(samples, attempted);
  }
}

typedef _Bounds = ({double minX, double minY, double maxX, double maxY});

_Bounds _boundsOf(BoardQuad quad) {
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

// --- small robust statistics ------------------------------------------------

double _luma(Rgb sample) =>
    0.299 * sample.$1 + 0.587 * sample.$2 + 0.114 * sample.$3;

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
