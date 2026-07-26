import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';

import '../board/board_theme.dart';
import '../board/board_view.dart';
import '../data/app_settings.dart';
import '../game/game_record.dart';
import '../game/match_controller.dart';
import '../game/player_agent.dart';
import '../tutor/move_assessment.dart';
import '../tutor/tutor_service.dart';
import 'history_screen.dart';
import 'metric_explainer.dart';

/// The playing screen. Assembles the [BoardView], a top HUD, a bottom action
/// bar, the in-game dialogs (cube/resign responses, game-end, match-end), the
/// error banner, and the hot-seat pass-device overlay.
///
/// It RECEIVES a ready [MatchController] (a local [GameController] or an online
/// controller, constructed by the caller), starts its match loop in
/// [initState], and disposes it in [dispose].
///
/// ## Dialogs are declarative, not `showDialog` routes
///
/// Every modal (cube offer, resign offer, game-end, match-end) and the
/// pass-device overlay is rendered as an in-tree layer of a [Stack]
/// (a [ModalBarrier] plus a centred [Material] card) driven directly by the
/// controller flags / human pending-request notifiers. This avoids the
/// route-timing complications of `showDialog` (imperative side effects that must
/// be scheduled after a frame and torn down on the next), so widget tests pump
/// the tree synchronously and the visible modal is always a pure function of
/// state. The error surface is likewise a plain (non-animated) banner row rather
/// than a [MaterialBanner], keeping `pumpAndSettle` free of pending animations.
///
/// ## Why `pendingDoubleRequest` is ignored
///
/// No [MatchController] surfaces a per-turn "double?" prompt for a locally-human
/// side (the hot-seat [GameController] never calls `considerDouble` on a human —
/// see `game_controller.dart` `_stepPreRoll`, whose `wantsDoublePrompts` branch
/// is AI-only; humans park on the turn gate instead). A human's double is driven
/// by the pre-roll action bar ([MatchController.offerDouble]), so there is no
/// `pendingDoubleOf` on the interface and this screen deliberately does not
/// observe one.
///
/// ## Board orientation
///
/// [BoardOrientationMode] chooses which side sits at the bottom of the board.
/// [BoardOrientationMode.fixedWhite] / [BoardOrientationMode.fixedBlack] pin a
/// side (vs-AI: the human's side stays at the bottom for the whole match).
/// [BoardOrientationMode.followActive] (hot-seat "rotate for Black") flips the
/// board so the active player is always at the bottom — but ONLY while the
/// pass-device overlay hides the board, so the rotation is never seen mid-turn.
class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    required this.controller,
    this.orientation = BoardOrientationMode.fixedWhite,
    this.tutor,
    this.timings = AnimationTimings.off,
    this.interactionOptions = const BoardInteractionOptions(),
    this.showScoring = true,
    this.persistedMatchId,
    this.dragHintShown = true,
    this.onDragHintShown,
    this.opponentLabel = 'AI',
  });

  final MatchController controller;

  /// The persisted match row's id (resolving asynchronously — the setup screen
  /// inserts it fire-and-forget), or `null` when this match is not persisted.
  ///
  /// When non-null the game-end dialog offers an "Analyze game" button and the
  /// match-end dialog a "Match summary" button; both await this id and push the
  /// [MatchDetailScreen] (its games list drills through to per-game
  /// [AnalysisScreen]). Post-game analysis needs only the ENGINE — the
  /// [AnalysisScreen] builds its own [TutorService] from the engine provider on
  /// demand — so this is gated purely on persistence, NOT on the live [tutor]
  /// (which defaults off for hard/expert and hot-seat matches).
  final Future<int>? persistedMatchId;

  /// The animation pacing (checker hop/inter-hop travel + the dice-roll beat's
  /// tumble/settle timings) passed to the [BoardView] and used by this screen's
  /// opponent dice-roll beat. Defaults to [AnimationTimings.off] (everything
  /// disabled) so widget tests are unaffected; production call sites pass the
  /// user's chosen speed via the settings-backed `AppSettings.timings`.
  final AnimationTimings timings;

  /// Board interaction toggles (highlights / drag / combined taps) forwarded to
  /// the [BoardView]. Production call sites build this from the persisted
  /// settings; the default enables highlights + combined taps and disables drag.
  final BoardInteractionOptions interactionOptions;

  /// Whether the HUD shows the running match score. Production call sites pass
  /// the persisted `AppSettings.showScoring`.
  final bool showScoring;

  /// Whether the one-time drag/tap discoverability hint has ALREADY been shown
  /// (the persisted `AppSettings.dragHintShown`). When false AND drag is enabled
  /// ([BoardInteractionOptions.enableDrag]), the hint SnackBar surfaces once on
  /// the first human move-entry of the match; see [onDragHintShown]. Defaults to
  /// true so the hint is opt-in for tests / harnesses that do not wire it.
  final bool dragHintShown;

  /// Fire-and-forget callback invoked the moment the one-time drag hint is shown,
  /// so the caller can persist `dragHintShown = true`. Null disables persistence
  /// (the hint would then re-show on the next match); production call sites pass
  /// a settings-repository write.
  final VoidCallback? onDragHintShown;

  /// Which side sits at the bottom of the board. See [BoardOrientationMode].
  final BoardOrientationMode orientation;

  /// What the HUD score calls the NON-local side when exactly one side is
  /// locally human — "AI" (the default, a match against the computer) or "Opp"
  /// (an online match). The local side is then always called "You" and shown
  /// first, so the header reads "You 2–1 AI · to 5" rather than the cryptic
  /// "W 2–1 B · to 5".
  ///
  /// IGNORED in hot-seat, where both sides are local and neither of them is
  /// "you": that header keeps the neutral "W 2–1 B · to 5".
  final String opponentLabel;

  /// The live tutor, or `null` when tutor mode is off. When non-null the screen
  /// surfaces a hint button (top-5 plays), post-move assessments for HUMAN moves
  /// (a mark + equity loss on the collapsed history strip and the expanded
  /// record sheet's rows), and cube advice at the human's pre-roll gate /
  /// cube-offer dialog. Display-only: hints never auto-apply.
  final TutorService? tutor;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

/// How [GameScreen] orients the board.
enum BoardOrientationMode {
  /// White is always at the bottom (the canonical layout).
  fixedWhite,

  /// Black is always at the bottom (vs-AI when the human plays Black).
  fixedBlack,

  /// The active player is at the bottom; the board flips behind the
  /// pass-device overlay when the actor changes (hot-seat rotate-for-Black).
  followActive,
}

class _GameScreenState extends State<GameScreen> {
  MatchController get _c => widget.controller;

  /// The merged listenable: the controller plus the pending-request notifiers of
  /// whichever agents are human. Rebuilds the screen on any of them.
  late final Listenable _observable;

  /// Hot-seat only: the side that last acted, so a change of actor triggers the
  /// pass-device reveal. `null` until the first human decision of the match.
  Player? _lastActor;

  /// Hot-seat only: true while the pass-device overlay is gating the reveal for
  /// a new actor. Cleared when the user taps to continue.
  bool _passDevicePending = false;

  /// followActive only: whether White currently sits at the bottom. Updated
  /// exactly when the pass-device overlay raises (behind the opaque overlay),
  /// so the board never flips while it is visible mid-turn. Ignored by the
  /// fixed orientation modes.
  late bool _displayedWhiteAtBottom =
      _c.state.turn == Player.white;

  bool get _hotSeat =>
      _c.isLocalHuman(Player.white) && _c.isLocalHuman(Player.black);

  TutorService? get _tutor => widget.tutor;

  // --- Tutor state -----------------------------------------------------------

  /// Count of game events observed at the last change, so a fresh MoveEvent can
  /// be detected (and a new game — a shorter event list — resets the tutor).
  late int _lastEventCount = _c.game.events.length;

  /// Post-move assessments for HUMAN moves, keyed by the source [MoveEvent]'s
  /// index in the event log (the same index [RecordLine.eventIndex] carries).
  /// The latest entry drives the collapsed history strip; every entry enriches
  /// its row in the expanded sheet. Cleared when a new game begins.
  final Map<int, MoveAssessment> _assessmentsByEventIndex = {};

  /// Event indices whose expanded-sheet row has its best-move line revealed
  /// (tap-to-reveal). Cleared when a new game begins.
  final Set<int> _revealedBest = {};

