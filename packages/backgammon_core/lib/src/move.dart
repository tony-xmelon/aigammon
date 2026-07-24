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
class Move {
  final List<CheckerMove> checkerMoves;

  Move(List<CheckerMove> checkerMoves)
      : checkerMoves = List.unmodifiable(checkerMoves);

  static final Move none = Move(const []);

  /// True when both moves consist of the same hops, in any order.
  /// Hit flags are ignored: the same hop multiset always produces the same
  /// resulting position, so this is the right identity for validation.
  bool sameAs(Move other) {
    if (other.checkerMoves.length != checkerMoves.length) return false;
    List<String> key(Move m) =>
        [for (final c in m.checkerMoves) '${c.from}>${c.to}']..sort();
    final a = key(this);
    final b = key(other);
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      checkerMoves.isEmpty ? '(no play)' : checkerMoves.join(' ');
}
