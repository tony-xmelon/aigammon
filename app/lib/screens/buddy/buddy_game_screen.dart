import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../board/board_view.dart';
import '../../buddy/buddy_policy.dart';
import '../../buddy/buddy_session.dart';
import '../../buddy/camera_frame_source.dart';
import '../../buddy/speaker.dart';
import '../../data/match_repository.dart';
import '../../data/persistence_hooks.dart';
import '../../engine/engine_provider.dart';
import '../../game/game_controller.dart';
import '../../game/game_record.dart';
import '../../game/player_agent.dart';
import '../game/tap_when_disabled.dart';
import 'buddy_setup_screen.dart';
import 'calibration_screen.dart';

/// Whether this device can run Buddy Mode at all.
///
/// A camera propped over a board and a voice reading the play out loud — and
/// this app also runs on Windows and Linux, where it has neither. So the home
/// entry is HIDDEN there rather than shown and then refused: a mode that cannot
/// work is not a mode a user should be able to start.
///
/// Deliberately a second getter rather than a use of
/// [isBuddySpeechSupportedPlatform], which today has the same body. They are
/// different questions — "is there a voice" and "is there a camera to watch a
/// board with" — and one of them would move if `flutter_tts` ever grew a
/// desktop implementation. `defaultTargetPlatform` rather than `dart:io`, as
/// everywhere else in the app, so it is overridable in a widget test.
bool get isBuddyModeSupportedPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// The engine Buddy speaks through, behind a provider for the same reason the
/// camera is behind one.
///
/// `flutter_test` runs with `defaultTargetPlatform == TargetPlatform.android`,
/// so [BuddySpeaker.forPlatform] would build a real `FlutterTts` — and reach
/// for a plugin channel with nothing on the other end — in every widget test
/// that mounts this screen. The platform choice itself is unchanged and still
/// lives in `speaker.dart`.
final buddyTtsProvider = Provider<BuddyTts>(
  (ref) => isBuddySpeechSupportedPlatform
      ? FlutterTtsBuddyTts()
      : const SilentBuddyTts(),
);

/// Opens a Buddy match — the [BuddyLaunch] the setup screen is built around.
void openBuddyGame(
  BuildContext context,
  BuddySetup setup,
  CalibrationOutcome outcome,
) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BuddyGameScreen(setup: setup, outcome: outcome),
      ),
    );

/// Whether the user's Double is a legal verb right now.
///
/// **The sixth copy of `GameController`'s private `_doublingLegal`**, and the
/// house reason for copying it is `game_hud.dart`'s: a control cannot ask the
/// authority whether it would accept a verb without performing it, so the
/// button restates the rule and the controller stays the authority behind it.
/// A copy that drifts PERMISSIVE meets `GameController.offerDouble`'s throw; a
/// copy that drifts RESTRICTIVE meets nothing at all — the button simply goes
/// quiet and the user plays a worse match — so this one is pinned against the
/// controller's actual acceptance on the five states that separate them, in
/// the "the screen's copy of the doubling predicate" group of
/// `test/buddy/buddy_session_test.dart` — beside the session's own copy and
/// against the same authority, because the two are one rule read at two
/// different moments and a reader comparing them should not have to go
/// looking.
///
/// A top-level function rather than a method for exactly that reason: the pin
/// has to be able to put a real [GameController] into each of those five
/// states and ask this the same question the button asks.
///
/// [awaitingRoll] is [BuddySession.awaitingRoll] — the physical throw that has
/// been asked for and not answered — and NOT the session's phase. The phase is
/// what the session is doing and a readability outage overrides it; whether the
/// cube in the middle of a real table may be turned is not something a dark
/// frame gets a say in.
bool buddyDoubleAvailable({
  required GameController? controller,
  required bool awaitingRoll,
  required bool cubeless,
  required Player userSide,
}) {
  final c = controller;
  if (c == null || cubeless) return false;
  final s = c.state;
  return awaitingRoll &&
      c.awaitingHumanTurn &&
      s.turn == userSide &&
      s.phase == GamePhase.awaitingRoll &&
      !s.isCrawfordGame &&
      (s.cube.owner == null || s.cube.owner == s.turn);
}

