import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';

import 'calibration.dart';
import 'color_model.dart';
import 'frame.dart';
import 'occupancy.dart';
import 'roi_atlas.dart';

/// One candidate legal play, scored against what two settled frames showed.
///
/// Ranked lists of these are what [PlayMatcher.match] answers with. A caller
/// reads three things off the front of that list: whether the best candidate is
/// [plausible] at all, whether it is [isAmbiguous], and — only then — which
/// [play] it is.
class PlayMatch {
  /// The candidate this entry scores.
  final Move play;

  /// The position [play] leaves behind. The identity that decides ties: two
  /// plays reaching the same board are the same observation.
  final BoardState after;

  /// The other candidates that reach [after] and are therefore impossible to
  /// tell from [play] by any comparison of the two frames.
  ///
  /// Empty when [play] is uniquely identified. When it is not, every one of
  /// these appears in the returned list in its own right, at exactly the same
  /// [confidence] — see [PlayMatcher.match]'s doc for why a winner is not
  /// picked here.
  final List<Move> tiedWith;

  /// How well the observed change fits this candidate, from 0 to 1.
  ///
  /// **Not a probability, and deliberately not calibrated as one** — the same
  /// stance [RegionOccupancy.confidence] and [DiceReading.confidence] take. It
  /// is [cost] and [instability] put through the two falloffs on
  /// [PlayMatcher], so that candidates can be ordered and a floor can be set
  /// under "this is not any of them".
  final double confidence;

  /// The weighted disagreement between this candidate's expected per-region
  /// deltas and the observed ones. Zero is a perfect fit.
  final double cost;

  /// The weighted change observed on regions **no** candidate touches.
  ///
  /// The same for every entry in one result, so it never reorders anything —
  /// it lowers the whole list together, which is the honest response to a
  /// board that moved in a way nothing on the table can explain: a nudged
  /// checker, a hand still in shot, a play by the wrong player, a misread.
  final double instability;

  /// Regions this candidate's expected delta touches that **this board has
  /// no such region for**, so nothing in the picture could confirm them.
  ///
  /// In practice always a bear-off tray, and in practice always a folding
  /// case: such a board has no wells, and a checker borne off it leaves the
  /// board altogether. The play is then identified by count-by-absence — the
  /// point that lost a man — and this field is how the caller knows the
  /// confirming half of the evidence was never available.
  final List<RoiId> unobservable;

  PlayMatch({
    required this.play,
    required this.after,
    required this.confidence,
    required this.cost,
    required this.instability,
    required List<Move> tiedWith,
    required List<RoiId> unobservable,
  })  : tiedWith = List<Move>.unmodifiable(tiedWith),
        unobservable = List<RoiId>.unmodifiable(unobservable);

  /// Whether another candidate reaches exactly the same position.
  bool get isAmbiguous => tiedWith.isNotEmpty;

  /// Whether this candidate fits well enough to be offered as an answer at
  /// all. See [PlayMatcher.minConfidence].
  bool get plausible => confidence >= PlayMatcher.minConfidence;

  @override
  String toString() => '$play @${confidence.toStringAsFixed(3)}'
      '${isAmbiguous ? ' (tied with ${tiedWith.join(", ")})' : ''}';
}

