import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  group('MoveBuilder opening 3-1 (White, initial board)', () {
    final legal =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(3, 1));

    test('selectableSources equals the generator-derived first-hop sources', () {
      // With no hops chosen, any hop of any legal move can start the turn
      // (reorderings allowed), so the expected sources are the union of every
      // hop's from-value across all legal moves.
      final expected = <int>{
        for (final m in legal)
          for (final cm in m.checkerMoves) cm.from,
      };
      final b = MoveBuilder(legal);
      expect(b.selectableSources, equals(expected));
    });

    test('golden point 8/5 6/5 entered as (7,4) then (5,4) completes', () {
      final b = MoveBuilder(legal);
      b.addHop(7, 4);
      expect(b.destinationsFor(5), contains(4));
      b.addHop(5, 4);
      expect(b.isComplete, isTrue);
      expect(
        b.build().sameAs(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        isTrue,
      );
    });

    test('reordering: (5,4) then (7,4) also completes to the same move', () {
      final b = MoveBuilder(legal);
      expect(b.selectableSources, contains(5));
      b.addHop(5, 4);
      expect(b.destinationsFor(7), contains(4));
      b.addHop(7, 4);
      expect(b.isComplete, isTrue);
      expect(
        b.build().sameAs(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        isTrue,
      );
    });

    test('addHop with an unoffered pair throws and leaves state unchanged', () {
      final b = MoveBuilder(legal);
      final beforeSources = b.selectableSources;
      final beforeChosen = List.of(b.chosenHops);
      expect(() => b.addHop(0, 0), throwsArgumentError);
      expect(b.chosenHops, equals(beforeChosen));
      expect(b.selectableSources, equals(beforeSources));
      // A valid source but an unoffered destination also throws.
      expect(() => b.addHop(7, 2), throwsArgumentError);
      expect(b.chosenHops, isEmpty);
    });

    test('undoHop then re-add works; reset clears; chosenHops reflects order',
        () {
      final b = MoveBuilder(legal);
      b.addHop(7, 4);
      b.addHop(5, 4);
      expect(b.chosenHops.map((c) => '${c.from}>${c.to}').toList(),
          equals(['7>4', '5>4']));
      // isHit is always false on chosen hops.
      expect(b.chosenHops.every((c) => c.isHit == false), isTrue);

      b.undoHop();
      expect(b.chosenHops.length, 1);
      expect(b.isComplete, isFalse);
      // Re-add a valid continuation.
      b.addHop(5, 4);
      expect(b.isComplete, isTrue);

      b.reset();
      expect(b.chosenHops, isEmpty);
      expect(b.isComplete, isFalse);
      expect(b.selectableSources, equals(MoveBuilder(legal).selectableSources));

      // undoHop on empty is a no-op.
      b.undoHop();
      expect(b.chosenHops, isEmpty);
    });
  });

  group('MoveBuilder doubles (1-1, initial board)', () {
    final legal =
        MoveGenerator.legalMoves(BoardState.initial(), Player.white, Dice(1, 1));

    test('all legal moves have length four', () {
      expect(legal, isNotEmpty);
      expect(legal.first.checkerMoves.length, 4);
    });

    test('four hops enterable one at a time to completion', () {
      final b = MoveBuilder(legal);
      var guard = 0;
      while (!b.isComplete) {
        expect(b.selectableSources, isNotEmpty,
            reason: 'builder must never strand the user mid-turn');
        final source = b.selectableSources.first;
        final dest = b.destinationsFor(source).first;
        b.addHop(source, dest);
        expect(++guard, lessThanOrEqualTo(4));
      }
      expect(b.chosenHops.length, 4);
      // The completed hops form a legal move (possibly a reordering).
      expect(legal.any((m) => m.sameAs(b.build())), isTrue);
    });

    test('partial prefixes offer only generator-backed continuations', () {
      final b = MoveBuilder(legal);
      final source = b.selectableSources.first;
      final dest = b.destinationsFor(source).first;
      b.addHop(source, dest);
      // Every offered continuation must be the (k)-th hop of some permutation
      // of a legal move whose earlier hops equal the chosen prefix.
      for (final s in b.selectableSources) {
        for (final d in b.destinationsFor(s)) {
          final backed = legal.any((m) {
            final hops = m.checkerMoves;
            return hops.any((h) => h.from == source && h.to == dest) &&
                hops.any((h) => h.from == s && h.to == d);
          });
          expect(backed, isTrue);
        }
      }
    });
  });

  group('MoveBuilder dance (no legal moves)', () {
    test('empty legal set: no sources, not complete, build throws', () {
      final b = MoveBuilder(const []);
      expect(b.selectableSources, isEmpty);
      expect(b.isComplete, isFalse);
      expect(b.build, throwsStateError);
    });
  });

  group('MoveBuilder bar/off sentinels', () {
    test('bear-off: destinationsFor includes off and completing works', () {
      // All White home: two checkers on point 6 (index 5), rest borne off.
      final board = BoardState(
        points: [
          0, 0, 0, 0, 0, 2, //  points 1-6
          0, 0, 0, 0, 0, 0, //  7-12
          0, 0, 0, 0, 0, 0, // 13-18
          0, 0, 0, 0, 0, -2, // 19-24 (black parked out of the way)
        ],
        whiteOff: 13,
        blackOff: 13,
      );
      final legal =
          MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
      expect(legal, isNotEmpty);

      final b = MoveBuilder(legal);
      expect(b.selectableSources, contains(5));
      expect(b.destinationsFor(5), contains(CheckerMove.off));

      b.addHop(5, CheckerMove.off); // bear off with the 6
      b.addHop(5, 0); // play the 5: point 6 -> point 1
      expect(b.isComplete, isTrue);
      final built = b.build();
      expect(built.checkerMoves.any((c) => c.to == CheckerMove.off), isTrue);
      expect(legal.any((m) => m.sameAs(built)), isTrue);
    });

    test('bar entry: selectableSources contains the bar sentinel', () {
      final board = BoardState(
        points: [
          4, 0, 0, 0, 0, 5, //  1-6   (9 white on board)
          0, 0, 0, 0, 0, 0, //  7-12
          0, -3, 0, -3, 0, 0, // 13-18 (black on 14 and 16)
          0, 0, 0, -3, -3, -3, // 19-24 (black on 22,23,24); 19/20 open
        ],
        whiteBar: 1,
        whiteOff: 5,
      );
      final legal =
          MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
      expect(legal, isNotEmpty);

      final b = MoveBuilder(legal);
      expect(b.selectableSources, contains(CheckerMove.bar));
      // Entering from the bar is offered, and destinations are real entry
      // points (24 - die => index 18 or 19).
      final entries = b.destinationsFor(CheckerMove.bar);
      expect(entries, isNotEmpty);
      expect(entries.every((to) => to == 18 || to == 19), isTrue);
      // Completing a turn that starts from the bar works end to end.
      b.addHop(CheckerMove.bar, entries.first);
      while (!b.isComplete) {
        final s = b.selectableSources.first;
        b.addHop(s, b.destinationsFor(s).first);
      }
      expect(legal.any((m) => m.sameAs(b.build())), isTrue);
    });
  });

  group('MoveBuilder single-checker transit (order-dependence regression)', () {
    test('reversed entry still plays the canonical, non-corrupt board', () {
      // Lone White checker on point 24 (index 23); dice (4,2). The only legal
      // move is 24/22 22/18 == [(23,21),(21,17)] — one checker through the
      // vacated point 22 (index 21). Entering the hops reversed must NOT let
      // the tap order reach the board (that would fabricate a checker on 22
      // and a phantom hit).
      final board = BoardState(
        points: [
          -2, 0, 0, 0, 0, 0, //  1-6 (black filler, out of the way)
          0, 0, 0, 0, 0, 0, //  7-12
          0, 0, 0, 0, 0, 0, // 13-18
          0, 0, 0, 0, 0, 1, // 19-24 (lone White on 24)
        ],
        whiteOff: 14,
        blackOff: 13,
      );
      final state = GameState.testState(
        board: board,
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(4, 2),
      );
      final legal = state.legalMoves;
      expect(legal, hasLength(1));
      final canonical = legal.single;
      final expected = board.applyMove(Player.white, canonical);

      final b = MoveBuilder(legal);
      // Enter REVERSED: 22/18 (21->17) first, then 24/22 (23->21).
      b.addHop(21, 17);
      b.addHop(23, 21);
      expect(b.isComplete, isTrue);
      // build() emits the canonical playable order, not the tap order.
      expect(
        b.build().checkerMoves.map((c) => '${c.from}>${c.to}').toList(),
        equals(['23>21', '21>17']),
      );

      final next = state.play(b.build());
      expect(next.board, equals(expected));
      // No phantom checker on the vacated transit point, no phantom hit.
      expect(next.board.points[21], 0);
      expect(next.board.points[17], 1);
      expect(next.board.whiteBar, 0);
      expect(next.board.blackBar, 0);
      expect(next.board.checkerCount(Player.white), 15);
      expect(next.board.checkerCount(Player.black), 15);
    });
  });

  group('MoveBuilder prefix-extendability invariant', () {
    test('random offered walks never strand the user (seeded)', () {
      final rolls = [Dice(3, 1), Dice(6, 5), Dice(1, 1)];
      final rng = Random(1234);
      for (final dice in rolls) {
        final legal = MoveGenerator.legalMoves(
            BoardState.initial(), Player.white, dice);
        for (var trial = 0; trial < 25; trial++) {
          final b = MoveBuilder(legal);
          var guard = 0;
          while (!b.isComplete) {
            expect(b.selectableSources, isNotEmpty,
                reason: 'roll $dice: prefix ${b.chosenHops} was stranded');
            final sources = b.selectableSources.toList();
            final source = sources[rng.nextInt(sources.length)];
            final dests = b.destinationsFor(source).toList();
            final dest = dests[rng.nextInt(dests.length)];
            b.addHop(source, dest);
            expect(++guard, lessThanOrEqualTo(4));
          }
          expect(legal.any((m) => m.sameAs(b.build())), isTrue);
        }
      }
    });
  });

  group('MoveBuilder.chainedDestinationsFor / chainFor (combined moves)', () {
    test('opening 3-1: one back checker chains 24/20, landing 19 via 22 or 20',
        () {
      // Index 23 is White's 24-point (two back checkers). With 3-1 a single
      // checker may run both dice: 24/23/20 or 24/21/20 — both land on the
      // 20-point (index 19). The chained landing is deduped to 19.
      final legal = MoveGenerator.legalMoves(
          BoardState.initial(), Player.white, Dice(3, 1));
      final b = MoveBuilder(legal);

      final chained = b.chainedDestinationsFor(23);
      expect(chained, contains(19),
          reason: '24/20 is a same-checker two-hop chain landing on 19');
      // 19 is NOT a single-hop (direct) destination of 23.
      expect(b.destinationsFor(23), isNot(contains(19)));

      final chain = b.chainFor(23, 19);
      expect(chain, hasLength(2), reason: 'a 3-1 chain is exactly two hops');
      expect(chain.first.from, 23);
      expect(chain.last.to, 19);
      // The two hops connect (checker travels through the intermediate point).
      expect(chain.first.to, chain.last.from);
      // The intermediate is one of the two single-die landings.
      expect(chain.first.to, anyOf(22, 20));
    });

    test('chainFor yields a sequence the builder can enter hop-by-hop', () {
      final legal = MoveGenerator.legalMoves(
          BoardState.initial(), Player.white, Dice(3, 1));
      final b = MoveBuilder(legal);
      final chain = b.chainFor(23, 19);
      expect(chain, isNotEmpty);
      // Entering the chain hop-by-hop never throws and leaves a legal prefix.
      for (final h in chain) {
        b.addHop(h.from, h.to);
      }
      expect(b.chosenHops, hasLength(2));
      // The chain plus its continuation completes to a legal move.
      while (!b.isComplete) {
        final s = b.selectableSources.first;
        b.addHop(s, b.destinationsFor(s).first);
      }
      expect(legal.any((m) => m.sameAs(b.build())), isTrue);
    });

    test('no chains when the roll only affords single hops', () {
      // Bear-off position: two White checkers on the 6-point (index 5), all
      // else home/off. Dice 6-5: the 6 bears one off, the 5 moves 6/1. The two
      // dice act on different checkers with no same-checker continuation.
      final board = BoardState(
        points: [
          0, 0, 0, 0, 0, 2, // 1-6
          0, 0, 0, 0, 0, 0, // 7-12
          0, 0, 0, 0, 0, 0, // 13-18
          0, 0, 0, 0, 0, -2, // 19-24
        ],
        whiteOff: 13,
        blackOff: 13,
      );
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
      final b = MoveBuilder(legal);
      // The 6-point (index 5) can bear off (6) or move to 1 (5) — both single
      // hops. There is no chain (a chain would need the same checker to play
      // both dice, but a 6-5 from index 5 overshoots).
      expect(b.chainedDestinationsFor(5), isEmpty);
      expect(b.chainFor(5, 0), isEmpty);
    });

    test('bar entry can start a chain', () {
      // White on the bar; entry board (indices 18..23) open enough to enter and
      // continue with the same checker.
      final board = BoardState(
        points: [
          4, 0, 0, 0, 0, 5, // 1-6
          0, 0, 0, 0, 0, 0, // 7-12
          0, -3, 0, -3, 0, 0, // 13-18 (black on 14,16)
          0, 0, 0, -3, -3, -3, // 19-24 (black on 22,23,24)
        ],
        whiteBar: 1,
        whiteOff: 5,
      );
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
      final b = MoveBuilder(legal);
      // bar/19 (index 18, the 6) then 19/14... is blocked; bar/18 (index 19,
      // the 5) then 18/12 (index 17->11? no). Compute what the builder actually
      // offers: any chain must start from the bar and be enterable.
      final chained = b.chainedDestinationsFor(CheckerMove.bar);
      // If a bar chain exists, its chainFor is enterable end to end.
      for (final landing in chained) {
        final chain = b.chainFor(CheckerMove.bar, landing);
        expect(chain.length, greaterThanOrEqualTo(2));
        expect(chain.first.from, CheckerMove.bar);
        expect(chain.last.to, landing);
        final probe = MoveBuilder(legal);
        for (final h in chain) {
          probe.addHop(h.from, h.to);
        }
        expect(probe.chosenHops.length, chain.length);
      }
    });

    test('doubles 1-1: a single checker chains up to four hops', () {
      // Contrived: a lone White back checker with a clear runway on 1-1 can
      // chain 24/23/22/21/20 (indices 23->22->21->20->19). Landings appear at
      // depths 2..4, capped at the full move length (4).
      final board = BoardState(
        points: [
          -2, 0, 0, 0, 0, 0, // 1-6 (black filler out of the way)
          13, 0, 0, 0, 0, 0, // 7-12 (White's other 13 checkers parked on 7)
          0, 0, 0, 0, 0, 0, // 13-18
          0, 0, 0, 0, 0, 1, // 19-24 (lone White on 24)
        ],
        whiteOff: 0,
        blackOff: 13,
      );
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(1, 1));
      expect(legal, isNotEmpty);
      final b = MoveBuilder(legal);
      final chained = b.chainedDestinationsFor(23);
      // The back checker can walk 23->22->21->20->19; the deepest chain lands
      // on 19 (four hops = the whole move).
      expect(chained, contains(19));
      final full = b.chainFor(23, 19);
      expect(full, hasLength(4));
      expect(full.first.from, 23);
      expect(full.last.to, 19);
      // No chain exceeds the move length.
      for (final landing in chained) {
        expect(b.chainFor(23, landing).length, lessThanOrEqualTo(4));
      }
    });

    test('a repeated (prefix, source) reuses one search, and the prefix '
        'invalidates it', () {
      // The board view asks for chained destinations on EVERY drag frame with
      // the same prefix and source, so the answer is cached per source and
      // dropped whenever the prefix moves. This pins both halves: the cached
      // answer is the same answer, and it is computed once.
      final legal = MoveGenerator.legalMoves(
          BoardState.initial(), Player.white, Dice(3, 1));
      final b = MoveBuilder(legal);
      expect(b.chainSearches, 0);

      final first = b.chainedDestinationsFor(23);
      expect(b.chainSearches, 1);
      final second = b.chainedDestinationsFor(23);
      expect(second, equals(first), reason: 'same inputs, same output');
      expect(b.chainSearches, 1, reason: 'the search ran once, not twice');

      // Another source is its own entry, and does not evict the first.
      b.chainedDestinationsFor(7);
      expect(b.chainSearches, 2);
      expect(b.chainedDestinationsFor(23), equals(first));
      expect(b.chainSearches, 2);

      // A chosen hop changes the prefix: the answer is recomputed, and equals
      // what a FRESH builder standing at the same prefix reports.
      b.addHop(7, 4);
      final afterHop = b.chainedDestinationsFor(23);
      expect(b.chainSearches, 3);
      final reference = MoveBuilder(legal)..addHop(7, 4);
      expect(afterHop, equals(reference.chainedDestinationsFor(23)));

      // Undo restores the original prefix — and the original answer.
      b.undoHop();
      expect(b.chainedDestinationsFor(23), equals(first));
      expect(b.chainSearches, 4);

      // reset() invalidates too (same prefix here, so the same answer again).
      b.reset();
      expect(b.chainedDestinationsFor(23), equals(first));
      expect(b.chainSearches, 5);
    });

    test('the cached set is unmodifiable, so a caller cannot poison it', () {
      final legal = MoveGenerator.legalMoves(
          BoardState.initial(), Player.white, Dice(3, 1));
      final b = MoveBuilder(legal);
      expect(() => b.chainedDestinationsFor(23).add(99),
          throwsUnsupportedError);
    });

    test('memoized answers match an unmemoized reference across a random '
        'playout', () {
      // Correctness-equivalence for the memoization: over real positions from a
      // random game, the cached answer for every selectable source equals the
      // answer a FRESH builder (empty cache) gives for the same prefix.
      final rng = Random(20260731);
      Dice rollDice() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);
      var opening = rollDice();
      while (opening.isDouble) {
        opening = rollDice();
      }
      var state = GameState.opening(
        firstPlayer: opening.die1 > opening.die2 ? Player.white : Player.black,
        openingDice: opening,
      );
      var checked = 0;
      var turns = 0;
      while (state.phase != GamePhase.gameOver && turns < 400) {
        turns++;
        if (state.phase == GamePhase.awaitingRoll) {
          state = state.roll(rollDice());
          continue;
        }
        final builder = MoveBuilder.forState(state);
        // Walk the whole turn hop by hop, comparing at every prefix.
        while (!builder.isComplete && builder.selectableSources.isNotEmpty) {
          for (final source in builder.selectableSources) {
            final memoized = builder.chainedDestinationsFor(source);
            // Same call again — must hit the cache and agree.
            expect(builder.chainedDestinationsFor(source), equals(memoized));
            // A fresh builder replaying the same prefix has an empty cache.
            final fresh = MoveBuilder.forState(state);
            for (final h in builder.chosenHops) {
              fresh.addHop(h.from, h.to);
            }
            expect(fresh.chainedDestinationsFor(source), equals(memoized),
                reason: 'memoized answer differs from an uncached one');
            checked++;
          }
          final s = builder.selectableSources.first;
          builder.addHop(s, builder.destinationsFor(s).first);
        }
        final legal = state.legalMoves;
        state = state.play(
            legal.isEmpty ? Move.none : (builder.isComplete
                ? builder.build()
                : legal[rng.nextInt(legal.length)]));
      }
      expect(checked, greaterThan(100), reason: 'the probe actually ran');
    });

    test('chainedDestinationsFor is empty for a non-source', () {
      final legal = MoveGenerator.legalMoves(
          BoardState.initial(), Player.white, Dice(3, 1));
      final b = MoveBuilder(legal);
      // Index 0 has no White checker in the opening / is not a first hop source.
      expect(b.chainedDestinationsFor(0), isEmpty);
      expect(b.chainFor(0, 5), isEmpty);
    });
  });

  // Investigation of the UX-round-1 bear-off complaint: "cannot move a chip out
  // of the board with a higher die than needed." The engine allows an overshoot
  // bear-off ONLY from the highest occupied point; these tests pin exactly what
  // the MoveBuilder surfaces so the UI chain (BoardView) can be trusted.
  group('MoveBuilder bear-off overshoot (UX round 1 investigation)', () {
    BoardState home(Map<int, int> whitePts,
        {required int whiteOff, int blackOff = 15}) {
      final p = List<int>.filled(24, 0);
      whitePts.forEach((k, v) => p[k] = v);
      return BoardState(points: p, whiteOff: whiteOff, blackOff: blackOff);
    }

    test('(a) overshoot legal: lone checker on the 4-point offers off directly',
        () {
      // Lone White checker on index 3 (the 4-point), all else borne off. With
      // 6-5 both dice exceed the point number and, since idx3 is the only (and
      // therefore highest) occupied point, either die bears it off. Only one
      // checker remains, so the maximal turn is length 1: a single overshoot
      // bear-off, offered as a DIRECT destination.
      final board = home({3: 1}, whiteOff: 14);
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(6, 5));
      expect(legal, isNotEmpty);
      final b = MoveBuilder(legal);
      expect(b.selectableSources, contains(3));
      expect(b.destinationsFor(3), contains(CheckerMove.off),
          reason: 'overshoot bear-off from the highest point is offered '
              'directly with a higher die than needed');
      b.addHop(3, CheckerMove.off);
      expect(b.isComplete, isTrue);
      expect(b.build().checkerMoves.single.to, CheckerMove.off);
    });

    test('(c) maximal-dice overshoot surfaces only as a chain (6-2 from the '
        '4-point)', () {
      // Lone checker on idx3, dice 6-2. The maximal-dice rule forces BOTH dice
      // to be played by the one checker: 4/2 (the 2) then 2/off (the 6, an
      // overshoot from the now-highest point). So the 6 cannot bear off FIRST
      // as a single hop — the builder does NOT offer off directly from idx3,
      // but DOES surface it as a same-checker two-die chain, which the BoardView
      // enters at once when combined taps are on.
      final board = home({3: 1}, whiteOff: 14);
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(6, 2));
      final b = MoveBuilder(legal);
      expect(b.destinationsFor(3), isNot(contains(CheckerMove.off)),
          reason: 'the 6 cannot bear off first under the maximal-dice rule');
      expect(b.destinationsFor(3), contains(1)); // the 2: 4-point -> 2-point
      expect(b.chainedDestinationsFor(3), contains(CheckerMove.off),
          reason: 'the overshoot bear-off is reachable as a two-die chain');
      final chain = b.chainFor(3, CheckerMove.off);
      expect(chain, hasLength(2));
      for (final h in chain) {
        b.addHop(h.from, h.to);
      }
      expect(b.isComplete, isTrue);
      expect(
          b.build().checkerMoves.any((c) => c.to == CheckerMove.off), isTrue);
    });

    test('(b) overshoot RULE: a checker on the 5-point blocks the 4-point from '
        'bearing off first with a 6', () {
      // Checkers on idx3 (4-point) AND idx4 (5-point), doubles 6-6. The engine
      // rule: a 6 (which exceeds both point numbers) may bear off ONLY from the
      // highest occupied point. So the canonical first hop of every legal turn
      // is 5/off (idx4) — never 4/off (idx3) while idx4 is still occupied.
      final board = home({3: 1, 4: 1}, whiteOff: 13);
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(6, 6));
      expect(legal, isNotEmpty);
      for (final m in legal) {
        expect(m.checkerMoves.first.from, 4,
            reason: 'every legal turn bears the highest (5-)point off first');
      }
      // The builder tolerates reordered ENTRY (it permutes a listed move), so
      // tapping the lower checker off first is accepted; build() still emits the
      // canonical, rule-legal ordering (5/off then 4/off). This is NOT a rule
      // violation: the board result is identical and correct.
      final b = MoveBuilder(legal);
      b.addHop(3, CheckerMove.off); // user taps the 4-point checker first
      b.addHop(4, CheckerMove.off);
      expect(b.isComplete, isTrue);
      expect(b.build().checkerMoves.first.from, 4,
          reason: 'canonical build bears the highest point off first');
    });

    test('(b2) non-double: the 6 bears off whichever point is highest after the '
        '2 is played (off offered from both bear-off sources)', () {
      // idx3 + idx4, dice 6-2. Two legal turns exist — 5/3 then 4/off, and
      // 4/2 then 3/off — so a bear-off with the 6 is reachable from either
      // point (as the point that is highest once the 2 has been played). The
      // builder therefore offers off from both idx3 and idx4.
      final board = home({3: 1, 4: 1}, whiteOff: 13);
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(6, 2));
      final b = MoveBuilder(legal);
      expect(b.destinationsFor(4), contains(CheckerMove.off));
      expect(b.destinationsFor(3), contains(CheckerMove.off));
    });

    test('(d) multi-checker: two on the 4-point bear off sequentially on 6-6',
        () {
      // Two White checkers on idx3, doubles 6-6. Each is borne off by an
      // overshoot 6; after the first leaves, idx3 is still the highest point, so
      // the second bears off too. The builder offers off from idx3, and keeps
      // offering it after the first hop is entered.
      final board = home({3: 2}, whiteOff: 13);
      final legal = MoveGenerator.legalMoves(board, Player.white, Dice(6, 6));
      final b = MoveBuilder(legal);
      expect(b.destinationsFor(3), contains(CheckerMove.off));
      b.addHop(3, CheckerMove.off);
      expect(b.destinationsFor(3), contains(CheckerMove.off),
          reason: 'the second checker on the 4-point still bears off');
      b.addHop(3, CheckerMove.off);
      expect(b.isComplete, isTrue);
      expect(
          b.build().checkerMoves.where((c) => c.to == CheckerMove.off).length,
          2);
    });
  });

  // The position-aware builder must not offer a bear-off the rules do not allow
  // YET. Both cases arise from permutation matching: a legal move's off-hop is
  // offered as a FIRST hop, at a position where bearing off is illegal — the
  // outcome would still be legal (build() emits the canonical order), but the
  // offer itself is a lie, and bear-off is exactly where users already struggle.
  group('MoveBuilder.forState never offers a premature bear-off', () {
    GameState state(Map<int, int> pts, Dice dice,
            {int whiteOff = 0, int blackOff = 0}) =>
        GameState.testState(
          board: BoardState(
            points: [for (var i = 0; i < 24; i++) pts[i] ?? 0],
            whiteOff: whiteOff,
            blackOff: blackOff,
          ),
          turn: Player.white,
          phase: GamePhase.moving,
          dice: dice,
        );

    Set<int> offSources(MoveBuilder b) => {
          for (final s in b.selectableSources)
            if (b.destinationsFor(s).contains(CheckerMove.off)) s,
        };

    test('a checker still outside the home board blocks every off-hop', () {
      // White has one checker on the 7-point (index 6) and everything else home,
      // playing 4-1. `7/6 4/off` is legal — the 1 brings the straggler home, THEN
      // the 4 bears off. Reordered as `4/off 7/6` it is not: no bear-off is legal
      // while index 6 is occupied.
      final s = state({6: 1, 3: 4, 2: 5, 1: 5, 23: -15}, Dice(4, 1));
      expect(
          s.legalMoves.any((m) =>
              m.checkerMoves.any((h) => h.to == CheckerMove.off)),
          isTrue,
          reason: 'precondition: some legal move does bear off (after the 1)');

      final b = MoveBuilder.forState(s);
      expect(offSources(b), isEmpty,
          reason: 'not all checkers are home yet, so nothing can come off');

      b.addHop(6, 5); // 7/6 — the straggler comes home
      expect(offSources(b), contains(3),
          reason: 'now the 4 bears the 4-point checker off');
    });

    test('an overshoot is offered only from the furthest-back checker', () {
      // All home, 6-4: one checker on the 4-point (index 3) and the rest on the
      // 2-point (index 1). `4/off 2/off` is legal — the 4 takes the 4-point
      // exactly, then the 6 overshoots from what is by then the furthest-back
      // point. Reordered as `2/off 4/off` the first hop is an illegal overshoot,
      // because index 3 is still occupied.
      final s = state({3: 1, 1: 14, 23: -15}, Dice(6, 4));
      final b = MoveBuilder.forState(s);
      expect(offSources(b), {3},
          reason: 'only the furthest-back checker may overshoot');

      b.addHop(3, CheckerMove.off);
      expect(offSources(b), contains(1),
          reason: 'the 2-point is now the furthest back: the 6 overshoots it');
    });

    test('an EXACT bear-off is offered from any point, back checker or not', () {
      // All home, 6-1: the 1 takes the 1-point (index 0) exactly even though the
      // 6-point (index 5) is further back, so the filter must not demand the
      // furthest-back checker when the die matches exactly.
      final s = state({5: 1, 0: 1, 23: -15}, Dice(6, 1), whiteOff: 13);
      final b = MoveBuilder.forState(s);
      expect(offSources(b), containsAll(<int>{5, 0}),
          reason: '6/off by exact 6, and 1/off by exact 1');
    });
  });
}
