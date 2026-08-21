import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:board_vision/board_vision.dart';
import 'package:flutter/foundation.dart';

import '../data/persistence_hooks.dart';
import '../game/game_controller.dart';
import '../game/player_agent.dart';
import 'buddy_dice_roller.dart';
import 'buddy_policy.dart';
import 'camera_frame_source.dart';
import 'perception_human_agent.dart';

/// Unreadable dice frames in a row before the manual pad is offered.
///
/// One frame that cannot find two settled dice is the ordinary case — a hand
/// is still over them, one is against the bar, the throw has not finished. Two
/// is a pattern, and the pad is one tap away by design (the Phase-1 gate made
/// tap-to-enter the shipping dice path, not a fallback). Deliberately small:
/// the cost of offering the pad early is a button nobody presses, and the cost
/// of offering it late is a user staring at a phone that is not answering.
const int kDiceReadAttempts = 2;

/// Failed placement checks before the on-screen belief mirror is raised.
///
/// The spec: "Repetition escalates to the on-screen belief mirror with the
/// discrepancy highlighted." Three is the smallest number that is a repetition
/// rather than a slow hand — a settled frame arrives roughly every
/// `kQuietFramesRequired` observation intervals, so three of them is a couple
/// of seconds of a board that still does not match what Buddy asked for.
const int kPlacementAttemptsBeforeMirror = 3;

/// What the session is doing, and therefore which question the next settled
/// frame gets asked.
///
/// The scheduler the spec asks for is exactly this enum: perception is never
/// asked an open question, so "which query runs next" is not a decision — it
/// is a reading of where the game has got to.
enum BuddyPhase {
  /// No usable calibration: either the session has not started yet, or one
  /// died mid-match and the guided corner flow has the camera. **The game
  /// state is untouched throughout** — this is a suspension, not a rollback.
  calibrating,

  /// Somebody has to throw. `readDice` runs on every settled frame until it
  /// answers or the manual pad takes over. Covers the opening throw too.
  awaitingDice,

  /// The user's play is being waited for. `matchLegalPlay` runs against the
  /// enumerated legal plays and the settled frame from before the hand moved.
  awaitingPlay,

  /// Two legal plays leave the same position and the picture cannot separate
  /// them. [BuddySession.candidates] holds them; [BuddySession.pickCandidate]
  /// resolves it.
  disambiguating,

  /// The board changed into something that is not a legal play. Nothing is
  /// folded, nothing is rolled back, and the query keeps running until the
  /// board becomes a play.
  objecting,

  /// Buddy dictated a move and the man has not been seen to arrive yet.
  /// `verifyExpectedBoard` runs against the regions the play touched.
  verifyingPlacement,

  /// Buddy doubled by voice and the user has not tapped take or drop.
  awaitingCubeAnswer,

  /// Something that is not the user is thinking: the engine picking a move,
  /// the controller stepping. No perception query is pending.
  thinking,

  /// The light is not green. Every answer is suppressed and the phase to
  /// return to is remembered.
  paused,

  /// The match is decided.
  over,
}

/// One Buddy match, from calibration to the last point.
///
/// ## What this is, and what it is not
///
/// It is a **state machine over the existing `GameController`**, and it forks
/// no game logic whatsoever. The authoritative position, the legal-move list,
/// the cube, the score and the persistence hooks are all the ones digital play
/// uses; what this adds is the three things a physical board needs and a
/// screen does not:
///
///  * **a scheduler** — which of `board_vision`'s state-primed questions the
///    next settled frame is asked, derived from the controller's phase;
///  * **a belief** — the authoritative state plus whatever has been observed
///    and not yet folded into it (a play mid-identification, a dictated move
///    the hand has not made yet);
///  * **the routing** — readability outages that suspend without touching the
///    game, recalibration, objections, and the fallbacks that make every
///    perceptual input optional.
///
/// The three collaborators stay separable, which is the spec's seam: the
/// **policy speaks**, the **session decides**, **perception answers**. A policy
/// is handed events and can reach neither the camera nor the game; perception
/// is asked questions and is told nothing.
///
/// ## Everything is injected
///
/// Vision, the frame stream, the policy (and through it the speaker and its
/// TTS engine), the engine agent and the persistence hook all arrive from
/// outside, so the whole of this file runs in a plain `flutter test` on a
/// desktop with no camera, no microphone and no phone. That is not a testing
/// convenience — it is the same discipline that keeps `board_vision` pure
/// Dart, and it is why the session's own behaviour can be pinned down while
/// the perception under it is still being measured against the corpus.
class BuddySession extends ChangeNotifier {
  BuddySession({
    required PlayerAgent engine,
    required this.buddySide,
    required this.policy,
    required Stream<ObservedFrame> frames,
    required this.matchLength,
    this.cubeless = false,
    this.persistence = const NoopPersistence(),
  }) {
    _humanAgent = PerceptionHumanAgent();
    _buddyAgent = BuddyOpponentAgent(engine, onCubeResponse: _onBuddyCube);
    _frames = frames.listen(_onFrame);
  }

