import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';

import 'roi_atlas.dart';

/// One sampled pixel, in the order `Frame.pixelAt` hands its bytes back.
typedef Rgb = (int, int, int);

/// What a sample turned out to be.
enum CheckerColor {
  white,
  black,

  /// Not a checker: the board's own surface, or something the model has never
  /// been shown. Perception says "no checker here", never "nothing here".
  none;

  static CheckerColor ofPlayer(Player player) =>
      player == Player.white ? CheckerColor.white : CheckerColor.black;

  /// The player whose checkers these are, or null for [none].
  Player? get player => switch (this) {
        CheckerColor.white => Player.white,
        CheckerColor.black => Player.black,
        CheckerColor.none => null,
      };
}

/// A cloud of samples in the model's feature space: where its middle is and
/// how far its members scatter, one number per channel.
///
/// Diagonal on purpose — a full covariance would need far more samples than a
/// single calibration frame offers, and the axes of this feature space are
/// already close to independent.
class ColorDistribution {
  /// Per-channel middle of the cloud (a median, so one bad region cannot drag
  /// it), in the feature space [ColorModel.feature] produces.
  final List<double> mean;

  /// Per-channel scatter, never below [ColorModel.minSpread]: a distribution
  /// learned from flat synthetic colour would otherwise be so tight that
  /// nothing in a real photograph could ever fall inside it.
  final List<double> spread;

  final int sampleCount;

  ColorDistribution({
    required List<double> mean,
    required List<double> spread,
    required this.sampleCount,
  })  : mean = List<double>.unmodifiable(mean),
        spread = List<double>.unmodifiable(spread);

  /// How many spreads [feature] is from this cloud's middle.
  double distanceTo(List<double> feature) {
    var sum = 0.0;
    for (var c = 0; c < 3; c++) {
      final d = (feature[c] - mean[c]) / spread[c];
      sum += d * d;
    }
    return math.sqrt(sum);
  }

  @override
  String toString() => 'ColorDistribution(mean: ${_fixed(mean)}, '
      'spread: ${_fixed(spread)}, n: $sampleCount)';
}

/// What one region of the board looks like with no checker on it.
///
/// [color] is the reference every sample in this region is measured against —
/// the local exposure, which is what makes classification survive a lamp on
/// one side of the table. [modes] are the surfaces the region actually showed
/// during calibration, as features relative to [color]: on most boards that is
/// the felt and the triangle painted on it, which are different enough that a
/// single average of the two would describe neither.
class RoiBackground {
  /// The region's reference colour: the median of every checker-free sample
  /// taken in it.
  final Rgb color;

  /// One to two surface appearances, relative to [color]. Empty only when the
  /// region showed nothing usable.
  final List<List<double>> modes;

  /// Per-channel scatter within those surfaces, floored like every other
  /// spread in the model.
  final List<double> spread;

  final int sampleCount;

  /// Whether the region showed its whole surface during calibration.
  ///
  /// False for nine regions: the eight points the starting position covers
  /// with checkers, whose triangles were partly or wholly hidden, and the dice
  /// band, which the four tallest stacks reach into. Their [modes] describe
  /// only what was visible around the checkers, so [ColorModel.classify] lends
  /// them the board-wide vocabulary. Anything reading "no checker" there still
  /// deserves less trust than elsewhere, which is why the flag is public
  /// rather than an implementation detail.
  final bool fullyMeasured;

  RoiBackground({
    required this.color,
    required List<List<double>> modes,
    required List<double> spread,
    required this.sampleCount,
    required this.fullyMeasured,
  })  : modes = List<List<double>>.unmodifiable(
          modes.map(List<double>.unmodifiable),
        ),
        spread = List<double>.unmodifiable(spread);

  /// How many spreads [feature] is from the nearest surface this region
  /// showed, or infinity when it showed none.
  double distanceTo(List<double> feature) => _distanceToModes(
        feature,
        modes,
        spread,
      );

  @override
  String toString() => 'RoiBackground($color, ${modes.length} modes, '
      'n: $sampleCount${fullyMeasured ? '' : ', partly hidden'})';
}

