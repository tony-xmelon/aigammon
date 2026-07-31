import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';

import '../../data/app_settings.dart';
import '../../game/match_controller.dart';

/// The dice presentation state machine, lifted out of the game screen so the
/// screen keeps only the layout that reads it.
///
/// Every roll — the opening roll, the local player's, the opponent's — is
/// PRESENTED: the roller's pair tumbles through [AnimationTimings.diceFrames]
/// pseudo-random faces, settles on the real roll, and is held readable for a
/// settle pause before anything else moves. This object owns the whole beat
/// ([_startRollBeat]) because only the event log sees the roll events; the board
/// is a pure renderer, fed the tumbling faces as `BoardView.diceOverride` and
/// the emphasis as `BoardView.activeDiceSide`.
///
/// Three things are derived from ONE piece of state — [presentingSide], the
/// roller of the beat currently running (`null` between beats):
///
/// * **which pair is lit** — [activeDiceSide]: the presenting roller while a
///   beat runs, else the side whose move is being entered, else NOBODY (both
///   pairs dim). Bright therefore means exactly "this roll is live", so the local
///   pair goes dim the instant a move is confirmed and stays dim until it is
///   rolled again — the reported "after my turn is over, my dice gets enabled
///   while the opponent moves". It is never derived from `state.turn`, which is
///   already back on the human while the opponent's roll is still tumbling.
/// * **when the opponent's checkers may travel** — [dicePresenting], handed to
///   the board as `BoardView.holdMoveAnimation`: a move that lands mid-beat is
///   queued and starts when the dice are readable.
/// * **when the local player may start entering** — [entryHeld]: while your own
///   roll is still tumbling the board is not interactive and the action bar shows
///   no move affordances, so nothing can be staged against dice that have not
///   settled. The settle pause is HALVED for your own roll (see
///   [_startRollBeat]): the presentation is the same beat, but you are waiting on
///   yourself, and the full pause read as lag.
///
/// The presentation is disabled outright by the "Dice roll animation" setting and
/// by animation speed "None" — both land as
/// [AnimationTimings.diceBeatEnabled] `== false`, in which case rolls settle
/// instantly and only the move-entry emphasis remains.
///
/// ## Notification contract
///
/// [notifyListeners] fires exactly where the screen used to call `setState`:
/// on each tumble frame, when the dice settle, when the presentation is
/// released, and when the board reports a move animation starting or ending.
/// It deliberately does NOT fire from [syncRollBeat] / [cancel], whose callers
/// are already inside a rebuild path (or disposing).
class DicePresenter extends ChangeNotifier {
  DicePresenter({
    required this.controller,
    required this.timings,
    required this.onEntryOpened,
  });

  final MatchController controller;

  /// Read live rather than captured: the screen's widget (and with it the user's
  /// chosen animation speed) can be replaced under a mounted state.
  final AnimationTimings Function() timings;

  /// Called the moment move entry opens at the end of a beat — the two things
  /// that wait for exactly those affordances (the one-time drag/tap tip and the
  /// dance hold) have to be re-offered there or they would sit out the whole
  /// move.
  final VoidCallback onEntryOpened;

  bool _disposed = false;

  /// Event cursor for the roll-beat detector, tracked SEPARATELY from the
  /// tutor's own cursor so the two event-growth hooks advance independently.
  ///
  /// LAZY on purpose (as it was inline): it is seeded on its first read, which
  /// is the first [syncRollBeat] call, so that first call can never mistake a
  /// log that already existed for a burst of fresh rolls.
  late int _lastRollEventCount = controller.game.events.length;

  /// The live roll beat: the ROLLER whose pair is tumbling, plus the cycling
  /// faces to paint on it. `null` when no beat is active (the board then shows
  /// both persisted pairs). Passed straight through to the board as its
  /// `diceOverride`.
  ///
  /// The roller is stored HERE, taken from the [RollEvent] that started the
  /// beat, because it cannot be recovered from the state the beat is painted
  /// against: by the first override frame the turn may already have advanced
  /// past the roller.
  ({Player roller, Dice faces})? get rollBeat => _rollBeat;
  ({Player roller, Dice faces})? _rollBeat;

  /// The current beat's frame timer, cancelled on a new beat / dispose.
  Timer? _rollBeatTimer;

  /// Monotonic guard so a superseded beat (a rapid second roll) cannot clear or
  /// advance a fresher one.
  int _rollBeatSeq = 0;

  /// Whether a roll is currently being PRESENTED — true from the moment a roll
  /// beat begins until its tumble frames AND the settle pause have elapsed.
  /// Handed to the board as `holdMoveAnimation` so a move that lands during the
  /// presentation is deferred until the dice are readable.
  ///
  /// A [ValueNotifier] rather than plain state because the board LISTENS to it
  /// (the queued move starts on the flip, between rebuilds). Kept exactly in step
  /// with [presentingSide]: `value == (presentingSide != null)`.
  final ValueNotifier<bool> dicePresenting = ValueNotifier<bool>(false);

