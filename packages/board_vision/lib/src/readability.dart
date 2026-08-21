import 'dart:math' as math;

import 'calibration.dart';
import 'color_model.dart';
import 'frame.dart';
import 'geometry_types.dart';
import 'roi_atlas.dart';
import 'roi_sampler.dart';

/// The three states of the light over the preview.
///
/// The line between them is what the session can DO about the frame, not how
/// bad it looks:
///
/// * [green] — answer the question;
/// * [amber] — do not answer, and wait: the cause clears on its own (a hand
///   lifts, a phone settles, focus catches up);
/// * [red] — do not answer, and say so: somebody has to change something
///   before it will clear.
///
/// Answers are suppressed for both [amber] and [red] — see
/// [Readability.answersSuppressed]. The difference is what the session says and
/// whether it says it at all: the spec speaks the transition to red once, and a
/// hand crossing the board several times a turn is not something to speak
/// about.
enum ReadabilityLevel { green, amber, red }

/// Why the light is not green.
///
/// Every one of these is a sentence a person can act on, which is the point of
/// naming them at all: "I can't see the board", "the phone moved", "too dark".
/// The module decides which one is true and says so; how it is said, when, and
/// what happens next belong to the session.
enum ReadabilityCause {
  /// Part of the playing field is outside the picture this frame came in.
  ///
  /// **In practice this is a programming error rather than something a user
  /// did**, and the message that goes with it is written accordingly. The
  /// geometry is fixed at calibration and does not move when the phone does —
  /// see [ReadabilityMonitor._boardIsInFrame] — so the only thing that can
  /// take the calibrated outline outside the picture is a preview handed over
  /// at a different size or crop from the one the session calibrated on. A
  /// user cannot fix that by moving the camera, and telling them to would be
  /// worse than saying nothing. So the sentence names the frame rather than
  /// the aim, and a session that shows it is looking at a bug in its own
  /// plumbing.
  boardOutOfFrame,

  /// The board is no longer where — or no longer looks like what — it was
  /// calibrated as. The one cause that carries
  /// [Readability.requiresRecalibration].
  calibrationStale,

  /// The phone is moving. From the gyro, not from the picture.
  motion,

  /// The picture has lost the fine detail the board was calibrated with.
  blur,

  /// Too little light for the colour model to be re-normalized onto.
  tooDark,

  /// So much light that the board's colours are running into each other at the
  /// top of the sensor's range.
  ///
  /// **Not in the plan's list of six, and added deliberately.** Task 3 left a
  /// note on `CalibrationFingerprint.clippedFraction` saying in as many words
  /// that it is "the readability cause Task 9 has to raise, and this is the
  /// number that raises it" — and the plan's vocabulary had nowhere for it to
  /// go. Folding it into [tooDark] would have the light tell a user staring at
  /// a board under a desk lamp that the room is too dark, which is worse than
  /// having a seventh name.
  tooBright,

  /// Something that is not the board is lying on a part of it.
  occluded,
}

/// What the gyro says about the phone, injected rather than measured here.
///
/// `board_vision` never touches a sensor: the app owns `sensors_plus` exactly
/// as it owns the camera, and hands the answer over. One bit is all this needs
/// — the frame gate upstream is already deciding "settled or not" from gyro
/// history and an inter-frame difference, and a readability check does not
/// improve on that by re-deriving it.
class MotionHint {
  /// Whether the phone was still over the window this frame came from.
  final bool deviceStill;

  const MotionHint({required this.deviceStill});

  /// The hint a desktop test bed gives: a phone on a stand, going nowhere.
  static const MotionHint still = MotionHint(deviceStill: true);

  /// A phone being picked up, put down, or knocked.
  static const MotionHint moving = MotionHint(deviceStill: false);

  @override
  String toString() => 'MotionHint(${deviceStill ? 'still' : 'moving'})';
}

/// What one stable frame is worth: a level, a named cause, and the one bit the
/// session routes on.
class Readability {
  final ReadabilityLevel level;

  /// Why, or null when [level] is [ReadabilityLevel.green].
  final ReadabilityCause? cause;

  /// Whether this cause has invalidated the calibration itself — the board
  /// moved, or its colours are no longer the ones that were learned — so that
  /// the session has to route to the recalibration flow rather than wait.
  ///
  /// **False for everything transient**, and the spec is explicit about which
  /// those are: a hand over the board and brief motion must never send a user
  /// to re-drag corners. It is also false for every cause that leaves the
  /// question unanswerable rather than answered — a frame too dark or too small
  /// to show the board cannot say whether the calibration is still true, so the
  /// verdict waits for a frame that can.
  final bool requiresRecalibration;

