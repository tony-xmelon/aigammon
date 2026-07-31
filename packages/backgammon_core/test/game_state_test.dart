import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  GameState fresh() =>
      GameState.opening(firstPlayer: Player.white, openingDice: Dice(3, 1));

  test('opening state is ready to move with the opening dice', () {
    final s = fresh();
    expect(s.turn, Player.white);
    expect(s.phase, GamePhase.moving);
    expect(s.dice, Dice(3, 1));
    expect(s.cube.value, 1);
    expect(s.cube.owner, isNull);
  });

  test('playing a legal move passes the turn', () {
    final s = fresh()
        .play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]));
    expect(s.turn, Player.black);
    expect(s.phase, GamePhase.awaitingRoll);
    expect(s.dice, isNull);
    expect(s.board.points[4], 2);
  });

  test('illegal moves throw', () {
    expect(() => fresh().play(Move(const [CheckerMove(23, 20)])),
        throwsStateError); // one hop when two dice are playable
  });

  test('a transit-equivalent decomposition of a legal move is accepted', () {
    // 24/20 with 3-then-1 vs 1-then-3: the generator keeps one
    // representative; play() must accept the other decomposition too
    // because it reaches the same position.
    final viaA = Move(const [CheckerMove(23, 20), CheckerMove(20, 19)]);
    final viaB = Move(const [CheckerMove(23, 22), CheckerMove(22, 19)]);
    final a = fresh().play(viaA);
    final b = fresh().play(viaB);
    expect(a.board, b.board);
    expect(a.phase, GamePhase.awaitingRoll);
  });

  group('canonicalPlay', () {
    test('resolves every accepted submission to the generator\'s move', () {
      final s = fresh();
      final generated = s.legalMoves.map((m) => m.toString());
      final viaA = s.canonicalPlay(
          Move(const [CheckerMove(23, 20), CheckerMove(20, 19)]))!;
      // The other decomposition of the same 24/20 play.
      final viaB = s.canonicalPlay(
          Move(const [CheckerMove(23, 22), CheckerMove(22, 19)]))!;
      expect(generated, contains(viaA.toString()),
          reason: 'the answer is a move the generator itself produced');
      expect(generated, contains(viaB.toString()));
      expect(s.board.applyMove(Player.white, viaA),
          s.board.applyMove(Player.white, viaB));
      // Hop ORDER is the submitter's business.
      expect(
          s
              .canonicalPlay(
                  Move(const [CheckerMove(5, 4), CheckerMove(7, 4)]))!
              .sameAs(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
          isTrue);
    });

    test('accepts a transit chain whose hops arrive in reverse order', () {
      // 24/20 entered as the transit chain 24/23, 23/20 — but submitted with
      // the hops the other way round. Hop ORDER is the submitter's business
      // (a remote peer or a replayed log may order them however it likes),
      // and normalising must happen BEFORE the board is asked to apply
      // anything: [BoardState.applyMove] is order-dependent for a checker
      // transiting a point, so applying the submission as given either throws
      // or lands on a board that belongs to no legal move at all.
      final s = fresh();
      // The NON-representative decomposition of 24/20 (24/21 then 21/20), so
      // the multiset check above cannot answer it and the transit fallback has
      // to.
      final forwards =
          Move(const [CheckerMove(23, 20), CheckerMove(20, 19)]);
      final backwards =
          Move(const [CheckerMove(20, 19), CheckerMove(23, 20)]);
      final canonical = s.canonicalPlay(backwards);
      expect(canonical, isNotNull,
          reason: 'the same hop multiset, merely listed in another order');
      expect(s.legalMoves.map((m) => m.toString()),
          contains(canonical!.toString()));
      expect(s.board.applyMove(Player.white, canonical),
          s.board.applyMove(Player.white, s.canonicalPlay(forwards)!));
      // And it plays, rather than throwing out of applyMove.
      expect(s.play(backwards).board, s.play(forwards).board);
    });

    test('answers null for anything illegal', () {
      final s = fresh();
      expect(s.canonicalPlay(Move(const [CheckerMove(23, 20)])), isNull,
          reason: 'one hop when two dice are playable');
      expect(s.isLegalPlay(Move(const [CheckerMove(23, 20)])), isFalse);
      expect(s.canonicalPlay(Move.none), isNull,
          reason: 'a pass while moves exist');
      // Out-of-range hops are refused before the board ever sees them.
      expect(
          s.canonicalPlay(
              Move(const [CheckerMove(-100, -100), CheckerMove(500, -7)])),
          isNull);
      expect(
          s.canonicalPlay(
              Move(const [CheckerMove(24, -1), CheckerMove(24, -1)])),
          isNull);
    });

    test('reports hits from the BOARD, not from the submission', () {
      final pts = List<int>.filled(24, 0);
      pts[7] = 2; // White on the 8-point
      pts[4] = -1; // a Black blot on the 5-point
      final s = GameState.testState(
        board: BoardState(points: pts),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(3, 1),
      );
      // 8/5, 5/4 submitted with the hit flag switched OFF.
      final lying =
          Move(const [CheckerMove(7, 4), CheckerMove(4, 3)]);
      final canonical = s.canonicalPlay(lying);
      expect(canonical, isNotNull);
      final hop = canonical!.checkerMoves
          .firstWhere((c) => c.from == 7 && c.to == 4);
      expect(hop.isHit, isTrue);
    });

    test('a dance canonicalises to Move.none', () {
      final pts = List<int>.filled(24, 0);
      pts[20] = 2;
      for (final i in [18, 19, 21, 22, 23]) {
        pts[i] = -2;
      }
      final s = GameState.testState(
        board: BoardState(points: pts, whiteBar: 1),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(2, 3),
      );
      expect(s.legalMoves, isEmpty);
      expect(s.canonicalPlay(Move.none)?.checkerMoves, isEmpty);
      expect(s.canonicalPlay(Move(const [CheckerMove(20, 18)])), isNull);
    });

    test('is null outside the moving phase', () {
      final s = fresh()
          .play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]));
      expect(s.phase, GamePhase.awaitingRoll);
      expect(s.canonicalPlay(Move.none), isNull);
    });

    test('the packed hop-set key answers exactly what sorted strings did', () {
      // `Move.sameAs` used to build two lists of '$from>$to' strings and sort
      // them on EVERY comparison — and canonicalPlay compares the submission
      // against every legal move and then against every decomposition of every
      // legal move. It now compares one packed integer per move instead.
      //
      // This is the equivalence proof: the string-sorting comparison is kept
      // here as the oracle, a reference canonicalPlay is built on top of it,
      // and the two must agree — answer for answer, character for character —
      // over every decomposition of every legal move in every hop order, in
      // real positions from a random game. It covers the reversed transit
      // chain the fallback exists for (see the reverse-order test above),
      // which arises many times over in a full game.
      bool sameAsBySortedStrings(Move a, Move b) {
        if (a.checkerMoves.length != b.checkerMoves.length) return false;
        List<String> key(Move m) =>
            [for (final c in m.checkerMoves) '${c.from}>${c.to}']..sort();
        final x = key(a);
        final y = key(b);
        for (var i = 0; i < x.length; i++) {
          if (x[i] != y[i]) return false;
        }
        return true;
      }

      // canonicalPlay's algorithm, verbatim, on the old comparison.
      Move? reference(GameState s, Move move) {
        if (s.phase != GamePhase.moving) return null;
        final legal = s.legalMoves;
        if (legal.isEmpty) {
          return move.checkerMoves.isEmpty ? Move.none : null;
        }
        for (final m in legal) {
          if (sameAsBySortedStrings(m, move)) return m;
        }
        if (move.checkerMoves.length != legal.first.checkerMoves.length) {
          return null;
        }
        for (final v in s.legalVariants) {
          for (final d in v.decompositions) {
            if (sameAsBySortedStrings(d, move)) return v.canonical;
          }
        }
        return null;
      }

      Iterable<List<CheckerMove>> permutations(List<CheckerMove> hops) sync* {
        if (hops.length <= 1) {
          yield List.of(hops);
          return;
        }
        for (var i = 0; i < hops.length; i++) {
          final rest = [...hops.sublist(0, i), ...hops.sublist(i + 1)];
          for (final tail in permutations(rest)) {
            yield [hops[i], ...tail];
          }
        }
      }

      final rng = Random(20260731);
      Dice roll() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);
      var opening = roll();
      while (opening.isDouble) {
        opening = roll();
      }
      var state = GameState.opening(
        firstPlayer: opening.die1 > opening.die2 ? Player.white : Player.black,
        openingDice: opening,
      );
      var compared = 0;
      var acceptedTransits = 0;
      var turns = 0;
      while (state.phase != GamePhase.gameOver && turns < 200) {
        turns++;
        if (state.phase == GamePhase.awaitingRoll) {
          state = state.roll(roll());
          continue;
        }
        final legal = state.legalMoves;
        // Every way a peer could word every legal play, plus two submissions
        // that must be REFUSED: a bogus hop, and a truncated play.
        final submissions = <Move>[
          for (final v in state.legalVariants)
            for (final d in v.decompositions)
              for (final perm in permutations(d.checkerMoves)) Move(perm),
          Move(const [CheckerMove(2, 99)]),
          if (legal.isNotEmpty && legal.first.checkerMoves.length > 1)
            Move([legal.first.checkerMoves.first]),
        ];
        for (final submission in submissions) {
          final mine = state.canonicalPlay(submission);
          final theirs = reference(state, submission);
          expect(mine?.toString(), theirs?.toString(),
              reason: 'canonicalPlay disagreed on $submission');
          if (mine != null &&
              !legal.any((m) => m.toString() == submission.toString())) {
            acceptedTransits++; // accepted although not literally a legal move
          }
          compared++;
        }
        state = state.play(
            legal.isEmpty ? Move.none : legal[rng.nextInt(legal.length)]);
      }
      expect(compared, greaterThan(500), reason: 'the probe actually ran');
      expect(acceptedTransits, greaterThan(0),
          reason: 'reordered/decomposed submissions were actually exercised');
    });
  });

  test('roll only when awaiting roll', () {
    expect(() => fresh().roll(Dice(2, 2)), throwsStateError);
    final s = fresh()
        .play(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]))
        .roll(Dice(2, 2));
    expect(s.phase, GamePhase.moving);
    expect(s.turn, Player.black);
  });

  test('bearing off the 15th checker wins: single, gammon, backgammon', () {
    GameState endgame({required int blackOff, int blackInWhiteHome = 0}) {
      final pts = List<int>.filled(24, 0);
      pts[0] = 1; // White's last checker on his 1-point
      if (blackInWhiteHome > 0) pts[3] = -blackInWhiteHome;
      final blackRemaining = 15 - blackOff - blackInWhiteHome;
      if (blackRemaining > 0) pts[20] = -blackRemaining;
      return GameState.testState(
        board: BoardState(
            points: pts, whiteOff: 14, blackOff: blackOff),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(1, 2),
        cube: const CubeState(value: 2, owner: Player.white),
      );
    }

    final single = endgame(blackOff: 3)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(single.phase, GamePhase.gameOver);
    expect(single.result!.winner, Player.white);
    expect(single.result!.outcome, GameOutcome.single);
    expect(single.result!.points, 2); // cube 2 × 1

    final gammon = endgame(blackOff: 0)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(gammon.result!.outcome, GameOutcome.gammon);
    expect(gammon.result!.points, 4); // cube 2 × 2

    final bg = endgame(blackOff: 0, blackInWhiteHome: 2)
        .play(Move(const [CheckerMove(0, CheckerMove.off)]));
    expect(bg.result!.outcome, GameOutcome.backgammon);
    expect(bg.result!.points, 6); // cube 2 × 3
  });

  test('no actions after game over', () {
    final done = GameState.testState(
      board: BoardState(points: List.filled(24, 0), whiteOff: 15),
      turn: Player.white,
      phase: GamePhase.gameOver,
    );
    expect(() => done.roll(Dice(3, 1)), throwsStateError);
    expect(() => done.play(Move.none), throwsStateError);
  });

  test('a dance passes the turn with Move.none', () {
    // White on the bar, Black's home fully closed.
    final pts = List<int>.filled(24, 0);
    for (var i = 18; i < 24; i++) {
      pts[i] = -2;
    }
    pts[0] = -3; // remaining black checkers
    pts[12] = 14; // white checkers elsewhere
    final s = GameState.testState(
      board: BoardState(points: pts, whiteBar: 1),
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(6, 2),
      cube: const CubeState(value: 1, owner: null),
    );
    expect(s.legalMoves, isEmpty);
    expect(() => s.play(Move(const [CheckerMove(12, 10)])), throwsStateError);
    final next = s.play(Move.none);
    expect(next.turn, Player.black);
    expect(next.phase, GamePhase.awaitingRoll);
  });

  test('reordered multiset-equal submission applies the canonical board', () {
    // Defense in depth: even a caller that bypasses MoveBuilder and submits a
    // reordered decomposition of a single-checker transit must not corrupt the
    // board. Lone White on point 24 (index 23), dice (4,2): the only legal
    // move is 24/22 22/18 == [(23,21),(21,17)]. Submitting the reversed hop
    // order must still land the checker on index 17 with no phantom checker on
    // the vacated point 22 (index 21) and no phantom hit.
    final board = BoardState(points: [
      -2, 0, 0, 0, 0, 0, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ], whiteOff: 14, blackOff: 13);
    final s = GameState.testState(
      board: board,
      turn: Player.white,
      phase: GamePhase.moving,
      dice: Dice(4, 2),
    );
    final expected = board.applyMove(Player.white, s.legalMoves.single);
    final reordered = Move(const [CheckerMove(21, 17), CheckerMove(23, 21)]);
    final next = s.play(reordered);
    expect(next.board, equals(expected));
    expect(next.board.points[21], 0);
    expect(next.board.points[17], 1);
    expect(next.board.whiteBar, 0);
    expect(next.board.blackBar, 0);
    expect(next.board.checkerCount(Player.white), 15);
    expect(next.board.checkerCount(Player.black), 15);
  });
}