  /// The roller whose dice are being presented right now (the beat's tumble
  /// frames plus its settle pause), or `null` when no presentation is running.
  ///
  /// The identity half of [dicePresenting], and the state the whole presentation
  /// is derived from — see the class doc. Taken from the [RollEvent] that started
  /// the beat, never from `state.turn`, which may already have advanced past the
  /// roller (see [rollBeat]).
  Player? get presentingSide => _presentingSide;
  Player? _presentingSide;

  /// The side whose move is currently TRAVELLING on the board (its cosmetic
  /// animation), or `null` when nothing is animating. Reported by the board
  /// through `BoardView.onMoveAnimation`, because the board owns that timeline
  /// (its length depends on the hop count) and this object must not duplicate it.
  ///
  /// Keeps the mover's dice lit for as long as their play is being presented:
  /// the roll settles, then the checkers move, and only when both are done does
  /// the pair go dim. Only ever set for a move that ANIMATES — a hand-entered
  /// local move is never replayed, so confirming still dims your pair at once.
  Player? _animatingSide;

  /// Detects a fresh roll in the event log and kicks off its presentation beat
  /// before the settled roll shows. EVERY roll beats — the opening roll, the
  /// local player's own, and the opponent's (AI or remote) alike: "there is no
  /// dice animation now, not for me, not for the opponent, please add it back".
  /// Only the settle pause differs, being halved for a local roller (see
  /// [_startRollBeat]).
  ///
  /// A shorter event list means a new game began: reset the cursor and cancel any
  /// live beat.
  ///
  /// The beat is gated on the screen's timings: with the [AnimationTimings.off]
  /// preset (animation off — the widget-test default) or the dice-roll animation
  /// setting turned off, no beat ever runs and the board shows the real roll
  /// immediately. Called from the screen's change handler before its `setState`,
  /// so the first override frame it sets is painted by that rebuild.
  void syncRollBeat() {
    final events = controller.game.events;
    final len = events.length;
    if (len < _lastRollEventCount) {
      _lastRollEventCount = len; // a new game reset the event log
      cancel();
      return;
    }
    if (len == _lastRollEventCount) return;
    for (var i = _lastRollEventCount; i < len; i++) {
      // Both the roller AND the settled faces come from the EVENT — never from
      // the controller's state (whose turn/dice may already have moved on). The
      // opening roll is one die each, and both belong to the first mover (who
      // plays them as their opening move), exactly as `persistentDice` folds it.
      switch (events[i]) {
        case OpeningRollEvent(
            :final whiteDie,
            :final blackDie,
            :final firstPlayer
          ):
          _startRollBeat(firstPlayer, Dice(whiteDie, blackDie));
        case RollEvent(:final player, :final die1, :final die2):
          _startRollBeat(player, Dice(die1, die2));
        default:
          break;
      }
    }
    _lastRollEventCount = len;
  }