  /// A sentence for the readability indicator, written to be shown as it
  /// stands — the same contract `CalibrationResult.message` has.
  final String message;

  const Readability._({
    required this.level,
    this.cause,
    this.requiresRecalibration = false,
    required this.message,
  });

  /// Whether perception answers are to be withheld on this frame.
  ///
  /// Anything but green. A frame that cannot be trusted is a frame no answer
  /// should be taken from, and the difference between amber and red is about
  /// what the user is told, not about what perception is allowed to claim.
  bool get answersSuppressed => level != ReadabilityLevel.green;

  @override
  String toString() => cause == null
      ? 'Readability(green)'
      : 'Readability(${level.name}: ${cause!.name}'
          '${requiresRecalibration ? ', recalibrate' : ''})';
}

/// The session-long contract, checked on every stable frame.
///
/// ## What the spec asks for
///
/// > Calibration is a session-long contract, continuously re-validated — not a
/// > one-time gate. Every stable frame throughout the session runs cheap
/// > validity checks [...] regardless of whether a query is pending, so that
/// > degraded conditions are caught the moment they happen.
///
/// So this runs on frames nobody asked a question about, all game, and it has
/// to be cheap enough that doing so is free.
///
/// ## What it costs
///
/// **Under a hundredth of the picture**, and the number is pinned to the digit
/// rather than claimed here: `readability_test.dart` hands the check a frame
/// that counts its own reads and asserts the exact total. On the bed's
/// 1280x960 frames — 1,228,800 pixels — one assessment of a plain board reads
/// **7,812** of them, 0.64%, in four places:
///
/// | what | places | reads each | total |
/// |---|---|---|---|
/// | the interior lattice (light, cast, clipping) | 576 | 1 | 576 |
/// | sharpness | 144 | 45 | 6,480 |
/// | the corner patches (and four more on a folding case) | 36 cells | 9 | 324 |
/// | the occlusion lattice | 27 regions x 16 | 1 | 432 |
///
/// Sharpness is five sixths of that and is the one worth watching if the cost
/// ever has to come down: it is a coarse lattice already, and what each place
/// costs is five blocks of nine.
///
/// **A folding case costs 8,104, which is 292 more rather than the 324 the
/// third row would suggest**, and the difference is not an error in either
/// number: a folding board has no bear-off wells, so it has 26 regions where a
/// cased one has 28, and the two the occlusion walk does not make gives back
/// 32 reads of the seams' 324. Both numbers are measured and both are pinned.
///
/// Nothing here re-reads the board: no stack is walked, no checker is found,
/// no region is classified as a whole. That is the difference between a check
/// that can run on every frame and one that cannot.
///
/// ## The order the checks run in, which is not arbitrary
///
/// Each one can be fooled by the conditions the ones above it name, so the
/// cheapest and most independent go first and the most interpretive last:
///
/// 1. **the gyro.** Free, and it settles the frame on its own: a moving phone
///    cannot produce a readable picture and no amount of measuring will change
///    that answer.
/// 2. **the board in the picture.** Nothing else means anything if the frame
///    cannot contain the board the geometry describes.
/// 3. **the light.** Measured against what the board can be re-normalized
///    from, in both directions.
/// 4. **sharpness.** A frame soft enough to matter smears the patches the next
///    check reads.
/// 5. **the geometry**, from the fingerprint's patches — and only asserted as
///    [ReadabilityCause.calibrationStale] while the light is still comparable.
///    A patch comparison is an APPEARANCE comparison: measured on the bed at
///    0.46 of the calibration light, with nothing whatever moved, the patches
///    drift past their bound (see [minExposureRatio] for why that happens as
///    early as it does, and what it costs). Naming the geometry there would
///    send a user whose board is exactly where they left it to re-drag its
///    corners, which is the one thing the spec asks this module not to do for
///    a cause that clears on its own.
/// 6. **occlusion** — it asks the colour model what it does not recognize, and
///    a board that has moved also puts unrecognizable things in every region.
///    The geometry check above has already spoken by then, so a board that slid
///    is named as one.
/// 7. **the light's colour**, last of all. The spec names two ways a
///    calibration dies — "geometry moved, colors no longer match" — and this is
///    the second. It is asked after occlusion because the cast is a board-WIDE
///    statistic and anything large enough to change the board's average colour
///    moves it: measured on the blue-red palette, a skin-coloured arm across
///    the far edge takes the cast to 0.128 and 0.138 against a bound of 0.12,
///    with nothing changed but what is lying on the felt. Asked before
///    occlusion, that frame would send a user with an arm over their board to
///    re-drag its corners.
///
/// ## What the ordering actually costs, measured rather than reasoned
///
/// Swept over 28 occluder sizes on all three palettes — bands lying along the
/// middle of the board, seven widths from a third of it to the whole of it
/// (0.333, 0.45, 0.6, 0.7, 0.8, 0.9, 1.0) by four heights from a sixth of it
/// to a half (0.167, 0.2, 0.333, 0.5) — **18 of the 84 come back
/// `calibrationStale`, and every one of them is on the blue-red palette.**
/// All eighteen arrive through check 7 rather than check 5: `geometryMatches`
/// is true on every one of them and `castMatches` is false, which is a
/// skin-coloured object on a blue board moving the board's average colour far
/// enough to look like a lamp that changed. They are the wide bands, and the
/// taller the band the narrower it needs to be — 0.7 across and wider at a
/// sixth of the height, 0.6 and wider at a fifth, 0.45 and wider at a third,
/// and at half the height everything from a third of the board up, until the
/// widest four tip over into `tooBright` instead. One of the eighteen is
/// pinned in `readability_test.dart` as the deliberate cost of leaving the
/// dice band out of the occlusion walk. The other two palettes never reach
/// check 7 at all: the classic board is green on 26 of its 28 and `tooBright`
/// on the two widest half-height bands, and the low-contrast wood board is
/// green on all 28.
///
/// **This paragraph said `calibrationStale` "never came back once" until the
/// cast check was added underneath it and nobody re-ran the sweep.** That
/// sentence was true of the check as it stood and false of the same commit
/// that shipped its replacement. What happens on the sixty-six cells that are
/// not stale is three things, and each is the ordering working rather than
/// failing:
///
/// * **a near-total cover reads `blur`.** A flat fill has no edges in it, so
///   the sharpness ratio collapses long before the geometry is reached: an
///   ellipse 0.9 of the board across leaves 0.029, 0.021 and 0.087 of the
///   calibration frame's contrast on the three palettes, against a bound of
///   0.23, and check 4 speaks first on all three.
/// * **a large pale one reads `tooBright`.** Not from clipping — a skin-toned
///   fill clips nothing — but because it lifts the board's own mean luma past
///   `CalibrationFingerprint.maxExposureRatio`: a band over half the board
///   measures 1.381 and 1.507 of the calibration light on the classic and
///   blue-red palettes against a bound of 1.3, the patches go with it, and the
///   geometry check's light fallback names the light rather than the geometry.
/// * **and a hand over one or two corners falls through to the occlusion
///   check — which on two of the three palettes then finds nothing, and the
///   frame reads GREEN.** `geometryMatches` needs more than half the patches
///   moved, and an arm across the far edge moves two of four. Colour is the
///   only instrument left after that, and on the classic and wood palettes an
///   arm across a corner covers no single region enough to be counted. That is
///   the honest cost: not a misnamed recalibration, an unnamed occlusion.
///
/// Every one of the three is pinned in `readability_test.dart`, including the
/// green, so that none of them can quietly become another.
///
/// ## Past a strong enough cast the routing bit inverts, and it is recorded
/// rather than fixed
///
/// Check 7 catches a lamp swapped for a warmer one — but only over a band of
/// strengths, and above that band the LIGHT checks win instead. Measured on
/// the bed at a fortieth of a full 2700 K shift at a time, as the fraction of
/// that shift the camera's white balance failed to take out:
///
/// | palette | routes to recalibration | and above that | why |
/// |---|---|---|---|
/// | classic | 0.175–0.250 | `tooBright` from 0.275 | the warm cast pushes pale points and white checkers past 255, clipping goes 0.030 to 0.094, and check 3 speaks before the geometry is reached |
/// | blue-red | 0.100–0.425 | `tooDark` from 0.450, `tooBright` from 0.650 | the cast moves the patches too, `geometryMatches` gives out, and its light fallback names the luma ratio — about 0.95, so "dark" — until the cast itself clips and check 3 takes over |
/// | low-contrast wood | 0.175–0.425 | `tooBright` from 0.450 | the same fallback, with a luma ratio of 1.03 |
///
/// The last two rows are the same mechanism as the second bullet above:
/// [CalibrationFingerprint.exposureMatches] consults the cast, so a frame
/// whose colour has moved fails it whatever its brightness is — and the
/// fallback then names `tooDark` or `tooBright` on the luma ratio alone. So
/// the canonical case, a lamp swapped outright with no white balance at all,
/// reads red, `tooBright` and [Readability.requiresRecalibration] **false** on
/// all three palettes, with `confirmStartingPosition` misreading eight regions
/// on each of them — and between four and sixteen anywhere in the inverted
/// band. The user is told to dim a light that is not too bright.
///
/// **And dimming does not walk them out of it**, which is the part worth
/// saying plainly: measured on all three palettes under a full tungsten cast,
/// turning the light down in tenths reads `tooBright` twice on blue-red and
/// wood (`tooDark` from 0.8 of the light) and three times on classic
/// (`tooDark` from 0.7), and stays red all the way to a third of the
/// calibration light. The cast has
/// moved the luma-normalized patches, so `geometryMatches` is false at every
/// level and the fallback speaks every time. What the user gets is a red light
/// with the wrong sentence under it until they recalibrate by hand.
///
/// **It is left alone because the obvious fix measured worse.** That fix is to
/// ask [CalibrationFingerprint.castMatches] inside the too-dark and too-bright
/// branches and name `calibrationStale` when the colour is out as well — but
/// clipping moves the measured cast on its own, with no change of colour
/// whatever. Brightened under a NEUTRAL lamp the wood board's red ratio drifts
/// 0.009 at 1.3 of its calibration light, 0.020 at 1.4, 0.054 at 1.6 and
/// **0.162 at 2.0**, past [CalibrationFingerprint.maxCastDrift]'s 0.12,
/// because the red channel saturates first and a ratio taken over saturated
/// pixels is not the light's. That fix would send a user with a blazing lamp
/// and a perfectly good calibration to re-drag four corners, which is the one
/// thing this module must not do. A real fix has to tell "the cast moved
/// because the colours moved" from "the cast moved because the sensor clipped"
/// — nothing measured here does that yet.
///
/// So the failure is safe rather than harmless: red, answers suppressed, no
/// phantom state written, and a sentence that sends the user the wrong way.
/// Both ends are pinned in `readability_test.dart` — the last strength that
/// still routes to recalibration, the first that does not, and a full lamp
/// swap reading `tooBright` — so the regime cannot change without somebody
/// rewriting this.
///
/// ## Numbers, provisionally
///
/// Every bound below was measured, and each says against what. The synthetic
/// bed can produce six of the seven causes — [ReadabilityCause.motion] is
/// injected rather than drawn — and `readability_test.dart` produces each of
/// them. It can also, since Task 9's review, produce a change of light COLOUR
/// as against a change of level: see `LightCast` in the renderer, which is what
/// the "colors no longer match" half of a stale calibration is measured
/// against.
///
/// The real corpus was filmed under one fixed light with hands clear, so it
/// can only show that the check stays quiet on good frames. It does, on eight
/// of its ten; the other two are its end-game keyframes, which come back
/// `calibrationStale`, and whether that is a board that really moved is
/// argued out in `corpus_harness_test.dart`'s `kRealCorpusFloors`. The
/// conditions this module exists to catch wait on acts 3 and 4 of the filming
/// plan — the light change and the sabotage — which are not shot.
class ReadabilityMonitor {
  /// The session's calibration — what every frame is judged against.
  final BoardCalibration calibration;

