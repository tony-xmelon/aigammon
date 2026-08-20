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

  /// How deep one candidate patch is, in board-space units. Well inside a
  /// single checker on any board — a checker reaches about a tenth of the
  /// board along a stack — so a patch that lands on one is all checker.
  static const double checkerPatchDepth = 0.025;

  /// Where the walk down a column starts, ends and how far it moves each time,
  /// in board-space units.
  ///
  /// [checkerSearchNear] leaves the warp's sliver of room at the board's own
  /// edge. [checkerSearchFar] is how far a stack may sit back from that edge
  /// and still be looked for, and it is **derived plus one measured step**.
  ///
  /// The derivation is [checkerHoldDepth]'s: a blind walk starting at
  /// [checkerSearchNear] steps over a gap of at most `hold`, so
  /// `near + hold` is the deepest a stack can sit and still be found by a walk
  /// that knows nothing about this board's colours. The extra
  /// [checkerSearchStep] is slack for grain, and it is worth a number: on the
  /// corpus's steep viewpoint the classic board — whose black checkers are the
  /// palette nearest the sensor floor — calibrates through four levels of
  /// grain with the extra step and only three without it. A walk that knows
  /// the colours already can settle on a checker at any depth it looks at, so
  /// this is also that walk's ceiling.
  ///
  /// It used to be written as `0.10`, with the doc claiming it followed from
  /// the derivation it was in fact a step past. That step was where a stack
  /// could be found by one walk and missed by another — see
  /// [checkerReachLeadIn], which is now derived from THIS so the two cannot
  /// drift apart again.
  static const double checkerSearchNear = 0.02;
  static const double checkerSearchFar =
      checkerSearchNear + checkerHoldDepth + checkerSearchStep;
  static const double checkerSearchStep = 0.01;

  /// How far either side of the column's centre the walk also looks, as a
  /// fraction of the column's width.
  ///
  /// Small on purpose: the patch is [checkerPatchHalfWidth] wide either way,
  /// so this much shift still leaves it inside the column and off the
  /// neighbouring stack. It buys the leading edge of a checker nudged
  /// sideways, which is where a round disc is at its narrowest and a
  /// centre-only patch half-misses.
  static const double checkerSearchOffset = 0.15;

  /// How far a block of colour has to hold, in board-space units, before the
  /// walk believes it has found a checker rather than a gap in front of one.
  ///
  /// This is the number that separates the two things a column can show near
  /// its edge. **Board holds briefly**: the wooden rim inside a tapped corner,
  /// or the felt a hand left in front of a stack, runs out where the checkers
  /// start. **A checker holds for the stack behind it**: the starting position
  /// never stands fewer than two.
  ///
  /// So it wants to sit above the deepest gap a stack may sit behind and below
  /// the shallowest stack of two. The ceiling is the tighter of the two and it
  /// is a measurement off the real board, not arithmetic: a two-stack on the
  /// FAR half, seen at the shallow angle a phone propped on the table gives,
  /// projects into **0.09** of the board along its column — the checkers stand
  /// above the felt, so the far one is largely behind the near one from where
  /// the camera is, and the pair covers barely more depth than one. The bed's
  /// flat-drawn checkers reach 0.087 each on a standard board and 0.107 on a
  /// folding one, so the bed is the generous case and the photograph sets the
  /// number.
  ///
  /// [checkerSearchFar] follows from it: a walk starting at
  /// [checkerSearchNear] rejects a gap of at most `hold + near`, which is
  /// where a stack may still sit and be found. Deeper in than that and a
  /// column reads as bare board — and it is not a limit worth fighting, since
  /// nothing local can tell a stack left a tenth of the board up its column
  /// from a piece of board a tenth of the board deep.
  ///
  /// ## What `near + hold` is and is not a ceiling on
  ///
  /// It is the ceiling on THIS walk. It is not the ceiling on the pipeline,
  /// and the difference is a whole palette wide. What a hand may leave and
  /// still have a board calibrate, confirm and count is measured per palette
  /// in the bed's `insetCeilingOf`, and it comes out:
  ///
  /// * classic **0.09** and low-contrast wood **0.09** — the walk's reach, so
  ///   on these two the number here is the pipeline's number;
  /// * blue-red **0.03** — a third of it, and nothing to do with the walk. Its
  ///   finder settles on the right checker at every inset tested; what gives
  ///   out is what a stack sitting back UNCOVERS. The base of its own triangle
  ///   comes out from under it, and this is the palette whose pale points sit
  ///   nearest its white checkers, so enough of that paint joins the region's
  ///   background that the white five-stack on the 13-point reads as bare.
  ///
  /// So: palette-dependent, worst case a third of what this constant allows,
  /// and the hard case is a colour-model limit wearing a placement limit's
  /// clothes. Before the brightness bound in [checkerHoldLumaTolerance] the
  /// wood board sat at 0.03 too, for a third reason again.
  static const double checkerHoldDepth = 0.07;

  /// How far a block has to hold before a walk that already knows this board's
  /// colours will call it a checker.
  ///
  /// Half of [checkerHoldDepth], because that walk is looking for as little as
  /// a single checker rather than a stack of two. What it has to refuse is a
  /// LINE rather than a disc: measured on the real frame, the shadow in the
  /// seam between the felt and the far rim is a coherent near-black strip
  /// about a hundredth of the board deep, and on a board with black checkers
  /// it classifies as one — six empty points and the bar came back holding
  /// phantom Black before this. The shallowest real checker block on the same
  /// frame is 0.09.
  static const double checkerMinBody = 0.035;

  /// How different two medians may be and still count as the same surface —
  /// **in colour, with brightness taken out**: the log-ratio feature
  /// [ColorModel.feature] measures in, less its own mean across the three
  /// channels.
  ///
  /// Brightness has to come out or the test measures the light rather than the
  /// board. Measured on the real frame: down the white two-stack on its far
  /// half, the medians run from (166,157,136) to (198,193,164) — a fifth of a
  /// log unit brighter at the top of the stack than at its foot, which is a
  /// window on one side of a table, not a change of surface. Judged whole,
  /// that gradient ends a checker's block halfway up itself; judged on colour
  /// alone it is 0.02.
  ///
  /// What has to stay outside: on the same frame, checker against felt is 0.24
  /// and checker against the rim's wood 0.25, and the tightest pair any of the
  /// bed's palettes has — the pale points and white checkers of the
  /// low-contrast wood board — is 0.11. This sits under all of them and well
  /// over the drift.
  ///
  /// ## Brightness cannot be put back, and here is the measurement
  ///
  /// The cost of taking brightness out is real and it is not small: two things
  /// of the same hue are the same surface however far apart they are. On the
  /// low-contrast wood palette the dark point paint (156,128,85) and the dark
  /// checker standing on it (107,86,58) are **0.019** apart here, so a block
  /// that starts on the board goes on holding straight through the checker in
  /// front of it, the blind walk settles on board, and the board's own paint
  /// is learned as a checker colour — which is why that palette refuses a
  /// hand-placed stack from an inset of 0.04 up (see [checkerHoldDepth]).
  ///
  /// **A brightness bound alongside this was tried, and the real frame killed
  /// it.** The idea: the wood board's board-to-checker step is 0.36 of a log
  /// unit in [lumaOf] even though it is nothing in colour, so bound the
  /// brightness too. At 0.30 it worked beautifully on the bed — the wood
  /// board's ceiling went 0.03 to 0.09 at every gain, classic's at gain 1.4
  /// did the same, all 368 tests passed and the corpus scoreboard did not
  /// move. On the real folding frame it refused the board, naming the
  /// 19-point.
  ///
  /// The reason is worth keeping, because it is a trap anyone would walk into
  /// twice. The 0.196 quoted above is the drift down a **white** stack, and a
  /// log ratio of brightness is not scale-free across checker colours: the
  /// same window over a **black** stack moves it three times as far, because
  /// the values are tiny to begin with. Measured down the real frame's black
  /// five-stack on the 19-point, which is the one under the window: luma runs
  /// 32 at the foot to 67 at the top, which is **0.63**. So the bound would
  /// have to sit at or above 0.63 to keep that stack and below 0.36 to buy the
  /// wood board anything, and there is no such number. In absolute levels it
  /// is no better — 35 levels of real drift against a 43-level wood step, a
  /// fifth of a stop apart with two measurements in evidence.
  ///
  /// So the wood board's ceiling is a colour-model limit, and the place to
  /// spend on it is the colour model rather than the walk. `checkersUnderLamp`
  /// in the bed now paints that gradient, so this dead end fails a test
  /// instead of a photograph next time.
  static const double checkerHoldTolerance = 0.08;

  /// How much a patch's own samples may scatter and still count as one
  /// surface: the mean per-channel distance from its median, in sensor levels.
  ///
  /// A checker's face is uniform and so is felt; what is not is a patch lying
  /// across the boundary between them, which is exactly the sample that must
  /// never be learned as a checker colour. Measured on the real frame: faces
  /// and felt come out at 2 to 9, a patch straddling a checker's leading edge
  /// at 28 to 50.
  ///
  /// **Absolute, where [checkerHoldTolerance] is relative, and the asymmetry
  /// is deliberate.** The two measure different things. The hold test compares
  /// two patches taken at different DEPTHS down a column, where the light
  /// genuinely differs — the top of a stack is nearer the window than its foot
  /// — so it has to be a ratio or it measures the lamp. This one compares the
  /// samples of a SINGLE patch against each other: 24 samples spanning a
  /// fortieth of the board, over which no lighting varies. What it is really
  /// asking is whether the patch straddles an edge, and an edge shows up as
  /// levels of scatter rather than as a fraction of anything. A relative
  /// version would also do the wrong thing at the two ends of the range it has
  /// to work over — 18 levels is a seventh of a dark checker's mean and a
  /// fourteenth of a pale one's — while what a straddling patch produces (28
  /// to 50) is well clear of what a face produces (2 to 9) in levels, on both.
  static const double checkerPatchMaxSpread = 18.0;

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

  /// Walks point [index]'s column from the board's edge inward and reports the
  /// first checker standing on it.
  ///
  /// ## Why this is a search rather than a spot
  ///
  /// This used to be a fixed window a few hundredths deep, taken from the
  /// board's edge, on the assumption that the outermost checker of a stack
  /// sits flush against that edge. Renderers place checkers that way. People
  /// do not, and the first real calibration frame said so plainly: not one of
  /// its eight starting stacks was flush, the gaps differed from stack to
  /// stack — so no single deeper window would have fixed it — and a shallow
  /// camera angle projects a near-edge stack further from its edge again,
  /// because the checker's own height carries its camera-facing side past the
  /// edge in the picture. Six of the eight windows landed on bare wood, both
  /// learned checker colours converged on wood, and calibration refused the
  /// frame for two sets of checkers that look alike. They did not; the
  /// instrument was looking in the wrong place.
  ///
  /// ## What the walk looks for
  ///
  /// Two things, and neither of them is a colour — this runs before anything
  /// about this board's colours is known, and it is what makes knowing them
  /// possible:
  ///
  /// * **coherence**, [checkerPatchMaxSpread] — a checker's face is one
  ///   colour, and so is felt; a patch lying across the edge between them is
  ///   not, and is exactly the sample that must not be learned as a checker;
  /// * **hold**, [checkerHoldDepth] — the board's surface near the edge runs
  ///   out where the checkers begin, while a checker is the front of a stack
  ///   of at least two and holds its colour for a fifth of the board. So the
  ///   walk takes the first coherent block that keeps its colour deeper than
  ///   any gap could, and steps over the rim and the felt in front of a stack
  ///   without ever being told what wood looks like.
  ///
  /// An empty point settles on its own felt, which is the honest answer and
  /// the one `Calibrator.confirm` needs: this finds what is standing at the
  /// foot of a column, and on an empty column that is the column.
  ///
  /// ## Once the colours are known
  ///
  /// The hold test above is what a walk can do knowing nothing, and it costs
  /// one thing: a single checker standing alone does not hold for two
  /// checkers' depth, so a blind walk steps over it and settles on the board
  /// behind it. That is the right trade at calibration, where the starting
  /// position guarantees a stack of at least two on every point that has any —
  /// and it is the wrong one afterwards, where a lone checker on a point that
  /// should be empty is precisely what has to be seen.
  ///
  /// So a caller that already has a [ColorModel] passes it, and the walk stops
  /// at the first coherent block that reads as a checker of either colour,
  /// however shallow the stack behind it. Nothing reads as a checker on an
  /// empty column, and the walk falls through to the blind answer.
  CheckerFind findChecker(int index, {ColorModel? colors}) => findAlong(
        StackAxis.forRegion(atlas, RoiId.point(index)),
        colors: colors,
      );

  /// The same walk, down whichever region [axis] belongs to.
  ///
  /// A point's column is the common case and [findChecker] is its name, but
  /// nothing about the walk is specific to points: it wants a line to walk, an
  /// end to start from and a width to sample across, which is exactly what a
  /// [StackAxis] is. Calibration uses this form on the bar and the bear-off
  /// trays — the regions the starting position says are empty — to ask whether
  /// something is STANDING in one of them, as opposed to the region's own
  /// surface merely looking like a checker.
  ///
  /// ## Two ways to know what a checker looks like
  ///
  /// [colors] is one: a finished model, which judges a block against the two
  /// checker clouds AND the region's own learned surface. That is what a
  /// mid-game reading wants.
  ///
  /// [isChecker] is the other, and it is there because the first is not always
  /// available *or trustworthy*. A region whose surface model has already
  /// swallowed the very checker being looked for will veto its own answer —
  /// which is exactly the state a bear-off tray with three men in it is in
  /// after calibration has modelled it with two surfaces. Passing the eight
  /// medians the starting position labelled asks a question that model cannot
  /// spoil: is this block the colour of one of this board's own checkers?
  ///
  /// Either way the block still has to be a block: one colour across its face
  /// ([checkerPatchMaxSpread]) with a body behind it ([checkerMinBody]). That
  /// is what a worn stripe down a hinge is not, because a patch laid across
  /// the strip catches the crack and the flanks along with the crown.
  CheckerFind findAlong(
    StackAxis axis, {
    ColorModel? colors,
    bool Function(Rgb median)? isChecker,
  }) {
    final looksLikeChecker = isChecker ??
        (colors == null
            ? null
            : (Rgb median) =>
                colors.classifyIn(axis.region, median) != CheckerColor.none);
    final centreX = (axis.minX + axis.maxX) / 2;
    final width = axis.maxX - axis.minX;

    const offsets = <double>[0.0, -checkerSearchOffset, checkerSearchOffset];
    final steps =
        ((checkerSearchFar - checkerSearchNear) / checkerSearchStep).round();
    final holdSteps = (checkerHoldDepth / checkerSearchStep).ceil();

    // Every patch the walk could want, taken once. The hold test reads blocks
    // deeper than the walk itself will start from, so the profile runs on past
    // [checkerSearchFar] — still nowhere near the midline.
    final profile = <List<_Block>>[
      for (final offset in offsets)
        <_Block>[
          for (var s = 0; s <= steps + holdSteps; s++)
            _blockAt(
              axis,
              centreX + offset * width,
              width,
              checkerSearchNear + s * checkerSearchStep,
            ),
        ],
    ];

    // With the colours in hand, a checker of either colour is what the walk
    // is looking for, and it may be standing alone — but it is still a disc
    // with a body, not a line: see [checkerMinBody].
    if (looksLikeChecker != null) {
      final bodySteps = (checkerMinBody / checkerSearchStep).ceil();
      final seen = _firstBlock(
        profile,
        offsets,
        steps,
        holdSteps,
        (o, s) =>
            looksLikeChecker(profile[o][s].median) &&
            _holdOf(profile[o], s, bodySteps) >= bodySteps,
      );
      if (seen != null) return seen;
    }

    final held = _firstBlock(
      profile,
      offsets,
      steps,
      holdSteps,
      (o, s) => _holdOf(profile[o], s, holdSteps) >= holdSteps,
    );
    return held ?? _bestEffort(profile, offsets, steps, holdSteps);
  }

  /// How far across the checker standing at [depth] along [axis] is, in
  /// board-x units — the contiguous run of [color] readings straight across
  /// the disc, or zero when even [centreX] does not read as one.
  ///
  /// The instrument behind `BoardCalibration.surfaceAspect`: a checker is a
  /// DISC, as wide as it is deep on the table, so its width here against the
  /// stacks' own pitch is the board's width-to-height ratio measured from
  /// furniture the camera cannot foreshorten away. Call it with [depth] at
  /// the disc's middle — half a pitch behind the edge the finder settled
  /// on — where the chord is widest. Each probe is the median of three
  /// samples a [checkerSearchStep] apart in depth, because a single pixel at
  /// a disc's rim is a coin toss and a run test amplifies coin tosses.
  double checkerWidth(
    StackAxis axis, {
    required double depth,
    required double centreX,
    required CheckerColor color,
    required ColorModel colors,
  }) {
    final width = axis.maxX - axis.minX;
    final step = width / 64;

    bool reads(double x) {
      final samples = <Rgb>[];
      for (final d in <double>[
        depth - checkerSearchStep,
        depth,
        depth + checkerSearchStep,
      ]) {
        final sample = at(x, axis.yAt(d));
        if (sample != null) samples.add(sample);
      }
      if (samples.isEmpty) return false;
      return colors.classifyIn(axis.region, medianRgb(samples)) == color;
    }

    if (!reads(centreX)) return 0;
    var left = centreX, right = centreX;
    // A checker can stand off its column's centre but not a whole column
    // away; the run stops at the rim's blend long before these bounds do.
    while (left - step >= axis.minX - width && reads(left - step)) {
      left -= step;
    }
    while (right + step <= axis.maxX + width && reads(right + step)) {
      right += step;
    }
    return right - left + step;
  }

  /// The shallowest coherent block any offset offers that [accepts] it, and
  /// the more uniform of the two where both do at the same depth.
  static CheckerFind? _firstBlock(
    List<List<_Block>> profile,
    List<double> offsets,
    int steps,
    int holdSteps,
    bool Function(int offset, int step) accepts,
  ) {
    for (var s = 0; s <= steps; s++) {
      var chosen = -1;
      for (var o = 0; o < offsets.length; o++) {
        final block = profile[o][s];
        if (block.scan.samples.isEmpty) continue;
        if (block.spread > checkerPatchMaxSpread) continue;
        if (!accepts(o, s)) continue;
        if (chosen < 0 || block.spread < profile[chosen][s].spread) chosen = o;
      }
      if (chosen < 0) continue;
      // Where the block starts is where the checker is; what it looks like is
      // taken from INSIDE it. A patch at the very front of a round checker
      // overhangs it — the disc is at its narrowest there, so the corners of
      // the patch fall on the board behind — and a colour learned off that rim
      // is a blend of the two. Measured on the bed: a patch on a checker's
      // leading edge reads seven of its twenty-four samples as something other
      // than that checker, which is close enough to the majority a read-back
      // needs that a hair of noise loses it.
      return CheckerFind(
        scan: _cleanestIn(profile[chosen], s, holdSteps).scan,
        depth: profile[chosen][s].depth,
        offset: offsets[chosen],
        settled: true,
      );
    }
    return null;
  }

  /// What to answer when nothing in the column held: whatever lasted longest,
  /// which is a better guess than the first thing the walk tripped over, and
  /// marked as the guess it is.
  static CheckerFind _bestEffort(
    List<List<_Block>> profile,
    List<double> offsets,
    int steps,
    int holdSteps,
  ) {
    _Block? loose;
    var looseOffset = 0.0;
    var longest = -1;
    for (var s = 0; s <= steps; s++) {
      for (var o = 0; o < offsets.length; o++) {
        final block = profile[o][s];
        if (block.scan.samples.isEmpty) continue;
        if (block.spread > checkerPatchMaxSpread) continue;
        final hold = _holdOf(profile[o], s, holdSteps);
        if (hold > longest) {
          longest = hold;
          loose = block;
          looseOffset = offsets[o];
        }
      }
    }
    final fallback = loose ?? profile[0][0];
    return CheckerFind(
      scan: fallback.scan,
      depth: fallback.depth,
      offset: loose == null ? 0.0 : looseOffset,
      settled: false,
    );
  }

  /// One candidate patch: a lattice [checkerPatchDepth] deep whose near end is
  /// at [depth] along [axis], centred on [centreX].
  _Block _blockAt(
    StackAxis axis,
    double centreX,
    double columnWidth,
    double depth,
  ) {
    final halfWidth = columnWidth * checkerPatchHalfWidth;
    final samples = <Rgb>[];
    var attempted = 0;
    for (var iy = 0; iy < checkerPatchDeep; iy++) {
      final d = depth + (iy + 0.5) / checkerPatchDeep * checkerPatchDepth;
      final y = axis.yAt(d);
      for (var ix = 0; ix < checkerPatchAcross; ix++) {
        final x = centreX +
            ((ix + 0.5) / checkerPatchAcross - 0.5) * 2 * halfWidth;
        attempted++;
        final sample = at(x, y);
        if (sample != null) samples.add(sample);
      }
    }
    return _Block(RoiScan(samples, attempted), depth);
  }

  /// The most uniform view of the block that starts at [at] — the patch whose
  /// own samples agree best, among those still showing the block's colour.
  static _Block _cleanestIn(List<_Block> profile, int at, int limit) {
    var best = profile[at];
    final reference = best.median;
    for (var k = 1; k <= limit && at + k < profile.length; k++) {
      final block = profile[at + k];
      if (block.scan.samples.isEmpty) break;
      if (!_sameSurface(block.median, reference)) break;
      if (block.spread < best.spread) best = block;
    }
    return best;
  }

  /// How many steps deeper than [at] the column goes on showing [at]'s colour,
  /// up to [limit].
  static int _holdOf(List<_Block> profile, int at, int limit) {
    final reference = profile[at].median;
    for (var k = 1; k <= limit; k++) {
      final next = at + k;
      if (next >= profile.length) return k - 1;
      final block = profile[next];
      if (block.scan.samples.isEmpty) return k - 1;
      if (!_sameSurface(block.median, reference)) return k - 1;
    }
    return limit;
  }

  /// Whether two block medians are the same thing seen twice — the one
  /// definition of "still the same surface" the whole walk uses.
  ///
  /// Colour only, with brightness taken out, because a stack is lit brighter
  /// at its top than at its foot and that is the light rather than the board.
  /// What that costs, what a brightness bound alongside it would buy, and the
  /// real frame's answer to whether one can exist: [checkerHoldTolerance].
  static bool _sameSurface(Rgb a, Rgb b) =>
      _colourGap(a, b) <= checkerHoldTolerance;

  /// A pedestal under every channel before a ratio is taken.
  ///
  /// A near-black checker — the classic palette paints one at 20/18/15, and
  /// real ones photograph darker still — differs from itself by a level or two
  /// of grain, and a bare ratio turns two levels on fifteen into an eighth of
  /// a log unit of "different colour". Measured: without this, a black stack's
  /// own block stops holding partway down itself.
  static const double _darkPedestal = 8.0;

  /// How far apart two colours are once brightness is taken out of them.
  ///
  /// The log-ratio feature the colour model judges every other sample in, less
  /// its mean across the three channels: what is left is the difference in
  /// colour, and lighting one of the two samples harder moves every channel by
  /// the same amount and so moves this not at all. That is what lets a block
  /// hold down a stack that is lit brighter at its top than at its foot while
  /// still ending where the surface changes.
  static double _colourGap(Rgb a, Rgb b) {
    final r = math.log((a.$1 + _darkPedestal) / (b.$1 + _darkPedestal));
    final g = math.log((a.$2 + _darkPedestal) / (b.$2 + _darkPedestal));
    final c = math.log((a.$3 + _darkPedestal) / (b.$3 + _darkPedestal));
    final mean = (r + g + c) / 3;
    final dr = r - mean, dg = g - mean, dc = c - mean;
    return math.sqrt(dr * dr + dg * dg + dc * dc);
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

  /// How far in from a region's origin a run of covered rows may START and
  /// still count as the stack standing on that region — see [_runReach].
  ///
  /// **Derived from the finder's own reach, and it has to be.** The two walks
  /// measure the same stack differently: [findAlong] settles on a BLOCK, whose
  /// near end is where the checker begins, while this one counts covered ROWS,
  /// and the first covered row lies deeper than the block's near end — a round
  /// checker tapers to nothing at its leading edge, so the rows there fall
  /// under [minRowCoverage] and are not counted. A block is
  /// [checkerPatchDepth] deep and that is exactly how much deeper than its own
  /// near end its samples reach, so `far + patchDepth` is the bound that makes
  /// the two agree: **anything the finder can settle on, this can start a run
  /// on.**
  ///
  /// It used to be [checkerSearchFar] flat, and the one step of difference was
  /// silent. Measured on the bed, reading inset frames through a calibration
  /// taken on a tidy board: at an inset of 0.09 nothing was miscounted; at
  /// 0.095 seven of the twenty-four points came back holding ONE checker where
  /// two, three and five stood — `reach` zero, count floored at one by
  /// `OccupancyReader._resolve` — and `confirm` agreed the board was set up
  /// for the start of a game, because the finder it uses had found every one
  /// of those stacks. A wrong count that nothing contradicts is the worst
  /// reading this pipeline can produce, and it lived in a band a hand's
  /// placement lands in.
  ///
  /// The die this bound exists to exclude is untouched by the widening: a die
  /// in a point's headroom sits against the midline, three and a half times
  /// further in than this.
  static const double checkerReachLeadIn =
      checkerSearchFar + checkerPatchDepth;

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

  /// How long the run of covered rows nearest the origin is.
  ///
  /// **Its length, not how far it reaches.** The two are the same thing on a
  /// board whose stacks are flush against their edges and nothing alike on a
  /// board where a hand has left them a little way in — and the second is what
  /// real boards look like (see [findChecker]). Measuring from the board's
  /// edge instead made the pitch depend on where each stack happened to be set
  /// down: with the run required to start at the edge, every inset stack
  /// measured *zero*, the pitch regression had nothing to fit, and occupancy
  /// counted one checker on stacks of five.
  ///
  /// The run may therefore begin anywhere within [checkerReachLeadIn] of the
  /// origin — as far in as a stack may sit and still be a stack on this point
  /// — and nowhere else. That bound is what keeps a die lying in a point's
  /// headroom from starting a run of its own: it sits three or four times
  /// further in than this, so it goes on measuring zero, which is the
  /// signature occupancy uses to tell it from a checker.
  ///
  /// ## The longest run that may start, not the first
  ///
  /// **One stray row used to be able to take the whole measurement.** This
  /// took the first covered row within the lead-in and stopped at the first
  /// wide gap after it, which is right when the first thing it meets is the
  /// stack and catastrophic when it is not. Measured on the folding bed with
  /// the stacks left a hand's width in, the 19-point's profile came back
  ///
  ///     #.........#############################################…
  ///
  /// — a single covered row hard against the board's edge, a nine-row gap,
  /// and then all five checkers. The gap is wider than [maxProfileGap], so the
  /// run ended after that one row and a five-stack measured 0.004: one row out
  /// of a hundred and twenty. Its twins measured 0.45.
  ///
  /// That single row is the board's own edge — a rim or the shadow in the seam
  /// catching the dark checker colour across enough of one row to clear
  /// [minRowCoverage]. It is not a stack, and the profile says so plainly: it
  /// is one row long and the stack behind it is a hundred and ten.
  ///
  /// So the walk now takes the LONGEST run that starts within the lead-in
  /// rather than the first one. Nothing about the die is weakened — it is
  /// outside the lead-in and still cannot start a run at all — and inside the
  /// lead-in there is only ever the stack and, sometimes, a row of rim.
  static double _runReach(List<double> coverage, double rowDepth) {
    final maxLeadIn =
        rowDepth <= 0 ? 0 : (checkerReachLeadIn / rowDepth).floor();
    var longest = 0;
    var first = -1, last = -1;

    void bank() {
      if (first >= 0 && first <= maxLeadIn && last - first + 1 > longest) {
        longest = last - first + 1;
      }
    }

    for (var r = 0; r < coverage.length; r++) {
      if (coverage[r] < minRowCoverage) continue;
      if (first >= 0 && r - last <= maxProfileGap + 1) {
        last = r;
        continue;
      }
      // Whatever was being measured has ended; a new run starts at r.
      bank();
      // Past the lead-in nothing may START a run, so there is nothing left to
      // find — an in-progress run would have been extended above.
      if (r > maxLeadIn) {
        first = -1;
        break;
      }
      first = r;
      last = r;
    }
    bank();
    return longest * rowDepth;
  }
}