  /// Bumped when a new game starts, so an in-flight [TutorService.assess] from
  /// the previous game is discarded rather than written into a fresh log's map.
  int _gameGeneration = 0;

  /// Cube advice for the human's currently-open pre-roll gate, or `null`. Keyed
  /// by [_cubeAdviceKey] so it is computed once per gate, not per rebuild.
  CubeAssessment? _cubeAdvice;
  int? _cubeAdviceKey;
  int _cubeAdviceSeq = 0;

  /// Take/pass advice for a human facing an opponent's double, or `null`. Keyed
  /// by [_cubeResponseKey] so it is computed once per offer.
  CubeAssessment? _cubeResponseAdvice;
  int? _cubeResponseKey;
  int _cubeResponseSeq = 0;

  /// Whether the post-match "Match summary" link is awaiting the persisted match
  /// id (a brief spinner in the dialog button until the row insert resolves).
  bool _summaryLoading = false;

  /// Whether the one-time drag/tap hint has been surfaced this session. Seeded
  /// from the persisted [GameScreen.dragHintShown]; set true the instant the
  /// hint actually shows (after the mounted check) so it can never appear twice
  /// within a match.
  late bool _dragHintShown = widget.dragHintShown;

  /// Whether a hint SnackBar has already been SCHEDULED (its post-frame callback
  /// queued) but not yet run. Prevents a burst of [_onChange] notifications
  /// between the schedule and the frame from queuing several SnackBars, without
  /// prematurely committing the persisted [_dragHintShown] latch.
  bool _dragHintScheduled = false;

  /// The messenger that owns this screen's SnackBars, captured while the
  /// [BuildContext] is still valid so [dispose] can reach it (looking it up in
  /// `dispose` is illegal — the element is already defunct).
  ScaffoldMessengerState? _messenger;

  /// The live drag-hint SnackBar's controller while OUR hint is on screen, else
  /// `null` (cleared by its own `closed` future the moment it goes, however it
  /// goes). [dispose] removes it only while this is non-null, so leaving the
  /// screen never tears down a SnackBar that belongs to somebody else.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _dragHintBar;

  /// The transient "that checker cannot move" hint currently shown over the
  /// bottom edge of the board, or `null` when nothing is shown. Raised by the
  /// [BoardView]'s [BoardView.onNoLegalSourceTap] and cleared by [_tapHintTimer].
  String? _tapHint;

  /// Auto-clear timer for [_tapHint]. A repeat tap RESTARTS it rather than
  /// stacking a second hint (the rate limit).
  Timer? _tapHintTimer;

  /// How long a [_tapHint] stays up.
  static const Duration _tapHintDuration = Duration(milliseconds: 1200);

  /// Whether the move-history ("Game record") bottom panel is open.
  bool _recordOpen = false;

  /// Scroll controller for the record list, kept so the panel can auto-scroll to
  /// the newest line on open and when live events append while it is open.
  final ScrollController _recordScroll = ScrollController();

  /// The event count the record was last auto-scrolled for. A change (open, or a
  /// fresh event) re-pins the list to the bottom; unrelated rebuilds do not, so
  /// a user who scrolls up is left where they are until the next real event.
  int _recordScrolledCount = -1;

  /// Whether the hint bottom panel is open, plus its loading/result state.
  bool _hintOpen = false;
  bool _hintLoading = false;
  List<ScoredMove>? _hintMoves;
  int _hintSeq = 0;

  /// Full move to STAGE into the interactive board (tap-to-apply hint). Fired
  /// when a hint row is tapped; the [BoardView] resets its builder and re-enters
  /// the move's hops, leaving it complete but uncommitted for the user's Confirm.
  final ValueNotifier<Move?> _stagedMove = ValueNotifier<Move?>(null);

  /// Bridges the interactive [BoardView]'s move-entry builder to the bottom
  /// action bar: it mirrors the live Undo/Confirm/Pass affordances and forwards
  /// the bar's taps back into the board. Merged into [_observable] so the bar
  /// rebuilds when the affordances change.
  final BoardEntryController _entryControl = BoardEntryController();

  // --- Opponent dice-roll beat -----------------------------------------------

  /// Event cursor for the roll-beat detector, tracked SEPARATELY from the
  /// tutor's [_lastEventCount] so the two event-growth hooks advance
  /// independently.
  late int _lastRollEventCount = _c.game.events.length;

  /// The cycling dice faces shown during a NON-local mover's roll beat, or
  /// `null` when no beat is active (the board then shows the real
  /// [GameState.dice]). Passed to the [BoardView] as its `diceOverride`.
  Dice? _rollBeatDice;

  /// The current beat's frame timer, cancelled on a new beat / dispose.
  Timer? _rollBeatTimer;

  /// Monotonic guard so a superseded beat (a rapid second roll) cannot clear or
  /// advance a fresher one.
  int _rollBeatSeq = 0;