  const ReadabilityMonitor(this.calibration);

  /// How dim the board may get, as a fraction of the light it was calibrated
  /// under, before there is not enough left to re-normalize onto.
  ///
  /// **Measured against what still reads, not against what looks dark**, and
  /// the pipeline is far better at this than it feels: dimmed on the bed, all
  /// three palettes read their own starting position back correctly down to
  /// **0.172** of their calibration light, and the first misread arrives at
  /// **0.162**, on the classic palette, at four of its twenty-four points —
  /// the other two are still clean at 0.120. This sits in that gap.
  ///
  /// `ColorModel`'s own envelope says three tenths, and it is the conservative
  /// end of the same measurement — `CalibrationFingerprint.maxExposureRatio`
  /// records the same 0.3 for a different purpose (whether the SCENE changed,
  /// which is a tighter question than whether it can still be read). A
  /// readability light that went red at three tenths would suppress answers the
  /// pipeline is demonstrably still getting right.
  ///
  /// ## This is not the only place the light goes red, and the difference is
  /// physical
  ///
  /// The paragraph above was the whole of this doc until a reviewer measured
  /// the shipped behaviour and found the light going red at **about a half** —
  /// nearly three times earlier, through a path nothing here described. Both
  /// numbers are real, and which one a session meets depends on what dimmed:
  ///
  /// | what happened | classic | blue-red | wood | named by |
  /// |---|---|---|---|---|
  /// | the whole room dims, board and surround together | 0.17 → 0.16 | 0.19 → 0.16 | 0.17 → 0.16 | this bound |
  /// | only the light on the board drops | 0.48 → 0.47 | 0.51 → 0.50 | 0.39 → 0.38 | the geometry check's light fallback |
  ///
  /// Last green, then first red — in **commanded gain**, what the bed is asked
  /// for, swept a hundredth at a time, which is the quantity
  /// `readability_test.dart`'s brackets are written in. The exposure the
  /// fingerprint goes on to measure is within three thousandths of the
  /// commanded figure everywhere in the table, so the two can be read as one
  /// number; where the difference matters it is said.
  ///
  /// The top row's **first red** is the same commanded gain on all three
  /// palettes, and the exposures measured there — 0.162, 0.159 and 0.160
  /// against this bound's 0.17 — agree to within three thousandths, which is
  /// this bound doing exactly the job its first paragraph describes. The
  /// last-green column is looser on the blue-red board because a room that
  /// dark starts to trip the occlusion walk, which cannot recognize samples
  /// with nothing left in them: at 0.22, 0.21, 0.18 and 0.17 that palette
  /// steps through an amber `occluded` verdict — a wait rather than a verdict,
  /// and not even monotone, since 0.20 and 0.19 are green between them. The
  /// other two palettes go straight from green to red. All six cells are
  /// bracketed in `readability_test.dart` so this table cannot drift from
  /// behaviour again.
  ///
  /// **The second row is the corner patches, and it is a real signal rather
  /// than an artefact.** `CalibrationFingerprint.cornerOutside` reaches each
  /// patch a little way OUTSIDE the playing field on purpose — the board's own
  /// outline is what makes a corner informative — so five of every patch's
  /// nine cells see the table around the board. `geometryMatches` divides both
  /// sides by their own frame's mean board luma, which is exactly right for
  /// everything ON the board and exactly wrong for anything that did not dim
  /// with it: a surround at unchanged brightness over a board at 0.45 reads as
  /// 2.2 times its calibration value, the patch drifts past
  /// `maxPatchDrift`, and the light fallback names `tooDark`. Measured across
  /// all three palettes, the four cells of each patch that lie wholly on the
  /// playing field drift **0.009–0.014** at that same 0.45 and **0.034–0.058**
  /// at 0.17 — the board itself has not moved at all.
  ///
  /// **The obvious alternative — comparing those four cells and nothing else —
  /// was named and rejected, on two measurements.** It costs the check exactly
  /// the slides the outside ring is there to see: on the low-contrast wood
  /// palette a board slid fifteen pixels under a 1280-pixel frame fires in six
  /// of the eight directions on the whole patch and in two of them on the four
  /// inner cells, so four of the six go unnoticed — and two of them are still
  /// unnoticed at twenty pixels, which is the displacement `geometryMatches`
  /// is set to catch. It would also invalidate every figure
  /// `CalibrationFingerprint.maxPatchDrift` is derived from, all of which are
  /// whole-patch with the outside cells in, so the bound would have to be
  /// re-measured from nothing in order to buy a less sensitive check.
  ///
  /// So the check is telling the truth in both rows: *the board's brightness
  /// relative to the room it sits in has changed*, which is a different scene
  /// from the calibrated one even though the board is where it was. **The cost
  /// is admitted rather than argued away**: between the second row's boundary
  /// and this bound a session
  /// whose board alone went dark is told "it is too dark" while the pipeline
  /// would still have read every point correctly (measured: zero discrepancies
  /// at 0.45, 0.40, 0.35 and 0.30 on all three palettes). What it buys is that
  /// the same frames are never called a board that MOVED: the fallback names
  /// `tooDark`, which carries no [Readability.requiresRecalibration] and so
  /// costs the user a suppressed answer rather than a re-drag of four corners,
  /// and the next frame under restored light answers immediately.
  static const double minExposureRatio = 0.17;

