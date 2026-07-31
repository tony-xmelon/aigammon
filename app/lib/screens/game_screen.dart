import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';

import '../board/board_theme.dart';
import '../analytics/analytics_events.dart';
import '../analytics/app_analytics.dart';
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
/// ## The dice presentation (this screen owns it)
///
/// Every roll — the opening roll, the local player's, the opponent's — is
/// PRESENTED: the roller's pair tumbles through [AnimationTimings.diceFrames]
/// pseudo-random faces, settles on the real roll, and is held readable for a
/// settle pause before anything else moves. The screen owns the whole beat
/// ([_startRollBeat]) because only it sees the [RollEvent]s; the board is a pure
/// renderer, fed the tumbling faces as [BoardView.diceOverride] and the emphasis
/// as [BoardView.activeDiceSide].
///
/// Three things are derived from ONE piece of state — [_presentingSide], the
/// roller of the beat currently running (`null` between beats):
///
/// * **which pair is lit** — [_activeDiceSide]: the presenting roller while a
///   beat runs, else the side whose move is being entered, else NOBODY (both
///   pairs dim). Bright therefore means exactly "this roll is live", so the local
///   pair goes dim the instant a move is confirmed and stays dim until it is
///   rolled again — the reported "after my turn is over, my dice gets enabled
///   while the opponent moves". It is never derived from `state.turn`, which is
///   already back on the human while the opponent's roll is still tumbling (see
///   [BoardPainter.activeDiceSide]).
/// * **when the opponent's checkers may travel** — [_dicePresenting], handed to
///   the board as [BoardView.holdMoveAnimation]: a move that lands mid-beat is
///   queued and starts when the dice are readable.
/// * **when the local player may start entering** — [_entryHeld]: while your own
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
  /// see the two budgets documented on [_scoreSheetHeight].
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
  /// the fixed-height budget stay per-screen constant — see [_scoreSheetHeight].
  bool get _tabletopBars =>
      widget.tabletop &&
      _hotSeat &&
      widget.orientation != BoardOrientationMode.followActive;

  TutorService? get _tutor => widget.tutor;

  // --- Tutor state -----------------------------------------------------------

  /// Count of game events observed at the last change, so a fresh MoveEvent can
  /// be detected (and a new game — a shorter event list — resets the tutor).
  int _lastEventCount = 0;

  /// The game state the log has reached after its first [_lastEventCount]
  /// events — the running prefix [_syncAssessment] carries forward instead of
  /// replaying the log from scratch for every move it assesses.
  GameState? _assessPrefix;

  /// The event object the assessed log STARTS with, so a log that was replaced
  /// rather than appended to is detected even when it is no shorter than the
  /// old one. `Game.append` carries the same event objects forward, so an
  /// identity check on the first event is exactly "still the same log".
  GameEvent? _assessLogRoot;

  /// Points the assessment cursor at the log as it stands NOW: nothing before
  /// this point will be assessed, and the running prefix is the state the whole
  /// of it has reached.
  ///
  /// The three fields are seeded together and never apart — a count without the
  /// state that belongs to it would fold later events onto the wrong position.
  /// (They were `late` initialisers once, and that is exactly what went wrong:
  /// each initialised on its own first read, at a different point in the log.)
  void _seedAssessmentCursor() {
    final events = _c.game.events;
    _lastEventCount = events.length;
    _assessPrefix = _c.game.state;
    _assessLogRoot = events.isEmpty ? null : events.first;
  }

  /// Post-move assessments for EVERY move of the current game — both sides,
  /// human or not — keyed by the source [MoveEvent]'s index in the event log
  /// (the same index [ScoreCell.eventIndex] carries). Each entry enriches its
  /// cell in the score sheet with a mark dot + equity loss, which is why the
  /// opponent's moves are assessed too: the sheet's second column would
  /// otherwise be scoreless. Cleared when a new game begins.
  final Map<int, MoveAssessment> _assessmentsByEventIndex = {};

  /// Event indices whose score-sheet cell has its best-move line revealed
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

  /// Scroll controller for the always-present score sheet's row list, kept so it
  /// can auto-scroll to the newest row as live events append.
  final ScrollController _sheetScroll = ScrollController();

  /// The event count the score sheet was last auto-scrolled for. A fresh event
  /// re-pins the list to the bottom; unrelated rebuilds do not, so a user who
  /// scrolls up to re-read an earlier turn is left where they are until the next
  /// real event.
  int _sheetScrolledCount = -1;

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

  // --- Dice-roll beat --------------------------------------------------------

  /// Event cursor for the roll-beat detector, tracked SEPARATELY from the
  /// tutor's [_lastEventCount] so the two event-growth hooks advance
  /// independently.
  late int _lastRollEventCount = _c.game.events.length;

  /// The live roll beat: the ROLLER whose pair is tumbling, plus the cycling
  /// faces to paint on it. `null` when no beat is active (the board then shows
  /// both persisted pairs). Passed straight through to the [BoardView] as its
  /// `diceOverride`.
  ///
  /// The roller is stored HERE, taken from the [RollEvent] that started the
  /// beat, because it cannot be recovered from the state the beat is painted
  /// against: by the first override frame the turn may already have advanced
  /// past the roller (see [BoardView.diceOverride] and [AppliedMove]).
  ({Player roller, Dice faces})? _rollBeat;

  /// The current beat's frame timer, cancelled on a new beat / dispose.
  Timer? _rollBeatTimer;

  /// Monotonic guard so a superseded beat (a rapid second roll) cannot clear or
  /// advance a fresher one.
  int _rollBeatSeq = 0;

  /// Whether a roll is currently being PRESENTED — true from the moment a roll
  /// beat begins until its tumble frames AND the settle pause have elapsed.
  /// Handed to the [BoardView] as `holdMoveAnimation` so a move that lands during
  /// the presentation is deferred until the dice are readable.
  ///
  /// A [ValueNotifier] rather than plain state because the board LISTENS to it
  /// (the queued move starts on the flip, between rebuilds). Kept exactly in step
  /// with [_presentingSide]: `value == (_presentingSide != null)`.
  final ValueNotifier<bool> _dicePresenting = ValueNotifier<bool>(false);

  /// The roller whose dice are being presented right now (the beat's tumble
  /// frames plus its settle pause), or `null` when no presentation is running.
  ///
  /// The identity half of [_dicePresenting], and the state the whole presentation
  /// is derived from — see the class doc. Taken from the [RollEvent] that started
  /// the beat, never from `state.turn`, which may already have advanced past the
  /// roller (see [_rollBeat]).
  Player? _presentingSide;

  /// The side whose move is currently TRAVELLING on the board (its cosmetic
  /// animation), or `null` when nothing is animating. Reported by the
  /// [BoardView] through [BoardView.onMoveAnimation], because the board owns
  /// that timeline (its length depends on the hop count) and this screen must
  /// not duplicate it.
  ///
  /// Keeps the mover's dice lit for as long as their play is being presented:
  /// the roll settles, then the checkers move, and only when both are done does
  /// the pair go dim. Only ever set for a move that ANIMATES — a hand-entered
  /// local move is never replayed, so confirming still dims your pair at once.
  Player? _animatingSide;

  @override
  void initState() {
    super.initState();
    _seedAssessmentCursor();
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
    _rollBeatTimer?.cancel();
    _tapHintTimer?.cancel();
    _cancelDancePass();
    _observable.removeListener(_onChange);
    _dicePresenting.dispose();
    _stagedMove.dispose();
    _sheetRevision.dispose();
    _sheetScroll.dispose();
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
    _syncRollBeat();
    _syncDancePass();
    _syncTutor();
    _maybeShowDragHint();
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
  /// — [_entryHeld] keeps `moveSide` null until then — so the dice are always
  /// legible before the turn goes.
  ///
  /// Applies wherever the danced side is locally human: vs-AI, hot-seat, and the
  /// local side of an online match alike. An AI's dance never reaches here (it
  /// has no pending move request).
  void _syncDancePass() {
    final pending = _humanSideWith((s) => _c.pendingMoveOf(s).value != null);
    final moveSide = _entryHeld(pending) ? null : pending;
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
    if (pending == null || _entryHeld(pending)) return;
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

  // --- Dice-roll beat -------------------------------------------------------

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
  /// The beat is gated on [GameScreen.timings]: with the [AnimationTimings.off]
  /// preset (animation off — the widget-test default) or the dice-roll animation
  /// setting turned off, no beat ever runs and the board shows the real roll
  /// immediately. Called from [_onChange] before its [setState], so the first
  /// override frame it sets is painted by that rebuild.
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
      // Both the roller AND the settled faces come from the EVENT — never from
      // `_c.state` (whose turn/dice may already have moved on). The opening roll
      // is one die each, and both belong to the first mover (who plays them as
      // their opening move), exactly as `persistentDice` folds it.
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
  /// and the real roll shows through the roller's own persisted pair (see
  /// [_persistentDice], which has already folded this [RollEvent]). The faces are
  /// seeded off [realRoll] so the sequence is stable under test, and each cycling
  /// face differs from the real roll (the dice visibly tumble). No-op when
  /// animation is off. The first frame is set synchronously; the [_onChange]
  /// `setState` that follows paints it.
  ///
  /// While the beat runs — AND for the settle pause after the dice settle —
  /// [_presentingSide] is [roller] and [_dicePresenting] is `true`, which lights
  /// the roller's pair ([_activeDiceSide]), holds any queued move animation, and
  /// (for a local roller) withholds move entry ([_entryHeld]).
  ///
  /// The settle pause is [AnimationTimings.diceSettlePause] for a remote/AI roll
  /// and HALF that for a local one. The pause exists so a roll is readable before
  /// the checkers move; when the roller is you, you already know what you rolled
  /// and the wait is between you and your own move, where the full pause reads as
  /// the app being slow. Same beat, half the dwell.
  ///
  /// [roller] is the roll event's player, carried through every frame so the
  /// tumbling faces land on the pair that actually rolled them regardless of
  /// how far the turn has advanced meanwhile (see [_rollBeat]).
  void _startRollBeat(Player roller, Dice realRoll) {
    if (!widget.timings.diceBeatEnabled) return;
    _cancelRollBeat();
    final seq = ++_rollBeatSeq;
    final frameCount = widget.timings.diceFrames;
    final frameDuration = widget.timings.diceFrame;
    final settlePause = _c.isLocalHuman(roller)
        ? widget.timings.diceSettlePause ~/ 2
        : widget.timings.diceSettlePause;
    _beginPresenting(roller); // hold move animation + entry until dice settle
    _rollBeat = (roller: roller, faces: _beatFace(realRoll, 0));
    var frame = 0;
    void nextFrame() {
      if (!mounted || seq != _rollBeatSeq) return;
      frame++;
      if (frame >= frameCount) {
        // Dice settle to the real roll now; keep presenting for one more settle
        // pause so the roll is legible before anything moves.
        setState(() => _rollBeat = null);
        _rollBeatTimer = Timer(settlePause, () {
          if (!mounted || seq != _rollBeatSeq) return;
          _rollBeatTimer = null;
          // Release: a queued move animation begins, and a local roller's move
          // entry affordances appear. A rebuild is needed for the latter (the
          // notifier alone only wakes the board's own listener).
          setState(_endPresenting);
          // Entry just opened without a controller notification, so the two
          // things that wait for exactly these affordances have to be re-offered
          // here or they would sit out the whole move: the one-time drag/tap
          // tip, and the dance hold.
          //
          // The dance hold DID already start without this call — the board's
          // [BoardEntryController] defers its notify to the next frame, which
          // lands back in [_onChange] — but relying on another object's
          // scheduling for a turn to advance itself is emergent, not designed.
          // Arming it on the same line that opens entry makes the beat start
          // when the dice become readable, by construction. [_syncDancePass] is
          // idempotent while a hold is already pending, so the later
          // notification is a no-op.
          _syncDancePass();
          _maybeShowDragHint();
        });
        return;
      }
      _rollBeatTimer = Timer(frameDuration, nextFrame);
      setState(() =>
          _rollBeat = (roller: roller, faces: _beatFace(realRoll, frame)));
    }

    _rollBeatTimer = Timer(frameDuration, nextFrame);
  }

  /// Marks [roller]'s roll as being presented, keeping [_presentingSide] and
  /// [_dicePresenting] in step (the board listens to the notifier).
  void _beginPresenting(Player roller) {
    _presentingSide = roller;
    _dicePresenting.value = true;
  }

  /// Ends the presentation (no roll is live until the next one).
  void _endPresenting() {
    _presentingSide = null;
    _dicePresenting.value = false;
  }

  /// Cancels any live beat and clears the override (fencing pending callbacks by
  /// bumping [_rollBeatSeq]), and ends the presentation. Does not call
  /// [setState]; callers are already in a rebuild path (or disposing).
  void _cancelRollBeat() {
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
  /// 3. [_animatingSide], the side whose checkers are travelling, so an
  ///    opponent's roll stays readable for the whole of their play.
  ///
  /// With none of the three — the pre-roll gate, the moment after a confirm, a
  /// finished turn — nothing is live and both pairs dim.
  Player? _activeDiceSide(Player? moveSide) =>
      _presentingSide ?? moveSide ?? _animatingSide;

  /// Records the board's animation state (see [_animatingSide]).
  ///
  /// Reached from the board's own listener paths — including the one where
  /// releasing the presentation hold synchronously starts a queued move — all of
  /// which run outside a build, so a plain [setState] is safe here.
  void _onMoveAnimation(Player? player) {
    if (!mounted || _animatingSide == player) return;
    setState(() => _animatingSide = player);
  }

  /// Whether move entry is WITHHELD because the local mover's own dice are still
  /// being presented. The board is left non-interactive and the action bar shows
  /// no move affordances until the roll settles, so no hop can be staged against
  /// dice that are still tumbling.
  bool _entryHeld(Player? moveSide) =>
      moveSide != null && _presentingSide == moveSide;

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
  /// assessment for every newly-landed move, keeps the pre-roll cube advice in
  /// sync with the open gate, and clears everything on game end / a new game.
  void _syncTutor() {
    if (_tutor == null) return;
    _syncAssessment();
    _syncCubeAdvice();
    _syncCubeResponse();
  }

  /// Detects new [MoveEvent]s in the current game's event log and kicks off an
  /// async assessment for EACH of them, stored under the move's event index
  /// (see [_assessmentsByEventIndex]). A shorter event list means a new game
  /// began: reset and clear the accumulated assessments.
  ///
  /// Deliberately NOT gated on [MatchController.isLocalHuman]: the score sheet
  /// scores both columns, so the AI's / the remote player's / the other hot-seat
  /// side's moves are assessed on exactly the same terms as your own. The extra
  /// cost is one 0-ply `rankMoves` per opponent turn — the same call the tutor
  /// already makes for your own move, on the same engine isolate.
  void _syncAssessment() {
    final events = _c.game.events;
    final len = events.length;
    final root = events.isEmpty ? null : events.first;

    if (len < _lastEventCount || !identical(root, _assessLogRoot)) {
      // A new game started (the event log reset). Discard the old game's
      // assessments and abandon any in-flight ones, and re-seed the cursor on
      // the new log.
      _seedAssessmentCursor();
      _assessmentsByEventIndex.clear();
      _revealedBest.clear();
      _gameGeneration++;
      return;
    }
    if (len == _lastEventCount) return;

    // One or more events appended since last time: assess every move among
    // them. In practice the loop notifies per-append, so this is usually one.
    //
    // The state each move was played FROM is the running prefix, carried one
    // event at a time. It used to be `Game.replay(events.sublist(0, i))` — a
    // fold of the whole log, per move, which makes reviewing a game of n moves
    // cost O(n²) folds (and n list copies) for information one forward pass
    // already has. `Game.applyEvent` is the single step `replay` is built from,
    // so the state handed to the tutor is the same state, event for event.
    var before = _assessPrefix!;
    for (var i = _lastEventCount; i < len; i++) {
      final event = events[i];
      if (event is MoveEvent) _fireAssessment(i, before, event.move);
      before = Game.applyEvent(before, event);
    }
    _assessPrefix = before;
    _lastEventCount = len;
  }

  /// Assesses the [played] move (whose event sits at [eventIndex]) and, on
  /// resolution, files it under that index — unless the game has since reset
  /// (a [_gameGeneration] mismatch) or the screen unmounted.
  void _fireAssessment(int eventIndex, GameState before, Move played) {
    final gen = _gameGeneration;
    unawaited(_tutor!.assess(before, played).then((assessment) {
      if (!mounted || gen != _gameGeneration) return;
      setState(() => _assessmentsByEventIndex[eventIndex] = assessment);
      _markSheetDirty(); // a cell gained its mark dot and equity loss
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
    widget.analytics.logTutorHintUsed(mode: widget.analyticsMode);
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
        builder: (context, _) => _Hud(
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
    // roll is still being presented (see [_entryHeld]). Everything downstream —
    // the board's interactivity, the action bar's affordances — reads this, so
    // entry appears as one piece the moment the dice settle.
    final moveSide = _entryHeld(pendingSide) ? null : pendingSide;
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
                        externalMove: _stagedMove,
                        lastMove: _c.lastMove,
                        holdMoveAnimation: _dicePresenting,
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
                        diceOverride: _rollBeat,
                        // Emphasis follows the PRESENTATION, never `state.turn`:
                        // the roller while a roll is live, the mover while a move
                        // is entered, nobody in between (both pairs dim).
                        activeDiceSide: _activeDiceSide(moveSide),
                        // Tapping the dice is a second, on-board route to the
                        // Roll button — wired under exactly the condition that
                        // enables that button, and null otherwise so dice-area
                        // taps fall through to normal move entry.
                        onDiceTap: _canRoll(moveSide) ? _rollDice : null,
                        onMoveAnimation: _onMoveAnimation,
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
            if (_hintOpen) _hintPanel(),
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
    if (_c.matchOver) return [_matchEndDialog()];
    if (_c.awaitingNextGame) return [_gameEndDialog()];
    if (_passDevicePending) return [_passDeviceOverlay()];
    if (cubeSide != null) return [_cubeDialog(cubeSide)];
    if (resignSide != null) return [_resignDialog(resignSide)];
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
    return _ModalCard(
      title: 'Surrender',
      message: _surrenderNeedsSideChoice
          // Name the side back to the user: on a shared device the sheet is the
          // only place that says WHO this concession costs.
          ? '${_playerName(side)} concedes the current game.'
          : 'Concedes the current game.',
      footnote: ready
          ? null
          : _surrenderNeedsSideChoice
              ? "Available at the start of ${_playerName(side)}'s turn"
              : 'Available at the start of your turn',
      actions: [
        _CardAction(
          label: 'Cancel',
          onPressed: () => setState(_closeSurrender),
        ),
        for (final (value, label) in const [
          (ResignValue.single, 'Single (1)'),
          (ResignValue.gammon, 'Gammon (2)'),
          (ResignValue.backgammon, 'Backgammon (3)'),
        ])
          _CardAction(
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
  Widget _surrenderSideChooser() => _ModalCard(
        title: 'Surrender',
        message: 'Who is conceding this game?',
        actions: [
          _CardAction(
            label: 'Cancel',
            onPressed: () => setState(_closeSurrender),
          ),
          for (final side in [Player.white, Player.black])
            _CardAction(
              label: _playerName(side),
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
          onPressed: () => _answerCube(side, CubeAction.drop),
        ),
        _CardAction(
          label: 'Take',
          filled: true,
          onPressed: () => _answerCube(side, CubeAction.take),
        ),
      ],
    );
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
  Widget _bottomRegion(Player? moveSide, Player? owner) {
    final showCube =
        _tutor != null && _cubeAdvice != null && _c.awaitingHumanTurn;
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
            child: showCube ? _cubeAdviceLine(_cubeAdvice!) : null,
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
  /// other layout doubles from the header's button, [_Hud._offerDouble]).
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
    final presenting = _presentingSide;
    if (presenting != null && _c.isLocalHuman(presenting)) return 'Rolling…';
    if (_c.isThinking) return 'Thinking…';
    if (_c.matchOver || _c.awaitingNextGame) return '';
    return "${_playerName(_c.state.turn)}'s turn";
  }

  // --- Score sheet -----------------------------------------------------------

  /// Total height of the always-present score sheet. FIXED and unconditional,
  /// for the same reason as the action bar: the board FILLS the slot above it,
  /// so a panel that grew with its content (or came and went) would resize the
  /// board on every turn (F6).
  ///
  /// ## The screen's fixed-height budget
  ///
  /// Everything outside the board's slot is a constant for a given screen, so
  /// the board can never reflow mid-match:
  ///
  ///     header ([_Hud._hudHeight])       64  (40 + 18 + 2*3)
  ///     score sheet (this)              112
  ///     action bar                       64
  ///     tutor advice slot (tutor only)   28
  ///
  /// There are exactly TWO budgets, chosen once per screen and never changed
  /// afterwards, because every input to [_tabletopBars] (the mode, the
  /// orientation, the tabletop flag) is fixed for the life of the screen:
  ///
  ///     every mode but tabletop hot-seat   240 + 28 with a tutor
  ///     tabletop hot-seat                  304 + 28 with a tutor
  ///
  /// The extra 64 is the top player's action bar ([_topActionBar]), which is
  /// mounted for the whole match rather than only on its owner's turn — that is
  /// what keeps the per-screen budget CONSTANT, and it is why the inactive bar
  /// is dimmed-and-disabled rather than removed.
  ///
  /// Round 6 rebalanced it: the header grew from one row to two (+8) while the
  /// standalone 20px pip line was deleted outright, so the board's slot GAINED
  /// 12px. Inside the unchanged 112px sheet, dropping its duplicate context line
  /// moved 18px from chrome to move rows (~5 rows visible, up from ~3). On a
  /// 390x844 phone the board's slot is ~568px (aspect ~0.69, inside the
  /// [BoardView.minAspect] clamp).
  static const double _scoreSheetHeight = 112;

  /// Height of the sheet's single header line (the two column labels).
  static const double _sheetHeaderHeight = 16;

  /// Width of the turn-number gutter left of the two move columns, shared by the
  /// header's column labels and every row so the columns line up.
  static const double _sheetGutter = 22;

  /// Horizontal inset of the sheet's rows and header.
  static const double _sheetInset = 8;

  /// The ALWAYS-VISIBLE two-column score sheet, sitting between the board and
  /// the action bar. This replaced a 32px collapsed strip that expanded into a
  /// scrimmed overlay sheet — a design the reported feedback rejected outright
  /// ("move history still looks like a popup"). Nothing here opens or closes:
  /// the whole game so far is on screen, scrollable, at all times.
  ///
  /// Layout: a slim header (game number + match score, then the two column
  /// labels), a hairline, then a scrollable list of [buildScoreSheet] rows —
  /// numbered turn rows with one cell per side, and full-width span rows for the
  /// opening / cube / resignation events. Newest row at the BOTTOM, auto-pinned
  /// there as events append (see [_sheetScrolledCount] for how a manual
  /// scroll-up is respected).
  ///
  /// Scoped to [_sheetRevision] and held as one widget instance, so the rows
  /// are rebuilt when a row actually changes and not when the dice tumble. See
  /// the rebuild-scoping note on [_sheetRevision].
  Widget _scoreSheetScope() => _scoreSheetWidget ??= ListenableBuilder(
        listenable: _sheetRevision,
        builder: (context, _) => _scoreSheet(),
      );

  Widget _scoreSheet() {
    final scheme = Theme.of(context).colorScheme;
    final rows = _scoreSheetRows();
    final count = _c.game.events.length;
    // Re-pin to the newest row on any new event, but NOT on unrelated rebuilds
    // (a tutor assessment landing, the thinking dot flickering) — so a user who
    // scrolled up to re-read turn 3 stays there until the game moves on.
    if (count != _sheetScrolledCount) {
      _sheetScrolledCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_sheetScroll.hasClients) {
          _sheetScroll.jumpTo(_sheetScroll.position.maxScrollExtent);
        }
      });
    }
    final leftSide = _sheetLeftSide();
    return Material(
      color: scheme.surfaceContainerHighest,
      child: SizedBox(
        key: const ValueKey('scoreSheet'),
        height: _scoreSheetHeight,
        child: Column(
          children: [
            _sheetHeader(leftSide),
            Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        'No moves yet',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('scoreSheetList'),
                      controller: _sheetScroll,
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      itemCount: rows.length,
                      itemBuilder: (context, i) =>
                          _sheetRow(rows[i], i, leftSide),
                    ),
            ),
          ],
        ),
      ),
    );
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
  /// [_compactScore] and the header's detail row.
  (String, String) _sheetColumnLabels(Player leftSide) {
    final localWhite = _c.isLocalHuman(Player.white);
    final localBlack = _c.isLocalHuman(Player.black);
    if (localWhite == localBlack) {
      return leftSide == Player.white ? ('W', 'B') : ('B', 'W');
    }
    return ('You', widget.opponentLabel);
  }

  /// The sheet's header: just the two column labels, aligned over the move
  /// columns.
  ///
  /// It used to carry a game/score context line above them ("Game 2 · You 1–0
  /// AI · to 3") — a verbatim duplicate of the header's own score, which is the
  /// "duplicate info" the reported feedback objected to. That line is gone and
  /// the HEADER is now the only place summary information lives; the sheet keeps
  /// its overall height and spends the reclaimed 18px on move rows instead.
  Widget _sheetHeader(Player leftSide) {
    final scheme = Theme.of(context).colorScheme;
    final (left, right) = _sheetColumnLabels(leftSide);
    final labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
      letterSpacing: 0.3,
    );
    return SizedBox(
      key: const ValueKey('scoreSheetHeader'),
      height: _sheetHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _sheetInset),
        child: Row(
          children: [
            const SizedBox(width: _sheetGutter),
            Expanded(child: Text(left, style: labelStyle)),
            const SizedBox(width: 6),
            Expanded(child: Text(right, style: labelStyle)),
          ],
        ),
      ),
    );
  }

  /// One sheet row: a numbered two-cell turn row, or a full-width span row.
  Widget _sheetRow(ScoreSheetRow row, int index, Player leftSide) =>
      switch (row) {
        ScoreSheetTurn() => _sheetTurnRow(row, index, leftSide),
        ScoreSheetSpan() => _sheetSpanRow(row, index),
      };

  /// A numbered turn row: the turn number in the gutter, then one equal-width
  /// cell per side (the left one being [leftSide]'s).
  Widget _sheetTurnRow(ScoreSheetTurn row, int index, Player leftSide) {
    final scheme = Theme.of(context).colorScheme;
    final left = row.cellFor(leftSide);
    final right = row.cellFor(leftSide.opponent);
    return Padding(
      key: ValueKey('sheetRow$index'),
      padding: const EdgeInsets.symmetric(horizontal: _sheetInset, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _sheetGutter,
            child: Text(
              '${row.number}.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(child: _sheetCell(left, ValueKey('sheetLeft$index'))),
          const SizedBox(width: 6),
          Expanded(child: _sheetCell(right, ValueKey('sheetRight$index'))),
        ],
      ),
    );
  }

  /// One move cell: an optional mark dot, the dice + notation, and the equity
  /// loss — e.g. a red dot, "66: 22/16 16/10 13/…", "−0.130". The dot and the
  /// number carry the verdict, so the mark WORD ("Blunder") is dropped here:
  /// there is no room for it in a ~180pt column, and the ⓘ explainer covers what
  /// the number means.
  ///
  /// The loss sits in its OWN inflexible slot at the end of the row rather than
  /// inside the notation's text run. As one ellipsized span the two competed for
  /// the same line, and a four-hop doubles play ("66: 22/16 16/10 13/7 13/7")
  /// always won — truncating the cell to "… 13/7 ·…" and eating the very number
  /// the cell exists to show. Now the NOTATION gives way instead, and the score
  /// is always legible.
  ///
  /// An assessed cell is tappable: it toggles a second "Best: …" line beneath
  /// the notation (the sheet scrolls, so the extra line costs the board nothing).
  /// An empty cell (the side has not moved this turn) renders as blank space.
  Widget _sheetCell(ScoreCell? cell, Key key) {
    if (cell == null) return SizedBox(key: key);
    final scheme = Theme.of(context).colorScheme;
    final assessment = _assessmentsByEventIndex[cell.eventIndex];
    final revealed = _revealedBest.contains(cell.eventIndex);
    final base = TextStyle(
      fontSize: 12,
      color: scheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Color? markColor;
    String lossText = '';
    // A dance offers no choice, so grading it "best" is noise — no mark at all.
    if (assessment != null && assessment.ranked.isNotEmpty) {
      final (color, _) = _markStyle(assessment.mark);
      markColor = color;
      final loss = assessment.equityLoss;
      // A best play has no number worth printing; the word carries it (and the
      // dot is already green).
      lossText = loss >= 0.001 ? '−${loss.toStringAsFixed(3)}' : 'best';
    }

    final line = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (markColor != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(Icons.circle, size: 8, color: markColor),
          ),
          const SizedBox(width: 3),
        ],
        Expanded(
          child: Text(
            cell.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base,
          ),
        ),
        if (markColor != null) ...[
          const SizedBox(width: 4),
          Text(
            lossText,
            maxLines: 1,
            style: base.copyWith(
                color: markColor, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );

    if (assessment == null) return KeyedSubtree(key: key, child: line);

    return InkWell(
      key: key,
      onTap: () {
        setState(() {
          if (revealed) {
            _revealedBest.remove(cell.eventIndex);
          } else {
            _revealedBest.add(cell.eventIndex);
          }
        });
        _markSheetDirty();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line,
          if (revealed && assessment.best.checkerMoves.isNotEmpty)
            Text(
              'Best: ${assessment.best}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(
                  fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  /// A full-width span row (the opening, a cube action, a resignation): an
  /// actor-tinted dot in the gutter, then the line across BOTH columns.
  Widget _sheetSpanRow(ScoreSheetSpan row, int index) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('sheetSpan$index'),
      padding: const EdgeInsets.symmetric(horizontal: _sheetInset, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _sheetGutter,
            child: row.actor == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: _actorDot(row.actor),
                  ),
          ),
          Expanded(
            child: Text(
              row.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Mark → (colour, label): best/good green, dubious amber, error orange,
  /// blunder red. The label is unused by the score sheet's cells (the dot plus
  /// the loss number is all that fits) but kept as the single source of truth for
  /// the mark vocabulary.
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

/// Entries in the header overflow (⋮) menu — one, always available wherever
/// there is a local human at all.
///
/// The three per-value Resign entries it used to hold have collapsed into a
/// single "Surrender…" that opens a sheet where the values are named with what
/// they are worth; see [_GameScreenState._surrenderDialog] for why the entry no
/// longer disappears off-gate. The old "Game record" entry is GONE too: the
/// record is now the always-visible score sheet under the board.
enum _MenuAction { surrender }

// --- HUD (two rows) ----------------------------------------------------------

/// The header — the SINGLE home for every piece of match summary information,
/// in two compact rows of FIXED total height ([_hudHeight]).
///
/// * Row 1, the match context: "You 1–0 AI · to 3 · Game 2", an optional
///   Crawford badge and the cube chip, then (right) the thinking dot, the Double
///   button and the overflow (⋮) menu.
/// * Row 2, small and muted: who you are playing and the live pip counts —
///   "vs AI · Easy · Pips 129–78" (hot-seat "White vs Black · Pips …", online
///   "vs Opp · Pips …").
///
/// ## Why everything moved up here
///
/// The reported "duplicate info in the header and the line under the board. best
/// use the header for all summary info … and leave the bottom of the screen for
/// the move history and actions". The game number and match score used to be
/// printed a SECOND time on the score sheet's own context line, and the pip
/// counts had a standalone 20px line of their own between the sheet and the
/// action bar. Both are gone: the sheet is now nothing but move history (it
/// gained the context line's height, so more turns are visible within the same
/// 112px), and the space under the board belongs to history and actions alone.
///
/// ## Fixed height
///
/// Both rows are ALWAYS present — row 2 reserves its height even with nothing
/// worth saying — for the same reason the action bar is pinned to 64px: the
/// board fills the slot beneath this, so a header that grew or shrank mid-match
/// (a Crawford badge appearing, a name getting longer) would resize the board
/// (F6). What scales to fit is the TEXT: row 1's left group (context line +
/// badge + chip) and row 2's line each sit in their own [FittedBox], so they
/// shrink rather than overflow at any width or system text scale. Row 1's
/// right-hand controls — the thinking dot, Double, ⋮ — are outside that box and
/// keep their natural size, which is what leaves the left group its width.
///
/// Keeping Double/Surrender up here (rather than in the bottom bar) puts the
/// risky actions away from where thumbs rest.
class _Hud extends StatelessWidget {
  const _Hud({
    required this.controller,
    this.showScoring = true,
    this.opponentLabel = 'AI',
    this.opponentDetail,
    this.onSurrender,
    this.showDouble = true,
    this.onDoubled,
  });

  /// Height of row 1 (the match context plus the action controls).
  ///
  /// NOT the natural height of its tallest child: a [PopupMenuButton]'s
  /// [IconButton] asks for the 48px minimum touch target, and Double (compact
  /// density) for 32. 40 is a deliberate squeeze — the row's [BoxConstraints]
  /// clamp the icon button's 48 down, so it renders at 40 with its hit box
  /// filling the row rather than overflowing it. Anything less would start
  /// clipping Double.
  static const double _row1Height = 40;

  /// Height of row 2 (the muted opponent/pips line).
  ///
  /// 18, not the 16 it started as: the line's natural height at fontSize 12 is
  /// ~17, so 16 put every render through the [FittedBox] at ~94% — a permanent
  /// silent shrink, and one that got worse rather than better as the system text
  /// scale went up. At 18 the line renders unscaled at scale 1.0 and only starts
  /// scaling when the user has actually asked for larger text.
  static const double _row2Height = 18;

  /// Padding above row 1 and below row 2. The 2px row 2 gained came from here,
  /// so the header's total is unchanged (see [_hudHeight]).
  static const double _verticalPadding = 3;

  /// The header's FIXED total height — the top half of the screen's layout
  /// budget (see [_GameScreenState._scoreSheetHeight] for the whole table).
  static const double _hudHeight =
      _row1Height + _row2Height + 2 * _verticalPadding;

  final MatchController controller;

  /// Whether the running match score is shown (the settings `showScoring`).
  final bool showScoring;

  /// What the score calls the non-local side. See [GameScreen.opponentLabel].
  final String opponentLabel;

  /// An extra qualifier for the opponent on row 2 — the AI difficulty ("Easy")
  /// where the caller knows it. Null (hot-seat, online, a bare test harness)
  /// simply drops that segment; the row keeps its height either way.
  final String? opponentDetail;

  /// Opens the Surrender sheet. Null only when NO side is locally human (an
  /// AI-vs-AI harness), which is the one case where the ⋮ has nothing to offer
  /// and is therefore disabled.
  final VoidCallback? onSurrender;

  /// Whether the header carries the Double button.
  ///
  /// False in the TABLETOP layout only. This header sits at one edge of a device
  /// two people share, but the button acts for whoever is on turn — so the
  /// player who is NOT on turn could double on their opponent's behalf simply by
  /// reaching over. There the verb belongs to the per-edge action bars, which
  /// are owner-gated; everywhere else exactly one human can be on turn at all,
  /// so the shared header is unambiguous and keeps it.
  final bool showDouble;

  /// Called just before the header's Double is submitted, so the screen can
  /// report it. The header has no analytics sink of its own — it is a
  /// presentation widget — and the screen owns the one that is injected.
  final VoidCallback? onDoubled;

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

  /// Offers a double, re-checking AT INVOCATION the very condition the button's
  /// enabled-ness was built from.
  ///
  /// Same race, and the same reason, as [_GameScreenState._rollDice]: Double and
  /// Surrender share the pre-roll gate with Roll. The enabled-ness is baked into
  /// the last build, so two presses inside one frame both run the callback that
  /// frame captured while the match moves on underneath them.
  ///
  /// Unlike Roll, this re-checks BOTH halves of the precondition, because
  /// [MatchController.offerDouble] has two: the gate must be open AND doubling
  /// must be legal right now. Mirroring only the gate was not enough — a second
  /// press lands after the opponent has taken the cube, by which time the gate
  /// has reopened for the roll but the double is no longer on offer, and the
  /// throw comes from the legality check instead ("doubling is not legal now").
  /// Re-checking exactly `atGate && _doublingLegal` cannot drift from the
  /// button's own condition.
  void _offerDouble() {
    if (!controller.awaitingHumanTurn || !_doublingLegal) return;
    onDoubled?.call();
    controller.offerDouble();
  }

  /// Row 1's text: the match context — "You 1–0 AI · to 3 · Game 2", or just
  /// "Game 2" when the score is switched off.
  ///
  /// `gameNumber` is 0 until the first game starts, and the header is on screen
  /// from the first frame, so it reads "Game 1" rather than "Game 0".
  String _contextLine() {
    final number = controller.gameNumber < 1 ? 1 : controller.gameNumber;
    if (!showScoring) return 'Game $number';
    return '${_compactScore(controller, opponentLabel)} · Game $number';
  }

  /// Row 2's text: who is playing, and the live pip counts — "vs AI · Easy ·
  /// Pips 129–78".
  ///
  /// Named from the local player's point of view where there IS one (so the
  /// first pip count is always yours, matching the score's "You" first), and
  /// neutrally as "White vs Black" in hot-seat — where both sides are local and
  /// neither of them is "you" — and for a controller with no local side at all.
  /// Same rule as [_compactScore].
  ///
  /// Pip counts come from the COMMITTED board, so they step once per move rather
  /// than flickering through a half-entered turn.
  String _detailLine() {
    final board = controller.state.board;
    final white = board.pipCount(Player.white);
    final black = board.pipCount(Player.black);
    final localWhite = controller.isLocalHuman(Player.white);
    final localBlack = controller.isLocalHuman(Player.black);
    final soleLocal = localWhite != localBlack;
    final String who;
    final int mine;
    final int theirs;
    if (!soleLocal) {
      who = 'White vs Black';
      (mine, theirs) = (white, black);
    } else {
      who = 'vs $opponentLabel';
      (mine, theirs) = localWhite ? (white, black) : (black, white);
    }
    final detail = opponentDetail;
    return [
      who,
      if (detail != null && detail.isNotEmpty) detail,
      'Pips $mine–$theirs',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final cube = state.cube;
    final scheme = Theme.of(context).colorScheme;
    // The thinking dot reflects a genuine AI await, not a human's own decision
    // (the controller keeps `isThinking` true while it awaits a human move too).
    final showThinking = controller.isThinking && !_humanDeciding;
    // Double is only meaningful at the human's own pre-roll gate.
    final atGate = controller.awaitingHumanTurn;

    return Material(
      // Keyed so tests can scope an assertion to the HEADER.
      key: const ValueKey('hud'),
      color: scheme.surfaceContainerHighest,
      // Pinned rather than merely implied by the rows: the header's height is
      // half the screen's fixed layout budget, so it is stated once, here.
      child: SizedBox(
        height: _hudHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: _verticalPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey('hudContextRow'),
                height: _row1Height,
                child: Row(
                  children: [
                    // The left group (context line, Crawford badge, cube chip)
                    // takes ALL the space the right-hand controls leave. A bare
                    // `Flexible` + `Spacer` split the free space evenly instead,
                    // which truncated the longer line to "You 0–1 AI · t…" on a
                    // phone.
                    //
                    // The group scales to fit as ONE unit rather than flexing
                    // the text alone: a clipped context line tells the player
                    // nothing, whereas a slightly smaller row still reads — and
                    // the badge and chip beside it are RIGID, so a flexing text
                    // could not absorb them. In a 1-point match (Crawford from
                    // the first roll) that rigid pair plus the line overflowed
                    // the row by a hair on a 390pt phone. Scaling the whole
                    // group can never overflow, at any width or text scale.
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          // Unbounded inside the FittedBox: measured at natural
                          // size, then scaled — no child here may be Flexible.
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _contextLine(),
                              maxLines: 1,
                              softWrap: false,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            if (state.isCrawfordGame) ...[
                              const SizedBox(width: 8),
                              const _MiniBadge(
                                  icon: Icons.star, label: 'Crawford'),
                            ],
                            // The cube chip is hidden in a cubeless match.
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
                    // Omitted entirely in a cubeless match, and in the tabletop
                    // layout — where it is not the header's verb to offer, since
                    // the header is shared by two players and this button acts
                    // for whoever is on turn. It moves to the per-edge action
                    // bars instead (see [_GameScreenState._actionBar]).
                    if (!controller.cubeless && showDouble)
                      OutlinedButton.icon(
                        onPressed:
                            atGate && _doublingLegal ? _offerDouble : null,
                        icon:
                            const Icon(Icons.control_point_duplicate, size: 16),
                        label: const Text('Double'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                    // ALWAYS enabled wherever a local human exists. Gating the
                    // whole ⋮ on the pre-roll gate hid the only way to concede a
                    // game at precisely the moments a losing player looks for
                    // it, which read as the feature not existing ("add surrender
                    // option" — of something that had shipped long before). The
                    // SHEET now owns the legality question and explains it; see
                    // [_GameScreenState._surrenderDialog].
                    PopupMenuButton<_MenuAction>(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'More actions',
                      enabled: onSurrender != null,
                      onSelected: (action) {
                        switch (action) {
                          case _MenuAction.surrender:
                            onSurrender!();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: _MenuAction.surrender,
                          child: Text('Surrender…'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                key: const ValueKey('hudDetailRow'),
                height: _row2Height,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _detailLine(),
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
              ),
            ],
          ),
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
