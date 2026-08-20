import 'dart:math' as math;
import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';

import 'calibration.dart';
import 'color_model.dart';
import 'frame.dart';
import 'geometry_types.dart';
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

/// Finding two dice in the band the atlas reserves, and reading their faces.
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
/// ## Telling a die from a checker
///
/// The dice band overlaps every point's headroom and the whole bar — that
/// overlap is deliberate, it is the same felt seen two ways (see [RoiAtlas]).
/// So the band is full of round things that are not dice and the reader
/// cannot assume otherwise. Three gates, in order of how much they cost:
///
/// 1. **Foreign to the board.** A cell counts only if it is further than
///    [minForeignDistance] from every surface calibration learned for the
///    band. This finds dice AND checkers AND hands — anything the board does
///    not account for. It cannot be asked to find dice specifically, because
///    there is no learned distribution for a die: calibration has never been
///    shown one, and there is no colour constant anywhere in this package to
///    fall back on.
/// 2. **Square, not round.** The blob's outline is measured about its own
///    middle after its covariance has been normalized away, which makes the
///    test blind to the perspective stretch that turns a circle into an
///    ellipse and a square into a parallelogram. A circle scores near zero
///    whatever angle it is seen from; a square scores near an eighth.
/// 3. **It has pips.** A die's face carries one to six small dark blobs well
///    inside its body; a checker is flat colour all the way across. This is
///    both the face reading and the last word on whether the thing is a die,
///    and it is the gate that catches the awkward cases gate 2 lets through —
///    a checker sliced by the edge of the band is not round any more, but it
///    still has nothing inside it.
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

  /// Cells across and down the band, for THIS session's dice.
  ///
  /// See [baseLatticeAcross]: the pair is scaled so that a die always spans
  /// the same number of cells, whatever size it is.
  final int latticeAcross;
  final int latticeDown;

  DiceReader(this.calibration, this.frame)
      : colors = calibration.colorsIn(frame),
        latticeAcross = _scaledLattice(baseLatticeAcross, calibration.dieSide),
        latticeDown = _scaledLattice(baseLatticeDown, calibration.dieSide);

  /// Cells across and down the band, for a die of [BoardCalibration
  /// .defaultDieSide].
  ///
  /// Sized so a pip — about a sixth of a die across — spans the best part of
  /// ten cells, which is what it takes to separate the six pips of a six from
  /// each other and from the die's rim.
  ///
  /// **Everything below is a share of a DIE, not of the band.** These two were
  /// the last absolute size in the reader: they described how finely to sample
  /// a band containing the bed's dice, and a board whose dice are a third of
  /// that size got a third of the cells per die and fell through every gate
  /// that follows. So the pair scales with [BoardCalibration.dieSide] and the
  /// numbers here are what the scaling is anchored to.
  static const int baseLatticeAcross = 600;
  static const int baseLatticeDown = 80;

  /// The band is never sampled finer than this many cells across, whatever
  /// the dice.
  ///
  /// Sampling finer than the frame's own pixels cannot recover detail the
  /// sensor did not capture, and the cost is quadratic: the cap is what stops
  /// a mis-measured `dieSide` of a thousandth from asking for forty-five
  /// thousand cells across and a hundred million cells of work. Dice small
  /// enough to reach it are refused by [minDiePixels] long before it binds.
  static const int maxLatticeAcross = 2400;

  static int _scaledLattice(int base, double dieSide) {
    final scale = BoardCalibration.defaultDieSide / dieSide;
    final capped =
        math.min(scale, maxLatticeAcross / baseLatticeAcross);
    return math.max(1, (base * capped).round());
  }

  /// How far in from the band's own sides to sample, as a fraction of its
  /// width. The band ends where the bear-off wells begin — or, on a board with
  /// no wells, at the board's own edge — and what is immediately outside
  /// belongs to neither.
  static const double insetX = 0.004;

  /// How far from every surface the band is known to show, in spreads, before
  /// a cell counts as something the board does not account for.
  ///
  /// Measured: on the hardest of the three palettes — pale wood dice on pale
  /// wood felt — a die's body sits 6.3 spreads from the felt and 9.2 from the
  /// bar's wood, and the band's own surfaces sit within about 1.5 of
  /// themselves. Three leaves room on both sides.
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

    final grid = _sampleBand();
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
  /// is so many pixels across and so many down at the band's middle, and the
  /// ratio of the two is the local aspect. A die that spans `n` cells across
  /// spans `n * (pixels per cell across) / (pixels per cell down)` cells down,
  /// because those are the same distance on the table.
  ///
  /// Measured at the band's middle rather than at the blob, deliberately: the
  /// gates this feeds are about what a die IS, and a size that moved with
  /// where a die happened to land would make them mean something different in
  /// each half of the board.
  ({double across, double down, double pixels}) get _dieOnLattice {
    final b = boundsOf(calibration.atlas.roi(RoiId.diceZone));
    final midX = (b.minX + b.maxX) / 2, midY = (b.minY + b.maxY) / 2;
    final cellX = (b.maxX - b.minX) / latticeAcross;
    final cellY = (b.maxY - b.minY) / latticeDown;

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

  /// The band, sampled onto a regular lattice in board space.
  ///
  /// Shape is measured on where those cells landed in the PICTURE, not on
  /// where they sit in board space: board space is a unit square whatever
  /// shape the board is, so a round checker is an ellipse there and would
  /// out-score a square on any test of roundness.
  _Band? _sampleBand() {
    final b = boundsOf(calibration.atlas.roi(RoiId.diceZone));
    final pad = (b.maxX - b.minX) * insetX;
    final x0 = b.minX + pad, x1 = b.maxX - pad;
    final y0 = b.minY, y1 = b.maxY;

    final n = latticeAcross * latticeDown;
    final band = _Band(
      boardX: Float64List(n),
      boardY: Float64List(n),
      imageX: Float64List(n),
      imageY: Float64List(n),
      luma: Float64List(n),
      foreign: Uint8List(n),
    );

    final background = colors.backgroundOf(RoiId.diceZone);
    var seen = 0;
    for (var row = 0; row < latticeDown; row++) {
      final y = y0 + (row + 0.5) / latticeDown * (y1 - y0);
      for (var col = 0; col < latticeAcross; col++) {
        final i = row * latticeAcross + col;
        final x = x0 + (col + 0.5) / latticeAcross * (x1 - x0);
        band.boardX[i] = x;
        band.boardY[i] = y;
        final p = calibration.geometry.imagePointOf(Pt(x, y));
        if (!p.x.isFinite || !p.y.isFinite) continue;
        final px = p.x.round(), py = p.y.round();
        if (px < 0 || py < 0 || px >= frame.width || py >= frame.height) {
          continue;
        }
        seen++;
        band.imageX[i] = p.x;
        band.imageY[i] = p.y;
        final sample = frame.pixelAt(px, py);
        band.luma[i] = lumaOf(sample);
        // The band's OWN surfaces, and deliberately not the board-wide
        // vocabulary `ColorModel.classify` would lend it. That loan exists so
        // a region whose surface was under a checker at calibration does not
        // invent a phantom checker out of felt it never measured — the right
        // trade when the question is "which checker is this". It is the wrong
        // trade here: extra vocabulary can only HIDE a foreign object, and it
        // measurably does. A pale die on a brown board is 13 spreads from the
        // band's own felt and 2.3 from a cream point triangle the band does
        // not contain and never will.
        //
        // The band can afford to go without the loan because, unlike the
        // points, it showed calibration almost the whole of itself: only the
        // tops of the four tallest stacks stand in it, and its two surfaces —
        // felt and the bar's wood — are both measured from hundreds of
        // samples.
        final f = ColorModel.feature(
          sample,
          background.color,
          exposure: colors.exposure,
        );
        if (background.distanceTo(f) > minForeignDistance) {
          band.foreign[i] = 1;
        }
      }
    }
    // A band hanging over the edge of the picture is not one to read dice
    // from. Saying nothing is the designed answer; the readability light is
    // what tells the user why.
    return seen / n < RoiSampler.minVisibleFraction ? null : band;
  }

  /// Connected runs of foreign cells, four-connected, big enough to matter.
  List<List<int>> _blobsIn(_Band band) {
    final n = latticeAcross * latticeDown;
    final die = _dieOnLattice;
    final dieCells = die.across * die.down;
    final minCells = math.max(1, (dieCells * minDieShare).round());
    // Never past the whole band: a share of a die is the right unit, but a
    // blob bigger than the band it was found in is a bug rather than a hand.
    final maxCells = math.min(n, (dieCells * maxDieShare).round());
    final seen = Uint8List(n);
    final blobs = <List<int>>[];
    final stack = <int>[];

    for (var start = 0; start < n; start++) {
      if (band.foreign[start] == 0 || seen[start] == 1) continue;
      seen[start] = 1;
      stack
        ..clear()
        ..add(start);
      final cells = <int>[];
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        cells.add(i);
        final col = i % latticeAcross, row = i ~/ latticeAcross;
        if (col > 0) _push(band, seen, stack, i - 1);
        if (col < latticeAcross - 1) _push(band, seen, stack, i + 1);
        if (row > 0) _push(band, seen, stack, i - latticeAcross);
        if (row < latticeDown - 1) _push(band, seen, stack, i + latticeAcross);
      }
      if (cells.length >= minCells && cells.length <= maxCells) {
        blobs.add(cells);
      }
    }
    return blobs;
  }

  static void _push(_Band band, Uint8List seen, List<int> stack, int i) {
    if (band.foreign[i] == 1 && seen[i] == 0) {
      seen[i] = 1;
      stack.add(i);
    }
  }

  /// A blob, if it turns out to be a die.
  DieReading? _readDie(_Band band, List<int> raw) {
    final cells = _fillHoles(raw);
    final outline = _outlineOf(band, cells);
    if (outline == null || outline.scatter < minSquareness) return null;

    final rounds = math.max(
      1,
      (_dieOnLattice.across * pipErosionShare).round(),
    );
    final interior = _erode(cells, rounds);
    if (interior.length < cells.length * 0.1) return null;

    final lumas = <double>[for (final i in interior) band.luma[i]]..sort();
    final body = lumas[lumas.length ~/ 2];
    final low = lumas[(lumas.length * pipPercentile).floor()];
    final high = lumas[
        math.min(lumas.length - 1, (lumas.length * (1 - pipPercentile)).ceil())];

    // Dice are usually pale with dark pips and occasionally the other way
    // round. Whichever tail is further from the body is the pips.
    final darker = body - low >= high - body;
    final spread = darker ? body - low : high - body;
    if (spread < minPipContrast) return null;
    final cut = darker ? body - pipCut * spread : body + pipCut * spread;

    final pipCells = <int>{
      for (final i in interior)
        if (darker ? band.luma[i] <= cut : band.luma[i] >= cut) i,
    };
    final minPip = (interior.length * minPipShare).round();
    final maxPip = (interior.length * maxPipShare).round();
    var face = 0;
    var pipLuma = 0.0, pipCount = 0;
    for (final pip in _componentsOf(pipCells)) {
      if (pip.length < minPip) continue;
      if (pip.length > maxPip) return null;
      face++;
      for (final i in pip) {
        pipLuma += band.luma[i];
        pipCount++;
      }
    }
    if (face < 1 || face > 6) return null;

    var cx = 0.0, cy = 0.0;
    for (final i in cells) {
      cx += band.boardX[i];
      cy += band.boardY[i];
    }
    return DieReading(
      face: face,
      center: Pt(cx / cells.length, cy / cells.length),
      span: _boardSpan(band, cells),
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
  ({double scatter, double radius})? _outlineOf(_Band band, List<int> cells) {
    var mx = 0.0, my = 0.0;
    for (final i in cells) {
      mx += band.imageX[i];
      my += band.imageY[i];
    }
    mx /= cells.length;
    my /= cells.length;

    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (final i in cells) {
      final dx = band.imageX[i] - mx, dy = band.imageY[i] - my;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    sxx /= cells.length;
    sxy /= cells.length;
    syy /= cells.length;

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
    for (final i in cells) {
      final dx = band.imageX[i] - mx, dy = band.imageY[i] - my;
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
  /// of the felt. Every pip therefore comes ringed by cells the band accounts
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
  double _boardSpan(_Band band, List<int> cells) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final i in cells) {
      lo = math.min(lo, band.boardX[i]);
      hi = math.max(hi, band.boardX[i]);
    }
    return hi - lo;
  }
}

/// The dice band, sampled: where each cell is in board space and in the
/// picture, how bright it was, and whether it is something the board does not
/// account for.
class _Band {
  final Float64List boardX;
  final Float64List boardY;
  final Float64List imageX;
  final Float64List imageY;
  final Float64List luma;
  final Uint8List foreign;

  const _Band({
    required this.boardX,
    required this.boardY,
    required this.imageX,
    required this.imageY,
    required this.luma,
    required this.foreign,
  });
}