  /// How much of the board may be pinned at the top of the sensor's range
  /// before the light is called too much.
  ///
  /// Deliberately `Calibrator.maxClippedFraction` rather than a number of its
  /// own: that is already this package's measured answer to "so much light
  /// that the colours are washing into each other", and two thresholds for one
  /// physical fact would drift apart.
  ///
  /// **It fires a step before reading actually breaks, and that is the right
  /// side to err on here.** Measured on the bed: the classic palette reads its
  /// start position correctly at 12% of itself clipped and misreads at 14%,
  /// the blue-red at 11% and 14%, and the low-contrast wood — whose checkers
  /// stay separable however hard it is lit — reads correctly at 45%. There is
  /// no bound that separates those cleanly, because which of a board's colours
  /// clips first is a fact about that board. Against that, going red early
  /// costs one suppressed answer that the next frame supplies, and going red
  /// late costs a phantom checker in the authoritative game state.
  static double get maxClippedFraction => Calibrator.maxClippedFraction;

  /// How much of the board's own fine detail may be lost before the picture is
  /// called blurred, as a fraction of what the calibration frame showed —
  /// each side divided by its own frame's light first, since edge contrast
  /// scales with the light that made it.
  ///
  /// Measured on the bed by blurring until the board stops COUNTING, rather
  /// than by eye. The ratio falls with sigma almost identically on all three
  /// palettes — 0.84 at one, 0.53 at two, 0.35 at three, 0.26 at four — and
  /// what differs is where each board's occupancy gives out: the classic
  /// palette misreads three of its twenty-four points at five sigma (0.202)
  /// having been clean at four (0.255), the blue-red holds to five and breaks
  /// at six (0.159), the low-contrast wood holds to six and breaks at eight
  /// (0.141).
  ///
  /// This is set from the first board to break rather than the last, so on the
  /// other two it goes amber a step or two before they would actually
  /// misread. That is the cheap error: blur is amber, the session waits one
  /// frame, and the alternative is a count taken from a picture that has
  /// stopped supporting it.
  static const double minSharpnessRatio = 0.23;

