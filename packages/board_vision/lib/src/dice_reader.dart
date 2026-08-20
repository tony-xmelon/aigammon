import 'dart:math' as math;
import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';

import 'calibration.dart';
import 'color_model.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'pip_pattern.dart';
import 'roi_atlas.dart';
import 'roi_sampler.dart';

/// One die the reader found, and where.
class DieReading {
  /// The face showing, 1 to 6 — one pip blob per pip.
  final int face;

  /// The die's middle, in board space.
  final Pt center;

  /// How far across the die is, in board-space x units. Two dice from the same
  /// set are the same size, so a pair that disagrees about this is a pair the
  /// reader has probably got wrong.
  final double span;

  /// How far the pips sit from the die's body, in the sensor's own levels
  /// (0..255). The reading's raw signal: halve the light and this halves.
  final double pipContrast;

  /// How square the blob was, as the scatter of its outline about its own
  /// middle once its aspect has been normalized away. A circle is near zero, a
  /// square near a ninth.
  final double squareness;

  const DieReading({
    required this.face,
    required this.center,
    required this.span,
    required this.pipContrast,
    required this.squareness,
  });

  @override
  String toString() => 'DieReading($face at (${center.x.toStringAsFixed(2)}, '
      '${center.y.toStringAsFixed(2)}))';
}

/// A settled pair of dice, read from one frame.
class DiceReading {
  /// The two dice, left to right in board space — the order the frame shows
  /// them in, which is the only order a reader can honestly claim. Which die
  /// is "first" in the game's sense is not a thing a photograph knows.
  final DieReading first;
  final DieReading second;

  /// How much this reading is worth, from 0 to 1. See [DiceReader] for what
  /// goes into it and what it does not mean.
  final double confidence;

  const DiceReading({
    required this.first,
    required this.second,
    required this.confidence,
  });

  /// The roll, for the game state.
  Dice get dice => Dice(first.face, second.face);

  @override
  String toString() => 'DiceReading(${first.face}-${second.face} '
      '@${confidence.toStringAsFixed(2)})';
}

/// Finding two settled dice anywhere on the playing surface, and reading
/// their faces.
///
/// ## Why this query is different
///
/// Every other question perception is asked arrives primed: which of these
/// seven legal plays happened, does this point still hold the four checkers
/// the game expects. A roll is new information, so there is nothing to match
/// against and thirty-six answers are equally likely beforehand. That is why
/// the spec sets the highest accuracy target here and names dice as the
/// sub-problem most likely to need the ML escape hatch.
///
/// It also fixes the failure mode: **anything that is not exactly two dice
/// reads as nothing**. A wrong roll is folded into the authoritative game
/// state and every position after it is wrong; a refusal costs one tap on the
/// manual dice pad, which the design keeps one tap away for exactly this
/// reason.
///
/// ## Where the reader looks
///
/// The whole playing surface: every point's column, the bar, and the band
/// between the triangle rows, from the board's far edge to its near one. The
/// reader once looked only in the band the atlas reserves as
/// [RoiId.diceZone], on the theory that dice are thrown into the middle.
/// The first real footage measured the theory and it failed: of the four
/// rolls its corpus carries, one pair settled entirely among the far-half
/// points, one had a die just past the band's far edge, and one lay out of
/// the band on both halves at once. Real players roll wherever the dice
/// stop, and a reader that cannot look there answers null to most of a real
/// session's rolls. What each patch of surface is judged AGAINST differs by
/// where the patch is — see [_sampleSurface], which is where the band still
/// earns its keep.
///
/// ## Telling a die from a checker
///
/// The surface is full of round things that are not dice — every checker on
/// every point, and the band's own overlap with the points' headroom (see
/// [RoiAtlas]) was always full of them. Rejecting them is not an edge case,
/// it is the job. Three gates, in order of how much they cost:
///
/// 1. **Foreign to what its own patch of board showed calibration.** A cell
///    counts only if it is further than [minForeignDistance] from every
///    surface calibration learned for the region the cell sits in — the
///    band's own two surfaces inside the band, the owning point's or the
///    bar's outside it. This finds dice AND checkers AND hands — anything
///    the board does not account for. It cannot be asked to find dice
///    specifically, because there is no learned distribution for a die:
///    calibration has never been shown one, and there is no colour constant
///    anywhere in this package to fall back on.
/// 2. **Square, not round.** The blob's outline is measured about its own
///    middle after its covariance has been normalized away, which makes the
///    test blind to the perspective stretch that turns a circle into an
///    ellipse and a square into a parallelogram. A circle scores near zero
///    whatever angle it is seen from; a square scores near an eighth.
/// 3. **It has pips — and pips stand where a face's pips stand.** A die's
///    face carries one to six small marks set off from the body that
///    carries them, arranged as one of the six shapes every die ever made
///    shares — [PipPattern] is that test, and what it retired is counting.
///    A checker is flat colour all the way across; a stack's shadow seams
///    and a blurred board edge make marks no face's shape contains; a dark
///    mass with BRIGHT marks is smeared checkers around windows of felt;
///    and a settled die lies ON the surface, so a candidate centred nearer
///    than half a die to the surface's edge is something standing against
///    the board's wall. This gate is both the face reading and the last
///    word on whether the thing is a die at all.
///
/// ## What colour cannot see, measured
///
/// A region's learned surfaces cover its whole column, so a die within
/// [minForeignDistance] of ANY of them is invisible anywhere in that
/// column's territory. Measured on the bed: the classic palette's die body
/// sits 2.3 spreads from a cream triangle's mode against 13.1 from a dark
/// one's, so out of the band that palette's dice are found in the dark
/// columns and camouflaged in the cream ones. Measured on the first real
/// footage: the left leaf's pale wood holds dice at 0.7 spreads from the
/// leaf's own surfaces — only the band's narrower vocabulary separates them
/// (3.2 spreads), and only inside the band. Both cases fail closed: a die
/// colour cannot separate from the board is a null and a tap on the dice
/// pad, never a guess. Finding such dice by their pips rather than their
/// bodies is the queued follow-up.
///
/// ## Numbers, provisionally
///
/// Measured against the synthetic renderer, whose dice are flat squares with
/// flat round pips. Real dice have rounded corners, sit at an angle to the
/// camera so one face is foreshortened, cast shadows, and roll to a stop
/// against checkers. The corpus gate (the plan's Task 6) is where every
/// number below is asked again, and where the escape hatch gets triggered if
/// they do not survive.
class DiceReader {
  final BoardCalibration calibration;
  final Frame frame;