  /// Whether the opponent's dice are currently being PRESENTED — true from the
  /// moment a roll beat begins until its tumble frames AND the settle pause have
  /// elapsed. Handed to the [BoardView] as `holdMoveAnimation` so the opponent's
  /// move animation is deferred until the dice are readable. Never true for the
  /// local player's own (instant) roll, since no beat runs.
  final ValueNotifier<bool> _dicePresenting = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _observable = Listenable.merge([_c, ..._humanNotifiers(), _entryControl]);
    _observable.addListener(_onChange);
    // Fire-and-forget: the controller catches loop errors and records them on
    // `error`, which the banner surfaces. Nothing here needs the returned future.
    unawaited(_c.playMatch());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    // The one-time drag hint is scoped to THIS screen: a floating SnackBar
    // outlives its route, so without this it follows the user onto whatever
    // they open next (History, Settings, …). Removed only while our own hint is
    // the live one — never a SnackBar posted by another screen.
    //
    // Deferred to the end of the frame: this `dispose` runs while the element
    // tree is LOCKED (mid-unmount), and removing a SnackBar drives the
    // messenger's animation, which would `setState` under that lock. By the
    // post-frame callback the lock is gone and the hint is still the current
    // SnackBar (the route we are leaving with cannot have posted another).
    // The `mounted` re-check matters when the whole app goes down with us (the
    // messenger is then gone too, and driving its animation would throw).
    final messenger = _messenger;
    if (_dragHintBar != null && messenger != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (messenger.mounted) messenger.removeCurrentSnackBar();
      });
    }
    _rollBeatTimer?.cancel();
    _tapHintTimer?.cancel();
    _observable.removeListener(_onChange);
    _dicePresenting.dispose();
    _stagedMove.dispose();
    _recordScroll.dispose();
    _entryControl.dispose();
    _c.disposeController();
    super.dispose();
  }

  List<Listenable> _humanNotifiers() => [
        for (final side in [Player.white, Player.black])
          if (_c.isLocalHuman(side)) ...[
            _c.pendingMoveOf(side),
            _c.pendingCubeOf(side),
            _c.pendingResignOf(side),
          ],
      ];

  void _onChange() {
    if (!mounted) return;
    _updatePassDevice();
    _syncRollBeat();
    _syncTutor();
    _maybeShowDragHint();
    setState(() {});
  }

  // --- "That checker cannot move" hint ---------------------------------------

  /// Surfaces the brief hint behind the reported "why am I not able to move the
  /// 7?" confusion: tapping one of your own checkers that no remaining die can
  /// play used to be a completely silent no-op, leaving the user to guess
  /// whether the tap registered at all.
  ///
  /// Deliberately NOT a floating [SnackBar]: one would cover the action bar (and
  /// outlive the route). This is an in-tree layer pinned to the BOTTOM EDGE of
  /// the board's slot — right above the history strip, next to where the eye
  /// already is — so it can never reflow the board or block Undo/Confirm. A
  /// repeat tap restarts the timer instead of queueing a second hint.
  void _showNoLegalSourceHint(bool hasStagedHops) {
    final message = hasStagedHops
        ? 'No legal move for that checker with the remaining dice — try Undo'
        : 'No legal move for that checker with the remaining dice';
    _tapHintTimer?.cancel();
    setState(() => _tapHint = message);
    _tapHintTimer = Timer(_tapHintDuration, () {
      if (!mounted) return;
      setState(() => _tapHint = null);
    });
  }

  // --- One-time drag/tap hint ------------------------------------------------

  /// Surfaces the one-time drag-to-move discoverability hint the first time a
  /// human's move-entry affordances appear, then never again. Guarded so it:
  /// only fires when drag is enabled ([BoardInteractionOptions.enableDrag]) — no
  /// point advertising a disabled gesture; only fires at a human move (the
  /// affordances are up); fires at most once (the [_dragHintShown] latch, seeded
  /// from the persisted flag, plus [_dragHintScheduled] to coalesce a burst of
  /// notifications before the frame). The persisted latch flip and the
  /// [GameScreen.onDragHintShown] persistence callback run INSIDE the post-frame
  /// callback, AFTER the mounted check — so a hint that never actually displays
  /// (screen torn down before the frame) is never recorded as shown. A SnackBar
  /// cannot be shown during a build/rebuild, hence the post-frame deferral.
  ///
  /// The SnackBar floats [SnackBarBehavior.floating] with a bottom margin that
  /// clears both the fixed 64px bottom action bar and the 32px history strip
  /// above it, so Confirm / Roll and the strip stay visible and tappable —
  /// the hint is genuinely non-blocking, not just logically so.
  void _maybeShowDragHint() {
    if (_dragHintShown || _dragHintScheduled) return;
    if (!widget.interactionOptions.enableDrag) return;
    final humanMoving =
        _humanSideWith((s) => _c.pendingMoveOf(s).value != null) != null;
    if (!humanMoving) return;
    _dragHintScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dragHintShown = true;
      widget.onDragHintShown?.call();
      final messenger = ScaffoldMessenger.of(context);
      final bar = messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 104, left: 12, right: 12),
          content:
              const Text('Tip: drag checkers or tap them — change in Settings'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Got it',
            onPressed: messenger.hideCurrentSnackBar,
          ),
        ),
      );
      _dragHintBar = bar;
      // Forget the controller however the bar goes (timeout, "Got it", or a
      // replacement), so `dispose` only ever removes a hint that is still up.
      unawaited(bar.closed.then((_) {
        if (identical(_dragHintBar, bar)) _dragHintBar = null;
      }));
    });
  }

  // --- Opponent dice-roll beat ----------------------------------------------

  /// Detects a fresh [RollEvent] by a NON-local mover (AI or a remote human) and
  /// kicks off the dice-roll animation beat before the settled roll shows. The
  /// LOCAL player's own roll is instant (they pressed Roll themselves) and is
  /// skipped, as is every non-roll event. A shorter event list means a new game
  /// began: reset the cursor and cancel any live beat.
  ///
  /// The beat is gated on [GameScreen.timings]: with the [AnimationTimings.off]
  /// preset (animation off — the widget-test default) no beat ever runs and the
  /// board shows the real roll immediately. Called from [_onChange] before its
  /// [setState], so the first override frame it sets is painted by that rebuild.
  void _syncRollBeat() {
    final events = _c.game.events;
    final len = events.length;
    if (len < _lastRollEventCount) {
      _lastRollEventCount = len; // a new game reset the event log
      _cancelRollBeat();
      return;
    }
    if (len == _lastRollEventCount) return;
    for (var i = _lastRollEventCount; i < len; i++) {
      final event = events[i];
      if (event is! RollEvent) continue;
      if (_c.isLocalHuman(event.player)) continue; // own roll: no beat
      _startRollBeat(Dice(event.die1, event.die2));
    }
    _lastRollEventCount = len;
  }

  /// Begins (or restarts) the roll beat toward [realRoll]:
  /// [AnimationTimings.diceFrames] cycling frames [AnimationTimings.diceFrame]
  /// apart of deterministic pseudo-random faces, after which the override clears
  /// and the real roll shows through [GameState.dice]. The faces are seeded off
  /// [realRoll] so the sequence is stable under test, and each cycling face
  /// differs from the real roll (the dice visibly tumble). No-op when animation
  /// is off. The first frame is set synchronously; the [_onChange] `setState`
  /// that follows paints it.
  ///
  /// While the beat runs — AND for [AnimationTimings.diceSettlePause] after the
  /// dice settle — [_dicePresenting] is held `true` so the opponent's move
  /// animation (queued in the [BoardView]) does not start until the dice are
  /// readable.
  void _startRollBeat(Dice realRoll) {
    if (!widget.timings.enabled) return;
    _cancelRollBeat();
    final seq = ++_rollBeatSeq;
    final frameCount = widget.timings.diceFrames;
    final frameDuration = widget.timings.diceFrame;
    _dicePresenting.value = true; // hold the move animation until dice settle
    _rollBeatDice = _beatFace(realRoll, 0);
    var frame = 0;
    void nextFrame() {
      if (!mounted || seq != _rollBeatSeq) return;
      frame++;
      if (frame >= frameCount) {
        // Dice settle to the real roll now; hold the move animation for one more
        // settle pause so the roll is legible before the checker travels.
        setState(() => _rollBeatDice = null);
        _rollBeatTimer = Timer(widget.timings.diceSettlePause, () {
          if (!mounted || seq != _rollBeatSeq) return;
          _rollBeatTimer = null;
          _dicePresenting.value = false; // release: queued move animation begins
        });
        return;
      }
      _rollBeatTimer = Timer(frameDuration, nextFrame);
      setState(() => _rollBeatDice = _beatFace(realRoll, frame));
    }

    _rollBeatTimer = Timer(frameDuration, nextFrame);
  }

  /// Cancels any live beat and clears the override (fencing pending callbacks by
  /// bumping [_rollBeatSeq]), and releases the dice-presenting hold. Does not
  /// call [setState]; callers are already in a rebuild path (or disposing).
  void _cancelRollBeat() {
    _rollBeatTimer?.cancel();
    _rollBeatTimer = null;
    _rollBeatSeq++;
    _rollBeatDice = null;
    _dicePresenting.value = false;
  }

  /// Folds the CURRENT game's event log into each player's most recent roll, so
  /// every player keeps their OWN persistent dice pair (the fix for "the
  /// opponent dice is not perceivable"). The opening roll seeds the FIRST mover's
  /// pair (they play the opening dice); each later [RollEvent] overwrites its
  /// roller's pair. Both are `null` before a player's first roll (a blank dimmed
  /// die), and reset automatically when a new game replaces the event log.
  (Dice?, Dice?) _persistentDice() => persistentDice(_c.game.events);

  /// A deterministic dice pair for beat [frame], derived from the settled
  /// [realRoll]. Both faces are offset off the real roll (die1 always differs
  /// from the real die1), so the whole pair reads as different from the settled
  /// roll on every frame.
  Dice _beatFace(Dice realRoll, int frame) {
    int face(int real, int salt) => ((real + frame + salt) % 6) + 1;
    return Dice(face(realRoll.die1, 1), face(realRoll.die2, 3));
  }

  // --- Tutor synchronisation -------------------------------------------------

  /// Reacts to controller changes when tutor mode is on: fires a post-move
  /// assessment for a newly-landed HUMAN move, keeps the pre-roll cube advice in
  /// sync with the open gate, and clears everything on game end / a new game.
  void _syncTutor() {
    if (_tutor == null) return;
    _syncAssessment();
    _syncCubeAdvice();
    _syncCubeResponse();
  }

  /// Detects a new [MoveEvent] in the current game's event log and, when the
  /// mover is a human, kicks off an async assessment stored under the move's
  /// event index (see [_assessmentsByEventIndex]). A shorter event list means a
  /// new game began: reset and clear the accumulated assessments.
  void _syncAssessment() {
    final events = _c.game.events;
    final len = events.length;

    if (len < _lastEventCount) {
      // A new game started (the event log reset). Discard the old game's
      // assessments and abandon any in-flight ones.
      _lastEventCount = len;
      _assessmentsByEventIndex.clear();
      _revealedBest.clear();
      _gameGeneration++;
      return;
    }
    if (len == _lastEventCount) return;

    // One or more events appended since last time: assess any that are human
    // moves. In practice the loop notifies per-append, so this is usually one.
    for (var i = _lastEventCount; i < len; i++) {
      final event = events[i];
      if (event is! MoveEvent) continue;
      if (!_c.isLocalHuman(event.player)) continue;
      final before = Game.replay(
        events.sublist(0, i),
        isCrawfordGame: _c.state.isCrawfordGame,
      ).state;
      _fireAssessment(i, before, event.move);
    }
    _lastEventCount = len;
  }

  /// Assesses a human [played] move (whose event sits at [eventIndex]) and, on
  /// resolution, files it under that index — unless the game has since reset
  /// (a [_gameGeneration] mismatch) or the screen unmounted.
  void _fireAssessment(int eventIndex, GameState before, Move played) {
    final gen = _gameGeneration;
    unawaited(_tutor!.assess(before, played).then((assessment) {
      if (!mounted || gen != _gameGeneration) return;
      setState(() => _assessmentsByEventIndex[eventIndex] = assessment);
    }));
  }

  /// Recomputes the pre-roll cube advice exactly when a human's turn gate is
  /// open and doubling is legal; clears it otherwise. Keyed by the event count
  /// so it is computed once per gate.
  void _syncCubeAdvice() {
    final s = _c.state;
    final showAdvice = _c.awaitingHumanTurn && _doublingLegal(s);
    if (!showAdvice) {
      _cubeAdvice = null;
      _cubeAdviceKey = null;
      return;
    }
    final key = _c.game.events.length;
    if (_cubeAdviceKey == key) return; // already computed for this gate
    _cubeAdviceKey = key;
    final seq = ++_cubeAdviceSeq;
    _cubeAdvice = null;
    unawaited(_tutor!
        .assessCube(s, _c.contextFor(s.turn), playerDoubled: false)
        .then((advice) {
      if (!mounted || seq != _cubeAdviceSeq) return;
      setState(() => _cubeAdvice = advice);
    }));
  }

  /// Recomputes the take/pass advice while a human faces an opponent's double
  /// (a pending cube request); clears it otherwise. Keyed by the event count.
  void _syncCubeResponse() {
    final cubeSide = _humanSideWith((s) => _c.pendingCubeOf(s).value != null);
    if (cubeSide == null) {
      _cubeResponseAdvice = null;
      _cubeResponseKey = null;
      return;
    }
    final key = _c.game.events.length;
    if (_cubeResponseKey == key) return;
    _cubeResponseKey = key;
    final seq = ++_cubeResponseSeq;
    _cubeResponseAdvice = null;
    final state = _c.pendingCubeOf(cubeSide).value!;
    unawaited(_tutor!
        .assessCubeResponse(state, _c.contextFor(state.turn))
        .then((advice) {
      if (!mounted || seq != _cubeResponseSeq) return;
      setState(() => _cubeResponseAdvice = advice);
    }));
  }

  bool _doublingLegal(GameState s) =>
      !s.isCrawfordGame && (s.cube.owner == null || s.cube.owner == s.turn);

  // --- Hint panel ------------------------------------------------------------

  void _openHint() {
    setState(() {
      _hintOpen = true;
      _hintLoading = true;
      _hintMoves = null;
      // Clear any prior staged move so re-tapping the same play in a later panel
      // is a fresh null→move transition (and thus fires the board listener).
      _stagedMove.value = null;
    });
    final seq = ++_hintSeq;
    final moveSide = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    final state =
        (moveSide != null ? _c.pendingMoveOf(moveSide).value : null) ?? _c.state;
    unawaited(_tutor!.hint(state).then((moves) {
      if (!mounted || seq != _hintSeq) return;
      setState(() {
        _hintLoading = false;
        _hintMoves = moves;
      });
    }));
  }

  void _closeHint() {
    setState(() {
      _hintOpen = false;
      _hintLoading = false;
      _hintMoves = null;
      _hintSeq++;
    });
  }

  // --- Game-record panel -----------------------------------------------------

  void _openRecord() {
    setState(() {
      _recordOpen = true;
      // Force a scroll-to-bottom on the first build of the freshly-opened panel.
      _recordScrolledCount = -1;
    });
  }

  void _closeRecord() {
    setState(() => _recordOpen = false);
  }

  /// Tracks the acting side and raises the pass-device overlay when, in a
  /// hot-seat game, a human decision opens for a DIFFERENT actor than the last.
  /// Skipped for the very first human decision of the match (`_lastActor` null).
  void _updatePassDevice() {
    if (!_hotSeat || !_humanDecisionActive) return;
    final actor = _c.state.turn;
    if (_lastActor == null) {
      _lastActor = actor; // first turn: reveal immediately, no overlay
      _displayedWhiteAtBottom = actor == Player.white; // orient to first actor
    } else if (actor != _lastActor && !_passDevicePending) {
      _passDevicePending = true;
      // Flip now, while the overlay that is about to raise hides the board;
      // the new orientation is revealed only when the user taps to continue.
      _displayedWhiteAtBottom = actor == Player.white;
    }
  }

  void _dismissPassDevice() {
    setState(() {
      _lastActor = _c.state.turn;
      _passDevicePending = false;
    });
  }

  // --- Decision lookups ------------------------------------------------------

  /// Any human decision is currently open (pre-roll gate, a move, a cube
  /// response, or a resign response).
  bool get _humanDecisionActive =>
      _c.awaitingHumanTurn ||
      _humanSideWith((s) => _c.pendingMoveOf(s).value != null) != null ||
      _humanSideWith((s) => _c.pendingCubeOf(s).value != null) != null ||
      _humanSideWith((s) => _c.pendingResignOf(s).value != null) != null;

  /// The locally-human side (if any) for which [test] holds.
  Player? _humanSideWith(bool Function(Player) test) {
    for (final side in [Player.white, Player.black]) {
      if (_c.isLocalHuman(side) && test(side)) return side;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = _c.state;
    final moveSide = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    final cubeSide = _humanSideWith((s) => _c.pendingCubeOf(s).value != null);
    final resignSide =
        _humanSideWith((s) => _c.pendingResignOf(s).value != null);
    final whiteAtBottom = switch (widget.orientation) {
      BoardOrientationMode.fixedWhite => true,
      BoardOrientationMode.fixedBlack => false,
      BoardOrientationMode.followActive => _displayedWhiteAtBottom,
    };
    // Each player's persistent dice pair (their most recent roll this game), so
    // both stay visible after the turn passes.
    final (whiteDice, blackDice) = _persistentDice();

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _Hud(
                  controller: _c,
                  showScoring: widget.showScoring,
                  opponentLabel: widget.opponentLabel,
                  onGameRecord: _openRecord,
                ),
                Expanded(
                  // The board's slot. An error banner FLOATS at its top edge
                  // (just under the HUD, where it used to sit) instead of being
                  // a Column child: the board fills this slot, so a banner that
                  // took height of its own would resize the board the moment an
                  // agent errored — the same F6 no-jump rule the action bar and
                  // the advice slot follow. StackFit.expand keeps the board's
                  // constraints byte-identical to the un-stacked layout.
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // NO padding: the board gets every pixel of this slot (a
                      // reported complaint — an 8pt inset on a 390pt phone cost
                      // 4% of the board's width, and the aspect clamp then left
                      // ~24pt of dead space above and below it). With
                      // [BoardView.minAspect] relaxed below a phone slot's
                      // shape, the board now fills the slot outright.
                      BoardView(
                        state: state,
                        interactive: moveSide != null,
                        onMoveCommitted: (move) {
                          if (moveSide != null) {
                            _c.submitMove(moveSide, move);
                          }
                        },
                        whiteAtBottom: whiteAtBottom,
                        externalMove: _stagedMove,
                        lastMove: _c.lastMove,
                        holdMoveAnimation: _dicePresenting,
                        entryControl: _entryControl,
                        hopDuration: widget.timings.hop,
                        interHopDuration: widget.timings.interHop,
                        interactionOptions: widget.interactionOptions,
                        whiteDice: whiteDice,
                        blackDice: blackDice,
                        diceOverride: _rollBeatDice,
                        // Tapping the dice is a second, on-board route to the
                        // Roll button — wired under exactly the condition that
                        // enables that button, and null otherwise so dice-area
                        // taps fall through to normal move entry.
                        onDiceTap: _canRoll(moveSide) ? _rollDice : null,
                        onNoLegalSourceTap: _showNoLegalSourceHint,
                      ),
                      // Both banners are PURELY informational and float over the
                      // board, so both are hit-test transparent: a [Stack]
                      // returns the topmost child that reports a hit, so a
                      // banner left tappable silently ate every board tap in
                      // its band — and each band covers a bear-off tray strip
                      // (the error banner Black's, the hint White's). Bearing
                      // off went dead for as long as the banner was up.
                      if (_c.error != null)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: _ErrorBanner(error: _c.error!),
                          ),
                        ),
                      // Floats over the board's bottom edge, so it never takes
                      // layout height (F6) and never covers the action bar.
                      if (_tapHint != null)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: _TapHintBanner(message: _tapHint!),
                          ),
                        ),
                    ],
                  ),
                ),
                _historyStrip(),
                _pipLine(),
                _bottomRegion(moveSide),
              ],
            ),
            ..._buildModals(cubeSide, resignSide),
            if (_hintOpen) _hintPanel(),
            if (_recordOpen) _recordPanel(),
          ],
        ),
      ),
    );
  }

  /// The single active modal layer, chosen by priority: match end, then game
  /// end, then the pass-device gate, then the cube/resign response dialogs.
  List<Widget> _buildModals(Player? cubeSide, Player? resignSide) {
    if (_c.matchOver) return [_matchEndDialog()];
    if (_c.awaitingNextGame) return [_gameEndDialog()];
    if (_passDevicePending) return [_passDeviceOverlay()];
    if (cubeSide != null) return [_cubeDialog(cubeSide)];
    if (resignSide != null) return [_resignDialog(resignSide)];
    return const [];
  }

  Widget _passDeviceOverlay() {
    final name = _playerName(_c.state.turn);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismissPassDevice,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Pass the device', style: _titleStyle),
                const SizedBox(height: 12),
                Text("$name's turn", style: _titleStyle),
                const SizedBox(height: 24),
                const Text('Tap to continue'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cubeDialog(Player side) {
    final state = _c.pendingCubeOf(side).value!;
    // The decider is `state.turn`; the doubler is the opponent.
    final doubler = _playerName(state.turn.opponent);
    final newValue = state.cube.value * 2;
    final advice = _cubeResponseAdvice;
    final tutorLine = _tutor == null || advice == null
        ? ''
        : '\nTutor: ${advice.advice.shouldTake ? 'Take' : 'Pass'}';
    return _ModalCard(
      title: 'Double offered',
      message: '$doubler offers a double to $newValue. Take or pass?$tutorLine',
      actions: [
        _CardAction(
          label: 'Pass',
          onPressed: () => _c.submitCubeResponse(side, CubeAction.drop),
        ),
        _CardAction(
          label: 'Take',
          filled: true,
          onPressed: () => _c.submitCubeResponse(side, CubeAction.take),
        ),
      ],
    );
  }

  Widget _resignDialog(Player side) {
    final (state, value) = _c.pendingResignOf(side).value!;
    final resigner = _playerName(state.turn.opponent);
    return _ModalCard(
      title: 'Resignation offered',
      message: '$resigner offers to resign a ${_resignName(value)}. '
          'Accept or decline?',
      actions: [
        _CardAction(
          label: 'Decline',
          onPressed: () => _c.submitResignResponse(side, false),
        ),
        _CardAction(
          label: 'Accept',
          filled: true,
          onPressed: () => _c.submitResignResponse(side, true),
        ),
      ],
    );
  }

  Widget _gameEndDialog() {
    final result = _c.state.result!;
    return _ModalCard(
      title: 'Game over',
      message: '${_gameEndSummary(result)}\n${_scoreLine(_c)}',
      actions: [
        if (_canShowSummary) _summaryAction('Analyze game'),
        _CardAction(
          label: 'Next game',
          filled: true,
          onPressed: _c.continueToNextGame,
        ),
      ],
    );
  }

  Widget _matchEndDialog() {
    final winner = _c.match.winner;
    return _ModalCard(
      title: 'Match over',
      message: '${winner == null ? 'Nobody' : _playerName(winner)} wins the '
          'match.\n${_scoreLine(_c)}',
      // A subtle reassurance that a finished match can be revisited later from
      // the home screen's History, even after this dialog is dismissed.
      footnote: _canShowSummary ? 'Saved to History' : null,
      actions: [
        if (_canShowSummary) _summaryAction('Match summary'),
        _CardAction(
          label: 'Done',
          filled: true,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  /// The post-game analysis link is offered whenever the match is PERSISTED
  /// ([GameScreen.persistedMatchId] set) — regardless of the live [GameScreen.tutor]
  /// setting. Analysis runs off the engine (the [AnalysisScreen] builds its own
  /// [TutorService] on demand), not the live tutor, so the tutor being off must
  /// not hide the entry point. Same gate for both end dialogs.
  bool get _canShowSummary => widget.persistedMatchId != null;

  _CardAction _summaryAction(String label) => _CardAction(
        label: label,
        busy: _summaryLoading,
        onPressed: _summaryLoading ? null : _openMatchSummary,
      );

  /// Awaits the persisted match id (a brief spinner) then pushes the match's
  /// detail screen (games list → per-game analysis). Swallows a failed insert
  /// by simply clearing the spinner — the dialog stays put so the user can retry
  /// (or dismiss). Re-entrancy is guarded by [_summaryLoading].
  Future<void> _openMatchSummary() async {
    final future = widget.persistedMatchId;
    if (future == null || _summaryLoading) return;
    setState(() => _summaryLoading = true);
    int matchId;
    try {
      matchId = await future;
    } catch (_) {
      if (mounted) setState(() => _summaryLoading = false);
      return;
    }
    if (!mounted) return;
    setState(() => _summaryLoading = false);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MatchDetailScreen(matchId: matchId),
      ),
    );
  }

  // --- Tutor UI --------------------------------------------------------------

  /// Height of the tutor advice slot below the action bar. RESERVED whenever a
  /// tutor is attached, whether or not there is advice to show right now, for
  /// exactly the reason [_actionBar] is pinned to 64px: the board FILLS the slot
  /// between the HUD and this region, so on a phone (where that slot is
  /// height-bound) a line appearing here would resize the board mid-turn. The
  /// advice comes and goes at every pre-roll gate, so an unreserved line meant a
  /// board that grew and shrank by this much on every turn (F6).
  static const double _adviceLineHeight = 28;

  /// The bottom region: the fixed-height contextual action bar and, when the
  /// tutor is on, the fixed-height cube-advice slot beneath it (empty until the
  /// pre-roll gate resolves its advice).
  Widget _bottomRegion(Player? moveSide) {
    final showCube =
        _tutor != null && _cubeAdvice != null && _c.awaitingHumanTurn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionBar(moveSide),
        // With no tutor there is never advice, so no slot is reserved at all —
        // the tutor is fixed for the life of the screen, so this is still a
        // constant height per screen.
        if (_tutor != null)
          SizedBox(
            key: const ValueKey('adviceLine'),
            height: _adviceLineHeight,
            child: showCube ? _cubeAdviceLine(_cubeAdvice!) : null,
          ),
      ],
    );
  }

  /// The contextual bottom action bar. Its height is ALWAYS 64px (a fixed
  /// [SizedBox]) so nothing below the board ever reflows as the phase changes —
  /// only the bar's *contents* swap:
  ///
  /// * entering a move → `[Undo] [Confirm]` (Confirm primary, right),
  /// * a dance → `[No moves — pass]`,
  /// * the human pre-roll gate → `[Roll]`,
  /// * otherwise → a subtle status line (whose turn / thinking).
  ///
  /// The tutor Hint button sits far-left whenever a human move is open. Double
  /// and Resign are NOT here — they live in the header row, away from where
  /// thumbs rest, to avoid accidental taps.
  Widget _actionBar(Player? moveSide) {
    final scheme = Theme.of(context).colorScheme;
    final showHint = _tutor != null && moveSide != null;
    final Widget content;
    if (moveSide != null && _entryControl.isDance) {
      content = Row(
        children: [
          if (showHint) _hintButton(),
          const Spacer(),
          FilledButton(
            onPressed: _entryControl.pass,
            child: const Text('No moves — pass'),
          ),
        ],
      );
    } else if (moveSide != null) {
      content = Row(
        children: [
          if (showHint) _hintButton(),
          const Spacer(),
          TextButton(
            onPressed: _entryControl.canUndo ? _entryControl.undo : null,
            child: const Text('Undo'),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: _entryControl.canConfirm ? _entryControl.confirm : null,
            child: const Text('Confirm'),
          ),
        ],
      );
    } else if (_canRoll(moveSide)) {
      content = Row(
        children: [
          const Spacer(),
          FilledButton(
            onPressed: _rollDice,
            child: const Text('Roll'),
          ),
        ],
      );
    } else {
      content = Center(
        child: Text(
          _statusText(),
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('actionBar'),
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: content,
      ),
    );
  }

  /// Whether the local player is at the pre-roll gate, i.e. whether a Roll is
  /// the action on offer. The single source of truth for BOTH routes to it: the
  /// action bar's Roll button and the board's tap-the-dice affordance, so the
  /// two can never disagree about when rolling is allowed.
  bool _canRoll(Player? moveSide) => moveSide == null && _c.awaitingHumanTurn;

  /// Rolls the dice — the shared handler behind BOTH routes (the action bar's
  /// Roll button and the on-board dice tap).
  ///
  /// Re-checks the gate AT INVOCATION rather than trusting the enabled-ness
  /// baked into the last build. Two presses inside one frame — a double-tap on
  /// the dice, or an impatient second jab at Roll — both run the callback that
  /// frame captured, and the second arrives at a gate the first already closed:
  /// [MatchController.rollDice] is documented as valid only while
  /// [MatchController.awaitingHumanTurn], and both implementations throw
  /// otherwise (a `StateError` straight out of the gesture handler). The first
  /// press did exactly what the user wanted, so the duplicate is dropped
  /// silently; this narrows the guard to that benign race and never hides a real
  /// failure, since the throw it replaces carried no information the UI could
  /// act on.
  void _rollDice() {
    if (!_c.awaitingHumanTurn) return;
    _c.rollDice();
  }

  Widget _hintButton() => OutlinedButton.icon(
        onPressed: _openHint,
        icon: const Icon(Icons.lightbulb_outline, size: 18),
        label: const Text('Hint'),
      );

  /// The idle-bar status line: what the game is waiting on.
  String _statusText() {
    if (_c.isThinking) return 'Thinking…';
    if (_c.matchOver || _c.awaitingNextGame) return '';
    return "${_playerName(_c.state.turn)}'s turn";
  }

  /// The always-present collapsed history strip. Fixed 32px height, rendered
  /// between the board and the action bar so the board never reflows (F6). It
  /// shows the LATEST record line (ellipsized), a PERSISTENT score chip for the
  /// local player's most recent assessed move, and a chevron. Tapping anywhere
  /// expands the full scrollable record sheet ([_recordPanel]).
  ///
  /// The chip is deliberately decoupled from the latest LINE. Against the AI the
  /// tutor's verdict on your move resolves only after the AI has already replied,
  /// so a chip tied to the latest line was never visible in a vs-computer match
  /// at all — the one mode where it matters most. It now persists until a newer
  /// assessment of your own replaces it, and clears with the log on a new game.
  Widget _historyStrip() {
    final scheme = Theme.of(context).colorScheme;
    final lines = buildGameRecord(_c.game.events);
    final latest = lines.isEmpty ? null : lines.last;
    final assessment = _stripAssessment();
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: _openRecord,
        child: SizedBox(
          key: const ValueKey('historyStrip'),
          height: 32,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    latest?.text ?? 'No moves yet',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: latest == null
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                    ),
                  ),
                ),
                if (assessment != null) ...[
                  const SizedBox(width: 8),
                  _assessmentMark(assessment),
                ],
                const SizedBox(width: 4),
                Icon(Icons.expand_less,
                    size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Height of the always-present pip-count line. Like the action bar and the
  /// advice slot it is FIXED and unconditional: the board fills the slot above
  /// it, so a line that came and went would resize the board (F6).
  static const double _pipLineHeight = 20;

  /// The live pip counts for both sides, sitting with the tutor metrics just
  /// under the history strip ("missing pip count along the tutor metrics").
  ///
  /// Named from the local player's point of view where there is one — "Pips:
  /// You 132 · AI 145", reusing [GameScreen.opponentLabel] so an online match
  /// reads "Opp" — and neutrally ("W … · B …") in hot-seat, where both sides are
  /// local and neither of them is "you". Same rule as the header score.
  ///
  /// Counts come from the COMMITTED board, so they step once per move rather
  /// than flickering through a half-entered turn.
  Widget _pipLine() {
    final scheme = Theme.of(context).colorScheme;
    final board = _c.state.board;
    final white = board.pipCount(Player.white);
    final black = board.pipCount(Player.black);
    final localWhite = _c.isLocalHuman(Player.white);
    final localBlack = _c.isLocalHuman(Player.black);
    final soleLocal = localWhite != localBlack;
    final String text;
    if (!soleLocal) {
      text = 'Pips: W $white · B $black';
    } else {
      final (mine, theirs) =
          localWhite ? (white, black) : (black, white);
      text = 'Pips: You $mine · ${widget.opponentLabel} $theirs';
    }
    return SizedBox(
      key: const ValueKey('pipLine'),
      height: _pipLineHeight,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  /// The assessment the strip's score chip shows: the most recent assessed move
  /// by [_chipSide], or `null` when that side has none yet this game.
  ///
  /// Assessments are only ever recorded for locally-human movers, so this scans
  /// [_assessmentsByEventIndex] backwards for the highest event index whose
  /// [MoveEvent] belongs to the chip's side. Entries whose index no longer
  /// addresses the live log (a game reset that has not yet cleared the map) are
  /// skipped defensively.
  ///
  /// Runs on every build, so it scans the LOG backwards (which is already in
  /// index order) and looks each candidate up in the map, rather than sorting
  /// the map's keys — no allocation, and it stops at the first hit.
  MoveAssessment? _stripAssessment() {
    if (_assessmentsByEventIndex.isEmpty) return null;
    final side = _chipSide();
    if (side == null) return null;
    final events = _c.game.events;
    for (var index = events.length - 1; index >= 0; index--) {
      final event = events[index];
      if (event is! MoveEvent || event.player != side) continue;
      final assessment = _assessmentsByEventIndex[index];
      if (assessment != null) return assessment;
    }
    return null;
  }

  /// Whose score the strip chip reports: in hot-seat the CURRENT mover (the
  /// person now holding the device sees their own last verdict); otherwise the
  /// single locally-human side (vs-AI or the local side of an online match).
  Player? _chipSide() {
    if (_hotSeat) return _c.state.turn;
    return _humanSideWith((_) => true);
  }

  /// The compact assessment indicator: a mark-coloured dot, the mark WORD, and
  /// (when the move gave up measurable equity) the loss — e.g. a red dot +
  /// "Error −0.061". The word is carried alongside the colour so the mark reads
  /// without relying on colour alone (a colour-blind accessibility guard). A
  /// best play (loss below the display threshold) shows just the dot + "Best".
  Widget _assessmentMark(MoveAssessment a) {
    final (color, label) = _markStyle(a.mark);
    final loss = a.equityLoss;
    final lossText = loss >= 0.001 ? ' −${loss.toStringAsFixed(3)}' : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 4),
        Text(
          '$label$lossText',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// Mark → (colour, label): best/good green, dubious amber, error orange,
  /// blunder red.
  (Color, String) _markStyle(MoveMark mark) => switch (mark) {
        MoveMark.best => (Colors.green.shade700, 'Best'),
        MoveMark.good => (Colors.green.shade600, 'Good'),
        MoveMark.dubious => (Colors.amber.shade800, 'Dubious'),
        MoveMark.error => (Colors.orange.shade800, 'Error'),
        MoveMark.blunder => (Colors.red.shade700, 'Blunder'),
      };

  /// The pre-roll cube advice: "Tutor: Double — opponent should take/pass" or
  /// "Tutor: Roll".
  /// Fills the reserved [_adviceLineHeight] slot (see [_bottomRegion]); the row
  /// is centred in it rather than padded to its own height.
  Widget _cubeAdviceLine(CubeAssessment a) {
    final advice = a.advice;
    final text = advice.shouldDouble
        ? 'Tutor: Double — opponent should '
            '${advice.shouldTake ? 'take' : 'pass'}'
        : 'Tutor: Roll';
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.school, size: 16, color: scheme.primary),
        const SizedBox(width: 6),
        // Scale-to-fit rather than overflow: the longest advice string ("Double
        // — opponent should take") outgrows a narrow phone once the system text
        // scale is turned up, and a slightly smaller line still reads. Mirrors
        // the HUD score's treatment.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(color: scheme.primary, fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }

  /// The in-tree hint bottom panel: top-5 plays with equity and delta, or a
  /// loading spinner while the ranking resolves.
  Widget _hintPanel() {
    final moves = _hintMoves ?? const <ScoredMove>[];
    final bestEq = moves.isEmpty ? 0.0 : moves.first.equity;
    final top = moves.take(5).toList();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeHint,
            child: const ColoredBox(color: Colors.black54),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Top plays',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                        ),
                        IconButton(
                          tooltip: 'What do these numbers mean?',
                          icon: const Icon(Icons.info_outline, size: 20),
                          onPressed: () => showMetricExplainer(context),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: _closeHint,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_hintLoading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (top.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No hints available.'),
                      )
                    else ...[
                      _hintColumnHeader(),
                      for (var i = 0; i < top.length; i++)
                        _hintRow(i, top[i], bestEq),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Names the hint sheet's two bare number columns ("Equity" / "Loss"), right-
  /// aligned over them at the same widths the rows use, so the figures are not
  /// left for the reader to guess at. The ⓘ in the sheet header explains what
  /// they mean.
  Widget _hintColumnHeader() {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          const Spacer(),
          SizedBox(
            width: _hintNumberColumn,
            child: Text('Equity', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: _hintNumberColumn,
            child: Text('Loss', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  /// Width of each of the hint sheet's number columns, shared by the header and
  /// the rows so the labels sit exactly over their figures.
  static const double _hintNumberColumn = 64;

  Widget _hintRow(int i, ScoredMove sm, double bestEq) {
    final delta = i == 0 ? '—' : (sm.equity - bestEq).toStringAsFixed(3);
    final mono = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    // Tap-to-apply: stage the play onto the interactive board and close the
    // panel. Guarded to the human's own moving phase (where the board is
    // interactive); if no move is pending it degrades to just closing the panel.
    return InkWell(
      onTap: () => _applyHint(sm.move),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Text('${i + 1}.', style: mono),
            ),
            Expanded(child: Text('${sm.move}', style: mono)),
            const SizedBox(width: 8),
            SizedBox(
              width: _hintNumberColumn,
              child: Text(sm.equity.toStringAsFixed(3),
                  style: mono, textAlign: TextAlign.right),
            ),
            SizedBox(
              width: _hintNumberColumn,
              child: Text(delta, style: mono, textAlign: TextAlign.right),
            ),
          ],
        ),
      ),
    );
  }

  /// Stages [move] onto the interactive board (via [_stagedMove]) and closes the
  /// hint panel. Only stages when a human move is actually pending — otherwise
  /// the board is not interactive and would ignore it, so we simply close.
  void _applyHint(Move move) {
    final moveSide = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    if (moveSide != null) _stagedMove.value = move;
    _closeHint();
  }

  /// The in-tree move-history bottom sheet (the expanded form of
  /// [_historyStrip]): a scrollable list of the CURRENT game's record lines
  /// (see [buildGameRecord]), each with an actor-coloured leading dot and, for
  /// assessed human moves, a trailing mark + loss with a tap-to-reveal best
  /// line. It floats OVER the board as a scrimmed overlay layer of the screen
  /// [Stack], so opening it never reflows the board (F6). Height is ~40% of the
  /// screen. Auto-scrolls to the newest line on open and whenever a fresh event
  /// appends while it is open; a manual scroll-up is respected until the next
  /// event. Both the ⋮ "Game record" entry and the strip route here.
  Widget _recordPanel() {
    final lines = buildGameRecord(_c.game.events);
    final count = _c.game.events.length;
    // Re-pin to the bottom on open (count reset to -1) and on any new event.
    if (count != _recordScrolledCount) {
      _recordScrolledCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_recordScroll.hasClients) {
          _recordScroll.jumpTo(_recordScroll.position.maxScrollExtent);
        }
      });
    }
    final height = MediaQuery.of(context).size.height * 0.4;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeRecord,
            child: const ColoredBox(color: Colors.black54),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: SizedBox(
              height: height,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Game record',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 2),
                                Text(
                                  _recordScoreContext(),
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: _closeRecord,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: lines.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text('No moves yet.'),
                              )
                            : ListView.builder(
                                controller: _recordScroll,
                                itemCount: lines.length,
                                itemBuilder: (context, i) => _recordRow(lines[i]),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The sheet's score context: "Game 3 · W 2–1 B · to 5".
  String _recordScoreContext() {
    final m = _c.match;
    return 'Game ${_c.gameNumber} · W ${m.whiteScore}–${m.blackScore} B · '
        'to ${m.matchLength}';
  }

  /// One record row. Assessed HUMAN moves (an entry in
  /// [_assessmentsByEventIndex] for [RecordLine.eventIndex]) get a trailing
  /// mark + loss and become tappable: a tap toggles a one-line "Best: …" reveal
  /// beneath the row. Unassessed lines render plainly.
  Widget _recordRow(RecordLine line) {
    final mono = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final index = line.eventIndex;
    final assessment =
        index == null ? null : _assessmentsByEventIndex[index];
    final revealed = index != null && _revealedBest.contains(index);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _actorDot(line.actor),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(line.text, style: mono)),
          if (assessment != null) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: _assessmentMark(assessment),
            ),
          ],
        ],
      ),
    );

    if (assessment == null) return row;

    // Assessed: tappable, with a tap-to-reveal best-move line under the row.
    final best = assessment.best;
    return InkWell(
      onTap: () => setState(() {
        if (revealed) {
          _revealedBest.remove(index);
        } else {
          _revealedBest.add(index!);
        }
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row,
          if (revealed && best.checkerMoves.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 4),
              child: Text('Best: $best',
                  style: mono?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
            ),
        ],
      ),
    );
  }

  /// A small leading dot in the actor's checker colour (ivory for White, ebony
  /// for Black), or an empty transparent slot for a neutral line (the opening).
  Widget _actorDot(Player? actor) {
    if (actor == null) return const SizedBox(width: 10, height: 10);
    final isWhite = actor == Player.white;
    final color =
        isWhite ? BoardTheme.light.whiteChecker : BoardTheme.light.blackChecker;
    final border = isWhite
        ? BoardTheme.light.whiteCheckerBorder
        : BoardTheme.light.blackCheckerBorder;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 1),
      ),
    );
  }

  TextStyle get _titleStyle =>
      Theme.of(context).textTheme.headlineSmall ?? const TextStyle(fontSize: 20);
}

