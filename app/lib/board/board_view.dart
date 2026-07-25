import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'board_geometry.dart';
import 'board_painter.dart';
import 'board_theme.dart';

/// Bridges the [BoardView]'s private move-entry [MoveBuilder] to an EXTERNAL
/// action bar (the game screen's fixed-height bottom bar).
///
/// The board no longer draws its own Undo/Confirm/Pass overlay. Instead the
/// consumer owns a [BoardEntryController], hands it to [BoardView.entryControl],
/// and renders the buttons wherever it likes. The controller MIRRORS the live
/// builder affordances — [active] (a move is being entered), [canUndo] (at least
/// one hop chosen), [canConfirm] (a full legal move is staged), [isDance] (no
/// legal play, so a pass is offered) — and FORWARDS the user's [undo] /
/// [confirm] / [pass] taps back into the board.
///
/// It is a [ChangeNotifier]: it fires whenever the affordances change, so a bar
/// listening to it rebuilds its enabled/disabled state. [BoardView] pushes state
/// via the private `_update` (which notifies only on a real change) and binds the
/// action callbacks via `_bind`; both are library-private so external callers see
/// only the read getters and the three action methods.
class BoardEntryController extends ChangeNotifier {
  bool _active = false;
  bool _canUndo = false;
  bool _canConfirm = false;
  bool _isDance = false;

  /// Whether a move is currently being entered (the interactive moving phase).
  bool get active => _active;

  /// Whether at least one hop has been chosen (Undo is meaningful).
  bool get canUndo => _canUndo;

  /// Whether a full legal move is staged (Confirm is enabled).
  bool get canConfirm => _canConfirm;

  /// Whether the moving phase has no legal play (offer a Pass instead).
  bool get isDance => _isDance;

  // Action callbacks bound by the owning [BoardView]; null when unbound.
  VoidCallback? _onUndo;
  VoidCallback? _onConfirm;
  VoidCallback? _onPass;
  bool _notifyScheduled = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Removes the last entered hop. No-op unless a move is being entered.
  void undo() => _onUndo?.call();

  /// Commits the staged move. No-op unless [canConfirm].
  void confirm() => _onConfirm?.call();

  /// Passes the turn (a dance). No-op unless [isDance].
  void pass() => _onPass?.call();

  /// [BoardView]-internal: wires the action callbacks.
  void _bind({
    required VoidCallback onUndo,
    required VoidCallback onConfirm,
    required VoidCallback onPass,
  }) {
    _onUndo = onUndo;
    _onConfirm = onConfirm;
    _onPass = onPass;
  }

  /// [BoardView]-internal: drops the action callbacks (on detach/dispose).
  void _unbind() {
    _onUndo = null;
    _onConfirm = null;
    _onPass = null;
  }

  /// [BoardView]-internal: mirrors the current builder affordances. Stores the
  /// fields immediately (so a synchronous read is always current) and notifies
  /// listeners only when something actually changed. If called mid-build (from
  /// [BoardView]'s `initState`/`didUpdateWidget`, which run during the parent's
  /// build), the notify is deferred to the next frame to avoid a
  /// setState-during-build; from event handlers (taps, external-move fires) the
  /// scheduler is idle, so it notifies immediately.
  void _update({
    required bool active,
    required bool canUndo,
    required bool canConfirm,
    required bool isDance,
  }) {
    if (_active == active &&
        _canUndo == canUndo &&
        _canConfirm == canConfirm &&
        _isDance == isDance) {
      return;
    }
    _active = active;
    _canUndo = canUndo;
    _canConfirm = canConfirm;
    _isDance = isDance;
    _emit();
  }

  void _emit() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }
}

