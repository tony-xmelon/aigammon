import 'board_state.dart';
import 'dice.dart';
import 'move.dart';
import 'move_generator.dart';
import 'player.dart';

enum GamePhase { awaitingRoll, moving, cubeOffered, resignOffered, gameOver }

enum GameOutcome { single, gammon, backgammon, drop, resignation }

enum ResignValue {
  single(1),
  gammon(2),
  backgammon(3);

  final int multiplier;
  const ResignValue(this.multiplier);
}

class ResignOffer {
  final Player by;
  final ResignValue value;
  const ResignOffer({required this.by, required this.value});

  @override
  bool operator ==(Object other) =>
      other is ResignOffer && other.by == by && other.value == value;

  @override
  int get hashCode => Object.hash(by, value);
}

class CubeState {
  final int value;
  final Player? owner; // null = centered

  const CubeState({required this.value, required this.owner});
  const CubeState.initial() : this(value: 1, owner: null);

  @override
  bool operator ==(Object other) =>
      other is CubeState && other.value == value && other.owner == owner;

  @override
  int get hashCode => Object.hash(value, owner);
}

class GameResult {
  final Player winner;
  final int points;
  final GameOutcome outcome;

  const GameResult(
      {required this.winner, required this.points, required this.outcome});

  @override
  bool operator ==(Object other) =>
      other is GameResult &&
      other.winner == winner &&
      other.points == points &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(winner, points, outcome);
}

/// Immutable game state machine. All mutating verbs return a new state and
/// throw [StateError] on illegal transitions.
class GameState {
  final BoardState board;
  final Player turn;
  final GamePhase phase;
  final Dice? dice;
  final CubeState cube;
  final bool isCrawfordGame;
  final GameResult? result;
  final ResignOffer? resignOffer;

  const GameState._({
    required this.board,
    required this.turn,
    required this.phase,
    required this.dice,
    required this.cube,
    required this.isCrawfordGame,
    required this.result,
    required this.resignOffer,
  });

  /// Start of game: the opening roll decided [firstPlayer], who now plays
  /// [openingDice] (never a double — ties are re-rolled by the caller).
  factory GameState.opening({
    required Player firstPlayer,
    required Dice openingDice,
    bool isCrawfordGame = false,
  }) {
    if (openingDice.isDouble) {
      throw ArgumentError('opening roll cannot be a double');
    }
    return GameState._(
      board: BoardState.initial(),
      turn: firstPlayer,
      phase: GamePhase.moving,
      dice: openingDice,
      cube: const CubeState.initial(),
      isCrawfordGame: isCrawfordGame,
      result: null,
      resignOffer: null,
    );
  }

  /// Arbitrary state for tests and analysis tooling.
  factory GameState.testState({
    required BoardState board,
    required Player turn,
    required GamePhase phase,
    Dice? dice,
    CubeState cube = const CubeState.initial(),
    bool isCrawfordGame = false,
  }) {
    if (phase == GamePhase.moving && dice == null) {
      throw ArgumentError('moving phase requires dice');
    }
    return GameState._(
        board: board,
        turn: turn,
        phase: phase,
        dice: dice,
        cube: cube,
        isCrawfordGame: isCrawfordGame,
        result: null,
        resignOffer: null,
      );
  }

  // clearDice explicitly nulls dice on turn handoff; result has no matching
  // flag because it is terminal-only and never needs clearing.
  GameState _copy({
    BoardState? board,
    Player? turn,
    GamePhase? phase,
    Dice? dice,
    bool clearDice = false,
    CubeState? cube,
    GameResult? result,
    ResignOffer? resignOffer,
    bool clearResignOffer = false,
  }) =>
      GameState._(
        board: board ?? this.board,
        turn: turn ?? this.turn,
        phase: phase ?? this.phase,
        dice: clearDice ? null : (dice ?? this.dice),
        cube: cube ?? this.cube,
        isCrawfordGame: isCrawfordGame,
        result: result ?? this.result,
        resignOffer:
            clearResignOffer ? null : (resignOffer ?? this.resignOffer),
      );