// --- Shared formatting -------------------------------------------------------

String _playerName(Player p) => p == Player.white ? 'White' : 'Black';

String _resignName(ResignValue v) => switch (v) {
      ResignValue.single => 'single',
      ResignValue.gammon => 'gammon',
      ResignValue.backgammon => 'backgammon',
    };

/// The game-end dialog's one-line summary, in plain language.
///
/// Replaces the old jargon fold ("Black wins 1 (drop).", which read as a score
/// of 1 and a mystery word) with what actually happened and what it was worth:
/// "Black wins this game (+1) — White declined the double." / "White wins this
/// game (+2, gammon)." Terse by design — the running match score follows on the
/// next line.
String _gameEndSummary(GameResult result) {
  final winner = _playerName(result.winner);
  final loser = _playerName(result.winner.opponent);
  final points = '+${result.points}';
  return switch (result.outcome) {
    GameOutcome.single => '$winner wins this game ($points).',
    GameOutcome.gammon => '$winner wins this game ($points, gammon).',
    GameOutcome.backgammon =>
      '$winner wins this game ($points, backgammon).',
    GameOutcome.drop =>
      '$winner wins this game ($points) — $loser declined the double.',
    GameOutcome.resignation =>
      '$winner wins this game ($points) — $loser resigned.',
  };
}

