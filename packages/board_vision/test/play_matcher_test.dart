import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:test/test.dart';

import 'synthetic/board_renderer.dart';

/// The query the whole product turns on: *which of these legal plays
/// happened?*
///
/// Every other perception question in Buddy Mode has a cheap fallback — a dice
/// pad, a tap-correct on the belief mirror. This one is the mode: if the app
/// cannot tell which of the enumerated plays the user just made, there is no
/// game following.
///
/// ## Why every test here renders TWO frames
///
/// Phase 1 measured the thing this design rests on. Per-region counts on a real
/// board are **biased but frame-stable**: a five-stack on the far half reads
/// short, and it reads short in every frame of the same session (Task 6's
/// scoreboard — 0.784 colour-and-count against 0.954 colour alone, with the
/// misses all in the direction the perspective predicts). So an absolute read
/// of the board after a play is the wrong instrument, and the *difference*
/// between two readings of the same session is the right one: whatever a region
/// is biased by cancels, because it is subtracted from itself.
///
/// That is why the matcher takes the settled frame from **before** the play as
/// well as the one after it, and why every test below renders a pair.
///
/// ## What is asserted, and how strongly
///
/// * **top-1 identification** over seeded turns from real playouts, at the
///   corpus's own degradation, across palettes the pipeline was never told
///   about. Held to the spec's own `legalPlayIdentification`;
/// * **ambiguity honesty** — two plays that reach the same position must come
///   back tied and both plausible. A delta cannot separate them, and a matcher
///   that invented a winner would hand the session a wrong play with a
///   confident face on it;
/// * **"none of these"** — a diff no legal play can produce must leave nothing
///   above the threshold. That is the drift-recovery trigger, and a matcher
///   that always names a best candidate has quietly deleted it.
void main() {
  final scoreboard = _Scoreboard();

  group('which of these legal plays happened', () {
    // Two beds, two seeded games, two palettes, two viewpoints — 64 turns
    // between them, every one a play a real game produced and every one read
    // off a pair of rendered frames at the corpus's own grade.
    for (final plan in _beds) {
      test('${plan.name}: ${plan.turns} seeded turns, told apart by the '
          'change alone', () {
        final bed = _bedOf(plan);
        final turns = _seededTurns(plan.seed, count: plan.turns);
        expect(turns.length, plan.turns);

        for (final turn in turns) {
          final matches = bed.match(turn);
          scoreboard.record(bed: plan.name, turn: turn, matches: matches);
        }
        final tally = scoreboard.byBed[plan.name]!;
        expect(
          tally.top1Rate,
          greaterThanOrEqualTo(PerceptionTargets.legalPlayIdentification),
          reason: 'top-1 fell to ${tally.top1Rate} on ${plan.name}:\n'
              '${scoreboard.missesFor(plan.name).join('\n')}',
        );
      });
    }

    test('the four plays that are not just a checker sliding along', () {
      // Hits, bar entries, bear-offs and doubles are the cases where the
      // expected delta is not simply "one off here, one on there", and each
      // has its own way of going wrong. The seeded games above cover the
      // first, second and fourth by construction — asserted here rather than
      // hoped for — and bear-offs need a position a random opening never
      // reaches, so they get their own bed below.
      final covered = scoreboard.byKind.keys.toSet();
      expect(covered, containsAll(<String>['hit', 'from the bar', 'doubles']));
      for (final kind in <String>['hit', 'from the bar', 'doubles']) {
        expect(scoreboard.byKind[kind]!.n, greaterThan(2), reason: kind);
        expect(
          scoreboard.byKind[kind]!.top1Rate,
          greaterThanOrEqualTo(PerceptionTargets.legalPlayIdentification),
          reason: '$kind: ${scoreboard.byKind[kind]}',
        );
      }
    });

    test('taken together they meet the spec\'s own target', () {
      expect(scoreboard.total.n, greaterThanOrEqualTo(30),
          reason: 'the plan asks for at least thirty seeded turns');
      expect(
        scoreboard.total.top1Rate,
        greaterThanOrEqualTo(PerceptionTargets.legalPlayIdentification),
        reason: scoreboard.missesFor(null).join('\n'),
      );
    });

    test('and the threshold sits under every one of them', () {
      // What `PlayMatcher.minConfidence` is for, checked where the numbers
      // are. The winning candidate must always clear it, or the session would
      // fall back to a prompt on a play it had actually identified.
      expect(scoreboard.worstWinner,
          greaterThan(PlayMatcher.minConfidence));

      // What it is NOT for, said out loud so nobody later "fixes" it. The best
      // RIVAL — a legal play differing by one hop, scored on regions the
      // reader was unsure of — clears the threshold too, and on this bed it
      // reaches 0.562 against the real corpus's worst correct answer of 0.542.
      // Those bands overlap, so telling two legal plays apart is the ranking's
      // job. The threshold's job is the diffs no legal play produced at all,
      // which score 0.16 to 0.25 — see 'none of these'.
      expect(scoreboard.bestRival, lessThan(scoreboard.worstWinner));
    });

    tearDownAll(scoreboard.report);
  });

  group('a hit is a checker going to the bar, not a checker vanishing', () {
    test('the hit is identified, and the bar is part of why', () {
      // The one play whose expected delta touches three regions at once: the
      // point the man left, the point it landed on (whose colour FLIPS), and
      // the bar the blot it hit is now standing on.
      //
      // The second half of this test is what makes the bar load-bearing rather
      // than decorative. The same landing-point evidence is present in both
      // frames-pairs; the only difference is whether the blot turns up on the
      // bar or simply ceases to exist. A matcher that routed hits nowhere
      // would score the two identically.
      final bed = _bedOf(_beds.first);
      final before = _blotOnTheSeven;
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(6, 3));
      final hit = legal.firstWhere(
        (m) => m.checkerMoves.any((h) => h.to == 6 && h.isHit),
        orElse: () => throw StateError('no hit in $legal'),
      );

      final honest = before.applyMove(Player.white, hit);
      expect(honest.blackBar, before.blackBar + 1);
      final matches = bed.matchBoards(before, honest, Player.white, legal);
      expect(matches.first.play.sameAs(hit), isTrue, reason: '$matches');
      expect(matches.first.plausible, isTrue);

      // The same play, with the blot gone from the board altogether instead of
      // standing on the bar. Nothing else about the picture changes.
      final impossible = BoardState(
        points: honest.points,
        whiteBar: honest.whiteBar,
        blackBar: before.blackBar,
        whiteOff: honest.whiteOff,
        blackOff: honest.blackOff,
      );
      final vanished =
          bed.matchBoards(before, impossible, Player.white, legal);
      final claimed = vanished.firstWhere((m) => m.play.sameAs(hit));
      expect(
        claimed.confidence,
        lessThan(matches.first.confidence),
        reason: 'the bar contributed nothing: the hit scored the same whether '
            'the blot arrived on the bar or evaporated',
      );
    });

    test('a checker coming in off the bar is identified', () {
      final bed = _bedOf(_beds.first);
      final before = _whiteOnTheBar;
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(5, 4));
      expect(legal, isNotEmpty);
      final entry = legal.firstWhere(
        (m) => m.checkerMoves.any((h) => h.from == CheckerMove.bar),
      );
      final matches = bed.matchBoards(
        before,
        before.applyMove(Player.white, entry),
        Player.white,
        legal,
      );
      expect(matches.first.play.sameAs(entry), isTrue, reason: '$matches');
      expect(matches.first.plausible, isTrue);
    });
  });

  group('bearing off, on a board with wells and on one without', () {
    test('a bear-off is identified from the tray it filled', () {
      final bed = _bedOf(_beds.first);
      final before = _bearingOff;
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(6, 5));
      final borne = legal.firstWhere(
        (m) => m.checkerMoves.every((h) => h.to == CheckerMove.off),
      );
      final matches = bed.matchBoards(
        before,
        before.applyMove(Player.white, borne),
        Player.white,
        legal,
      );
      expect(matches.first.play.sameAs(borne), isTrue, reason: '$matches');
      expect(matches.first.plausible, isTrue);
      expect(matches.first.unobservable, isEmpty,
          reason: 'this board has wells, so the tray IS observable');
    });

    test('on a folding case a bear-off is the checker LEAVING, and the '
        'matcher says the tray could not be seen', () {
      // A folding case has no bear-off wells at all: a borne-off checker
      // leaves the board and there is nothing in the picture to count. The
      // evidence is therefore entirely count-by-absence — the point that lost
      // a man — and the matcher has to say out loud that the region its
      // expected delta wanted is not one this board has, rather than scoring a
      // region that does not exist or quietly pretending the play left no
      // trace.
      final bed = _bedOf(_foldingBed);
      final before = _bearingOff;
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(6, 5));
      final borne = legal.firstWhere(
        (m) => m.checkerMoves.every((h) => h.to == CheckerMove.off),
      );
      final matches = bed.matchBoards(
        before,
        before.applyMove(Player.white, borne),
        Player.white,
        legal,
      );
      expect(matches.first.play.sameAs(borne), isTrue, reason: '$matches');
      expect(matches.first.plausible, isTrue);
      expect(matches.first.unobservable, contains(RoiId.offWhite));
    });
  });

  group('hop order is the submitter\'s business', () {
    // `BoardState.applyMove` is order-dependent for a hit — it reads the
    // landing point's count off the board as it stands at that moment — and
    // `GameState.canonicalPlay` exists in `backgammon_core` precisely so that
    // a submitted order is never applied. This matcher applies a candidate to
    // work out what it would have left behind, so it inherits that hazard, and
    // its input is an arbitrary `List<Move>` rather than something it
    // generated.
    //
    // Neither `legalMoves` nor `legalVariants` emits an unplayable order, so
    // nothing in the app reaches this today. A replayed log, a remote peer, or
    // a session that reassembles hops from a tap-by-tap correction all can.
    test('a hit listed after the hop that depends on it still lands on the '
        'right board', () {
      final bed = _bedOf(_beds.first);
      final before = _blotOnTheEleven;
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(2, 5));
      final canonical = legal.firstWhere(
        (m) =>
            m.checkerMoves.any((h) => h.from == 12 && h.to == 10) &&
            m.checkerMoves.any((h) => h.from == 10 && h.to == 5),
        orElse: () => throw StateError('13/11* 11/6 is not legal here: $legal'),
      );
      final sound = before.applyMove(Player.white, canonical);
      expect(sound.blackBar, 1, reason: 'the bed must contain a real hit');

      // The same hop multiset with the two hops the other way round. Applied
      // in this order a checker leaves the 11 before the hit puts one there:
      // the blot is decremented to a phantom SECOND black checker, no man
      // reaches the bar, and the board that comes out belongs to no game.
      final misOrdered = Move(<CheckerMove>[
        const CheckerMove(10, 5),
        const CheckerMove(12, 10, isHit: true),
      ]);
      expect(misOrdered.sameAs(canonical), isTrue,
          reason: 'the same play, written the other way round');

      final matches = bed.matchBoards(
        before,
        sound,
        Player.white,
        // Listed FIRST, so `_distinct` keeps this one and drops the canonical.
        <Move>[misOrdered, ...legal],
      );
      expect(matches.length, legal.length, reason: 'the two are one play');

      final top = matches.first;
      expect(top.play.sameAs(canonical), isTrue, reason: '$matches');
      expect(top.after, sound,
          reason: 'the submitted order was applied as given, and the board it '
              'produced is not one any game can reach');
      expect(top.after.checkerCount(Player.white), 15);
      expect(top.after.checkerCount(Player.black), 15);
      expect(top.plausible, isTrue);
    });

    test('a hop multiset no order can play is not a candidate at all', () {
      // The other half: not a bad ORDER but a play this board cannot take in
      // any order — here a checker lifted off a point that is empty. There is
      // no position it would have left behind, so there is nothing to score it
      // against, and it comes back as nothing rather than as a candidate with
      // an invented board under it.
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(5, 3));
      final fromNowhere = Move(const <CheckerMove>[CheckerMove(3, 0)]);
      expect(before.points[3], 0, reason: 'the 4-point must be bare');

      final matches = bed.matchBoards(
        before,
        before.applyMove(Player.white, legal.first),
        Player.white,
        <Move>[fromNowhere, ...legal],
      );
      expect(matches.length, legal.length);
      expect(matches.any((m) => m.play.sameAs(fromNowhere)), isFalse,
          reason: '$matches');
    });
  });

  group('the plays a difference cannot tell apart', () {
    test('two transits of the same play come back tied, and both plausible',
        () {
      // The plan's own example. `MoveGenerator.legalMoves` already dedupes by
      // RESULTING POSITION, so this pair never arrives from that door — it is
      // `legalVariants`' decompositions that carry it, and a session that
      // wants to name the transit a user actually used is exactly the caller
      // that would pass them. Whichever door they come through, a difference
      // between two frames cannot separate them: the board they leave behind
      // is the same board.
      final bed = _bedOf(_beds.first);
      final before = _twoWaysToTheNine;
      final variants =
          MoveGenerator.legalVariants(before, Player.white, Dice(3, 1));
      final target = before
          .applyMove(Player.white, Move(const <CheckerMove>[CheckerMove(12, 9)]))
          .applyMove(Player.white, Move(const <CheckerMove>[CheckerMove(9, 8)]));
      final ambiguous = variants.firstWhere(
        (v) => before.applyMove(Player.white, v.canonical) == target,
        orElse: () => throw StateError('13/9 is not legal here'),
      );
      expect(ambiguous.decompositions.length, 2,
          reason: 'the bed is wrong: ${ambiguous.decompositions}');

      final candidates = <Move>[
        for (final v in variants)
          if (identical(v, ambiguous))
            ...v.decompositions
          else
            v.canonical,
      ];
      final matches =
          bed.matchBoards(before, target, Player.white, candidates);

      final tied = matches.takeWhile((m) => m.plausible).toList();
      expect(tied.length, greaterThanOrEqualTo(2),
          reason: 'one of two indistinguishable plays was crowned: $matches');
      expect(tied[0].confidence, closeTo(tied[1].confidence, 1e-12));
      expect(tied[0].isAmbiguous, isTrue);
      expect(tied[0].tiedWith.single.sameAs(tied[1].play), isTrue);
      expect(tied[1].tiedWith.single.sameAs(tied[0].play), isTrue);
      for (final m in tied) {
        expect(
          ambiguous.decompositions.any((d) => d.sameAs(m.play)),
          isTrue,
          reason: '${m.play} is not one of the two transits',
        );
      }
    });

    test('the same play listed twice in a different order is one candidate',
        () {
      // `Move.sameAs` is order-insensitive by construction, so `13/8 8/5` and
      // `8/5 13/8` are one play written two ways — NOT an ambiguity. Reporting
      // them as two would put a disambiguation prompt in front of the user
      // asking which of two identical sentences they meant.
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(5, 3));
      final played = legal.first;
      final reversed = Move(played.checkerMoves.reversed.toList());
      expect(played.sameAs(reversed), isTrue);

      final matches = bed.matchBoards(
        before,
        before.applyMove(Player.white, played),
        Player.white,
        <Move>[played, reversed, ...legal.skip(1)],
      );
      expect(matches.length, legal.length);
      expect(matches.first.isAmbiguous, isFalse, reason: '$matches');
    });
  });

  group('none of these', () {
    test('a checker that teleported matches nothing', () {
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(5, 3));
      // White moves toward index 0. This takes a man BACKWARDS from the
      // 13-point to the 15-point, which no roll of any dice can do.
      final teleported = BoardState(points: <int>[
        for (final (i, c) in before.points.indexed)
          i == 12
              ? c - 1
              : i == 14
                  ? c + 1
                  : c,
      ]);
      final matches =
          bed.matchBoards(before, teleported, Player.white, legal);
      expect(matches, isNotEmpty);
      expect(matches.any((m) => m.plausible), isFalse,
          reason: 'a diff no legal play can produce was called a play: '
              '${matches.first}');
    });

    test('a play run BACKWARDS matches nothing, which is what the sign of a '
        'delta is for', () {
      // The sharpest form of the impossible diff, and the one test in this
      // file that pins the deltas being SIGNED rather than merely sized.
      //
      // The board here is the exact reverse of the legal play `13/7 6/5`: two
      // White checkers have run the wrong way, along the very four regions
      // that play touches and by the very amounts it moves. A matcher scoring
      // |observed| against |expected| — which is an easy thing to write and
      // passes the whole seeded matrix, measured — sees four perfect matches,
      // costs nothing, and hands the session a play at full confidence that
      // the board flatly contradicts.
      //
      // A picture like this is not a curiosity. It is what a user tidying the
      // board, or undoing a move they had second thoughts about, produces.
      final bed = _bedOf(_beds.first);
      final before = _blotsToRunBackFrom;
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(6, 1));
      final forwards = legal.firstWhere(
        (m) => m.checkerMoves.length == 2 &&
            m.checkerMoves.any((h) => h.from == 12 && h.to == 6) &&
            m.checkerMoves.any((h) => h.from == 5 && h.to == 4),
        orElse: () => throw StateError('13/7 6/5 is not legal here: $legal'),
      );
      // Every region that play touches, moved by the same amount the other
      // way.
      final backwards = BoardState(points: <int>[
        for (final (i, c) in before.points.indexed)
          switch (i) { 12 => c + 1, 6 => c - 1, 5 => c + 1, 4 => c - 1, _ => c },
      ]);
      expect(backwards, isNot(before.applyMove(Player.white, forwards)));

      final matches = bed.matchBoards(before, backwards, Player.white, legal);
      expect(matches.any((m) => m.plausible), isFalse,
          reason: 'checkers that ran backwards were read as a play: '
              '${matches.first}');
    });

    test('the other player moving matches nothing', () {
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final white = MoveGenerator.legalMoves(before, Player.white, Dice(5, 3));
      final black = MoveGenerator.legalMoves(before, Player.black, Dice(5, 3));
      final matches = bed.matchBoards(
        before,
        before.applyMove(Player.black, black.first),
        Player.white,
        white,
      );
      expect(matches.any((m) => m.plausible), isFalse,
          reason: 'Black\'s move was read as one of White\'s: '
              '${matches.first}');
    });

    test('a board that did not change at all matches no play that moves '
        'anything', () {
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(5, 3));
      final matches = bed.matchBoards(before, before, Player.white, legal);
      expect(matches.any((m) => m.plausible), isFalse,
          reason: 'a player who has not touched the board yet was credited '
              'with a play: ${matches.first}');
    });
  });

  group('the contract at the edges', () {
    test('no candidates in, no candidates out — a dance is the session\'s '
        'business, not the matcher\'s', () {
      // `legalPlays` empty is the rules engine saying the mover has no play.
      // There is nothing for perception to identify and nothing to look at the
      // board about, so this answers with the empty list rather than inventing
      // a "the board did not change" verdict: the session announces the dance
      // and passes the turn, exactly as the digital game does.
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      expect(
        bed.matchBoards(before, before, Player.white, const <Move>[]),
        isEmpty,
      );
    });

    test('an explicit no-play candidate is matched by a board that did not '
        'move', () {
      // The other half of the same contract: a caller that puts `Move.none` in
      // the list is asking "did nothing happen?", and that IS answerable from
      // two frames.
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final matches =
          bed.matchBoards(before, before, Player.white, <Move>[Move.none]);
      expect(matches.single.play.checkerMoves, isEmpty);
      expect(matches.single.plausible, isTrue);
    });

    test('the ranking is by confidence, best first, and stable in the '
        'candidate order', () {
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(6, 5));
      final matches = bed.matchBoards(
        before,
        before.applyMove(Player.white, legal[2]),
        Player.white,
        legal,
      );
      expect(matches.length, legal.length);
      for (var i = 1; i < matches.length; i++) {
        expect(matches[i - 1].confidence,
            greaterThanOrEqualTo(matches[i].confidence));
      }
      // Every candidate comes back, whether or not it is plausible: the
      // session's disambiguation prompt is drawn from this list and the drift
      // path needs to see what the runners-up were.
      expect(
        matches.map((m) => m.play).toSet().length,
        legal.length,
      );
    });

    test('the two frames are each read in their own light', () {
      // A live preview's auto-exposure drifts between two frames of the same
      // scene by enough to turn every empty point into a phantom checker — and
      // a phantom on one side of a subtraction is a play that never happened.
      // Each side of the difference has to take its own exposure, which is what
      // going through `OccupancyReader` (and so through
      // `BoardCalibration.colorsIn`) buys.
      //
      // Measured on this bed, walking the pair apart: a 35% swing between the
      // two frames (0.85 to 1.15) still costs the winning candidate NOTHING —
      // cost 0.00, confidence 1.000. It breaks at 56% (0.8 to 1.25), where the
      // classic palette's white checkers begin to clip against its pale points
      // — a colour-model limit `occupancy_test` already pins, not a matcher
      // one. What matters there is the second half of this test: at the swing
      // that loses the play, nothing is offered as an answer.
      final bed = _bedOf(_beds.first);
      final before = BoardState.initial();
      final legal = MoveGenerator.legalMoves(before, Player.white, Dice(6, 5));
      final played = legal.first;

      List<PlayMatch> through(double dim, double bright) =>
          bed.vision.matchLegalPlay(
            bed.frameOf(before.applyMove(Player.white, played), gain: bright),
            before,
            Player.white,
            legal,
            beforeFrame: bed.frameOf(before, gain: dim),
          );

      final drifted = through(0.85, 1.15);
      expect(drifted.first.play.sameAs(played), isTrue, reason: '$drifted');
      expect(drifted.first.plausible, isTrue);

      // Past what the colours survive, the answer may be wrong — but it may
      // not be wrong AND confident, because a confident wrong play goes into
      // the authoritative game state and stays there.
      final past = through(0.8, 1.25);
      expect(
        past.first.play.sameAs(played) || !past.first.plausible,
        isTrue,
        reason: 'a play the light had already destroyed was offered as an '
            'answer: ${past.first}',
      );
    });
  });
}