  void _require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  List<Move> get legalMoves => phase == GamePhase.moving
      ? MoveGenerator.legalMoves(board, turn, dice!)
      : const [];

  /// [legalMoves] with every distinct way of ENTERING each move (see
  /// [MoveVariants]) — what hop-by-hop entry needs so the checker a user has just
  /// moved can still play the other die.
  ///
  /// [MoveBuilder.forState] gets the same list straight from
  /// [MoveGenerator.legalVariants]; this getter is the convenient way to inspect
  /// it (tests, debugging) without repeating the phase check.
  List<MoveVariants> get legalVariants => phase == GamePhase.moving
      ? MoveGenerator.legalVariants(board, turn, dice!)
      : const [];

  GameState roll(Dice d) {
    _require(phase == GamePhase.awaitingRoll, 'not awaiting a roll');
    return _copy(dice: d, phase: GamePhase.moving);
  }

  GameState offerDouble() {
    _require(phase == GamePhase.awaitingRoll, 'can only double before rolling');
    _require(!isCrawfordGame, 'no doubling in the Crawford game');
    _require(cube.owner == null || cube.owner == turn,
        'only the cube owner may double');
    return _copy(phase: GamePhase.cubeOffered, turn: turn.opponent);
  }

  GameState take() {
    _require(phase == GamePhase.cubeOffered, 'no double is pending');
    return _copy(
      cube: CubeState(value: cube.value * 2, owner: turn),
      turn: turn.opponent,
      phase: GamePhase.awaitingRoll,
    );
  }

  GameState drop() {
    _require(phase == GamePhase.cubeOffered, 'no double is pending');
    return _copy(
      phase: GamePhase.gameOver,
      result: GameResult(
        winner: turn.opponent,
        points: cube.value,
        outcome: GameOutcome.drop,
      ),
    );
  }

  // Resign offers carry an explicit ResignOffer record, whereas the cube verbs
  // encode the offerer purely via a turn-flip. The two modeling styles coexist
  // deliberately: resignation can be offered mid-turn (from `moving`), so
  // declineResign must restore the exact prior context, which the record makes
  // possible. Do not "simplify" one style into the other.
  GameState offerResign(ResignValue value) {
    _require(phase == GamePhase.awaitingRoll || phase == GamePhase.moving,
        'cannot resign now');
    return _copy(
      phase: GamePhase.resignOffered,
      turn: turn.opponent,
      resignOffer: ResignOffer(by: turn, value: value),
    );
  }

  GameState acceptResign() {
    _require(phase == GamePhase.resignOffered, 'no resignation is pending');
    final offer = resignOffer!;
    return _copy(
      phase: GamePhase.gameOver,
      clearResignOffer: true,
      result: GameResult(
        winner: offer.by.opponent,
        points: cube.value * offer.value.multiplier,
        outcome: GameOutcome.resignation,
      ),
    );
  }

  GameState declineResign() {
    _require(phase == GamePhase.resignOffered, 'no resignation is pending');
    final offer = resignOffer!;
    // Prior phase is inferred from dice in exactly this one place.
    return _copy(
      phase: dice == null ? GamePhase.awaitingRoll : GamePhase.moving,
      turn: offer.by,
      clearResignOffer: true,
    );
  }

