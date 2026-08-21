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
      stdout
        ..write(board.report())
        ..write(priorReport(board));
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
      // One resync per shot the corpus does not deliberately spoil: thirty of
      // the thirty-three.
      expect(board.totalFor(CorpusMetric.boardResynced).attempts, 30);
      // Placement verification needs two shots one turn apart, and this corpus
      // has none — the same reason it cannot ask about plays. Said out loud
      // rather than reported as a silent zero.
      expect(board.totalFor(CorpusMetric.placementVerified).attempts, 0);
    });

    test('every spec target that is scoreable today is met', () {
      // Four of the spec's five, plus the refusal counterweight. Legal-play
      // identification is scored on the real corpus; this one cannot ask it —
      // see the test below.
      //
      // **Full-board resync is in that four now, and the reshape is why.**
      // Until the gate follow-up (2026-08-21) it was scored per whole BOARD and
      // missed here at 0.733, for an arithmetic reason rather than a perception
      // one. A resync sweep asks twenty-six regions on a folding case and
      // twenty-eight on a cased one — every board in this corpus is cased, so
      // 840 region-reads over 30 shots — and a board succeeds only when all
      // twenty-eight agree at once. At the measured 0.9869 a region, that is
      // **0.691** if the misses were independent and **0.733** as measured (a
      // little better, because a bad shot loses several regions together).
      // Requiring 0.90 of the whole board is requiring **0.9962** of every
      // region, which is not a threshold anybody chose.
      //
      // So the user reshaped the row to what the resolve screen actually
      // consumes — the region list — and per region this corpus scores 0.986
      // against the same 0.90. The whole-board rate is still counted, still
      // printed, and floored below, so nothing was hidden by the change.
      expect(board.targetViolations(), isEmpty, reason: board.report());
    });

    test('and the whole-board rate the reshape retired is still measured', () {
      // The number that used to be the target, kept as a watched row. A
      // reshape that deleted it would be indistinguishable from a reshape that
      // hid it.
      final board_ = board.totalFor(CorpusMetric.boardResynced);
      expect(board_.attempts, 30);
      expect(board_.successes, 22, reason: board.report());
      expect(kMetricTargets[CorpusMetric.boardResynced], isNull);
    });

    test('the whole-board queries hold the rates they were committed at', () {
      // The same ratchet the real corpus gets, for the same reason: a number
      // that is recorded rather than asserted is a number nobody notices
      // moving. Measured on the day Task 8 landed.
      final violations = <String>[];
      for (final entry in kSyntheticFloors.entries) {
        final tally = board.totalFor(entry.key);
        expect(tally.attempts, greaterThan(0), reason: entry.key.label);
        if (tally.rate! + 1e-9 < entry.value) {
          violations.add('${entry.key.label} fell to '
              '${tally.rate!.toStringAsFixed(3)} ($tally), floor '
              '${entry.value.toStringAsFixed(3)}');
        }
      }
      expect(violations, isEmpty, reason: board.report());
    });

    test('the state-primed read beats the blind one, region for region', () {
      // **The verifier's whole reason to exist, as a number.** It is handed the
      // expected count and only has to decide whether the picture contradicts
      // it, so its window is wider than the half-checker a blind count's
      // rounding sits on — and every region a blind count gets right is inside
      // that window by construction.
      //
      // **Compared like for like, and the denominators are why that has to be
      // said out loud.** The two rows' totals are 829/840 and 760/789: the
      // verifier asks both ends of the bar on every shot and `_scoreOccupancy`
      // does not, so the totals are over different sets, and setting one
      // against the other credits the verifier with bar reads nobody else
      // attempted. The point slices ARE the same reads on both sides — 720 of
      // them — and that is the comparison below.
      //
      // The counts are pinned rather than bounded. `greaterThan(0)` would pass
      // on one rescued region out of eighteen, which is the difference between
      // a query that earns its complexity and one that does not.
      final verified =
          board.sliceOf(CorpusMetric.regionVerified, 'region')['point']!;
      final blind =
          board.sliceOf(CorpusMetric.regionOccupancy, 'region')['point']!;
      expect(verified.attempts, blind.attempts,
          reason: 'the like-for-like comparison stopped being like for like');
      expect(verified.attempts, 720);
      expect(verified.successes, 712, reason: '$verified');
      expect(blind.successes, 694, reason: '$blind');

      // The same claim with no denominator at all: computed one (region, side)
      // at a time, so every mark is the two instruments answering about the
      // identical read of the identical frame.
      expect(board.signalOf(kPriorRescuedSignal).sum, 18,
          reason: 'the prior rescued a different number of regions than it did '
              'on the day this landed — re-measure deliberately');
      expect(board.signalOf(kPriorLostSignal).sum, 0,
          reason: 'a region a blind count got RIGHT was called wrong by the '
              'verifier, which the tolerance is meant to make impossible');
    });

    test('it says out loud that it cannot ask about plays', () {
      // A synthetic session photographs two mid-game positions from two
      // DIFFERENT seeded playouts, so no two of its shots are one turn apart
      // and there is no play in it to identify. That is a property of how the
      // capture plan was built, not a pipeline result, and the corpus has to
      // say so rather than quietly reporting nothing: an empty metric that
      // nobody notices is how a suite stops testing something.
      //
      // Where the target IS asserted on rendered before/after pairs is
      // `play_matcher_test.dart`, over sixty-four seeded turns.
      expect(board.totalFor(CorpusMetric.legalPlay).attempts, 0);
      expect(
        board.notes.where((n) => n.contains('one turn apart')).length,
        board.sessions,
        reason: 'every session must account for itself',
      );
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
        ..write(priorReport(board))
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

    test('the two dice rows ask about disjoint frames, and five belong to '
        'neither', () {
      // **The row that was paying for the wrong behaviour.** `diceAbsence`
      // says "no dice read as no dice", and until 2026-08-23 its denominator
      // was every shot with no certified roll — which on this corpus is six
      // frames, and **five of them have settled dice lying in them**. 008's
      // two are unmistakable at full resolution; 018's near die shows a clean
      // 5 on its top face. So the reader was scoring 6/6 for missing real
      // dice, and the day it started seeing them the row would have gone red.
      //
      // The fork is now on `CorpusShot.diceInFrame`, and this is the test that
      // says so: one frame in this session has no dice in it (001, the
      // calibration hold — and it has to be, since a die present at
      // calibration is learned as part of the board), four carry a certified
      // roll, and the remaining five are scored on neither row and named.
      expect(board.totalFor(CorpusMetric.diceAbsence).attempts, 1,
          reason: 'the absence row is over frames with no dice in them, and '
              'this session has exactly one: ${board.report()}');
      expect(board.totalFor(CorpusMetric.diceAbsence).successes, 1);

      final excluded = board.signalOf(kDiceUncertifiedSignal);
      expect(excluded.n, 5, reason: 'five frames have dice and no roll');
      expect(excluded.sum, 0,
          reason: 'the reader answered on a frame the corpus cannot check it '
              'against — that is not a failure, but it is new, and the note '
              'and the floors should be re-read deliberately');

      final note =
          board.notes.firstWhere((n) => n.contains('NEITHER dice row'));
      for (final id in <String>['008', '018', '020', '066', '070']) {
        expect(note, contains(id), reason: note);
      }

      // And between them the three outcomes account for every shot exactly
      // once, which is the arithmetic that makes an exclusion visible instead
      // of merely absent.
      expect(
        board.totalFor(CorpusMetric.dicePair).attempts +
            board.totalFor(CorpusMetric.diceAbsence).attempts +
            excluded.n,
        board.shots,
        reason: board.report(),
      );
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

    test('the six windows that ARE one turn apart carry the play-ID score, '
        'and the three that are not are named', () {
      // The corpus's ten windows are not ten consecutive turns. Turn 6's window
      // never came (hands still in shot), so 013->018 spans two plays; the two
      // end-game keyframes carry a board and no log at all, so nothing can be
      // paired with them. Six pairs are genuinely one turn apart — 001->003,
      // 003->005, 005->008, 008->010, 010->013 and 018->020 — and which six is
      // derived from the sidecars' own event logs rather than from a list typed
      // here.
      //
      // **018->020 has been in and out of this list twice**, which is why it is
      // worth naming. It was a pair; the 2026-08-21 audit retired it, believing
      // a checker had left the board during turn 7; the 2026-08-22 measurement
      // found that checker on the 10-point and both turns legal, and the pair
      // came back. Nothing was ever scored differently — it left and returned
      // through the same derivation as the others, which is why nothing here
      // had to be crossed out by hand.
      expect(board.totalFor(CorpusMetric.legalPlay).attempts, 6);
      // The same six, asked whether the session would have acted or prompted.
      expect(board.totalFor(CorpusMetric.legalPlayActed).attempts, 6);
      final note = board.notes.firstWhere((n) => n.contains('one turn apart'));
      for (final pair in <String>[
        '013->018',
        '020->066',
        '066->070',
      ]) {
        expect(note, contains(pair));
      }
      expect(note, isNot(contains('018->020')),
          reason: 'the turn-8 pair is scored, not skipped');
      // Both movers are represented: a play is identified from the change on
      // the board, and the two colours' checkers do not read alike on a real
      // one (colour 0.942 near against 0.975 far).
      expect(board.sliceOf(CorpusMetric.legalPlay, 'mover').keys,
          containsAll(<String>['white', 'black']));
    });

    test('the transit signal is zero now, and it is worth saying why', () {
      // **This row used to be the plan's ambiguity-honesty case in the wild,
      // and the corrections took it away.** Turn 3 was transcribed as
      // `W 5-2: 13/8 8/6`, a hop multiset `MoveGenerator.legalMoves` does not
      // list at all (it dedupes by resulting position and offers `13/11 11/6`
      // for that one), so the signal read 1 of 6 and was quoted as the reason
      // the harness scores positions rather than hop multisets.
      //
      // Measurement has since put turn 3 at **one man, 13/10 on a 2-1**, and
      // turn 4 at one man, `1/11` on a 6-4. Both are runs whose intermediate
      // point no photograph can name, and `canonicalPlay` folds each pair of
      // roads to one representative, so that is what the ledger records — the
      // generator lists every play in this corpus.
      //
      // **The harness's reason for scoring positions is unchanged** — it is
      // what `GameState.play` means and the only thing two settled frames can
      // say — but it is now supported by `play_matcher_test.dart`'s fixtures
      // rather than by this corpus, and pretending otherwise would be quoting
      // evidence that has been withdrawn. Pinned at zero so that a transcript
      // edit which reintroduces one has to say so.
      expect(board.signalOf(kTransitDifferedSignal).n, 6);
      expect(board.signalOf(kTransitDifferedSignal).sum, 0,
          reason: 'every filmed play is now written with hops the generator '
              'itself lists');
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

    test('the two board queries were asked of every shot and every pair, in '
        'both shapes', () {
      // The denominators, pinned, because the whole-board rates are zero and a
      // zero over an empty tally is indistinguishable from a zero over ten. Ten
      // shots resynced — the calibration frame and both board-only keyframes
      // included — and the six pairs that are one turn apart verified as
      // placements, each scored twice: once on the regions the play touched and
      // once over the whole board.
      expect(board.totalFor(CorpusMetric.boardResynced).attempts, 10);
      expect(board.totalFor(CorpusMetric.placementVerified).attempts, 6);
      expect(board.totalFor(CorpusMetric.placementVerifiedBoard).attempts, 6);
      // Twenty-six regions a shot: twenty-four points and both ends of the
      // bar. This board is a folding case, so it has no bear-off wells to ask
      // about — those two come back `unobservable` and are not scored.
      expect(board.totalFor(CorpusMetric.regionVerified).attempts, 26 * 10);
    });

    test('the reshaped placement query is the narrower one, and it is what '
        'moved', () {
      // **The user\'s decision, as the two numbers it is a decision between.**
      // The same five attempts, the same five frames, the same verifier call:
      // the only difference is which regions the answer is read off. Over the
      // whole board every one of the five fails, because every one of these
      // frames contradicts its sidecar SOMEWHERE. Over the regions the play
      // actually touched, one comes back clean.
      //
      // **This row has been 3/6, then 1/5, and is now 1/6, and none of the
      // movement is perception.** Every step was a truth fix: the 2026-08-21
      // audit put men on cells the reader cannot see and retired a pair; the
      // 2026-08-22 measurement put them on different such cells and gave the
      // pair back. The pipeline has not been touched throughout.
      //
      // Pinned rather than bounded, because "it helps" is not a finding and
      // "it is worth one turn in six, and here are the five it is not" is.
      expect(board.totalFor(CorpusMetric.placementVerifiedBoard).successes, 0,
          reason: board.report());
      expect(board.totalFor(CorpusMetric.placementVerified).successes, 1,
          reason: board.report());
      // And the five that fail are **one mechanism plus one stray**, named so
      // that a change moving this number says which case it moved:
      //
      // * four of them are a **point's BASE** — the wide end against the near
      //   edge, which is where `StackAxis.forRegion` starts a near-half stack
      //   and where the harness prints "reach 0.000". (Every note in this
      //   batch called it the tip until 2026-08-23; the tip is the midline end
      //   and nothing happens there.) This folding case's rim stands proud of
      //   the felt and hides three quarters of the man standing at that base,
      //   so the reader returns *nothing* there rather than a short count: the
      //   10-point's arriving man twice (005->008 and 010->013), the 1-point's
      //   last Black man (008->010), and White's man on the hinge after the
      //   hit (018->020). Every one of them is a region the play just touched,
      //   which is what makes this the placement query's own worst case on
      //   this board;
      // * the **23-point** reads three men for two — an OVER-count, and the one
      //   the rim story does not cover. Its run starts at row zero on every
      //   shot of the session, where the board's own far rim and the shadow in
      //   its seam classify as Black, and half a pitch of that is enough.
      final missed = board.missesOf(CorpusMetric.placementVerified);
      expect(missed, hasLength(5));
      expect(missed[0], contains('the 23-point'));
      expect(missed[1], contains('the 10-point'));
      expect(missed[2], contains('the 1-point'));
      expect(missed[3], contains('the 10-point'));
      expect(missed[4], contains('the bar'));
    });

    test('the state-primed read beats the blind one on real photographs too',
        () {
      // The claim the verifier exists to make, on the only frames that can
      // settle it — **twenty-two** regions a blind count reports wrongly and
      // verification agrees with, none the other way.
      //
      // Over the 240 point-reads both rows score, that is 216 against 195:
      // **0.900 against 0.813**. Not the rows' totals, which are 235/260 and
      // 195/242 — the verifier asks both ends of the bar on every shot and
      // most of those extra reads are bare-bar agreements, so comparing the
      // totals would hand it about a point it did not earn.
      //
      // Both sides moved through each truth correction and the margin has only
      // widened (22 rescued now, 20, 21 and 22 before), which is the right
      // shape: the two instruments were being scored against the same wrong
      // cells, so correcting them helps both, and neither instrument is what
      // changed. The last two rescues are the keyframes' rim-hidden men on the
      // 1-point — a blind count sees nothing there and the verifier, handed
      // "White 1", declines to contradict it, which is the whole query in one
      // region.
      //
      // **And twenty-two regions is still not enough for a clean board**, which
      // is the finding rather than a caveat — see `kRealCorpusFloors`.
      final verified =
          board.sliceOf(CorpusMetric.regionVerified, 'region')['point']!;
      final blind =
          board.sliceOf(CorpusMetric.regionOccupancy, 'region')['point']!;
      expect(verified.attempts, blind.attempts,
          reason: 'the like-for-like comparison stopped being like for like');
      expect(verified.attempts, 240);
      expect(verified.successes, 216, reason: '$verified');
      expect(blind.successes, 195, reason: '$blind');

      expect(board.signalOf(kPriorRescuedSignal).sum, 22,
          reason: 'the prior rescued a different number of regions than it did '
              'on the day this landed — re-measure deliberately');
      expect(board.signalOf(kPriorLostSignal).sum, 0,
          reason: 'a region a blind count got RIGHT was called wrong by the '
              'verifier');
    });

    test('the bar shot verifies the checker a blind count cannot see', () {
      // The flagship, asked the other way round. `the bar shot reports what it
      // read` above prints the blind reading — `expected black x1, read none
      // x0` — and this is the same region of the same photograph asked as a
      // verification. Printed verbatim, whatever it says.
      final bar = board
          .missesOf(CorpusMetric.regionVerified)
          .where((m) => m.startsWith('066 the bar'))
          .toList();
      stdout.writeln('\n  THE BAR SHOT (066), verified against the game:\n'
          '    ${bar.isEmpty ? '066 the bar: agreed — the Black checker on '
              'the worn hinge is where the game says' : bar.single}\n');
      expect(bar, isEmpty,
          reason: 'the state-primed read lost the checker blind occupancy also '
              'loses, which is the one case Task 8 was built for');
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

    test('a session whose shots are one turn apart has its plays identified',
        () {
      // Three shots, two of them one turn apart from their predecessor, so the
      // harness has two plays to identify — which is a thing the committed
      // synthetic corpus cannot ask (its two mid-game positions come from two
      // different playouts) and the real one can only ask six times.
      final board = _scoreFixture(_Fixture.playFollowed);
      expect(board.totalFor(CorpusMetric.legalPlay).attempts, 2);
      expect(board.totalFor(CorpusMetric.legalPlay).rate, 1.0);
      expect(board.targetViolations(), isEmpty, reason: board.report());
      expect(board.totalFor(CorpusMetric.legalPlayActed).rate, 1.0);
    });

    test('and a photograph showing a different play fails the play-ID target',
        () {
      // The discriminator, and the shape of a genuine misidentification: the
      // last shot's sidecar says one legal play was made and its picture shows
      // a different one. If the harness were pairing shots by their position
      // on disk rather than by their logs — or comparing anything other than
      // what the frames actually show — this would score exactly as well as
      // the test above.
      final board = _scoreFixture(_Fixture.playedSomethingElse);
      expect(board.totalFor(CorpusMetric.legalPlay).rate, lessThan(1.0));
      expect(
        board.targetViolations(),
        contains(contains(CorpusMetric.legalPlay.label)),
        reason: board.report(),
      );
      // **And the placement query catches it as well**, which is not noise —
      // it is two instruments agreeing about one planted lie. The last shot's
      // photograph shows a position its sidecar does not, so the play is
      // misidentified AND the position that play should have left behind does
      // not verify on the regions the play claims to have touched. A fixture
      // that reddened one of the two and not the other would mean one of them
      // was not looking at the picture.
      expect(
        board.targetViolations().map((v) => v.split(' scored').first).toSet(),
        <String>{
          'playedSomethingElse: ${CorpusMetric.legalPlay.label}',
          'playedSomethingElse: ${CorpusMetric.placementVerified.label}',
        },
        reason: board.report(),
      );

      // **The resync rows move and do not go red, and that is the reshape
      // working rather than a hole in it.** A misplayed turn is wrong on two
      // or three regions out of the eighty-odd this fixture reads, so a
      // per-region rate barely notices — 0.90 is not a whole-board alarm and
      // was never meant to be one. The whole-board row is what notices, which
      // is exactly why it is still counted after being demoted: it falls off
      // 1.0 and names the shot.
      final resync = board.totalFor(CorpusMetric.boardResynced);
      expect(resync.rate, lessThan(1.0), reason: board.report());
      expect(board.totalFor(CorpusMetric.regionVerified).rate,
          greaterThan(PerceptionTargets.fullBoardResyncPerRegion),
          reason: board.report());
      expect(board.totalFor(CorpusMetric.placementVerifiedBoard).rate,
          lessThan(1.0), reason: board.report());
    });

    test('a fixture whose only fault is the ROLL leaves the board queries '
        'alone', () {
      // The other side of the discriminator above. `wrongRoll` plants a
      // different pair of dice on a board that is otherwise exactly what its
      // sidecar says, and the two board queries must not notice: dice lie in
      // the band between the point triangles, not on any region a game is
      // played on. If they reddened here, they would be reddening on something
      // other than the position.
      final board = _scoreFixture(_Fixture.wrongRoll);
      expect(board.totalFor(CorpusMetric.boardResynced).rate, 1.0,
          reason: board.report());
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
/// **Re-measured three times, and the last one is the one to read.** The
/// 2026-08-21 pass corrected the filmed ledger from a person's reading of
/// zooms; the 2026-08-22 pass corrected that correction from pixels; the
/// 2026-08-23 pass ran the same pixel instruments over the two end-game
/// **keyframes**, which the pixel pass had never re-audited, and found each of
/// them hiding two White men behind the near rim where the sidecar had written
/// `whiteOff: 2`. Superseded floors are kept in the git history rather than
/// here, but the shape of the movement is recorded so that nobody re-derives
/// it: ~~occupancy 192/242, colour 228/242, play 5/5, acted 5/5, placement
/// 1/5, verified 231/260~~ belonged to a truth in which a White checker had
/// left the board, and it had not; ~~colour 222/242, verified 233/260~~
/// belonged to one in which four more had been borne off, and they had not.
/// See `capture_plan.dart`'s `_filmedTurns` and `_filmedKeyframes` for the
/// instruments and the plan doc for the before/after tables. Nothing here was
/// hand-tuned to fit, and floors have moved **down** as often as up.
///
/// The two that miss the spec today, and why they are recorded rather than
/// asserted:
///
/// * **dice pair 0/4.** The reader declines every real roll — it finds no pair
///   at all rather than reading a wrong one. This board's dice are 0.021 of it
///   across against the synthetic bed's 0.075, and the band-location and tilt
///   work that would let a die that small be found is queued, not done.
///
///   **The denominator stayed at four when it was audited, and that is a
///   finding rather than an oversight.** Nine of the ten frames have dice in
///   them; 008's two are settled, unmistakable, and were read at full
///   magnification on 2026-08-23 — and what came back was the near-facing
///   *side* of each die, not the top a roll is read from, which at this
///   distance is 7-8 px deep on a 21 px die. A pair the corpus cannot read is
///   not a pair the corpus may claim, so 008 stays uncertified and joins the
///   five frames scored on neither dice row.
///
/// And one that changed shape rather than value:
///
/// * **no dice in frame, none read: 1/1, from ~~6/6~~.** Same floor, same
///   perfect score, a denominator that now means what the row's sentence says.
///   Five of the old six had dice lying in them, so the row was paying the
///   reader for missing this board's dice and would have gone red the day it
///   stopped. See `CorpusMetric.diceAbsence` and `_scoreDice`. One frame in
///   this session has no dice in it at all, and it is the calibration hold —
///   which is not luck, since a die present at calibration is learned as part
///   of the board.
/// * **region occupancy 0.806** (195/242, from 192/242). Counts on this board
///   run short, worst on tall stacks, exactly as the plan doc's far-half note
///   predicts. The design never trusts a blind count anyway; it is Task 7's
///   play matching that the spec sets a threshold for, and this number is what
///   that was built against.
///
///   **It survived the keyframe correction unchanged, and what happened
///   underneath it is the finding.** The corrected 066 and 070 cost this row
///   the two rim-hidden men on their 1-points, which the reader cannot see —
///   and paid for them with 066's 7-point and 070's, where the reader had been
///   reading *white x2* and *white x3* against a sidecar saying one and two.
///   Two lost, two gained, the rate identical, and the two gained are the
///   pipeline having been right about a cell the ground truth was wrong about:
///   the same shape as the 8-point on 2026-08-22, found the same way.
///
/// And the one that arrived with Task 7 and **passes**:
///
/// * **legal-play identification 6/6.** The query the whole mode turns on, over
///   the windows of the filmed game that are genuinely one turn apart, with the
///   actual legal-move list `backgammon_core` would have offered at each moment
///   (7 to 24 candidates). The denominator went back to six when 018 and 020
///   returned to the replay; **six is still a small denominator** and a floor
///   of 1.0 over it is a ratchet, not a claim that the pipeline is perfect. The
///   number is what the delta design predicts — the counts this corpus reads
///   are biased and the bias cancels, which is why 0.806 per-region counting
///   supports 1.000 play identification, and it now does so over two turns
///   whose moved man the reader **cannot see at all** (see the placement note).
/// * **legal play acted on 4/6, and this row is the one that moved most.** Being
///   right and being acted on are different things: two of the six come back
///   under `PlayMatcher.minConfidence`, so a session would have put the
///   candidate list in front of the user rather than acting. Both are turns
///   with a rim-hidden man in the difference the matcher is reading, and it is
///   worth saying which man, since ~~both are turns whose play lands a man on
///   a near-half point's tip~~ was true of neither end of one of them:
///
///     * **005→008** (`13/11 11/10`, 0.455) is the arriving-man case: the play
///       lands White on the **10-point's base**, against the near rim, and
///       the reader sees nothing of him;
///     * **018→020** (`11/14 14/20*`, 0.457) hides both ends of the hit
///       instead: the man Black moves **leaves** the 11-point's base, which
///       the reader could not see him on at 018 either, and the White man he
///       hits arrives **on the hinge**, which the reader cannot see him on at
///       020. The destination is read — over-read, in fact, at Black 2 for
///       Black 1.
///
///   The evidence for the right answer is thin in both, even though the
///   ranking still finds it. Under the old truth this read 5/5, and that was a
///   rate over turns which had been transcribed onto cells the reader happens
///   to see well. The floor drops with it, and the drop is a finding rather
///   than a regression.
/// And the two that arrived with Task 8, **reshaped by the user at the gate
/// follow-up (2026-08-21)** — one still missing, one that now clears its
/// target:
///
/// * **placement verification 1/6, resync per region 0.904.** The reshape is
///   the denominator and only the denominator — the two thresholds are still
///   0.95 and 0.90. Placement is now the regions the play touched, one attempt
///   per dictated turn; resync is per region, with the whole-board rate kept as
///   a watched row (**0/6 and 0/10**, both still recorded below).
///
///   **Resync per region passes 0.90 for the first time on this corpus**, at
///   0.904 against 0.896 — and not by a pipeline change. The keyframe
///   correction handed it the two 7-point cells it had been contradicting, and
///   it kept the two 1-points because a state-primed read does not need to see
///   a rim-hidden man to decline to contradict him. A floor rising through a
///   truth fix is the same event as a floor falling through one, and it is
///   recorded the same way.
///
///   Per region the prior is doing real work: over the 240 point-reads both
///   rows score, verification is **216/240 = 0.900** against a blind count's
///   **195/240 = 0.813**, twenty-two regions rescued and none lost — the two
///   new rescues being exactly those rim-hidden men on the keyframes' 1-points.
///   (Not the rows' totals — 235/260 against 195/242 — since the verifier asks
///   both ends of the bar on every shot and most of those extra reads are
///   bare-bar agreements. See [priorReport].)
///
///   **The five turns missing are one mechanism plus one stray, and naming the
///   mechanism is the whole value of the truth fix.** Four of the five fail at
///   a **point's BASE** — the wide end against the near edge, where a near-half
///   stack starts (~~a point's tip~~, which is the midline end and is not
///   where any of this happens; corrected 2026-08-23). This folding case's rim
///   stands proud of the felt and a man standing at that base is three quarters
///   behind it. The reader sees nothing there — not a short count, *nothing* —
///   so the 10-point's arriving man (005→008, 010→013), the 1-point's last
///   Black man (008→010) and White's man on the hinge (018→020) are all
///   invisible. The fifth is the **23-point** reading three men for two, an
///   over-count whose run starts on the board's own far rim. None of this was
///   visible while the ledger had those men on cells the camera sees; a corpus
///   that had been quietly flattered is now a corpus that names the one thing
///   this board does to perception.
///
/// * **`region colour alone` reads 220/242 and the floor moved down twice, by a
///   loss rather than a denominator both times.** Same twenty-fifth region as
///   ever (White on the hinge at 020, which the reader does not see), then the
///   rim-hidden men of the ledger's own turns (~~222/242~~), and now the two on
///   the keyframes' 1-points. Every one of them is a checker that **vanishes**
///   rather than one that appears, which is the direction `ColorModel.classify`
///   breaks ties in on purpose — a checker that appears contradicts the game
///   and gets asked about; one that vanishes does not.
const Map<CorpusMetric, double> kRealCorpusFloors = <CorpusMetric, double>{
  CorpusMetric.calibration: 1.0,
  CorpusMetric.startConfirmed: 1.0,
  CorpusMetric.dicePair: 0.0,
  CorpusMetric.diceAbsence: 1.0,
  CorpusMetric.regionOccupancy: 195 / 242,
  CorpusMetric.regionColour: 220 / 242,
  CorpusMetric.legalPlay: 6 / 6,
  CorpusMetric.legalPlayActed: 4 / 6,
  CorpusMetric.placementVerified: 1 / 6,
  CorpusMetric.placementVerifiedBoard: 0.0,
  CorpusMetric.boardResynced: 0.0,
  CorpusMetric.regionVerified: 235 / 260,
};

/// What the SYNTHETIC corpus scored on the whole-board queries when Task 8
/// landed.
///
/// The real corpus has been ratcheted since Task 6 and the synthetic one has
/// not needed it, because everything it is asked it passes against
/// `targets.dart` itself — including, since the gate follow-up reshaped it,
/// resync per region at 0.986 against 0.90. Full-board resync is the row that
/// does not, and now that nothing is promised about it, it gets the same
/// treatment for the same reason: a number that is recorded rather than
/// asserted is a number nobody notices moving. See the test above for why
/// twenty-eight regions at 0.986 apiece cannot make a clean board much more
/// often than this: 0.691 if their misses were independent, 0.733 measured.
///
/// **`regionVerified` moved down by one when the gap bound was derived**, from
/// 829/840 to 828/840, and the floor moved with it deliberately: a lone White
/// man under a lamp on shot 008 now measures 1.75 checkers where a bridged gap
/// joined his run to the shadow beside it. The same trade the real corpus
/// makes, at a twentieth of the size — see `kRealCorpusFloors`.
const Map<CorpusMetric, double> kSyntheticFloors = <CorpusMetric, double>{
  CorpusMetric.boardResynced: 22 / 30,
  CorpusMetric.regionVerified: 828 / 840,
};

/// What knowing the expected position is worth, printed under both corpora.
///
/// **The two per-region rows in the table above do not share a denominator**,
/// so their totals must never be set against each other: `region verified vs
/// game` asks both ends of the bar on every shot, while `region colour and
/// count` scores a bar side only where the game puts men on it — 260 reads
/// against 241 on the real corpus, and the nineteen extra are bare-bar
/// agreements that flatter the verifier by about a point.
///
/// This prints the two comparisons that ARE honest. The **point** slice is the
/// same 240 (or 720) reads on both sides. The **rescued / lost** pair is the
/// same question with no denominator at all: it is computed one `(region,
/// side)` at a time inside a single pass, so every mark is the two instruments
/// answering about the identical read of the identical frame.
String priorReport(Scoreboard board) {
  final vp = board.sliceOf(CorpusMetric.regionVerified, 'region')['point'];
  final bp = board.sliceOf(CorpusMetric.regionOccupancy, 'region')['point'];
  if (vp == null || bp == null) return '';
  final out = StringBuffer()
    ..writeln()
    ..writeln('  what the prior is worth, like for like')
    ..writeln('  ${'the points both rows score'.padRight(30)}'
        '${'n'.padLeft(6)}${'ok'.padLeft(6)}${'rate'.padLeft(8)}')
    ..writeln('  ${'state-primed verification'.padRight(30)}'
        '${vp.attempts.toString().padLeft(6)}'
        '${vp.successes.toString().padLeft(6)}'
        '${vp.rate!.toStringAsFixed(3).padLeft(8)}')
    ..writeln('  ${'a blind count'.padRight(30)}'
        '${bp.attempts.toString().padLeft(6)}'
        '${bp.successes.toString().padLeft(6)}'
        '${bp.rate!.toStringAsFixed(3).padLeft(8)}')
    ..writeln()
    ..writeln('  per region AND side, over all '
        '${board.signalOf(kPriorRescuedSignal).n} reads: '
        '${board.signalOf(kPriorRescuedSignal).sum.round()} rescued from a '
        'blind count, ${board.signalOf(kPriorLostSignal).sum.round()} lost to '
        'it.');
  return (out..writeln('=' * 64)).toString();
}

/// "1 frame" / "5 frames". The dice split is read at the gate, and a report
/// that says "1 frames" is a report somebody stops reading carefully.
String _frames(int n) => '$n frame${n == 1 ? '' : 's'}';

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
    final excluded = board.signalOf(kDiceUncertifiedSignal);
    out
      ..writeln()
      ..writeln('  dice, split three ways: ${pairs.attempts} rolls in the '
          'sidecars, $found found by the reader, ${pairs.successes} read '
          'right, ${pairs.attempts - found} refused outright.')
      ..writeln('  A refusal is the behaviour the design asks for; a wrong '
          'pair would not be.')
      ..writeln('  Beside them: ${_frames(board
              .totalFor(CorpusMetric.diceAbsence)
              .attempts)} with no dice at all (the absence row) and '
          '${_frames(excluded.n)} holding dice with no roll to check a '
          'reading against — scored on neither row, ${excluded.sum.round()} of '
          'those answered anyway.');
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

/// A three-shot corpus of one game, each shot one turn on from the last.
///
/// The shape the legal-play query needs and neither committed corpus has much
/// of: the synthetic one photographs positions from unrelated playouts, and the
/// real one manages six pairs out of ten windows. Ground truth is the game's own
/// event log, so the mover, the candidate list and the play made all come out of
/// `backgammon_core` rather than out of this file.
///
/// Without [honest] the LAST photograph shows a different legal play from the
/// one its sidecar's log records — the same pictures otherwise, so the
/// difference between the two scoreboards is entirely what the frames showed.
Directory _writePlayFixture({required bool honest}) {
  final directory = Directory.systemTemp.createTempSync('corpus_play');
  const conditions = CaptureConditions(
    board: 'fixture board',
    lighting: 'daylight',
    angle: 'straight on',
  );
  const degradation = ShotDegradation(noise: 2, blurSigma: 0.8, seed: 11);
  final quad = jitterQuad(kCameraQuad, 0.8, 11);

  var game = Game.start(const OpeningRollEvent(whiteDie: 6, blackDie: 5));
  final firstPlay = game.state.legalMoves.first;
  game = game.append(MoveEvent(Player.white, firstPlay));
  final afterOne = game;

  game = game.append(RollEvent(Player.black, 3, 1));
  final blacksChoices = game.state.legalMoves;
  final secondPlay = blacksChoices.first;
  // A different resulting position, which is what `legalMoves` guarantees
  // about any two of its entries.
  final somethingElse = blacksChoices.last;
  game = game.append(MoveEvent(Player.black, secondPlay));
  final afterTwo = game;

  CorpusShot shotOf({
    required String id,
    required ShotKind kind,
    required String? calibrateFrom,
    required BoardState board,
    required List<GameEvent>? events,
    BoardQuad? corners,
  }) =>
      CorpusShot(
        id: id,
        session: 'one game',
        kind: kind,
        calibrateFrom: calibrateFrom,
        corners: corners,
        orientation: BoardOrientation.whiteHomeNear,
        board: board,
        events: events,
        dice: null,
        capture: conditions,
        synthetic: null,
        expectRefusal: null,
        refusalReason: null,
        title: 'one game $id',
        instructions: const <String>['fixture'],
      );

  void write(CorpusShot shot, BoardState pictured) {
    File('${directory.path}/${shot.id}.jpg').writeAsBytesSync(
      encodeCorpusJpeg(
        imageOfFrame(
          renderShot(board: pictured, quad: quad, degradation: degradation)
              .frame,
        ),
      ),
    );
    writeSidecar(directory, shot);
  }

  final calibration =
      renderShot(board: BoardState.initial(), quad: quad, degradation: degradation);
  File('${directory.path}/p01.jpg')
      .writeAsBytesSync(encodeCorpusJpeg(imageOfFrame(calibration.frame)));
  writeSidecar(
    directory,
    shotOf(
      id: 'p01',
      kind: ShotKind.calibration,
      calibrateFrom: null,
      board: BoardState.initial(),
      events: null,
      corners: calibration.groundTruthQuad,
    ),
  );

  write(
    shotOf(
      id: 'p02',
      kind: ShotKind.position,
      calibrateFrom: 'p01',
      board: afterOne.state.board,
      events: afterOne.events,
    ),
    afterOne.state.board,
  );

  write(
    shotOf(
      id: 'p03',
      kind: ShotKind.position,
      calibrateFrom: 'p01',
      board: afterTwo.state.board,
      events: afterTwo.events,
    ),
    honest
        ? afterTwo.state.board
        : afterOne.state.board.applyMove(Player.black, somethingElse),
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

  /// Three shots of one game, each one turn on from the last — the shape the
  /// legal-play query needs and the committed synthetic corpus does not have.
  playFollowed,

  /// The same, with the last photograph showing a DIFFERENT legal play from
  /// the one its sidecar's log records. The shape of a misidentification.
  playedSomethingElse,
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
  if (fixture == _Fixture.playFollowed ||
      fixture == _Fixture.playedSomethingElse) {
    return _writePlayFixture(honest: fixture == _Fixture.playFollowed);
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