// --- the beds ---------------------------------------------------------------

/// One synthetic session: a palette, a viewpoint, a board shape, and the seed
/// of the game played on it.
typedef _BedPlan = ({
  String name,
  BoardPalette palette,
  BoardQuad quad,
  BoardProportions proportions,
  int seed,
  int turns,
});

/// The two seeded games the matrix is measured on.
///
/// Seeds picked for coverage rather than for scores, and checked before a line
/// of the matcher existed: both games play out 32 half-turns with no dance in
/// them (a dance has no candidates, so it is not a turn this can be scored on),
/// and between them they carry 36 hitting hops over 29 turns, 35 checkers
/// coming in off the bar over 30, and 7 rolls of doubles. A random opening
/// never reaches a bear-off; those have their own beds below, one board with
/// wells and one without.
const List<_BedPlan> _beds = <_BedPlan>[
  (
    name: 'classic, steep',
    palette: BoardPalette.classic,
    quad: kCorpusSteepQuad,
    proportions: BoardProportions.standard,
    seed: 36,
    turns: 32,
  ),
  (
    name: 'low-contrast wood, low and rolled',
    palette: BoardPalette.lowContrastWood,
    quad: kCorpusLowQuad,
    proportions: BoardProportions.standard,
    seed: 12,
    turns: 32,
  ),
];