  /// The CANONICAL legal move a submitted [move] denotes, or null when [move]
  /// is not a legal play here. The single place legality of a play is decided:
  /// [play] applies the answer, and a remote authority (see `lan_play`'s
  /// HostAuthority) validates AND records it.
  ///
  /// Two kinds of submission map onto a legal move:
  ///  * one whose hops form the same MULTISET ([Move.sameAs]) — hop order is
  ///    the submitter's business, never the board's;
  ///  * one that reaches the same POSITION as a legal move but splits the hops
  ///    differently — a transit-equivalent decomposition [MoveGenerator]
  ///    deduped away, which hop-by-hop entry can still produce.
  ///
  /// Both resolve to the GENERATOR's representative, and callers must use that
  /// rather than the submission, for two reasons: [BoardState.applyMove] is
  /// order-dependent for a single checker transiting a point it vacates, and
  /// the representative carries the engine's own hit flags instead of whatever
  /// the submitter claimed.
  ///
  /// A dance (no legal moves) canonicalises to [Move.none].
  Move? canonicalPlay(Move move) {
    if (phase != GamePhase.moving) return null;
    final legal = legalMoves;
    if (legal.isEmpty) return move.checkerMoves.isEmpty ? Move.none : null;
    for (final m in legal) {
      if (m.sameAs(move)) return m;
    }
    if (move.checkerMoves.length != legal.first.checkerMoves.length) return null;
    for (final cm in move.checkerMoves) {
      final fromOk =
          cm.from == CheckerMove.bar || (cm.from >= 0 && cm.from < 24);
      final toOk = cm.to == CheckerMove.off || (cm.to >= 0 && cm.to < 24);
      if (!fromOk || !toOk) return null;
    }
    final resulting = board.applyMove(turn, move);
    for (final m in legal) {
      if (board.applyMove(turn, m) == resulting) return m;
    }
    return null;
  }

  /// Whether [move] is a legal play in this state — [canonicalPlay] without the
  /// answer.
  bool isLegalPlay(Move move) => canonicalPlay(move) != null;

  GameState play(Move move) {
    _require(phase == GamePhase.moving, 'not in the moving phase');
    final canonical = canonicalPlay(move);
    if (canonical == null) {
      _require(legalMoves.isNotEmpty, 'no legal moves: must pass');
      throw StateError('illegal move: $move');
    }
    // Only a dance canonicalises to an empty move (legal moves always have
    // hops), so an empty answer means "pass".
    if (canonical.checkerMoves.isEmpty) {
      return _copy(
          turn: turn.opponent, phase: GamePhase.awaitingRoll, clearDice: true);
    }
    final next = board.applyMove(turn, canonical);
    if (next.offFor(turn) == 15) {
      return _copy(
          board: next, phase: GamePhase.gameOver, result: _winResult(next));
    }
    return _copy(
        board: next,
        turn: turn.opponent,
        phase: GamePhase.awaitingRoll,
        clearDice: true);
  }

  GameResult _winResult(BoardState finalBoard) {
    final loser = turn.opponent;
    var outcome = GameOutcome.single;
    if (finalBoard.offFor(loser) == 0) {
      outcome = _loserTrappedForBackgammon(finalBoard, loser)
          ? GameOutcome.backgammon
          : GameOutcome.gammon;
    }
    final multiplier = switch (outcome) {
      GameOutcome.single => 1,
      GameOutcome.gammon => 2,
      GameOutcome.backgammon => 3,
      _ => throw StateError('unreachable'),
    };
    return GameResult(
        winner: turn, points: cube.value * multiplier, outcome: outcome);
  }

  /// Backgammon: the loser still has a checker on the bar or in the
  /// winner's home board.
  bool _loserTrappedForBackgammon(BoardState b, Player loser) {
    if (b.barFor(loser) > 0) return true;
    // Winner's home board: indices 0-5 when White wins, 18-23 when Black.
    final range = turn == Player.white
        ? [0, 1, 2, 3, 4, 5]
        : [18, 19, 20, 21, 22, 23];
    for (final i in range) {
      final c = b.points[i];
      if (loser == Player.white ? c > 0 : c < 0) return true;
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      other is GameState &&
      other.board == board &&
      other.turn == turn &&
      other.phase == phase &&
      other.dice == dice &&
      other.cube == cube &&
      other.isCrawfordGame == isCrawfordGame &&
      other.resignOffer == resignOffer &&
      other.result == result;

  @override
  int get hashCode => Object.hash(
      board, turn, phase, dice, cube, isCrawfordGame, resignOffer, result);
}