  /// The side the engine plays. The other side is the user's, and the user
  /// physically executes BOTH.
  final Player buddySide;

  final BuddyPolicy policy;
  final int matchLength;
  final bool cubeless;
  final MatchPersistence persistence;

  late final PerceptionHumanAgent _humanAgent;
  late final BuddyOpponentAgent _buddyAgent;
  late final StreamSubscription<ObservedFrame> _frames;
  final BuddyDiceRoller _roller = BuddyDiceRoller();

  BoardVision? _vision;
  GameController? _controller;

  BuddyPhase _phase = BuddyPhase.calibrating;
  BuddyPhase? _pausedFrom;
  Readability? _readability;
  bool _needsRecalibration = false;
  bool _needsManualDice = false;
  bool _needsBeliefMirror = false;
  List<Move> _candidates = const <Move>[];
  String? _objection;

  /// The settled frame the board was last known to hold the authoritative
  /// position in — the "before" half of every `matchLegalPlay`.
  ///
  /// Dropped whenever the calibration is invalidated, because a difference
  /// across two epochs is noise shaped like a play; `board_vision` says so in
  /// as many words and cannot check it itself.
  Frame? _beforeFrame;

  Frame? _lastStableFrame;
  Frame? _candidateFrame;

  BoardState? _placementExpected;
  List<TouchedRegion>? _placementTouched;
  int _placementAttempts = 0;
  String? _lastFix;

  int _diceAttempts = 0;
  double? _lastConfidence;
  bool _rollInFlight = false;
  final Map<Player, Dice> _lastDice = <Player, Dice>{};

  int? _cubeConsideredAtEvent;
  int? _announcedGame;
  bool _announcedMatch = false;
  bool _advancing = false;
  bool _disposed = false;

  // --- what a screen reads -------------------------------------------------

  /// The match, once the opening throw has been read off the board.
  ///
  /// Null before then, and deliberately: a `GameController` rolls its opening
  /// in its constructor, so a session that built one before the dice were on
  /// the table would have to invent that roll. See BuddyDiceRoller.
  GameController? get controller => _controller;

  BuddyPhase get phase => _phase;

  /// The most recent verdict, or null before the first frame.
  Readability? get readability => _readability;

  /// The calibration is dead and the guided corner flow has to run.
  bool get needsRecalibration => _needsRecalibration;

  /// The camera could not find the dice; the pad has the floor.
  bool get needsManualDice => _needsManualDice;

  /// A dictated move has failed verification often enough that the user should
  /// be shown the board Buddy believes in, with the discrepancy on it.
  bool get needsBeliefMirror => _needsBeliefMirror;

  /// The legal plays a settled frame could not choose between.
  List<Move> get candidates => _candidates;

  /// Why the board is not a legal play, or null.
  String? get objection => _objection;

  /// The side the user plays.
  Player get userSide => buddySide.opponent;

  // --- what a screen calls -------------------------------------------------

  /// Installs a calibration and lets play run.
  ///
  /// The same verb for both the first calibration and every recalibration
  /// after it, because it is the same event: a board has been learned and the
  /// session may look at it again. A recalibration resumes at the phase the
  /// outage interrupted — the spec's "play resumes exactly where it paused".
  void useCalibration(BoardVision vision) {
    _vision = vision;
    _needsRecalibration = false;
    if (_phase == BuddyPhase.calibrating) {
      _phase = _pausedFrom ?? BuddyPhase.awaitingDice;
      _pausedFrom = null;
    }
    _advance();
    notifyListeners();
  }