String _scoreLine(MatchController c) {
  final m = c.match;
  return 'White ${m.whiteScore} — ${m.blackScore} Black  (to ${m.matchLength})';
}

/// The compact header score, named from the local player's point of view where
/// there IS one: "You 2–3 AI · to 5" against the computer (or "… Opp …" online,
/// per [GameScreen.opponentLabel]), with the local side's score first.
///
/// Falls back to the neutral "W 2–3 B · to 5" in hot-seat, where both sides are
/// local, and for any controller with no locally-human side at all (an AI-vs-AI
/// harness), since "You" would then be a lie.
String _compactScore(MatchController c, String opponentLabel) {
  final m = c.match;
  final localWhite = c.isLocalHuman(Player.white);
  final localBlack = c.isLocalHuman(Player.black);
  final soleLocal = localWhite != localBlack;
  if (!soleLocal) {
    return 'W ${m.whiteScore}–${m.blackScore} B · to ${m.matchLength}';
  }
  final (mine, theirs) = localWhite
      ? (m.whiteScore, m.blackScore)
      : (m.blackScore, m.whiteScore);
  return 'You $mine–$theirs $opponentLabel · to ${m.matchLength}';
}

/// Entries in the header overflow (⋮) menu. "Game record" is always available;
/// the resign entries appear only at the human's pre-roll gate.
enum _MenuAction {
  gameRecord,
  resignSingle,
  resignGammon,
  resignBackgammon,
}