/// A folding case: no bear-off wells, a hinge for a bar. The shape the real
/// corpus is shot on.
const _BedPlan _foldingBed = (
  name: 'folding case',
  palette: BoardPalette.lowContrastWood,
  quad: kCorpusSteepQuad,
  proportions: BoardProportions(trayWidth: 0, barWidth: 0.03),
  seed: 0,
  turns: 0,
);

/// What the corpus does to every synthetic shot, minus the per-session quad
/// jitter (which is deterministic in the seed, so every frame of one bed lands
/// on the same board — a board does not move between two settled frames).
const ShotDegradation _corpusGrade =
    ShotDegradation(noise: 2, blurSigma: 0.5, seed: 4242);

/// The beds, built once each.
///
/// A bed costs a render and a calibration, and a dozen small tests all want the
/// same one — a real session calibrates once too, so sharing it is what the
/// tests are supposed to be doing anyway.
final Map<String, _Bed> _built = <String, _Bed>{};

_Bed _bedOf(_BedPlan plan) => _built.putIfAbsent(plan.name, () => _Bed(plan));

/// One Buddy session on the synthetic bed.
///
/// Calibrated once from the starting position, exactly as a real session is,
/// and then asked about pairs of later frames. Frames are cached by position:
/// consecutive turns share a board, so a game of N turns costs N+1 renders
/// rather than 2N.
class _Bed {
  final _BedPlan plan;
  late final BoardVision vision;
  final Map<(BoardState, double), Frame> _frames =
      <(BoardState, double), Frame>{};