/// Which of the enumerated legal plays happened, from the change between two
/// settled frames.
///
/// ## Why this is a difference and not a reading
///
/// The obvious shape for this query is: read the board now, compare it with the
/// position each candidate would produce, take the best. Phase 1 measured why
/// that is the wrong instrument. On the real corpus, per-region colour comes
/// back at 0.954 and colour-with-count at 0.784, and the counting misses are
/// not scattered — a tall stack on the far half reads short, and it reads short
/// in **every frame of the same session**, because what makes it short is the
/// seat the phone is in. An absolute comparison pays that bias in full on every
/// region of every candidate. A difference between two frames of one session
/// does not pay it at all: the bias is subtracted from itself.
///
/// So this class holds two frames, reads every region of both, and scores each
/// candidate on **signed per-region deltas** — how many White and how many
/// Black each region gained or lost — plus the colour transitions those deltas
/// imply. What a candidate claims about a region it does not touch is nothing,
/// and what the board did on a region **no** candidate touches is
/// [PlayMatch.instability]: it cannot reorder the candidates, and it lowers all
/// of their confidences together, because a change nothing on the table can
/// explain is a reason to doubt the whole answer rather than any part of it.
///
/// ## Hits route through the bar
///
/// A hit is the one play whose delta touches three regions: the point the man
/// left, the point it landed on — where the **colour flips**, from the
/// opponent's to the mover's — and the bar the blot is now standing on. All
/// three are scored, and they are not scored equally: the bar's own reading is
/// the weakest in the pipeline for a single checker (Task 6's real corpus found
/// the object on a worn hinge and could not name its colour), so it carries
/// [barWeight] against a point's 1.0, while the landing point's colour flip is
/// asked for explicitly through [colourWeight] on top of the counts. Evidence
/// that is reliable decides; evidence that is corroborating corroborates.
///
/// ## Doubles, and why transits are invisible
///
/// Up to four hops, and between two settled frames only the NET change is
/// observable — nobody photographs the intermediate positions. That falls out
/// of the design rather than needing handling: expected deltas are computed
/// from `before.applyMove(mover, play)`, which is the net position, so a play
/// that passes through a point and leaves it again claims nothing about it.
/// It is also the reason two plays reaching the same board are returned tied
/// (see [match]).
///
/// ## Every threshold here is provisional
///
/// The weights and the two falloffs were measured on the synthetic bed at the
/// corpus's own grade and checked against the real corpus's six consecutive
/// windows (`corpus_harness_test.dart`). They are named constants on this class
/// rather than in `targets.dart` on purpose: `targets.dart` holds promises made
/// to the user, and these are knobs the next measurement moves. See
/// [PerceptionTargets] for that distinction spelled out.
class PlayMatcher {
  /// The board this is reading, and the colours it learned.
  final BoardCalibration calibration;

  /// What the frame **before** the play showed, per region.
  final Map<RoiId, RegionReading> before;

  /// What the frame after it showed, per region.
  final Map<RoiId, RegionReading> after;

  /// What a point's delta is worth. The unit the other weights are fractions
  /// of: a point is a narrow column with one queue of checkers in it, which is
  /// the region shape the whole sampler was built around.
  static const double pointWeight = 1.0;

  /// What the bar's delta is worth, against a point's.
  ///
  /// Deliberately low, and the reason is measured rather than cautious. The bar
  /// is the one region whose bare appearance calibration can never learn from
  /// the men standing on it (there are none at the start of a game), it holds
  /// both colours at once stacked in opposite directions, and on the first real
  /// board it is a worn hinge ridge that reads like checkers all by itself.
  /// Task 6's flagship shot found a genuine checker there and returned
  /// `none` for its colour. A hit must therefore not depend on the bar being
  /// read correctly — it depends on the landing point, and the bar agrees or
  /// stays quiet.
  static const double barWeight = 0.35;

  /// What a bear-off tray's delta is worth. Between the two: a tray is a wide,
  /// long region whose checkers lie in a loose pile rather than a queue, so its
  /// count is softer than a point's, but calibration does measure it bare.
  static const double trayWeight = 0.5;

  /// What a promised colour change is worth when it did not happen.
  ///
  /// The strongest single term, and the strongest single piece of evidence: on
  /// the real corpus a region's colour comes back right 0.954 of the time
  /// against 0.784 for its colour and count together. A candidate that says
  /// "this point is now White" is making the claim the pipeline is best at
  /// checking, and a candidate whose claim fails it should lose to one whose
  /// does not, even when their counts disagree by the same amount.
  static const double colourWeight = 1.5;

  /// The least a region's reading is allowed to count for, however little the
  /// occupancy reader trusts it.
  ///
  /// Regions weigh in proportional to how much both frames' readings are worth
  /// there, so a stack the reader is unsure of does not get to decide the
  /// answer. Without a floor that becomes a hole: a candidate could hide its
  /// whole disagreement on the one region nobody trusts and pay nothing for it.
  static const double minEvidence = 0.25;

  /// How much disagreement a candidate may carry before its confidence halves,
  /// give or take — the scale of the [PlayMatch.cost] falloff.
  ///
  /// One unit of cost is one whole checker misplaced on a fully trusted point.
  /// Measured on the synthetic bed at corpus grade, the play that actually
  /// happened comes back at a cost under 0.5 on the great majority of turns,
  /// and the nearest rival that is a genuinely different play costs at least
  /// two — a moved checker is worth two units on its own, one at each end.
  static const double noiseTolerance = 2.0;