/// One candidate patch in a column walk, with the two numbers the walk judges
/// it by.
class _Block {
  final RoiScan scan;

  /// Board-space depth of the patch's near end.
  final double depth;

  final Rgb median;

  /// Mean per-channel distance from [median], in sensor levels.
  final double spread;

  _Block(RoiScan scan, double depth)
      : this._(scan, depth, scan.samples.isEmpty ? (0, 0, 0) : medianRgb(scan.samples));

  _Block._(this.scan, this.depth, this.median)
      : spread = _spreadOf(scan.samples, median);

  static double _spreadOf(List<Rgb> samples, Rgb median) {
    if (samples.isEmpty) return double.infinity;
    var total = 0.0;
    for (final s in samples) {
      total += ((s.$1 - median.$1).abs() +
              (s.$2 - median.$2).abs() +
              (s.$3 - median.$3).abs()) /
          3;
    }
    return total / samples.length;
  }
}

/// What the walk down a point's column settled on.
class CheckerFind {
  /// The samples the chosen patch took — what the colour of whatever stands
  /// at the foot of this column is learned from, or judged against.
  final RoiScan scan;

  /// Board-space depth of the patch's near end, measured from the board edge
  /// this point stacks from. How far back from its edge the stack was sitting,
  /// to within the patch's own step.
  final double depth;

