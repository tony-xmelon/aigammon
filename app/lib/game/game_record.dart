import 'package:backgammon_core/backgammon_core.dart';

/// One rendered line of a game's move history.
///
/// [text] is the fully-formatted line (turn number, roll, notation, …) and
/// [actor] is the player whose action the line describes — used by the UI to
/// tint a leading dot — or `null` for a neutral line such as the opening roll.
///
/// [eventIndex] is the index of the source [GameEvent] in the event log the
/// line was folded from (each line comes from exactly one event). It lets the
/// UI correlate a line back to a per-move assessment keyed by event index. It is
/// DELIBERATELY excluded from [==]/[hashCode] (which compare on [text]/[actor]
/// only): it is positional display metadata, so existing equality-based record
/// assertions keep matching lines built without an index.
class RecordLine {
  const RecordLine(this.text, {this.actor, this.eventIndex});

  final String text;
  final Player? actor;
  final int? eventIndex;

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

  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    switch (event) {
      case OpeningRollEvent(:final whiteDie, :final blackDie):
        pending = Dice(whiteDie, blackDie);
        lines.add(RecordLine(
          'Opening: W $whiteDie — B $blackDie (${_p(event.firstPlayer)} starts)',
          eventIndex: i,
        ));
      case RollEvent(:final die1, :final die2):
        pending = Dice(die1, die2);
      case MoveEvent(:final player, :final move):
        turn++;
        final roll = pending == null ? '' : '${pending.high}-${pending.low}: ';
        pending = null;
        lines.add(RecordLine('$turn. ${_p(player)} $roll$move',
            actor: player, eventIndex: i));
      case DoubleEvent(:final player):
        turn++;
        cubeValue *= 2;
        lines.add(RecordLine('$turn. ${_p(player)} doubles → $cubeValue',
            actor: player, eventIndex: i));
      case TakeEvent(:final player):
        lines.add(RecordLine('${_p(player)} takes', actor: player, eventIndex: i));
      case DropEvent(:final player):
        lines.add(RecordLine('${_p(player)} drops', actor: player, eventIndex: i));
      case ResignOfferEvent(:final player, :final value):
        turn++;
        lines.add(RecordLine(
          '$turn. ${_p(player)} offers to resign a ${_resign(value)}',
          actor: player,
          eventIndex: i,
        ));
      case ResignAcceptEvent(:final player):
        lines.add(
            RecordLine('${_p(player)} accepts', actor: player, eventIndex: i));
      case ResignDeclineEvent(:final player):
        lines.add(
            RecordLine('${_p(player)} declines', actor: player, eventIndex: i));
    }
  }
  return lines;
}

// --- Two-column score sheet --------------------------------------------------

/// One side's cell in a [ScoreSheetTurn]: the COMPACT dice + notation for a
/// single played move ("31: 8/5 6/5"), the mover, and the index of the
/// [MoveEvent] it was folded from.
///
/// Deliberately narrower than a [RecordLine]: no turn number and no side letter,
/// because the row's gutter carries the number and the COLUMN identifies the
/// side. The dice are run together ("31:" rather than "3-1:") to buy characters
/// back for the notation in a ~180pt column.
class ScoreCell {
  const ScoreCell({
    required this.text,
    required this.actor,
    required this.eventIndex,
  });

  final String text;
  final Player actor;
  final int eventIndex;

  @override
  bool operator ==(Object other) =>
      other is ScoreCell &&
      other.text == text &&
      other.actor == actor &&
      other.eventIndex == eventIndex;

  @override
  int get hashCode => Object.hash(text, actor, eventIndex);

  @override
  String toString() => 'ScoreCell($text, ${actor.name}, $eventIndex)';
}

/// One row of the two-column score sheet: either a numbered [ScoreSheetTurn]
/// (up to one move per side) or a full-width [ScoreSheetSpan].
sealed class ScoreSheetRow {
  const ScoreSheetRow();
}

/// A numbered turn row: White's move and Black's reply. Either cell may be
/// `null` — the first row of a game the opponent opened has no White move, and
/// the last row of a game usually has no reply.
final class ScoreSheetTurn extends ScoreSheetRow {
  const ScoreSheetTurn(this.number, {this.white, this.black});

  final int number;
  final ScoreCell? white;
  final ScoreCell? black;

  /// This row's cell for [side], or `null` when that side has not moved in it.
  ScoreCell? cellFor(Player side) => side == Player.white ? white : black;

  @override
  String toString() => 'ScoreSheetTurn($number, $white, $black)';
}

/// A full-width row spanning BOTH columns: the opening roll, a cube action
/// (double / take / drop) or a resignation offer / response. These belong to no
/// single column — a double is not a move — and are rare enough that giving them
/// the whole width keeps them readable instead of ellipsized into a cell.
final class ScoreSheetSpan extends ScoreSheetRow {
  const ScoreSheetSpan(this.text, {this.actor, this.eventIndex});

  final String text;

  /// The acting side (for a tinted leading dot), or `null` for the neutral
  /// opening line.
  final Player? actor;
  final int? eventIndex;

