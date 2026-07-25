import 'package:backgammon_core/backgammon_core.dart';

/// One rendered line of a game's move history.
///
/// [text] is the fully-formatted line (turn number, roll, notation, …) and
/// [actor] is the player whose action the line describes — used by the UI to
/// tint a leading dot — or `null` for a neutral line such as the opening roll.
class RecordLine {
  const RecordLine(this.text, {this.actor});

  final String text;
  final Player? actor;

  @override
  bool operator ==(Object other) =>
      other is RecordLine && other.text == text && other.actor == actor;

  @override
  int get hashCode => Object.hash(text, actor);

  @override
  String toString() => 'RecordLine($text, $actor)';
}

/// Folds a game's append-only [events] into human-readable, turn-numbered
/// history lines.
///
/// The opening roll becomes a neutral header ("Opening: W 3 — B 1 (W starts)")
/// and also supplies the dice for the first player's first move (there is no
/// separate [RollEvent] for that turn). Each move and each double advances the
/// turn counter and is prefixed with its number; cube responses (take/drop) and
/// resignation responses (accept/decline) are unnumbered follow-ups. A dance
/// renders as "(no play)" via [Move.toString].
List<RecordLine> buildGameRecord(List<GameEvent> events) {
  final lines = <RecordLine>[];
  var turn = 0;
  var cubeValue = 1;
  // The dice available for the next move: from the opening roll for the first
  // mover, otherwise from the most recent RollEvent.
  Dice? pending;

  for (final event in events) {
    switch (event) {
      case OpeningRollEvent(:final whiteDie, :final blackDie):
        pending = Dice(whiteDie, blackDie);
        lines.add(RecordLine(
          'Opening: W $whiteDie — B $blackDie (${_p(event.firstPlayer)} starts)',
        ));
      case RollEvent(:final die1, :final die2):
        pending = Dice(die1, die2);
      case MoveEvent(:final player, :final move):
        turn++;
        final roll = pending == null ? '' : '${pending.high}-${pending.low}: ';
        pending = null;
        lines.add(RecordLine('$turn. ${_p(player)} $roll$move', actor: player));
      case DoubleEvent(:final player):
        turn++;
        cubeValue *= 2;
        lines.add(
            RecordLine('$turn. ${_p(player)} doubles → $cubeValue', actor: player));
      case TakeEvent(:final player):
        lines.add(RecordLine('${_p(player)} takes', actor: player));
      case DropEvent(:final player):
        lines.add(RecordLine('${_p(player)} drops', actor: player));
      case ResignOfferEvent(:final player, :final value):
        turn++;
        lines.add(RecordLine(
          '$turn. ${_p(player)} offers to resign a ${_resign(value)}',
          actor: player,
        ));
      case ResignAcceptEvent(:final player):
        lines.add(RecordLine('${_p(player)} accepts', actor: player));
      case ResignDeclineEvent(:final player):
        lines.add(RecordLine('${_p(player)} declines', actor: player));
    }
  }
  return lines;
}

String _p(Player p) => p == Player.white ? 'W' : 'B';

String _resign(ResignValue v) => switch (v) {
      ResignValue.single => 'single',
      ResignValue.gammon => 'gammon',
      ResignValue.backgammon => 'backgammon',
    };
