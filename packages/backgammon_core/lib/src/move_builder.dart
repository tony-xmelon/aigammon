import 'board_state.dart';
import 'dice.dart';
import 'game_state.dart';
import 'move.dart';
import 'move_generator.dart';
import 'player.dart';

/// Builds a full-turn [Move] hop by hop, always staying inside the legal set.
///
/// Construct with [MoveBuilder.forState] (what the board does) or, position-free,
/// with the current position's legal moves. The builder narrows candidates as
/// hops are chosen: a candidate survives while some permutation of its hops
/// starts with the chosen hops (compared by from/to, ignoring hit flags).
/// Because turns are at most 4 hops, permutation matching is brute-force.
///
/// The builder offers only hops that appear in surviving candidates, so a
/// completed sequence always corresponds to a legal move (possibly entered as
/// a reordering). The builder accepts reordered *entry* but [build] always
/// emits the canonical playable ordering of the matched legal move — never the
/// user's tap order — because `BoardState.applyMove` is order-dependent for a
/// single checker transiting a point it vacates (see [build]).
///
/// ## Position awareness ([MoveBuilder.forState])
///
/// The plain constructor can only offer what the supplied move list spells out,
/// and `legalMoves` lists ONE representative decomposition per resulting
/// position. That stranded checkers mid-turn: after 13/9 of a 4-1 the same
/// checker could not play the 1, because the listed representative of that
/// position runs 13/12 12/8 (a P0 live-play bug — "I cannot make the second move
/// with the same checker"). [MoveBuilder.forState] therefore feeds in
/// [MoveGenerator.legalVariants] — every distinct hop multiset per position —
/// and each variant maps back to the same canonical move for [build].
///
/// Knowing the position also lets the builder offer only hops that are PLAYABLE
/// right now: a permutation may reorder a transit chain into a hop whose source
/// is empty (offering the empty 12-point as a "source" and previewing a phantom
/// checker). Such hops are filtered out, so [selectableSources] is exactly what
/// the user can pick up. Both refinements are additive — the position-free
/// constructor behaves exactly as it always did.
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
///
/// The playability filter cannot break that, because for any surviving candidate
/// SOME playable ordering of its remaining hops always exists:
///
/// * hops move strictly toward the mover's home (index strictly decreasing for
///   White, increasing for Black, with the bar above every point and `off` below
///   every point), so "hop A feeds hop B" — A's landing is B's source — is a
///   strict order and the remaining hops form a DAG;
/// * take the remaining hop whose SOURCE is furthest back. No remaining hop can
///   feed it (that would need a source further back still), so every hop that
///   delivers a checker to that source has already been played, and the
///   candidate's own canonical ordering therefore leaves a checker standing
///   there: the hop is playable now;
/// * bar-first falls out of the same ordering — the bar is the furthest-back
///   location of all, so while a checker sits on it the furthest-back remaining
///   hop is a bar hop, which is exactly the one the rules demand;
/// * a bear-off hop is likewise last among the hops of its own checker, and its
///   preconditions (all home, overshoot only from the back checker) are those the
///   generator already satisfied at that point of the canonical ordering.
///
/// `move_entry_property_test.dart` proves all of this empirically over hundreds
/// of real positions, in both modes, including that no offered hop is illegal at
/// the moment it is offered.
class MoveBuilder {
  final List<Move> _legal;

  /// Every enterable hop sequence, each mapped to the legal move it commits.
  /// One per legal move for the position-free constructor; one per
  /// [MoveVariants.decompositions] entry when the position is known.
  final List<_Candidate> _candidates;

  /// The position the turn starts from, when known: enables the playability
  /// filter in [_computeNextHops]. `null` for the position-free constructor.
  final BoardState? _board;
  final Player? _player;

  /// The roll, known exactly when [_board] is (both come from the same state).
  /// Only the bear-off filter needs it — see [_canBearOff].
  final Dice? _dice;

  final List<CheckerMove> _chosen = [];