  /// How far the patch was shifted across the column, in fractions of the
  /// column's width.
  final double offset;

  /// Whether the walk settled on a block that held its colour, or ran out of
  /// column and handed back the best it saw.
  ///
  /// Not "there is a checker here": an empty point settles on its own felt,
  /// and settling is what makes that reading trustworthy. False means the
  /// column showed nothing that held — a hand across it, a stack left halfway
  /// up it, a region mostly out of the picture — and whatever came back
  /// deserves less trust.
  final bool settled;

  const CheckerFind({
    required this.scan,
    required this.depth,
    required this.offset,
    required this.settled,
  });

  @override
  String toString() => 'CheckerFind(depth ${depth.toStringAsFixed(3)}, '
      'offset ${offset.toStringAsFixed(2)}${settled ? '' : ', unsettled'})';
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

  /// How long each colour's run at the origin end is, in board-space units.
  /// Zero when that colour was not found there at all.
  ///
  /// A *run*, not a scattering: the walk takes the first covered row within
  /// [RoiSampler.checkerReachLeadIn] of the origin and stops at the first gap
  /// wider than [maxProfileGap] after it. A blob floating in the middle of a
  /// region — a die in a point's headroom, a hand's shadow — is therefore not
  /// counted as part of the stack unless it is touching it, and does not start
  /// a run of its own.
  ///
  /// The length is measured from where the run starts rather than from the
  /// board's edge, so a stack a person left sitting a little way in measures
  /// the same as one pushed flush — see [RoiSampler._runReach].
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

