import 'game_state.dart';
import 'move.dart';
import 'player.dart';

/// One entry in a game's append-only event log. Events carry no derived
/// state; folding them (see Game.replay) reproduces the GameState.
sealed class GameEvent {
  const GameEvent();

  Map<String, dynamic> toJson();

  /// Throws [FormatException] on any malformed input.
  static GameEvent fromJson(Map<String, dynamic> json) {
    try {
      final player = json['player'] != null
          ? Player.values.byName(json['player'] as String)
          : null;
      return switch (json['type'] as String) {
        'openingRoll' => OpeningRollEvent(
            whiteDie: (json['whiteDie'] as num).toInt(),
            blackDie: (json['blackDie'] as num).toInt())
          ..validate(),
        'roll' => RollEvent(player!, (json['die1'] as num).toInt(),
            (json['die2'] as num).toInt()),
        'move' => MoveEvent(player!, _moveFromJson(json['move'] as List)),
        'double' => DoubleEvent(player!),
        'take' => TakeEvent(player!),
        'drop' => DropEvent(player!),
        'resignOffer' => ResignOfferEvent(
            player!, ResignValue.values.byName(json['value'] as String)),
        'resignAccept' => ResignAcceptEvent(player!),
        'resignDecline' => ResignDeclineEvent(player!),
        final t => throw FormatException('unknown event type: $t'),
      };
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed GameEvent JSON: $e');
    }
  }

  static Move _moveFromJson(List<dynamic> hops) => Move([
        for (final h in hops)
          CheckerMove((h[0] as num).toInt(), (h[1] as num).toInt(),
              isHit: h[2] as bool),
      ]);

  static List<List<Object>> moveToJson(Move m) => [
        for (final c in m.checkerMoves) [c.from, c.to, c.isHit],
      ];
}

class OpeningRollEvent extends GameEvent {
  final int whiteDie;
  final int blackDie;
  const OpeningRollEvent({required this.whiteDie, required this.blackDie});

  void validate() {
    if (whiteDie == blackDie) {
      throw ArgumentError('opening roll ties are re-rolled, not recorded');
    }
  }

  Player get firstPlayer => whiteDie > blackDie ? Player.white : Player.black;

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'openingRoll', 'whiteDie': whiteDie, 'blackDie': blackDie};

  @override
  bool operator ==(Object other) =>
      other is OpeningRollEvent &&
      other.whiteDie == whiteDie &&
      other.blackDie == blackDie;
  @override
  int get hashCode => Object.hash(whiteDie, blackDie);
}

class RollEvent extends GameEvent {
  final Player player;
  final int die1;
  final int die2;
  const RollEvent(this.player, this.die1, this.die2);

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'roll', 'player': player.name, 'die1': die1, 'die2': die2};

  @override
  bool operator ==(Object other) =>
      other is RollEvent &&
      other.player == player &&
      other.die1 == die1 &&
      other.die2 == die2;
  @override
  int get hashCode => Object.hash(player, die1, die2);
}

class MoveEvent extends GameEvent {
  final Player player;
  final Move move;
  const MoveEvent(this.player, this.move);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'move',
        'player': player.name,
        'move': GameEvent.moveToJson(move),
      };

  @override
  bool operator ==(Object other) =>
      other is MoveEvent && other.player == player && other.move.sameAs(move);
  @override
  int get hashCode => Object.hash(player, move.checkerMoves.length);
}

class DoubleEvent extends GameEvent {
  final Player player;
  const DoubleEvent(this.player);
  @override
  Map<String, dynamic> toJson() => {'type': 'double', 'player': player.name};
  @override
  bool operator ==(Object other) =>
      other is DoubleEvent && other.player == player;
  @override
  int get hashCode => Object.hash('double', player);
}

class TakeEvent extends GameEvent {
  final Player player;
  const TakeEvent(this.player);
  @override
  Map<String, dynamic> toJson() => {'type': 'take', 'player': player.name};
  @override
  bool operator ==(Object other) =>
      other is TakeEvent && other.player == player;
  @override
  int get hashCode => Object.hash('take', player);
}

class DropEvent extends GameEvent {
  final Player player;
  const DropEvent(this.player);
  @override
  Map<String, dynamic> toJson() => {'type': 'drop', 'player': player.name};
  @override
  bool operator ==(Object other) =>
      other is DropEvent && other.player == player;
  @override
  int get hashCode => Object.hash('drop', player);
}

class ResignOfferEvent extends GameEvent {
  final Player player;
  final ResignValue value;
  const ResignOfferEvent(this.player, this.value);
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'resignOffer', 'player': player.name, 'value': value.name};
  @override
  bool operator ==(Object other) =>
      other is ResignOfferEvent &&
      other.player == player &&
      other.value == value;
  @override
  int get hashCode => Object.hash(player, value);
}

class ResignAcceptEvent extends GameEvent {
  final Player player;
  const ResignAcceptEvent(this.player);
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'resignAccept', 'player': player.name};
  @override
  bool operator ==(Object other) =>
      other is ResignAcceptEvent && other.player == player;
  @override
  int get hashCode => Object.hash('resignAccept', player);
}

class ResignDeclineEvent extends GameEvent {
  final Player player;
  const ResignDeclineEvent(this.player);
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'resignDecline', 'player': player.name};
  @override
  bool operator ==(Object other) =>
      other is ResignDeclineEvent && other.player == player;
  @override
  int get hashCode => Object.hash('resignDecline', player);
}
