import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

/// A byte-for-byte golden over the whole move generator.
///
/// The search was memoized for doubles and its position key repacked from a
/// comma-joined string into a packed integer record. Neither is allowed to
/// change a single character of what the generator emits — not the moves, not
/// their hit flags, not their ORDER (the first-seen decomposition is the
/// representative `legalMoves` lists, and the whole app, the AI's move ranking
/// and several goldens read that order).
///
/// A benchmark would prove the change was worth making; this proves it was
/// safe. The digest below was captured from the pre-change generator and must
/// survive every later optimisation of the search untouched. If a deliberate
/// change to the generator's OUTPUT is ever made, this constant is re-captured
/// in the same commit and the reason recorded there.
const String _goldenDigest = '7de7d1939eddd44d';

/// FNV-1a (64-bit), folded through the digits of every emitted move. Stable
/// across platforms and Dart versions — it is arithmetic on code units only.
String _digestOf(String s) {
  var hash = 0xcbf29ce484222325;
  const mask = 0xFFFFFFFFFFFFFFFF;
  for (final unit in s.codeUnits) {
    hash = (hash ^ unit) & mask;
    hash = (hash * 0x100000001b3) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Every emitted move of every probed roll at [board]/[player], written out in
/// generator order, including each variant's decompositions.
void _record(StringBuffer out, BoardState board, Player player, Dice dice) {
  out.write('${player.name} ${dice.die1}-${dice.die2}|');
  for (final m in MoveGenerator.legalMoves(board, player, dice)) {
    out.write('$m,');
  }
  out.write('#');
  for (final v in MoveGenerator.legalVariants(board, player, dice)) {
    out.write('${v.canonical}:');
    for (final d in v.decompositions) {
      out.write('$d;');
    }
  }
  out.writeln();
}

void main() {
  test('the generator emits byte-identical output for a seeded position sweep',
      () {
    final rng = Random(20260731);
    final out = StringBuffer();
    Dice roll() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);

    // Positions come from real random games (the same playout infrastructure
    // `playout_test.dart` uses), so the sweep covers openings, midgame contact,
    // bar entry, bear-off and back games rather than hand-built boards.
    var probed = 0;
    for (var g = 0; g < 12; g++) {
      var opening = roll();
      while (opening.isDouble) {
        opening = roll();
      }
      var state = GameState.opening(
        firstPlayer: opening.die1 > opening.die2 ? Player.white : Player.black,
        openingDice: opening,
      );
      var turns = 0;
      while (state.phase != GamePhase.gameOver && turns < 400) {
        turns++;
        switch (state.phase) {
          case GamePhase.awaitingRoll:
            state = state.roll(roll());
          case GamePhase.moving:
            // Every DOUBLES roll (the memoized path) and two non-doubles rolls
            // (the repacked signature key) are probed at this position, for
            // both players — a position is just a board, and the mirrored
            // search is worth exercising too.
            for (final player in Player.values) {
              for (var d = 1; d <= 6; d++) {
                _record(out, state.board, player, Dice(d, d));
                probed++;
              }
              _record(out, state.board, player, Dice(6, 1));
              _record(out, state.board, player, Dice(5, 3));
              probed += 2;
            }
            final legal = state.legalMoves;
            state = state.play(
                legal.isEmpty ? Move.none : legal[rng.nextInt(legal.length)]);
          case GamePhase.cubeOffered:
          case GamePhase.resignOffered:
          case GamePhase.gameOver:
            fail('unexpected phase ${state.phase}');
        }
      }
    }

    expect(probed, greaterThan(2000), reason: 'the sweep actually ran');
    expect(_digestOf(out.toString()), _goldenDigest,
        reason: 'the move generator\'s output changed — see the file header');
  });
}