  /// [calibration]'s colours, re-normalized for [frame]'s own light — the
  /// same seam every other query goes through, and for the same reason.
  final ColorModel colors;

  /// Cells across and down the playing surface, for THIS session's dice.
  ///
  /// See [baseLatticeAcross]: the pair is scaled so that a die always spans
  /// the same number of cells, whatever size it is. The across count is the
  /// band's own, since the surface spans the same columns; the down count
  /// carries the band's cell size over the surface's full unit height — see
  /// [_surfaceRows].
  final int latticeAcross;
  final int latticeDown;

  DiceReader(this.calibration, this.frame)
      : colors = calibration.colorsIn(frame),
        latticeAcross = _scaledLattice(baseLatticeAcross, calibration.dieSide),
        latticeDown = _surfaceRows(calibration);

  /// Cells across the surface, and down the BAND, for a die of
  /// [BoardCalibration.defaultDieSide].
  ///
  /// Sized so a pip — about a sixth of a die across — spans the best part of
  /// ten cells, which is what it takes to separate the six pips of a six from
  /// each other and from the die's rim. [baseLatticeDown] stays anchored to
  /// the band — the strip [RoiId.diceZone] reserves — because that is where
  /// the density was measured and validated; the whole surface is sampled at
  /// the same cell size, so its row count is derived, not written down.
  ///
  /// **Everything below is a share of a DIE, not of the lattice.** These two
  /// were the last absolute size in the reader: they described how finely to
  /// sample a band containing the bed's dice, and a board whose dice are a
  /// third of that size got a third of the cells per die and fell through
  /// every gate that follows. So the pair scales with
  /// [BoardCalibration.dieSide] and the numbers here are what the scaling is
  /// anchored to.
  static const int baseLatticeAcross = 600;
  static const int baseLatticeDown = 80;

  /// The surface is never sampled finer than this many cells across,
  /// whatever the dice.
  ///
  /// Sampling finer than the frame's own pixels cannot recover detail the
  /// sensor did not capture, and the cost is quadratic: the cap is what stops
  /// a mis-measured `dieSide` of a thousandth from asking for forty-five
  /// thousand cells across and billions of cells of work. Dice small enough
  /// to reach it are refused by [minDiePixels] long before it binds.
  static const int maxLatticeAcross = 2400;

  static int _scaledLattice(int base, double dieSide) {
    final scale = BoardCalibration.defaultDieSide / dieSide;
    final capped =
        math.min(scale, maxLatticeAcross / baseLatticeAcross);
    return math.max(1, (base * capped).round());
  }

  /// Rows for the whole playing surface, at the cell size the band anchors.
  ///
  /// The band is [baseLatticeDown] scaled rows tall over its own height; the
  /// surface is the unit rectangle's full height at the same cell size. Kept
  /// as a division rather than a constant so that the band's measured
  /// density remains the single thing the row count follows.
  static int _surfaceRows(BoardCalibration calibration) {
    final band = boundsOf(calibration.atlas.roi(RoiId.diceZone));
    final scaled = _scaledLattice(baseLatticeDown, calibration.dieSide);
    return math.max(1, (scaled / (band.maxY - band.minY)).round());
  }

  /// How far in from the playing surface's own sides to sample, as a
  /// fraction of its width. The surface ends where the bear-off wells begin —
  /// or, on a board with no wells, at the board's own edge — and what is
  /// immediately outside belongs to neither. The far and near edges get no
  /// such margin, exactly as the band's own edges never did: a row's cells
  /// are sampled at their middles, half a cell inside.
  static const double insetX = 0.004;

  /// How far from every surface its region is known to show, in spreads,
  /// before a cell counts as something the board does not account for.
  ///
  /// Measured: on the hardest of the three palettes — pale wood dice on pale
  /// wood felt — a die's body sits 6.3 spreads from the felt and 9.2 from the
  /// bar's wood, and the band's own surfaces sit within about 1.5 of
  /// themselves. Three leaves room on both sides. Outside the band the same
  /// three is asked of the owning region's surfaces, whose triangles sit
  /// further from a die than that on every column that is not camouflage
  /// outright (see the class doc's measured section).
  static const double minForeignDistance = 3.0;

  /// How much of a DIE a blob has to cover to be worth considering, and how
  /// much it may cover before it is something else entirely — a merged pair, a
  /// hand, a shadow across the middle of the board.
  ///
  /// **Shares of a die, not of the band, and that is the whole fix.** These
  /// were 0.005 and 0.20 of the band, which is the same thing only while the
  /// dice are the size the bed draws. The first real footage's dice cover
  /// about a fiftieth of the area the bed's do — 198 cells against 2520 — so
  /// they came in under a floor of 240 cells and were thrown away before
  /// anything looked at them. The floor was measuring the band; it should
  /// always have been measuring the die.
  ///
  /// Wide on purpose in both directions: a die seen at an angle is
  /// foreshortened, one resting against a checker merges with it, and the
  /// gates that follow — squareness, and pips — are the ones meant to be
  /// discriminating. These two only keep the work down.
  static const double minDieShare = 0.10;
  static const double maxDieShare = 4.0;