  _Bed(this.plan) {
    final start = _render(BoardState.initial(), 1.0);
    final result = BoardVision.calibrate(
      frame: start.frame,
      corners: start.groundTruthQuad,
      orientation: BoardOrientation.whiteHomeNear,
      proportions: plan.proportions,
    );
    expect(result.ok, isTrue, reason: '${plan.name}: ${result.message}');
    vision = BoardVision(result.calibration!);
    _frames[(BoardState.initial(), 1.0)] = start.frame;
  }

  Frame frameOf(BoardState board, {double gain = 1.0}) =>
      _frames.putIfAbsent((board, gain), () => _render(board, gain).frame);

  List<PlayMatch> match(_Turn turn) =>
      matchBoards(turn.before, turn.after, turn.mover, turn.legal);

  List<PlayMatch> matchBoards(
    BoardState before,
    BoardState after,
    Player mover,
    List<Move> legal,
  ) =>
      vision.matchLegalPlay(
        frameOf(after),
        before,
        mover,
        legal,
        beforeFrame: frameOf(before),
      );

  SyntheticShot _render(BoardState board, double gain) => renderShot(
        // A board with no wells has nowhere to draw a borne-off checker, and
        // the renderer refuses one — which is the picture being honest: on
        // such a board those men have left it.
        board: plan.proportions.hasTrays ? board : _onFelt(board),
        palette: plan.palette,
        lightingGain: gain,
        proportions: plan.proportions,
        quad: plan.quad,
        degradation: _corpusGrade,
      );
}