  /// How far a sample may be from everything the model knows, in the model's
  /// own spreads, before it is counted as something the board does not
  /// contain.
  ///
  /// Derived from `ColorModel`'s own measurement rather than chosen: genuine
  /// samples of things a board HAS sit "under 1 in every synthetic condition
  /// tested, and about 3.3 in the worst" — see [ColorModel.maxClassDistance],
  /// which is set at 6 for a different job, namely how far a sample may be and
  /// still be classified rather than declined. Past 4 spreads nothing the bed
  /// has ever drawn as part of a board has been measured.
  ///
  /// **Real photographs go much further, and that is why the rule under this
  /// one counts REGIONS rather than samples.** On the committed corpus the
  /// strangeness tail reaches 15 and even 29 spreads — rims, specular glints,
  /// the shadow under a checker — on frames where nothing is covering
  /// anything. Scattered strangeness is what a photograph looks like; a region
  /// more than half strange is what a hand looks like.
  static const double maxKnownDistance = 4.0;

  /// What share of a region's lattice has to be unrecognizable before that
  /// region counts as covered. Half: a thing that covers a region covers most
  /// of it, and a thing that speckles one is the photograph.
  static const double minCoveredShare = 0.5;

  /// How many regions have to be covered before the board is called occluded.
  ///
  /// One, and the measurement says one is enough because nothing else measured
  /// reaches even that. A hand over a quadrant covers one region on the classic
  /// palette and two on the blue-red; a clean frame, four sigma of blur, a room
  /// at three tenths of its light and a board with its men played all cover
  /// none, the worst region on any of them reaching 0.06 of itself. Across the
  /// ten real frames — which have no hands in them — the worst region reaches
  /// 0.31, still well short of half.
  ///
  /// **On `BoardPalette.lowContrastWood` a hand covers nothing, and that is the
  /// honest result rather than a bug.** Every surface of that board is in the
  /// wood family and a hand sits 1.8 spreads from its felt: a hand on a board
  /// the colour of a hand is not separable by colour, and nothing here pretends
  /// otherwise. What such a board loses is the amber; what it does not lose is
  /// any of the other five causes.
  static const int minCoveredRegions = 1;

