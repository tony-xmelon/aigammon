import 'dart:io';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'corpus/capture_plan.dart';
import 'corpus/corpus_io.dart';
import 'corpus/harness.dart';
import 'corpus/scoreboard.dart';
import 'synthetic/board_renderer.dart';

/// **The corpus is the test suite.** This file is where that sentence in the
/// spec becomes a thing CI can go red on: it walks the committed corpus, asks
/// the pipeline the questions a live session would ask of each shot, and holds
/// the answers to the spec's own accuracy table.
///
/// Two corpora, one machinery. The synthetic one is committed and runs today;
/// the real one arrives with the plan's Task 6 and drops into exactly the same
/// scoring without a line changing. Until it does, its directory is empty and
/// this file **says so out loud** — an empty corpus is not a pass, it is a
/// question nobody has been asked yet, and the difference has to be visible in
/// the output or it will be forgotten.
///
/// ## The harness is itself tested
///
/// A scoreboard that has never been seen to fail proves nothing. The last group
/// builds three tiny corpora in a temporary directory — one correct, one with a
/// misread roll planted, one with a shot that is supposed to be unreadable and
/// is not — and checks that the right target goes red for the right reason,
/// and that the correct one stays green.
void main() {
  group('the synthetic corpus', () {
    late Scoreboard board;

    setUpAll(() {
      board = scoreCorpus(
        Directory('test/corpus/synthetic'),
        name: 'synthetic',
      );
      stdout.write(board.report());
    });

    test('is committed and was scored', () {
      expect(board.shots, greaterThan(0),
          reason: 'test/corpus/synthetic is empty — run '
              '`dart run tool/generate_synthetic_corpus.dart`');
      expect(board.sessions, 6);
      expect(board.totalFor(CorpusMetric.calibration).attempts, 6,
          reason: 'one calibration per session, as a real session does');
    });

    test('every shot the plan describes is present', () {
      final planned = flatten(buildCapturePlan()).map((s) => s.id).toSet();
      final present = loadSidecars(Directory('test/corpus/synthetic'))
          .map((s) => s.id)
          .toSet();
      expect(present, planned,
          reason: 'the corpus and the capture plan have drifted apart — '
              'regenerate with tool/generate_synthetic_corpus.dart');
    });

    test('it stays inside the corpus size budget', () {
      expect(board.bytes, lessThan(kCorpusByteBudget),
          reason: '${megabytes(board.bytes)} committed');
    });

    test('nothing was skipped', () {
      // A skipped shot is a hole in the corpus, and a hole that nobody sees is
      // how a suite quietly stops testing something.
      expect(board.skipped, isEmpty,
          reason: board.skipped.map((s) => s.toString()).join('; '));
    });

    test('the questions the corpus can ask were all asked', () {
      expect(board.totalFor(CorpusMetric.dicePair).attempts, 12);
      expect(board.totalFor(CorpusMetric.expectedRefusal).attempts, 3);
      expect(board.totalFor(CorpusMetric.regionOccupancy).attempts,
          greaterThan(600));
    });

    test('every spec target that is scoreable today is met', () {
      // Two of the spec's five, plus the refusal counterweight. Legal-play
      // identification, placement verification and full-board resync arrive
      // with the plan's Tasks 7 and 8, and their metrics slot into the same
      // scoreboard when they do.
      expect(board.targetViolations(), isEmpty);
    });

    test('occupancy has not fallen off a cliff (a tripwire, not a target)',
        () {
      // Explicitly NOT one of the spec's numbers, and deliberately kept out of
      // `kMetricTargets` so that `targetViolations` stays a pure reading of the
      // spec's table. Blind per-region counts have no target by design: the
      // design never trusts them alone, and it is Task 7's top-1 play
      // identification that the spec sets a threshold for.
      //
      // But "watched" turns into "ignored" the first time nobody looks, so
      // there is a floor here with a lot of slack under today's number. It
      // catches a collapse; it does not pretend to grade anything.
      final tally = board.totalFor(CorpusMetric.regionOccupancy);
      expect(tally.rate, greaterThan(0.85),
          reason: 'per-region occupancy fell to ${tally.rate}; the misses are '
              'listed in the scoreboard above');
    });

    test('the residuals are real, which is what makes the scores mean '
        'anything', () {
      // The degraded corpus's whole justification, checked where it is
      // actually scored rather than only in degradation_test.dart. On the flat
      // bed Tasks 1–4 used, every measured stack length divided into a whole
      // number of checkers exactly, so the rounding was never asked a question
      // and `floor()` in place of `round()` passed the entire matrix.
      final error = board.signalOf('stack height error (checkers)');
      expect(error.n, greaterThan(300));
      expect(error.mean, greaterThan(0.01),
          reason: 'the lengths are dividing into whole checkers again — the '
              'bed has gone flat and these scores would be arithmetic');
      expect(error.mean, lessThan(0.25),
          reason: 'a typical region should still land well inside its own '
              'checker; past this the bed is broken rather than hard');

      // Deliberately no upper bound on the worst case. Occupancy is watched
      // here, not promised: a region that reads two checkers out is a finding
      // for Task 7's diff-matching to answer, and hiding it behind an
      // assertion in the harness would be the harness deciding what the corpus
      // is allowed to say.
      final decided = board.signalOf('rounding decided the count');
      expect(decided.mean, greaterThan(0.05),
          reason: 'the mutant Task 4 could not kill: on this corpus, flooring '
              'instead of rounding must change some answers');
    });
  });

  group('the real corpus', () {
    late Scoreboard board;

    setUpAll(() {
      board = scoreCorpus(Directory('test/corpus/real'), name: 'real');
      stdout.write(board.report());
    });

    test('is scored when it exists, and says plainly when it does not', () {
      if (board.shots == 0) {
        expect(board.notes, isNotEmpty,
            reason: 'an absent corpus must announce itself, never pass '
                'silently');
        stdout.writeln(
          'NOTE: no real photographs yet. The synthetic corpus is what is '
          'being scored above; the numbers that decide the Task 6 gate come '
          'from corpus/CHECKLIST.md being shot on real boards.',
        );
        return;
      }
      expect(board.targetViolations(), isEmpty);
    });

    test('shots waiting on hand-tapped corners are named, not ignored', () {
      // The one manual step in the pipeline. A session whose corners have not
      // been filled in is skipped with its reason, so it shows up in the
      // report rather than quietly shrinking the denominator.
      for (final skipped in board.skipped) {
        expect(skipped.reason, isNotEmpty);
      }
    });
  });

  group('the harness can fail', () {
    test('a correct fixture corpus passes', () {
      final board = _scoreFixture(_Fixture.correct);
      expect(board.targetViolations(), isEmpty, reason: board.report());
      expect(board.totalFor(CorpusMetric.dicePair).rate, 1.0);
      expect(board.totalFor(CorpusMetric.expectedRefusal).rate, 1.0);
      expect(board.skipped, isEmpty);
    });

    test('a roll the sidecar disagrees with fails the dice target', () {
      final board = _scoreFixture(_Fixture.wrongRoll);
      expect(board.totalFor(CorpusMetric.dicePair).rate, lessThan(1.0));
      expect(
        board.targetViolations(),
        contains(contains(CorpusMetric.dicePair.label)),
        reason: board.report(),
      );
      // And only that one: a planted failure that reddened everything would
      // tell us nothing about which target caught it.
      expect(board.targetViolations().length, 1);
    });

    test('an unreadable shot that reads perfectly fails the refusal target',
        () {
      // The honesty check, and the one that matters most. A pipeline that
      // answers everything scores beautifully on every question it was asked
      // and is useless at the table, because the user cannot tell a confident
      // wrong answer from a right one.
      final board = _scoreFixture(_Fixture.readableWhenItShouldNotBe);
      expect(board.totalFor(CorpusMetric.expectedRefusal).rate, lessThan(1.0));
      expect(
        board.targetViolations(),
        contains(contains(CorpusMetric.expectedRefusal.label)),
        reason: board.report(),
      );
    });

    test('a corpus with no images at all is a note, not a pass', () {
      final empty = Directory.systemTemp.createTempSync('corpus_empty');
      addTearDown(() => empty.deleteSync(recursive: true));
      final board = scoreCorpus(empty, name: 'empty');
      expect(board.shots, 0);
      expect(board.targetViolations(), isEmpty);
      expect(board.notes, isNotEmpty);
    });

    test('a shot whose photograph never arrived is skipped by name', () {
      final directory = _writeFixture(_Fixture.correct);
      addTearDown(() => directory.deleteSync(recursive: true));
      File('${directory.path}/f02.jpg').deleteSync();

      final board = scoreCorpus(directory, name: 'missing image');
      expect(board.skipped.map((s) => s.id), contains('f02'));
      expect(board.totalFor(CorpusMetric.dicePair).attempts, 0);
    });
  });
}