  /// The same, for change on regions no candidate claims. Looser, because this
  /// is diffuse: a session's frames differ a little everywhere, and a board
  /// that murmurs is not a board that has been tampered with. A whole checker
  /// appearing where nothing should have moved costs about a quarter of the
  /// confidence; five of them cost most of it.
  static const double stabilityTolerance = 6.0;

  /// The floor under "this is one of the plays you listed".
  ///
  /// Below it the session does not prompt with a candidate at all — it goes to
  /// drift recovery, because the honest reading of a diff that fits nothing is
  /// that the board and the game state have come apart. **The "none of these"
  /// answer is the point of this constant**, and it is why the matcher returns
  /// its whole ranked list rather than a best guess: a matcher that always
  /// names a winner has silently deleted the one answer that keeps the game
  /// state honest.
  ///
  /// ## What it does NOT do, measured
  ///
  /// It does not separate the right play from the runners-up, and no threshold
  /// could. On the synthetic bed at corpus grade the play that happened comes
  /// back at 1.000 every time, but the best rival — a legal play differing by
  /// one hop, scored on regions the reader was unsure of — reaches **0.562**,
  /// and on the real corpus the worst correct answer of the six is **0.542**.
  /// Those two bands overlap, so telling two legal plays apart is the
  /// ranking's job, not this number's.
  ///
  /// What it separates is diffs no legal play produced at all, and there the
  /// gap is real: on the same bed a checker moved backwards scores 0.243, the
  /// wrong player's move 0.162, and a board nobody touched 0.217. Half of that
  /// gap is where this sits.
  static const double minConfidence = 0.5;

  final Set<RoiId> _observable;

  PlayMatcher(
    this.calibration, {
    required Frame beforeFrame,
    required Frame afterFrame,
  })  : before = _readFrame(calibration, beforeFrame),
        after = _readFrame(calibration, afterFrame),
        _observable = <RoiId>{
          for (final id in calibration.atlas.regions)
            if (id != RoiId.diceZone) id,
        };

  /// Every region a play can move a checker into or out of, whether or not a
  /// particular board has one.
  ///
  /// The trays are here even on a folding case, which has none: a bear-off
  /// still *expects* a tray to gain a checker, and the difference between "the
  /// tray disagrees" and "this board has no tray" is exactly what
  /// [PlayMatch.unobservable] carries.
  static final List<RoiId> allRegions = List<RoiId>.unmodifiable(<RoiId>[
    for (var i = 0; i < 24; i++) RoiId.point(i),
    RoiId.bar,
    RoiId.offWhite,
    RoiId.offBlack,
  ]);