  /// The roll the user typed on the pad. Also the escape hatch for a misread
  /// one: the pad is always open, per the spec's "manual dice entry is always
  /// one tap away".
  void enterDiceManually(Dice dice) {
    if (!_roller.isPending) {
      throw StateError('no roll is being waited for');
    }
    _acceptDice(dice, null);
  }

  /// The user picked one of [candidates].
  void pickCandidate(Move move) {
    if (_candidates.isEmpty) {
      throw StateError('no play candidates are on offer');
    }
    final c = _controller!;
    _foldPlay(c.state.turn, move, _candidateFrame);
    notifyListeners();
  }

  /// The tap-to-enter fallback for a play perception could not identify.
  void enterPlayManually(Move move) {
    final c = _controller;
    if (c == null || _humanAgent.pendingMove.value == null) {
      throw StateError('no play is being waited for');
    }
    _foldPlay(c.state.turn, move, _lastStableFrame);
    notifyListeners();
  }

  /// The user's on-screen Double, under the digital game's own gating (the
  /// controller throws if it is not legal, and stays the authority on that).
  ///
  /// **Announced only once the controller has taken it**, and that ordering is
  /// the rule for every cube verb in this file. A spoken line here is not a
  /// log entry: the transcript is the user's record of the match and the cube
  /// on the table is theirs to turn, so "You double." over a refused verb
  /// instructs a real-world action the game will disagree with for the rest of
  /// the match.
  void offerDouble() {
    final c = _controller;
    if (c == null) throw StateError('there is no game to double in');
    c.offerDouble();
    policy.onCubeAction(userSide, BuddyCubeAction.offered);
  }