  /// How much the outline may scatter about its own middle and still be
  /// called round. A filled circle scores about 0.015 at this lattice and a
  /// filled square about 0.115, so this sits nearer the circle: the pip gate
  /// is what has the last word, and letting a doubtful blob through to it is
  /// safer than refusing a die that a checker happened to touch.
  static const double minSquareness = 0.06;

  /// How much of a blob's edge to shave before looking for pips, as a share of
  /// the die's own width.
  ///
  /// The rim of any blob is a blend of the thing and what is behind it, and on
  /// a board whose felt is darker than its dice that blend looks exactly like
  /// a pip. A die's pips sit a sixth of its width inside its edge, so a
  /// fifteenth is nowhere near them.
  ///
  /// **This one was NOT a hidden absolute size, and the audit that found the
  /// others says so.** It was three cells flat, and three cells looks like an
  /// absolute — but its unit is lattice cells, and the lattice now scales with
  /// the die, so a die spans about forty-five cells whatever size it is and
  /// three of them stay a fifteenth of it. Put back to a literal 3 and every
  /// small-dice test still passes. It is written as a share anyway, because
  /// that is what it means and it stays true if the lattice base is ever
  /// changed on its own; it never rounds below one cell, since a rim is at
  /// least one cell wide however small the die.
  static const double pipErosionShare = 1 / 15;

  /// The share of a die's body one pip covers, at the extremes. A pip is
  /// about a sixth of the die across, so about a fortieth of its area.
  ///
  /// There briefly stood a third pip gate beside these — a cap on how far a
  /// pip blob may run, added the day the widened search met the shadow
  /// seams of checker stacks reading as rows of "pips". [PipPattern]
  /// retired it: a seam's centroid never stands where a face's pips stand,
  /// and with the shape test in place the cap refused nothing more on the
  /// bed's whole suite or on all seventy real windows, measured both ways.
  static const double minPipShare = 0.003;
  static const double maxPipShare = 0.08;

  /// How far the pips must sit from the die's body, in the sensor's own
  /// levels, before the difference is a pip rather than the grain of a flat
  /// surface. The whole point of this one: a checker is flat, so nothing
  /// inside it clears this, and a checker with no pips is not a die.
  static const double minPipContrast = 20.0;

  /// Where the pip threshold sits between the body and the pips.
  static const double pipCut = 0.5;

  /// The percentile of a die's own brightness taken to BE the pips — low
  /// enough to land inside the pip of a one-face, which covers only about a
  /// fortieth of the die.
  static const double pipPercentile = 0.01;

  /// How much bigger one die of a pair may be than the other. Dice come in
  /// sets; a pair that disagrees about its own size is a pair with something
  /// else in it.
  static const double maxSizeDisagreement = 0.45;

  /// How close together a pair's two middles may stand, in die sides, before
  /// the pair is one die seen twice rather than a roll.
  ///
  /// Two SETTLED dice cannot hold their middles much nearer than one die —
  /// that close their blobs have merged, and [maxDieSpanShare] refuses the
  /// union — so two SEPARATE candidates that close are the halves of one
  /// thing. Measured on the real footage: a die tilted into two visible
  /// faces splits at the dark roll of its edge into a top-face and a
  /// side-face candidate 0.8 to 1.1 dies apart, and three stable windows
  /// paired those halves into 2-3, 1-3 and 1-2 — rolls nobody threw — while
  /// the footage's true pairs never stood separate blobs closer than two
  /// dies. The price is refusing a pair lying genuinely shoulder to
  /// shoulder, which the bed can paint and the pin test does paint: that
  /// refusal costs a tap on the dice pad, and the split die cost three
  /// wrong rolls in seventy windows.
  static const double minPairGap = 1.25;

  /// How far across a candidate may be, as a share of the die the session
  /// measured, before it is not a die at all.
  ///
  /// **The session is TOLD how big its dice are** —
  /// [BoardCalibration.dieSide] exists precisely because no constant could
  /// know — and until the search widened, nothing ever held a candidate to
  /// it: only the PAIR was asked to agree with itself. Measured the day the
  /// search left the band, that is not enough. A die is wider than a point
  /// column, so it always straddles a column boundary, and where the
  /// neighbouring column's own surfaces sit within [minForeignDistance] of
  /// the die's body — the camouflage the class doc measures — the blob is
  /// the die CUT AT THE SEAM. A truncated five reads as a three or a two,
  /// and when both dice of a roll land that way their fragments AGREE about
  /// their wrong size: a true 5-6 came back 3-3 at a confidence of 0.63,
  /// above the lowest reading the corpus knows to be correct, through every
  /// other gate. A wrong roll into the game state is the one output this
  /// class exists to prevent, and this pair of bounds is what refuses it:
  /// the fragments measure 0.63 of a die across and under, a merely-clipped
  /// die that still reads right measures 0.77, and a flat die is 1.0.
  ///
  /// The upper bound is the same idea against mergers — a die fused with a
  /// checker measures 1.77 dice across, against 1.41 for a die rotated a
  /// full half-turn of its symmetry — and turns the die-against-a-stack
  /// refusal from a lucky cascade of gate failures into a stated rule.
  ///
  /// [PipPattern] arrived after these bounds and refuses the measured
  /// fragment cases by shape as well — a truncated face's dots stand
  /// wrong — so today they are the stated physical rule with the shape test
  /// behind it, not the only thing standing.
  static const double minDieSpanShare = 0.70;
  static const double maxDieSpanShare = 1.60;

  /// The contrast at which a reading is worth half of what a perfect one
  /// would be, in the sensor's own levels. Deliberately a soft curve with no
  /// ceiling: a brighter frame is always a better frame, so this never quite
  /// reaches one and a dim room always scores lower for the same answer.
  static const double halfContrast = 40.0;