// --- HUD (single row) --------------------------------------------------------

/// The single-row header: a compact score, an optional Crawford badge, the cube
/// chip, a spacer, an optional thinking dot, then the Double button and the
/// overflow (⋮) menu holding Resign. Keeping Double/Resign up here (rather than
/// in the bottom bar) puts the risky actions away from where thumbs rest.
class _Hud extends StatelessWidget {
  const _Hud({
    required this.controller,
    required this.onGameRecord,
    this.showScoring = true,
    this.opponentLabel = 'AI',
  });

  final MatchController controller;

  /// Opens the move-history ("Game record") panel.
  final VoidCallback onGameRecord;

  /// Whether the running match score is shown (the settings `showScoring`).
  final bool showScoring;

  /// What the score calls the non-local side. See [GameScreen.opponentLabel].
  final String opponentLabel;

  bool get _humanDeciding {
    if (controller.awaitingHumanTurn) return true;
    for (final side in [Player.white, Player.black]) {
      if (controller.isLocalHuman(side) &&
          (controller.pendingMoveOf(side).value != null ||
              controller.pendingCubeOf(side).value != null ||
              controller.pendingResignOf(side).value != null)) {
        return true;
      }
    }
    return false;
  }

  bool get _doublingLegal {
    if (controller.cubeless) return false;
    final s = controller.state;
    return !s.isCrawfordGame &&
        (s.cube.owner == null || s.cube.owner == s.turn);
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final cube = state.cube;
    // The thinking dot reflects a genuine AI await, not a human's own decision
    // (the controller keeps `isThinking` true while it awaits a human move too).
    final showThinking = controller.isThinking && !_humanDeciding;
    // Double/Resign are only meaningful at the human's own pre-roll gate.
    final atGate = controller.awaitingHumanTurn;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            // The left group (score, Crawford badge, cube chip) takes ALL the
            // space the right-hand controls leave. A bare `Flexible` + `Spacer`
            // split the free space evenly instead, which truncated the longer
            // "You 0–1 AI · to 3" score to "You 0–1 AI · t…" on a phone.
            //
            // The group scales to fit as ONE unit rather than flexing the score
            // alone: a clipped score ("You 0–1 AI · t…") tells the player
            // nothing, whereas a slightly smaller row still reads — and the
            // badge and chip beside it are RIGID, so a flexing score could not
            // absorb them. In a 1-point match (Crawford from the first roll)
            // that rigid pair plus the score overflowed the row by a hair on a
            // 390pt phone. Scaling the whole group can never overflow, at any
            // width or system text scale, and only kicks in when the group
            // genuinely outgrows the row — long names, two-digit scores, an
            // 11-point match, the Crawford badge.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  // Unbounded inside the FittedBox: measured at natural size,
                  // then scaled — so no child here may be Flexible.
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The score segment is hidden entirely when scoring is off;
                    // the rest of the header (Crawford badge, cube chip, Double,
                    // overflow) stays.
                    if (showScoring)
                      Text(
                        _compactScore(controller, opponentLabel),
                        maxLines: 1,
                        softWrap: false,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    if (state.isCrawfordGame) ...[
                      if (showScoring) const SizedBox(width: 8),
                      const _MiniBadge(icon: Icons.star, label: 'Crawford'),
                    ],
                    // The cube chip is hidden in a cubeless match (no cube).
                    if (!controller.cubeless) ...[
                      const SizedBox(width: 8),
                      _CubeChip(value: cube.value, owner: cube.owner),
                    ],
                  ],
                ),
              ),
            ),
            if (showThinking) ...[
              const _ThinkingDot(),
              const SizedBox(width: 8),
            ],
            // The Double button is omitted entirely in a cubeless match.
            if (!controller.cubeless)
              OutlinedButton.icon(
                onPressed:
                    atGate && _doublingLegal ? controller.offerDouble : null,
                icon: const Icon(Icons.control_point_duplicate, size: 16),
                label: const Text('Double'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            PopupMenuButton<_MenuAction>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'More actions',
              onSelected: (action) {
                switch (action) {
                  case _MenuAction.gameRecord:
                    onGameRecord();
                  case _MenuAction.resignSingle:
                    controller.offerResign(ResignValue.single);
                  case _MenuAction.resignGammon:
                    controller.offerResign(ResignValue.gammon);
                  case _MenuAction.resignBackgammon:
                    controller.offerResign(ResignValue.backgammon);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                    value: _MenuAction.gameRecord, child: Text('Game record')),
                // Resign is only meaningful (and legal) at the human's own
                // pre-roll gate, so its entries appear only then.
                if (atGate) ...const [
                  PopupMenuDivider(),
                  PopupMenuItem(
                      value: _MenuAction.resignSingle,
                      child: Text('Resign — single')),
                  PopupMenuItem(
                      value: _MenuAction.resignGammon,
                      child: Text('Resign — gammon')),
                  PopupMenuItem(
                      value: _MenuAction.resignBackgammon,
                      child: Text('Resign — backgammon')),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A small icon+label chip (e.g. the Crawford marker).
class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(label,
              style:
                  TextStyle(color: scheme.onSecondaryContainer, fontSize: 12)),
        ],
      ),
    );
  }
}

