/// One checker moved by one die. Indices are from White's perspective
/// (0-23) regardless of who moves; [bar] and [off] are sentinels.
class CheckerMove {
  static const int bar = 24;
  static const int off = -1;

  final int from;
  final int to;
  final bool isHit;

  const CheckerMove(this.from, this.to, {this.isHit = false});

  @override
  bool operator ==(Object other) =>
      other is CheckerMove &&
      other.from == from &&
      other.to == to &&
      other.isHit == isHit;

  @override
  int get hashCode => Object.hash(from, to, isHit);

  @override
  String toString() {
    final f = from == bar ? 'bar' : '${from + 1}';
    final t = to == off ? 'off' : '${to + 1}';
    return '$f/$t${isHit ? '*' : ''}';
  }
}

/// A full turn: every checker moved for one dice roll, in a playable order.
/// An empty move is a dance (no legal play).
///
/// Note: `Move` has no value `==` — identity comparison only. Use [sameAs]
/// for order-insensitive value comparison; do not use `Move` as a Set/Map
/// key expecting value semantics.
class Move {
  final List<CheckerMove> checkerMoves;

  Move(List<CheckerMove> checkerMoves)
      : checkerMoves = List.unmodifiable(checkerMoves);

  static final Move none = Move(const []);

  /// This move's hops as ONE integer, independent of the order they are listed
  /// in — the identity [sameAs] compares, and the key the generator files its
  /// alternative decompositions under.
  ///
  /// Each hop packs into `(from + 1) * 100 + (to + 1)` (100..2500, with the
  /// [CheckerMove.bar] and [CheckerMove.off] sentinels inside the range), and up
  /// to four SORTED hop codes pack base-2600 into one int — comfortably inside
  /// the 2^53 that stays exact on every Dart backend. Sorting makes it
  /// order-insensitive; a move's key is computed once and kept.
  ///
  /// `null` when ANY hop falls outside the board, which no generated move ever
  /// does but a submission from a remote peer or a replayed log certainly can.
  /// The base-100 digit would carry, and a hop like 3/100 would pack to exactly
  /// the code of the legal 4/off — aliasing a bogus play onto a real one across
  /// the trust boundary. Out of range means "no key", and [sameAs] compares
  /// such moves the slow, exact way instead.
  late final int? hopSetKey = _computeHopSetKey();

  int? _computeHopSetKey() {
    final codes = <int>[];
    for (final h in checkerMoves) {
      final fromOk = h.from == CheckerMove.bar || (h.from >= 0 && h.from < 24);
      final toOk = h.to == CheckerMove.off || (h.to >= 0 && h.to < 24);
      if (!fromOk || !toOk) return null;
      codes.add((h.from + 1) * 100 + (h.to + 1));
    }
    codes.sort();
    var key = 0;
    for (final code in codes) {
      key = key * 2600 + code;
    }
    return key;
  }

  /// True when both moves consist of the same hops, in any order.
  /// Hit flags are ignored: the same hop multiset always produces the same
  /// resulting position, so this is the right identity for validation.
  ///
  /// One integer comparison in the normal case (see [hopSetKey]). This used to
  /// build two lists of strings and sort them on every call, which
  /// `GameState.canonicalPlay` makes once per legal move and then once per
  /// decomposition of every legal move — for every move played, by either side,
  /// live and on every replay of a persisted log.
  bool sameAs(Move other) {
    if (other.checkerMoves.length != checkerMoves.length) return false;
    final mine = hopSetKey;
    final theirs = other.hopSetKey;
    if (mine != null && theirs != null) return mine == theirs;
    return _sameHopsUnpacked(other);
  }

  /// [sameAs] for moves carrying an off-board hop: a plain multiset match on
  /// (from, to), quadratic in a length that never exceeds four.
  bool _sameHopsUnpacked(Move other) {
    final remaining = List.of(other.checkerMoves);
    for (final h in checkerMoves) {
      final at = remaining
          .indexWhere((o) => o.from == h.from && o.to == h.to);
      if (at < 0) return false;
      remaining.removeAt(at);
    }
    return remaining.isEmpty;
  }

  @override
  String toString() =>
      checkerMoves.isEmpty ? '(no play)' : checkerMoves.join(' ');
}