/// What a fixture corpus has wrong with it, if anything.
enum _Fixture {
  /// Everything as the sidecars say.
  correct,

  /// The dice shot shows a different pair from the one its sidecar claims —
  /// the shape of a genuine misread.
  wrongRoll,

  /// The shot labelled unreadable is a clean, perfectly readable frame, so a
  /// pipeline that answers it is caught being over-confident rather than
  /// wrong.
  readableWhenItShouldNotBe,
}

Scoreboard _scoreFixture(_Fixture fixture) {
  final directory = _writeFixture(fixture);
  addTearDown(() => directory.deleteSync(recursive: true));
  return scoreCorpus(directory, name: fixture.name);
}

/// A three-shot corpus in a temporary directory: one session, one calibration,
/// one roll, one shot that is meant to be refused.
///
/// Small on purpose. Its job is to exercise the scoreboard's arithmetic and the
/// harness's routing, not to measure perception — so it uses the gentlest
/// viewpoint and the plainest board, and any failure it reports is a failure of
/// the harness rather than of the pipeline.
Directory _writeFixture(_Fixture fixture) {
  final directory = Directory.systemTemp.createTempSync('corpus_fixture');
  const conditions = CaptureConditions(
    board: 'fixture board',
    lighting: 'daylight',
    angle: 'straight on',
  );
  const degradation = ShotDegradation(noise: 2, blurSigma: 0.8, seed: 11);
  final quad = jitterQuad(kCameraQuad, 0.8, 11);

  CorpusShot shotOf({
    required String id,
    required ShotKind kind,
    required String? calibrateFrom,
    required BoardState board,
    Dice? dice,
    BoardQuad? corners,
    ExpectedRefusal? expectRefusal,
  }) =>
      CorpusShot(
        id: id,
        session: 'fixture',
        kind: kind,
        calibrateFrom: calibrateFrom,
        corners: corners,
        orientation: BoardOrientation.whiteHomeNear,
        board: board,
        events: null,
        dice: dice,
        capture: conditions,
        synthetic: const SyntheticRecipe(
          palette: 'classic',
          lightingGain: 1.0,
          noise: 2,
          blurSigma: 0.8,
          seed: 11,
          jpegQuality: kCorpusJpegQuality,
        ),
        expectRefusal: expectRefusal,
        refusalReason: expectRefusal == null ? null : 'planted for the fixture',
        title: 'fixture $id',
        instructions: const <String>['fixture'],
      );

  void write(CorpusShot shot, Frame frame) {
    File('${directory.path}/${shot.id}.jpg')
        .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(frame)));
    writeSidecar(directory, shot);
  }

  // f01 — the calibration the whole fixture session is read through.
  final calibration = renderShot(
    board: BoardState.initial(),
    quad: quad,
    degradation: degradation,
  );
  write(
    shotOf(
      id: 'f01',
      kind: ShotKind.calibration,
      calibrateFrom: null,
      board: BoardState.initial(),
      corners: calibration.groundTruthQuad,
    ),
    calibration.frame,
  );

  // f02 — a roll. Under _Fixture.wrongRoll the picture and the sidecar
  // disagree, which is exactly what a misread looks like from the harness's
  // side of the glass.
  final claimed = Dice(6, 3);
  final shown = fixture == _Fixture.wrongRoll ? Dice(2, 1) : claimed;
  write(
    shotOf(
      id: 'f02',
      kind: ShotKind.dice,
      calibrateFrom: 'f01',
      board: BoardState.initial(),
      dice: claimed,
    ),
    renderShot(
      board: BoardState.initial(),
      dice: shown,
      quad: quad,
      degradation: degradation,
    ).frame,
  );

  // f03 — a shot the sidecar says is unreadable. Normally it is (barely any
  // light); under _Fixture.readableWhenItShouldNotBe it is a clean frame, so
  // calibration succeeds and the refusal target has to catch it.
  final spoiled = fixture == _Fixture.readableWhenItShouldNotBe;
  final degraded = renderShot(
    board: BoardState.initial(),
    lightingGain: spoiled ? 1.0 : 0.12,
    quad: quad,
    degradation: degradation,
  );
  write(
    shotOf(
      id: 'f03',
      kind: ShotKind.degraded,
      calibrateFrom: null,
      board: BoardState.initial(),
      corners: degraded.groundTruthQuad,
      expectRefusal: ExpectedRefusal.calibration,
    ),
    degraded.frame,
  );

  return directory;
}