BoardState _onFelt(BoardState board) => BoardState(
      points: board.points,
      whiteBar: board.whiteBar,
      blackBar: board.blackBar,
    );

// --- seeded games -----------------------------------------------------------

/// One half-turn of a seeded game: the board before it, what the rules allowed,
/// what was played, and the board after.
typedef _Turn = ({
  BoardState before,
  BoardState after,
  Player mover,
  Dice dice,
  List<Move> legal,
  Move played,
});

/// [count] half-turns of a real game, played by rolling and choosing legally
/// through `backgammon_core`.
///
/// Ground truth by construction, the same way the corpus's own positions are:
/// nothing here is a hand-invented pile of checkers, so a play the matcher is
/// asked to identify is a play a game can actually produce, together with the
/// exact set of rivals the app would hand it at that moment.
List<_Turn> _seededTurns(int seed, {required int count}) {
  final rng = math.Random(seed);
  int die() => rng.nextInt(6) + 1;
  var whiteDie = die(), blackDie = die();
  while (whiteDie == blackDie) {
    whiteDie = die();
    blackDie = die();
  }
  var game = Game.start(
    OpeningRollEvent(whiteDie: whiteDie, blackDie: blackDie),
  );
  final turns = <_Turn>[];
  while (turns.length < count && game.state.phase != GamePhase.gameOver) {
    if (game.state.phase == GamePhase.awaitingRoll) {
      game = game.append(RollEvent(game.state.turn, die(), die()));
      continue;
    }
    final legal = game.state.legalMoves;
    final mover = game.state.turn;
    final before = game.state.board;
    final dice = game.state.dice!;
    if (legal.isEmpty) {
      // A dance has no candidates; the session announces it and passes, and
      // there is nothing for the matcher to be scored on.
      game = game.append(MoveEvent(mover, Move.none));
      continue;
    }
    final played = legal[rng.nextInt(legal.length)];
    game = game.append(MoveEvent(mover, played));
    turns.add((
      before: before,
      after: game.state.board,
      mover: mover,
      dice: dice,
      legal: legal,
      played: played,
    ));
  }
  return turns;
}