  /// Lattice per side, per region, for the occlusion walk. Coarse on purpose:
  /// what is being asked is how much of a region is covered, which does not
  /// need resolution.
  static const int occlusionLattice = 4;

  /// How many places the board's outline is checked at, per edge.
  static const int outlineSteps = 10;

  /// What [frame] is worth, given what the gyro says about the phone.
  ///
  /// See the class doc for the order the checks run in and why. The answer
  /// names ONE cause even when several are true, and the one it names is the
  /// first that could have produced the others.
  Readability assess(Frame frame, MotionHint motion) {
    if (!motion.deviceStill) {
      return const Readability._(
        level: ReadabilityLevel.amber,
        cause: ReadabilityCause.motion,
        message: 'Hold still a moment — I lose the board while the phone is '
            'moving.',
      );
    }

    if (!_boardIsInFrame(frame)) {
      return const Readability._(
        level: ReadabilityLevel.red,
        cause: ReadabilityCause.boardOutOfFrame,
        // Not "line the camera up": a user cannot fix this by moving the
        // phone, because the outline that fell outside the picture is the
        // calibrated one and it does not move with the camera. See the doc on
        // [ReadabilityCause.boardOutOfFrame] — this sentence is for the one
        // frame a user might ever see it on, and it sends them to the only
        // action that works.
        message: 'The picture I am being given is not the one this board was '
            'set up on, so I cannot line anything up in it. Set the board up '
            'again from here.',
      );
    }

    final remembered = calibration.fingerprint;
    final now = CalibrationFingerprint.fromFrame(frame, calibration.geometry);
    final exposure = now.meanLuma / math.max(remembered.meanLuma, 1.0);

    if (exposure < minExposureRatio) return _tooDark;
    if (now.clippedFraction > maxClippedFraction) return _tooBright;

    // Divided by each frame's own light before they are compared. Edge
    // contrast scales with the light that made it, so a board at three tenths
    // of its calibration brightness has three tenths the laplacian with
    // nothing whatever out of focus — measured, and it read as blur until this
    // line was here.
    final contrastNow = now.sharpness / math.max(now.meanLuma, 1.0);
    final contrastThen =
        remembered.sharpness / math.max(remembered.meanLuma, 1.0);
    if (contrastThen > 0 && contrastNow < contrastThen * minSharpnessRatio) {
      return const Readability._(
        level: ReadabilityLevel.amber,
        cause: ReadabilityCause.blur,
        message: 'The picture is too soft to read the board from. Give the '
            'camera a moment to focus.',
      );
    }

    if (!remembered.geometryMatches(now)) {
      // See the class doc: the patches are appearance, so a light that has
      // moved past what the fingerprint calls the same scene can move them on
      // its own. Where both are true the light is the answer, because it is
      // the one that explains the other.
      if (!remembered.exposureMatches(now)) {
        return exposure < 1 ? _tooDark : _tooBright;
      }
      return const Readability._(
        level: ReadabilityLevel.red,
        cause: ReadabilityCause.calibrationStale,
        requiresRecalibration: true,
        message: 'The board is not where it was when I learned it. Line the '
            'corners up again and I will pick the game straight back up.',
      );
    }

    if (_coveredRegions(frame, exposure) >= minCoveredRegions) {
      return const Readability._(
        level: ReadabilityLevel.amber,
        cause: ReadabilityCause.occluded,
        message: 'Something is covering part of the board. I will carry on as '
            'soon as it is clear.',
      );
    }

    // The second way a calibration dies, and the spec names it in the same
    // breath as the first: "geometry moved, colors no longer match". Asked
    // LAST, and the reason is measured — see the class doc.
    if (!remembered.castMatches(now)) return _colourStale;

    return const Readability._(
      level: ReadabilityLevel.green,
      message: 'I can see the board.',
    );
  }

