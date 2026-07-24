import 'dice.dart';
import 'game_events.dart';
import 'game_state.dart';
import 'player.dart';

/// A single game as an event log plus its folded state. Appending an event
/// validates it against the state machine; replay rebuilds from scratch.
class Game {
  final List<GameEvent> events;
  final GameState state;

  Game._(this.events, this.state);

  /// Starts a fresh game from the opening roll.
  factory Game.start(OpeningRollEvent opening, {bool isCrawfordGame = false}) =>
      Game.replay([opening], isCrawfordGame: isCrawfordGame);

  /// Rebuilds a game by folding [events] over the initial state.
  ///
  /// isCrawfordGame is match context supplied out of band (from MatchState);
  /// peers replaying the same events must agree on it.
  factory Game.replay(List<GameEvent> events, {bool isCrawfordGame = false}) {
    if (events.isEmpty || events.first is! OpeningRollEvent) {
      throw StateError('a game starts with an OpeningRollEvent');
    }
    final opening = events.first as OpeningRollEvent..validate();
    var state = GameState.opening(
      firstPlayer: opening.firstPlayer,
      openingDice: Dice(opening.whiteDie, opening.blackDie),
      isCrawfordGame: isCrawfordGame,
    );
    for (final event in events.skip(1)) {
      state = _apply(state, event);
    }
    return Game._(List.unmodifiable(events), state);
  }

  Game append(GameEvent event) =>
      Game._(List.unmodifiable([...events, event]), _apply(state, event));

  static GameState _apply(GameState s, GameEvent e) => switch (e) {
        OpeningRollEvent() =>
          throw StateError('opening roll must be the first event'),
        RollEvent(:final player, :final die1, :final die2) =>
          _forPlayer(s, player, () => s.roll(Dice(die1, die2))),
        MoveEvent(:final player, :final move) =>
          _forPlayer(s, player, () => s.play(move)),
        DoubleEvent(:final player) =>
          _forPlayer(s, player, () => s.offerDouble()),
        TakeEvent(:final player) => _forPlayer(s, player, () => s.take()),
        DropEvent(:final player) => _forPlayer(s, player, () => s.drop()),
        ResignOfferEvent(:final player, :final value) =>
          _forPlayer(s, player, () => s.offerResign(value)),
        ResignAcceptEvent(:final player) =>
          _forPlayer(s, player, () => s.acceptResign()),
        ResignDeclineEvent(:final player) =>
          _forPlayer(s, player, () => s.declineResign()),
      };

  static GameState _forPlayer(
      GameState s, Player player, GameState Function() action) {
    if (s.turn != player) {
      throw StateError('event out of turn: expected ${s.turn}, got $player');
    }
    return action();
  }
}