  /// Next-hop options for the current prefix, deduped by (from, to). Cached and
  /// recomputed whenever the prefix changes.
  List<CheckerMove> _nextHops = const [];

  /// [chainedDestinationsFor]'s answers for the CURRENT prefix, keyed by source.
  /// Dropped wholesale by [_recompute] — i.e. by every prefix change — which is
  /// the only thing the answer depends on besides the source, so an entry can
  /// never go stale. The builder itself is per-position (a new turn, a new
  /// position, or a new game builds a new one), so nothing survives a turn.
  ///
  /// The cache exists because the board view asks for a source's chained
  /// destinations on every drag frame — many times a second, with an unchanged
  /// prefix — and each answer is a permutation-enumerating DFS.
  final Map<int, Set<int>> _chainCache = {};

  /// How many chained-destination searches have actually RUN (cache misses).
  /// Exposed so the memoization has a regression test: repeating a
  /// [chainedDestinationsFor] call must not advance this.
  int get chainSearches => _chainSearches;
  int _chainSearches = 0;

  /// The board the CHOSEN prefix has reached, when the position is known — the
  /// base for the playability filter and for the chain DFS, which carries it
  /// forward hop by hop. `null` for the position-free constructor.
  BoardState? _position;

  /// Position-free: offers exactly the decompositions listed in [legalMoves]
  /// (plus their reorderings). Prefer [MoveBuilder.forState] for live entry.
  MoveBuilder(List<Move> legalMoves)
      : _legal = List.of(legalMoves),
        _candidates = [
          for (final m in legalMoves) _Candidate(m.checkerMoves, m),
        ],
        _board = null,
        _player = null,
        _dice = null {
    _recompute();
  }

  /// Position-aware builder for [state]'s moving phase: every playable way to
  /// enter each legal move is offered, and only hops playable from the live
  /// position are. Empty (nothing selectable) outside the moving phase.
  MoveBuilder.forState(GameState state)
      : this._variants(
          state.phase == GamePhase.moving
              ? MoveGenerator.legalVariants(state.board, state.turn, state.dice!)
              : const [],
          state.board,
          state.turn,
          state.dice,
        );

