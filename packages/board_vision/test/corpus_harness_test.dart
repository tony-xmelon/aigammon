import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

    test('every committed sidecar is still the one the plan produces', () {
      // Not just the same shot numbers: the same ground truth, the same
      // instructions, the same everything the plan owns. The corpus is
      // generated and committed, so it goes stale the moment the plan moves —
      // and a stale sidecar is a corpus scoring this week's pipeline against
      // last week's truth. Caught here once already, on nothing worse than a
      // reworded instruction.
      final planned = <String, CorpusShot>{
        for (final shot in flatten(buildCapturePlan())) shot.id: shot,
      };
      final committed = loadSidecars(Directory('test/corpus/synthetic'));
      expect(committed.map((s) => s.id).toSet(), planned.keys.toSet());

      for (final shot in committed) {
        expect(
          jsonEncode(shot.toJson()),
          // Everything except the two fields the generator owns: where the
          // corners came out after the session's jitter, and the recipe that
          // drew the picture.
          jsonEncode(planned[shot.id]!
              .copyWith(corners: shot.corners, synthetic: shot.synthetic)
              .toJson()),
          reason: 'shot ${shot.id} has drifted from the capture plan — '
              'regenerate with tool/generate_synthetic_corpus.dart',
        );
      }
    });

    test('the committed pictures are still the ones this code draws', () {
      // The sidecar guard above deliberately excludes `corners` and
      // `synthetic` — the two fields that describe the PICTURE — so on its own
      // it would let a renderer change, a new `kCorpusDegradation`, or a
      // different palette in the generator's session map leave thirty-three
      // stale JPEGs behind with nothing red. Determinism is what makes the
      // corpus reproducible; this is the test that notices if it is lost.
      //
      // Two shots rather than thirty-three, for runtime: one calibration frame
      // and one with dice on it, which between them exercise the warp, the
      // palette, all three degradation knobs, the dice placements and the JPEG
      // encoder. The three deliberately-spoiled shots are not re-rendered —
      // their quads are the generator's own arithmetic and are deliberately
      // not recorded anywhere a harness could reach, since a shot whose
      // sidecar said where the board really was would not be much of a drift
      // test.
      final committed = loadSidecars(Directory('test/corpus/synthetic'));
      final calibration = committed.firstWhere((s) => s.id == '001');
      final withDice = committed.firstWhere((s) => s.id == '002');
      expect(calibration.corners, isNotNull);
      expect(withDice.dice, isNotNull);
      expect(withDice.calibrateFrom, calibration.id,
          reason: 'the dice shot is warped onto its session\'s quad, which is '
              'only recorded on the shot the session calibrates from');

      for (final shot in <CorpusShot>[calibration, withDice]) {
        expect(
          _reRender(shot, calibration.corners!),
          File('test/corpus/synthetic/${shot.id}.jpg').readAsBytesSync(),
          reason: 'shot ${shot.id} on disk is not what the renderer draws '
              'today — regenerate with tool/generate_synthetic_corpus.dart, '
              'and look at why it moved before you do',
        );
      }
    });

    test('and they were drawn at the settings this code still uses', () {
      // The other half of the same guard, covering the thirty-one shots not
      // re-rendered above: a knob turned in `kCorpusDegradation` or in the
      // corpus JPEG settings has to be followed by a regeneration.
      for (final shot in loadSidecars(Directory('test/corpus/synthetic'))) {
        final recipe = shot.synthetic;
        expect(recipe, isNotNull, reason: '${shot.id} has no recipe');
        expect(recipe!.noise, kCorpusDegradation.noise, reason: shot.id);
        expect(recipe.blurSigma, kCorpusDegradation.blurSigma,
            reason: shot.id);
        expect(recipe.jpegQuality, kCorpusJpegQuality, reason: shot.id);
        expect(
          BoardPalette.all.map((p) => p.name),
          contains(recipe.palette),
          reason: '${shot.id} was drawn with a palette that no longer exists',
        );
      }
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
      stdout
        ..write(board.report())
        ..write(_realFloorReport(board));
    });

    test('is committed and was scored', () {
      expect(board.shots, 10,
          reason: 'ten windows out of one filmed game — see buildRealSession');
      expect(board.sessions, 1);
      expect(board.totalFor(CorpusMetric.calibration).attempts, 1,
          reason: 'one board, one light, one camera position, one calibration');
    });

    test('every committed sidecar is still the one the filmed session '
        'produces', () {
      // The same guard the synthetic corpus gets, and it matters more here:
      // these sidecars carry a REPLAYED ledger, so a shot that drifted from
      // the plan would be scoring photographs against a game that no longer
      // exists. Corners are excluded for the same reason the synthetic guard
      // excludes its quad — they are a property of the prepared image, read
      // off it rather than derived from the plan.
      final planned = <String, CorpusShot>{
        for (final shot in buildRealSession().shots) shot.id: shot,
      };
      final committed = loadSidecars(Directory('test/corpus/real'));
      expect(committed.map((s) => s.id).toSet(), planned.keys.toSet());
      for (final shot in committed) {
        expect(
          jsonEncode(shot.toJson()),
          jsonEncode(planned[shot.id]!
              .copyWith(
                corners: shot.corners,
                foldingCorners: shot.foldingCorners,
              )
              .toJson()),
          reason: 'shot ${shot.id} has drifted from the filmed session — '
              're-prepare with tool/prepare_corpus.dart --plan filmed',
        );
        if (shot.events != null) {
          expect(shot.replayedBoard, shot.board,
              reason: '${shot.id}: the committed log no longer replays to the '
                  'committed board');
        }
      }
    });

    test('it holds the rates it was committed at, and may only improve', () {
      // **Why this corpus is held to its own numbers and not to the spec's.**
      //
      // The synthetic corpus above asserts `targets.dart` exactly, and must:
      // it is a bed this package draws, so a target it misses is a bug in
      // something here. This one is ten frames of a real folding board in real
      // backlight, and it misses some of those targets today — the dice
      // reader declines every real roll, and per-region counts run well under
      // what a drawn board gives. Those gaps are the Task 6 GATE's subject
      // matter: the plan says the spec's table is "renegotiated only at the
      // Task 6 gate with the user", and this corpus is the evidence that
      // conversation reads.
      //
      // So asserting the spec's targets here would redden CI permanently on a
      // question that is not CI's to answer, and dropping the metrics would
      // hide the gap from the people whose decision it is. The third way is
      // this: pin what it measured on the day it was committed. A later change
      // may not silently make the real corpus worse; making it better costs
      // nothing and is noticed by nobody, which is the right price. The gap to
      // the spec is printed alongside every run, so nothing is out of sight.
      //
      // When the gate renegotiates a target, or a fix moves a number, these
      // floors are re-measured deliberately and in the same commit.
      final violations = <String>[];
      for (final entry in kRealCorpusFloors.entries) {
        final tally = board.totalFor(entry.key);
        expect(tally.attempts, greaterThan(0),
            reason: '${entry.key.label} was never attempted — a floor over an '
                'empty tally is a floor over nothing');
        if (tally.rate! + 1e-9 < entry.value) {
          violations.add('${entry.key.label} fell to '
              '${tally.rate!.toStringAsFixed(3)} ($tally), floor '
              '${entry.value.toStringAsFixed(3)}');
        }
      }
      expect(violations, isEmpty, reason: board.report());
    });

    test('the dice metric says found, right and refused, not one rate', () {
      // The distinction the gate turns on. Zero pairs read is two completely
      // different findings — a reader that answers wrongly, or a reader that
      // declines — and only the second is behaviour the design asked for. The
      // sidecars keep the four human-read rolls either way: they are ground
      // truth, and ground truth does not move because the machine cannot see
      // it yet.
      final pairs = board.totalFor(CorpusMetric.dicePair);
      final found = board.signalOf(kDiceFoundSignal);
      expect(found.n, pairs.attempts,
          reason: 'every shot with a roll in it must be counted once');
      final foundCount = found.sum.round();
      expect(pairs.successes, lessThanOrEqualTo(foundCount),
          reason: 'a pair cannot be read right without being found at all');
      expect(foundCount - pairs.successes, 0,
          reason: 'a pair was FOUND and read WRONG on the real corpus. That is '
              'a misread entering the game state, not a refusal, and it is a '
              'different conversation from the one this corpus was committed '
              'having — re-measure the floors deliberately.');
    });

    test('the bar shot reports what it read on the worn hinge', () {
      // The flagship. Every other question about this board's hinge has been
      // asked of an EMPTY one; 066 has a Black checker standing on the rubbed
      // ridge, which is the object-versus-surface case in the wild. Printed
      // verbatim whatever it says, because the answer is the finding.
      final bar = board
          .missesOf(CorpusMetric.regionOccupancy)
          .where((m) => m.startsWith('066 bar:'))
          .toList();
      final read = bar.isEmpty
          ? '066 bar: read as the sidecar says — a Black checker on the hinge'
          : bar.single;
      stdout.writeln('\n  THE BAR SHOT (066), verbatim:\n    $read\n');
      expect(board.sliceOf(CorpusMetric.regionOccupancy, 'region'),
          contains('bar'),
          reason: 'the bar must be scored on a shot that has a checker on it, '
              'or this corpus is not asking its own flagship question');
    });

    test('shots waiting on hand-tapped corners are named, not ignored', () {
      // The one manual step in the pipeline. A session whose corners have not
      // been filled in is skipped with its reason, so it shows up in the
      // report rather than quietly shrinking the denominator.
      expect(board.skipped, isEmpty,
          reason: board.skipped.map((s) => s.toString()).join('; '));
    });

    test('it stays inside the corpus size budget', () {
      expect(board.bytes, lessThan(kCorpusByteBudget),
          reason: '${megabytes(board.bytes)} committed');
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

    test('a session on a board of a different shape is read through its own '
        'measurements', () {
      // The real corpus is shot on a folding-case board — no bear-off wells, a
      // hinge for a bar — and its sidecars carry the widths a person measured
      // off the calibration frame. The harness has to read every shot in the
      // session through them.
      final board = _scoreFixture(_Fixture.foldingCase);
      expect(board.targetViolations(), isEmpty, reason: board.report());
      expect(board.totalFor(CorpusMetric.calibration).rate, 1.0);
      expect(board.totalFor(CorpusMetric.dicePair).rate, 1.0);
      expect(board.skipped, isEmpty, reason: board.report());

      // Twenty-four points and the bar were scored, and no tray was: there is
      // no well on this board for a checker to be in, and inventing an
      // "empty tray" reading would be scoring a region that does not exist.
      expect(board.sliceOf(CorpusMetric.regionOccupancy, 'region').keys,
          isNot(contains('tray')));
      expect(board.sliceOf(CorpusMetric.regionOccupancy, 'region').keys,
          contains('point'));
      // Checkers borne off such a board leave it altogether, so the sidecar
      // can say so and perception cannot check it. Said out loud rather than
      // quietly shrinking the denominator.
      expect(board.notes.join(' '), contains('borne off'));
    });

    test('and the same corpus without them does not calibrate at all', () {
      // The discriminator. If the harness ignored the field, this would score
      // exactly as well as the one above — and the corpus would be scoring a
      // pipeline reading every region a column out of true.
      final board = _scoreFixture(_Fixture.foldingCaseUnmeasured);
      expect(board.totalFor(CorpusMetric.calibration).rate, 0.0);
      expect(
        board.targetViolations(),
        contains(contains(CorpusMetric.calibration.label)),
        reason: board.report(),
      );
    });

    test('a session on a board that FOLDS is read through its eight points',
        () {
      // The other thing the first real board turned out to be: a case whose
      // two leaves tent, so no four corners describe it. Its sidecars carry
      // eight points, and the harness has to notice and take the folding door.
      final board = _scoreFixture(_Fixture.tentedFoldingCase);
      expect(board.targetViolations(), isEmpty, reason: board.report());
      expect(board.totalFor(CorpusMetric.calibration).rate, 1.0);
      expect(board.totalFor(CorpusMetric.dicePair).rate, 1.0);
      expect(board.skipped, isEmpty, reason: board.report());
    });

    test('and the same photographs fitted to one plane do not calibrate', () {
      // The discriminator, and the same shape as the widths one above: same
      // pictures, same session, the eight points replaced by the four they
      // contain and the widths those eight would have derived. If the harness
      // ignored the field this would score exactly as well as the test above.
      final board = _scoreFixture(_Fixture.tentedFoldingCaseFlatFit);
      expect(board.totalFor(CorpusMetric.calibration).rate, 0.0);
      expect(
        board.targetViolations(),
        contains(contains(CorpusMetric.calibration.label)),
        reason: board.report(),
      );
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

/// What the real corpus scored on the day it was committed, per metric.
///
/// **Measured, not chosen.** Every number here was read off the scoreboard the
/// committed frames produce, and each is a floor rather than a target: the
/// corpus may not get worse without somebody saying so in the same commit, and
/// it may get better freely. The spec's own table is printed beside them on
/// every run — see [_realFloorReport] — so the gap the Task 6 gate exists to
/// discuss is never out of sight.
///
/// **They are one-sided, and that is a real limit.** A floor catches a
/// regression and says nothing about an improvement, so a number that rose
/// because the session's corners were re-tapped more luckily would pass here
/// in silence, with nothing in the pipeline having changed. The occupancy
/// numbers in particular carry the corner-choice spread recorded in the plan
/// doc's Task 6 note — every set in the accepting region passes the same
/// calibration gate, and their counts on this frame span 13/24 to 23/24. Read
/// these as a ratchet against regression, never as a measurement of the
/// pipeline's accuracy to three decimal places.
///
/// The two that miss the spec today, and why they are recorded rather than
/// asserted:
///
/// * **dice pair 0/4.** The reader declines every real roll — it finds no pair
///   at all rather than reading a wrong one. This board's dice are 0.021 of it
///   across against the synthetic bed's 0.075, and the band-location and tilt
///   work that would let a die that small be found is queued, not done.
/// * **region occupancy 0.784.** Counts on this board run short, worst on tall
///   stacks, exactly as the plan doc's far-half note predicts. The design never
///   trusts a blind count anyway; it is Task 7's play matching that the spec
///   sets a threshold for, and this number is what that will be built against.
const Map<CorpusMetric, double> kRealCorpusFloors = <CorpusMetric, double>{
  CorpusMetric.calibration: 1.0,
  CorpusMetric.startConfirmed: 1.0,
  CorpusMetric.dicePair: 0.0,
  CorpusMetric.diceAbsence: 1.0,
  CorpusMetric.regionOccupancy: 189 / 241,
  CorpusMetric.regionColour: 230 / 241,
};

/// The floors, what was measured against them, and how far each still sits
/// from the spec — printed under the real corpus's scoreboard every run.
String _realFloorReport(Scoreboard board) {
  final out = StringBuffer()
    ..writeln()
    ..writeln('  real corpus: measured against its own floors, and the gap to '
        'the spec')
    // The gap column is eleven wide because '(no target)' is eleven
    // characters: a padLeft narrower than its own widest cell does not pad, it
    // just runs into the column before it.
    ..writeln('  ${'metric'.padRight(28)}${'measured'.padLeft(9)}'
        '${'floor'.padLeft(8)}${'spec'.padLeft(8)}${'gap'.padLeft(12)}');
  for (final metric in CorpusMetric.values) {
    final tally = board.totalFor(metric);
    if (tally.attempts == 0) continue;
    final floor = kRealCorpusFloors[metric];
    final target = kMetricTargets[metric];
    final gap = target == null ? null : tally.rate! - target;
    out.writeln('  ${metric.label.padRight(28)}'
        '${tally.rate!.toStringAsFixed(3).padLeft(9)}'
        '${(floor?.toStringAsFixed(3) ?? '—').padLeft(8)}'
        '${(target?.toStringAsFixed(3) ?? '—').padLeft(8)}'
        '${(gap == null ? '(no target)' : '${gap >= 0 ? '+' : ''}'
            '${gap.toStringAsFixed(3)}').padLeft(12)}');
  }

  final pairs = board.totalFor(CorpusMetric.dicePair);
  if (pairs.attempts > 0) {
    final found = board.signalOf(kDiceFoundSignal).sum.round();
    out
      ..writeln()
      ..writeln('  dice, split three ways: ${pairs.attempts} rolls in the '
          'sidecars, $found found by the reader, ${pairs.successes} read '
          'right, ${pairs.attempts - found} refused outright.')
      ..writeln('  A refusal is the behaviour the design asks for; a wrong '
          'pair would not be.');
  }
  return (out..writeln('=' * 64)).toString();
}

/// A three-shot corpus on a folding-case board: no bear-off wells, a hinge for
/// a bar. The shape the real Task 6 corpus is shot on.
///
/// With [measured] the sidecars carry the widths a person read off the
/// calibration frame, as `prepare_corpus` writes them; without it they carry
/// nothing and the harness has only the standard widths to go on — which puts
/// every column most of one out of true. The two are the same photographs, so
/// the difference between the scoreboards is entirely the field.
///
/// The position shot has two checkers borne off, which on this board means off
/// the felt: there is nowhere to put them, and the picture simply shows
/// thirteen White checkers. That is the case the harness has to say something
/// about rather than score.
Directory _writeFoldingCaseFixture({required bool measured}) {
  final directory = Directory.systemTemp.createTempSync('corpus_folding');
  const conditions = CaptureConditions(
    board: 'folding case',
    lighting: 'daylight',
    angle: 'straight on',
  );
  const degradation = ShotDegradation(noise: 2, blurSigma: 0.8, seed: 11);
  final quad = jitterQuad(kCameraQuad, 0.8, 11);

  // Two of White's five off the 6-point and off the board altogether.
  final onFelt = BoardState(
    points: <int>[
      for (final (i, c) in BoardState.initial().points.indexed)
        i == 5 ? c - 2 : c,
    ],
  );

  CorpusShot shotOf({
    required String id,
    required ShotKind kind,
    required String? calibrateFrom,
    required BoardState board,
    Dice? dice,
    BoardQuad? corners,
  }) =>
      CorpusShot(
        id: id,
        session: 'folding',
        kind: kind,
        calibrateFrom: calibrateFrom,
        corners: corners,
        orientation: BoardOrientation.whiteHomeNear,
        board: board,
        events: null,
        dice: dice,
        capture: conditions,
        synthetic: null,
        expectRefusal: null,
        refusalReason: null,
        title: 'folding $id',
        instructions: const <String>['fixture'],
        proportions: measured ? _foldingCase : null,
      );

  void write(CorpusShot shot, Frame frame) {
    File('${directory.path}/${shot.id}.jpg')
        .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(frame)));
    writeSidecar(directory, shot);
  }

  final calibration = renderShot(
    board: BoardState.initial(),
    proportions: _foldingCase,
    quad: quad,
    degradation: degradation,
  );
  write(
    shotOf(
      id: 'g01',
      kind: ShotKind.calibration,
      calibrateFrom: null,
      board: BoardState.initial(),
      corners: calibration.groundTruthQuad,
    ),
    calibration.frame,
  );

  write(
    shotOf(
      id: 'g02',
      kind: ShotKind.dice,
      calibrateFrom: 'g01',
      board: BoardState.initial(),
      dice: Dice(6, 3),
    ),
    renderShot(
      board: BoardState.initial(),
      dice: Dice(6, 3),
      proportions: _foldingCase,
      quad: quad,
      degradation: degradation,
    ).frame,
  );

  write(
    shotOf(
      id: 'g03',
      kind: ShotKind.position,
      calibrateFrom: 'g01',
      // The sidecar says two are off; the picture cannot show that, and the
      // rendered board is the thirteen checkers still on the felt.
      board: BoardState(points: onFelt.points, whiteOff: 2),
    ),
    renderShot(
      board: onFelt,
      proportions: _foldingCase,
      quad: quad,
      degradation: degradation,
    ).frame,
  );

  return directory;
}

/// A two-shot corpus on a folding case standing open and tented.
///
/// With [asFolding] the sidecars carry the eight points a person tapped and
/// the harness takes the folding door. Without it they carry the four outer
/// points those eight contain, plus the widths the eight would have derived —
/// which is to say, everything a careful person could measure while still
/// believing the board is flat. The pictures are identical, so the difference
/// between the two scoreboards is entirely how the harness read the field.
Directory _writeTentedFixture({required bool asFolding}) {
  final directory = Directory.systemTemp.createTempSync('corpus_tented');
  const conditions = CaptureConditions(
    board: 'folding case, tented',
    lighting: 'daylight',
    angle: 'low, near-left corner',
  );
  const degradation = ShotDegradation(noise: 2, blurSigma: 0.5, seed: 11);
  final roll = Dice(5, 2);
  // NOT the classic palette, and the reason is measured rather than a
  // preference: see the JPEG note on [kCorpusDegradation]. At a steep
  // viewpoint, quality-95 JPEG puts that palette's far-half black stack on a
  // knife edge — with nothing folding involved — and a fixture whose job is
  // the harness's routing must not be sitting on somebody else's cliff. This
  // palette is the hardest of the three for telling felt from triangles and
  // the steadiest through the encoder; checked over three grain seeds.
  const palette = BoardPalette.lowContrastWood;

  final calibration = renderFoldingShot(
    board: BoardState.initial(),
    palette: palette,
    degradation: degradation,
  );
  final eight = calibration.groundTruthCorners;

  CorpusShot shotOf({
    required String id,
    required ShotKind kind,
    required String? calibrateFrom,
    Dice? dice,
    bool carriesCorners = false,
  }) =>
      CorpusShot(
        id: id,
        session: 'tented',
        kind: kind,
        calibrateFrom: calibrateFrom,
        corners: carriesCorners ? eight.outer : null,
        orientation: BoardOrientation.whiteHomeNear,
        board: BoardState.initial(),
        events: null,
        dice: dice,
        capture: conditions,
        synthetic: null,
        expectRefusal: null,
        refusalReason: null,
        title: 'tented $id',
        instructions: const <String>['fixture'],
        proportions: asFolding ? null : eight.proportions,
        foldingCorners: asFolding && carriesCorners ? eight : null,
      );

  void write(CorpusShot shot, Frame frame) {
    File('${directory.path}/${shot.id}.jpg')
        .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(frame)));
    writeSidecar(directory, shot);
  }

  write(
    shotOf(
      id: 't01',
      kind: ShotKind.calibration,
      calibrateFrom: null,
      carriesCorners: true,
    ),
    calibration.frame,
  );
  write(
    shotOf(id: 't02', kind: ShotKind.dice, calibrateFrom: 't01', dice: roll),
    renderFoldingShot(
      board: BoardState.initial(),
      palette: palette,
      // Clear of every stack and off the hinge, one on each leaf — so the
      // pair is read through two different planes in one pass.
      dicePlacements: <DicePlacement>[
        DicePlacement(face: roll.die1, center: const Pt(0.20, 0.5)),
        DicePlacement(face: roll.die2, center: const Pt(0.75, 0.5)),
      ],
      degradation: degradation,
    ).frame,
  );

  return directory;
}

