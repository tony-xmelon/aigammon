import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

void main() {
  test('starting position has the canonical gnubg Position ID', () {
    expect(positionId(BoardState.initial(), Player.white), '4HPwATDgc/ABMA');
    // The start is symmetric, so the ID is the same with black on roll.
    expect(positionId(BoardState.initial(), Player.black), '4HPwATDgc/ABMA');
  });

  test('a checker on the bar changes the ID', () {
    final b = BoardState(points: BoardState.initial().points, whiteBar: 1);
    expect(positionId(b, Player.white), isNot('4HPwATDgc/ABMA'));
    expect(positionId(b, Player.white), hasLength(14));
  });

  test('IDs are 14 base64 characters', () {
    final pts = List<int>.filled(24, 0);
    pts[0] = 15;
    pts[23] = -15;
    expect(positionId(BoardState(points: pts), Player.white), hasLength(14));
  });

  // Disambiguating golden derived by hand from the gnubg manual
  // ("A technical description of the Position ID").
  //
  // The manual specifies: the player ON ROLL is encoded FIRST, then the
  // opponent. The symmetric start cannot catch a swapped player order, so we
  // use an ASYMMETRIC position:
  //   White: 15 checkers on White's ace point (points[0] = +15).
  //   Black: 15 checkers on Black's 6 point (points[18] = -15).
  //
  // With White on roll, the 80-bit string (each location: one 1-bit per
  // checker then a 0-bit; locations run point 1..24 from that player's own
  // direction of travel, then the bar) is:
  //   White (on roll, bits 0..39):  15 ones, then 25 zeros
  //   Black (opponent, bits 40..79): 5 zeros, 15 ones, 1 zero, 19 zeros
  // Combined runs: bits 0-14 = 1, 15-44 = 0, 45-59 = 1, 60-79 = 0.
  // Packed little-endian (bit 0 -> LSB of byte 0) gives the 10 bytes:
  //   FF 7F 00 00 00 E0 FF 0F 00 00
  // base64 -> "/38AAADg/w8AAA==", first 14 chars -> "/38AAADg/w8AAA".
  test('asymmetric position: on-roll player is encoded first (manual order)',
      () {
    final pts = List<int>.filled(24, 0);
    pts[0] = 15; // White on its ace point.
    pts[18] = -15; // Black on its 6 point.
    final board = BoardState(points: pts);

    final whiteOnRoll = positionId(board, Player.white);
    final blackOnRoll = positionId(board, Player.black);

    // Player order matters: the two IDs must differ.
    expect(whiteOnRoll, isNot(blackOnRoll));

    // Exact ID hand-derived following the manual (on-roll player first).
    expect(whiteOnRoll, '/38AAADg/w8AAA');
  });
}