  /// The board is where it was and nothing is lying on it — but the light it
  /// is under is not the light its colours were learned from.
  ///
  /// Same cause and same routing as a board that moved, because it is the same
  /// event as far as the session is concerned: the calibration is dead and
  /// only a new one revives it. The sentence differs because what the user has
  /// to do differs — nobody can be told to put the old lamp back.
  static const Readability _colourStale = Readability._(
    level: ReadabilityLevel.red,
    cause: ReadabilityCause.calibrationStale,
    requiresRecalibration: true,
    message: 'The light on the board has changed colour, so the board no '
        'longer looks like the one I learned. Line the corners up again under '
        'this light and I will pick the game straight back up.',
  );

  static const Readability _tooDark = Readability._(
    level: ReadabilityLevel.red,
    cause: ReadabilityCause.tooDark,
    message: 'It is too dark to read the board. A little more light and I will '
        'carry on where we were.',
  );

  static const Readability _tooBright = Readability._(
    level: ReadabilityLevel.red,
    cause: ReadabilityCause.tooBright,
    message: 'There is so much light on the board that its colours are running '
        'into each other. Dim it, or move the phone so the lamp is not shining '
        'straight back at it.',
  );

  /// Whether the playing field's whole outline lands inside [frame].
  ///
  /// Walks the unit square's perimeter through the session's own geometry —
  /// forty projections and not a single pixel read. On a folding case that is
  /// the outline through three planes, which is why it is walked rather than
  /// reasoned about from four corners.
  ///
  /// **This is a check on the FRAME, not on where the board has got to.** The
  /// geometry is fixed at calibration, so a phone that moved does not move
  /// these projections — it changes what is under them, which is the
  /// fingerprint's business. What this catches is a picture that cannot hold
  /// the calibrated board at all: a preview handed over at a different size or
  /// crop from the one the session was calibrated on. Left unnamed it is
  /// silent rather than wrong, because [FrameSampler] clamps samples to the
  /// picture's border, and the geometry check would then be comparing patches
  /// of the border against patches of the board.
  ///
  /// The fingerprint's own patches reach a little further out than this — see
  /// [CalibrationFingerprint.cornerOutside] — so a board photographed flush
  /// against the picture's edge passes here and has its patches clamped. That
  /// is deliberate: the board is what has to be visible, and the margin is
  /// there to make a corner informative rather than to be measured.
  bool _boardIsInFrame(Frame frame) {
    for (var i = 0; i < outlineSteps; i++) {
      final t = i / outlineSteps;
      for (final point in <Pt>[
        Pt(t, 0),
        Pt(1, t),
        Pt(1 - t, 1),
        Pt(0, 1 - t),
      ]) {
        final p = calibration.geometry.imagePointOf(point);
        if (!p.x.isFinite || !p.y.isFinite) return false;
        if (p.x < 0 ||
            p.y < 0 ||
            p.x > frame.width - 1 ||
            p.y > frame.height - 1) {
          return false;
        }
      }
    }
    return true;
  }