/// Interactive board. Renders [state]'s board (with a display-only preview of
/// partially-entered hops) and, when [interactive], drives a [MoveBuilder]
/// from taps: tap a highlighted source, then a highlighted destination. The
/// move-entry affordances (Undo/Confirm, or Pass on a dance) are NOT drawn on
/// the board; they are surfaced to an external action bar through the optional
/// [entryControl] (see [BoardEntryController]). Confirm commits `builder.build()`
/// via [onMoveCommitted]; Pass commits [Move.none].
///
/// ## Preview board (display-only)
///
/// While hops are being entered the painted board shows the partial move
/// applied. That preview is recomputed *fresh every build* from the original
/// [state]'s board by folding the builder's chosen hops one at a time via
/// `board.applyMove(turn, Move([hop]))` — a single-hop application per tap.
/// Per-hop application reproduces exactly what the user tapped, in tap order,
/// so the preview never diverges from what the user selected.
///
/// The preview is NEVER fed back into game state. On commit, `builder.build()`
/// returns the *canonical* legal move (correct hop order and hit flags) and the
/// controller applies it properly through [GameState]. A transit-reordered
/// entry could momentarily show a phantom-hit intermediate in the preview; this
/// is a known, accepted, display-only cosmetic risk (see [MoveBuilder]). No
/// board corruption is possible because the preview board is discarded.
///
/// ## Staging a full move externally ([externalMove])
///
/// A tap-to-apply hint needs to preload a complete play into the in-progress
/// entry without committing it. Because the [MoveBuilder] is private (created
/// from `state.legalMoves` inside this widget), callers hand in an
/// [externalMove] `ValueListenable<Move?>`; whenever it fires with a non-null
/// [Move] the view resets its builder and re-enters that move's hops *one at a
/// time* via `addHop`, in the move's canonical (generator) order — so the play
/// lands STAGED (`isComplete`, preview shows it applied, Confirm enabled) but
/// NOT committed. The user still presses Confirm. Selection is cleared.
///
/// The move is expected to be a *current* legal play, so hop-by-hop entry in
/// canonical order is always offered by the builder. Defensively, if any hop is
/// rejected (an [ArgumentError] — a stale/illegal move fired after the position
/// moved on), the builder is reset and the fire is ignored: never a crash, and
/// the board falls back to the clean base position. External application is a
/// no-op unless [interactive] and a builder exists (the moving phase).
///
/// ## Move animation ([lastMove] / [animationDuration])
///
/// When [lastMove] fires a non-null [MoveEvent], the view plays a purely
/// cosmetic animation: the moved checker travels hop-by-hop from source to
/// destination while the board underneath shows the position with the earlier
/// hops applied and the travelling checker suppressed (see [BoardPainter]'s
/// `hiddenChecker`/`overlayChecker`). The controller fires [lastMove] BEFORE it
/// notifies its own listeners, so at the moment the listener runs [state] is
/// still the PRE-move state — the pre-move board is captured then. Both the
/// local player's own just-confirmed move and the opponent's/AI's moves are
/// animated (simpler, and it reads fine).
///
/// Timing: [animationDuration] per hop (default 150ms), total capped at 600ms,
/// [Curves.easeInOut]. Animation is DISABLED — the post-move board snaps in
/// immediately — when [animationDuration] is [Duration.zero] or the ambient
/// [MediaQuery.disableAnimations] is set. Input is never blocked: taps flow to
/// the current (post-move) state; the animation is decoration only.
class BoardView extends StatefulWidget {
  const BoardView({
    super.key,
    required this.state,
    required this.interactive,
    required this.onMoveCommitted,
    this.whiteAtBottom = true,
    this.theme, // defaults by brightness
    this.externalMove,
    this.lastMove,
    this.entryControl,
    this.animationDuration = const Duration(milliseconds: 150),
  });

  /// The game state to render. Its board is the base of the preview.
  final GameState state;

  /// When true, taps drive a [MoveBuilder] whose affordances are surfaced to
  /// [entryControl] (there is no in-board control overlay).
  final bool interactive;

  /// Invoked with the completed [Move] when the external Confirm action fires,
  /// or with [Move.none] when the external Pass action is used (a dance).
  final ValueChanged<Move> onMoveCommitted;

  /// Board orientation. When false the board is rotated 180°.
  final bool whiteAtBottom;

  /// Optional stream of full moves to STAGE (not commit) into the in-progress
  /// entry — e.g. a tap-to-apply hint. Each non-null fire resets the builder and
  /// re-enters the move's hops, leaving it staged for Confirm. See the class doc.
  final ValueListenable<Move?>? externalMove;

  /// Stream of applied moves to animate (from [MatchController.lastMove]). Each
  /// non-null fire plays a cosmetic hop-by-hop travel of the moved checker. See
  /// the class doc for timing and the pre-move-state capture contract.
  final ValueListenable<MoveEvent?>? lastMove;

  /// Optional external bridge for the move-entry controls. When provided, the
  /// board mirrors its live builder affordances onto it and honours its
  /// [BoardEntryController.undo] / [BoardEntryController.confirm] /
  /// [BoardEntryController.pass] actions, letting the consumer render the
  /// buttons in its own layout instead of on the board.
  final BoardEntryController? entryControl;

