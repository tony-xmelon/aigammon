import 'dart:typed_data';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';

/// A [BoardVision] whose every answer is written by the test.
///
/// The house fake style, applied to perception: scripted answers consumed in
/// order, every call recorded, and nothing computed. `board_vision`'s own
/// suite is where the pipeline is measured — against real photographs, which
/// is the only honest way to measure it. What the session tests need is the
/// opposite: a perception layer that says exactly what the scenario is about,
/// so that "the play was ambiguous" or "the light died mid-turn" is one line
/// of script rather than a corpus frame nobody can construct by hand.
///
/// **The last scripted answer repeats.** A session polls readability on every
/// stable frame and re-asks a pending query on every frame until it gets an
/// answer it can use, so a script of fixed length would run out mid-scenario
/// and turn a behavioural test into a bookkeeping exercise. Scripts are
/// therefore "what happens next, and then from now on"; [readabilityCalls] and
/// friends are how a test asserts that a query stopped being asked.
class FakeVision implements BoardVision {
  /// What the session calibrated against. Nothing here reads it, and building
  /// a real one needs a photographed board, so asking for it is a bug in the
  /// caller rather than a gap in the fake.
  @override
  BoardCalibration get calibration =>
      throw UnimplementedError('FakeVision has no calibration to hand out');

  // --- the script ----------------------------------------------------------

  final List<Readability> _readability = <Readability>[greenReading];
  final List<DiceReading?> _dice = <DiceReading?>[null];
  final List<PlayAnswer> _plays = <PlayAnswer>[matchesNothing];
  final List<VerifyAnswer> _verdicts = <VerifyAnswer>[boardAgrees];

  /// The next readability verdicts, in order; the last one repeats.
  void willSee(List<Readability> readings) => _replace(_readability, readings);

  /// The next `readDice` answers; `null` is "there are not two settled dice",
  /// which is the common real answer and the one the manual pad exists for.
  void willReadDice(List<DiceReading?> readings) => _replace(_dice, readings);

  /// The next `matchLegalPlay` answers, written against the query rather than
  /// against moves the test would have to enumerate by hand.
  void willMatchPlay(List<PlayAnswer> answers) => _replace(_plays, answers);

  /// The next `verifyExpectedBoard` answers.
  void willVerify(List<VerifyAnswer> answers) => _replace(_verdicts, answers);

  static void _replace<T>(List<T> script, List<T> answers) {
    if (answers.isEmpty) {
      throw ArgumentError('a script needs at least one answer — its last '
          'entry is what repeats once the others are used up');
    }
    script
      ..clear()
      ..addAll(answers);
  }

  static T _next<T>(List<T> script) =>
      script.length == 1 ? script.first : script.removeAt(0);

  // --- the record ----------------------------------------------------------

  /// Every query, in order, as `'readability'`, `'dice'`, `'play'`,
  /// `'verify'` — for asserting which question a phase asks, and that a paused
  /// session asks none of them.
  final List<String> calls = <String>[];

  int get readabilityCalls => calls.where((c) => c == 'readability').length;
  int get diceCalls => calls.where((c) => c == 'dice').length;
  int get playCalls => calls.where((c) => c == 'play').length;
  int get verifyCalls => calls.where((c) => c == 'verify').length;

  /// The `(before, mover, candidates, beforeFrame)` of every `matchLegalPlay`.
  final List<PlayQuery> playQueries = <PlayQuery>[];

  /// The position every `verifyExpectedBoard` was primed with.
  final List<BoardState> verifyQueries = <BoardState>[];

  // --- BoardVision ---------------------------------------------------------

  @override
  Readability assessReadability(Frame frame, MotionHint motion) {
    calls.add('readability');
    return _next(_readability);
  }

  @override
  DiceReading? readDice(Frame frame) {
    calls.add('dice');
    return _next(_dice);
  }

  @override
  List<PlayMatch> matchLegalPlay(
    Frame frame,
    BoardState before,
    Player mover,
    List<Move> legalPlays, {
    required Frame beforeFrame,
  }) {
    calls.add('play');
    playQueries.add(PlayQuery(before, mover, legalPlays, beforeFrame));
    return _next(_plays)(before, mover, legalPlays);
  }

  @override
  BoardDiscrepancies verifyExpectedBoard(Frame frame, BoardState expected) {
    calls.add('verify');
    verifyQueries.add(expected);
    return _next(_verdicts)(expected);
  }

  @override
  DriftReport recoverFromDrift(Frame frame, BoardState expected) =>
      DriftReport.of(verifyExpectedBoard(frame, expected));

  @override
  ConfirmResult confirmStartingPosition(Frame frame) =>
      throw UnimplementedError('calibration is Task 12, not the session');

  @override
  OccupancyReader occupancyIn(Frame frame) => throw UnimplementedError(
      'the session asks state-primed questions, never a raw count');
}

/// One `matchLegalPlay` call, as the test wants to read it back.
class PlayQuery {
  PlayQuery(this.before, this.mover, this.candidates, this.beforeFrame);

  final BoardState before;
  final Player mover;
  final List<Move> candidates;

