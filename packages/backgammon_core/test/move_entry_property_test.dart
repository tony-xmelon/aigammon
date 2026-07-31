import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:test/test.dart';

/// Engine-level PROOF that hop-by-hop move entry can never dead-end or strand a
/// checker.
///
/// The board's tap/drag entry (see `BoardView` / [MoveBuilder]) is only as
/// trustworthy as a handful of properties of the builder, which this suite
/// asserts over hundreds of seeded random positions × rolls sampled from real
/// playouts (the `playout_test` idiom) — every position a game can actually
/// reach, including bar entries, blocked home boards and bear-off races:
///
/// * **(a) no dead ends** — every prefix the builder OFFERS extends to
///   [MoveBuilder.isComplete], so a partially entered move can always be
///   finished;
/// * **(b) completeness is real** — a complete prefix [MoveBuilder.build]s to a
///   move that IS one of `legalMoves` and applies cleanly to the board;
/// * **(c) nothing is unreachable** — every legal move can be entered, and (for
///   the position-aware builder) via EVERY playable decomposition of it, in its
///   own order and in any playable reordering;
/// * **(d) one-die turns end after one hop** — when the maximal play is a single
///   hop, one hop completes the turn (no phantom second die to chase);
/// * **(e) no stranded checkers** — the P0: whenever a decomposition continues
///   with the checker just moved, that checker is offered as a source for the
///   next hop (`13/9` then `9/8` on a 4-1). Falls out of (c) over decompositions,
///   and is asserted explicitly as well;
/// * **(f) no phantom sources** — the position-aware builder never offers a hop
///   from a point the mover has no checker on.
///
/// It also checks the combined-move (chained) offers the board paints as
/// "landing" targets: every chain [MoveBuilder.chainFor] returns is enterable
/// hop by hop and really lands where it claims.
///
/// Everything runs through [MoveBuilder.forState] — the only constructor, and
/// what the board uses.
///
/// The DFS over offered paths is bounded by a node budget per position, so a
/// doubles turn with many movable checkers is sampled rather than exhausted.
void main() {
  final positions = _samplePositions(Random(20260726), games: 40, keep: 400);

  test('the sample covers the shapes that matter', () {
    expect(positions.length, 400);
    var withBar = 0;
    var withOff = 0;
    var doubles = 0;
    var dances = 0;
    var singleDie = 0;
    var multiWay = 0;
    for (final c in positions) {
      if (c.board.barFor(c.player) > 0) withBar++;
      if (c.board.offFor(c.player) > 0) withOff++;
      if (c.dice.isDouble) doubles++;
      final legal = c.state.legalMoves;
      if (legal.isEmpty) {
        dances++;
      } else if (legal.first.checkerMoves.length == 1) {
        singleDie++;
      }
      if (c.state.legalVariants.any((v) => v.decompositions.length > 1)) {
        multiWay++;
      }
    }
    expect(withBar, greaterThan(10), reason: 'bar entries');
    expect(withOff, greaterThan(10), reason: 'bear-off races');
    expect(doubles, greaterThan(50), reason: 'doubles');
    expect(singleDie, greaterThan(5), reason: 'one-die turns');
    expect(dances, greaterThan(0), reason: 'dances');
    expect(multiWay, greaterThan(50),
        reason: 'positions where a move can be entered more than one way — the '
            'shape the P0 lived in');
  });

  test('entry never dead-ends, over sampled real positions', () {
    final rng = Random(4242);
    for (final c in positions) {
      _checkEntry(c, rng);
    }
  });

  test('crafted tight positions still complete', () {
    final rng = Random(7);
    for (final c in _craftedPositions()) {
      expect(c.board.checkerCount(Player.white), 15, reason: 'setup: $c');
      expect(c.board.checkerCount(Player.black), 15, reason: 'setup: $c');
      expect(c.state.legalMoves, isNotEmpty, reason: 'setup: $c is playable');
      _checkEntry(c, rng);
    }
  });

  group('the P0 shape: the checker just moved keeps playing', () {
    /// White with two checkers on the 13-point (index 12) and a 4-1 to play.
    /// `legalMoves` lists the one-checker run as `13/12 12/8`; a user who taps
    /// the 4 first (13/9) must still be able to play the 1 with that checker.
    GameState state() {
      final pts = List<int>.filled(24, 0);
      pts[12] = 2;
      pts[5] = 5;
      pts[4] = 5;
      pts[3] = 3;
      pts[23] = -8;
      pts[22] = -5;
      pts[0] = -2;
      return GameState.testState(
        board: BoardState(points: pts),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(4, 1),
      );
    }

    test('the generator keeps both routes as one move with two decompositions',
        () {
      final s = state();
      final run = s.legalVariants
          .firstWhere((v) => v.canonical.sameAs(
              Move(const [CheckerMove(12, 11), CheckerMove(11, 7)])));
      expect(run.decompositions.length, 2);
      expect(
          run.decompositions.any((d) =>
              d.sameAs(Move(const [CheckerMove(12, 8), CheckerMove(8, 7)]))),
          isTrue,
          reason: '13/9 9/8 must be offered as well as 13/12 12/8');
      expect(s.legalMoves.length, s.legalVariants.length,
          reason: 'the listed moves are unchanged — only their entry paths grew');
    });

    test('4 first: the checker on the 9-point can still play the 1', () {
      final b = MoveBuilder.forState(state());
      expect(b.destinationsFor(12), {11, 8});
      b.addHop(12, 8); // 13/9 — the 4
      expect(b.selectableSources, contains(8),
          reason: 'the checker that just landed must be movable again');
      expect(b.destinationsFor(8), {7}, reason: '9/8 — the 1');
      b.addHop(8, 7);
      expect(b.isComplete, isTrue);
      expect(b.build().sameAs(Move(const [CheckerMove(12, 11), CheckerMove(11, 7)])),
          isTrue,
          reason: 'it commits the canonical move for that position');
    });

    test('1 first: the same run entered the other way round', () {
      final b = MoveBuilder.forState(state());
      b.addHop(12, 11); // 13/12 — the 1
      expect(b.destinationsFor(11), {7});
      b.addHop(11, 7); // 12/8 — the 4
      expect(b.isComplete, isTrue);
      expect(b.build().sameAs(Move(const [CheckerMove(12, 11), CheckerMove(11, 7)])),
          isTrue);
    });

    test('no phantom source: the empty 12-point is not selectable', () {
      final s = state();
      // A permutation of the listed 13/12 12/8 run starts from the empty
      // 12-point; without the playability filter that used to be offered.
      expect(MoveBuilder.forState(s).selectableSources, isNot(contains(11)),
          reason: 'no checker sits there, so it cannot be picked up');
    });

    test('bearing off: 6/5 then 5/off, and 6/1 then 1/off, both enter', () {
      // All fifteen White checkers home, a 5-1 to play. Running one checker off
      // the 6-point collapses to a single listed move; both routes must enter.
      final pts = List<int>.filled(24, 0);
      pts[5] = 3;
      pts[2] = 6;
      pts[1] = 6;
      pts[23] = -15;
      final s = GameState.testState(
        board: BoardState(points: pts),
        turn: Player.white,
        phase: GamePhase.moving,
        dice: Dice(5, 1),
      );
      for (final route in [
        [const CheckerMove(5, 4), const CheckerMove(4, CheckerMove.off)],
        [const CheckerMove(5, 0), const CheckerMove(0, CheckerMove.off)],
      ]) {
        final b = MoveBuilder.forState(s);
        for (final hop in route) {
          expect(b.selectableSources, contains(hop.from),
              reason: 'entering ${Move(route)}');
          expect(b.destinationsFor(hop.from), contains(hop.to),
              reason: 'entering ${Move(route)}');
          b.addHop(hop.from, hop.to);
        }
        expect(b.isComplete, isTrue, reason: 'entering ${Move(route)}');
        expect(s.legalMoves.any((m) => m.sameAs(b.build())), isTrue);
      }
    });
  });
}