/// A match against the engine, played on a real board.
///
/// ## What this screen is
///
/// **An orchestrator, and nothing else.** Every decision about the game belongs
/// to [BuddySession] and every sentence belongs to [OpponentPolicy]; what is
/// here is the wiring and the rendering — which slot shows what, which control
/// is live, and where a tap goes. There is no game logic in this file: the one
/// predicate that looks like some ([_canDouble]) is the digital screens' own
/// gating, copied for the same reason `game_hud.dart` copies it, and the
/// controller stays the authority behind it.
///
/// ## The slots, top to bottom
///
///  * **the readability light** — a colour, an icon and `Readability.message`
///    verbatim, because that sentence is written to be shown as it stands and
///    a light that says only "red" tells a user to start guessing;
///  * **the camera preview** — what Buddy is looking at, so a phone that got
///    nudged is visible before the light says so;
///  * **the belief mirror** — the authoritative position through the app's own
///    board painter, read-only except for tap-correct (see [_onMirrorMove]);
///  * **the prompt** — one sentence saying what Buddy is waiting for, and the
///    answers to whatever question it is asking (take/drop, which play);
///  * **the transcript** — every line Buddy said, "overlaid text first", so a
///    user in a loud room or with the volume down misses nothing;
///  * **the control bar** — the manual pad, the cube, and the two move-entry
///    verbs while a play is being tapped out.
///
/// Every band but the two pictures has a FIXED height, exactly as the digital
/// game screen's do: a match where the board resizes because a sentence got
/// longer is a match played on a moving target.
class BuddyGameScreen extends ConsumerStatefulWidget {
  const BuddyGameScreen({
    super.key,
    required this.setup,
    required this.outcome,
  });

  final BuddySetup setup;

  /// The learned board the calibration flow just handed over.
  final CalibrationOutcome outcome;

  @override
  ConsumerState<BuddyGameScreen> createState() => _BuddyGameScreenState();
}

/// The fixed heights. See the class doc for why they are fixed.
const double _kLightHeight = 64;
const double _kPromptHeight = 108;
const double _kTranscriptHeight = 92;
const double _kControlHeight = 64;

/// How much of the transcript is kept on screen.
///
/// The whole of it is scrollable and every line is in the tree — the cap is
/// against a match's worth of `Text` widgets being rebuilt several times a
/// second, not against the user seeing what was said. Twelve turns or so, and
/// the permanent record of the match is the game log in History.
const int _kTranscriptLines = 40;

class _BuddyGameScreenState extends ConsumerState<BuddyGameScreen> {
  late final BuddyCamera _camera = ref.read(buddyCameraProvider);
  late final BuddySpeaker _speaker;
  late final BuddySession _session;
  final BoardEntryController _entry = BoardEntryController();

  StreamSubscription<BuddyLine>? _transcript;
  StreamSubscription<ObservedFrame>? _frames;
  final List<BuddyLine> _lines = <BuddyLine>[];

  CameraOpening? _opening;
  Size? _frameSize;

  /// The outline the current calibration was learned from, so the next
  /// recalibration opens on the corners with them already where they were.
  late BoardHandles _handles = widget.outcome.handles;
  late BuddySeat _seat = widget.outcome.seat;

  /// Guards against a second calibration route being pushed on top of the
  /// first — the light's button and the app bar's are the same verb.
  bool _recalibrating = false;

  @override
  void initState() {
    super.initState();
    _speaker = BuddySpeaker(
      engine: ref.read(buddyTtsProvider),
      phrasing: widget.setup.phrasing,
    );
    final repo = ref.read(matchRepositoryProvider);
    final buddyType = 'ai:${widget.setup.difficulty.name}';
    final matchId = repo.startMatch(
      matchLength: widget.setup.matchLength,
      mode: 'buddy',
      whiteType: widget.setup.buddySide == Player.white ? buddyType : 'human',
      blackType: widget.setup.buddySide == Player.black ? buddyType : 'human',
    );
    _session = BuddySession(
      engine: AiAgent(ref.read(engineFacadeProvider), widget.setup.difficulty),
      buddySide: widget.setup.buddySide,
      seat: _seat,
      policy: OpponentPolicy(
        speaker: _speaker,
        buddySide: widget.setup.buddySide,
      ),
      frames: _camera.frames,
      matchLength: widget.setup.matchLength,
      cubeless: widget.setup.cubeless,
      persistence: RepositoryPersistence(repo, matchId),
    );
    // BEFORE the listener is attached: `useCalibration` notifies, and a
    // `setState` from `initState` is an error rather than a rebuild.
    _session.useCalibration(widget.outcome.vision);
    _session.addListener(_onChange);
    _entry.addListener(_onChange);
    _transcript = _speaker.transcript.listen(_onLine);
    _frames = _camera.frames.listen(_onFrame);
    unawaited(_open());
  }

