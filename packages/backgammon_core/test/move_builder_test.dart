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
}