/// A position to test entry from.
class _Case {
  _Case(this.state);
  final GameState state;

  BoardState get board => state.board;
  Player get player => state.turn;
  Dice get dice => state.dice!;

  @override
  String toString() => '$player $dice on ${board.points}'
      ' bar(w:${board.whiteBar} b:${board.blackBar})'
      ' off(w:${board.whiteOff} b:${board.blackOff})';
}

/// Plays [games] seeded random games, capturing every moving-phase position and
/// thinning the haul down to [keep] of them (shuffled, so opening, middlegame
/// and bear-off positions are all represented).
List<_Case> _samplePositions(Random rng,
    {required int games, required int keep}) {
  Dice roll() => Dice(rng.nextInt(6) + 1, rng.nextInt(6) + 1);
  final out = <_Case>[];
  for (var g = 0; g < games; g++) {
    var opening = roll();
    while (opening.isDouble) {
      opening = roll();
    }
    var state = GameState.opening(
      firstPlayer: opening.die1 > opening.die2 ? Player.white : Player.black,
      openingDice: opening,
    );
    var turns = 0;
    while (state.phase != GamePhase.gameOver && turns < 500) {
      turns++;
      switch (state.phase) {
        case GamePhase.awaitingRoll:
          state = state.roll(roll());
        case GamePhase.moving:
          out.add(_Case(state));
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
  out.shuffle(rng);
  return out.take(keep).toList();
}

/// Hand-built shapes that random play reaches rarely: a closed-out bar entry, a
/// bear-off with an overshoot, a one-die-only turn, doubles that can only play
/// twice, and a chain that must run one checker through a transit point.
List<_Case> _craftedPositions() {
  _Case make(Map<int, int> pts, Player player, Dice dice,
          {int whiteBar = 0,
          int blackBar = 0,
          int whiteOff = 0,
          int blackOff = 0}) =>
      _Case(GameState.testState(
        board: BoardState(
          points: [for (var i = 0; i < 24; i++) pts[i] ?? 0],
          whiteBar: whiteBar,
          blackBar: blackBar,
          whiteOff: whiteOff,
          blackOff: blackOff,
        ),
        turn: player,
        phase: GamePhase.moving,
        dice: dice,
      ));

  return [
    // Bar entry only on the 4: the 6's entry point (index 18) is blocked.
    make({
      23: -2, 22: -2, 21: -2, 19: -2, 18: -2, 0: -5,
      5: 8, 4: 4, 3: 2,
    }, Player.white, Dice(6, 4), whiteBar: 1),
    // Bear-off overshoot: only the 4-point occupied, rolling 6-5.
    make({3: 2, 23: -15}, Player.white, Dice(6, 5), whiteOff: 13),
    // One die only (the higher-die rule): the 2 is blocked everywhere, the 6
    // bears a checker off the 6-point.
    make({5: 8, 4: 7, 3: -2, 2: -2, 23: -11}, Player.white, Dice(6, 2)),
    // Doubles that can only play TWICE: 3-3, one runner, everything else walled.
    make({
      20: 2, 5: 5, 4: 5, 3: 3,
      14: -2, 11: -2, 8: -2, 2: -2, 1: -2, 0: -2, 23: -3,
    }, Player.white, Dice(3, 3)),
    // Transit chain: one checker can run 13/11/9/7/5 on 2-2, hitting on the way.
    make({
      12: 1, 5: 5, 4: 5, 3: 4,
      23: -8, 22: -2, 21: -2, 10: -1, 2: -2,
    }, Player.white, Dice(2, 2)),
    // Black's turn, mirrored bar entry, to prove the denormalised side too.
    make({
      0: 2, 1: 2, 2: 2, 4: 2, 5: 2, 23: 5,
      18: -8, 19: -4, 20: -2,
    }, Player.black, Dice(6, 4), blackBar: 1),
    // Black running one checker through a transit point on a 5-2.
    make({
      18: -2, 5: 2, 4: 2, 3: 2, 2: 2, 1: 2, 0: 5,
      23: -13,
    }, Player.black, Dice(5, 2)),
  ];
}

/// Asserts properties (a)-(f) for one position.
void _checkEntry(_Case c, Random rng) {
  final legal = c.state.legalMoves;
  final reason = 'position: $c';
  MoveBuilder make() => MoveBuilder.forState(c.state);

  if (legal.isEmpty) {
    final builder = make();
    expect(builder.selectableSources, isEmpty, reason: reason);
    expect(builder.isComplete, isFalse, reason: reason);
    expect(builder.chosenHops, isEmpty, reason: reason);
    return;
  }

  // Every legal move has the same length: the invariant `isComplete` rests on.
  final len = legal.first.checkerMoves.length;
  expect(legal.every((m) => m.checkerMoves.length == len), isTrue,
      reason: 'legal moves must all be the same length — $reason');
  expect(len, inInclusiveRange(1, c.dice.isDouble ? 4 : 2), reason: reason);

  // Every enterable hop sequence, with the move it must commit to.
  final entries = <({Move decomposition, Move canonical})>[
    for (final v in c.state.legalVariants)
      for (final d in v.decompositions)
        (decomposition: d, canonical: v.canonical),
  ];
  for (final e in entries) {
    expect(e.decomposition.checkerMoves.length, len, reason: reason);
  }

  // (a) + (b): explore the offered tree, bounded by a node budget (a doubles
  // turn's tree is sampled, not exhausted — the seed makes the sample stable).
  var budget = 40;
  void walk(List<CheckerMove> prefix) {
    if (budget-- <= 0) return;
    final builder = _replay(make(), prefix, reason);
    if (builder.isComplete) {
      expect(prefix.length, len, reason: reason);
      final built = builder.build();
      expect(legal.any((m) => m.sameAs(built)), isTrue,
          reason: 'build() must return a listed legal move — $reason');
      expect(built.checkerMoves.length, len, reason: reason);
      // The canonical order really applies to the board, and the entered order
      // reaches the very same position.
      final after = c.board.applyMove(c.player, built);
      expect(after.checkerCount(Player.white), 15, reason: reason);
      expect(after.checkerCount(Player.black), 15, reason: reason);
      var stepped = c.board;
      for (final hop in prefix) {
        stepped = stepped.applyMove(c.player, Move([hop]));
      }
      expect(stepped, after,
          reason: 'entering ${Move(prefix)} hop by hop must reach the same '
              'position as committing $built — $reason');
      return;
    }
    // (a) An incomplete prefix ALWAYS offers a continuation.
    expect(prefix.length, lessThan(len), reason: reason);
    final sources = builder.selectableSources.toList()..sort();
    expect(sources, isNotEmpty,
        reason: 'offered prefix ${Move(prefix)} dead-ended — $reason');
    // (f) Every offered hop is one the rules allow AT THIS MOMENT: its source
    // holds a checker of the mover's, and a bear-off really is available (all
    // home, and an overshoot only from the furthest-back checker).
    {
      var position = c.board;
      for (final hop in prefix) {
        position = position.applyMove(c.player, Move([hop]));
      }
      final white = c.player == Player.white;
      final sign = white ? 1 : -1;
      for (final s in sources) {
        final held = s == CheckerMove.bar
            ? position.barFor(c.player)
            : position.points[s] * sign;
        expect(held, greaterThan(0),
            reason: 'source $s holds no checker of the mover\'s — $reason');
        if (!builder.destinationsFor(s).contains(CheckerMove.off)) continue;
        // A bear-off is offered: the rules must allow it from THIS position —
        // every checker home, and a die that either matches the distance exactly
        // or overshoots from the furthest-back checker.
        expect(position.barFor(c.player), 0, reason: reason);
        for (var i = 0; i < 24; i++) {
          if (position.points[i] * sign <= 0) continue;
          expect(white ? i <= 5 : i >= 18, isTrue,
              reason: 'off offered from $s with a checker still on $i at '
                  '${Move(prefix)} — $reason');
        }
        var furthest = s;
        for (var i = 0; i < 24; i++) {
          if (position.points[i] * sign <= 0) continue;
          if (white ? i > furthest : i < furthest) furthest = i;
        }
        final distance = white ? s + 1 : 24 - s;
        final inHand = _diceInHand(c.dice, prefix, white);
        expect(
            inHand.any((d) =>
                d == distance || (d > distance && s == furthest)),
            isTrue,
            reason: 'off offered from $s (needs $distance) with $inHand in hand '
                'and $furthest furthest back, at ${Move(prefix)} — $reason');
      }
    }
    for (final s in sources) {
      expect(builder.destinationsFor(s), isNotEmpty,
          reason: 'source $s offers nothing — $reason');
    }
    // Chained (combined-tap) offers must be enterable and land where claimed.
    // Checked at the ROOT prefix (what the board paints when a turn opens),
    // where the chains are longest; deeper prefixes are covered by the walk.
    if (prefix.isEmpty) {
      for (final s in sources) {
        for (final landing in builder.chainedDestinationsFor(s)) {
          final chain = builder.chainFor(s, landing);
          expect(chain.length, greaterThanOrEqualTo(2),
              reason: 'chain to $landing from $s — $reason');
          expect(chain.first.from, s, reason: reason);
          expect(chain.last.to, landing, reason: reason);
          _replay(make(), chain, 'chain to $landing from $s — $reason');
        }
      }
    }
    // Recurse over every offered hop (shuffled so the budget samples widely).
    final hops = <CheckerMove>[
      for (final s in sources)
        for (final d in builder.destinationsFor(s)) CheckerMove(s, d),
    ]..shuffle(rng);
    for (final hop in hops) {
      if (budget <= 0) break;
      walk([...prefix, hop]);
    }
  }

  walk(const []);

  // (c) + (e) Every enterable sequence really enters — in its own (playable)
  // order, and in any reordering whose hops stay playable. A bounded sample,
  // since a doubles roll can offer hundreds of moves.
  for (final e in _sample(entries, 10, rng)) {
    final hops = e.decomposition.checkerMoves;
    final ordered = _replay(make(), hops, 'entering ${e.decomposition} — $reason');
    expect(ordered.isComplete, isTrue,
        reason: 'entering ${e.decomposition} left it incomplete — $reason');
    expect(ordered.build().sameAs(e.canonical), isTrue,
        reason: 'entering ${e.decomposition} must commit ${e.canonical} '
            '— $reason');

    // (e) explicitly: wherever the sequence continues with the checker just
    // moved, that checker is offered again.
    final probe = make();
    for (var i = 0; i < hops.length; i++) {
      probe.addHop(hops[i].from, hops[i].to);
      if (i + 1 < hops.length && hops[i + 1].from == hops[i].to) {
        expect(probe.selectableSources, contains(hops[i].to),
            reason: 'the checker on ${hops[i].to} was stranded after '
                '${hops[i]} — $reason');
      }
    }

    // Reordered entry: at every step SOME remaining hop must be offered.
    final remaining = [...hops]..shuffle(rng);
    final builder = make();
    while (remaining.isNotEmpty) {
      final i = remaining.indexWhere((h) =>
          builder.selectableSources.contains(h.from) &&
          builder.destinationsFor(h.from).contains(h.to));
      expect(i, greaterThanOrEqualTo(0),
          reason: 'no remaining hop of ${e.decomposition} is offered after '
              '${Move(builder.chosenHops)} — $reason');
      final hop = remaining.removeAt(i);
      builder.addHop(hop.from, hop.to);
    }
    expect(builder.isComplete, isTrue, reason: reason);
    expect(builder.build().sameAs(e.canonical), isTrue, reason: reason);
  }

  // (d) A one-die turn is over after ONE hop, whichever offered hop is chosen —
  // no phantom second die left highlighted for the user to chase.
  if (len == 1) {
    final root = make();
    for (final source in root.selectableSources) {
      for (final dest in root.destinationsFor(source)) {
        final builder = make();
        builder.addHop(source, dest);
        expect(builder.isComplete, isTrue,
            reason: 'one-die turn not complete after $source/$dest — $reason');
        expect(builder.selectableSources, isEmpty,
            reason: 'a finished turn offers nothing more — $reason');
      }
    }
  }
}

/// The dice values [prefix] has NOT spent. Each hop consumes the die its pip
/// distance names; a bear-off overshoot consumes the smallest die that covers it.
List<int> _diceInHand(Dice dice, List<CheckerMove> prefix, bool white) {
  final remaining = dice.isDouble
      ? <int>[dice.die1, dice.die1, dice.die1, dice.die1]
      : <int>[dice.die1, dice.die2];
  for (final hop in prefix) {
    final from = hop.from == CheckerMove.bar ? (white ? 24 : -1) : hop.from;
    final distance = hop.to == CheckerMove.off
        ? (white ? from + 1 : 24 - from)
        : (white ? from - hop.to : hop.to - from);
    var pick = remaining.indexOf(distance);
    if (pick < 0) {
      for (var i = 0; i < remaining.length; i++) {
        if (remaining[i] < distance) continue;
        if (pick < 0 || remaining[i] < remaining[pick]) pick = i;
      }
    }
    if (pick >= 0) remaining.removeAt(pick);
  }
  return remaining;
}

/// Enters [hops] into [builder], asserting each was offered when its turn came.
MoveBuilder _replay(
    MoveBuilder builder, List<CheckerMove> hops, String reason) {
  for (final hop in hops) {
    expect(builder.selectableSources, contains(hop.from),
        reason: '$hop not offered after ${Move(builder.chosenHops)} — $reason');
    expect(builder.destinationsFor(hop.from), contains(hop.to),
        reason: '$hop not offered after ${Move(builder.chosenHops)} — $reason');
    builder.addHop(hop.from, hop.to);
  }
  return builder;
}

/// Up to [n] entries of [items]: the first, the last, and a seeded random pick
/// of the rest, so the sample is stable across runs.
List<T> _sample<T>(List<T> items, int n, Random rng) {
  if (items.length <= n) return items;
  final picked = <T>{items.first, items.last};
  while (picked.length < n) {
    picked.add(items[rng.nextInt(items.length)]);
  }
  return picked.toList();
}