  /// Scores every play in [legalPlays] against the change between the two
  /// frames, best fit first.
  ///
  /// [before] is the authoritative position the game says the board was in, and
  /// [mover] is whose turn it was; between them they say what each candidate
  /// would have left behind, hits included.
  ///
  /// ## What comes back
  ///
  /// Every candidate, ranked — not just the good ones. The session's
  /// disambiguation prompt is drawn from the top of this list and the drift
  /// path needs to see what the runners-up were, so nothing is filtered out
  /// here. Read [PlayMatch.plausible] before reading [PlayMatch.play]: a list
  /// in which nothing is plausible is the "none of these" answer, and it is a
  /// first-class one.
  ///
  /// ## Ties are kept as ties
  ///
  /// Two plays that reach the same position are **indistinguishable by
  /// construction** — the difference between two frames is a difference between
  /// two positions, and theirs is the same position. Both come back, at exactly
  /// the same confidence, each naming the other in [PlayMatch.tiedWith]. The
  /// caller disambiguates (the spec's on-screen candidate prompt); picking one
  /// here would be inventing a fact about which route a checker took, which no
  /// camera watching two settled frames can know.
  ///
  /// Note that `MoveGenerator.legalMoves` already dedupes by resulting
  /// position, so a list from that door has no ties in it at all. They arrive
  /// from `legalVariants`' decompositions — the door a session takes when it
  /// wants to name the transit a user's hand actually used.
  ///
  /// Plays that differ only in the ORDER their hops are listed in are the same
  /// play written twice, not a tie, and are folded before scoring
  /// (`Move.sameAs`, which is order-insensitive by construction).
  ///
  /// ## A dance
  ///
  /// An empty [legalPlays] is the rules engine saying the mover has no play at
  /// all. There is nothing to identify, so this answers with the empty list and
  /// the session announces the dance and passes the turn, exactly as the
  /// digital game does. A caller that wants "did nothing happen?" answered from
  /// the frames puts `Move.none` in the list instead.
  List<PlayMatch> match(
    BoardState before,
    Player mover,
    List<Move> legalPlays,
  ) {
    if (legalPlays.isEmpty) return const <PlayMatch>[];

    final candidates = _distinct(legalPlays);
    final was = _countsOf(before);
    final becomes = <Map<RoiId, (int, int)>>[];
    final afters = <BoardState>[];
    for (final play in candidates) {
      final after = before.applyMove(mover, play);
      afters.add(after);
      becomes.add(_countsOf(after));
    }

    // Which regions ANY candidate claims. Scoring every candidate over the same
    // set is what makes them comparable: a candidate that touches fewer regions
    // must still answer for the ones it says nothing about, or a play that
    // barely moves would win every time the board was noisy.
    final touched = <RoiId>{
      for (final id in allRegions)
        if (becomes.any((counts) => counts[id] != was[id])) id,
    };

    // Everything else is the stability check.
    var instability = 0.0;
    for (final id in _observable) {
      if (touched.contains(id)) continue;
      final (dWhite, dBlack) = _observedDelta(id);
      instability +=
          _weightOf(id) * _evidenceAt(id) * (dWhite.abs() + dBlack.abs());
    }
    final stability = math.exp(-instability / stabilityTolerance);

    final scored = <(int index, double cost, List<RoiId> unobservable)>[];
    for (var i = 0; i < candidates.length; i++) {
      var cost = 0.0;
      final unobservable = <RoiId>[];
      for (final id in touched) {
        final expected = becomes[i][id]!;
        final wasHere = was[id]!;
        if (!_observable.contains(id)) {
          // This board has no such region. A candidate that wanted it to change
          // says so; one that did not is neither helped nor hurt.
          if (expected != wasHere) unobservable.add(id);
          continue;
        }
        final weight = _weightOf(id) * _evidenceAt(id);
        final (oWhite, oBlack) = _observedDelta(id);
        cost += weight *
            (((oWhite - (expected.$1 - wasHere.$1)).abs()) +
                ((oBlack - (expected.$2 - wasHere.$2)).abs()));

        // The colour a region turns, which is the pipeline's strongest signal.
        // Skipped on the bar, which holds both colours at once and has no
        // single colour to turn.
        if (id == RoiId.bar) continue;
        final becomesColour = _colourOf(expected);
        if (_colourOf(wasHere) != becomesColour &&
            after[id]!.colour != becomesColour) {
          cost += colourWeight * _evidenceAt(id);
        }
      }
      scored.add((i, cost, unobservable));
    }

    // Plays reaching the same position are one observation with several names.
    final byPosition = <BoardState, List<int>>{};
    for (var i = 0; i < afters.length; i++) {
      (byPosition[afters[i]] ??= <int>[]).add(i);
    }

    final matches = <PlayMatch>[
      for (final (index, cost, unobservable) in scored)
        PlayMatch(
          play: candidates[index],
          after: afters[index],
          confidence: math.exp(-cost / noiseTolerance) * stability,
          cost: cost,
          instability: instability,
          tiedWith: <Move>[
            for (final other in byPosition[afters[index]]!)
              if (other != index) candidates[other],
          ],
          unobservable: unobservable,
        ),
    ];
    // Sorted by fit, and by candidate order under a tie — `List.sort` is not
    // stable, and two indistinguishable plays coming back in a different order
    // on different runs would make the session's prompt flicker.
    final order = <PlayMatch, int>{
      for (final (i, m) in matches.indexed) m: i,
    };
    matches.sort((a, b) {
      final byFit = b.confidence.compareTo(a.confidence);
      return byFit != 0 ? byFit : order[a]!.compareTo(order[b]!);
    });
    return List<PlayMatch>.unmodifiable(matches);
  }

  /// The signed change [region] showed between the two frames, per colour.
  (int white, int black) _observedDelta(RoiId region) => (
        after[region]!.white - before[region]!.white,
        after[region]!.black - before[region]!.black,
      );

