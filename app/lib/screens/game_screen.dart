import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';

import '../board/board_view.dart';
import '../game/game_controller.dart';
import '../game/player_agent.dart';

/// The playing screen. Assembles the [BoardView], a top HUD, a bottom action
/// bar, the in-game dialogs (cube/resign responses, game-end, match-end), the
/// error banner, and the hot-seat pass-device overlay.
///
/// It RECEIVES a ready [GameController] (constructed by the caller — Plan 3
/// Task 9), starts its match loop in [initState], and disposes it in [dispose].
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
/// [LocalHumanAgent.wantsDoublePrompts] is `false`, so the [GameController] never
/// calls `considerDouble` on a human (see `game_controller.dart`
/// `_stepPreRoll`: the `wantsDoublePrompts` branch is AI-only; humans park on the
/// turn gate instead). A human's double is driven by the pre-roll action bar
/// ([GameController.offerDouble]), so `pendingDoubleRequest` never fires for a
/// human in practice and this screen deliberately does not observe it.
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
  });

  final GameController controller;

  /// Which side sits at the bottom of the board. See [BoardOrientationMode].
  final BoardOrientationMode orientation;

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
  GameController get _c => widget.controller;

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
      _c.white is LocalHumanAgent && _c.black is LocalHumanAgent;

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
    _c.disposeController();
    super.dispose();
  }

  List<Listenable> _humanNotifiers() => [
        for (final a in [_c.white, _c.black])
          if (a is LocalHumanAgent) ...[
            a.pendingMoveRequest,
            a.pendingCubeRequest,
            a.pendingResignRequest,
          ],
      ];

  void _onChange() {
    if (!mounted) return;
    _updatePassDevice();
    setState(() {});
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
      _humanWith((a) => a.pendingMoveRequest.value != null) != null ||
      _humanWith((a) => a.pendingCubeRequest.value != null) != null ||
      _humanWith((a) => a.pendingResignRequest.value != null) != null;

  /// The human agent (if any) for which [test] holds.
  LocalHumanAgent? _humanWith(bool Function(LocalHumanAgent) test) {
    for (final a in [_c.white, _c.black]) {
      if (a is LocalHumanAgent && test(a)) return a;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = _c.state;
    final moveHuman = _humanWith((a) => a.pendingMoveRequest.value != null);
    final cubeHuman = _humanWith((a) => a.pendingCubeRequest.value != null);
    final resignHuman = _humanWith((a) => a.pendingResignRequest.value != null);
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
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Center(
                      child: BoardView(
                        state: state,
                        interactive: moveHuman != null,
                        onMoveCommitted: (move) => moveHuman?.submitMove(move),
                        whiteAtBottom: whiteAtBottom,
                      ),
                    ),
                  ),
                ),
                _ActionBar(controller: _c),
              ],
            ),
            ..._buildModals(cubeHuman, resignHuman),
          ],
        ),
      ),
    );
  }

  /// The single active modal layer, chosen by priority: match end, then game
  /// end, then the pass-device gate, then the cube/resign response dialogs.
  List<Widget> _buildModals(
    LocalHumanAgent? cubeHuman,
    LocalHumanAgent? resignHuman,
  ) {
    if (_c.matchOver) return [_matchEndDialog()];
    if (_c.awaitingNextGame) return [_gameEndDialog()];
    if (_passDevicePending) return [_passDeviceOverlay()];
    if (cubeHuman != null) return [_cubeDialog(cubeHuman)];
    if (resignHuman != null) return [_resignDialog(resignHuman)];
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

  Widget _cubeDialog(LocalHumanAgent human) {
    final state = human.pendingCubeRequest.value!;
    // The decider is `state.turn`; the doubler is the opponent.
    final doubler = _playerName(state.turn.opponent);
    final newValue = state.cube.value * 2;
    return _ModalCard(
      title: 'Double offered',
      message: '$doubler offers a double to $newValue. Take or pass?',
      actions: [
        _CardAction(
          label: 'Pass',
          onPressed: () => human.submitCubeResponse(CubeAction.drop),
        ),
        _CardAction(
          label: 'Take',
          filled: true,
          onPressed: () => human.submitCubeResponse(CubeAction.take),
        ),
      ],
    );
  }

  Widget _resignDialog(LocalHumanAgent human) {
    final (state, value) = human.pendingResignRequest.value!;
    final resigner = _playerName(state.turn.opponent);
    return _ModalCard(
      title: 'Resignation offered',
      message: '$resigner offers to resign a ${_resignName(value)}. '
          'Accept or decline?',
      actions: [
        _CardAction(
          label: 'Decline',
          onPressed: () => human.submitResignResponse(false),
        ),
        _CardAction(
          label: 'Accept',
          filled: true,
          onPressed: () => human.submitResignResponse(true),
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

String _scoreLine(GameController c) {
  final m = c.match;
  return 'White ${m.whiteScore} — ${m.blackScore} Black  (to ${m.matchLength})';
}

// --- HUD ---------------------------------------------------------------------

class _Hud extends StatelessWidget {
  const _Hud({required this.controller});

  final GameController controller;

  bool get _humanDeciding {
    if (controller.awaitingHumanTurn) return true;
    for (final a in [controller.white, controller.black]) {
      if (a is LocalHumanAgent &&
          (a.pendingMoveRequest.value != null ||
              a.pendingCubeRequest.value != null ||
              a.pendingResignRequest.value != null)) {
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

  final GameController controller;

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