  /// The user's answer to Buddy's spoken double. Announced after the answer is
  /// accepted, for the reason [offerDouble] gives.
  void answerDouble(CubeAction action) {
    _humanAgent.submitCubeResponse(action);
    policy.onCubeAction(
      userSide,
      action == CubeAction.take
          ? BuddyCubeAction.taken
          : BuddyCubeAction.dropped,
    );
    _advance();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_frames.cancel());
    _roller.cancel();
    final c = _controller;
    if (c != null) {
      c.removeListener(_onController);
      c.lastMove.removeListener(_onLastMove);
      // Disposes both agents exactly once, and its own notifiers — which is
      // why the listeners come off first.
      c.disposeController();
    } else {
      // A session abandoned before the opening throw never built a controller,
      // so nothing else will ever dispose the agents it made.
      _humanAgent.dispose();
      _buddyAgent.dispose();
    }
    super.dispose();
  }

  // --- the frame loop ------------------------------------------------------

  /// Readability on EVERY frame; a query only on a settled one.
  ///
  /// The split is the spec's: the light is what a user needs precisely while
  /// things are unstable, and an answer taken from an unsettled frame is an
  /// answer taken from a board mid-move.
  void _onFrame(ObservedFrame f) {
    if (_disposed) return;
    final vision = _vision;
    // No calibration, nothing to say. A dead calibration cannot even judge its
    // own readability — the guided flow owns the camera until it is replaced.
    if (vision == null) return;

    final reading = vision.assessReadability(f.frame, f.motion);
    if (_readability == null || _differs(_readability!, reading)) {
      _readability = reading;
      policy.onReadability(reading);
      notifyListeners();
    }

    if (reading.requiresRecalibration) {
      _enterRecalibration();
      return;
    }
    if (reading.answersSuppressed) {
      _pause();
      return;
    }
    _resume();
    if (!f.isStable) return;
    _lastStableFrame = f.frame;
    switch (_phase) {
      case BuddyPhase.awaitingDice:
        _tryReadDice(f);
      case BuddyPhase.awaitingPlay || BuddyPhase.objecting:
        _tryMatchPlay(f);
      case BuddyPhase.verifyingPlacement:
        _tryVerifyPlacement(f);
      case BuddyPhase.calibrating ||
            BuddyPhase.disambiguating ||
            BuddyPhase.awaitingCubeAnswer ||
            BuddyPhase.thinking ||
            BuddyPhase.paused ||
            BuddyPhase.over:
        break;
    }
  }

  static bool _differs(Readability a, Readability b) =>
      a.level != b.level ||
      a.cause != b.cause ||
      a.requiresRecalibration != b.requiresRecalibration;

  void _pause() {
    if (_phase == BuddyPhase.paused || _phase == BuddyPhase.calibrating) return;
    _pausedFrom = _phase;
    _phase = BuddyPhase.paused;
    notifyListeners();
  }

  void _resume() {
    if (_phase != BuddyPhase.paused) return;
    _phase = _pausedFrom ?? BuddyPhase.thinking;
    _pausedFrom = null;
    _advance();
    notifyListeners();
  }

  void _enterRecalibration() {
    if (_phase == BuddyPhase.calibrating) return;
    if (_phase != BuddyPhase.paused) _pausedFrom = _phase;
    _phase = BuddyPhase.calibrating;
    _needsRecalibration = true;
    _vision = null;
    // The epoch is over. Anything held from it would be differenced against a
    // frame from a different board, quietly and without an error.
    _beforeFrame = null;
    _candidateFrame = null;
    _lastStableFrame = null;
    notifyListeners();
  }

  // --- the three queries ---------------------------------------------------

  void _tryReadDice(ObservedFrame f) {
    if (_needsManualDice || !_roller.isPending) return;
    final reading = _vision!.readDice(f.frame);
    if (reading == null) {
      _diceAttempts++;
      if (_diceAttempts >= kDiceReadAttempts && !_needsManualDice) {
        _needsManualDice = true;
        notifyListeners();
      }
      return;
    }
    // The dice are on the board and the men have not moved, so this frame IS
    // the position before the play — the "before" half the matcher needs.
    _beforeFrame = f.frame;
    _acceptDice(reading.dice, reading.confidence);
  }

  void _acceptDice(Dice dice, double? confidence) {
    if (_openingNeeded && dice.isDouble) {
      // Two people at a board throw again; so does this.
      policy.onOpeningRerolled(dice);
      return;
    }
    _lastConfidence = confidence;
    _roller.submit(dice);
  }

  bool get _openingNeeded =>
      _controller == null || _controller!.awaitingNextGame;

  void _tryMatchPlay(ObservedFrame f) {
    final c = _controller!;
    final s = c.state;
    final before = _beforeFrame;
    if (before == null) {
      // Re-anchoring after an outage. A play made while the light was out
      // cannot be recovered by differencing — the tap fallback is what covers
      // it, and the belief mirror is what shows the user why.
      _beforeFrame = f.frame;
      return;
    }
    final legal = s.legalMoves;
    if (legal.isEmpty) return; // a dance; _advance passes it
    final matches = _vision!
        .matchLegalPlay(f.frame, s.board, s.turn, legal, beforeFrame: before);
    final best = matches.isEmpty ? null : matches.first;

    if (best == null || !best.plausible) {
      // Nothing legal fits. Two very different things look like that, and the
      // difference is the whole objection flow: a board that still holds the
      // position is a player thinking, and a board that does not is a play
      // that is not legal.
      final check = _vision!.verifyExpectedBoard(f.frame, s.board);
      if (check.agrees) return;
      final reason = check.message;
      if (reason != _objection) {
        _objection = reason;
        policy.onIllegalPlayObserved(reason);
      }
      _phase = BuddyPhase.objecting;
      notifyListeners();
      return;
    }

    if (best.isAmbiguous) {
      _candidates = List<Move>.unmodifiable(<Move>[best.play, ...best.tiedWith]);
      _candidateFrame = f.frame;
      _phase = BuddyPhase.disambiguating;
      notifyListeners();
      return;
    }

    _foldPlay(s.turn, best.play, f.frame);
    notifyListeners();
  }

  void _tryVerifyPlacement(ObservedFrame f) {
    final expected = _placementExpected!;
    final touched = _placementTouched!;
    final result = _vision!.verifyExpectedBoard(f.frame, expected);

    if (result.agreesOn(touched)) {
      _beforeFrame = f.frame;
      _placementExpected = null;
      _placementTouched = null;
      _placementAttempts = 0;
      _lastFix = null;
      _needsBeliefMirror = false;
      policy.onPlacementVerified(true, null);
      _advance();
      notifyListeners();
      return;
    }

    _placementAttempts++;
    final fix = result.discrepanciesOn(touched).first.message;
    if (fix != _lastFix) {
      _lastFix = fix;
      policy.onPlacementVerified(false, fix);
    }
    if (_placementAttempts >= kPlacementAttemptsBeforeMirror) {
      _needsBeliefMirror = true;
    }
    notifyListeners();
  }

  void _foldPlay(Player mover, Move play, Frame? settledOn) {
    _objection = null;
    _candidates = const <Move>[];
    _candidateFrame = null;
    if (settledOn != null) _beforeFrame = settledOn;
    policy.onPlayObserved(mover, play);
    _humanAgent.submitMove(play);
  }

  // --- the scheduler -------------------------------------------------------

  /// Re-derives [phase] from where the game has got to.
  ///
  /// The order of the checks is the priority order, and one of them is not
  /// obvious: **placement verification outranks everything the controller
  /// wants next.** Buddy's move is applied to the authoritative state the
  /// moment the engine returns it, so the controller is already asking for the
  /// user's roll while the man is still in the user's hand. Asking for that
  /// roll before the board has caught up would fold a dictated move nobody
  /// made.
  void _advance() {
    if (_disposed || _advancing) return;
    _advancing = true;
    try {
      _derive();
    } finally {
      _advancing = false;
    }
  }

  void _derive() {
    if (_phase == BuddyPhase.calibrating || _phase == BuddyPhase.paused) return;

    final c = _controller;
    if (c == null) {
      _phase = BuddyPhase.awaitingDice;
      _kickRoll();
      return;
    }
    if (_placementExpected != null) {
      _phase = BuddyPhase.verifyingPlacement;
      return;
    }
    if (c.matchOver) {
      _phase = BuddyPhase.over;
      return;
    }
    if (c.awaitingNextGame) {
      _phase = BuddyPhase.awaitingDice;
      _kickRoll();
      return;
    }
    if (_humanAgent.pendingCube.value != null) {
      _phase = BuddyPhase.awaitingCubeAnswer;
      return;
    }
    if (_humanAgent.pendingMove.value != null) {
      final s = c.state;
      if (s.legalMoves.isEmpty) {
        // The dance, mirroring the digital game's auto-pass: announced, and
        // passed without waiting for a board that has nothing to show.
        _phase = BuddyPhase.thinking;
        _foldPlay(s.turn, Move.none, null);
        return;
      }
      _phase = _objection != null
          ? BuddyPhase.objecting
          : (_candidates.isEmpty
              ? BuddyPhase.awaitingPlay
              : BuddyPhase.disambiguating);
      return;
    }
    if (c.awaitingHumanTurn) {
      _preRoll(c);
      return;
    }
    _phase = BuddyPhase.thinking;
  }

  /// Both sides park here, because a hand throws for both. Buddy's side gets
  /// its cube question first — the one the controller no longer asks, since
  /// this agent answers `wantsDoublePrompts == false`.
  void _preRoll(GameController c) {
    final events = c.game.events.length;
    if (c.state.turn == buddySide &&
        _cubeConsideredAtEvent != events &&
        _doublingLegal(c)) {
      _cubeConsideredAtEvent = events;
      _phase = BuddyPhase.thinking;
      unawaited(_considerBuddyDouble(c));
      return;
    }
    _phase = BuddyPhase.awaitingDice;
    _kickRoll();
  }

  /// The controller's own `_doublingLegal`, restated because it is private
  /// there. The controller stays the authority: `offerDouble` throws if the
  /// two ever disagree, which is the failure mode worth having.
  ///
  /// **Only in one direction, though**, and that is why this copy is pinned
  /// rather than merely documented. A copy that drifts PERMISSIVE meets that
  /// throw. A copy that drifts restrictive meets nothing: Buddy stops
  /// offering the cube, no exception is raised, no line is logged, and the
  /// mode goes on playing a strictly worse match. The "doubling predicate"
  /// group in `test/buddy/buddy_session_test.dart` compares this against the
  /// controller's actual acceptance on the states that separate them — a
  /// centred cube, one Buddy owns, one the user owns, Crawford, cubeless — so
  /// that drift in either direction is loud.
  bool _doublingLegal(GameController c) {
    final s = c.state;
    return !cubeless &&
        s.phase == GamePhase.awaitingRoll &&
        !s.isCrawfordGame &&
        (s.cube.owner == null || s.cube.owner == s.turn);
  }

  Future<void> _considerBuddyDouble(GameController c) async {
    final wants =
        await _buddyAgent.considerDouble(c.state, c.contextFor(buddySide));
    if (_disposed || !identical(_controller, c)) return;
    if (wants && c.awaitingHumanTurn && _doublingLegal(c)) {
      // After the verb, as in [offerDouble] — the guard above makes a throw
      // here unreachable, and one ordering for all three cube verbs is what
      // keeps it that way.
      c.offerDouble();
      policy.onCubeAction(buddySide, BuddyCubeAction.offered);
      return;
    }
    _advance();
    notifyListeners();
  }

  void _kickRoll() {
    if (_rollInFlight || _roller.isPending) return;
    unawaited(_requestRoll());
  }

  /// One physical roll, start to finish: ask, wait for the board or the pad,
  /// say it, and let the game take it.
  Future<void> _requestRoll() async {
    _rollInFlight = true;
    _diceAttempts = 0;
    _needsManualDice = false;
    final Dice dice;
    try {
      dice = await _roller.rollDice();
    } finally {
      _rollInFlight = false;
    }
    if (_disposed) return;
    _needsManualDice = false;

    final c = _controller;
    if (c == null) {
      // The throw that starts the match.
      final first = _openingWinner(dice);
      _lastDice[first] = dice;
      policy.onDiceRead(first, dice, _lastConfidence);
      _buildController();
      return;
    }
    if (c.awaitingNextGame) {
      final first = _openingWinner(dice);
      _lastDice[first] = dice;
      policy.onDiceRead(first, dice, _lastConfidence);
      c.continueToNextGame();
      return;
    }
    final roller = c.state.turn;
    _lastDice[roller] = dice;
    policy.onDiceRead(roller, dice, _lastConfidence);
    c.rollDice();
  }

  /// White's die is [Dice.die1] and Black's is [Dice.die2].
  ///
  /// Which physical die is whose is the one thing about an opening throw that
  /// a settled frame genuinely cannot answer on its own, and pretending
  /// otherwise would be the wrong kind of confidence. What makes it safe is
  /// that it does not have to: the pad is open on the opening throw like every
  /// other, and the calibration knows which half of the table the user sits at
  /// — the seat-aware split of `DiceReading`'s two board-space centres is
  /// Task 12's to wire, on the flow that asked for the throw.
  Player _openingWinner(Dice dice) =>
      dice.die1 > dice.die2 ? Player.white : Player.black;

  void _buildController() {
    final c = GameController(
      white: buddySide == Player.white ? _buddyAgent : _humanAgent,
      black: buddySide == Player.black ? _buddyAgent : _humanAgent,
      matchLength: matchLength,
      cubeless: cubeless,
      persistence: persistence,
      diceRoller: _roller,
    );
    _controller = c;
    c.addListener(_onController);
    c.lastMove.addListener(_onLastMove);
    unawaited(c.playMatch());
    _advance();
    notifyListeners();
  }

  // --- listening to the game ----------------------------------------------

  void _onController() {
    final c = _controller;
    if (_disposed || c == null) return;
    final result = c.state.result;
    if (result != null && _announcedGame != c.gameNumber) {
      _announcedGame = c.gameNumber;
      policy.onGameEnd(result);
    }
    if (c.matchOver && !_announcedMatch) {
      _announcedMatch = true;
      final winner = c.match.winner;
      if (winner != null) policy.onMatchEnd(winner);
    }
    _advance();
    notifyListeners();
  }

  /// Buddy's move has been applied to the authoritative state; now the board
  /// has to catch up.
  ///
  /// Fired from the controller's `lastMove` rather than from the agent, and
  /// that is deliberate: the agent returns the move BEFORE it is applied, so
  /// the expected position would not exist yet. Here the game already holds
  /// it, which is exactly what the placement query has to be primed with.
  void _onLastMove() {
    final c = _controller;
    if (_disposed || c == null) return;
    final applied = c.lastMove.value;
    if (applied == null || applied.player != buddySide) return;
    final dice = _lastDice[buddySide];
    if (dice != null) policy.onBuddyMoveChosen(dice, applied.move);
    _placementExpected = c.state.board;
    _placementTouched = regionsTouchedBy(applied.move, buddySide);
    _placementAttempts = 0;
    _lastFix = null;
    _advance();
  }

  void _onBuddyCube(CubeAction action) => policy.onCubeAction(
        buddySide,
        action == CubeAction.take
            ? BuddyCubeAction.taken
            : BuddyCubeAction.dropped,
      );
}