/// This board's colours, as learned from its own starting position.
///
/// ## The feature space
///
/// A sample is never judged on its own bytes. It is judged on the **per-channel
/// natural logarithm of its ratio to its region's background**:
///
/// ```text
/// f = ( ln(Rs/Rb), ln(Gs/Gb), ln(Bs/Bb) )
/// ```
///
/// Turn the room light down and every byte in the frame is multiplied by the
/// same factor; the factor appears in both halves of each ratio and cancels
/// exactly. That is the spec's lighting-robustness mechanism, and it is why
/// the reference is *per region* rather than global: a lamp to one side of the
/// table dims the far half of the board more than the near half, and each
/// region carries its own local exposure in [RoiBackground.color].
///
/// One catch, which [renormalized] exists for: a background is *measured once*,
/// at calibration, and a checker sitting on it can never be measured again.
/// So when the light drifts, the ratio has a dimmed numerator over a
/// calibration-bright denominator and stops cancelling. Scaling every
/// reference by how much the light has moved — the spec's "slow exposure drift
/// re-normalizes on each confirmed-stable frame" — restores it.
///
/// Logarithms rather than plain ratios so that "twice as bright" and "half as
/// bright" are the same distance from the reference, which keeps a single
/// symmetric spread honest for both. Channels are kept separate rather than
/// collapsed to a chroma pair because the two checker colours on a great many
/// boards — cream and near-black — differ almost entirely in brightness and
/// hardly at all in hue.
///
/// ## Classifying
///
/// Three learned answers compete for every sample: the two checker clouds and
/// the region's own surface. The nearest wins, measured in spreads, and the
/// surface has to win by [boardPreferenceMargin] to veto a checker, because
/// where the two are that close the board has told us nothing that separates
/// them and the answer that does not make a real checker vanish is the better
/// one. Nothing within [maxClassDistance] of any of the three is
/// [CheckerColor.none].
///
/// **The known blind spot**, measured on the synthetic bed rather than
/// suspected: over-expose a board whose points are pale and both the points
/// and the white checkers clip to the same 255, at which point the margin
/// between them is exactly zero and a bare point reads as a white checker.
/// This is not a modelling failure to be tuned away — the sensor discarded the
/// difference — and the tie is broken toward the checker on purpose. What
/// catches it is `CalibrationFingerprint.clippedFraction`, which is why that
/// number exists.
///
/// ## No colour is written down here
///
/// Everything above is learned at calibration from the known starting
/// position. There is not a single colour constant in this package's `lib/`,
/// and `test/calibration_test.dart` fails the build if one appears.
/// ## Numbers, provisionally
///
/// Every threshold below was measured against the synthetic renderer, which
/// paints in flat colour. Real boards have grain, weave, gloss and shadow, and
/// the corpus gate (the plan's Task 6) is where each of these gets asked
/// again with photographs. Nothing outside this file should hard-code any of
/// them.
class ColorModel {
  /// The floor under every spread in the model, in log units — about 15% of
  /// intensity. It keeps a distribution learned from flat colour from being so
  /// tight that ordinary photographic variation falls outside it.
  ///
  /// Worth being plain about how much this one is currently doing: against the
  /// synthetic renderer every measured spread comes out *below* the floor, so
  /// [boardSpread] is exactly `[0.15, 0.15, 0.15]` on all three palettes and
  /// the floor is the whole of the scale in the borrowed-background path. The
  /// measured half of this number has never yet been exercised; the first real
  /// photograph will exercise it.
  static const double minSpread = 0.15;

  /// How far apart [separation] must find the two checker clouds before a
  /// calibration is worth keeping. The three synthetic palettes come out at
  /// 15.1, 9.5 and 5.1 — so this refuses only a board considerably worse than
  /// the one deliberately built to be hard.
  static const double minSeparation = 2.0;

  /// Farther than this from all three learned answers and a sample is nothing
  /// the model knows: [CheckerColor.none], not a guess. Genuine checker
  /// samples sit under 1 in every synthetic condition tested, and about 3.3
  /// in the worst (a board clipping at 40% over its calibration light), so
  /// this leaves room without admitting a hand or a coffee cup.
  static const double maxClassDistance = 6.0;

  /// How much closer the region's own surface has to be than a checker cloud
  /// before it wins. See the class doc for why the tie goes to the checker.
  static const double boardPreferenceMargin = 0.5;

  final ColorDistribution white;
  final ColorDistribution black;

  /// Every surface the fully-visible regions showed, pooled. Regions that were
  /// under checkers during calibration borrow this vocabulary, because their
  /// own is missing whatever the stack was sitting on.
  final List<List<double>> boardModes;

  /// The scatter to measure [boardModes] with.
  final List<double> boardSpread;

  /// How much brighter the frames being classified are than the frame this
  /// model was learned from. One until [renormalized] says otherwise.
  final double exposure;

  final Map<RoiId, RoiBackground> _backgrounds;