  Future<void> _open() async {
    final opening = await _camera.open();
    if (!mounted) return;
    setState(() => _opening = opening);
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_transcript?.cancel());
    _session.removeListener(_onChange);
    _entry.removeListener(_onChange);
    _session.dispose();
    _entry.dispose();
    unawaited(_speaker.dispose());
    unawaited(_camera.close());
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _onLine(BuddyLine line) {
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > _kTranscriptLines) _lines.removeAt(0);
    });
  }

  /// The preview box is sized from the FRAME, so a rebuild is owed only when
  /// the frame's shape changes — which is once a session, not four times a
  /// second.
  void _onFrame(ObservedFrame f) {
    if (!mounted) return;
    final size = Size(f.frame.width.toDouble(), f.frame.height.toDouble());
    if (_frameSize == size) return;
    setState(() => _frameSize = size);
  }

  // --- what the session is waiting for -------------------------------------

  GameController? get _controller => _session.controller;

  /// The user's own home board at the bottom, which is how they are looking at
  /// the felt whichever side of it they are sitting on. (The point NUMBERS are
  /// the app's single White-based 1–24 frame either way — see
  /// `BuddyPhrasing.describePlay`, which explains why Buddy speaks that frame
  /// too.)
  bool get _whiteAtBottom => _session.userSide == Player.white;

  // --- the fallbacks -------------------------------------------------------

  /// A play the user tapped out on the mirror because the camera could not say
  /// what their hand did.
  ///
  /// **Through the session's own verb, never onto the board.** The mirror shows
  /// the authoritative state and has no way to change it; what a tap does is
  /// exactly what a recognised play does — [BuddySession.enterPlayManually]
  /// folds it as the user's, and the policy acknowledges it the same way.
  void _onMirrorMove(Move move) {
    if (!_session.awaitingPlay) return;
    _session.enterPlayManually(move);
  }

  /// Whether the throw being waited for is the one that starts a game.
  ///
  /// [BuddySession] asks the same question of the same two facts; it is asked
  /// again here because the pad's copy turns on it — see [_openDicePad].
  bool get _openingNeeded {
    final c = _controller;
    return c == null || c.awaitingNextGame;
  }

  /// The pad, and the two labels its rows carry.
  ///
  /// **The opening throw is the one roll whose ORDER matters**, and the pad is
  /// where that has to be said. `GameController` records an opening as
  /// `OpeningRollEvent(whiteDie: dice.die1, blackDie: dice.die2)` and the first
  /// turn follows from the comparison, so on that throw the two rows are two
  /// different people's dice and the pad names them by colour. On every other
  /// roll both faces belong to whoever is on turn and the order is nothing at
  /// all, which is what the second pair of labels says.
  Future<void> _openDicePad() async {
    final opening = _openingNeeded;
    final dice = await showModalBottomSheet<Dice>(
      context: context,
      builder: (_) => _DicePad(
        caption: opening
            ? 'One die each. Which face is whose is what decides who starts.'
            : 'The two faces on the table, in either order.',
        firstLabel: opening ? "White's die" : 'One die',
        secondLabel: opening ? "Black's die" : 'The other',
      ),
    );
    if (dice == null || !mounted) return;
    // Re-checked after the sheet, as every gated verb in the app is: a settled
    // frame may have read the roll off the felt while the sheet was open.
    if (!_session.awaitingRoll) return;
    _session.enterDiceManually(dice);
  }

  /// The user asked to fix the aim, or the light said the calibration is gone.
  ///
  /// One verb for both, because it is one thing: the session suspends without
  /// touching the game, the same guided flow runs with the corners where they
  /// were, and play picks up at the phase the outage interrupted.
  ///
  /// **Backing out of the flow leaves the session without a calibration**, and
  /// that is the right end for it rather than an oversight. The old vision is
  /// dropped the moment this is asked for, because a camera answering questions
  /// about a board somebody is re-aiming is worse than a camera saying nothing;
  /// so a user who changes their mind lands back here with the light red, the
  /// way in one tap away, the corners still seeded — and the manual pad still
  /// live, which is what keeps the match playable in the meantime.
  Future<void> _recalibrate() async {
    if (_recalibrating) return;
    _recalibrating = true;
    _session.recalibrate();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => CalibrationScreen(
          request: CalibrationRequest(
            userSide: _session.userSide,
            seat: _seat,
            seededHandles: _handles,
          ),
          onCalibrated: (outcome) {
            Navigator.of(routeContext).pop();
            _handles = outcome.handles;
            _seat = outcome.seat;
            // The seat travels with the calibration: a user who moved round
            // the table has a different near half, and that is what tells the
            // next game's two opening dice apart.
            _session.useCalibration(outcome.vision, seat: outcome.seat);
          },
        ),
      ),
    );
    _recalibrating = false;
  }

  // --- the cube ------------------------------------------------------------

  /// The digital screens' own gating, restated for the one control that has to
  /// mirror it — see `game_hud.dart`'s copy, which exists for the same reason.
  ///
  /// [BuddySession.offerDouble] throws when the controller refuses, and that
  /// throw is the backstop rather than the user experience: a dead button that
  /// says why is what the digital game does and what this does.
  bool get _canDouble => buddyDoubleAvailable(
        controller: _controller,
        awaitingRoll: _session.awaitingRoll,
        cubeless: _session.cubeless,
        userSide: _session.userSide,
      );

  /// One sentence explaining why a tap on the disabled Double just did nothing
  /// — the one thing the button itself cannot say. The two rule clauses are
  /// `game_hud.dart`'s, word for word, because they are the same two rules.
  ///
  /// Every clause here is a clause of [buddyDoubleAvailable], so no sentence
  /// can name a rule that is not the one refusing. That mattered: the gate used
  /// to include the session's PHASE, which a readability outage overrides, and
  /// the button then went dead behind "You can only double before rolling, on
  /// your turn." while the user was standing at exactly that gate on exactly
  /// their turn.
  String _doubleBlockedReason() {
    final c = _controller;
    if (c == null) {
      return 'There is no game to double in yet — the opening throw comes '
          'first.';
    }
    final s = c.state;
    if (!_session.awaitingRoll ||
        !c.awaitingHumanTurn ||
        s.turn != _session.userSide) {
      return 'You can only double before rolling, on your turn.';
    }
    if (s.isCrawfordGame) {
      return 'No doubling in the Crawford game — this single game decides '
          'the match.';
    }
    if (s.cube.owner != null && s.cube.owner != s.turn) {
      return 'Only the cube owner can double, and the other side owns it '
          'right now.';
    }
    return 'Doubling is not available right now.';
  }

  void _explain(String reason) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 104, left: 12, right: 12),
          content: Text(reason),
        ),
      );

  // --- the screen ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_contextLine()),
        actions: <Widget>[
          IconButton(
            tooltip: 'Fix the aim',
            icon: const Icon(Icons.center_focus_strong_outlined),
            onPressed: _session.phase == BuddyPhase.over ? null : _recalibrate,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _light(context),
            Expanded(flex: 5, child: _preview(context)),
            Expanded(flex: 4, child: _mirror(context)),
            _prompt(context),
            _transcriptBand(context),
            _controls(context),
          ],
        ),
      ),
    );
  }

  /// "You 1–0 Buddy · to 3 · Game 2", or the mode's name before there is a
  /// game to say anything about.
  String _contextLine() {
    final c = _controller;
    if (c == null) return 'Play with Buddy';
    final match = c.match;
    final (you, buddy) = _session.userSide == Player.white
        ? (match.whiteScore, match.blackScore)
        : (match.blackScore, match.whiteScore);
    final number = c.gameNumber < 1 ? 1 : c.gameNumber;
    return 'You $you–$buddy Buddy · to ${_session.matchLength} · Game $number';
  }

  /// The readability light: a colour, an icon, the cause in words, and — when
  /// the calibration itself is gone — the way back to a working one.
  ///
  /// **Never colour alone.** The icon and the sentence carry the same verdict,
  /// so the light works for a user who cannot tell green from amber and for one
  /// listening to a screen reader.
  Widget _light(BuildContext context) {
    final theme = Theme.of(context);
    final reading = _session.readability;
    final needsFix =
        _session.needsRecalibration || _session.phase == BuddyPhase.calibrating;
    final (Color tone, IconData icon) = switch (reading?.level) {
      null => (theme.colorScheme.onSurfaceVariant, Icons.visibility_outlined),
      ReadabilityLevel.green => (Colors.green.shade700, Icons.visibility),
      ReadabilityLevel.amber => (Colors.amber.shade800, Icons.back_hand_outlined),
      ReadabilityLevel.red => (Colors.red.shade700, Icons.visibility_off),
    };
    return SizedBox(
      height: _kLightHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Icon(icon, color: tone, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                // `Readability.message` is written to be shown as it stands —
                // the same contract `CalibrationResult.message` has.
                key: const Key('buddy-readability'),
                reading?.message ?? 'Buddy is looking at the board.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: tone),
              ),
            ),
            if (needsFix) ...<Widget>[
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _recalibrate,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Fix the aim'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// What the camera is looking at.
  ///
  /// Sized from the frame, as the calibration screen's is — but nothing is
  /// drawn over it here, so the preview↔frame mapping this mode has yet to
  /// verify on a phone (see `_CalibrationScreenState._preview`) costs this slot
  /// nothing: a stretched or mirrored preview is still a picture of the board,
  /// and no coordinate is read off it.
  Widget _preview(BuildContext context) {
    final opening = _opening;
    if (opening is CameraUnavailable) {
      return _Placeholder(
        icon: Icons.no_photography_outlined,
        message: '${opening.message}\n\nYou can still play the match: type '
            'each roll on the dice pad and tap your plays out on the board '
            'below.',
      );
    }
    final size = _frameSize;
    final aspect =
        size == null || size.height == 0 ? 4 / 3 : size.width / size.height;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRect(
          key: const Key('buddy-camera-preview'),
          child: _camera.preview(context),
        ),
      ),
    );
  }

  /// The position Buddy believes is on the felt, drawn by the app's own board
  /// painter.
  ///
  /// Read-only, with one exception: while the session is holding the user's
  /// turn open, the board accepts a tapped-out play and hands it to
  /// [_onMirrorMove]. That is the spec's tap-correct — the fallback for a play
  /// the camera could not identify — and it goes through the session's manual
  /// verb like every other answer.
  ///
  /// `interactive` is [BuddySession.awaitingPlay] rather than a phase, and that
  /// is load-bearing rather than tidy: [BoardView] rebuilds its move builder
  /// whenever `interactive` changes, so a phase that flips false for one amber
  /// frame throws away a correction the user is halfway through tapping —
  /// under a prompt that says "Nothing is lost."
  Widget _mirror(BuildContext context) {
    final c = _controller;
    if (c == null) {
      return const _Placeholder(
        icon: Icons.casino_outlined,
        message: 'Buddy is waiting for the throw that starts the match.',
      );
    }
    final (whiteDice, blackDice) = persistentDice(c.game.events);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: BoardView(
        state: c.state,
        interactive: _session.awaitingPlay,
        onMoveCommitted: _onMirrorMove,
        whiteAtBottom: _whiteAtBottom,
        entryControl: _entry,
        whiteDice: whiteDice,
        blackDice: blackDice,
        activeDiceSide: c.state.turn,
        showCube: !_session.cubeless,
      ),
    );
  }

  /// One sentence saying what Buddy is waiting for, and the buttons that answer
  /// whatever it is asking.
  Widget _prompt(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _kPromptHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  key: const Key('buddy-prompt'),
                  _promptLine(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            SizedBox(height: 40, child: _promptActions(context)),
          ],
        ),
      ),
    );
  }

  String _promptLine() {
    final c = _controller;
    if (_session.needsRecalibration ||
        _session.phase == BuddyPhase.calibrating) {
      return 'Buddy has lost the board. Fix the aim and the match carries on '
          'where it stopped.';
    }
    return switch (_session.phase) {
      // A pause is perception's, not the user's: whatever the user was already
      // being asked is still being asked, and its buttons are still under this
      // sentence (see [_promptActions]). "Waiting for a picture" over a live
      // Take/Drop would be the screen contradicting itself, so the outage line
      // is the FALLBACK — what is left to say when the only thing outstanding
      // is something the camera has to answer.
      BuddyPhase.paused => _userQuestionLine() ??
          'Waiting for a picture Buddy can read. Nothing is lost.',
      BuddyPhase.awaitingDice when _session.needsManualDice =>
        'Buddy cannot find the dice. Type the roll instead.',
      BuddyPhase.awaitingDice => _throwLine(c),
      BuddyPhase.awaitingPlay => _kPlayLine,
      BuddyPhase.objecting => _objectionLine,
      BuddyPhase.disambiguating => _kCandidateLine,
      BuddyPhase.verifyingPlacement =>
        "Make Buddy's move on the board, then Buddy will carry on.",
      BuddyPhase.awaitingCubeAnswer => _kCubeLine,
      BuddyPhase.thinking => 'Buddy is thinking.',
      BuddyPhase.over => _outcomeLine(),
      BuddyPhase.calibrating => 'Waiting for a calibration.',
    };
  }

  /// The sentence for whichever question the USER has open, or null when the
  /// only thing outstanding is something perception has to answer.
  ///
  /// Read from the session's open questions rather than from its phase, which
  /// is what lets the paused line fall through to it. The order is the
  /// scheduler's own priority in `BuddySession._derive`.
  String? _userQuestionLine() {
    if (_session.awaitingCubeAnswer) return _kCubeLine;
    if (_session.candidates.isNotEmpty) return _kCandidateLine;
    if (_session.awaitingPlay) {
      return _session.objection == null ? _kPlayLine : _objectionLine;
    }
    return null;
  }

  static const String _kPlayLine =
      'Make your play on the board. Tap it out here if Buddy does not see it.';
  static const String _kCandidateLine = 'Which play was it?';
  static const String _kCubeLine = 'Buddy doubles. Take or drop?';

  /// Word for word what Buddy just said out loud. The transcript and the
  /// prompt are two channels for one sentence, not two sentences.
  String get _objectionLine => _session.objection == null
      ? "That isn't a legal play."
      : "That isn't a legal play. ${_session.objection}";

  /// Whose dice are on the table. A hand throws for both sides in this mode,
  /// so which pair to pick up is a real question and the screen answers it.
  String _throwLine(GameController? c) {
    if (_openingNeeded) return 'Throw the opening dice — one die each.';
    return c!.state.turn == _session.userSide
        ? 'Throw your dice.'
        : "Throw Buddy's dice.";
  }

  String _outcomeLine() {
    final winner = _controller?.match.winner;
    if (winner == null) return 'The match is over.';
    return winner == _session.userSide
        ? 'You win the match.'
        : 'Buddy wins the match.';
  }

  /// The buttons that answer whatever the prompt is asking.
  ///
  /// **Gated on the session's open QUESTIONS, never on its phase**, and that is
  /// the whole of what keeps a match playable through a readability outage. An
  /// outage parks the phase in [BuddyPhase.paused] so that perception stops
  /// claiming things about a picture it cannot read — a suppression of what the
  /// CAMERA may say, which is not the same thing as a suppression of what the
  /// user may do. A cube on the table stays takeable and two candidate plays
  /// stay separable, exactly as the manual dice pad stays live (see
  /// [BuddySession.awaitingRoll], which shipped this decision first).
  ///
  /// The order is the scheduler's own priority in `BuddySession._derive`, so
  /// the slot can never show an answer to a question that has been overtaken.
  Widget _promptActions(BuildContext context) {
    if (_session.awaitingCubeAnswer) {
      // Take and DROP, not the digital dialog's Take and Pass: Buddy has just
      // said "take or drop?" out loud, and the buttons under a spoken question
      // have to be the words in it.
      return Row(
        children: <Widget>[
          Expanded(
            child: OutlinedButton(
              onPressed: () => _session.answerDouble(CubeAction.drop),
              child: const Text('Drop'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: () => _session.answerDouble(CubeAction.take),
              child: const Text('Take'),
            ),
          ),
        ],
      );
    }
    if (_session.candidates.isNotEmpty) {
      return ListView(
        key: const Key('buddy-candidates'),
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          for (final move in _session.candidates) ...<Widget>[
            OutlinedButton(
              onPressed: () => _session.pickCandidate(move),
              child: Text(_speaker.phrasing.describePlay(move).text),
            ),
            const SizedBox(width: 8),
          ],
        ],
      );
    }
    if (_session.phase == BuddyPhase.over) {
      return Row(
        children: <Widget>[
          Expanded(
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  /// Everything Buddy said, oldest at the top and the newest already in view.
  ///
  /// The spec's "overlaid text first": every spoken line is mirrored here
  /// whether or not the phone has a voice, whether or not the volume is up, and
  /// whether or not the room is loud enough to hear one.
  Widget _transcriptBand(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _kTranscriptHeight,
      child: Semantics(
        label: 'What Buddy said',
        child: SingleChildScrollView(
          // The scroll opens at the END of the content, so the newest line is
          // the one on screen without a controller animating anything into
          // place.
          reverse: true,
          child: Padding(
            key: const Key('buddy-transcript'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final (i, line) in _lines.indexed)
                  Semantics(
                    // Only the newest, or a screen reader would re-read the
                    // whole match every time Buddy opened its mouth.
                    liveRegion: i == _lines.length - 1,
                    child: Text(
                      line.text,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The bar that is always there: the manual pad and the cube, or — while a
  /// play is being tapped out on the mirror — that entry's two verbs.
  ///
  /// The swap costs nothing, and that is why it is a swap: neither the pad nor
  /// the cube is a legal verb during the user's own move (no roll is open and
  /// doubling is over for the turn), so the two buttons it replaces are two
  /// disabled buttons.
  Widget _controls(BuildContext context) {
    final buttons = _entry.active
        ? <Widget>[
            OutlinedButton(
              onPressed: _entry.canUndo ? _entry.undo : null,
              child: const Text('Undo'),
            ),
            FilledButton(
              onPressed: _entry.canConfirm ? _entry.confirm : null,
              child: const Text('Confirm'),
            ),
          ]
        : <Widget>[
            FilledButton.icon(
              key: const Key('buddy-dice-button'),
              onPressed: _session.awaitingRoll ? _openDicePad : null,
              icon: const Icon(Icons.casino_outlined, size: 18),
              label: const Text('Dice'),
            ),
            // Suppressed with the rest of the cube in a cubeless match, exactly
            // as the digital screens suppress their three cube surfaces
            // together.
            if (!_session.cubeless)
              TapWhenDisabled(
                onDisabledTap: () => _explain(_doubleBlockedReason()),
                child: OutlinedButton.icon(
                  onPressed: _canDouble ? _offerDouble : null,
                  icon: const Icon(Icons.control_point_duplicate, size: 18),
                  label: const Text('Double'),
                ),
              ),
          ];
    return SizedBox(
      height: _kControlHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: <Widget>[
            for (final (i, button) in buttons.indexed) ...<Widget>[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: button),
            ],
          ],
        ),
      ),
    );
  }

  /// Re-checks the gate at invocation, as every copy of this verb in the app
  /// does: the enabled-ness was baked into the last build, and a settled frame
  /// can have moved the game on since.
  void _offerDouble() {
    if (!_canDouble) return;
    _session.offerDouble();
  }
}

/// A slot with nothing in it yet, saying what it is waiting for.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 32, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// The manual dice pad: two faces and a deliberate Enter.
///
/// **Three taps rather than two**, and the extra one is on purpose. What this
/// returns goes straight into the authoritative game state and cannot be taken
/// back — a roll is not a selection, it is a fact about a table — so the pad
/// asks for a confirmation rather than folding the moment a second face is
/// touched.
///
/// The two rows are labelled by the caller, because what they mean depends on
/// which throw this is; see [_BuddyGameScreenState._openDicePad].
class _DicePad extends StatefulWidget {
  const _DicePad({
    required this.caption,
    required this.firstLabel,
    required this.secondLabel,
  });

  final String caption;

  /// What the first row is, and therefore what `Dice.die1` will be.
  final String firstLabel;
  final String secondLabel;

  @override
  State<_DicePad> createState() => _DicePadState();
}

class _DicePadState extends State<_DicePad> {
  int? _a;
  int? _b;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('What did you throw?', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(widget.caption, style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            _row(widget.firstLabel, 'a', _a, (v) => setState(() => _a = v)),
            const SizedBox(height: 12),
            _row(widget.secondLabel, 'b', _b, (v) => setState(() => _b = v)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _a == null || _b == null
                  ? null
                  : () => Navigator.of(context).pop(Dice(_a!, _b!)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('Enter roll'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String die, int? chosen, ValueChanged<int> onPick) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              for (var face = 1; face <= 6; face++) ...<Widget>[
                if (face > 1) const SizedBox(width: 8),
                Expanded(
                  child: chosen == face
                      ? FilledButton(
                          key: Key('buddy-die-$die-$face'),
                          onPressed: () => onPick(face),
                          child: Text('$face'),
                        )
                      : OutlinedButton(
                          key: Key('buddy-die-$die-$face'),
                          onPressed: () => onPick(face),
                          child: Text('$face'),
                        ),
                ),
              ],
            ],
          ),
        ],
      );
}
