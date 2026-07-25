import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:engine_bindings/engine_bindings.dart';
import 'package:flutter/material.dart';

import '../board/board_view.dart';
import '../game/match_controller.dart';
import '../game/player_agent.dart';
import '../tutor/move_assessment.dart';
import '../tutor/tutor_service.dart';

/// The production default per-hop checker-movement animation speed, passed by
/// the app's [GameScreen] call sites. Task 5 replaces this with a user setting.
const Duration kDefaultMoveAnimationDuration = Duration(milliseconds: 150);

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
    this.animationDuration = Duration.zero,
  });

  final MatchController controller;

  /// Per-hop checker-movement animation duration passed to the [BoardView].
  /// Defaults to [Duration.zero] (animation off) so widget tests are unaffected;
  /// production call sites pass a fixed non-zero speed. Settings wiring lands in
  /// a later task.
  final Duration animationDuration;

  /// Which side sits at the bottom of the board. See [BoardOrientationMode].
  final BoardOrientationMode orientation;

  /// The live tutor, or `null` when tutor mode is off. When non-null the screen
  /// surfaces a hint button (top-5 plays), a post-move assessment chip for
  /// HUMAN moves, and cube advice at the human's pre-roll gate / cube-offer
  /// dialog. Display-only: hints never auto-apply.
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

  /// The current post-move assessment chip (HUMAN moves only), or `null`. Each
  /// new human move replaces it; it is dismissible and cleared on game end.
  MoveAssessment? _chip;

  /// Whether the chip is expanded to reveal the best play.
  bool _chipExpanded = false;

  /// Monotonic token guarding the async [TutorService.assess]: a resolved future
  /// is applied only if it is still the latest request (and the screen mounted).
  int _assessSeq = 0;

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

  /// Whether the hint bottom panel is open, plus its loading/result state.
  bool _hintOpen = false;
  bool _hintLoading = false;
  List<ScoredMove>? _hintMoves;
  int _hintSeq = 0;

  /// Full move to STAGE into the interactive board (tap-to-apply hint). Fired
  /// when a hint row is tapped; the [BoardView] resets its builder and re-enters
  /// the move's hops, leaving it complete but uncommitted for the user's Confirm.
  final ValueNotifier<Move?> _stagedMove = ValueNotifier<Move?>(null);

  @override
  void initState() {
    super.initState();
    _observable = Listenable.merge([_c, ..._humanNotifiers()]);
    _observable.addListener(_onChange);
    // Fire-and-forget: the controller catches loop errors and records them on
    // `error`, which the banner surfaces. Nothing here needs the returned future.
    unawaited(_c.playMatch());
  }

  @override
  void dispose() {
    _observable.removeListener(_onChange);
    _stagedMove.dispose();
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
    _syncTutor();
    setState(() {});
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
  /// mover is a human, kicks off an async assessment whose result becomes the
  /// chip. A shorter event list means a new game began: reset and clear.
  void _syncAssessment() {
    final events = _c.game.events;
    final len = events.length;

    if (len < _lastEventCount) {
      // A new game started (the event log reset). Clear the previous chip.
      _lastEventCount = len;
      _chip = null;
      _chipExpanded = false;
      _assessSeq++; // abandon any in-flight assessment from the old game
      return;
    }
    if (_c.state.phase == GamePhase.gameOver) {
      _chip = null;
      _chipExpanded = false;
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
      _fireAssessment(before, event.move);
    }
    _lastEventCount = len;
  }

  void _fireAssessment(GameState before, Move played) {
    final seq = ++_assessSeq;
    _chip = null; // show a fresh (empty) slot until the future resolves
    _chipExpanded = false;
    unawaited(_tutor!.assess(before, played).then((assessment) {
      if (!mounted || seq != _assessSeq) return;
      setState(() {
        _chip = assessment;
        _chipExpanded = false;
      });
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

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                if (_c.error != null) _ErrorBanner(error: _c.error!),
                _Hud(controller: _c),
                if (_chip != null) _tutorChip(_chip!),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Center(
                      child: BoardView(
                        state: state,
                        interactive: moveSide != null,
                        onMoveCommitted: (move) {
                          if (moveSide != null) _c.submitMove(moveSide, move);
                        },
                        whiteAtBottom: whiteAtBottom,
                        externalMove: _stagedMove,
                        lastMove: _c.lastMove,
                        animationDuration: widget.animationDuration,
                      ),
                    ),
                  ),
                ),
                _bottomRegion(moveSide),
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
    final winner = _playerName(result.winner);
    return _ModalCard(
      title: 'Game over',
      message: '$winner wins ${result.points} '
          '(${_outcomeName(result.outcome)}).\n'
          '${_scoreLine(_c)}',
      actions: [
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
      actions: [
        _CardAction(
          label: 'Done',
          filled: true,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  // --- Tutor UI --------------------------------------------------------------

  /// The bottom controls: the tutor hint button (during a human move), the
  /// pre-roll action bar, and the pre-roll cube advice line.
  Widget _bottomRegion(Player? moveSide) {
    final showHint = _tutor != null && moveSide != null;
    final showCube =
        _tutor != null && _cubeAdvice != null && _c.awaitingHumanTurn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHint)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: _openHint,
              icon: const Icon(Icons.lightbulb_outline, size: 18),
              label: const Text('Hint'),
            ),
          ),
        _ActionBar(controller: _c),
        if (showCube) _cubeAdviceLine(_cubeAdvice!),
      ],
    );
  }

  /// The dismissible post-move assessment chip: a coloured mark, the equity
  /// loss, and (tap to expand) the best play. HUMAN moves only.
  Widget _tutorChip(MoveAssessment a) {
    final (color, label) = _markStyle(a.mark);
    final loss = a.equityLoss;
    final lossText = loss >= 0.001 ? ' −${loss.toStringAsFixed(3)}' : '';
    final showBest = _chipExpanded && a.best.checkerMoves.isNotEmpty;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _chipExpanded = !_chipExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 12, color: color),
                      const SizedBox(width: 8),
                      Text('$label$lossText',
                          style: TextStyle(
                              color: color, fontWeight: FontWeight.w600)),
                      if (showBest) ...[
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text('Best: ${a.best}',
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() {
                _chip = null;
                _chipExpanded = false;
              }),
            ),
          ],
        ),
      ),
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
  Widget _cubeAdviceLine(CubeAssessment a) {
    final advice = a.advice;
    final text = advice.shouldDouble
        ? 'Tutor: Double — opponent should '
            '${advice.shouldTake ? 'take' : 'pass'}'
        : 'Tutor: Roll';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.school, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: scheme.primary, fontSize: 13)),
        ],
      ),
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
                    else
                      for (var i = 0; i < top.length; i++)
                        _hintRow(i, top[i], bestEq),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

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
            Text(sm.equity.toStringAsFixed(3), style: mono),
            SizedBox(
              width: 64,
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

String _outcomeName(GameOutcome o) => switch (o) {
      GameOutcome.single => 'single',
      GameOutcome.gammon => 'gammon',
      GameOutcome.backgammon => 'backgammon',
      GameOutcome.drop => 'drop',
      GameOutcome.resignation => 'resignation',
    };

String _scoreLine(MatchController c) {
  final m = c.match;
  return 'White ${m.whiteScore} — ${m.blackScore} Black  (to ${m.matchLength})';
}

// --- HUD ---------------------------------------------------------------------

class _Hud extends StatelessWidget {
  const _Hud({required this.controller});

  final MatchController controller;

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

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final cube = state.cube;
    final cubeOwner = cube.owner == null
        ? 'centre'
        : _playerName(cube.owner!).toLowerCase();
    // The thinking chip reflects a genuine AI await, not a human's own decision
    // (the controller keeps `isThinking` true while it awaits a human move too).
    final showThinking = controller.isThinking && !_humanDeciding;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _scoreLine(controller),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (state.isCrawfordGame) ...[
              const _Badge(label: 'Crawford'),
              const SizedBox(width: 8),
            ],
            _Badge(label: 'Cube ${cube.value} ($cubeOwner)'),
            if (showThinking) ...[
              const SizedBox(width: 8),
              const _Badge(label: 'thinking…'),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12)),
    );
  }
}