  MoveBuilder._variants(List<MoveVariants> variants, BoardState board,
      Player player, Dice? dice)
      : _legal = [for (final v in variants) v.canonical],
        _candidates = [
          for (final v in variants)
            for (final d in v.decompositions)
              _Candidate(d.checkerMoves, v.canonical),
        ],
        _board = board,
        _player = player,
        _dice = dice {
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
  ///
  /// Memoized per source for the current prefix (see [_chainCache]); the
  /// returned set is unmodifiable because it is the cached one.
  Set<int> chainedDestinationsFor(int source) {
    final cached = _chainCache[source];
    if (cached != null) return cached;
    _chainSearches++;
    final out = <int>{};
    _collectChains(List.of(_chosen), _position, source, const [], out);
    final answer = Set<int>.unmodifiable(out);
    _chainCache[source] = answer;
    return answer;
  }

  /// One enterable hop sequence (length ≥ 2) that runs the same checker from
  /// [source] to [landing], or an empty list when no such chain exists.
  ///
  /// The returned hops are guaranteed enterable in order via [addHop] from the
  /// current prefix. When several routes reach [landing] (e.g. 24/23/20 vs.
  /// 24/21/20) an arbitrary but valid one is returned.
  List<CheckerMove> chainFor(int source, int landing) =>
      _findChain(List.of(_chosen), _position, source, landing, const []) ??
      const [];

  /// DFS from [currentPos] (the same checker's current location) collecting the
  /// landings of every enterable chain of length ≥ 2 into [out]. [prefix] is the
  /// hypothetical chosen sequence (real prefix + chain so far), [position] the
  /// board it produces (null when the position is unknown), and [chain] the
  /// same-checker hops accumulated from [source]. The position is carried down
  /// one hop at a time rather than rebuilt per node.
  void _collectChains(List<CheckerMove> prefix, BoardState? position,
      int currentPos, List<CheckerMove> chain, Set<int> out) {
    for (final h in _computeNextHops(prefix, position)) {
      if (h.from != currentPos) continue; // must continue the SAME checker
      final next = [...chain, h];
      if (next.length >= 2) out.add(h.to);
      if (h.to == CheckerMove.off) continue; // a borne-off checker cannot go on
      _collectChains([...prefix, h], _advance(position, h), h.to, next, out);
    }
  }

  /// DFS variant returning the first enterable chain (length ≥ 2) whose final
  /// hop lands on [landing], or `null`.
  List<CheckerMove>? _findChain(List<CheckerMove> prefix, BoardState? position,
      int currentPos, int landing, List<CheckerMove> chain) {
    for (final h in _computeNextHops(prefix, position)) {
      if (h.from != currentPos) continue;
      final next = [...chain, h];
      if (next.length >= 2 && h.to == landing) return next;
      if (h.to == CheckerMove.off) continue;
      final found =
          _findChain([...prefix, h], _advance(position, h), h.to, landing, next);
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
    // The entered hops are one of the offered decompositions (in some order);
    // commit the canonical move it maps to.
    for (final c in _candidates) {
      if (Move(c.hops).sameAs(entered)) return c.move;
    }
    return _legal.firstWhere((m) => m.sameAs(entered));
  }

  /// Recomputes the position the chosen prefix has reached and the next-hop
  /// options from it. Both are cached until the prefix changes.
  ///
  /// The prefix is also the only input to [_chainCache], so it is dropped here:
  /// every path that changes [_chosen] ([addHop], [undoHop], [reset], and
  /// construction) ends in this method.
  void _recompute() {
    _chainCache.clear();
    var position = _board;
    if (position != null) {
      for (final hop in _chosen) {
        position = _advance(position, hop);
      }
    }
    _position = position;
    _nextHops = _computeNextHops(_chosen, position);
  }

  /// The next-hop options for an arbitrary [prefix]: for every candidate
  /// decomposition and every permutation of its hops whose first `prefix.length`
  /// hops equal [prefix] (by from/to), the next hop is offered (deduped by
  /// from/to). When the position is known, a hop whose source holds no checker of
  /// the mover's at this point in the turn is skipped — a permutation may reorder
  /// a transit chain into an unplayable order.
  ///
  /// [position] is the board [prefix] produces (`null` when this builder does not
  /// know the position, which switches the playability filter off).
  ///
  /// Used both for the live prefix (via [_recompute]) and for the hypothetical
  /// prefixes explored while enumerating combined-move chains, so chain hops are
  /// exactly the hops the builder would offer when they are played.
  List<CheckerMove> _computeNextHops(
      List<CheckerMove> prefix, BoardState? position) {
    final k = prefix.length;
    final result = <CheckerMove>[];
    final seen = <int>{};
    for (final candidate in _candidates) {
      final hops = candidate.hops;
      if (k >= hops.length) continue;
      for (final perm in _permutations(hops)) {
        if (!_prefixMatches(perm, prefix)) continue;
        final hop = perm[k];
        // Sentinels: bar == 24, off == -1; both fit in a single stable key.
        final key = (hop.from + 1) * 100 + (hop.to + 1);
        if (!seen.add(key)) continue; // already decided about this hop
        // Playability does not depend on WHICH candidate offered the hop, so a
        // rejected hop stays rejected for this prefix (hence the seen key above).
        if (position != null && !_isPlayable(hop, position, prefix)) continue;
        result.add(hop);
      }
    }
    return result;
  }

  /// [position] with [hop] played, or `null` when the position is unknown.
  BoardState? _advance(BoardState? position, CheckerMove hop) =>
      position?.applyMove(_player!, Move([hop]));

  /// Whether [hop] is legal to play RIGHT NOW — at [position], the board the
  /// already-chosen [prefix] has reached.
  ///
  /// Two things can make a hop of a legal move unplayable in a reordering:
  ///
  /// * its source may be empty (the mover's checker has not arrived there yet, or
  ///   it must come off the bar first);
  /// * it may be a BEAR-OFF whose preconditions are not met yet — see
  ///   [_canBearOff].
  ///
  /// A point-to-point LANDING needs no check: the opponent never adds checkers
  /// during the turn, so a landing that is legal in the candidate's own order is
  /// legal in any order.
  bool _isPlayable(
      CheckerMove hop, BoardState position, List<CheckerMove> prefix) {
    final player = _player!;
    final onBar = position.barFor(player);
    if (hop.from == CheckerMove.bar) {
      if (onBar == 0) return false;
    } else {
      if (onBar > 0) return false; // the bar is served first
      final n = position.points[hop.from];
      if (player == Player.white ? n <= 0 : n >= 0) return false;
    }
    if (hop.to == CheckerMove.off) return _canBearOff(hop.from, position, prefix);
    return true;
  }

  /// Whether a checker may be borne off [from] at [position] with the dice still
  /// in hand after [prefix].
  ///
  /// Bearing off needs every checker home, and a die LARGER than the point's
  /// distance (an overshoot) may only lift the furthest-back checker. Both
  /// conditions depend on the position mid-turn, so a legal move's off-hop can be
  /// illegal as a FIRST hop: `7/6 4/off` reordered puts the bear-off before the
  /// straggler comes home, and `4/off 2/off` on a 6-4 reordered overshoots the
  /// 2-point while the 4-point is still occupied. Neither is offered.
  bool _canBearOff(int from, BoardState position, List<CheckerMove> prefix) {
    final player = _player!;
    if (position.barFor(player) > 0) return false;
    final white = player == Player.white;
    // Every checker inside the mover's home board (White 0-5, Black 18-23).
    for (var i = 0; i < 24; i++) {
      final n = position.points[i];
      final mine = white ? n > 0 : n < 0;
      if (!mine) continue;
      if (white ? i > 5 : i < 18) return false;
    }
    final distance = white ? from + 1 : 24 - from;
    // The furthest-back checker: the highest index for White, lowest for Black.
    var furthest = from;
    for (var i = 0; i < 24; i++) {
      final n = position.points[i];
      final mine = white ? n > 0 : n < 0;
      if (!mine) continue;
      if (white ? i > furthest : i < furthest) furthest = i;
    }
    for (final die in _remainingDice(prefix)) {
      if (die == distance) return true; // exact: from any point
      if (die > distance && from == furthest) return true; // overshoot: back only
    }
    return false;
  }

  /// The dice values not yet spent by [prefix]. Each hop consumes the die its pip
  /// distance names, except a bear-off overshoot, which consumes the smallest
  /// remaining die that covers the distance (the same attribution the board uses
  /// to dim spent dice).
  List<int> _remainingDice(List<CheckerMove> prefix) {
    final dice = _dice;
    if (dice == null) return const [];
    final remaining = dice.isDouble
        ? <int>[dice.die1, dice.die1, dice.die1, dice.die1]
        : <int>[dice.die1, dice.die2];
    for (final hop in prefix) {
      final distance = _pipsOf(hop);
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

  /// The pip distance [hop] covers for the mover — the die it consumed, except a
  /// bear-off overshoot, where the die may be larger.
  int _pipsOf(CheckerMove hop) {
    final white = _player == Player.white;
    final from = hop.from == CheckerMove.bar ? (white ? 24 : -1) : hop.from;
    if (hop.to == CheckerMove.off) return white ? from + 1 : 24 - from;
    return white ? from - hop.to : hop.to - from;
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
  /// 4! = 24 permutations per candidate — cheap to enumerate exhaustively.
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

/// One enterable hop sequence and the legal move it commits. Several candidates
/// can share a [move] — the different ways to enter the same resulting position
/// (see [MoveVariants]).
class _Candidate {
  _Candidate(this.hops, this.move);

  final List<CheckerMove> hops;
  final Move move;
}