  /// Duration of each hop's travel (default 150ms; total capped at 600ms).
  /// [Duration.zero] disables animation entirely (the post-move board snaps in),
  /// as does an ambient [MediaQuery.disableAnimations].
  final Duration animationDuration;

  /// Palette override. Defaults to [BoardTheme.dark]/[BoardTheme.light] by the
  /// ambient [Theme] brightness.
  final BoardTheme? theme;

  @override
  State<BoardView> createState() => _BoardViewState();
}

/// The pre-move board plus the ordered hops of the move currently animating.
class _BoardAnimation {
  _BoardAnimation(this.preBoard, this.hops, this.player);

  /// The board BEFORE the animated move (captured while [BoardView.state] still
  /// held the pre-move position).
  final BoardState preBoard;

  /// The move's hops, in canonical (applied) order.
  final List<CheckerMove> hops;

  /// The side that made the move (for colour and board application).
  final Player player;
}

class _BoardViewState extends State<BoardView>
    with SingleTickerProviderStateMixin {
  /// Live move builder — non-null only while interactive and in the moving
  /// phase. Mutated in place (addHop/undoHop); rebuilt on any state change.
  MoveBuilder? _builder;

  /// The currently picked-up source (a point index, or [CheckerMove.bar]);
  /// null when nothing is selected and sources are highlighted for pickup.
  int? _selectedSource;

  /// Cached at builder-reset time (legalMoves runs the generator): true when
  /// the interactive moving phase has no legal play, so a Pass is offered.
  bool _isDance = false;

  /// Drives the move animation (0 → 1 across all hops). Repaints on each tick.
  /// Constructed eagerly in [initState] (a lazy `late` field would first build —
  /// and touch the TickerMode inherited widget — during [dispose], which throws).
  late final AnimationController _animController;

  /// The move currently animating, or `null` when idle.
  _BoardAnimation? _animation;

  /// Monotonic guard so a superseded animation's completion callback (fired when
  /// a new move restarts the controller) does not clear a fresh animation.
  int _animSeq = 0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this)..addListener(_onAnimTick);
    _resetBuilder();
    widget.externalMove?.addListener(_applyExternalMove);
    widget.lastMove?.addListener(_onLastMove);
    _bindEntryControl(widget.entryControl);
  }

  @override
  void didUpdateWidget(BoardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebuild the builder and clear selection whenever the game state (by value
    // equality) or interactivity changes. Orientation/theme changes don't
    // affect move entry, so they don't reset it.
    if (oldWidget.state != widget.state ||
        oldWidget.interactive != widget.interactive) {
      _resetBuilder();
    }
    // Re-subscribe if the external-move listenable instance was swapped.
    if (!identical(oldWidget.externalMove, widget.externalMove)) {
      oldWidget.externalMove?.removeListener(_applyExternalMove);
      widget.externalMove?.addListener(_applyExternalMove);
    }
    if (!identical(oldWidget.lastMove, widget.lastMove)) {
      oldWidget.lastMove?.removeListener(_onLastMove);
      widget.lastMove?.addListener(_onLastMove);
    }
    if (!identical(oldWidget.entryControl, widget.entryControl)) {
      oldWidget.entryControl?._unbind();
      _bindEntryControl(widget.entryControl);
    }
    // Any of the above may have changed the affordances; push them.
    _syncEntry();
  }

  @override
  void dispose() {
    widget.externalMove?.removeListener(_applyExternalMove);
    widget.lastMove?.removeListener(_onLastMove);
    widget.entryControl?._unbind();
    _animController.dispose();
    super.dispose();
  }

  /// Wires [control]'s action methods to this board's entry handlers and pushes
  /// the current affordances into it.
  void _bindEntryControl(BoardEntryController? control) {
    control?._bind(onUndo: _undo, onConfirm: _confirm, onPass: _pass);
    _syncEntry();
  }

  /// Mirrors the live builder affordances onto [widget.entryControl].
  void _syncEntry() {
    final builder = _builder;
    widget.entryControl?._update(
      active: builder != null,
      canUndo: builder != null && builder.chosenHops.isNotEmpty,
      canConfirm: builder != null && builder.isComplete,
      isDance: _isDance,
    );
  }

  /// Removes the last entered hop (external Undo). No-op with no builder.
  void _undo() {
    final builder = _builder;
    if (builder == null) return;
    setState(() {
      builder.undoHop();
      _selectedSource = null;
    });
    _syncEntry();
  }

  /// Commits the staged move (external Confirm). No-op unless a full legal move
  /// is entered.
  void _confirm() {
    final builder = _builder;
    if (builder == null || !builder.isComplete) return;
    widget.onMoveCommitted(builder.build());
  }

  /// Passes the turn on a dance (external Pass). No-op unless in a dance.
  void _pass() {
    if (!_isDance) return;
    widget.onMoveCommitted(Move.none);
  }

  void _onAnimTick() {
    if (mounted) setState(() {});
  }

  /// Whether move animation is currently enabled: a positive per-hop duration
  /// and no ambient reduce-motion setting.
  bool get _animationsEnabled {
    if (widget.animationDuration <= Duration.zero) return false;
    final mq = MediaQuery.maybeOf(context);
    return mq == null || !mq.disableAnimations;
  }

  /// Reacts to a fired [BoardView.lastMove]: captures the (still) pre-move board
  /// and plays the hop-by-hop travel. Skipped when animations are disabled or
  /// the move is an empty pass. A rapid follow-up move restarts the controller;
  /// the old completion callback is fenced out by [_animSeq].
  void _onLastMove() {
    final event = widget.lastMove?.value;
    if (event == null || !_animationsEnabled) return;
    final hops = event.move.checkerMoves;
    if (hops.isEmpty) return; // a pass: nothing to animate
    // The controller fires this BEFORE it notifies, so [widget.state] is still
    // the PRE-move state here — capture its board as the animation base.
    final anim = _BoardAnimation(widget.state.board, hops, event.player);
    final seq = ++_animSeq;
    setState(() => _animation = anim);
    _animController
      ..stop()
      ..duration = _totalDuration(hops.length)
      ..value = 0
      ..forward().whenComplete(() {
        if (!mounted || seq != _animSeq) return;
        setState(() => _animation = null);
      });
  }

  /// Total animation time: per-hop [BoardView.animationDuration] × hop count,
  /// capped at 600ms so long multi-hop plays stay snappy.
  Duration _totalDuration(int hopCount) {
    const cap = Duration(milliseconds: 600);
    final total = widget.animationDuration * hopCount;
    return total > cap ? cap : total;
  }

  /// Stages the current [BoardView.externalMove] value into the builder: resets
  /// entry and re-enters the move's hops in canonical order, leaving it complete
  /// but uncommitted (Confirm remains the user's action). Ignores a null fire or
  /// a fire while not in the interactive moving phase. A rejected hop (stale or
  /// illegal move) resets the builder and is silently dropped — never a crash.
  void _applyExternalMove() {
    final move = widget.externalMove?.value;
    if (move == null) return;
    final builder = _builder;
    if (!widget.interactive || builder == null) return;
    setState(() {
      _selectedSource = null;
      builder.reset();
      try {
        for (final hop in move.checkerMoves) {
          builder.addHop(hop.from, hop.to);
        }
      } on ArgumentError {
        builder.reset(); // stale/illegal move: leave a clean base position
      }
    });
    _syncEntry();
  }

  /// Creates a fresh builder from the current legal moves (or clears it) and
  /// drops any in-progress selection. A builder exists only in the interactive
  /// moving phase; in a dance it exists but offers no sources.
  void _resetBuilder() {
    _selectedSource = null;
    if (widget.interactive && widget.state.phase == GamePhase.moving) {
      final legal = widget.state.legalMoves;
      _builder = MoveBuilder(legal);
      _isDance = legal.isEmpty;
    } else {
      _builder = null;
      _isDance = false;
    }
  }

  /// The current animation frame for [geometry]: the board to paint (pre-move
  /// board with earlier hops applied), the checker to hide, and the travelling
  /// overlay checker. `null` when no move is animating.
  ({
    BoardState board,
    ({int location, int stackIndex, bool isWhite})? hidden,
    ({Offset center, bool isWhite})? overlay,
  })? _animFrame(BoardGeometry geometry) {
    final anim = _animation;
    if (anim == null) return null;
    final n = anim.hops.length;
    final raw = _animController.value * n;
    final hopIndex = raw.floor().clamp(0, n - 1);
    final localT = (raw - hopIndex).clamp(0.0, 1.0);
    final eased = Curves.easeInOut.transform(localT);
    final isWhite = anim.player == Player.white;

    // The board with the hops before the current one already applied.
    var board = anim.preBoard;
    for (var k = 0; k < hopIndex; k++) {
      board = board.applyMove(anim.player, Move([anim.hops[k]]));
    }
    final hop = anim.hops[hopIndex];

    // Source: the top checker at the hop's origin, lifted (hidden) as it travels.
    final Offset from;
    final int fromLoc;
    final int fromStack;
    if (hop.from == CheckerMove.bar) {
      fromLoc = CheckerMove.bar;
      final barCount = board.barFor(anim.player);
      fromStack = (barCount - 1).clamp(0, 1 << 30);
      from = geometry.barCheckerCenter(anim.player, fromStack, barCount);
    } else {
      fromLoc = hop.from;
      final srcCount = board.points[hop.from].abs();
      fromStack = (srcCount - 1).clamp(0, 1 << 30);
      from = geometry.checkerCenter(hop.from, fromStack, srcCount);
    }

    // Destination: the moving checker's landing spot (its own stack top, or the
    // bear-off tray centre).
    final Offset to;
    if (hop.to == CheckerMove.off) {
      to = geometry.offRect(anim.player).center;
    } else {
      final at = board.points[hop.to];
      final sameSign = isWhite ? at > 0 : at < 0;
      // Lands on top of an existing same-colour stack, or as the first checker
      // on an empty / just-hit point.
      final landStack = sameSign ? at.abs() : 0;
      to = geometry.checkerCenter(hop.to, landStack, landStack + 1);
    }

    return (
      board: board,
      hidden: (location: fromLoc, stackIndex: fromStack, isWhite: isWhite),
      overlay: (center: Offset.lerp(from, to, eased)!, isWhite: isWhite),
    );
  }

  /// Preview board: [state]'s board with the chosen hops applied one at a time,
  /// in tap order. Display-only — see the class doc. Recomputed every build.
  BoardState _previewBoard() {
    var board = widget.state.board;
    final builder = _builder;
    if (builder == null) return board;
    for (final hop in builder.chosenHops) {
      board = board.applyMove(widget.state.turn, Move([hop]));
    }
    return board;
  }

  void _handleTap(BoardGeometry geometry, Offset localPosition) {
    final builder = _builder;
    if (builder == null) return;
    final loc = geometry.locationAt(localPosition);
    setState(() {
      if (loc == null) {
        _selectedSource = null; // tap on empty space clears selection
        return;
      }
      final selected = _selectedSource;
      if (selected == null) {
        // Nothing picked up: pick up a highlighted source if this is one.
        if (builder.selectableSources.contains(loc)) {
          _selectedSource = loc;
        }
        return;
      }
      if (loc == selected) {
        _selectedSource = null; // re-tapping the source deselects it
        return;
      }
      if (builder.destinationsFor(selected).contains(loc)) {
        builder.addHop(selected, loc); // complete a hop
        _selectedSource = null;
      } else if (builder.selectableSources.contains(loc)) {
        _selectedSource = loc; // switch pickup to another source
      } else {
        _selectedSource = null; // tapped somewhere irrelevant
      }
    });
    _syncEntry();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ??
        (Theme.of(context).brightness == Brightness.dark
            ? BoardTheme.dark
            : BoardTheme.light);
    final builder = _builder;
    final selected = _selectedSource;

    return AspectRatio(
      aspectRatio: 4 / 3,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final geometry =
              BoardGeometry(size, whiteAtBottom: widget.whiteAtBottom);

          // While a move animates, paint the pre-move board (with earlier hops
          // applied), hide the travelling checker, and drop interaction
          // highlights; otherwise paint the normal preview board.
          final frame = _animFrame(geometry);
          final painter = frame != null
              ? BoardPainter(
                  board: frame.board,
                  geometry: geometry,
                  theme: theme,
                  dice: widget.state.dice,
                  cube: widget.state.cube,
                  hiddenChecker: frame.hidden,
                  overlayChecker: frame.overlay,
                )
              : BoardPainter(
                  board: _previewBoard(),
                  geometry: geometry,
                  theme: theme,
                  dice: widget.state.dice,
                  cube: widget.state.cube,
                  highlightedSources: (builder != null && selected == null)
                      ? builder.selectableSources
                      : const {},
                  highlightedDestinations: (builder != null && selected != null)
                      ? builder.destinationsFor(selected)
                      : const {},
                  selectedSource: selected,
                );

          return widget.interactive
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) =>
                      _handleTap(geometry, details.localPosition),
                  child: CustomPaint(size: size, painter: painter),
                )
              : CustomPaint(size: size, painter: painter);
        },
      ),
    );
  }
}