/// Redraws [shot] from nothing but its own sidecar, and encodes it the way the
/// corpus is committed.
///
/// Driven entirely by the recipe in the sidecar rather than by anything inside
/// the generator, so this checks that a committed picture and the code that
/// claims to have drawn it still agree — which is what makes the corpus
/// reproducible and, when it stops being true, worth knowing about.
Uint8List _reRender(CorpusShot shot, BoardQuad sessionQuad) {
  final recipe = shot.synthetic!;
  final rendered = renderShot(
    board: shot.board,
    palette: recipe.boardPalette,
    lightingGain: recipe.lightingGain,
    orientation: shot.orientation,
    dicePlacements: recipe.dice.isEmpty ? null : recipe.placements,
    quad: shot.corners ?? sessionQuad,
    degradation: recipe.degradation,
  );
  return encodeCorpusJpeg(
    imageOfFrame(rendered.frame),
    quality: recipe.jpegQuality,
  );
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

  /// A folding-case board — no bear-off wells, a hinge for a bar — with the
  /// widths a person measured written into its sidecars, as the real corpus
  /// carries them.
  foldingCase,

  /// The same board and the same photographs, with the measurements left out.
  /// Every region is then read a column out of true, and the session must not
  /// calibrate.
  foldingCaseUnmeasured,

  /// A folding case standing open and TENTED — two leaf planes and a raised
  /// hinge, which is what such a board actually looks like on a table. Its
  /// sidecars carry the eight points a person tapped.
  tentedFoldingCase,

  /// The same photographs with the eight points replaced by the four outer
  /// ones they contain, plus the widths those eight would have derived. One
  /// plane through a board that has two, which is what the real frame did.
  tentedFoldingCaseFlatFit,
}

/// The folding-case board's shape: no wells, and a hinge for a bar.
const BoardProportions _foldingCase =
    BoardProportions(trayWidth: 0, barWidth: 0.03);

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
  if (fixture == _Fixture.foldingCase ||
      fixture == _Fixture.foldingCaseUnmeasured) {
    return _writeFoldingCaseFixture(measured: fixture == _Fixture.foldingCase);
  }
  if (fixture == _Fixture.tentedFoldingCase ||
      fixture == _Fixture.tentedFoldingCaseFlatFit) {
    return _writeTentedFixture(
      asFolding: fixture == _Fixture.tentedFoldingCase,
    );
  }
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