// --- the positions the seeded games never reach -----------------------------

/// A Black blot standing on White's 7-point, with White able to hit it.
final BoardState _blotOnTheSeven = BoardState(points: const <int>[
  0, 0, 0, 0, 0, 5, //  1-6
  -1, 3, 0, 0, 0, -4, //  7-12   Black's lone man on the 7
  5, 0, 0, 0, -3, 0, // 13-18
  -5, 0, 0, 0, 0, 2, // 19-24
], blackBar: 2);

/// White on the bar, with the entry points open.
final BoardState _whiteOnTheBar = BoardState(points: const <int>[
  -2, 0, 0, 0, 0, 5, //  1-6
  0, 3, 0, 0, 0, -5, //  7-12
  5, 0, 0, 0, -3, 0, // 13-18
  -5, 0, 0, 0, 0, 1, // 19-24
], whiteBar: 1);

/// White home and bearing off, Black still running.
final BoardState _bearingOff = BoardState(points: const <int>[
  3, 2, 3, 2, 3, 2, //  1-6    fifteen White, all home
  0, 0, 0, 0, 0, 0, //  7-12
  0, 0, 0, -3, -3, -3, // 13-18
  -3, -3, 0, 0, 0, 0, // 19-24
]);

/// A Black blot standing on White's 11-point, where a 2-5 can hit it and run
/// on with the same checker — so the play's two hops only work in one order.
final BoardState _blotOnTheEleven = BoardState(points: const <int>[
  -2, 0, 0, 0, 0, 5, //  1-6
  0, 3, 0, 0, -1, -4, //  7-12   one Black man forward off the 12
  5, 0, 0, 0, -3, 0, // 13-18
  -5, 0, 0, 0, 0, 2, // 19-24
]);