  /// The settled frame the session held from before the play. Identity matters
  /// — `board_vision` requires both frames to come from one calibration epoch,
  /// so a test proves the session dropped a stale one by comparing instances.
  final Frame beforeFrame;
}

/// An answer to "which of these legal plays happened?", written against the
/// query so a test never has to spell a [Move] out.
typedef PlayAnswer = List<PlayMatch> Function(
    BoardState before, Player mover, List<Move> legal);

/// An answer to "does the board hold this position?".
typedef VerifyAnswer = BoardDiscrepancies Function(BoardState expected);

/// Nothing in the picture looks like any of the candidates.
List<PlayMatch> matchesNothing(
        BoardState before, Player mover, List<Move> legal) =>
    const <PlayMatch>[];

/// The candidate at [index] happened, unambiguously.
PlayAnswer matchesPlay(int index, {double confidence = 0.9}) =>
    (before, mover, legal) => <PlayMatch>[
          _match(legal[index], before, confidence: confidence),
        ];

/// The candidates at [index] and [alsoIndex] are indistinguishable — the
/// picture cannot say which of the two the hand made.
PlayAnswer matchesAmbiguously(int index, int alsoIndex) =>
    (before, mover, legal) => <PlayMatch>[
          _match(legal[index], before,
              confidence: 0.9, tiedWith: <Move>[legal[alsoIndex]]),
        ];

/// Something happened, but nothing legal — every candidate is implausible.
PlayAnswer matchesImplausibly(int index) => (before, mover, legal) => <PlayMatch>[
      _match(legal[index], before, confidence: PlayMatcher.minConfidence / 2),
    ];

PlayMatch _match(Move play, BoardState before,
        {required double confidence, List<Move> tiedWith = const <Move>[]}) =>
    PlayMatch(
      play: play,
      // The position the play lands on. The session applies the move through
      // the `GameController` and never reads this, so the fake does not pay to
      // compute a board nobody looks at.
      after: before,
      confidence: confidence,
      cost: 1 - confidence,
      instability: 0,
      tiedWith: tiedWith,
      unobservable: const <RoiId>[],
    );

/// Nothing in the picture contradicts the game.
BoardDiscrepancies boardAgrees(BoardState expected) =>
    BoardDiscrepancies(expected: expected, regions: const <RegionVerification>[]);

/// The picture contradicts the game **everywhere it can** — every point and
/// both ends of the bar.
///
/// Deliberately total rather than aimed at one region: placement verification
/// asks only about the regions the dictated play touched, and a test that had
/// to name those in advance would be testing its own arithmetic about
/// `regionsTouchedBy` rather than the session's handling of a wrong placement.
BoardDiscrepancies boardDisagrees(BoardState expected) => BoardDiscrepancies(
      expected: expected,
      regions: <RegionVerification>[
        for (var p = 0; p < 24; p++)
          _disagreement(RoiId.point(p), CheckerColor.white, p),
        _disagreement(RoiId.bar, CheckerColor.white, null),
        _disagreement(RoiId.bar, CheckerColor.black, null),
      ],
    );

RegionVerification _disagreement(
        RoiId region, CheckerColor side, int? pointIndex) =>
    RegionVerification(
      region: region,
      side: side,
      pointNumber: pointIndex == null ? null : pointIndex + 1,
      expected: 1,
      observedColour: CheckerColor.none,
      observedCount: 0,
      observedHeight: 0,
      reach: 0,
      verdict: RegionVerdict.disagrees,
      kind: DiscrepancyKind.unexpectedlyEmpty,
      confidence: 0.9,
    );

/// The green verdict, spelled out once so every scenario that is not about
/// readability can ignore the subject.
const Readability greenReading = Readability.stated(
  level: ReadabilityLevel.green,
  message: 'I can see the board.',
);

/// A red that clears on its own — the pause the spec asks for, and nothing
/// more.
const Readability tooDarkReading = Readability.stated(
  level: ReadabilityLevel.red,
  cause: ReadabilityCause.tooDark,
  message: 'It is too dark to read the board.',
);

/// A red that has killed the calibration: the session has to route to the
/// guided corner flow, and the game must not notice.
const Readability staleCalibrationReading = Readability.stated(
  level: ReadabilityLevel.red,
  cause: ReadabilityCause.calibrationStale,
  requiresRecalibration: true,
  message: 'The board is not where it was when I learned it.',
);

/// A settled pair of dice showing [a] and [b].
DiceReading diceShowing(int a, int b, {double confidence = 0.9}) => DiceReading(
      first: _die(a, 0.30),
      second: _die(b, 0.36),
      confidence: confidence,
    );

DieReading _die(int face, double x) => DieReading(
      face: face,
      center: Pt(x, 0.5),
      span: 0.075,
      pipContrast: 60,
      squareness: 0.9,
    );

/// A frame that is only a frame: the session hands it straight to perception,
/// which here is [FakeVision] and reads no pixels.
///
/// Distinct instances on purpose — the session's before-frame handling is
/// asserted by identity.
Frame blankFrame({int width = 8, int height = 6}) =>
    Frame(Uint8List(width * height * 3), width, height);