  ColorModel({
    required this.white,
    required this.black,
    required Map<RoiId, RoiBackground> backgrounds,
    required List<List<double>> boardModes,
    required List<double> boardSpread,
    this.exposure = 1.0,
  })  : _backgrounds = Map<RoiId, RoiBackground>.unmodifiable(backgrounds),
        boardModes = List<List<double>>.unmodifiable(
          boardModes.map(List<double>.unmodifiable),
        ),
        boardSpread = List<double>.unmodifiable(boardSpread);

  /// The same model, reading a board whose light has drifted since it was
  /// learned.
  ///
  /// [exposure] is how much brighter the current frame's board is than the
  /// calibration frame's — the ratio of two `CalibrationFingerprint.meanLuma`
  /// values, which the session already takes on every stable frame. Everything
  /// learned stays: only the references the samples are divided by move.
  ///
  /// A single number cannot undo everything light does. It cannot recover
  /// detail a bright frame clipped away, and it does not touch a change of
  /// colour cast. Judging when the drift has gone past what this can absorb is
  /// the fingerprint's job, not this method's — it will happily scale by ten.
  ColorModel renormalized(double exposure) => ColorModel(
        white: white,
        black: black,
        backgrounds: _backgrounds,
        boardModes: boardModes,
        boardSpread: boardSpread,
        exposure: exposure <= 0 ? 1.0 : exposure,
      );

  /// What [region] looks like bare, as measured under the calibration frame's
  /// light.
  RoiBackground backgroundOf(RoiId region) => _backgrounds[region]!;

  /// The two checker clouds' separation, in units of their own combined
  /// spread, per channel and then summed as a length.
  ///
  /// One means the clouds are a single combined spread apart — touching.
  /// [minSeparation] asks for rather more than that before calibration will
  /// claim it can tell this board's checkers apart.
  double get separation {
    var sum = 0.0;
    for (var c = 0; c < 3; c++) {
      final d =
          (white.mean[c] - black.mean[c]) / (white.spread[c] + black.spread[c]);
      sum += d * d;
    }
    return math.sqrt(sum);
  }

  /// What [sample] is, judged against the region it was taken from.
  CheckerColor classify(Rgb sample, RoiBackground background) {
    final f = feature(sample, background.color, exposure: exposure);
    final toWhite = white.distanceTo(f);
    final toBlack = black.distanceTo(f);
    var toBoard = background.distanceTo(f);
    if (!background.fullyMeasured) {
      toBoard = math.min(
        toBoard,
        _distanceToModes(f, boardModes, boardSpread),
      );
    }

    final nearestChecker = math.min(toWhite, toBlack);
    if (math.min(nearestChecker, toBoard) > maxClassDistance) {
      return CheckerColor.none;
    }
    if (toBoard + boardPreferenceMargin <= nearestChecker) {
      return CheckerColor.none;
    }
    return toWhite <= toBlack ? CheckerColor.white : CheckerColor.black;
  }

  /// [classify], with the background looked up for you.
  CheckerColor classifyIn(RoiId region, Rgb sample) =>
      classify(sample, backgroundOf(region));

  /// A sample's position in the model's feature space — see the class doc.
  ///
  /// [exposure] scales the reference, for a frame whose light has drifted
  /// since the reference was measured. Channels are floored at one before
  /// dividing, so a black pixel in a black shadow is a finite ratio rather
  /// than a nan.
  static List<double> feature(
    Rgb sample,
    Rgb reference, {
    double exposure = 1.0,
  }) =>
      <double>[
        math.log(_atLeastOne(sample.$1) / //
            (_atLeastOne(reference.$1) * exposure)),
        math.log(_atLeastOne(sample.$2) / //
            (_atLeastOne(reference.$2) * exposure)),
        math.log(_atLeastOne(sample.$3) / //
            (_atLeastOne(reference.$3) * exposure)),
      ];

  @override
  String toString() => 'ColorModel(separation: '
      '${separation.toStringAsFixed(2)}, ${_backgrounds.length} regions)';
}

double _atLeastOne(int channel) => channel < 1 ? 1.0 : channel.toDouble();

double _distanceToModes(
  List<double> feature,
  List<List<double>> modes,
  List<double> spread,
) {
  var best = double.infinity;
  for (final mode in modes) {
    var sum = 0.0;
    for (var c = 0; c < 3; c++) {
      final d = (feature[c] - mode[c]) / spread[c];
      sum += d * d;
    }
    final distance = math.sqrt(sum);
    if (distance < best) best = distance;
  }
  return best;
}

String _fixed(List<double> v) =>
    '[${v.map((d) => d.toStringAsFixed(3)).join(', ')}]';
