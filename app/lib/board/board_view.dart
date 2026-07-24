import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';

import 'board_geometry.dart';
import 'board_painter.dart';
import 'board_theme.dart';

/// Interactive board. Renders [state]'s board (with a display-only preview of
/// partially-entered hops) and, when [interactive], drives a [MoveBuilder]
/// from taps: tap a highlighted source, then a highlighted destination;
/// Confirm commits `builder.build()` via [onMoveCommitted]; Undo removes the
/// last hop. When there are no legal moves a "No moves — pass" affordance
/// invokes [onMoveCommitted] with [Move.none].
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
class BoardView extends StatefulWidget {
  const BoardView({
    super.key,
    required this.state,
    required this.interactive,
    required this.onMoveCommitted,
    this.whiteAtBottom = true,
    this.theme, // defaults by brightness
  });

  /// The game state to render. Its board is the base of the preview.
  final GameState state;

  /// When true, taps drive a [MoveBuilder] and the overlay controls appear.
  final bool interactive;

  /// Invoked with the completed [Move] when Confirm is pressed, or with
  /// [Move.none] when the "No moves — pass" affordance is used.
  final ValueChanged<Move> onMoveCommitted;

  /// Board orientation. When false the board is rotated 180°.
  final bool whiteAtBottom;

  /// Palette override. Defaults to [BoardTheme.dark]/[BoardTheme.light] by the
  /// ambient [Theme] brightness.
  final BoardTheme? theme;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  /// Live move builder — non-null only while interactive and in the moving
  /// phase. Mutated in place (addHop/undoHop); rebuilt on any state change.
  MoveBuilder? _builder;

  /// The currently picked-up source (a point index, or [CheckerMove.bar]);
  /// null when nothing is selected and sources are highlighted for pickup.
  int? _selectedSource;

  /// Cached at builder-reset time (legalMoves runs the generator): true when
  /// the interactive moving phase has no legal play, so a Pass is offered.
  bool _isDance = false;

  @override
  void initState() {
    super.initState();
    _resetBuilder();
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

          final painter = BoardPainter(
            board: _previewBoard(),
            geometry: geometry,
            theme: theme,
            dice: widget.state.dice,
            cube: widget.state.cube,
            highlightedSources:
                (builder != null && selected == null)
                    ? builder.selectableSources
                    : const {},
            highlightedDestinations: (builder != null && selected != null)
                ? builder.destinationsFor(selected)
                : const {},
            selectedSource: selected,
          );

          final board = widget.interactive
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) =>
                      _handleTap(geometry, details.localPosition),
                  child: CustomPaint(size: size, painter: painter),
                )
              : CustomPaint(size: size, painter: painter);

          return Stack(
            children: [
              Positioned.fill(child: board),
              if (builder != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: size.height * 0.02,
                  child: _Overlay(
                    builder: builder,
                    hasDance: _isDance,
                    onUndo: () => setState(() {
                      builder.undoHop();
                      _selectedSource = null;
                    }),
                    onConfirm: () => widget.onMoveCommitted(builder.build()),
                    onPass: () => widget.onMoveCommitted(Move.none),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The bottom control row: a Pass affordance during a dance, otherwise Undo +
/// Confirm. Plain Material buttons — no custom styling.
class _Overlay extends StatelessWidget {
  const _Overlay({
    required this.builder,
    required this.hasDance,
    required this.onUndo,
    required this.onConfirm,
    required this.onPass,
  });

  final MoveBuilder builder;
  final bool hasDance;
  final VoidCallback onUndo;
  final VoidCallback onConfirm;
  final VoidCallback onPass;

  @override
  Widget build(BuildContext context) {
    if (hasDance) {
      return Center(
        child: FilledButton(
          onPressed: onPass,
          child: const Text('No moves — pass'),
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton(
          onPressed: builder.chosenHops.isNotEmpty ? onUndo : null,
          child: const Text('Undo'),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: builder.isComplete ? onConfirm : null,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
