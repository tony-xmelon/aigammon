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

  group('buildScoreSheet', () {
    ScoreSheetTurn turnAt(List<ScoreSheetRow> rows, int i) =>
        rows[i] as ScoreSheetTurn;
    ScoreSheetSpan spanAt(List<ScoreSheetRow> rows, int i) =>
        rows[i] as ScoreSheetSpan;

    test('empty event list yields no rows', () {
      expect(buildScoreSheet(const []), isEmpty);
    });

    test('the opening roll is a full-width span row', () {
      final rows = buildScoreSheet(const [
        OpeningRollEvent(whiteDie: 3, blackDie: 1),
      ]);
      expect(rows, hasLength(1));
      expect(spanAt(rows, 0).text, 'Opening: W 3 — B 1 (W starts)');
      expect(spanAt(rows, 0).actor, isNull);
      expect(spanAt(rows, 0).eventIndex, 0);
    });

    test('White then Black pair into ONE numbered turn row', () {
      final rows = buildScoreSheet([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const RollEvent(Player.black, 2, 6),
        MoveEvent(
            Player.black, Move(const [CheckerMove(0, 6), CheckerMove(6, 11)])),
      ]);
      expect(rows, hasLength(2), reason: 'the span plus one paired turn row');
      final turn = turnAt(rows, 1);
      expect(turn.number, 1);
      // Compact dice ("31:" not "3-1:") and no side letter — the column says it.
      expect(turn.white?.text, '31: 8/5 6/5');
      expect(turn.white?.eventIndex, 1);
      expect(turn.black?.text, '62: 1/7 7/12');
      expect(turn.black?.eventIndex, 3);
    });

    test('a Black opening leaves the first row\'s White cell empty', () {
      final rows = buildScoreSheet([
        const OpeningRollEvent(whiteDie: 1, blackDie: 6),
        MoveEvent(
            Player.black, Move(const [CheckerMove(0, 5), CheckerMove(5, 8)])),
        const RollEvent(Player.white, 3, 2),
        MoveEvent(
            Player.white, Move(const [CheckerMove(23, 20), CheckerMove(20, 18)])),
      ]);
      // Row 1 carries only Black's opening move; White's reply opens row 2, so
      // each row always reads White-then-Black in chronological order.
      expect(turnAt(rows, 1).number, 1);
      expect(turnAt(rows, 1).white, isNull);
      expect(turnAt(rows, 1).black?.text, '61: 1/6 6/9');
      expect(turnAt(rows, 2).number, 2);
      expect(turnAt(rows, 2).white?.text, '32: 24/21 21/19');
      expect(turnAt(rows, 2).black, isNull);
    });

    test('a dance renders as (no play) in its own cell', () {
      final rows = buildScoreSheet([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(Player.white, Move.none),
      ]);
      expect(turnAt(rows, 1).white?.text, '31: (no play)');
    });

    test('cube actions are span rows that close the open turn row', () {
      final rows = buildScoreSheet([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const DoubleEvent(Player.black),
        const TakeEvent(Player.white),
        const RollEvent(Player.black, 5, 3),
        MoveEvent(
            Player.black, Move(const [CheckerMove(0, 5), CheckerMove(5, 8)])),
      ]);
      expect(spanAt(rows, 2).text, 'B doubles → 2');
      expect(spanAt(rows, 2).actor, Player.black);
      expect(spanAt(rows, 3).text, 'W takes');
      // The double closed turn 1, so Black's later move cannot back-fill it.
      expect(turnAt(rows, 1).black, isNull);
      expect(turnAt(rows, 4).number, 2);
      expect(turnAt(rows, 4).black?.text, '53: 1/6 6/9');
    });

    test('successive doubles multiply the cube value on the span rows', () {
      final rows = buildScoreSheet([
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
      expect(
        rows
            .whereType<ScoreSheetSpan>()
            .where((r) => r.text.contains('doubles'))
            .map((r) => r.text),
        ['B doubles → 2', 'W doubles → 4'],
      );
    });

    test('drop / resign offers and responses are span rows', () {
      final rows = buildScoreSheet([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        const DoubleEvent(Player.white),
        const DropEvent(Player.black),
        const ResignOfferEvent(Player.white, ResignValue.gammon),
        const ResignAcceptEvent(Player.black),
        const ResignDeclineEvent(Player.black),
      ]);
      expect(
        rows.whereType<ScoreSheetSpan>().map((r) => r.text),
        [
          'Opening: W 3 — B 1 (W starts)',
          'W doubles → 2',
          'B drops',
          'W offers to resign a gammon',
          'B accepts',
          'B declines',
        ],
      );
      expect(rows.whereType<ScoreSheetTurn>(), isEmpty);
    });

    test('every row carries the event index it was folded from', () {
      final rows = buildScoreSheet([
        const OpeningRollEvent(whiteDie: 3, blackDie: 1),
        MoveEvent(
            Player.white, Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        const DoubleEvent(Player.black),
      ]);
      expect(spanAt(rows, 0).eventIndex, 0);
      expect(turnAt(rows, 1).white?.eventIndex, 1);
      expect(spanAt(rows, 2).eventIndex, 2);
    });
  });
}