  /// How many of the board's regions are more than [minCoveredShare] covered
  /// by something the colour model has never been shown.
  ///
  /// **The dice band is left out, and leaving it in would break the dice
  /// reader's own premise.** That band is modelled as felt and the bar's wood
  /// and nothing else, deliberately — `DiceReader` finds dice precisely by
  /// looking for what the band's surfaces do not account for. A die lying in
  /// it is therefore unrecognizable BY CONSTRUCTION, so whatever this walk
  /// counted there would be a count of dice rather than of hands.
  ///
  /// **The justification used to be that counting it "would call every roll a
  /// hand over the board", and that overstates the case fourfold.** Measured
  /// on the bed, a settled roll leaves 0.000, 0.125 and 0.000 of the band's
  /// lattice unrecognizable on the three palettes, against [minCoveredShare]'s
  /// 0.5 — nowhere near. What actually settles it is the other end: counting
  /// the band would not buy back the blindness it is blamed for. The one
  /// occluder this walk cannot see — the ellipse 0.60 of the board wide lying
  /// along the band, below — covers 0.000, **0.500** and 0.000 of that same
  /// lattice, and the rule is `strange > minCoveredShare * seen`, strictly
  /// greater. Exactly half is not more than half, so on the one palette where
  /// the thing lying there is strange at all the band would stay blind to the
  /// very frame that motivates counting it, while the walk had started reading
  /// the dice reader's signal as though it were an occlusion.
  ///
  /// **What that costs is a blind stripe across the middle of the board, and
  /// it is pinned rather than only explained.** An ellipse 0.60 of the board
  /// wide lying along the band — an arm laid across the bar, not a die —
  /// covers nothing this walk looks at, moves two of four corner patches at
  /// most, and comes back green: the session answers on it. Measured on the
  /// classic palette and asserted in `readability_test.dart`, so that a later
  /// idea which closes the blindness has to rewrite this paragraph rather than
  /// silently making it untrue. The one thing that does catch such a frame is
  /// the colour check at the end of [assess], and only on a board whose
  /// colours are far enough from the thing lying on it — see that test too.
  ///
  /// [exposure] is the light this frame is in, already measured, so the colour
  /// model is re-normalized without walking the board a second time for it.
  int _coveredRegions(Frame frame, double exposure) {
    final atlas = calibration.atlas;
    final colors = calibration.colors.renormalized(exposure);
    final sampler = FrameSampler(frame, calibration.geometry);
    var covered = 0;
    for (final id in atlas.regions) {
      if (id == RoiId.diceZone) continue;
      final bounds = boundsOf(atlas.roi(id));
      final background = colors.backgroundOf(id);
      var strange = 0, seen = 0;
      for (var iy = 0; iy < occlusionLattice; iy++) {
        final y = bounds.minY +
            (iy + 0.5) / occlusionLattice * (bounds.maxY - bounds.minY);
        for (var ix = 0; ix < occlusionLattice; ix++) {
          final x = bounds.minX +
              (ix + 0.5) / occlusionLattice * (bounds.maxX - bounds.minX);
          final sample = sampler.at(x, y);
          if (sample == null) continue;
          seen++;
          if (colors.strangenessOf(sample, background) > maxKnownDistance) {
            strange++;
          }
        }
      }
      if (seen > 0 && strange > minCoveredShare * seen) covered++;
    }
    return covered;
  }
}
