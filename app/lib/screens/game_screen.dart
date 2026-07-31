import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';

import '../analytics/analytics_events.dart';
import '../analytics/app_analytics.dart';
import '../board/board_view.dart';
import '../data/app_settings.dart';
import '../game/game_record.dart';
import '../game/match_controller.dart';
import '../game/player_agent.dart';
import '../tutor/move_assessment.dart';
import '../tutor/tutor_service.dart';
import 'game/dice_presenter.dart';
import 'game/game_dialogs.dart';
import 'game/game_hud.dart';
import 'game/hint_panel.dart';
import 'game/score_sheet_panel.dart';
import 'game/tutor_sync.dart';
import 'history_screen.dart';

/// The playing screen. Assembles the [BoardView], a top HUD, a bottom action
/// bar (plus, in tabletop hot-seat, a second one rotated 180° at the top edge —
/// see [tabletop]), the in-game dialogs (cube/resign responses, game-end,
/// match-end), the error banner, and the hot-seat pass-device overlay.
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
/// [BoardOrientationMode.followActive] (hot-seat "Rotate board between turns",
/// a setting that is OFF by default) flips the board so the active player is
/// always at the bottom. With the pass-device overlay on ([showPassDevice]) the
/// flip happens BEHIND it, so the rotation is never seen mid-turn; with the
/// overlay off the flip happens in the open at the hand-over, and IS the
/// hand-over cue.
///
/// The hot-seat DEFAULT is neither of those hand-overs: it is the TABLETOP
/// layout ([tabletop]) — a fixed White-at-bottom board with a second, 180°
/// rotated action bar at the top edge for the player sitting opposite. Nothing
/// rotates between turns; only which of the two bars is live changes.
///
/// ## The dice presentation
///
/// Every roll — the opening roll, the local player's, the opponent's — is
/// PRESENTED: the roller's pair tumbles through pseudo-random faces, settles on
/// the real roll, and is held readable for a settle pause before anything else
/// moves. The whole beat lives in [DicePresenter], which this screen owns and
/// listens to; the board is a pure renderer, fed the tumbling faces as
/// [BoardView.diceOverride] and the emphasis as [BoardView.activeDiceSide]. See
/// that class for what the presentation drives (which pair is lit, when a queued
/// move may travel, and when move entry opens).
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
    this.opponentDetail,
    this.showPassDevice = false,
    this.tabletop = false,
    this.analytics = const NoopAnalytics(),
    this.analyticsMode = AnalyticsModes.vsComputer,
  });

  /// Where this screen's usage events go.
  ///
  /// Injected rather than read from a provider because this screen is a plain
  /// [StatefulWidget] that several tests mount WITHOUT a [ProviderScope] above
  /// it (see `test/net/`). The default no-op keeps every one of those working
  /// untouched; the four production call sites pass
  /// `ref.read(appAnalyticsProvider)`.
  final AppAnalytics analytics;

  /// One of [AnalyticsModes] — how this match is being played, which is the
  /// dimension every event on this screen is sliced by.
  ///
  /// Defaults to `vsComputer` rather than being required for the same reason
  /// [analytics] is injectable: a telemetry parameter must not force churn on
  /// harnesses that only care about the board. Production call sites always
  /// pass it.
  final String analyticsMode;

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

  /// An extra qualifier for the opponent on the header's second row — the AI
  /// difficulty ("Easy", "Expert") where the caller knows it, giving "vs AI ·
  /// Easy · Pips 129–78". Null wherever there is no such thing to say (hot-seat,
  /// online, a bare test harness); the row keeps its reserved height regardless.
  final String? opponentDetail;

  /// Whether the hot-seat "Pass the device" cover screen gates each hand-over
  /// (the persisted `AppSettings.showPassDevice`). DEFAULT FALSE, matching the
  /// stored default: the reported feedback was that the cover screen is an
  /// unwanted extra tap between two people sharing one device. With it off the
  /// board still flips to the new actor — that rotation is the cue. Ignored
  /// outside hot-seat, where there is nobody to pass to.
  final bool showPassDevice;

  /// Hot-seat TABLETOP layout: the two players sit at opposite edges of a device
  /// lying flat between them, so each gets an action bar at their OWN edge — the
  /// usual bottom bar for the player the board faces, plus a second bar pinned
  /// directly under the header and rotated 180° for the player opposite. See
  /// [_topActionBar].
  ///
  /// DEFAULT FALSE — production turns it on for every hot-seat match whose
  /// "Rotate board between turns" setting is off (which is itself the default):
  /// "when playing person vs person, the default should be not flipping the
  /// board. People will share the device at each side, place action buttons for
  /// each player, and keep the board fixed". Turning the rotation setting ON
  /// turns this OFF — the flip paradigm keeps the single bottom bar, because the
  /// board (and with it the acting player) always faces the bottom edge, so a
  /// second bar would serve nobody.
  ///
  /// Ignored outside hot-seat and ignored under
  /// [BoardOrientationMode.followActive] (see [_tabletopBars]): a mode with one
  /// local human has nobody at the top edge. It is FIXED for the life of the
  /// screen, which is what keeps the fixed-height budget constant per screen —
  /// see the two budgets documented on [ScoreSheetPanel.height].
  final bool tabletop;

  /// The live tutor, or `null` when tutor mode is off. When non-null the screen
  /// surfaces a hint button (top-5 plays), post-move assessments for EVERY move
  /// — both sides, human or not (a mark dot + equity loss in the score sheet's
  /// cells) — and cube advice at the human's pre-roll gate / cube-offer dialog.
  /// Display-only: hints never auto-apply.
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

  /// Whether the screen runs PER-EDGE action bars (the tabletop hot-seat
  /// layout): the requested [GameScreen.tabletop], narrowed to the only
  /// situation it can mean anything — a hot-seat match on a board that does not
  /// rotate. Under [BoardOrientationMode.followActive] the acting player is
  /// always at the bottom already, so the top bar would serve nobody and the
  /// single bottom bar is kept.
  ///
  /// Constant for the life of the screen (every input is), which is what lets
  /// the fixed-height budget stay per-screen constant — see [ScoreSheetPanel.height].
  bool get _tabletopBars =>
      widget.tabletop &&
      _hotSeat &&
      widget.orientation != BoardOrientationMode.followActive;

  TutorService? get _tutor => widget.tutor;

  // --- Tutor state -----------------------------------------------------------

  /// The live tutor's bookkeeping: per-move assessments, the pre-roll cube
  /// advice, and the take/pass advice at an incoming double.
  late final TutorSync _tutorSync;

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

  // --- Rebuild scoping -------------------------------------------------------
  //
  // Most of what makes this screen rebuild concerns the BOARD: a roll-beat
  // frame, an animation starting, a tap hint appearing and clearing. The header
  // and the score sheet do not care about any of it, and the sheet in
  // particular re-folds the whole event log to build its rows. Both are
  // therefore held as ONE widget instance and handed back unchanged: an
  // identical widget in the same slot short-circuits the element update, so the
  // subtree is not rebuilt at all. Each listens to what it actually depends on
  // instead.

  /// Ticks when the SCORE SHEET's content changes: a new (or replaced) event
  /// log, an assessment landing, a best-play line revealed. Nothing else moves
  /// a row, so nothing else needs to rebuild the sheet.
  final ValueNotifier<int> _sheetRevision = ValueNotifier<int>(0);

  /// The event log [_sheetRevision] last accounted for, by identity — `Game`
  /// hands out a fresh unmodifiable list per append and never mutates one, so
  /// the same instance IS the same content, and a replaced log of equal length
  /// is still caught.
  List<GameEvent>? _sheetSeenEvents;

  /// The header and the sheet, built once each. Cleared by [didUpdateWidget]:
  /// they close over `widget`'s labels and flags, which a caller may replace.
  Widget? _hudWidget;
  Widget? _scoreSheetWidget;

  /// [buildScoreSheet] / [persistentDice] of the current log. Both are folds of
  /// the WHOLE log and both were re-run on every rebuild — many times a second
  /// while the dice tumble — for a log that had not changed. Keyed by the same
  /// list identity as [_sheetSeenEvents].
  List<GameEvent>? _foldedEvents;
  List<ScoreSheetRow> _foldedRows = const [];
  (Dice?, Dice?) _foldedDice = (null, null);

  void _refoldEvents() {
    final events = _c.game.events;
    if (identical(events, _foldedEvents)) return;
    _foldedEvents = events;
    _foldedRows = buildScoreSheet(events);
    _foldedDice = persistentDice(events);
  }

  /// The sheet's rows for the current log (folded once per log).
  List<ScoreSheetRow> _scoreSheetRows() {
    _refoldEvents();
    return _foldedRows;
  }

  /// Ticks [_sheetRevision] when the sheet's content has moved. Called from
  /// [_onChange] for the log, and directly from the two places that change an
  /// assessment or a revealed line.
  void _markSheetDirty() {
    _sheetRevision.value++;
  }

  void _syncSheetLog() {
    final events = _c.game.events;
    if (identical(events, _sheetSeenEvents)) return;
    _sheetSeenEvents = events;
    _markSheetDirty();
  }

  /// The tutor hint panel's open/loading/result state, and the staged move it
  /// hands to the board when a hint row is tapped.
  final HintController _hint = HintController();

  /// Bridges the interactive [BoardView]'s move-entry builder to the bottom
  /// action bar: it mirrors the live Undo/Confirm/Pass affordances and forwards
  /// the bar's taps back into the board. Merged into [_observable] so the bar
  /// rebuilds when the affordances change.
  final BoardEntryController _entryControl = BoardEntryController();

  // --- Dice-roll beat --------------------------------------------------------

  /// The dice presentation state machine (the roll beat, which pair is lit, and
  /// whether move entry is still held). Owned here and listened to, so a beat
  /// frame rebuilds the screen exactly as it did when the beat lived inline.
  late final DicePresenter _dice;

  @override
  void initState() {
    super.initState();
    _tutorSync = TutorSync(
      controller: _c,
      tutor: () => widget.tutor,
      doublingLegal: _doublingLegal,
      pendingCubeSide: () =>
          _humanSideWith((s) => _c.pendingCubeOf(s).value != null),
      onSheetDirty: _markSheetDirty,
    )..addListener(_repaint);
    _dice = DicePresenter(
      controller: _c,
      timings: () => widget.timings,
      // Entry just opened at the end of a beat, without a controller
      // notification: the two things that wait for exactly those affordances
      // have to be re-offered or they would sit out the whole move.
      onEntryOpened: () {
        _syncDancePass();
        _maybeShowDragHint();
      },
    )..addListener(_repaint);
    _hint.addListener(_repaint);
    _observable = Listenable.merge([_c, ..._humanNotifiers(), _entryControl]);
    _observable.addListener(_onChange);
    widget.analytics.logScreenView(AnalyticsScreens.game);
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
  void didUpdateWidget(GameScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The cached header and sheet close over this widget's labels, flags and
    // callbacks. A replaced widget may carry different ones, so the caches go.
    _hudWidget = null;
    _scoreSheetWidget = null;
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
    _tapHintTimer?.cancel();
    _cancelDancePass();
    _observable.removeListener(_onChange);
    _dice.removeListener(_repaint);
    _dice.dispose();
    _tutorSync.removeListener(_repaint);
    _tutorSync.dispose();
    _hint.removeListener(_repaint);
    _hint.dispose();
    _sheetRevision.dispose();
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
    _syncSheetLog();
    _reportMatchCompletion();
    _updatePassDevice();
    _closeSurrenderIfOutranked();
    _dice.syncRollBeat();
    _syncDancePass();
    _tutorSync.sync();
    _maybeShowDragHint();
    setState(() {});
  }

  /// A presentation-only collaborator moved (the dice beat, the hint panel):
  /// repaint. Both notify exactly where this screen used to call [setState]
  /// inline, and neither is merged into [_observable] — the header and the score
  /// sheet must not rebuild for a tumbling die or an opened hint sheet.
  void _repaint() {
    if (!mounted) return;
    setState(() {});
  }

  // --- Analytics -------------------------------------------------------------

  /// Whether the match-completed event has already been sent.
  ///
  /// [_onChange] fires many times after a match ends (the dialog, the score
  /// sheet, an animation settling), and `matchOver` stays true for all of them.
  /// Without this latch one finished match would report dozens of completions
  /// and every "matches played" figure in the console would be fiction.
  bool _completionReported = false;

  void _reportMatchCompletion() {
    if (_completionReported || !_c.matchOver) return;
    _completionReported = true;
    final match = _c.match;
    final winner = match.winner;
    if (winner == null) return;
    final winnerScore =
        winner == Player.white ? match.whiteScore : match.blackScore;
    final loserScore =
        winner == Player.white ? match.blackScore : match.whiteScore;
    widget.analytics.logMatchCompleted(
      mode: widget.analyticsMode,
      matchLength: match.matchLength,
      localWon: _localWon(winner),
      winnerScore: winnerScore,
      loserScore: loserScore,
    );
  }

  /// Did the person holding this device win?
  ///
  /// `null` when the question has no answer: hot-seat and tabletop have TWO
  /// local humans, so "local won" would be true whoever won and the figure
  /// would quietly inflate every win rate that includes shared-device play.
  bool? _localWon(Player winner) {
    final whiteLocal = _c.isLocalHuman(Player.white);
    final blackLocal = _c.isLocalHuman(Player.black);
    if (whiteLocal == blackLocal) return null; // both, or neither (AI vs AI).
    return winner == (whiteLocal ? Player.white : Player.black);
  }

  /// Logs the local player's double. Called from BOTH double affordances (the
  /// header's and the tabletop action bar's) — they are separate widgets, and a
  /// double is a double whichever one sent it.
  void _logCubeOffered() => widget.analytics
      .logCubeOffered(mode: widget.analyticsMode, cubeValue: _c.state.cube.value);

  // --- Auto-pass on a dance --------------------------------------------------

  /// How long a human's dance is HELD on screen before the turn passes itself,
  /// with animations on. Long enough to read the dice and the "No moves" line
  /// and understand why nothing can be played — the roll's own beat has already
  /// shown the dice by the time this starts — and short enough not to feel like
  /// a hang. Collapses to zero with animations off (see [_dancePause]).
  static const Duration _danceHold = Duration(milliseconds: 1200);

  /// The pending auto-pass, or `null` when no dance is being held.
  Timer? _dancePassTimer;

  /// Fences a superseded hold (the position moved on) against a timer that has
  /// already been scheduled.
  int _dancePassSeq = 0;

  /// The hold before a dance passes itself: [_danceHold] normally, ZERO with
  /// animations off — where every other beat is instant too, and a deliberate
  /// pause would be the only thing on screen that waits.
  ///
  /// Even at zero the pass goes through a timer rather than firing inline: this
  /// runs from a controller/entry notification, and committing a move straight
  /// back into the controller from inside its own notify is exactly the
  /// re-entrancy the rest of this screen avoids.
  Duration get _dancePause =>
      widget.timings.enabled ? _danceHold : Duration.zero;

  /// Passes a HUMAN's danced turn automatically after [_dancePause].
  ///
  /// A dance offers no choice at all, so making the player tap "No moves — pass"
  /// was pure ceremony — and in hot-seat it was worse than ceremony: the device
  /// changed hands for a turn with nothing in it ("when two players play, and
  /// one has no possible moves, skip the turn"). The affordance STAYS on screen
  /// throughout the hold, so a player who has already read the position can tap
  /// it and skip the wait; either route commits the same [Move.none].
  ///
  /// The hold begins only once the mover's own roll has finished being presented
  /// — [DicePresenter.entryHeld] keeps `moveSide` null until then — so the dice are always
  /// legible before the turn goes.
  ///
  /// Applies wherever the danced side is locally human: vs-AI, hot-seat, and the
  /// local side of an online match alike. An AI's dance never reaches here (it
  /// has no pending move request).
  void _syncDancePass() {
    final pending = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    final moveSide = _dice.entryHeld(pending) ? null : pending;
    final dancing = moveSide != null && _entryControl.isDance;
    if (!dancing) {
      _cancelDancePass();
      return;
    }
    if (_dancePassTimer != null) return; // this dance is already being held
    final seq = ++_dancePassSeq;
    _dancePassTimer = Timer(_dancePause, () {
      if (!mounted || seq != _dancePassSeq) return;
      _dancePassTimer = null;
      // Re-check at fire time: a manual tap during the hold has already passed,
      // and the position has moved on.
      if (!_entryControl.isDance) return;
      _entryControl.pass();
    });
  }

  /// Drops any pending auto-pass (the dance ended, or the screen is going away),
  /// fencing a timer that has already been scheduled.
  void _cancelDancePass() {
    _dancePassTimer?.cancel();
    _dancePassTimer = null;
    _dancePassSeq++;
  }

  // --- "That checker cannot move" hint ---------------------------------------

  /// Surfaces the brief hint behind the reported "why am I not able to move the
  /// 7?" confusion: tapping one of your own checkers that no remaining die can
  /// play used to be a completely silent no-op, leaving the user to guess
  /// whether the tap registered at all.
  ///
  /// Deliberately NOT a floating [SnackBar]: one would cover the action bar (and
  /// outlive the route). This is an in-tree layer pinned to the BOTTOM EDGE of
  /// the board's slot — right above the score sheet, next to where the eye
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
  /// clears the fixed 64px bottom action bar, so
  /// Confirm / Roll stay visible and tappable — the hint is genuinely
  /// non-blocking, not just logically so. It deliberately does NOT clear the
  /// whole score sheet: a margin tall enough for that would put the tip halfway
  /// up the board.
  void _maybeShowDragHint() {
    if (_dragHintShown || _dragHintScheduled) return;
    if (!widget.interactionOptions.enableDrag) return;
    // The affordances the hint talks about appear only once the mover's own roll
    // has finished being presented, so the tip must not arrive a beat early.
    final pending = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    if (pending == null || _dice.entryHeld(pending)) return;
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

  /// Folds the CURRENT game's event log into each player's most recent roll, so
  /// every player keeps their OWN persistent dice pair (the fix for "the
  /// opponent dice is not perceivable"). The opening roll seeds the FIRST mover's
  /// pair (they play the opening dice); each later [RollEvent] overwrites its
  /// roller's pair. Both are `null` before a player's first roll (a blank dimmed
  /// die), and reset automatically when a new game replaces the event log.
  ///
  /// Folded once per log rather than once per rebuild (see [_refoldEvents]) —
  /// the board asks for it on every frame of a roll beat.
  (Dice?, Dice?) _persistentDice() {
    _refoldEvents();
    return _foldedDice;
  }

  // --- Tutor synchronisation -------------------------------------------------

  bool _doublingLegal(GameState s) =>
      !s.isCrawfordGame && (s.cube.owner == null || s.cube.owner == s.turn);

  // --- Hint panel ------------------------------------------------------------

  void _openHint() {
    widget.analytics.logTutorHintUsed(mode: widget.analyticsMode);
    final moveSide = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    final state =
        (moveSide != null ? _c.pendingMoveOf(moveSide).value : null) ?? _c.state;
    _hint.open(() => _tutor!.hintOrNone(state));
  }

  /// Stages [move] onto the interactive board and closes the hint panel. Only
  /// stages when a human move is actually pending — otherwise the board is not
  /// interactive and would ignore it, so we simply close.
  void _applyHint(Move move) {
    final moveSide = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    _hint.apply(move, stage: moveSide != null);
  }

  /// Tracks the acting side and — when [GameScreen.showPassDevice] is on —
  /// raises the pass-device overlay as a hot-seat human decision opens for a
  /// DIFFERENT actor than the last. Skipped for the very first human decision of
  /// the match (`_lastActor` null).
  ///
  /// With the setting OFF (the default), the hand-over still happens; it simply
  /// is not gated ("when playing with two persons, do not show the pass the
  /// device screen"). What signals it then depends on the layout: under
  /// [BoardOrientationMode.followActive] the board FLIPS to the new actor and
  /// that rotation is the cue, while in the tabletop layout ([_tabletopBars])
  /// nothing moves at all — the cue is the other edge's action bar lighting up,
  /// which is the point of sitting on opposite sides. The orientation update
  /// therefore lives on both branches (it is a no-op for the fixed modes, which
  /// ignore [_displayedWhiteAtBottom]); only [_passDevicePending] is
  /// conditional.
  void _updatePassDevice() {
    if (!_hotSeat || !_humanDecisionActive) return;
    final actor = _c.state.turn;
    if (_lastActor == null) {
      _lastActor = actor; // first turn: reveal immediately, no overlay
      _displayedWhiteAtBottom = actor == Player.white; // orient to first actor
    } else if (actor != _lastActor && !_passDevicePending) {
      // The cover is meaningless in the TABLETOP layout and actively wrong
      // there: it exists to hide a board being rotated while a device is handed
      // from one player to the other, and in tabletop the device is handed to
      // nobody and the board is never rotated. Both settings are independent, so
      // a user who had turned the cover on for the old flip paradigm would
      // otherwise be made to tap through a full-screen "Pass the device" between
      // every turn of a game where they are sitting opposite each other. The
      // setting itself is untouched and still governs the flip layout.
      if (widget.showPassDevice && !_tabletopBars) {
        _passDevicePending = true;
      } else {
        // No cover to hide behind: the flip happens in the open, and the actor
        // is adopted at once so the next change is detected against it.
        _lastActor = actor;
      }
      // Flip now. With the overlay on, this happens behind it and the new
      // orientation is revealed only when the user taps to continue.
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

  /// The header, scoped to [_observable] — the controller plus the local
  /// players' pending-decision notifiers, which between them are every input it
  /// reads. Held as one widget instance so the screen's own rebuilds (a
  /// roll-beat frame, a tap hint, an assessment landing) do not reach it.
  Widget _hudScope() => _hudWidget ??= ListenableBuilder(
        listenable: _observable,
        builder: (context, _) => GameHud(
          controller: _c,
          showScoring: widget.showScoring,
          opponentLabel: widget.opponentLabel,
          opponentDetail: widget.opponentDetail,
          onSurrender: _hasLocalHuman ? _openSurrender : null,
          // Tabletop moves Double to the players' own edges — the shared
          // header cannot tell which of the two people pressed it.
          showDouble: !_tabletopBars,
          onDoubled: _logCubeOffered,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = _c.state;
    final pendingSide = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    // The side whose move may be ENTERED right now: nobody while that side's own
    // roll is still being presented (see [DicePresenter.entryHeld]). Everything downstream —
    // the board's interactivity, the action bar's affordances — reads this, so
    // entry appears as one piece the moment the dice settle.
    final moveSide = _dice.entryHeld(pendingSide) ? null : pendingSide;
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
                _hudScope(),
                // TABLETOP hot-seat only: the second player's action bar, at
                // THEIR edge (directly under the header) and upside-down so it
                // reads right-way-up from across the device. Present for the
                // whole match — reserved height, live only on its owner's turn.
                if (_tabletopBars)
                  _topActionBar(
                      moveSide, whiteAtBottom ? Player.black : Player.white),
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
                        externalMove: _hint.stagedMove,
                        lastMove: _c.lastMove,
                        holdMoveAnimation: _dice.dicePresenting,
                        entryControl: _entryControl,
                        hopDuration: widget.timings.hop,
                        interHopDuration: widget.timings.interHop,
                        interactionOptions: widget.interactionOptions,
                        whiteDice: whiteDice,
                        blackDice: blackDice,
                        // A cubeless match paints NO cube on the bar, exactly as
                        // it shows no header chip and no Double button — the
                        // three cube surfaces are suppressed together.
                        showCube: !_c.cubeless,
                        diceOverride: _dice.rollBeat,
                        // Emphasis follows the PRESENTATION, never `state.turn`:
                        // the roller while a roll is live, the mover while a move
                        // is entered, nobody in between (both pairs dim).
                        activeDiceSide: _dice.activeDiceSide(moveSide),
                        // Tapping the dice is a second, on-board route to the
                        // Roll button — wired under exactly the condition that
                        // enables that button, and null otherwise so dice-area
                        // taps fall through to normal move entry.
                        onDiceTap: _canRoll(moveSide) ? _rollDice : null,
                        onMoveAnimation: _dice.onMoveAnimation,
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
                _scoreSheetScope(),
                // In the tabletop layout the bottom bar belongs to ONE player
                // (the side the board faces) and goes inert on the other's turn;
                // everywhere else it is the screen's only bar and serves whoever
                // is deciding.
                _bottomRegion(
                  moveSide,
                  _tabletopBars
                      ? (whiteAtBottom ? Player.white : Player.black)
                      : null,
                ),
              ],
            ),
            ..._buildModals(cubeSide, resignSide),
            if (_hint.isOpen)
              HintPanel(
                loading: _hint.isLoading,
                moves: _hint.moves,
                onClose: _hint.close,
                onApply: _applyHint,
              ),
          ],
        ),
      ),
    );
  }

  /// The single active modal layer, chosen by priority: match end, then game
  /// end, then the pass-device gate, then the cube/resign response dialogs, and
  /// last the user's own Surrender sheet — which [_onChange] closes outright the
  /// moment anything above it wants the screen, so it can never sit on top of a
  /// decision the match is waiting for.
  List<Widget> _buildModals(Player? cubeSide, Player? resignSide) {
    if (_c.matchOver) {
      return [
        matchEndDialog(
          winner: _c.match.winner,
          score: scoreLine(_c),
          savedToHistory: _canShowSummary,
          summaryAction: _canShowSummary ? _summaryAction('Match summary') : null,
          onDone: () => Navigator.of(context).maybePop(),
        ),
      ];
    }
    if (_c.awaitingNextGame) {
      return [
        gameEndDialog(
          result: _c.state.result!,
          score: scoreLine(_c),
          summaryAction: _canShowSummary ? _summaryAction('Analyze game') : null,
          onNextGame: _c.continueToNextGame,
        ),
      ];
    }
    if (_passDevicePending) {
      return [
        passDeviceOverlay(
          context,
          turn: _c.state.turn,
          onDismiss: _dismissPassDevice,
        ),
      ];
    }
    if (cubeSide != null) {
      // The decider is `state.turn`; the doubler is the opponent.
      final state = _c.pendingCubeOf(cubeSide).value!;
      final advice = _tutorSync.cubeResponseAdvice;
      return [
        cubeDialog(
          state: state,
          tutorLine: _tutor == null || advice == null
              ? ''
              : '\nTutor: ${advice.advice.shouldTake ? 'Take' : 'Pass'}',
          onPass: () => _answerCube(cubeSide, CubeAction.drop),
          onTake: () => _answerCube(cubeSide, CubeAction.take),
        ),
      ];
    }
    if (resignSide != null) {
      final (state, value) = _c.pendingResignOf(resignSide).value!;
      return [
        resignDialog(
          state: state,
          value: value,
          onDecline: () => _c.submitResignResponse(resignSide, false),
          onAccept: () => _c.submitResignResponse(resignSide, true),
        ),
      ];
    }
    if (_surrenderOpen) return [_surrenderDialog()];
    return const [];
  }

  // --- Surrender -------------------------------------------------------------

  /// Whether the user's Surrender sheet is open.
  bool _surrenderOpen = false;

  /// The side the open sheet BELONGS to — latched when it opens, `null` when it
  /// is closed. Every gate on the sheet is keyed to this rather than to the
  /// side-agnostic [MatchController.awaitingHumanTurn].
  ///
  /// Without it, hot-seat could resign for the wrong player. `awaitingHumanTurn`
  /// says only "some local human's gate is open", and since round 6 two things
  /// can hand the turn over UNDER an open sheet with nothing to interrupt it: a
  /// danced turn passing itself, and the pass-device cover being off by default.
  /// White would open the sheet mid-dance (values disabled), the auto-pass would
  /// advance to Black's gate, the values would light up — and White's tap booked
  /// the resignation against BLACK.
  ///
  /// Latched to the side that will actually be conceding: the sole local human
  /// where there is one (vs-AI, online — no other side is even possible there,
  /// so the sheet survives the opponent's turn as it always did), else the side
  /// on turn when the sheet opened (hot-seat, where "who is holding the device"
  /// is exactly what the turn tells us).
  Player? _surrenderFor;

  /// Whether any side of this match is driven by a local human — i.e. whether
  /// there is anybody here who COULD surrender. False only for an AI-vs-AI
  /// harness, where the ⋮ has nothing to offer.
  bool get _hasLocalHuman =>
      _c.isLocalHuman(Player.white) || _c.isLocalHuman(Player.black);

  /// Closes the Surrender sheet if a modal that outranks it has appeared (an
  /// incoming double, a resignation to answer, the end of the game or match, a
  /// hot-seat hand-over). Its own layer is last in [_buildModals], so without
  /// this it would simply be hidden and then pop back afterwards.
  void _closeSurrenderIfOutranked() {
    if (!_surrenderOpen) return;
    final outranked = _c.matchOver ||
        _c.awaitingNextGame ||
        _passDevicePending ||
        _humanSideWith((s) => _c.pendingCubeOf(s).value != null) != null ||
        _humanSideWith((s) => _c.pendingResignOf(s).value != null) != null;
    // HOT-SEAT WITH A ROTATING BOARD ONLY: the turn leaving the side that opened
    // this sheet means the device has changed hands, so the sheet belongs to
    // somebody who is no longer playing — it goes, rather than lingering for the
    // new player to tap by accident. Not applied when one side is the AI or a
    // remote opponent: the turn leaving you there is just them playing, nobody
    // else has touched the device, and the sheet is still yours when it comes
    // back.
    //
    // NOT applied in tabletop either, for the same reason it needs a side
    // chooser at all: the device changes hands at no point and both players are
    // present throughout, so a turn change is not somebody walking away. The
    // sheet there is bound to an explicitly NAMED side, so a turn change cannot
    // retarget it — the values simply go dark ([_surrenderReady] compares
    // against the latch, not against whoever is on turn). `_surrenderFor` is
    // also null while the chooser step is up, which this comparison would read
    // as "handed over" and close on the very next rebuild.
    //
    // Note the sheet is MODAL, so a side named while its own gate is shut
    // cannot then wait for that gate to open — nobody can play underneath it.
    // Cancelling is the only way on, which is a deliberate dead end rather than
    // a deadlock: it is what makes "concede for the player who is not on turn"
    // unreachable instead of merely discouraged.
    final handedOver =
        _hotSeat && !_tabletopBars && _c.state.turn != _surrenderFor;
    if (outranked || handedOver) _closeSurrender();
  }

  /// Whether the surrender flow must ASK who is conceding before it will offer
  /// any values — true in the tabletop layout, false everywhere else.
  ///
  /// Everywhere else the answer is not in doubt: either exactly one side is
  /// locally human (vs-AI, online, LAN — nobody else can concede), or the board
  /// rotates to face whoever is on turn, so the person holding the device is the
  /// one the turn names. In tabletop BOTH players are sitting at the device at
  /// once and neither of those inferences holds, which is precisely the hole:
  /// latching `state.turn` let the player who is NOT on turn open the ⋮ and
  /// immediately concede — at their opponent's own open gate, for up to three
  /// points. Naming the side is the only honest way to resolve it, so it becomes
  /// an explicit first step rather than a silent guess.
  bool get _surrenderNeedsSideChoice => _tabletopBars;

  /// Opens the sheet, latching the side it is for (see [_surrenderFor]) — or
  /// leaving it UNSET in tabletop, where [_surrenderSideChooser] asks first.
  void _openSurrender() {
    setState(() {
      _surrenderFor = _surrenderNeedsSideChoice ? null : _surrenderSide();
      _surrenderOpen = true;
    });
  }

  /// Closes the sheet and drops the latch. Callers already inside a rebuild path
  /// ([_closeSurrenderIfOutranked]) do not need their own [setState]; the ones
  /// reached from a tap wrap it.
  void _closeSurrender() {
    _surrenderOpen = false;
    _surrenderFor = null;
  }

  /// Which side a sheet opened right now would belong to. See [_surrenderFor].
  Player _surrenderSide() {
    final localWhite = _c.isLocalHuman(Player.white);
    final localBlack = _c.isLocalHuman(Player.black);
    if (localWhite != localBlack) {
      return localWhite ? Player.white : Player.black;
    }
    return _c.state.turn;
  }

  /// Whether the open sheet's value buttons may fire: a local gate is open AND
  /// it is the latched side's gate. Both halves are needed — see [_surrenderFor]
  /// for the hot-seat case the first half alone got wrong.
  bool get _surrenderReady =>
      _c.awaitingHumanTurn && _c.state.turn == _surrenderFor;

  /// The Surrender sheet: the three concession values with what each is worth,
  /// and one line saying what surrendering does.
  ///
  /// ## Why the entry point is always live but the ACTIONS are gated
  ///
  /// Resigning is legal only at your own pre-roll gate — both [MatchController]
  /// implementations of [MatchController.offerResign] throw a [StateError]
  /// otherwise (the local one has no open human-turn gate to complete; the
  /// online one has no legal action to send). The old UI expressed that by
  /// disabling the whole ⋮ off-gate, which made the only way to concede a game
  /// invisible at exactly the moments a losing player reaches for it — reported
  /// as "add surrender option", of a feature that had shipped long before.
  ///
  /// So the menu and this sheet are ALWAYS reachable, and the gate is expressed
  /// where it can be explained: the three value buttons are disabled until it is
  /// the latched side's own pre-roll gate ([_surrenderReady]), under a line
  /// saying when they will work. The alternative — queueing the intent and
  /// firing it at the next legal moment — was rejected as the less robust of the
  /// two: a queued resignation has to be invalidated against every transition
  /// that can happen while it waits (the game ending, the match ending, a new
  /// game starting, the opponent doubling), and getting any of them wrong
  /// concedes a game the player did not mean to concede.
  ///
  /// Nothing is lost by waiting: the sheet is declarative, so it rebuilds with
  /// the controller and the buttons light up as soon as the latched side's gate
  /// opens — during your own move or dance, that is this same turn. In hot-seat
  /// the sheet does not wait that long, because the turn changing hands closes
  /// it outright (see [_closeSurrenderIfOutranked]).
  Widget _surrenderDialog() {
    // Tabletop: nothing is on offer until the sheet knows who is conceding.
    if (_surrenderFor == null) return _surrenderSideChooser();
    final ready = _surrenderReady;
    final side = _surrenderFor!;
    return ModalCard(
      title: 'Surrender',
      message: _surrenderNeedsSideChoice
          // Name the side back to the user: on a shared device the sheet is the
          // only place that says WHO this concession costs.
          ? '${playerName(side)} concedes the current game.'
          : 'Concedes the current game.',
      footnote: ready
          ? null
          : _surrenderNeedsSideChoice
              ? "Available at the start of ${playerName(side)}'s turn"
              : 'Available at the start of your turn',
      actions: [
        CardAction(
          label: 'Cancel',
          onPressed: () => setState(_closeSurrender),
        ),
        for (final (value, label) in const [
          (ResignValue.single, 'Single (1)'),
          (ResignValue.gammon, 'Gammon (2)'),
          (ResignValue.backgammon, 'Backgammon (3)'),
        ])
          CardAction(
            label: label,
            onPressed: ready ? () => _surrender(value) : null,
          ),
      ],
    );
  }

  /// The tabletop-only first step: WHICH player is conceding. Until one is
  /// chosen there is no value button on screen at all, so there is no path from
  /// "open the ⋮" to a live concession without naming the side it costs.
  ///
  /// The chosen side is latched into [_surrenderFor], and [_surrenderReady] then
  /// holds the values shut until THAT side's own pre-roll gate — so a choice
  /// made during the opponent's turn simply waits rather than firing against
  /// whoever happens to be on turn.
  Widget _surrenderSideChooser() => ModalCard(
        title: 'Surrender',
        message: 'Who is conceding this game?',
        actions: [
          CardAction(
            label: 'Cancel',
            onPressed: () => setState(_closeSurrender),
          ),
          for (final side in [Player.white, Player.black])
            CardAction(
              label: playerName(side),
              onPressed: () => setState(() => _surrenderFor = side),
            ),
        ],
      );

  /// Offers the resignation and closes the sheet. Re-checks [_surrenderReady] AT
  /// INVOCATION for the same reason the header's Double re-checks its own
  /// condition: the sheet was built a frame ago and the match moves on
  /// underneath it. Re-checking the SIDE as well as the gate is what keeps a
  /// stale tap from booking the resignation against whoever is on turn now.
  void _surrender(ResignValue value) {
    final ready = _surrenderReady;
    setState(_closeSurrender);
    if (!ready) return;
    widget.analytics
        .logResignOffered(mode: widget.analyticsMode, value: value.name);
    _c.offerResign(value);
  }

  /// Answers a double, reporting the choice before submitting it — the cube
  /// value is read from the CURRENT state, which the submission is about to
  /// change.
  void _answerCube(Player side, CubeAction action) {
    widget.analytics.logCubeAnswered(
      mode: widget.analyticsMode,
      action: action.name,
      cubeValue: _c.state.cube.value,
    );
    _c.submitCubeResponse(side, action);
  }

  /// The post-game analysis link is offered whenever the match is PERSISTED
  /// ([GameScreen.persistedMatchId] set) — regardless of the live [GameScreen.tutor]
  /// setting. Analysis runs off the engine (the [AnalysisScreen] builds its own
  /// [TutorService] on demand), not the live tutor, so the tutor being off must
  /// not hide the entry point. Same gate for both end dialogs.
  bool get _canShowSummary => widget.persistedMatchId != null;

  CardAction _summaryAction(String label) => CardAction(
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
  Widget _bottomRegion(Player? moveSide, Player? owner) {
    final showCube =
        _tutor != null && _tutorSync.cubeAdvice != null && _c.awaitingHumanTurn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionBar(moveSide, owner: owner),
        // With no tutor there is never advice, so no slot is reserved at all —
        // the tutor is fixed for the life of the screen, so this is still a
        // constant height per screen.
        if (_tutor != null)
          SizedBox(
            key: const ValueKey('adviceLine'),
            height: _adviceLineHeight,
            child: showCube ? _cubeAdviceLine(_tutorSync.cubeAdvice!) : null,
          ),
      ],
    );
  }

  /// The TOP player's action bar (tabletop hot-seat only): the same contextual
  /// bar as [_actionBar], owned by [owner] — the side the board does NOT face —
  /// and turned upside-down with a [RotatedBox] so its labels and its button
  /// order read correctly to somebody sitting at the far edge of a device lying
  /// flat on the table.
  ///
  /// [RotatedBox] rotates at LAYOUT time (unlike [Transform.rotate]), so the
  /// child is laid out in the parent's box and hit-testing follows the rotation:
  /// the top player taps what they see. A half turn also leaves the box's
  /// dimensions unchanged, so this contributes exactly the bar's own 64px to the
  /// budget.
  ///
  /// It is present for the WHOLE match, not just its owner's turn: appearing and
  /// disappearing would resize the board's slot on every hand-over (F6). On the
  /// other player's turn it simply goes inert — see [_actionBar]'s `owner`.
  Widget _topActionBar(Player? moveSide, Player owner) => RotatedBox(
        quarterTurns: 2,
        child: _actionBar(
          moveSide,
          owner: owner,
          key: const ValueKey('topActionBar'),
        ),
      );

  /// The contextual action bar. Its height is ALWAYS 64px (a fixed
  /// [SizedBox]) so nothing below the board ever reflows as the phase changes —
  /// only the bar's *contents* swap:
  ///
  /// * entering a move → `[Undo] [Confirm]` (Confirm primary, right),
  /// * a dance → `[No moves — pass]` — which the turn no longer WAITS on: the
  ///   dance passes itself after a readable beat (see [_syncDancePass]), and
  ///   this stays tappable throughout so an impatient player can skip it,
  /// * the human pre-roll gate → `[Roll]`,
  /// * otherwise → a subtle status line (whose turn / thinking).
  ///
  /// The tutor Hint button sits far-left whenever a human move is open. Double
  /// and Resign are NOT here — they live in the header row, away from where
  /// thumbs rest, to avoid accidental taps.
  ///
  /// ## Why the buttons are density-compact
  ///
  /// The bar's children are sized to their NATURAL widths (a button never
  /// ellipsizes its own label), so the widest phase — Hint + Undo + Confirm, with
  /// the tutor on — overflowed the row by 11px on a 375pt phone (an iPhone SE).
  /// [VisualDensity.compact] on the three, plus a tighter Undo/Confirm gap, buys
  /// that back with ~30pt to spare; it is the same treatment the header's Double
  /// button already uses.
  /// [owner] — tabletop hot-seat only — is the player this bar belongs to. The
  /// bar then LIVES only while that player is the one deciding ([_actingSide]);
  /// on the other player's turn it keeps its shape and its 64px, but every
  /// control is disabled and the whole row is dimmed, so the pair reads as "your
  /// buttons / their buttons" rather than two live copies of the same controls.
  /// `null` (every non-tabletop screen) means the bar serves whoever is
  /// deciding, exactly as it always did.
  Widget _actionBar(
    Player? moveSide, {
    Player? owner,
    Key key = const ValueKey('actionBar'),
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Whether THIS bar's owner is the one who may act right now.
    final live = owner == null || _actingSide(moveSide) == owner;
    final showHint = _tutor != null && moveSide != null;
    final Widget content;
    if (moveSide != null && _entryControl.isDance) {
      content = Row(
        children: [
          if (showHint) _hintButton(live),
          const Spacer(),
          FilledButton(
            onPressed: live ? _entryControl.pass : null,
            style: _compactButton,
            child: const Text('No moves — pass'),
          ),
        ],
      );
    } else if (moveSide != null) {
      content = Row(
        children: [
          if (showHint) _hintButton(live),
          const Spacer(),
          TextButton(
            onPressed:
                live && _entryControl.canUndo ? _entryControl.undo : null,
            style: _compactButton,
            child: const Text('Undo'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed:
                live && _entryControl.canConfirm ? _entryControl.confirm : null,
            style: _compactButton,
            child: const Text('Confirm'),
          ),
        ],
      );
    } else if (_canRoll(moveSide)) {
      content = Row(
        children: [
          // TABLETOP ONLY: Double belongs to the player whose gate is open, so
          // in this layout it lives at their EDGE rather than in the shared
          // header — see [_ownsTheVerbs]. Far left, away from Roll: it is the
          // irreversible one of the two verbs on offer at this gate.
          if (_tabletopBars && !_c.cubeless)
            OutlinedButton.icon(
              onPressed: live && _doublingLegal(_c.state) ? _offerDouble : null,
              icon: const Icon(Icons.control_point_duplicate, size: 16),
              label: const Text('Double'),
              style: _compactButton,
            ),
          const Spacer(),
          FilledButton(
            onPressed: live ? _rollDice : null,
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
      key: key,
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        // Disabled Material buttons are already muted; the extra wash makes the
        // OTHER player's bar recede as a whole so a glance finds the live one.
        child: Opacity(opacity: live ? 1 : 0.45, child: content),
      ),
    );
  }

  /// The side whose decision is open right now — the mover while a move is being
  /// entered, else the player sitting at the pre-roll gate, else nobody. The
  /// single answer to "whose bar is live" in the tabletop layout.
  Player? _actingSide(Player? moveSide) =>
      moveSide ?? (_c.awaitingHumanTurn ? _c.state.turn : null);

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

  /// Offers a double from the acting player's own edge (tabletop only — every
  /// other layout doubles from the header's own button).
  ///
  /// Re-checks BOTH halves of the precondition at invocation, exactly as the
  /// header's copy does and for the same reason: the enabled-ness was baked into
  /// the last build, and a second press inside one frame lands after the first
  /// has already closed the gate or the opponent has taken the cube.
  void _offerDouble() {
    if (!_c.awaitingHumanTurn || !_doublingLegal(_c.state)) return;
    _logCubeOffered();
    _c.offerDouble();
  }

  /// The shared compact style for the action bar's buttons — see [_actionBar] for
  /// why the bar cannot afford default button density on a narrow phone.
  static final ButtonStyle _compactButton = ButtonStyle(
    visualDensity: VisualDensity.compact,
    padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12)),
  );

  Widget _hintButton([bool enabled = true]) => OutlinedButton.icon(
        onPressed: enabled ? _openHint : null,
        icon: const Icon(Icons.lightbulb_outline, size: 18),
        label: const Text('Hint'),
        style: _compactButton,
      );

  /// The idle-bar status line: what the game is waiting on.
  String _statusText() {
    // Your own roll is on screen being rolled: say so, rather than reporting
    // whatever the engine happens to be chewing on in the background.
    final presenting = _dice.presentingSide;
    if (presenting != null && _c.isLocalHuman(presenting)) return 'Rolling…';
    if (_c.isThinking) return 'Thinking…';
    if (_c.matchOver || _c.awaitingNextGame) return '';
    return "${playerName(_c.state.turn)}'s turn";
  }

  // --- Score sheet -----------------------------------------------------------

  /// The always-visible score sheet, scoped to [_sheetRevision] and held as ONE
  /// widget instance so the rows are rebuilt when a row actually changes and not
  /// when the dice tumble. The panel is rebuilt INSIDE the builder (not captured
  /// with the cached instance) so each revision hands it a freshly folded row
  /// list. See the rebuild-scoping note on [_sheetRevision].
  Widget _scoreSheetScope() => _scoreSheetWidget ??= ListenableBuilder(
        listenable: _sheetRevision,
        builder: (context, _) {
          final leftSide = _sheetLeftSide();
          return ScoreSheetPanel(
            rows: _scoreSheetRows(),
            leftSide: leftSide,
            columnLabels: _sheetColumnLabels(leftSide),
            assessments: _tutorSync.assessmentsByEventIndex,
            revealedBest: _tutorSync.revealedBest,
            onToggleBest: _toggleRevealedBest,
          );
        },
      );

  /// Toggles an assessed cell's "Best: …" line. The set lives with the tutor's
  /// other bookkeeping; the sheet is told its content moved.
  void _toggleRevealedBest(int eventIndex) {
    setState(() {
      if (_tutorSync.revealedBest.contains(eventIndex)) {
        _tutorSync.revealedBest.remove(eventIndex);
      } else {
        _tutorSync.revealedBest.add(eventIndex);
      }
    });
    _markSheetDirty();
  }

  /// Which side owns the sheet's LEFT column: the single locally-human side
  /// where there is one (so "You" reads first, as in the header score and the
  /// header's pip counts), else White — hot-seat, where both sides are local
  /// and neither is
  /// "you", and an AI-vs-AI harness with no local side at all.
  Player _sheetLeftSide() {
    final localWhite = _c.isLocalHuman(Player.white);
    final localBlack = _c.isLocalHuman(Player.black);
    if (localWhite == localBlack) return Player.white; // hot-seat / neither
    return localWhite ? Player.white : Player.black;
  }

  /// Names for the two columns: "You" / [GameScreen.opponentLabel] where exactly
  /// one side is local, else the neutral "W" / "B". Same rule as
  /// the header score and the header's detail row.
  (String, String) _sheetColumnLabels(Player leftSide) {
    final localWhite = _c.isLocalHuman(Player.white);
    final localBlack = _c.isLocalHuman(Player.black);
    if (localWhite == localBlack) {
      return leftSide == Player.white ? ('W', 'B') : ('B', 'W');
    }
    return ('You', widget.opponentLabel);
  }

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
