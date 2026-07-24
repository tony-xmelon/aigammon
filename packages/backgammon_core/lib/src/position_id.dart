import 'dart:convert';
import 'dart:typed_data';

import 'board_state.dart';
import 'player.dart';

/// The gnubg Position ID for [board] with [onRoll] to move: an 80-bit
/// checker encoding, base64-encoded to 14 characters.
///
/// Per the gnubg manual ("A technical description of the Position ID"): the
/// player ON ROLL is encoded FIRST, then the opponent. For each player, for
/// each of the 25 locations (points 1..24 from that player's own direction of
/// travel, then the bar), append one 1-bit per checker followed by a single
/// 0-bit. Pad to 80 bits. The bit string is stored little-endian: the first
/// bits fill the least-significant bits of the first byte. Base64 of the 10
/// bytes gives 16 chars; the first 14 (dropping the trailing "==") are the ID.
///
/// The manual's worked example is the (symmetric) starting position, which
/// cannot disambiguate the player order; the on-roll-first order is confirmed
/// by reproducing the manual's exact bit string and by an asymmetric golden
/// test (see position_id_test.dart).
String positionId(BoardState board, Player onRoll) {
  final bytes = Uint8List(10);
  var bit = 0;

  void writeChecker() {
    bytes[bit >> 3] |= 1 << (bit & 7);
    bit++;
  }

  void writePlayer(Player p) {
    for (var k = 1; k <= 24; k++) {
      final i = p == Player.white ? k - 1 : 24 - k;
      final c = board.points[i];
      final count = p == Player.white ? (c > 0 ? c : 0) : (c < 0 ? -c : 0);
      for (var j = 0; j < count; j++) {
        writeChecker();
      }
      bit++; // the terminating 0-bit
    }
    for (var j = 0; j < board.barFor(p); j++) {
      writeChecker();
    }
    bit++; // the terminating 0-bit after the bar
  }

  // The manual specifies the player on roll is encoded first.
  writePlayer(onRoll);
  writePlayer(onRoll.opponent);

  return base64Encode(bytes).substring(0, 14);
}