// --- Action bar --------------------------------------------------------------

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.controller});

  final MatchController controller;

  bool get _doublingLegal {
    final s = controller.state;
    return !s.isCrawfordGame &&
        (s.cube.owner == null || s.cube.owner == s.turn);
  }

  @override
  Widget build(BuildContext context) {
    // Move-entry controls (Undo/Confirm/Pass) live inside the BoardView during
    // the moving phase; this bar only serves the pre-roll human turn gate.
    if (!controller.awaitingHumanTurn) {
      return const SizedBox(height: 64);
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton(
            onPressed: controller.rollDice,
            child: const Text('Roll'),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: _doublingLegal ? controller.offerDouble : null,
            child: const Text('Double'),
          ),
          const SizedBox(width: 12),
          PopupMenuButton<ResignValue>(
            onSelected: controller.offerResign,
            itemBuilder: (context) => const [
              PopupMenuItem(value: ResignValue.single, child: Text('Single')),
              PopupMenuItem(value: ResignValue.gammon, child: Text('Gammon')),
              PopupMenuItem(
                  value: ResignValue.backgammon, child: Text('Backgammon')),
            ],
            // A styled container (not a disabled OutlinedButton) so the
            // affordance does not read as greyed-out; the menu owns the tap.
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border:
                    Border.all(color: Theme.of(context).colorScheme.outline),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text('Resign ▾'),
            ),
          ),
        ],
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

// --- Declarative modal card --------------------------------------------------

class _CardAction {
  const _CardAction({
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;
}

/// A declarative modal: an opaque [ModalBarrier] plus a centred [Material] card.
/// No route, no animation — visibility is a pure function of the caller's state.
class _ModalCard extends StatelessWidget {
  const _ModalCard({
    required this.title,
    required this.message,
    required this.actions,
  });

  final String title;
  final String message;
  final List<_CardAction> actions;

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
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (var i = 0; i < actions.length; i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          if (actions[i].filled)
                            FilledButton(
                              onPressed: actions[i].onPressed,
                              child: Text(actions[i].label),
                            )
                          else
                            TextButton(
                              onPressed: actions[i].onPressed,
                              child: Text(actions[i].label),
                            ),
                        ],
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
