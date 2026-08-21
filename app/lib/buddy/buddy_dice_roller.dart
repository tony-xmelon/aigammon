import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';

import '../game/dice_roller.dart';

/// The [DiceRoller] for a game played with real dice.
///
/// In Buddy Mode a **human hand throws the dice for both sides** — Buddy has
/// no hands, and asking the phone to generate its own roll while the user
/// throws theirs would make half the match unverifiable against the board in
/// front of them. So every roll in the match comes through here, and none of
/// them comes from a random number generator.
///
/// ## Why there are two verbs
///
/// [rollDice] is the asynchronous one the session drives: it opens a request
/// and returns a future that perception (`readDice` on a settled frame) or the
/// manual dice pad completes through [submit]. [roll] and [rollOpening] are
/// the synchronous [DiceRoller] interface the [GameController] calls, and they
/// hand back the value that was submitted.
///
/// The two-step exists because `GameController`'s roll is synchronous and
/// cannot wait for a camera. The session closes that gap by **owning the
/// moment**: it keeps the controller parked on the pre-roll gate (both agents
/// in a Buddy session answer `wantsDoublePrompts == false`, so the controller
/// waits for a verb rather than rolling for itself), gets the dice, arms this
/// roller, and
/// only then lets the controller move. If [roll] is ever reached unarmed that
/// invariant has been broken, and it throws rather than inventing a roll — a
/// fabricated roll would enter the authoritative game state and stay there,
/// which is the one failure this whole mode cannot recover from.
class BuddyDiceRoller implements DiceRoller {
  Completer<Dice>? _pending;
  Dice? _armed;

  /// Whether a roll has been asked for and not yet supplied.
  bool get isPending => _pending != null;

  /// Whether a supplied roll is waiting for the controller to take it.
  bool get isArmed => _armed != null;

  /// Asks for one physical roll.
  ///
  /// The returned future completes when [submit] is called with what the board
  /// showed — from `readDice`, or from the manual pad, which the session offers
  /// whenever the camera cannot say. Only one request may be open at a time.
  Future<Dice> rollDice() {
    if (_pending != null) {
      throw StateError('a roll has already been asked for');
    }
    final completer = Completer<Dice>();
    _pending = completer;
    return completer.future;
  }

  /// The dice the user actually threw. Completes [rollDice] and arms [roll].
  void submit(Dice dice) {
    final pending = _pending;
    if (pending == null) {
      throw StateError('no roll has been asked for');
    }
    _pending = null;
    _armed = dice;
    pending.complete(dice);
  }

  /// Abandons an open request — the calibration died under it, or the session
  /// is going away. The awaiting future is never completed, exactly as
  /// `LocalHumanAgent` abandons a pending decision: the session owns
  /// cancellation and a completed-with-garbage roll would be worse than a
  /// dropped one.
  void cancel() {
    _pending = null;
    _armed = null;
  }

  @override
  Dice roll() => _take();

  /// The opening roll: White's die and Black's, in that order.
  ///
  /// **Never a double.** `GameState.opening` refuses one and the session
  /// re-asks for the throw instead, which is what two people at a board do.
  @override
  Dice rollOpening() {
    final dice = _take();
    if (dice.isDouble) {
      throw StateError('an opening roll cannot be a double — the session is '
          'meant to have asked for another throw');
    }
    return dice;
  }

  Dice _take() {
    final dice = _armed;
    if (dice == null) {
      throw StateError('no physical roll has been submitted — the session '
          'must read or accept the dice before letting the game roll');
    }
    _armed = null;
    return dice;
  }
}