  /// How little a reading may be worth before it is not worth having.
  ///
  /// **Added because the first real footage produced a wrong roll and said so
  /// in the confidence.** On the one real window whose dice both landed in the
  /// band, the reader came back 3-4 where the pips read 3-6 to a human, at a
  /// confidence of **0.13**. The die it got wrong is tilted far enough to show
  /// two faces at once, so the blob spans a six and part of a neighbouring
  /// face — a shape the bed never draws, and one no size gate can catch.
  ///
  /// What makes a threshold safe here is that the separation is wide and
  /// measured on both sides. Every correct reading on the bed, over all
  /// twenty-one pairs at five die sizes, sharp and at corpus blur alike, scores
  /// between **0.544 and 0.641** — not one below 0.54. The synthetic corpus,
  /// whose dice sit at angles the bed's placements do not, runs lower but
  /// bottoms out at **0.268**, and every one of those readings is right. So
  /// this sits a comfortable way under the lowest reading known to be correct
  /// and a comfortable way over the one known to be wrong.
  ///
  /// It can only ever turn a reading into a null, which is the failure this
  /// class is built to prefer: a shrug costs one tap on the manual dice pad,
  /// and a wrong roll is folded into the authoritative game state for good.
  static const double minConfidence = 0.2;

  /// Bins the outline is measured in. Fifteen degrees each, which puts a
  /// square's corner within half a bin of a bin's middle.
  static const int outlineBins = 24;

  /// How small a die may be in the PICTURE, in pixels across, before the
  /// reader refuses to look at all.
  ///
  /// **The number is where WRONG answers begin, not where reading gets hard.**
  /// Everything else in this class fails closed: a die too small or too soft
  /// loses its pips, the pip gate finds fewer than one blob, and the reading
  /// comes back null. Measured over all twenty-one pairs on all three
  /// palettes, by shrinking the bed's dice — `found` is how many came back at
  /// all, `right` how many were the roll actually on the board:
  ///
  /// | die across | sharp frame | corpus blur + grain |
  /// |---|---|---|
  /// | 76px (the bed's own) | 21 found, 21 right | 21 found, 21 right |
  /// | 41px | 21 found, 21 right | 21 found, 21 right |
  /// | 31px | 21 found, 21 right | 21 found, 21 right |
  /// | 25px | 21 found, 21 right | 14 found, 14 right |
  /// | 21px | 21 found, 21 right | 7 found, 7 right |
  /// | **18px** | 5 found, **3 right** | 9 found, **7 right** |
  /// | 12px | 10 found, **5 right** | 8 found, **1 right** |
  ///
  /// Down to 21 pixels every reading that came back was the right roll and the
  /// rest were nulls — the reader just reads fewer of them as the frame gets
  /// softer, which is the designed behaviour and needs no floor. At 18 pixels
  /// that stops being true. A pip is a sixth of a die, so three pixels there,
  /// and three pixels of pale on pale is a grain of noise as often as it is a
  /// pip: blobs merge and split and the face count comes back confidently
  /// wrong. A wrong roll goes into the authoritative game state, which is the
  /// one thing this class exists to prevent. So the floor sits at 20, between
  /// the last size that was always right and the first that was not.
  ///
  /// **What this means for the first real footage.** Its dice measure 18 to 23
  /// pixels across in a 1920-wide frame — straddling this floor. So the honest
  /// gate answer is that dice photographed this small are not readable by this
  /// instrument: they want a closer camera, a longer lens, or the ML hatch.
  /// Not a lower threshold — the sizes below the floor are precisely the ones
  /// that produce wrong rolls rather than no rolls.
  static const double minDiePixels = 20.0;

  /// The dice on the board, or null when there are not exactly two of them.
  DiceReading? read() {
    // Nothing below can be trusted at a size the sensor never resolved, and a
    // guess here goes into the authoritative game state.
    if (diePixels < minDiePixels) return null;

    final grid = _sampleSurface();
    if (grid == null) return null;

    final candidates = <DieReading>[];
    for (final blob in _blobsIn(grid)) {
      final die = _readDie(grid, blob);
      if (die != null) candidates.add(die);
      // Three candidates is already an answer — nothing found later can make
      // this a pair again.
      if (candidates.length > 2) return null;
    }
    if (candidates.length != 2) return null;

    candidates.sort((a, b) => a.center.x.compareTo(b.center.x));
    final first = candidates[0], second = candidates[1];

    // One die seen twice is not a pair — see [minPairGap].
    final gapX = (second.center.x - first.center.x) / calibration.dieSide;
    final gapY = (second.center.y - first.center.y) / _dieDownUnits(grid);
    if (math.sqrt(gapX * gapX + gapY * gapY) < minPairGap) return null;

    final bigger = math.max(first.span, second.span);
    final smaller = math.min(first.span, second.span);
    final disagreement = bigger <= 0 ? 1.0 : 1 - smaller / bigger;
    if (disagreement > maxSizeDisagreement) return null;

    double signal(DieReading die) =>
        die.pipContrast / (die.pipContrast + halfContrast);

    final confidence = (signal(first) *
            signal(second) *
            (1 - disagreement / maxSizeDisagreement))
        .clamp(0.0, 1.0);
    if (confidence < minConfidence) return null;

    return DiceReading(
      first: first,
      second: second,
      confidence: confidence,
    );
  }