  /// How little of what its twins reached a stack may reach before it is taken
  /// as a measurement that FAILED rather than as evidence about this board.
  ///
  /// Half, and the halving is the whole argument: stacks of the same labelled
  /// height stand on the same board in the same frame, so they reach the same
  /// distance. Two that differ by a factor of two are not two measurements of
  /// one board, they are one measurement and one failure — a run that stopped
  /// at a gap partway up a stack rather than at its top.
  ///
  /// Note what this does NOT need: any idea of what a pitch should be. A floor
  /// on the ratio would be a second [minPitch] in disguise and would refuse a
  /// board whose checkers are genuinely close-stacked. This asks the board
  /// about itself and only ever throws out the low side, because that is the
  /// only side the failure has — a run can stop early, it cannot run long.
  static const double minStackAgreement = 0.5;

  /// Least squares through `(height, reach)` pairs.
  ///
  /// Falls back to the median of `reach / height` when the heights on offer do
  /// not span enough to fit a line — one ratio is a worse instrument than a
  /// regression, but it is a great deal better than refusing to count.
  ///
  /// ## Why the pairs are filtered first
  ///
  /// **A least squares fit believes everything it is given, and one of these
  /// eight is sometimes a lie.** Measured on the first real folding frame: of
  /// the eight stacks the starting position labels, the 13-point's five-stack
  /// came back reaching 0.0667 and the 20-point's 0.1458, where their two
  /// twins reached 0.3333 and 0.3667. Those are not short stacks — they are
  /// five men each, and the finder settled on all eight correctly. They are
  /// runs that stopped at a gap. Regressed through anyway, they pulled the
  /// pitch to 0.0429 against a true 0.0874, and since
  /// `Calibrator.minPitch` is 0.02 nothing objected: separation 7.1, `confirm`
  /// agreeing, and ten of the twenty-four points then counted wrong on the
  /// frame the whole session is calibrated from. The tall stacks over-counted
  /// (five read as eight) and the collapsed ones under-counted (five read as
  /// one).
  ///
  /// So the pairs are checked against each other before any line is fitted,
  /// by [minStackAgreement], and what survives is what the pitch is measured
  /// from. On that frame six of the eight survive, at three distinct heights,
  /// and the pitch comes back 0.0874.
  ///
  /// [wellConditioned] is then computed over the SURVIVORS, so a board that
  /// lost too many says so — and `Calibrator` turns that into a refusal rather
  /// than shipping a pitch that halves every count.
  factory StackMetrics.fit(List<(int height, double reach)> samples) {
    final measured = samples.where((s) => s.$1 > 0 && s.$2 > 0).toList();
    if (measured.isEmpty) {
      return const StackMetrics(pitch: 0, origin: 0, wellConditioned: false);
    }
    final usable = _agreeingStacks(measured);
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

  /// The pairs that agree with their own twins, by [minStackAgreement].
  ///
  /// Each labelled height is judged against the median reach of the stacks
  /// that share it. A height with only one stack has nothing to disagree with
  /// and is always kept: this rejects measurements the board itself
  /// contradicts, and invents no evidence where there is none.
  static List<(int, double)> _agreeingStacks(List<(int, double)> samples) {
    final byHeight = <int, List<double>>{};
    for (final sample in samples) {
      (byHeight[sample.$1] ??= <double>[]).add(sample.$2);
    }
    final floors = <int, double>{};
    for (final entry in byHeight.entries) {
      final reaches = List<double>.of(entry.value)..sort();
      floors[entry.key] =
          reaches[reaches.length ~/ 2] * minStackAgreement;
    }
    final kept = samples.where((s) => s.$2 >= floors[s.$1]!).toList();
    // A filter that threw everything out would be worse than none: fall back
    // to the raw pairs and let the conditioning check downstream say so.
    return kept.isEmpty ? samples : kept;
  }

  /// How many checkers a run of [reach] is, before any rounding.
  double heightOf(double reach) =>
      pitch <= 0 ? 0.0 : (reach - origin) / pitch;

  /// What share of a whole checker a run has to be before it is one at all.
  ///
  /// Half, which is the same boundary [heightOf]'s rounding uses — but asked
  /// of the RUN, which was measured, rather than of the line, which was
  /// extrapolated. That is the whole point of it existing: see [holdsAnything].
  static const double minRunFraction = 0.5;

  /// Whether a run of [reach] is long enough to be a checker at all.
  ///
  /// **A line fitted to stacks of two, three and five does not have to behave
  /// at zero, and on real frames it does not.** Measured on the first real
  /// folding frame: the eight labelled stacks fit a pitch of 0.0874 with an
  /// origin of **-0.0905**, which is an honest least-squares line through
  /// honest measurements and also says that a run of nothing at all is 1.04
  /// checkers. So every empty region whose mass cleared the presence threshold
  /// came back holding a man — four of them on that frame, at runs of 0.008 to
  /// 0.037 where a checker is 0.0874 deep.
  ///
  /// Rounding cannot catch that, because rounding asks the poisoned line. This
  /// asks the measurement instead: a run under half a checker is not a
  /// checker, whatever the line extrapolates. A stack of one measures most of
  /// a pitch — the coverage threshold shaves each end of a round disc, which
  /// is what [origin] is for — so this sits well under the smallest real
  /// reading and well over the rim and shadow that produce these.
  bool holdsAnything(double reach) => reach >= pitch * minRunFraction;

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

/// The per-channel median of a set of samples — the package's one way of
/// asking "what colour is this patch", so that a single bright pixel on a
/// checker's rim cannot drag an answer the way a mean would.
Rgb medianRgb(List<Rgb> samples) {
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

/// BT.601 luma of a sample — the one brightness number the package uses, so
/// the fingerprint's exposure statistics and the dice reader's contrast are
/// measured on the same scale.
double lumaOf(Rgb sample) =>
    0.299 * sample.$1 + 0.587 * sample.$2 + 0.114 * sample.$3;
