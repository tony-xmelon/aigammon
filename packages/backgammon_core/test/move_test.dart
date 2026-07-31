import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('checker move equality includes hit flag', () {
    expect(const CheckerMove(7, 4), const CheckerMove(7, 4));
    expect(const CheckerMove(7, 4),
        isNot(const CheckerMove(7, 4, isHit: true)));
  });

  test('sameAs ignores hop order', () {
    final a = Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]);
    final b = Move(const [CheckerMove(5, 4), CheckerMove(7, 4)]);
    expect(a.sameAs(b), isTrue);
    expect(a.sameAs(Move(const [CheckerMove(7, 4)])), isFalse);
  });

  test('sameAs ignores hit flags but not the hops themselves', () {
    final a = Move(const [CheckerMove(7, 4), CheckerMove(5, 4)]);
    expect(
        a.sameAs(Move(const [
          CheckerMove(5, 4, isHit: true),
          CheckerMove(7, 4, isHit: true),
        ])),
        isTrue);
    // A repeated hop is a MULTISET member, not a set member.
    final twice = Move(const [CheckerMove(7, 4), CheckerMove(7, 4)]);
    expect(twice.sameAs(Move(const [CheckerMove(7, 4), CheckerMove(5, 4)])),
        isFalse);
    expect(twice.sameAs(Move(const [CheckerMove(7, 4), CheckerMove(7, 4)])),
        isTrue);
    // Reversing one hop is a different play.
    expect(a.sameAs(Move(const [CheckerMove(4, 7), CheckerMove(5, 4)])),
        isFalse);
  });

  test('an off-board hop cannot alias onto a legal one', () {
    // The packed key codes a hop as (from + 1) * 100 + (to + 1), which is a
    // bijection only while `to` stays on the board. A submitted 3/100 would
    // carry into the next digit and pack to exactly the code of the legal
    // 4/off — so out-of-range moves get no key and are compared exactly. A
    // remote peer or a replayed log is where such a hop comes from, which is
    // why this is not merely hypothetical.
    final bogus = Move(const [CheckerMove(2, 99)]);
    final real = Move(const [CheckerMove(3, CheckerMove.off)]);
    expect(bogus.hopSetKey, isNull);
    expect(real.hopSetKey, isNotNull);
    expect(bogus.sameAs(real), isFalse);
    expect(real.sameAs(bogus), isFalse);
    // Two identical off-board submissions still compare equal to each other.
    expect(bogus.sameAs(Move(const [CheckerMove(2, 99)])), isTrue);
    expect(bogus.sameAs(Move(const [CheckerMove(2, 98)])), isFalse);
  });

  test('the hop-set key is order-insensitive and hop-sensitive', () {
    final a = Move(const [CheckerMove(23, 20), CheckerMove(20, 19)]);
    final b = Move(const [CheckerMove(20, 19), CheckerMove(23, 20)]);
    expect(a.hopSetKey, b.hopSetKey);
    expect(a.hopSetKey,
        isNot(Move(const [CheckerMove(23, 21), CheckerMove(21, 19)]).hopSetKey));
    // The sentinels are inside the coded range.
    expect(Move(const [CheckerMove(CheckerMove.bar, 20)]).hopSetKey, isNotNull);
    expect(Move(const [CheckerMove(0, CheckerMove.off)]).hopSetKey, isNotNull);
  });

  test('empty move is the dance', () {
    expect(Move.none.checkerMoves, isEmpty);
  });
}
