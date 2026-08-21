import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';

import 'speaker.dart';

/// What happened to the cube, as the session narrates it.
///
/// **The spec sketched `onCubeAction(CubeAction action)`** and `CubeAction` in
/// this app is take-or-drop (see `game/player_agent.dart`), which leaves the
/// double itself — the event the whole verbal negotiation turns on — with no
/// value to carry. So the policy hears a three-valued action and an actor
/// instead: who did what, which is exactly what a spoken line needs and what a
/// transcript has to distinguish ("I double" / "You take" are different
/// sentences said by different people about one cube).
enum BuddyCubeAction { offered, taken, dropped }

/// What a mode says and shows.
///
/// The spec's seam, and the reason Buddy Mode is "mode-pluggable from day one":
/// the session decides, perception answers, and this decides what is SAID. A
/// policy receives events and touches neither perception nor the game state —
/// which is why coach and tracker modes are later policies rather than later
/// subsystems, and why every one of these methods returns void.
///
/// ## Deviations from the spec's sketch, recorded
///
///  * `onDiceRead` carries a `double?` rather than the spec's `Confidence`.
///    No such type was ever built: `board_vision` reports a plain confidence on
///    `DiceReading`, and `null` here means the roll was TYPED rather than read,
///    which a policy legitimately words differently.
///  * `onCubeAction` carries an actor and a [BuddyCubeAction] — see that enum.
///  * [onOpeningRerolled] is new. Two equal opening dice are not a roll that
///    happened; folding them into `onDiceRead` would report a turn that nobody
///    is about to take.
abstract interface class BuddyPolicy {
  /// [confidence] is the reading's, or `null` when the roll was typed on the
  /// manual pad. For the OPENING roll, [roller] is the side the dice gave the
  /// first turn to.
  void onDiceRead(Player roller, Dice dice, double? confidence);

  /// The opening dice came up equal, so they are being thrown again.
  void onOpeningRerolled(Dice tied);

  /// [mover]'s play has been identified and folded into the game.
  void onPlayObserved(Player mover, Move play);

  /// The board changed into something that is not a legal play. [reason] is a
  /// sentence written for the user by whichever query noticed.
  void onIllegalPlayObserved(String reason);

  /// Buddy has decided its play. The user has not made it yet — that is what
  /// [onPlacementVerified] is about.
  void onBuddyMoveChosen(Dice dice, Move play);

  /// Whether the board now holds the position Buddy dictated. [fix] names the
  /// discrepancy when it does not.
  void onPlacementVerified(bool correct, String? fix);

  void onCubeAction(Player actor, BuddyCubeAction action);

  /// Every distinct verdict, as it changes — never once per frame.
  void onReadability(Readability state);

  void onGameEnd(GameResult result);

  void onMatchEnd(Player winner);
}

/// The MVP mode: Buddy plays one side and says so.
///
/// Per the spec — "speaks Buddy's dice/moves, acknowledges the user's plays
/// tersely, objects to illegal or incomplete plays, and runs the verbal cube
/// negotiation". Every line goes through [BuddySpeaker], so every line is
/// mirrored on screen whether or not the phone has a voice.
///
/// **Silence is a feature here.** A policy that narrated every event would be
/// unbearable at a real board: the user's own play gets an acknowledgement
/// short enough to talk over, a placement that came out right gets nothing at
/// all (the next line already implies it), and readability is spoken only on
/// the transition into red — the spec says "spoken once (not nagged)" and the
/// session only ever calls [onReadability] on a change.
class OpponentPolicy implements BuddyPolicy {
  OpponentPolicy({required this.speaker, required this.buddySide});

  final BuddySpeaker speaker;

  /// The side the engine plays. Everything else is the user's.
  final Player buddySide;

  bool _saidRed = false;

  @override
  void onDiceRead(Player roller, Dice dice, double? confidence) {
    final who = roller == buddySide ? 'I rolled' : 'You rolled';
    final d = BuddyPhrasing.describeDice(dice);
    speaker.say(BuddyLine('$who ${d.text}.', speech: '$who ${d.speech}.'));
  }

  @override
  void onOpeningRerolled(Dice tied) => speaker.say(BuddyLine(
        'Both ${tied.die1} — roll again.',
        speech: 'Both ${tied.die1}. Roll again.',
      ));

  @override
  void onPlayObserved(Player mover, Move play) {
    if (mover == buddySide) return; // Buddy's own play was announced already.
    if (play.checkerMoves.isEmpty) {
      speaker.say(const BuddyLine('No play — your turn passes.'));
      return;
    }
    // Terse on purpose: an acknowledgement is a receipt, not a commentary.
    speaker.announcePlay(play);
  }

  @override
  void onIllegalPlayObserved(String reason) =>
      speaker.say(BuddyLine("That isn't a legal play. $reason"));

  @override
  void onBuddyMoveChosen(Dice dice, Move play) {
    final described = speaker.phrasing.describePlay(play);
    final d = BuddyPhrasing.describeDice(dice);
    if (play.checkerMoves.isEmpty) {
      speaker.say(BuddyLine(
        'I rolled ${d.text} — no play, so it is back to you.',
        speech: 'I rolled ${d.speech}. No play, so it is back to you.',
      ));
      return;
    }
    speaker.say(BuddyLine(
      'I rolled ${d.text} — play ${described.text}',
      speech: 'I rolled ${d.speech}. Play ${described.speech}',
    ));
  }

  @override
  void onPlacementVerified(bool correct, String? fix) {
    // Nothing is said when it came out right: the next line — a roll, a play,
    // a double — is the acknowledgement, and a board being correct is the
    // ordinary case, which is precisely what must not be narrated.
    if (correct) return;
    speaker.say(BuddyLine("That isn't quite it. ${fix ?? ''}".trim()));
  }

  @override
  void onCubeAction(Player actor, BuddyCubeAction action) {
    final mine = actor == buddySide;
    speaker.say(switch (action) {
      BuddyCubeAction.offered => mine
          ? const BuddyLine('I double — take or drop?')
          : const BuddyLine('You double.'),
      BuddyCubeAction.taken =>
        mine ? const BuddyLine('I take.') : const BuddyLine('You take.'),
      BuddyCubeAction.dropped =>
        mine ? const BuddyLine('I drop.') : const BuddyLine('You drop.'),
    });
  }

  @override
  void onReadability(Readability state) {
    if (state.level == ReadabilityLevel.red) {
      // "Spoken once (not nagged)": the session already only reports changes,
      // and this latch survives an amber flicker in between two reds.
      if (_saidRed) return;
      _saidRed = true;
      speaker.say(BuddyLine(state.message));
      return;
    }
    if (state.level == ReadabilityLevel.green && _saidRed) {
      _saidRed = false;
      speaker.say(const BuddyLine('I can see the board again.'));
    }
  }

  @override
  void onGameEnd(GameResult result) {
    final who = result.winner == buddySide ? 'I win' : 'You win';
    final points = result.points == 1 ? '1 point' : '${result.points} points';
    speaker.say(BuddyLine('$who $points.'));
  }

  @override
  void onMatchEnd(Player winner) => speaker.say(BuddyLine(
      winner == buddySide ? 'That is the match to me.' : 'You win the match.'));
}