/// The doubling-cube chip: value plus the owner's initial (or centred when
/// nobody owns it).
class _CubeChip extends StatelessWidget {
  const _CubeChip({required this.value, required this.owner});

  final int value;
  final Player? owner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final suffix = owner == null
        ? ''
        : ' ${owner == Player.white ? 'W' : 'B'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('×$value$suffix',
          style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12)),
    );
  }
}

/// A small static dot signalling the AI is thinking (a compact replacement for
/// the old "thinking…" chip). Deliberately not animated, so tests that
/// `pumpAndSettle` through AI turns are not blocked by a perpetual animation.
class _ThinkingDot extends StatelessWidget {
  const _ThinkingDot();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Thinking',
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// --- Error banner ------------------------------------------------------------

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$error',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Transient board hint ----------------------------------------------------

/// The brief "that checker cannot move" strip pinned to the bottom edge of the
/// board slot. A plain [Material] row — not a [SnackBar] — so it neither covers
/// the action bar nor survives a route change, and no animation is left pending
/// for `pumpAndSettle`.
class _TapHintBanner extends StatelessWidget {
  const _TapHintBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.inverseSurface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: scheme.onInverseSurface),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                style: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Declarative modal card --------------------------------------------------

class _CardAction {
  const _CardAction({
    required this.label,
    required this.onPressed,
    this.filled = false,
    this.busy = false,
  });