  /// Begins (or restarts) [roller]'s roll beat toward [realRoll]:
  /// [AnimationTimings.diceFrames] cycling frames [AnimationTimings.diceFrame]
  /// apart of deterministic pseudo-random faces, after which the override clears
  /// and the real roll shows through the roller's own persisted pair (which has
  /// already folded this [RollEvent]). The faces are seeded off [realRoll] so the
  /// sequence is stable under test, and each cycling face differs from the real
  /// roll (the dice visibly tumble). No-op when animation is off. The first frame
  /// is set synchronously; the caller's `setState` paints it.
  ///
  /// While the beat runs — AND for the settle pause after the dice settle —
  /// [presentingSide] is [roller] and [dicePresenting] is `true`, which lights
  /// the roller's pair ([activeDiceSide]), holds any queued move animation, and
  /// (for a local roller) withholds move entry ([entryHeld]).
  ///
  /// The settle pause is [AnimationTimings.diceSettlePause] for a remote/AI roll
  /// and HALF that for a local one. The pause exists so a roll is readable before
  /// the checkers move; when the roller is you, you already know what you rolled
  /// and the wait is between you and your own move, where the full pause reads as
  /// the app being slow. Same beat, half the dwell.
  ///
  /// [roller] is the roll event's player, carried through every frame so the
  /// tumbling faces land on the pair that actually rolled them regardless of
  /// how far the turn has advanced meanwhile (see [rollBeat]).
  void _startRollBeat(Player roller, Dice realRoll) {
    final pacing = timings();
    if (!pacing.diceBeatEnabled) return;
    cancel();
    final seq = ++_rollBeatSeq;
    final frameCount = pacing.diceFrames;
    final frameDuration = pacing.diceFrame;
    final settlePause = controller.isLocalHuman(roller)
        ? pacing.diceSettlePause ~/ 2
        : pacing.diceSettlePause;
    _beginPresenting(roller); // hold move animation + entry until dice settle
    _rollBeat = (roller: roller, faces: _beatFace(realRoll, 0));
    var frame = 0;
    void nextFrame() {
      if (_disposed || seq != _rollBeatSeq) return;
      frame++;
      if (frame >= frameCount) {
        // Dice settle to the real roll now; keep presenting for one more settle
        // pause so the roll is legible before anything moves.
        _rollBeat = null;
        notifyListeners();
        _rollBeatTimer = Timer(settlePause, () {
          if (_disposed || seq != _rollBeatSeq) return;
          _rollBeatTimer = null;
          // Release: a queued move animation begins, and a local roller's move
          // entry affordances appear. A rebuild is needed for the latter (the
          // notifier alone only wakes the board's own listener).
          _endPresenting();
          notifyListeners();
          // Entry just opened without a controller notification, so the two
          // things that wait for exactly these affordances have to be re-offered
          // here or they would sit out the whole move: the one-time drag/tap
          // tip, and the dance hold.
          //
          // The dance hold DID already start without this call — the board's
          // `BoardEntryController` defers its notify to the next frame, which
          // lands back in the screen's change handler — but relying on another
          // object's scheduling for a turn to advance itself is emergent, not
          // designed. Arming it on the same line that opens entry makes the beat
          // start when the dice become readable, by construction. The dance hold
          // is idempotent while one is already pending, so the later
          // notification is a no-op.
          onEntryOpened();
        });
        return;
      }
      _rollBeatTimer = Timer(frameDuration, nextFrame);
      _rollBeat = (roller: roller, faces: _beatFace(realRoll, frame));
      notifyListeners();
    }

    _rollBeatTimer = Timer(frameDuration, nextFrame);
  }

  /// Marks [roller]'s roll as being presented, keeping [presentingSide] and
  /// [dicePresenting] in step (the board listens to the notifier).
  void _beginPresenting(Player roller) {
    _presentingSide = roller;
    dicePresenting.value = true;
  }

  /// Ends the presentation (no roll is live until the next one).
  void _endPresenting() {
    _presentingSide = null;
    dicePresenting.value = false;
  }

  /// Cancels any live beat and clears the override (fencing pending callbacks by
  /// bumping the beat sequence), and ends the presentation. Does not notify;
  /// callers are already in a rebuild path (or disposing).
  void cancel() {
    _rollBeatTimer?.cancel();
    _rollBeatTimer = null;
    _rollBeatSeq++;
    _rollBeat = null;
    _endPresenting();
  }

  /// The dice pair to light this frame, or `null` to dim BOTH — the presentation
  /// state machine's single output (see the class doc).
  ///
  /// Precedence, strongest first:
  ///
  /// 1. the presenting roller — a roll being rolled is always the live pair;
  /// 2. [moveSide], the local side whose move is being ENTERED — a play the user
  ///    is making by hand outranks a replay finishing in the background, so their
  ///    own dice (with per-die spent dimming) stay lit while they use them;
  /// 3. the side whose checkers are travelling, so an opponent's roll stays
  ///    readable for the whole of their play.
  ///
  /// With none of the three — the pre-roll gate, the moment after a confirm, a
  /// finished turn — nothing is live and both pairs dim.
  Player? activeDiceSide(Player? moveSide) =>
      _presentingSide ?? moveSide ?? _animatingSide;

  /// Records the board's animation state (see [_animatingSide]).
  ///
  /// Reached from the board's own listener paths — including the one where
  /// releasing the presentation hold synchronously starts a queued move — all of
  /// which run outside a build, so notifying (and the screen's `setState` behind
  /// it) is safe here.
  void onMoveAnimation(Player? player) {
    if (_disposed || _animatingSide == player) return;
    _animatingSide = player;
    notifyListeners();
  }

  /// Whether move entry is WITHHELD because the local mover's own dice are still
  /// being presented. The board is left non-interactive and the action bar shows
  /// no move affordances until the roll settles, so no hop can be staged against
  /// dice that are still tumbling.
  bool entryHeld(Player? moveSide) =>
      moveSide != null && _presentingSide == moveSide;

  /// A deterministic dice pair for beat [frame], derived from the settled
  /// [realRoll]. Both faces are offset off the real roll (die1 always differs
  /// from the real die1), so the whole pair reads as different from the settled
  /// roll on every frame.
  Dice _beatFace(Dice realRoll, int frame) {
    int face(int real, int salt) => ((real + frame + salt) % 6) + 1;
    return Dice(face(realRoll.die1, 1), face(realRoll.die2, 3));
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    dicePresenting.dispose();
    super.dispose();
  }
}
