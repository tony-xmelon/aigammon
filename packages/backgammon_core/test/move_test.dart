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

  test('empty move is the dance', () {
    expect(Move.none.checkerMoves, isEmpty);
  });
}