  @override
  String toString() => 'ScoreSheetSpan($text, $actor, $eventIndex)';
}

/// Folds a game's append-only [events] into the rows of a two-column score
/// sheet: White's move on the left, Black's reply on the right, one numbered
/// row per exchange.
///
/// ## Pairing rule
///
/// A row always reads White-then-Black in CHRONOLOGICAL order, so a move only
/// joins the open row when no later column of it is already filled: a White move
/// needs both cells free, a Black move only its own. A game Black opened
/// therefore starts with a row whose White cell is empty (rather than pulling
/// White's reply up beside it and reversing the order).
///
/// A [ScoreSheetSpan] (opening roll, cube action, resignation) CLOSES the open
/// row, so nothing can back-fill across it and the sheet stays in event order.
List<ScoreSheetRow> buildScoreSheet(List<GameEvent> events) {
  final rows = <ScoreSheetRow>[];
  var turn = 0;
  var cubeValue = 1;
  // The dice available for the next move: from the opening roll for the first
  // mover, otherwise from the most recent RollEvent (see buildGameRecord).
  Dice? pending;
  // Index in [rows] of the turn row still open for cells, or null when the last
  // row is a span (or there are no rows yet).
  int? open;

  void span(String text, {Player? actor, required int eventIndex}) {
    open = null;
    rows.add(ScoreSheetSpan(text, actor: actor, eventIndex: eventIndex));
  }

  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    switch (event) {
      case OpeningRollEvent(:final whiteDie, :final blackDie):
        pending = Dice(whiteDie, blackDie);
        span(
          'Opening: W $whiteDie — B $blackDie (${_p(event.firstPlayer)} starts)',
          eventIndex: i,
        );
      case RollEvent(:final die1, :final die2):
        pending = Dice(die1, die2);
      case MoveEvent(:final player, :final move):
        final roll = pending == null ? '' : '${pending.high}${pending.low}: ';
        pending = null;
        final cell =
            ScoreCell(text: '$roll$move', actor: player, eventIndex: i);
        final row = open == null ? null : rows[open!] as ScoreSheetTurn;
        // White may only join a row with BOTH cells free; Black needs only its
        // own — that is what keeps each row chronological.
        final joinable = row != null &&
            row.cellFor(player) == null &&
            (player == Player.black || row.black == null);
        if (joinable) {
          rows[open!] = player == Player.white
              ? ScoreSheetTurn(row.number, white: cell, black: row.black)
              : ScoreSheetTurn(row.number, white: row.white, black: cell);
        } else {
          turn++;
          rows.add(player == Player.white
              ? ScoreSheetTurn(turn, white: cell)
              : ScoreSheetTurn(turn, black: cell));
          open = rows.length - 1;
        }
      case DoubleEvent(:final player):
        cubeValue *= 2;
        span('${_p(player)} doubles → $cubeValue',
            actor: player, eventIndex: i);
      case TakeEvent(:final player):
        span('${_p(player)} takes', actor: player, eventIndex: i);
      case DropEvent(:final player):
        span('${_p(player)} drops', actor: player, eventIndex: i);
      case ResignOfferEvent(:final player, :final value):
        span('${_p(player)} offers to resign a ${_resign(value)}',
            actor: player, eventIndex: i);
      case ResignAcceptEvent(:final player):
        span('${_p(player)} accepts', actor: player, eventIndex: i);
      case ResignDeclineEvent(:final player):
        span('${_p(player)} declines', actor: player, eventIndex: i);
    }
  }
  return rows;
}

/// Folds [events] up to (and including) index [through] and returns each
/// player's most recent roll — White's and Black's persistent dice pairs as of
/// that point — as `(white, black)`. A pair is `null` when that player has not
/// rolled yet by [through].
///
/// Rolls come from the [OpeningRollEvent] (both opening dice belong to the first
/// mover, who plays them as their opening move) and each [RollEvent]. Events
/// past [through] are ignored; pass `events.length - 1` (the default) to fold
/// the whole log. This is the same fold the live game screen shows on the board,
/// shared so the replay screen reproduces the historical dice at any step.
(Dice?, Dice?) persistentDice(List<GameEvent> events, {int? through}) {
  Dice? white;
  Dice? black;
  final end = through ?? events.length - 1;
  for (var i = 0; i <= end && i < events.length; i++) {
    switch (events[i]) {
      case OpeningRollEvent(:final whiteDie, :final blackDie, :final firstPlayer):
        final d = Dice(whiteDie, blackDie);
        if (firstPlayer == Player.white) {
          white = d;
        } else {
          black = d;
        }
      case RollEvent(:final player, :final die1, :final die2):
        final d = Dice(die1, die2);
        if (player == Player.white) {
          white = d;
        } else {
          black = d;
        }
      default:
        break;
    }
  }
  return (white, black);
}

String _p(Player p) => p == Player.white ? 'W' : 'B';

String _resign(ResignValue v) => switch (v) {
      ResignValue.single => 'single',
      ResignValue.gammon => 'gammon',
      ResignValue.backgammon => 'backgammon',
    };