/// The starting position with a White blot on the 5-point and another on the
/// 7-point, so that the legal 6-1 play `13/7 6/5` has somewhere to be run
/// backwards FROM as well as to.
final BoardState _blotsToRunBackFrom = BoardState(points: const <int>[
  -2, 0, 0, 0, 1, 3, //  1-6    one off the 6-point onto the 5
  1, 3, 0, 0, 0, -5, //  7-12   and one more standing on the 7
  5, 0, 0, 0, -3, 0, // 13-18
  -5, 0, 0, 0, 0, 2, // 19-24
]);

/// Two ways for one White checker to reach the 9-point with a 3-1: through the
/// 10 or through the 12, both of them empty.
final BoardState _twoWaysToTheNine = BoardState(points: const <int>[
  0, 0, 0, 0, 2, 3, //  1-6
  0, 3, 0, 0, 0, 0, //  7-12   the 10 and the 12 are both open
  5, 0, 0, 0, -3, -3, // 13-18
  -3, -3, 2, -3, 0, 0, // 19-24
]);

// --- the scoreboard ---------------------------------------------------------

/// Top-1 identification, sliced the ways the plan asks about.
class _Scoreboard {
  final Map<String, _Tally> byBed = <String, _Tally>{};
  final Map<String, _Tally> byKind = <String, _Tally>{};
  final Map<String, _Tally> byCandidateCount = <String, _Tally>{};
  final _Tally total = _Tally();
  final List<(String, String)> misses = <(String, String)>[];

  /// The worst the winning candidate ever scored, and the best any candidate
  /// reaching a DIFFERENT position ever scored.
  ///
  /// The gap between the two is what [PlayMatcher.minConfidence] has to sit in,
  /// and printing it is how the threshold stops being a number somebody picked.
  double worstWinner = 1;
  double bestRival = 0;