  /// How wide one die is across the lattice, in cells, and how tall.
  ///
  /// **Board space is a unit square whatever shape the board is**, so a die —
  /// which is square in the WORLD — is not square in board space, and nothing
  /// tells the reader the board's proportions. So it measures them: one cell
  /// is so many pixels across and so many down at the board's middle, and the
  /// ratio of the two is the local aspect. A die that spans `n` cells across
  /// spans `n * (pixels per cell across) / (pixels per cell down)` cells down,
  /// because those are the same distance on the table.
  ///
  /// Measured at the board's middle — the band's own middle, which is the
  /// same point — rather than at the blob, deliberately: the gates this feeds
  /// are about what a die IS, and a size that moved with where a die happened
  /// to land would make them mean something different in each half of the
  /// board.
  ({double across, double down, double pixels}) get _dieOnLattice {
    final b = boundsOf(calibration.atlas.roi(RoiId.diceZone));
    final midX = (b.minX + b.maxX) / 2, midY = (b.minY + b.maxY) / 2;
    final cellX = (b.maxX - b.minX) / latticeAcross;
    final cellY = 1.0 / latticeDown;

    double pixelsBetween(Pt a, Pt c) {
      final p = calibration.geometry.imagePointOf(a);
      final q = calibration.geometry.imagePointOf(c);
      if (!p.x.isFinite || !q.x.isFinite) return 0;
      return math.sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y));
    }

    final o = Pt(midX, midY);
    final wide = pixelsBetween(o, Pt(midX + cellX, midY));
    final tall = pixelsBetween(o, Pt(midX, midY + cellY));
    final across = calibration.dieSide / cellX;
    // A degenerate geometry gives no aspect to work with; treating the cells
    // as square is the least wrong thing and the visibility gate below will
    // reject such a frame anyway.
    final down = tall <= 0 ? across : across * wide / tall;
    return (across: across, down: down, pixels: across * wide);
  }

  /// How wide one die is in the picture, in pixels.
  double get diePixels => _dieOnLattice.pixels;

  /// The playing surface, sampled onto a regular lattice in board space.
  ///
  /// ## One lattice, two vocabularies
  ///
  /// Every cell is judged against the surfaces ITS OWN patch of board showed
  /// calibration — the owning point's, or the bar's — except inside the
  /// band, which keeps the two surfaces measured for [RoiId.diceZone].
  /// Neither choice can stand in for the other, and both directions are
  /// measured:
  ///
  /// * A point's territory MUST be judged by its own surfaces, because its
  ///   triangle is one of them. Judged against the band's felt-and-wood
  ///   instead, every triangle on the board is one giant foreign blob, and a
  ///   die landing on a triangle merges into that blob and is thrown away
  ///   with it.
  /// * The band MUST keep its own narrower pair, because extra vocabulary
  ///   can only HIDE a foreign object, and it measurably does: a pale die on
  ///   a brown board is 13 spreads from the band's felt and 2.3 from a cream
  ///   point triangle the band does not contain — and the first real
  ///   footage's left leaf is paler still, holding its in-band dice at 0.7
  ///   spreads from the leaf's own surfaces against 3.2 from the band's.
  ///   Only the band can afford the narrow pair: it showed calibration
  ///   almost the whole of itself, and its two surfaces — felt and the bar's
  ///   wood — are both measured from hundreds of samples.
  ///
  /// For the same reason, NO cell borrows the board-wide vocabulary
  /// `ColorModel.classify` lends a partly-hidden region. That loan exists so
  /// a region whose surface was under a checker at calibration does not
  /// invent a phantom checker out of felt it never measured — the right
  /// trade when the question is "which checker is this", and the wrong one
  /// here, where vocabulary only hides.
  ///
  /// Shape is measured on where those cells landed in the PICTURE, not on
  /// where they sit in board space: board space is a unit square whatever
  /// shape the board is, so a round checker is an ellipse there and would
  /// out-score a square on any test of roundness.
  _Surface? _sampleSurface() {
    final band = boundsOf(calibration.atlas.roi(RoiId.diceZone));
    final pad = (band.maxX - band.minX) * insetX;
    final x0 = band.minX + pad, x1 = band.maxX - pad;
    const y0 = 0.0, y1 = 1.0;

    final n = latticeAcross * latticeDown;
    final owners = _ownersByColumn(x0, x1);
    final surface = _Surface(
      x0: x0,
      x1: x1,
      y0: y0,
      y1: y1,
      bandMinY: band.minY,
      bandMaxY: band.maxY,
      bandBackground: colors.backgroundOf(RoiId.diceZone),
      ownersFar: owners.far,
      ownersNear: owners.near,
      foreign: Uint8List(n),
    );

    var seen = 0;
    for (var i = 0; i < n; i++) {
      final p = _imageAt(surface, i);
      if (!p.x.isFinite || !p.y.isFinite) continue;
      final px = p.x.round(), py = p.y.round();
      if (px < 0 || py < 0 || px >= frame.width || py >= frame.height) {
        continue;
      }
      final background = _referenceOf(surface, i);
      // The atlas's points and bar tile the surface, so a cell with no
      // owner is a board this code has never met; not counting it as seen
      // lets the visibility gate below say so rather than reading around
      // the hole.
      if (background == null) continue;
      seen++;
      final sample = frame.pixelAt(px, py);
      final f = ColorModel.feature(
        sample,
        background.color,
        exposure: colors.exposure,
      );
      if (background.distanceTo(f) > minForeignDistance) {
        surface.foreign[i] = 1;
      }
    }
    // A board hanging over the edge of the picture is not one to read dice
    // from. Saying nothing is the designed answer; the readability light is
    // what tells the user why.
    return seen / n < RoiSampler.minVisibleFraction ? null : surface;
  }

  /// Which region's background judges each lattice column, per half.
  ///
  /// The points and the bar tile the whole playing surface (see [RoiAtlas]),
  /// so every column belongs to exactly one region in each half. Resolved
  /// once per read from the atlas's own rectangles, because the atlas is the
  /// one place a session's board is described; the trays take no part — the
  /// surface the lattice spans ends where they begin.
  ({List<RoiBackground?> far, List<RoiBackground?> near}) _ownersByColumn(
    double x0,
    double x1,
  ) {
    final far = List<RoiBackground?>.filled(latticeAcross, null);
    final near = List<RoiBackground?>.filled(latticeAcross, null);
    for (final id in calibration.atlas.regions) {
      if (id == RoiId.diceZone ||
          id == RoiId.offWhite ||
          id == RoiId.offBlack) {
        continue;
      }
      final b = boundsOf(calibration.atlas.roi(id));
      final background = colors.backgroundOf(id);
      for (var col = 0; col < latticeAcross; col++) {
        final x = x0 + (col + 0.5) / latticeAcross * (x1 - x0);
        if (x < b.minX || x > b.maxX) continue;
        if (b.minY < RoiAtlas.midline) far[col] = background;
        if (b.maxY > RoiAtlas.midline) near[col] = background;
      }
    }
    return (far: far, near: near);
  }

  /// The background cell [i] is judged against — the band's own two
  /// surfaces inside the band, the owning point's or the bar's outside it.
  /// One rule, used by the sampling pass and by every later question about a
  /// cell, so the two can never quietly disagree.
  RoiBackground? _referenceOf(_Surface s, int i) {
    final y = _boardYAt(s, i);
    if (y >= s.bandMinY && y <= s.bandMaxY) return s.bandBackground;
    final col = i % latticeAcross;
    return y >= RoiAtlas.midline ? s.ownersNear[col] : s.ownersFar[col];
  }

  /// One die's y-extent in board units, from the board middle's aspect.
  ///
  /// The same estimate everything else uses ([_dieOnLattice]), named because
  /// the pip-shape frame leans on it and its error is now measured. The
  /// pixel aspect at any point carries the CAMERA's own y-foreshortening on
  /// top of the board's true proportions, so this over-estimates on a low
  /// camera — by about 1.35 on the first real footage (framed patterns
  /// compress to about 0.74 of a die frame, inside [PipPattern.tolerance])
  /// and by 1.85 at the tented bed's hinge crown, which is outside any
  /// tolerance that still refuses the wrong shapes. A die-frame divisor the
  /// camera cannot pollute needs a physical vertical reference; the
  /// measured checker pitch (`StackMetrics.pitch` is a disc's diameter in
  /// y-units) is the obvious candidate, queued with the tent findings.
  double _dieDownUnits(_Surface s) =>
      _dieOnLattice.down * (s.y1 - s.y0) / latticeDown;

  /// Board-space x of cell [i]'s middle.
  double _boardXAt(_Surface s, int i) =>
      s.x0 + (i % latticeAcross + 0.5) / latticeAcross * (s.x1 - s.x0);

  /// Board-space y of cell [i]'s middle.
  double _boardYAt(_Surface s, int i) =>
      s.y0 + (i ~/ latticeAcross + 0.5) / latticeDown * (s.y1 - s.y0);

  /// Where cell [i]'s middle lands in the picture.
  Pt _imageAt(_Surface s, int i) =>
      calibration.geometry.imagePointOf(Pt(_boardXAt(s, i), _boardYAt(s, i)));

  /// Cell [i]'s brightness, re-read from the frame.
  ///
  /// Zero for a cell the picture does not contain — which can only reach the
  /// pip arithmetic as a hole enclosed by a blob at the picture's very edge,
  /// on a frame the visibility gate already found barely acceptable.
  double _lumaAt(_Surface s, int i) {
    final p = _imageAt(s, i);
    if (!p.x.isFinite || !p.y.isFinite) return 0;
    final px = p.x.round(), py = p.y.round();
    if (px < 0 || py < 0 || px >= frame.width || py >= frame.height) return 0;
    return lumaOf(frame.pixelAt(px, py));
  }

  /// Connected runs of foreign cells, four-connected, big enough to matter.
  List<List<int>> _blobsIn(_Surface surface) {
    final n = latticeAcross * latticeDown;
    final die = _dieOnLattice;
    final dieCells = die.across * die.down;
    final minCells = math.max(1, (dieCells * minDieShare).round());
    // Never past the whole lattice: a share of a die is the right unit, but a
    // blob bigger than the surface it was found on is a bug rather than a
    // hand.
    final maxCells = math.min(n, (dieCells * maxDieShare).round());
    final seen = Uint8List(n);
    final blobs = <List<int>>[];
    final stack = <int>[];

    for (var start = 0; start < n; start++) {
      if (surface.foreign[start] == 0 || seen[start] == 1) continue;
      seen[start] = 1;
      stack
        ..clear()
        ..add(start);
      final cells = <int>[];
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        cells.add(i);
        final col = i % latticeAcross, row = i ~/ latticeAcross;
        if (col > 0) _push(surface, seen, stack, i - 1);
        if (col < latticeAcross - 1) _push(surface, seen, stack, i + 1);
        if (row > 0) _push(surface, seen, stack, i - latticeAcross);
        if (row < latticeDown - 1) _push(surface, seen, stack, i + latticeAcross);
      }
      if (cells.length >= minCells && cells.length <= maxCells) {
        blobs.add(cells);
      }
    }
    return blobs;
  }

  static void _push(_Surface surface, Uint8List seen, List<int> stack, int i) {
    if (surface.foreign[i] == 1 && seen[i] == 0) {
      seen[i] = 1;
      stack.add(i);
    }
  }

  /// A blob, if it turns out to be a die.
  DieReading? _readDie(_Surface surface, List<int> raw) {
    final cells = _fillHoles(raw);
    // The picture positions and brightness only this blob needs, computed
    // here: the surface keeps nothing per cell but the foreign mask (see
    // [_Surface] for the arithmetic that says why).
    final image = <int, Pt>{for (final i in cells) i: _imageAt(surface, i)};
    final outline = _outlineOf(image);
    if (outline == null || outline.scatter < minSquareness) return null;

    final die = _dieOnLattice;
    var cx = 0.0, cy = 0.0;
    for (final i in cells) {
      cx += _boardXAt(surface, i);
      cy += _boardYAt(surface, i);
    }
    final center = Pt(cx / cells.length, cy / cells.length);

    // A settled die LIES on the surface, so its middle is at least half a
    // die from every edge of it — nearer than that is up the board's wall,
    // which is not a place dice settle. What actually stands there is the
    // outermost checker of a far-edge stack, smeared die-sized by a steep
    // viewpoint and a sigma of blur: a bare classic board's stacks paired up
    // and read 2-4 at a confidence of 0.24 through every other gate, centred
    // 0.039 and 0.047 of the board from its far edge against a half-die of
    // 0.050 — and the first real footage grew a 4-4 the same way, one of its
    // "dice" centred 0.02 of the board from the rim.
    final halfAcross = calibration.dieSide / 2;
    final dieDownUnits = _dieDownUnits(surface);
    if (center.x < surface.x0 + halfAcross ||
        center.x > surface.x1 - halfAcross ||
        center.y < surface.y0 + dieDownUnits / 2 ||
        center.y > surface.y1 - dieDownUnits / 2) {
      return null;
    }

    final rounds = math.max(1, (die.across * pipErosionShare).round());
    final interior = _erode(cells, rounds);
    if (interior.length < cells.length * 0.1) return null;

    final luma = <int, double>{
      for (final i in interior) i: _lumaAt(surface, i),
    };
    final lumas = luma.values.toList()..sort();
    final body = lumas[lumas.length ~/ 2];
    final low = lumas[(lumas.length * pipPercentile).floor()];
    final high = lumas[
        math.min(lumas.length - 1, (lumas.length * (1 - pipPercentile)).ceil())];

    // Dice are usually pale with dark pips and occasionally the other way
    // round. Whichever tail is further from the body is the pips — a
    // two-sidedness that was briefly withdrawn while the search widened,
    // because a blurred black stack at a steep far edge is a dark mass
    // enclosing windows of plain felt, [_fillHoles] hands the windows back
    // as brilliant marks, and the "dark die with pale pips" read 2-4 on a
    // bare board. [PipPattern] made the withdrawal unnecessary and it was
    // reinstated, measured both ways: window marks never stand where a
    // face's pips stand, and with the shape test in place the two-sided
    // reader scores identically on the bed's whole suite and on all seventy
    // real windows.
    final darker = body - low >= high - body;
    final spread = darker ? body - low : high - body;
    if (spread < minPipContrast) return null;
    final cut = darker ? body - pipCut * spread : body + pipCut * spread;

    final pipCells = <int>{
      for (final i in interior)
        if (darker ? luma[i]! <= cut : luma[i]! >= cut) i,
    };
    final minPip = (interior.length * minPipShare).round();
    final maxPip = (interior.length * maxPipShare).round();
    final pips = <Pt>[];
    var pipLuma = 0.0, pipCount = 0;
    for (final pip in _componentsOf(pipCells)) {
      if (pip.length < minPip) continue;
      if (pip.length > maxPip) return null;
      var px = 0.0, py = 0.0;
      for (final i in pip) {
        px += _boardXAt(surface, i);
        py += _boardYAt(surface, i);
        pipLuma += luma[i]!;
        pipCount++;
      }
      pips.add(Pt(px / pip.length, py / pip.length));
    }

    // The face is the SHAPE the pips stand in, not their count — see
    // [PipPattern] for the misreads that retired counting. Positions are
    // scaled by the die the session measured and anchored on the blob's own
    // middle, so a fragment's dots and a two-face union's dots land outside
    // every face's shape instead of re-scaling into one.
    final face = PipPattern.faceOf(<Pt>[
      for (final p in pips)
        Pt(
          (p.x - center.x) / calibration.dieSide + 0.5,
          (p.y - center.y) / dieDownUnits + 0.5,
        ),
    ]);
    if (face == null) return null;

    // A die is the size the session said dice are. Too narrow is a fragment
    // cut at a camouflage seam — the wrong-smaller-face machine the constant
    // documents — and too wide is a die fused with something else.
    final span = _boardSpan(surface, cells);
    final share = span / calibration.dieSide;
    if (share < minDieSpanShare || share > maxDieSpanShare) return null;

    return DieReading(
      face: face,
      center: center,
      span: span,
      pipContrast: (body - pipLuma / pipCount).abs(),
      squareness: outline.scatter,
    );
  }

  /// How far the blob's outline scatters about its own middle, once the
  /// blob's covariance has been normalized away.
  ///
  /// The normalization is what makes this a shape test rather than an aspect
  /// test: any affine stretch of the picture — which is what perspective does
  /// to a small patch — leaves the number alone. A circle comes out near zero
  /// however it is squashed, and a square near an eighth however it is
  /// sheared.
  ({double scatter, double radius})? _outlineOf(Map<int, Pt> image) {
    var mx = 0.0, my = 0.0;
    for (final p in image.values) {
      mx += p.x;
      my += p.y;
    }
    mx /= image.length;
    my /= image.length;

    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (final p in image.values) {
      final dx = p.x - mx, dy = p.y - my;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    sxx /= image.length;
    sxy /= image.length;
    syy /= image.length;

    final trace = sxx + syy;
    final gap = math.sqrt((sxx - syy) * (sxx - syy) + 4 * sxy * sxy);
    final major = (trace + gap) / 2, minor = (trace - gap) / 2;
    if (minor <= 1e-9) return null;
    // Eigenvector of the major axis; the minor one is its perpendicular.
    var ex = sxy, ey = major - sxx;
    if (ex.abs() + ey.abs() < 1e-12) {
      ex = 1;
      ey = 0;
    }
    final norm = math.sqrt(ex * ex + ey * ey);
    ex /= norm;
    ey /= norm;
    final sMajor = math.sqrt(major), sMinor = math.sqrt(minor);

    final reach = List<double>.filled(outlineBins, 0);
    for (final p in image.values) {
      final dx = p.x - mx, dy = p.y - my;
      final u = (dx * ex + dy * ey) / sMajor;
      final v = (-dx * ey + dy * ex) / sMinor;
      final r = math.sqrt(u * u + v * v);
      var bin = ((math.atan2(v, u) + math.pi) / (2 * math.pi) * outlineBins)
          .floor();
      if (bin < 0) bin = 0;
      if (bin >= outlineBins) bin = outlineBins - 1;
      if (r > reach[bin]) reach[bin] = r;
    }

    var mean = 0.0, filled = 0;
    for (final r in reach) {
      if (r <= 0) continue;
      mean += r;
      filled++;
    }
    // A blob that leaves whole directions empty is not a solid shape at all.
    if (filled < outlineBins) return null;
    mean /= filled;
    var variance = 0.0;
    for (final r in reach) {
      if (r <= 0) continue;
      variance += (r - mean) * (r - mean);
    }
    variance /= filled;
    return (scatter: math.sqrt(variance) / mean, radius: mean);
  }

  /// The blob with anything enclosed by it counted as part of it.
  ///
  /// Measured, and the reason this exists: a pip's edge blends into the die's
  /// body, and on a pale board that blend passes straight through the colour
  /// of the felt. Every pip therefore comes ringed by cells the board accounts
  /// for perfectly well, which punches the pips out of the blob as holes —
  /// and then eroding the blob eats the pips before it reaches the rim, which
  /// is the opposite of what the erosion is for. A pip that is a hole in a die
  /// is still a pip, so the hole goes back in.
  List<int> _fillHoles(List<int> cells) {
    var minCol = latticeAcross, maxCol = -1;
    var minRow = latticeDown, maxRow = -1;
    for (final i in cells) {
      final col = i % latticeAcross, row = i ~/ latticeAcross;
      minCol = math.min(minCol, col);
      maxCol = math.max(maxCol, col);
      minRow = math.min(minRow, row);
      maxRow = math.max(maxRow, row);
    }
    // One cell of margin all round, so the flood below always has a border of
    // non-blob cells to start from.
    final w = maxCol - minCol + 3, h = maxRow - minRow + 3;
    final blob = Uint8List(w * h);
    for (final i in cells) {
      final col = i % latticeAcross - minCol + 1;
      final row = i ~/ latticeAcross - minRow + 1;
      blob[row * w + col] = 1;
    }

    final outside = Uint8List(w * h);
    final stack = <int>[];
    for (var col = 0; col < w; col++) {
      stack..add(col)..add((h - 1) * w + col);
    }
    for (var row = 0; row < h; row++) {
      stack..add(row * w)..add(row * w + w - 1);
    }
    while (stack.isNotEmpty) {
      final j = stack.removeLast();
      if (blob[j] == 1 || outside[j] == 1) continue;
      outside[j] = 1;
      final col = j % w, row = j ~/ w;
      if (col > 0) stack.add(j - 1);
      if (col < w - 1) stack.add(j + 1);
      if (row > 0) stack.add(j - w);
      if (row < h - 1) stack.add(j + w);
    }

    final filled = List<int>.of(cells);
    for (var row = 1; row < h - 1; row++) {
      for (var col = 1; col < w - 1; col++) {
        final j = row * w + col;
        if (blob[j] == 1 || outside[j] == 1) continue;
        filled.add((row + minRow - 1) * latticeAcross + (col + minCol - 1));
      }
    }
    return filled;
  }

  /// The blob without its outermost [rounds] cells.
  List<int> _erode(List<int> cells, int rounds) {
    var live = cells.toSet();
    for (var round = 0; round < rounds; round++) {
      final next = <int>{};
      for (final i in live) {
        final col = i % latticeAcross, row = i ~/ latticeAcross;
        if (col == 0 || col == latticeAcross - 1) continue;
        if (row == 0 || row == latticeDown - 1) continue;
        if (live.contains(i - 1) &&
            live.contains(i + 1) &&
            live.contains(i - latticeAcross) &&
            live.contains(i + latticeAcross)) {
          next.add(i);
        }
      }
      live = next;
      if (live.isEmpty) break;
    }
    return live.toList();
  }

  /// Four-connected runs within an arbitrary set of cells.
  List<List<int>> _componentsOf(Set<int> cells) {
    final seen = <int>{};
    final out = <List<int>>[];
    final stack = <int>[];
    for (final start in cells) {
      if (!seen.add(start)) continue;
      stack
        ..clear()
        ..add(start);
      final run = <int>[];
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        run.add(i);
        final col = i % latticeAcross;
        for (final j in <int>[
          if (col > 0) i - 1,
          if (col < latticeAcross - 1) i + 1,
          i - latticeAcross,
          i + latticeAcross,
        ]) {
          if (cells.contains(j) && seen.add(j)) stack.add(j);
        }
      }
      out.add(run);
    }
    return out;
  }

  /// How far across the blob is in board-space x — a size two dice from the
  /// same set have to agree about.
  double _boardSpan(_Surface surface, List<int> cells) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final i in cells) {
      final x = _boardXAt(surface, i);
      lo = math.min(lo, x);
      hi = math.max(hi, x);
    }
    return hi - lo;
  }
}

/// The playing surface, sampled: which cells hold something the board does
/// not account for, and the rectangle they were sampled over.
///
/// Deliberately nothing per cell but the mask. The band this grew from
/// carried five parallel arrays — board position, picture position,
/// brightness — and at the band's size that was cheap. The surface is six
/// times the band, four million cells on a small-dice board, and everything
/// except the mask matters only for the few thousand cells inside candidate
/// blobs — so those are recomputed from the cell's own index when a blob
/// asks, instead of being stored for millions of cells nothing will look at
/// again.
class _Surface {
  final double x0, x1, y0, y1;

  /// The band's extent and reference, and each column's owning region per
  /// half — everything `DiceReader._referenceOf` needs to answer for any
  /// cell, carried so the sampling pass and the pip gates judge colour
  /// against the very same surfaces.
  final double bandMinY, bandMaxY;
  final RoiBackground bandBackground;
  final List<RoiBackground?> ownersFar, ownersNear;

  final Uint8List foreign;

  const _Surface({
    required this.x0,
    required this.x1,
    required this.y0,
    required this.y1,
    required this.bandMinY,
    required this.bandMaxY,
    required this.bandBackground,
    required this.ownersFar,
    required this.ownersNear,
    required this.foreign,
  });
}