  final String label;

  /// Null disables the button (e.g. while [busy] awaits an async action).
  final VoidCallback? onPressed;
  final bool filled;

  /// When true the button shows a small spinner in place of its label.
  final bool busy;
}

/// A declarative modal: an opaque [ModalBarrier] plus a centred [Material] card.
/// No route, no animation — visibility is a pure function of the caller's state.
class _ModalCard extends StatelessWidget {
  const _ModalCard({
    required this.title,
    required this.message,
    required this.actions,
    this.footnote,
  });

  final String title;
  final String message;
  final List<_CardAction> actions;

  /// An optional subtle line (bodySmall) shown between the message and the
  /// action row — e.g. the match-end "Saved to History" reassurance.
  final String? footnote;

  /// Renders one action as a filled or text button, showing a small spinner in
  /// place of the label while [_CardAction.busy].
  Widget _actionButton(_CardAction action) {
    final child = action.busy
        ? const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(action.label);
    return action.filled
        ? FilledButton(onPressed: action.onPressed, child: child)
        : TextButton(onPressed: action.onPressed, child: child);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: ModalBarrier(color: Colors.black54, dismissible: false),
        ),
        Center(
          child: Material(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    Text(message),
                    if (footnote != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        footnote!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    // Wrap (not Row) so a second action — e.g. the post-match
                    // "Match summary" link alongside "Next game" / "Done" — flows
                    // onto a new line rather than overflowing the narrow card.
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        for (final action in actions) _actionButton(action),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