  void record({
    required String bed,
    required _Turn turn,
    required List<PlayMatch> matches,
  }) {
    // **Right means the right POSITION**, which is what the game means by a
    // move (`GameState.play` folds any decomposition through `canonicalPlay`)
    // and the only thing two settled frames can say — an intermediate transit
    // leaves no trace in either of them. The seeded plays here are drawn from
    // `legalMoves`, which already dedupes by position, so the two criteria
    // agree on this bed; on the real corpus they do not, and the harness
    // records why.
    final target = turn.before.applyMove(turn.mover, turn.played);
    final top = matches.first;
    final right = top.after == target;
    final tallies = <_Tally>[
      total,
      byBed.putIfAbsent(bed, _Tally.new),
      byCandidateCount.putIfAbsent(_bucket(turn.legal.length), _Tally.new),
      for (final kind in _kindsOf(turn)) byKind.putIfAbsent(kind, _Tally.new),
    ];
    for (final tally in tallies) {
      tally.add(
        right: right,
        plausible: top.plausible,
        ambiguous: top.isAmbiguous,
      );
    }
    for (final match in matches) {
      if (match.after == target) {
        worstWinner = math.min(worstWinner, match.confidence);
      } else {
        bestRival = math.max(bestRival, match.confidence);
      }
    }
    if (!right) {
      final rank = matches.indexWhere((m) => m.after == target);
      misses.add((
        bed,
        '${turn.mover.name} ${turn.dice}: played ${turn.played}, '
            'ranked ${rank + 1} of ${matches.length}; '
            'top was ${top.play} at ${top.confidence.toStringAsFixed(3)}',
      ));
    }
  }

  List<String> missesFor(String? bed) => <String>[
        for (final (where, what) in misses)
          if (bed == null || where == bed) '  $where — $what',
      ];

  static String _bucket(int candidates) => candidates <= 4
      ? 'up to 4 candidates'
      : candidates <= 15
          ? '5 to 15 candidates'
          : 'over 15 candidates';

  static List<String> _kindsOf(_Turn turn) => <String>[
        if (turn.dice.isDouble) 'doubles',
        if (turn.played.checkerMoves.any((h) => h.isHit)) 'hit',
        if (turn.played.checkerMoves.any((h) => h.from == CheckerMove.bar))
          'from the bar',
        if (turn.played.checkerMoves.any((h) => h.to == CheckerMove.off))
          'bearing off',
        if (turn.played.checkerMoves.every(
          (h) => !h.isHit && h.from != CheckerMove.bar && h.to != CheckerMove.off,
        ))
          'a plain move',
      ];

  void report() {
    final lines = <String>[
      '',
      'legal-play identification, on the synthetic bed:',
    ];
    void section(String title, Map<String, _Tally> rows) {
      lines.add('  $title');
      for (final key in rows.keys.toList()..sort()) {
        lines.add('    ${key.padRight(30)} ${rows[key]}');
      }
    }

    section('by bed', byBed);
    section('by what kind of play', byKind);
    section('by how many rivals', byCandidateCount);
    lines
      ..add('  overall')
      ..add('    ${'all turns'.padRight(30)} $total')
      ..add('    spec target: '
          '${PerceptionTargets.legalPlayIdentification.toStringAsFixed(3)}')
      ..add('  the gap the threshold sits in')
      ..add('    ${'worst winning candidate'.padRight(30)} '
          '${worstWinner.toStringAsFixed(3)}')
      ..add('    ${'best candidate reaching another position'.padRight(30)} '
          '${bestRival.toStringAsFixed(3)}')
      ..add('    ${'PlayMatcher.minConfidence'.padRight(30)} '
          '${PlayMatcher.minConfidence.toStringAsFixed(3)}');
    if (misses.isNotEmpty) {
      lines
        ..add('  what missed')
        ..addAll(missesFor(null));
    }
    // ignore: avoid_print
    print(lines.join('\n'));
  }
}

class _Tally {
  int n = 0, right = 0, plausible = 0, ambiguous = 0;

  void add({
    required bool right,
    required bool plausible,
    required bool ambiguous,
  }) {
    n++;
    if (right) this.right++;
    if (plausible) this.plausible++;
    if (ambiguous) this.ambiguous++;
  }

  double get top1Rate => n == 0 ? 0 : right / n;

  String _pc(int hit) =>
      n == 0 ? '   -  ' : '${(100 * hit / n).toStringAsFixed(1)}%';

  @override
  String toString() => 'n=${n.toString().padLeft(4)}  top-1 ${_pc(right)}  '
      'above threshold ${_pc(plausible)}  tied ${_pc(ambiguous)}';
}
