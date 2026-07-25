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

  /// Final landing points of *combined* (multi-hop) moves in which the SAME
  /// checker, starting at [source], plays two or more consecutive dice.
  ///
  /// A chain is a sequence of offered hops h1=(source, x), h2=(x, y), … where
  /// each hop continues from the previous hop's landing (same checker) and the
  /// whole sequence is enterable hop-by-hop from the current prefix (each hop is
  /// offered by the builder at the point it would be played). The returned set
  /// is the DEDUPED landing spots of chains of length ≥ 2 — e.g. for an opening
  /// 3-1 the back checker's two routes 24/23/20 and 24/21/20 both collapse to
  /// the single landing 20 (index 19).
  ///
  /// Chains are naturally capped at the turn's move length (once the prefix is
  /// full no hops are offered), so a doubles roll yields landings at depths 2..4
  /// but never deeper. Landings that would also be a single-hop [destinationsFor]
  /// value cannot occur (one die vs. two dice never coincide for one source),
  /// but callers that paint both sets may subtract [destinationsFor] defensively.
  Set<int> chainedDestinationsFor(int source) {
    final out = <int>{};
    _collectChains(List.of(_chosen), source, const [], out);
    return out;
  }

  /// One enterable hop sequence (length ≥ 2) that runs the same checker from
  /// [source] to [landing], or an empty list when no such chain exists.
  ///
  /// The returned hops are guaranteed enterable in order via [addHop] from the
  /// current prefix. When several routes reach [landing] (e.g. 24/23/20 vs.
  /// 24/21/20) an arbitrary but valid one is returned.
  List<CheckerMove> chainFor(int source, int landing) =>
      _findChain(List.of(_chosen), source, landing, const []) ?? const [];

  /// DFS from [currentPos] (the same checker's current location) collecting the
  /// landings of every enterable chain of length ≥ 2 into [out]. [prefix] is the
  /// hypothetical chosen sequence (real prefix + chain so far); [chain] is the
  /// same-checker hops accumulated from [source].
  void _collectChains(List<CheckerMove> prefix, int currentPos,
      List<CheckerMove> chain, Set<int> out) {
    for (final h in _computeNextHops(prefix)) {
      if (h.from != currentPos) continue; // must continue the SAME checker
      final next = [...chain, h];
      if (next.length >= 2) out.add(h.to);
      if (h.to == CheckerMove.off) continue; // a borne-off checker cannot go on
      _collectChains([...prefix, h], h.to, next, out);
    }
  }

  /// DFS variant returning the first enterable chain (length ≥ 2) whose final
  /// hop lands on [landing], or `null`.
  List<CheckerMove>? _findChain(List<CheckerMove> prefix, int currentPos,
      int landing, List<CheckerMove> chain) {
    for (final h in _computeNextHops(prefix)) {
      if (h.from != currentPos) continue;
      final next = [...chain, h];
      if (next.length >= 2 && h.to == landing) return next;
      if (h.to == CheckerMove.off) continue;
      final found = _findChain([...prefix, h], h.to, landing, next);
      if (found != null) return found;
    }
    return null;
  }

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

  /// Recomputes the next-hop options for the current chosen prefix.
  void _recompute() {
    _nextHops = _computeNextHops(_chosen);
  }

  /// The next-hop options for an arbitrary [prefix]: for every legal move and
  /// every permutation of its hops whose first `prefix.length` hops equal
  /// [prefix] (by from/to), the next hop is offered (deduped by from/to).
  ///
  /// Used both for the live prefix (via [_recompute]) and for the hypothetical
  /// prefixes explored while enumerating combined-move chains, so chain hops are
  /// exactly the hops the builder would offer when they are played.
  List<CheckerMove> _computeNextHops(List<CheckerMove> prefix) {
    final k = prefix.length;
    final result = <CheckerMove>[];
    final seen = <int>{};
    for (final move in _legal) {
      final hops = move.checkerMoves;
      if (k >= hops.length) continue;
      for (final perm in _permutations(hops)) {
        if (!_prefixMatches(perm, prefix)) continue;
        final hop = perm[k];
        // Sentinels: bar == 24, off == -1; both fit in a single stable key.
        final key = (hop.from + 1) * 100 + (hop.to + 1);
        if (seen.add(key)) result.add(hop);
      }
    }
    return result;
  }

  /// Whether the first `prefix.length` hops of [perm] equal [prefix] by from/to.
  bool _prefixMatches(List<CheckerMove> perm, List<CheckerMove> prefix) {
    if (perm.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (perm[i].from != prefix[i].from || perm[i].to != prefix[i].to) {
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
