import 'move.dart';

/// Builds a full-turn [Move] hop by hop, always staying inside the legal set.
///
/// Construct with the current position's legal moves (`GameState.legalMoves`).
/// The builder narrows candidates as hops are chosen: a candidate survives
/// while some permutation of its hops starts with the chosen hops (compared by
/// from/to, ignoring hit flags). Because turns are at most 4 hops, permutation
/// matching is brute-force.
///
/// The builder offers only hops that appear in surviving candidates, so a
/// completed sequence always corresponds to a legal move (possibly entered as
/// a reordering). The builder accepts reordered *entry* but [build] always
/// emits the canonical playable ordering of the matched legal move — never the
/// user's tap order — because `BoardState.applyMove` is order-dependent for a
/// single checker transiting a point it vacates (see [build]).
///
/// v1 scope: reorderings of a *listed* move are supported (permutation
/// matching). A transit-equivalent decomposition that the generator collapsed
/// away (kept only one representative of) is only offered when it is the
/// representative present in the supplied list — the UI highlights only what
/// the builder offers, so the user can only tap what is offered. Acceptable v1
/// semantics.
///
/// Hits: chosen hops are recorded with `isHit == false` and compared to
/// candidates by (from, to) only. [build] resolves back to the matching legal
/// move, whose hops carry the generator's correct isHit flags, so the emitted
/// move is fully playable.
///
/// No `isDeadEnd`: under the maximal-dice rule every legal move has the same
/// length, so any prefix the builder offers can always be extended to a
/// complete turn. Each offered hop is the k-th hop of some permutation of a
/// full-length legal move whose earlier hops equal the chosen prefix; choosing
/// it keeps that permutation alive, so more hops remain until completion.
class MoveBuilder {
  final List<Move> _legal;
  final List<CheckerMove> _chosen = [];

  /// Next-hop options for the current prefix, deduped by (from, to). Cached and
  /// recomputed whenever the prefix changes.
  List<CheckerMove> _nextHops = const [];

  MoveBuilder(List<Move> legalMoves) : _legal = List.of(legalMoves) {
    _recompute();
  }

  /// Hops chosen so far, in the order entered (isHit always false).
  List<CheckerMove> get chosenHops => List.unmodifiable(_chosen);

  /// From-values (0-23 or [CheckerMove.bar]) that can start the next hop.
  /// Empty when the turn is complete or there are no legal moves.
  Set<int> get selectableSources => {for (final h in _nextHops) h.from};

  /// To-values (0-23 or [CheckerMove.off]) reachable in one hop from [source].
  Set<int> destinationsFor(int source) =>
      {for (final h in _nextHops) if (h.from == source) h.to};

  /// Records a hop. Throws [ArgumentError] unless (from, to) is currently
  /// offered by [selectableSources]/[destinationsFor].
  void addHop(int from, int to) {
    final offered = _nextHops.any((h) => h.from == from && h.to == to);
    if (!offered) {
      throw ArgumentError('hop $from/$to is not currently selectable');
    }
    _chosen.add(CheckerMove(from, to));
    _recompute();
  }

  /// Removes the last chosen hop (no-op when none).
  void undoHop() {
    if (_chosen.isEmpty) return;
    _chosen.removeLast();
    _recompute();
  }

  /// Clears all chosen hops.
  void reset() {
    _chosen.clear();
    _recompute();
  }

  /// True when the chosen hops form a complete legal turn. Because all legal
  /// moves have equal length, this is `chosenHops.length == (the legal move
  /// length)`; false when there are no legal moves.
  bool get isComplete =>
      _legal.isNotEmpty &&
      _chosen.length == _legal.first.checkerMoves.length;

  /// The completed [Move] in canonical (generator/playable) order. Throws
  /// [StateError] unless [isComplete].
  ///
  /// This returns the matching legal move — NOT the user's tap order.
  /// `BoardState.applyMove` is order-dependent for a single checker moving
  /// through a point it vacates earlier in the sequence (a reordered
  /// decomposition would decrement an empty transit point and fabricate a
  /// hit), so the canonical playable ordering (with correct isHit flags) must
  /// be what reaches the board.
  Move build() {
    if (!isComplete) {
      throw StateError('turn is not complete: ${_chosen.length} hop(s) chosen');
    }
    final entered = Move(List.of(_chosen));
    return _legal.firstWhere((m) => m.sameAs(entered));
  }

  /// Recomputes the next-hop options for the current prefix: for every legal
  /// move and every permutation of its hops whose first `k` hops equal the
  /// chosen prefix (by from/to), the (k)-th hop is offered.
  void _recompute() {
    final k = _chosen.length;
    final result = <CheckerMove>[];
    final seen = <int>{};
    for (final move in _legal) {
      final hops = move.checkerMoves;
      if (k >= hops.length) continue;
      for (final perm in _permutations(hops)) {
        if (!_prefixMatches(perm, k)) continue;
        final hop = perm[k];
        // Sentinels: bar == 24, off == -1; both fit in a single stable key.
        final key = (hop.from + 1) * 100 + (hop.to + 1);
        if (seen.add(key)) result.add(hop);
      }
    }
    _nextHops = result;
  }

  /// Whether the first [k] hops of [perm] equal the chosen prefix by from/to.
  bool _prefixMatches(List<CheckerMove> perm, int k) {
    for (var i = 0; i < k; i++) {
      if (perm[i].from != _chosen[i].from || perm[i].to != _chosen[i].to) {
        return false;
      }
    }
    return true;
  }

  /// All orderings of [items]. Turns are at most 4 hops, so this is at most
  /// 4! = 24 permutations per candidate — trivial to enumerate exhaustively.
  Iterable<List<CheckerMove>> _permutations(List<CheckerMove> items) sync* {
    if (items.length <= 1) {
      yield List.of(items);
      return;
    }
    for (var i = 0; i < items.length; i++) {
      final rest = [...items.sublist(0, i), ...items.sublist(i + 1)];
      for (final tail in _permutations(rest)) {
        yield [items[i], ...tail];
      }
    }
  }
}
