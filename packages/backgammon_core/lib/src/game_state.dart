import 'board_state.dart';
import 'dice.dart';
import 'move.dart';
import 'move_generator.dart';
import 'player.dart';

enum GamePhase { awaitingRoll, moving, cubeOffered, resignOffered, gameOver }

enum GameOutcome { single, gammon, backgammon, drop, resignation }

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

  const GameState._({
    required this.board,
    required this.turn,
    required this.phase,
    required this.dice,
    required this.cube,
    required this.isCrawfordGame,
    required this.result,
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
  }) =>
      GameState._(
        board: board ?? this.board,
        turn: turn ?? this.turn,
        phase: phase ?? this.phase,
        dice: clearDice ? null : (dice ?? this.dice),
        cube: cube ?? this.cube,
        isCrawfordGame: isCrawfordGame,
        result: result ?? this.result,
      );

  void _require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  List<Move> get legalMoves => phase == GamePhase.moving
      ? MoveGenerator.legalMoves(board, turn, dice!)
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

  GameState play(Move move) {
    _require(phase == GamePhase.moving, 'not in the moving phase');
    final legal = legalMoves;
    if (legal.isEmpty) {
      _require(move.checkerMoves.isEmpty, 'no legal moves: must pass');
      return _copy(
          turn: turn.opponent, phase: GamePhase.awaitingRoll, clearDice: true);
    }
    _require(_isLegal(move, legal), 'illegal move: $move');
    final next = board.applyMove(turn, move);
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

  /// A submitted move is legal when it matches a generated move hop-for-hop
  /// (sameAs), or — because the generator dedupes transit-equivalent
  /// decompositions to one representative — when applying it reaches the
  /// same resulting position as some legal move.
  bool _isLegal(Move move, List<Move> legal) {
    if (legal.any((m) => m.sameAs(move))) return true;
    if (move.checkerMoves.length != legal.first.checkerMoves.length) {
      return false;
    }
    for (final cm in move.checkerMoves) {
      final fromOk = cm.from == CheckerMove.bar || (cm.from >= 0 && cm.from < 24);
      final toOk = cm.to == CheckerMove.off || (cm.to >= 0 && cm.to < 24);
      if (!fromOk || !toOk) return false;
    }
    final resulting = board.applyMove(turn, move);
    return legal.any((m) => board.applyMove(turn, m) == resulting);
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
}
