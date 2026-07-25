import 'package:aigammon_app/game/game_record.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildGameRecord', () {
    test('empty event list yields no lines', () {
      expect(buildGameRecord(const []), isEmpty);
    });

    test('opening roll becomes a neutral header naming the first player', () {
      final lines = buildGameRecord(const [
        OpeningRollEvent(whiteDie: 3, blackDie: 1),
      ]);
      expect(lines, hasLength(1));
      expect(lines.single, const RecordLine('Opening: W 3 — B 1 (W starts)'));
      expect(lines.single.actor, isNull, reason: 'the opening line is neutral');
    });

    test('opening won by Black names Black as the starter', () {
      final lines = buildGameRecord(const [
        OpeningRollEvent(whiteDie: 1, blackDie: 6),
      ]);
      expect(lines.single, const RecordLine('Opening: W 1 — B 6 (B starts)'));
    });

    test('first move uses the opening dice; later moves use their roll', () {
      final lines = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const RollEvent(Player.black, 2, 6),
        MoveEvent(
            Player.black, Move(const [CheckerMove(0, 6), CheckerMove(6, 11)])),
      ]);
      expect(lines, [
        const RecordLine('Opening: W 3 — B 1 (W starts)'),
        // Opening dice 3/1 supply the first mover; hops from White's view.
        RecordLine('1. W 3-1: 8/5 6/5', actor: Player.white),
        // Roll 2/6 is normalised high-first to "6-2".
        RecordLine('2. B 6-2: 1/7 7/12', actor: Player.black),
      ]);
    });

    test('a hit is shown with the * from the move notation', () {
      final lines = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(Player.white,
            Move(const [CheckerMove(7, 4, isHit: true), CheckerMove(5, 4)])),
      ]);
      expect(lines.last, RecordLine('1. W 3-1: 8/5* 6/5', actor: Player.white));
    });

    test('a dance renders as (no play)', () {
      final lines = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(Player.white, Move.none),
      ]);
      expect(lines.last, RecordLine('1. W 3-1: (no play)', actor: Player.white));
    });

    test('a double is numbered and shows the new cube value; take follows', () {
      final lines = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const DoubleEvent(Player.black),
        const TakeEvent(Player.white),
      ]);
      expect(lines, [
        const RecordLine('Opening: W 3 — B 1 (W starts)'),
        RecordLine('1. W 3-1: 8/5 6/5', actor: Player.white),
        RecordLine('2. B doubles → 2', actor: Player.black),
        RecordLine('W takes', actor: Player.white),
      ]);
    });

    test('a drop follows a double unnumbered', () {
      final lines = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const DoubleEvent(Player.black),
        const DropEvent(Player.white),
      ]);
      expect(lines.last, RecordLine('W drops', actor: Player.white));
    });

    test('successive doubles multiply the cube value', () {
      final lines = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const DoubleEvent(Player.black),
        const TakeEvent(Player.white),
        const RollEvent(Player.black, 5, 3),
        MoveEvent(
            Player.black, Move(const [CheckerMove(0, 5), CheckerMove(5, 8)])),
        const DoubleEvent(Player.white),
        const TakeEvent(Player.black),
      ]);
      expect(lines.where((l) => l.text.contains('doubles')).map((l) => l.text),
          ['2. B doubles → 2', '4. W doubles → 4']);
    });

    test('resign offer is numbered; accept/decline follow unnumbered', () {
      final accepted = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const RollEvent(Player.black, 2, 1),
        const ResignOfferEvent(Player.black, ResignValue.gammon),
        const ResignAcceptEvent(Player.white),
      ]);
      expect(accepted.sublist(2), [
        RecordLine('2. B offers to resign a gammon', actor: Player.black),
        RecordLine('W accepts', actor: Player.white),
      ]);

      final declined = buildGameRecord([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        const ResignOfferEvent(Player.white, ResignValue.single),
        const ResignDeclineEvent(Player.black),
      ]);
      expect(declined.sublist(1), [
        RecordLine('1. W offers to resign a single', actor: Player.white),
        RecordLine('B declines', actor: Player.black),
      ]);
    });
  });
}