  /// How much [region]'s pair of readings is worth, floored at [minEvidence].
  ///
  /// The weaker of the two frames, not their average: a delta is only as good
  /// as the poorer end of it, and a region the reader trusted in one frame and
  /// not in the other is exactly a region whose difference means little.
  double _evidenceAt(RoiId region) => math
      .min(before[region]!.confidence, after[region]!.confidence)
      .clamp(minEvidence, 1.0);

  static double _weightOf(RoiId region) => switch (region) {
        RoiId.bar => barWeight,
        RoiId.offWhite || RoiId.offBlack => trayWeight,
        _ => pointWeight,
      };

  static CheckerColor _colourOf((int white, int black) counts) =>
      counts.$1 > 0
          ? CheckerColor.white
          : counts.$2 > 0
              ? CheckerColor.black
              : CheckerColor.none;

  /// [board] as per-region checker counts, over every region a play can reach.
  static Map<RoiId, (int white, int black)> _countsOf(BoardState board) =>
      <RoiId, (int, int)>{
        for (var i = 0; i < 24; i++)
          RoiId.point(i): (
            board.points[i] > 0 ? board.points[i] : 0,
            board.points[i] < 0 ? -board.points[i] : 0,
          ),
        RoiId.bar: (board.whiteBar, board.blackBar),
        RoiId.offWhite: (board.whiteOff, 0),
        RoiId.offBlack: (0, board.blackOff),
      };

  /// [plays] with re-orderings of the same hops folded together.
  ///
  /// Quadratic in a list that is a few hundred entries at its very worst, on
  /// a comparison that is one integer in the normal case ([Move.hopSetKey]).
  static List<Move> _distinct(List<Move> plays) {
    final out = <Move>[];
    for (final play in plays) {
      if (out.any((kept) => kept.sameAs(play))) continue;
      out.add(play);
    }
    return out;
  }

  /// Every region of one frame, read once.
  ///
  /// The reader takes its colours from `calibration.colorsIn(frame)`, so each
  /// side of the difference is measured in its own light — which is not a
  /// nicety: a live preview's auto-exposure drifts between two frames of the
  /// same scene by enough to turn empty points into phantom checkers, and a
  /// phantom on one side of a subtraction is a play that never happened.
  static Map<RoiId, RegionReading> _readFrame(
    BoardCalibration calibration,
    Frame frame,
  ) {
    final reader = OccupancyReader(calibration, frame);
    final out = <RoiId, RegionReading>{};
    for (final id in calibration.atlas.regions) {
      if (id == RoiId.diceZone) continue;
      if (id == RoiId.bar) {
        // Both colours, separately: the bar's two stacks grow away from each
        // other and every hit puts a checker on one of them.
        final white = reader.readFor(id, CheckerColor.white);
        final black = reader.readFor(id, CheckerColor.black);
        out[id] = RegionReading(
          white: white.count,
          black: black.count,
          colour: white.count >= black.count
              ? (white.count > 0 ? CheckerColor.white : CheckerColor.none)
              : CheckerColor.black,
          confidence: math.min(white.confidence, black.confidence),
        );
        continue;
      }
      final reading = reader.read(id);
      out[id] = RegionReading(
        white: reading.color == CheckerColor.white ? reading.count : 0,
        black: reading.color == CheckerColor.black ? reading.count : 0,
        colour: reading.color,
        confidence: reading.confidence,
      );
    }
    return out;
  }
}

/// What one region held in one frame, in the form a difference needs it.
///
/// [RegionOccupancy] answers "what is on this region", which is one colour and
/// a count. A difference wants both colours at once — the bar holds two, and a
/// point that changes hands loses one colour and gains the other in the same
/// step — so the reading is unpacked into a count per colour here, with the
/// dominant colour kept alongside for the colour-transition evidence.
class RegionReading {
  final int white;
  final int black;

  /// Whichever colour the frame read there, or [CheckerColor.none].
  final CheckerColor colour;

  /// What the occupancy reader thought this reading was worth. On the bar, the
  /// weaker of the two colours' readings.
  final double confidence;

  const RegionReading({
    required this.white,
    required this.black,
    required this.colour,
    required this.confidence,
  });

  @override
  String toString() => '${colour.name} (w$white b$black) '
      '@${confidence.toStringAsFixed(2)}';
}
