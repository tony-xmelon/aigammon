import 'dart:math' as math;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game/applied_move.dart';
import 'board_geometry.dart';
import 'board_painter.dart';
import 'board_theme.dart';
import 'dice_usage.dart';

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

/// Toggles for the optional interaction affordances layered on top of the
/// base tap-to-move flow. Persistence of these toggles is wired by the settings
/// screen (Task 5); [BoardView] defaults to highlights ON, drag OFF, combined
/// taps ON.
class BoardInteractionOptions {
  const BoardInteractionOptions({
    this.showHighlights = true,
    this.enableDrag = false,
    this.enableCombinedTaps = true,
  });

  /// When false, the board paints NO source rings, NO selection ring, and NO
  /// destination (direct or combined) fills — a pure VISUAL gating. Taps and
  /// drags still drive move entry exactly as before; only the highlight layer is
  /// suppressed. When true (the default) highlights render normally.
  final bool showHighlights;

  /// When true, a pan gesture that starts on a selectable source's top checker
  /// lifts it and drops it on the released location (a drag-to-move). When
  /// false, no pan recogniser is attached at all: nothing is ever lifted and a
  /// travelling press falls through to the tap handler, which reads it as a tap
  /// on the point the finger came down on (see
  /// `_BoardViewState._tapDownPosition`).
  final bool enableDrag;

  /// When true, combined (multi-hop, same-checker) landings are highlighted (a
  /// dimmer variant) alongside the direct destinations, and tapping / dropping
  /// on one enters the WHOLE chain at once.
  final bool enableCombinedTaps;

  @override
  bool operator ==(Object other) =>
      other is BoardInteractionOptions &&
      other.showHighlights == showHighlights &&
      other.enableDrag == enableDrag &&
      other.enableCombinedTaps == enableCombinedTaps;

  @override
  int get hashCode =>
      Object.hash(showHighlights, enableDrag, enableCombinedTaps);
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
/// ## Move animation ([lastMove] / [hopDuration] / [interHopDuration])
///
/// When [lastMove] fires a non-null [AppliedMove], the view plays a purely
/// cosmetic animation: the moved checker travels hop-by-hop from source to
/// destination while the board underneath shows the position with the earlier
/// hops applied and the travelling checker suppressed (see [BoardPainter]'s
/// `hiddenChecker`/`overlayChecker`).
///
/// The animation's base position is the [AppliedMove.preBoard] the controller
/// publishes WITH the move — never [state]'s board as of the fire. That
/// distinction is the whole point of [AppliedMove]: the controller routinely
/// advances several events (a commit, the opponent's roll, the opponent's reply)
/// between two painted frames, so at fire time [state] may be older than the
/// move's true starting position. Basing the animation on it froze the board at
/// a position that predated the user's OWN committed move, which then appeared
/// to un-happen and be replayed when the animation ended.
///
/// ## Gating the animation by ENTRY SOURCE (no self-replay)
///
/// A move the user just entered HOP-BY-HOP on this device's board (by tapping or
/// dragging the checkers) must NOT be replayed as an animation — the user already
/// performed that travel live, so replaying it feels like a stutter (the reported
/// bug). A move that was NOT hand-entered here still animates: the AI's reply, a
/// remote opponent's move (folded from the server), and a tap-to-apply tutor hint
/// (staged PROGRAMMATICALLY via [externalMove], not dragged by the user).
///
/// The distinguishing signal is captured AT THE COMMIT SITE, entirely inside this
/// widget — the one place that sees the difference between hops added by user
/// gestures and a whole move staged externally. [_confirm] sets a one-shot
/// [_suppressNextCommitAnimation] flag whenever the committed move was NOT staged
/// from [externalMove] (i.e. it was hand-entered). The FIRST [lastMove] to fire
/// after a local commit is that very commit, so [_onLastMove] consumes the flag
/// and skips the replay for it; every later move (the opponent's) fires with the
/// flag clear and animates normally. This is source-based, not mover-based, so it
/// holds across vs-AI (human's own moves are hand-entered here; the AI's are not),
/// hot-seat (BOTH sides are hand-entered on this board — neither replays), and
/// online (the local side is hand-entered; the remote side folds in and animates).
///
/// Timing: [hopDuration] per hop with an [interHopDuration] stationary pause
/// BETWEEN hops, so the controller's total is `n·hop + (n-1)·interHop` with NO
/// cap (a long multi-hop play travels fully rather than being squeezed into a
/// fixed budget), [Curves.easeInOut] per hop. Animation is DISABLED — the
/// post-move board snaps in immediately — when [hopDuration] is [Duration.zero]
/// or the ambient [MediaQuery.disableAnimations] is set. Input is never blocked:
/// taps flow to the current (post-move) state; the animation is decoration only.
///
/// ## Holding the move animation ([holdMoveAnimation])
///
/// When an opponent rolls, the game screen first plays a dice-roll beat (see
/// [GameScreen]) and a settle pause; the moved checker must not start travelling
/// until the dice are readable. The screen exposes that gate as a
/// [ValueListenable<bool>] passed as [holdMoveAnimation]: while it is `true` a
/// fired [lastMove] is QUEUED rather than started, and the queued move begins as
/// soon as it flips `false`. Only the LATEST queued move is kept (in practice a
/// turn produces one move). When [holdMoveAnimation] is null or already `false`
/// (e.g. the local player's own move — no beat), the animation starts at once.
///
/// ## Tapping the dice to roll ([onDiceTap])
///
/// At the local player's pre-roll gate the board is NOT interactive (no move is
/// pending), but the dice are the obvious thing to reach for — so the screen
/// hands in an [onDiceTap] and a tap on either pair rolls. Gestures are
/// therefore attached whenever [interactive] OR [onDiceTap] is live, and the tap
/// router checks the dice hit boxes FIRST. Because the callback is null at every
/// other moment, move entry is untouched: during the moving phase a tap on the
/// dice area is exactly the "nothing actionable" tap it has always been.
///
/// The affordance is NOT painted. A ring/glow around the pair was tried and read
/// as an alarm rather than an invitation ("the yellow highlight around my dice is
/// unnecessary and confusing"), so the dice look identical whether or not they
/// are tappable; the Roll button is the discoverable control, and the dice tap is
/// a shortcut for people who reach for them anyway.
///
/// ## Double-tap to play a hop ([doubleTapWindow])
///
/// Tapping a checker picks it up; tapping it AGAIN within [doubleTapWindow]
/// plays a hop from it outright — the higher remaining die when that is legal
/// from this checker, else the lower. Detection is manual (a timestamp plus a
/// same-target check inside the existing tap handler) rather than
/// [GestureDetector.onDoubleTap], because that recogniser delays EVERY single
/// tap by its timeout; selection must stay instant.
///
/// Only a tap that SELECTED a source arms it, and a tap is consumed only when
/// the quick hop actually applies — so no tap that would advance move entry can
/// ever be swallowed by the detector (see [_BoardViewState._consumeDoubleTap]).
/// Completing a hop and then starting the next one from the same point is
/// therefore an ordinary pickup, however fast it arrives.
///
/// ## Sloppy taps still count ([_BoardViewState._tapDownPosition])
///
/// A press that slid a few millimetres — routine for a thumb on a phone — used to
/// fall into the gap between Flutter's tap and pan recognisers and vanish. The
/// recognisers are wired by hand so a gesture that never became a drag is always
/// delivered as a tap, routed by the point the finger came DOWN on.
///
/// ## Which pair is lit ([activeDiceSide])
///
/// Both players keep a persistent pair in a FIXED position (see
/// [BoardGeometry.diceRect]); which one is lit is told to the board by its owner
/// through [activeDiceSide], and means "this roll is live" — the roller while a
/// roll is being presented, the mover while a move is being entered, and nobody
/// (both pairs dim) at every quiet moment in between. The board never infers it
/// from [state]`.turn`; see [BoardPainter.activeDiceSide] for the two ways that
/// was wrong.
///
/// ## Played dice read as spent ([BoardPainter.usedDiceSlots])
///
/// While a move is being entered, the dice the staged hops have consumed render
/// heavily dimmed on the mover's own pair (see `dice_usage.dart` for the hop →
/// die mapping; doubles dim progressively, since four hops share two painted
/// dice). Undo restores the brightness, because the set is recomputed from the
/// builder on every paint rather than latched. The spent dimming sits BENEATH the
/// pair emphasis: it only ever applies to the [activeDiceSide]'s own pair.
///
/// ## Responsive sizing ([minAspect] / [maxAspect])
///
/// The board FILLS the slot its parent gives it, clamped to an aspect range —
/// it is not pinned to a landscape shape. On a phone in portrait the slot
/// between the header and the bottom strip is much taller than it is wide, so
/// the board comes out TALLER than wide (down to [minAspect]); on a wide window
/// it stops widening at [maxAspect] rather than stretching. See [boardSizeFor],
/// and [BoardGeometry]'s "Aspect independence" note for how the geometry adapts
/// (checkers sized by column width, triangle length capped, dice growing into
/// the roomier middle band).
///
/// The "board never reflows" invariant survives: the slot is fixed for a given
/// screen (a fixed-height HUD above, and below it a fixed-height score sheet and
/// action bar), so the board size is constant while the screen is —
/// nothing those regions do mid-turn can resize it.
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
    this.holdMoveAnimation,
    this.entryControl,
    this.hopDuration = const Duration(milliseconds: 150),
    this.interHopDuration = Duration.zero,
    this.interactionOptions = const BoardInteractionOptions(),
    this.whiteDice,
    this.blackDice,
    this.diceOverride,
    this.activeDiceSide,
    this.showCube = true,
    this.highlightedSources = const {},
    this.highlightedDestinations = const {},
    this.strongHighlightSources = const {},
    this.highlightMovingPlayer,
    this.onDiceTap,
    this.onMoveAnimation,
    this.onNoLegalSourceTap,
    this.doubleTapWindow = const Duration(milliseconds: 300),
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

  /// Stream of applied moves to animate (from `MatchController.lastMove`). Each
  /// non-null fire plays a cosmetic hop-by-hop travel of the moved checker over
  /// the [AppliedMove.preBoard] it carries. See the class doc for timing.
  final ValueListenable<AppliedMove?>? lastMove;

  /// Gate that HOLDS the move animation while `true`: a [lastMove] fired during
  /// the hold is queued (latest wins) and started when this flips `false`. Used
  /// by the game screen to keep the opponent's checker from moving until the
  /// dice-roll beat + settle pause finishes. Null (or already `false`) means the
  /// animation starts immediately. See the class doc.
  final ValueListenable<bool>? holdMoveAnimation;

  /// Optional external bridge for the move-entry controls. When provided, the
  /// board mirrors its live builder affordances onto it and honours its
  /// [BoardEntryController.undo] / [BoardEntryController.confirm] /
  /// [BoardEntryController.pass] actions, letting the consumer render the
  /// buttons in its own layout instead of on the board.
  final BoardEntryController? entryControl;

  /// Duration of each hop's travel (default 150ms). [Duration.zero] disables
  /// animation entirely (the post-move board snaps in), as does an ambient
  /// [MediaQuery.disableAnimations].
  final Duration hopDuration;

  /// Stationary pause inserted BETWEEN consecutive hops of a move (default
  /// zero). The controller's total duration is `n·hop + (n-1)·interHop`; there
  /// is no cap. See the class doc.
  final Duration interHopDuration;

  /// Palette override. Defaults to [BoardTheme.dark]/[BoardTheme.light] by the
  /// ambient [Theme] brightness.
  final BoardTheme? theme;

  /// Toggles for drag-to-move and combined-move taps. See
  /// [BoardInteractionOptions].
  final BoardInteractionOptions interactionOptions;

  /// WHITE's persistent dice pair — the most recent roll to show on White's
  /// dice, or `null` when White has not rolled yet this game (a blank dimmed
  /// outline). Each player keeps their OWN pair so the opponent's roll stays
  /// visible after the turn passes. See [BoardPainter.whiteDice].
  final Dice? whiteDice;

  /// BLACK's persistent dice pair (see [whiteDice]).
  final Dice? blackDice;

  /// Whether the doubling cube is PAINTED on the bar. False in a cubeless match,
  /// where the painter is handed no [CubeState] at all so no cube glyph is drawn
  /// — the reported "I selected game without a cube but cube is still showing".
  ///
  /// A display flag, not a rule: [GameState.cube] still exists (it is part of the
  /// core state and stays at ×1, centred, for the whole match), and the cube is
  /// suppressed at its three surfaces together — this marker, the header chip and
  /// the Double button. Defaults to true so every other call site (analysis,
  /// replay, the board's own tests) is unaffected.
  final bool showCube;

  /// When non-null, `faces` REPLACES `roller`'s dice pair on the painted board —
  /// purely cosmetic. Used by the opponent dice-roll animation beat (see
  /// `GameScreen`), which cycles pseudo-random faces for ~840ms before the real
  /// roll settles (the override then clears back to `null`). Applies ONLY to
  /// `roller`; the other pair stays static with its persisted roll. Never
  /// affects move entry or state.
  ///
  /// The roller is carried HERE, as data, rather than inferred from
  /// [state]`.turn`: by the time a beat runs, the turn may already have advanced
  /// past the roller. In vs-AI play that is the normal case — the AI's
  /// [RollEvent], its [MoveEvent] and the turn advance back to the human all
  /// fold inside one microtask chain, with no frame painted in between, so
  /// `state.turn` is the HUMAN while the AI's roll is still tumbling. Inferring
  /// the roller there put the opponent's tumbling faces on the human's own pair
  /// (the "the app replays MY dice animation during the opponent's move"
  /// regression). Same failure mode, and same fix, as [AppliedMove].
  final ({Player roller, Dice faces})? diceOverride;

  /// The side whose dice pair is EMPHASISED (painted at full opacity while the
  /// other is dimmed); `null` dims both. Passed straight to
  /// [BoardPainter.activeDiceSide] — see there for why this is stated by the
  /// caller rather than derived from [state]`.turn`, and why the caller is the
  /// only thing that knows it (it owns the roll beat and therefore the
  /// presentation). Pair POSITIONS do not depend on it: each is anchored per
  /// player (see [BoardGeometry.diceRect]).
  final Player? activeDiceSide;

  /// Static SOURCE highlights to paint (point index 0..23, or [CheckerMove.bar])
  /// — a subtle ring on each location's top checker. Used by the NON-interactive
  /// replay/analysis board to draw a recorded move's origins over the pre-move
  /// position; ignored in the interactive moving phase, where the live builder
  /// owns the highlight layer. See [BoardPainter.highlightedSources].
  final Set<int> highlightedSources;

  /// Static DESTINATION highlights to paint (point index 0..23, or
  /// [CheckerMove.off]) — a triangle/tray fill on each target. The replay board's
  /// recorded-move landings; ignored while interactive (see [highlightedSources]).
  final Set<int> highlightedDestinations;

  /// Static STRONG source highlights (point index 0..23, or [CheckerMove.bar]):
  /// each location's top checker wears the same bright yellow ring the live
  /// selection uses, rather than the thin "could be picked up" ring. Used by the
  /// analysis screen so the checker(s) a recorded play MOVES are unmistakable.
  /// Ignored while interactive. See [BoardPainter.strongHighlightLocations].
  final Set<int> strongHighlightSources;

  /// The side a static overlay's move belongs to, so a bar source or an `off`
  /// destination resolves to the correct half. Required for those to render;
  /// ignored while interactive (the builder supplies the moving player).
  final Player? highlightMovingPlayer;

  /// Rolls the dice — wired ONLY while the local player is at the pre-roll gate
  /// (the same condition that enables the screen's Roll button); `null` at every
  /// other moment.
  ///
  /// When non-null a tap inside EITHER dice pair's generous hit box
  /// ([BoardGeometry.diceTapRect]) fires this instead of running move entry (the
  /// Roll button stays put regardless). The affordance is deliberately NOT
  /// painted — see the class doc. When null the dice areas behave exactly as
  /// before — a tap there falls through to normal move-entry handling — so this
  /// can never interfere with entering a move.
  final VoidCallback? onDiceTap;

  /// Fired whenever the cosmetic move animation starts or stops: the animating
  /// move's PLAYER while a checker is travelling, and `null` the moment it is
  /// done (or is abandoned because a drag lifted a checker).
  ///
  /// The board owns the animation's timeline — its duration depends on the hop
  /// count — so a consumer that needs to know whether one is running cannot
  /// compute it without duplicating that timeline. The game screen needs exactly
  /// this to keep the mover's dice pair lit for as long as their play is being
  /// presented (see [activeDiceSide]).
  final ValueChanged<Player?>? onMoveAnimation;

  /// Called when the user taps one of their OWN checkers that is not a legal
  /// source with the dice still in hand — the silent no-op behind the reported
  /// "why am I not able to move the 7?" confusion. The argument is whether a
  /// PARTIAL move is already staged, so the caller can add a "try Undo" nudge.
  ///
  /// Fires only for a genuine own-checker miss: taps on empty felt, on the
  /// opponent's checkers, or that resolve to a legal source / destination are
  /// silent as before.
  final ValueChanged<bool>? onNoLegalSourceTap;

  /// How close together two taps on the SAME checker must be to count as a
  /// double-tap (which plays a hop immediately — see [_applyQuickHop]).
  ///
  /// Detection is manual, on the existing tap handler, rather than through
  /// [GestureDetector.onDoubleTap]: that recogniser delays every single tap by
  /// the double-tap timeout, which would have made ordinary selection feel
  /// sluggish. [Duration.zero] disables double-tap entirely.
  final Duration doubleTapWindow;

  /// Narrowest (tallest) shape the board may take, as width : height.
  ///
  /// A phone in portrait leaves a slot around 0.58 wide : tall, so this bound
  /// deliberately sits BELOW that: the board fills its slot outright instead of
  /// letterboxing ~24pt of dead space above and below it (the "we need every
  /// pixel of screen space" complaint — the horizontal padding was only half of
  /// it). The extra height is absorbed by the triangles, whose length cap
  /// (`BoardGeometry._maxPointRadii`) grew with this bound; past ~0.55 the
  /// triangles stop growing and the surplus would go to the empty middle band,
  /// so the clamp holds there.
  static const double minAspect = 0.55;

  /// Widest shape the board may take, as width : height. Past this the checkers
  /// (height-bound on a wide board) stop growing and only the gaps between the
  /// columns would widen, so a very wide slot letterboxes at the sides instead.
  static const double maxAspect = 1.45;

  /// Shape used when a dimension is unbounded (a board inside a scroll view):
  /// roughly where the column-width and point-height bounds on the checker
  /// radius meet, i.e. the most "efficient" board.
  static const double naturalAspect = 1.2;

  /// The board's paint size within [constraints]: the largest rectangle that
  /// fits, with its aspect clamped to [minAspect] … [maxAspect]. An unbounded
  /// dimension falls back to [naturalAspect] (and, with both unbounded, to a
  /// nominal 320pt width) so the board is never laid out unbounded.
  static Size boardSizeFor(BoxConstraints constraints) {
    const double fallbackWidth = 320;
    final bool boundedW = constraints.hasBoundedWidth;
    final bool boundedH = constraints.hasBoundedHeight;
    final double maxW = constraints.maxWidth;
    final double maxH = constraints.maxHeight;
    double w;
    double h;
    if (boundedW && boundedH && maxW > 0 && maxH > 0) {
      final available = maxW / maxH;
      final aspect = available.clamp(minAspect, maxAspect);
      if (available > aspect) {
        // The slot is wider than the board is allowed to be: height binds.
        h = maxH;
        w = h * aspect;
      } else {
        // The slot is taller than the board is allowed to be (or exactly the
        // right shape): width binds and the board takes the height it may.
        w = maxW;
        h = w / aspect;
      }
    } else if (boundedW && maxW > 0) {
      w = maxW;
      h = w / naturalAspect;
    } else if (boundedH && maxH > 0) {
      h = maxH;
      w = h * naturalAspect;
    } else {
      w = fallbackWidth;
      h = w / naturalAspect;
    }
    // A degenerate (zero-sized) slot would trip BoardGeometry's positive-size
    // assertion; hand back a nominal 1pt board instead.
    return Size(math.max(1, w), math.max(1, h));
  }

  @override
  State<BoardView> createState() => _BoardViewState();
}

/// The pre-move board plus the ordered hops of the move currently animating.
class _BoardAnimation {
  _BoardAnimation(this.preBoard, this.hops, this.player);

  /// The board BEFORE the animated move, as published with it (see
  /// [AppliedMove.preBoard]).
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

  /// A move captured while [BoardView.holdMoveAnimation] was `true`, waiting for
  /// the hold to release before it starts. Only the LATEST is kept.
  _BoardAnimation? _pendingAnimation;

  /// Monotonic guard so a superseded animation's completion callback (fired when
  /// a new move restarts the controller) does not clear a fresh animation.
  int _animSeq = 0;

  /// Whether the CURRENT move-entry builder holds a move that was staged
  /// PROGRAMMATICALLY (a tap-to-apply hint via [BoardView.externalMove]) rather
  /// than entered hop-by-hop by the user. Defaults to `false` (a fresh builder is
  /// hand entry); [_applyExternalMove] sets it `true`, and any manual tap / drag /
  /// undo flips it back to `false`. Read at [_confirm] to decide whether the
  /// committed move should still animate. See the "Gating the animation" class doc.
  bool _stagedFromExternal = false;

  /// One-shot latch: set by [_confirm] when the user commits a move they entered
  /// hop-by-hop on this board. The next [lastMove] to fire is that very commit;
  /// [_onLastMove] consumes this to SKIP the cosmetic replay (the user already
  /// performed the move live). See the "Gating the animation" class doc.
  bool _suppressNextCommitAnimation = false;

  /// The source (point index or [CheckerMove.bar]) currently being dragged, or
  /// `null` when no drag is in progress. Only set when drag is enabled and a
  /// pan started on a selectable source's top checker.
  int? _dragSource;

  /// Current pointer position of the in-progress drag (board-local), where the
  /// lifted checker's ghost is painted. `null` when not dragging.
  Offset? _dragPointer;

  /// Wall-clock time the double-tap detector was ARMED — i.e. of the tap that
  /// picked [_lastTapTarget] up. `null` whenever the detector is disarmed, which
  /// is after every tap that did not leave a source selected. See
  /// [_armDoubleTap] / [_consumeDoubleTap].
  DateTime? _lastTapAt;

  /// The source the arming tap picked up; a second tap on THIS checker is what
  /// the double-tap detector looks for. `null` when disarmed.
  int? _lastTapTarget;

  /// Where the finger came DOWN for the tap in progress (board-local), and the
  /// reason the recognisers are wired by hand (see the [RawGestureDetector] in
  /// [build]).
  ///
  /// A press drifts. Flutter's tap recogniser abandons one as soon as the finger
  /// has moved [kTouchSlop] (18pt), while the pan recogniser only claims the
  /// gesture at [kPanSlop] (36pt) — so with drag enabled (the shipped default) a
  /// press that slid 18-36pt was dropped by BOTH: no selection, no hop, no hint,
  /// nothing. A thumb on a phone-sized board slides that far constantly, which is
  /// the other half of "I cannot move a valid move".
  ///
  /// Both tap tolerances are therefore switched off, which makes the split the
  /// one the user intends: travel far enough and the PAN claims the gesture (a
  /// drag); otherwise the tap survives to the release. It is then routed by THIS
  /// position — where the user aimed — rather than by where the finger left the
  /// glass, and the tap's own forgiveness ([_tapTolerance]) resolves what that
  /// addressed. With drag disabled there is no pan to claim anything, so even a
  /// long swipe arrives as a tap on the checker it started on.
  ///
  /// `null` between taps.
  Offset? _tapDownPosition;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this)..addListener(_onAnimTick);
    _resetBuilder();
    widget.externalMove?.addListener(_applyExternalMove);
    widget.lastMove?.addListener(_onLastMove);
    widget.holdMoveAnimation?.addListener(_onHoldChanged);
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
    if (!identical(oldWidget.holdMoveAnimation, widget.holdMoveAnimation)) {
      oldWidget.holdMoveAnimation?.removeListener(_onHoldChanged);
      widget.holdMoveAnimation?.addListener(_onHoldChanged);
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
    widget.holdMoveAnimation?.removeListener(_onHoldChanged);
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
      _stagedFromExternal = false; // a manual undo makes this hand entry
    });
    _disarmDoubleTap(); // nothing is picked up any more
    _syncEntry();
  }

  /// Commits the staged move (external Confirm). No-op unless a full legal move
  /// is entered.
  void _confirm() {
    final builder = _builder;
    if (builder == null || !builder.isComplete) return;
    // A move entered hop-by-hop on this board (tap/drag) must not be replayed as
    // an animation — the user just performed it live. Flag the imminent lastMove
    // fire so [_onLastMove] skips it. A move STAGED from [externalMove] (a
    // tap-to-apply hint) was not hand-entered, so it is left to animate.
    if (!_stagedFromExternal) _suppressNextCommitAnimation = true;
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
    if (widget.hopDuration <= Duration.zero) return false;
    final mq = MediaQuery.maybeOf(context);
    return mq == null || !mq.disableAnimations;
  }

  /// Reacts to a fired [BoardView.lastMove]: plays the hop-by-hop travel over
  /// the board the move was applied to. Skipped when animations are disabled or
  /// the move is an empty pass. When [BoardView.holdMoveAnimation] is `true` the
  /// move is QUEUED (latest wins) and started only when the hold releases (see
  /// [_onHoldChanged]); otherwise it starts immediately.
  void _onLastMove() {
    final applied = widget.lastMove?.value;
    if (applied == null) return;
    // One-shot: the first move to land after a hand-entered commit IS that
    // commit. Skip its cosmetic replay (the user just performed it live on the
    // board). Consumed before the enabled/empty guards so it never leaks onto a
    // later (opponent) move.
    if (_suppressNextCommitAnimation) {
      _suppressNextCommitAnimation = false;
      return;
    }
    if (!_animationsEnabled) return;
    final hops = applied.move.checkerMoves;
    if (hops.isEmpty) return; // a pass: nothing to animate
    // The move carries the board it was applied to: the animation's base is that
    // position, NOT [widget.state]'s board (which lags by however many events
    // the controller advanced since the last painted frame).
    final anim = _BoardAnimation(applied.preBoard, hops, applied.player);
    if (widget.holdMoveAnimation?.value ?? false) {
      _pendingAnimation = anim; // held: queue it, latest wins
      return;
    }
    _startAnimation(anim);
  }

  /// Reacts to [BoardView.holdMoveAnimation] flipping: when it releases
  /// (`false`) and a move was queued during the hold, start it now.
  void _onHoldChanged() {
    final held = widget.holdMoveAnimation?.value ?? false;
    if (held) return;
    final pending = _pendingAnimation;
    if (pending == null) return;
    _pendingAnimation = null;
    _startAnimation(pending);
  }

  /// Runs the controller for [anim]: repaints hop-by-hop, then clears the
  /// animation on completion. A rapid follow-up restarts the controller; the old
  /// completion callback is fenced out by [_animSeq].
  void _startAnimation(_BoardAnimation anim) {
    final seq = ++_animSeq;
    setState(() => _animation = anim);
    widget.onMoveAnimation?.call(anim.player);
    _animController
      ..stop()
      ..duration = _totalDuration(anim.hops.length)
      ..value = 0
      ..forward().whenComplete(() {
        if (!mounted || seq != _animSeq) return;
        setState(() => _animation = null);
        widget.onMoveAnimation?.call(null);
      });
  }

  /// Total animation time: `n·hop + (n-1)·interHop` (per-hop travel plus the
  /// stationary pauses between hops). No cap — a long multi-hop play travels in
  /// full.
  Duration _totalDuration(int hopCount) =>
      widget.hopDuration * hopCount +
      widget.interHopDuration * (hopCount - 1);

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
        // Staged programmatically (a tap-to-apply hint): the user did not enter
        // these hops by hand, so the committed move should still animate.
        _stagedFromExternal = true;
      } on ArgumentError {
        builder.reset(); // stale/illegal move: leave a clean base position
        _stagedFromExternal = false;
      }
    });
    _syncEntry();
  }

  /// Creates a fresh builder from the current legal moves (or clears it) and
  /// drops any in-progress selection. A builder exists only in the interactive
  /// moving phase; in a dance it exists but offers no sources.
  void _resetBuilder() {
    _selectedSource = null;
    _dragSource = null;
    _dragPointer = null;
    _disarmDoubleTap(); // a new position never inherits a half-finished pair
    _tapDownPosition = null;
    _stagedFromExternal = false; // a fresh phase defaults to hand entry
    if (widget.interactive && widget.state.phase == GamePhase.moving) {
      // POSITION-AWARE: every playable way to enter each legal move is offered,
      // so the checker just moved with one die can still play the other, and no
      // unplayable (phantom) source is ever offered. See MoveBuilder.forState.
      final builder = MoveBuilder.forState(widget.state);
      _builder = builder;
      // A fresh builder with nothing chosen offers no sources only when there is
      // no legal move at all — a dance.
      _isDance = builder.selectableSources.isEmpty;
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
    // Map the controller's 0→1 progress onto a timeline of hop-travel segments
    // separated by stationary inter-hop pauses: each hop occupies [hop] of
    // travel, then [interHop] of rest (checker sitting at the landing) before
    // the next hop. During a pause the local progress clamps to 1.0 so the
    // overlay is stationary at the hop's destination.
    final hopUs = widget.hopDuration.inMicroseconds;
    final interUs = widget.interHopDuration.inMicroseconds;
    final cycleUs = hopUs + interUs;
    final totalUs = _totalDuration(n).inMicroseconds;
    final elapsedUs = _animController.value * totalUs;
    final int hopIndex;
    final double localT;
    if (cycleUs <= 0) {
      hopIndex = n - 1;
      localT = 1.0;
    } else {
      hopIndex = (elapsedUs / cycleUs).floor().clamp(0, n - 1);
      final withinUs = elapsedUs - hopIndex * cycleUs;
      localT = hopUs <= 0 ? 1.0 : (withinUs / hopUs).clamp(0.0, 1.0);
    }
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

  /// Whether [localPosition] lands on either player's dice pair (the padded
  /// [BoardGeometry.diceTapRect]). Both pairs are live so the user can tap
  /// whichever dice they were looking at.
  bool _isDiceTap(BoardGeometry geometry, Offset localPosition) {
    for (final player in Player.values) {
      if (geometry.diceTapRect(player).contains(localPosition)) return true;
    }
    return false;
  }

  /// Routes a tap: at the pre-roll gate ([BoardView.onDiceTap] wired) a tap on
  /// either dice pair rolls; a DOUBLE-tap on the checker already picked up plays
  /// a hop outright; everything else goes to move entry.
  void _onTapUp(BoardGeometry geometry, Offset localPosition) {
    _tapDownPosition = null; // consumed: the next tap records its own
    final roll = widget.onDiceTap;
    if (roll != null && _isDiceTap(geometry, localPosition)) {
      roll();
      return;
    }
    if (_consumeDoubleTap(geometry, localPosition)) return;
    _handleTap(geometry, localPosition);
  }

  /// Manual double-tap detection: returns true when this tap completed a
  /// double-tap that PLAYED a hop (so the caller must not also run normal tap
  /// handling).
  ///
  /// ## A tap can never be eaten
  ///
  /// The detector is ARMED only by a tap that SELECTED a source (see
  /// [_armDoubleTap], called from [_handleTap]); every other tap — a destination
  /// tap that staged a hop, a deselect, a tap on dead felt — leaves it disarmed,
  /// so nothing but "pick a checker up, tap it again" can even be a candidate.
  /// Each further condition below must also hold, and the LAST of them is the
  /// invariant that matters: the tap is consumed only when the quick hop really
  /// applies. If any check fails the tap falls through to [_handleTap] unchanged,
  /// so a tap that would advance move entry is never swallowed.
  ///
  /// * the pickup must still be live ([_selectedSource]) and still selectable —
  ///   so "complete a hop here, then start the next hop from the same point"
  ///   stays an ordinary pickup however fast it arrives (a staged hop clears the
  ///   selection AND disarms);
  /// * the tap must land on that same checker ([_tapTarget]);
  /// * and it must NOT address one of that source's destinations — a genuine MOVE
  ///   is never stolen. A destination one column over from the picked-up checker
  ///   sits inside the tap-forgiveness radius (at least 22pt), so [_tapTarget]
  ///   resolves a tap on its triangle back to the source; without this check,
  ///   quickly tapping the 1's triangle of a 6-1 played the 6 instead — a wrong
  ///   move, entered silently. Destination handling wins, exactly as in
  ///   [_handleTap].
  bool _consumeDoubleTap(BoardGeometry geometry, Offset localPosition) {
    final builder = _builder;
    final armedAt = _lastTapAt;
    final armedTarget = _lastTapTarget;
    // Whatever happens, this tap does not stay armed: a double-tap fires at most
    // once per pair, and a third quick tap starts a fresh pair.
    _disarmDoubleTap();
    if (builder == null || armedAt == null || armedTarget == null) return false;
    final window = widget.doubleTapWindow;
    if (window <= Duration.zero) return false;
    if (DateTime.now().difference(armedAt) > window) return false;
    if (_selectedSource != armedTarget) return false;
    if (!builder.selectableSources.contains(armedTarget)) return false;
    if (_tapTarget(geometry, localPosition, builder) != armedTarget) return false;
    if (_addressesDestination(geometry, localPosition, builder, armedTarget)) {
      return false;
    }
    // The decisive guard: consume the tap only when there is a hop to play.
    final destination =
        highestDieDestination(builder, armedTarget, widget.state.turn);
    if (destination == null) return false;
    _applyQuickHop(builder, armedTarget, destination);
    return true;
  }

  /// Arms the double-tap detector on [source], which this tap just picked up.
  void _armDoubleTap(int source) {
    _lastTapAt = DateTime.now();
    _lastTapTarget = source;
  }

  /// Disarms the detector: the next tap starts a fresh pair.
  void _disarmDoubleTap() {
    _lastTapAt = null;
    _lastTapTarget = null;
  }

  /// Whether a tap at [pos] would be read as a MOVE for the picked-up [source] —
  /// a direct destination or a combined landing, by exact hit or by the same
  /// forgiveness [_handleTap] applies. Mirrors [_handleTap]'s precedence so the
  /// two can never disagree about what a tap means.
  bool _addressesDestination(
      BoardGeometry geometry, Offset pos, MoveBuilder builder, int source) {
    final loc = geometry.locationAt(pos);
    final chained = _chainedDestinations(builder, source);
    if (loc != null &&
        (builder.destinationsFor(source).contains(loc) ||
            chained.contains(loc))) {
      return true;
    }
    return _nearestDestination(geometry, pos, builder, source) != null ||
        _nearestTarget(geometry, pos, chained) != null;
  }

  /// The location a tap at [pos] addresses for double-tap purposes: the exact
  /// hit when it is a selectable source, else the nearest forgiven source, else
  /// the raw hit-tested location (so two taps on the same dead point still pair
  /// up and can be answered with the "no legal move" hint).
  int? _tapTarget(BoardGeometry geometry, Offset pos, MoveBuilder builder) {
    final loc = geometry.locationAt(pos);
    if (loc != null && builder.selectableSources.contains(loc)) return loc;
    return _nearestSource(geometry, pos, builder) ?? loc;
  }

  /// Plays the hop [source] → [destination] immediately (the double-tap's
  /// quick hop; [highestDieDestination] chooses the destination — the HIGHER
  /// remaining die when that is legal from this checker, else the lower).
  void _applyQuickHop(MoveBuilder builder, int source, int destination) {
    setState(() {
      _stagedFromExternal = false; // a manual gesture makes this hand entry
      builder.addHop(source, destination);
      _selectedSource = null;
    });
    _syncEntry();
  }

  /// Handles a tap. Selection semantics live on the CHECKERS; move targets on
  /// the destination TRIANGLES. The exact hit-tested [BoardGeometry.locationAt]
  /// is tried first; when it is not a directly-actionable target the tap is
  /// forgiven to the NEAREST actionable target (a selectable source's top
  /// checker, or a highlighted destination's region centre) within
  /// [BoardGeometry.checkerRadius] * 1.8. Taps near nothing actionable clear the
  /// selection.
  void _handleTap(BoardGeometry geometry, Offset localPosition) {
    final builder = _builder;
    if (builder == null) return;
    final loc = geometry.locationAt(localPosition);
    // Set by the branches that end with nothing picked up and no hop played, so
    // a tap on one of the mover's OWN checkers that simply cannot move is
    // answered with a hint instead of the old silent no-op.
    var missed = false;
    setState(() {
      // Any manual tap interaction marks the entry as hand-driven; a later hint
      // re-stage would flip it back via [_applyExternalMove].
      _stagedFromExternal = false;
      final selected = _selectedSource;
      if (selected == null) {
        // Nothing picked up: pick up a source. Direct hit first, then forgive to
        // the nearest selectable source's checker.
        if (loc != null && builder.selectableSources.contains(loc)) {
          _selectedSource = loc;
        } else {
          _selectedSource = _nearestSource(geometry, localPosition, builder);
          missed = _selectedSource == null && _isOwnChecker(loc);
        }
        return;
      }
      // A source is picked up. Prefer completing a hop on a direct destination.
      if (loc != null && builder.destinationsFor(selected).contains(loc)) {
        builder.addHop(selected, loc);
        _selectedSource = null;
        return;
      }
      // Then a combined (multi-hop) landing: enter the whole chain at once.
      final chained = _chainedDestinations(builder, selected);
      if (loc != null && chained.contains(loc)) {
        _enterChain(builder, selected, loc);
        _selectedSource = null;
        return;
      }
      // Re-tapping the picked-up source deselects it — but only a SLOW re-tap
      // gets here: a re-tap inside [BoardView.doubleTapWindow] that has a hop to
      // play is claimed by [_consumeDoubleTap] and plays it instead.
      if (loc == selected) {
        _selectedSource = null;
        return;
      }
      // Direct hit on another selectable source switches pickup.
      if (loc != null && builder.selectableSources.contains(loc)) {
        _selectedSource = loc;
        return;
      }
      // Forgiving fallbacks: a near direct destination completes the hop; then a
      // near combined landing enters the chain; else a near source re-selects;
      // else the tap hit nothing actionable, so clear.
      final nearDest =
          _nearestDestination(geometry, localPosition, builder, selected);
      if (nearDest != null) {
        builder.addHop(selected, nearDest);
        _selectedSource = null;
        return;
      }
      final nearChain =
          _nearestTarget(geometry, localPosition, chained);
      if (nearChain != null) {
        _enterChain(builder, selected, nearChain);
        _selectedSource = null;
        return;
      }
      _selectedSource = _nearestSource(geometry, localPosition, builder);
      missed = _selectedSource == null && _isOwnChecker(loc);
    });
    // A tap that leaves a source PICKED UP is a selection tap — the only kind
    // that arms the double-tap detector. Every hop-staging branch above clears
    // the selection, so this reads the outcome without tracking it by hand.
    final picked = _selectedSource;
    if (picked != null) {
      _armDoubleTap(picked);
    } else {
      _disarmDoubleTap();
    }
    _syncEntry();
    if (missed) {
      widget.onNoLegalSourceTap?.call(builder.chosenHops.isNotEmpty);
    }
  }

  /// Whether [loc] holds at least one of the MOVER's own checkers on the preview
  /// board — i.e. whether the user plausibly meant "move this checker of mine".
  bool _isOwnChecker(int? loc) {
    if (loc == null) return false;
    final turn = widget.state.turn;
    final board = _previewBoard();
    if (loc == CheckerMove.bar) return board.barFor(turn) > 0;
    if (loc < 0 || loc >= 24) return false;
    final count = board.points[loc];
    return turn == Player.white ? count > 0 : count < 0;
  }

  /// The combined-move landing points for [source] when combined taps are
  /// enabled, with any point that is already a DIRECT destination removed (the
  /// bright single-hop highlight wins). Empty when combined taps are off.
  Set<int> _chainedDestinations(MoveBuilder builder, int source) {
    if (!widget.interactionOptions.enableCombinedTaps) return const {};
    final direct = builder.destinationsFor(source);
    return {
      for (final d in builder.chainedDestinationsFor(source))
        if (!direct.contains(d)) d,
    };
  }

  /// Enters the whole same-checker chain from [source] to [landing] by replaying
  /// its hops through the builder. Each hop is offered by construction (see
  /// [MoveBuilder.chainFor]); a defensive [ArgumentError] guard leaves the
  /// builder untouched past the last accepted hop.
  void _enterChain(MoveBuilder builder, int source, int landing) {
    try {
      for (final hop in builder.chainFor(source, landing)) {
        builder.addHop(hop.from, hop.to);
      }
    } on ArgumentError {
      // A stale chain (position moved on): ignore the trailing hops.
    }
  }

  /// The maximum distance a tap may miss an actionable target and still count.
  ///
  /// Scales with the checker so it stays proportionate on a big board, with a
  /// floor of [_minTapTolerance] so a phone-sized checker (~13pt radius — a
  /// 26pt disc, well under the 44pt accessibility minimum) still presents an
  /// effective target at least 44pt across. Only the NEAREST target within the
  /// tolerance wins, so a generous radius never makes a tap ambiguous.
  double _tapTolerance(BoardGeometry geometry) =>
      math.max(geometry.checkerRadius * 1.8, _minTapTolerance);

  /// Half of the 44pt minimum touch target: the tap-forgiveness radius never
  /// drops below this, however small the board's checkers are.
  static const double _minTapTolerance = 22;

  /// The selectable source whose top-checker anchor is nearest [pos] within
  /// [_tapTolerance], or `null` when none is close enough. Anchors are computed
  /// on the PREVIEW board so they match exactly where the painter draws the
  /// source rings.
  int? _nearestSource(BoardGeometry geometry, Offset pos, MoveBuilder builder) {
    final board = _previewBoard();
    var bestD = _tapTolerance(geometry);
    int? best;
    for (final loc in builder.selectableSources) {
      final c = _sourceAnchor(geometry, board, loc);
      if (c == null) continue;
      final d = (c - pos).distance;
      if (d < bestD) {
        bestD = d;
        best = loc;
      }
    }
    return best;
  }

  /// The legal destination for [source] whose region centre is nearest [pos]
  /// within [_tapTolerance], or `null` when none is close enough.
  int? _nearestDestination(
      BoardGeometry geometry, Offset pos, MoveBuilder builder, int source) {
    return _nearestTarget(geometry, pos, builder.destinationsFor(source));
  }

  /// The target location in [targets] whose region centre is nearest [pos]
  /// within [_tapTolerance], or `null` when none is close enough. Shared by the
  /// direct-destination and combined-landing forgiveness paths.
  int? _nearestTarget(BoardGeometry geometry, Offset pos, Set<int> targets) {
    var bestD = _tapTolerance(geometry);
    int? best;
    for (final loc in targets) {
      final d = (_destAnchor(geometry, loc) - pos).distance;
      if (d < bestD) {
        bestD = d;
        best = loc;
      }
    }
    return best;
  }

  /// Top-checker centre of source [loc] on [board] — the same anchor the painter
  /// rings. `null` when the location is empty.
  Offset? _sourceAnchor(BoardGeometry geometry, BoardState board, int loc) {
    if (loc == CheckerMove.bar) {
      final n = board.barFor(widget.state.turn);
      if (n == 0) return null;
      return geometry.barCheckerCenter(widget.state.turn, n - 1, n);
    }
    final count = board.points[loc].abs();
    if (count == 0) return null;
    return geometry.checkerCenter(loc, count - 1, count);
  }

  /// Region centre of destination [loc]: the target triangle's centre, or the
  /// moving player's bear-off strip centre for `off`.
  Offset _destAnchor(BoardGeometry geometry, int loc) => loc == CheckerMove.off
      ? geometry.offRect(widget.state.turn).center
      : geometry.pointRect(loc).center;

  // --- Drag-to-move ----------------------------------------------------------

  /// Pan start: lift the selectable source under (or nearest to) the pointer as
  /// a drag ghost. No-op when drag is disabled, there is no builder, or the pan
  /// did not start near a selectable source. Suspends any running move animation
  /// so the ghost is the only travelling checker.
  void _onPanStart(BoardGeometry geometry, Offset localPosition) {
    if (!widget.interactionOptions.enableDrag) return;
    final builder = _builder;
    if (builder == null) return;
    final loc = geometry.locationAt(localPosition);
    final int? source;
    if (loc != null && builder.selectableSources.contains(loc)) {
      source = loc;
    } else {
      source = _nearestSource(geometry, localPosition, builder);
    }
    if (source == null) return;
    setState(() {
      // Suspend a running animation: fence its completion callback and stop it.
      if (_animation != null) {
        _animSeq++;
        _animController.stop();
        _animation = null;
      }
      _pendingAnimation = null; // drop any queued (held) move too
      _dragSource = source;
      _dragPointer = localPosition;
      _selectedSource = null;
      _stagedFromExternal = false; // a manual drag makes this hand entry
    });
    // A suspended animation is over as far as consumers are concerned.
    widget.onMoveAnimation?.call(null);
    _disarmDoubleTap(); // a drag is not half of a double-tap
    _syncEntry();
  }

  /// Pan update: move the drag ghost to the pointer. No-op unless a drag is live.
  void _onPanUpdate(Offset localPosition) {
    if (_dragSource == null) return;
    setState(() => _dragPointer = localPosition);
  }

  /// Pan end: drop the lifted checker. A direct destination under (or near) the
  /// release commits a single hop; a combined landing (when enabled) enters the
  /// whole chain; anything else snaps back (the ghost simply clears). The dragged
  /// source is always deselected afterwards, mirroring the tap flow.
  void _onPanEnd(BoardGeometry geometry) {
    final source = _dragSource;
    final pointer = _dragPointer;
    setState(() {
      _dragSource = null;
      _dragPointer = null;
    });
    if (source == null || pointer == null) return;
    final builder = _builder;
    if (builder == null) return;
    final loc = geometry.locationAt(pointer);

    // Direct destination: exact hit first, then forgiveness.
    int? directDrop;
    if (loc != null && builder.destinationsFor(source).contains(loc)) {
      directDrop = loc;
    } else {
      directDrop = _nearestDestination(geometry, pointer, builder, source);
    }
    if (directDrop != null) {
      setState(() => builder.addHop(source, directDrop!));
      _syncEntry();
      return;
    }

    // Combined landing: exact hit first, then forgiveness.
    final chained = _chainedDestinations(builder, source);
    int? chainDrop;
    if (loc != null && chained.contains(loc)) {
      chainDrop = loc;
    } else {
      chainDrop = _nearestTarget(geometry, pointer, chained);
    }
    if (chainDrop != null) {
      setState(() => _enterChain(builder, source, chainDrop!));
      _syncEntry();
      return;
    }
    // Dropped on nothing actionable: snap-back is a simple clear (already done).
  }

  /// The hidden-checker record for the drag ghost: the top checker of
  /// [_dragSource] on [board], lifted while it travels as the overlay. `null`
  /// when nothing is being dragged or the source is empty.
  ({int location, int stackIndex, bool isWhite})? _dragHidden(BoardState board) {
    final source = _dragSource;
    if (source == null) return null;
    final isWhite = widget.state.turn == Player.white;
    if (source == CheckerMove.bar) {
      final n = board.barFor(widget.state.turn);
      if (n == 0) return null;
      return (location: CheckerMove.bar, stackIndex: n - 1, isWhite: isWhite);
    }
    final count = board.points[source].abs();
    if (count == 0) return null;
    return (location: source, stackIndex: count - 1, isWhite: isWhite);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ??
        (Theme.of(context).brightness == Brightness.dark
            ? BoardTheme.dark
            : BoardTheme.light);
    final builder = _builder;
    final selected = _selectedSource;

    // The board is one semantics node with a spoken summary (see
    // [_semanticsLabel]); the painted board itself has no semantics of its own.
    final board = _BoardFrame(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final geometry =
              BoardGeometry(size, whiteAtBottom: widget.whiteAtBottom);

          final dragSource = _dragSource;
          final dragPointer = _dragPointer;
          final dragging = dragSource != null && dragPointer != null;

          // The two persistent dice pairs to paint. The roll-beat override, when
          // active, REPLACES its OWN ROLLER's pair with the cycling faces; the
          // other pair keeps its persisted roll. The roller comes from the
          // override itself, never from [state]'s turn — see
          // [BoardView.diceOverride]. Cosmetic only — never touches state or
          // move entry.
          final turn = widget.state.turn;
          final override = widget.diceOverride;
          final whiteDice = (override != null && override.roller == Player.white)
              ? override.faces
              : widget.whiteDice;
          final blackDice = (override != null && override.roller == Player.black)
              ? override.faces
              : widget.blackDice;

          // Highlights are a pure visual layer: when off, taps/drag still drive
          // entry but no rings or destination fills are painted (see
          // [BoardInteractionOptions.showHighlights]).
          final showHl = widget.interactionOptions.showHighlights;
          // Dice the staged hops have already spent, so they render disabled.
          // Purely derived from the live builder: an Undo drops a hop and the
          // die brightens again on the very next paint. Never dims the waiting
          // player's memento pair (the painter gates on the mover).
          final rolled = widget.state.dice;
          final playedSlots = (builder != null && rolled != null)
              ? usedDiceSlots(builder.chosenHops, rolled, turn)
              : const <int>{};

          // A live drag suspends animation, so the two are mutually exclusive.
          final frame = dragging ? null : _animFrame(geometry);
          // A move queued while [BoardView.holdMoveAnimation] is `true` has not
          // started travelling yet: freeze the board at the captured PRE-move
          // position (no overlay) so the moved checker sits at its source until
          // the hold releases. Only when no live/drag animation is in play.
          final held =
              (!dragging && _animation == null) ? _pendingAnimation : null;
          final BoardPainter painter;
          if (dragging) {
            // Drag: paint the preview board, hide the lifted source checker, and
            // draw the ghost at the pointer with the drop targets highlighted.
            final preview = _previewBoard();
            painter = BoardPainter(
              board: preview,
              geometry: geometry,
              theme: theme,
              whiteDice: whiteDice,
              blackDice: blackDice,
              activeDiceSide: widget.activeDiceSide,
              cube: widget.showCube ? widget.state.cube : null,
              usedDiceSlots: playedSlots,
              hiddenChecker: _dragHidden(preview),
              overlayChecker: (
                center: dragPointer,
                isWhite: widget.state.turn == Player.white,
              ),
              highlightedDestinations: (showHl && builder != null)
                  ? builder.destinationsFor(dragSource)
                  : const {},
              combinedDestinations: (showHl && builder != null)
                  ? _chainedDestinations(builder, dragSource)
                  : const {},
              movingPlayer: builder != null ? widget.state.turn : null,
            );
          } else if (frame != null) {
            // While a move animates, paint the pre-move board (with earlier hops
            // applied), hide the travelling checker, drop interaction highlights.
            painter = BoardPainter(
              board: frame.board,
              geometry: geometry,
              theme: theme,
              whiteDice: whiteDice,
              blackDice: blackDice,
              activeDiceSide: widget.activeDiceSide,
              cube: widget.showCube ? widget.state.cube : null,
              hiddenChecker: frame.hidden,
              overlayChecker: frame.overlay,
            );
          } else {
            painter = BoardPainter(
              board: held?.preBoard ?? _previewBoard(),
              geometry: geometry,
              theme: theme,
              whiteDice: whiteDice,
              blackDice: blackDice,
              activeDiceSide: widget.activeDiceSide,
              cube: widget.showCube ? widget.state.cube : null,
              usedDiceSlots: playedSlots,
              // A static overlay's origins wear the STRONG ring; the live
              // builder never uses it (its pickup is [selectedCheckerLocation]).
              strongHighlightLocations:
                  builder == null ? widget.strongHighlightSources : const {},
              // When a builder owns the board (interactive moving phase) the
              // live selection drives the highlights; otherwise the static
              // overlay fields (the replay/analysis move highlights) apply.
              highlightedSources: builder == null
                  ? widget.highlightedSources
                  : (showHl && selected == null)
                      ? builder.selectableSources
                      : const {},
              highlightedDestinations: builder == null
                  ? widget.highlightedDestinations
                  : (showHl && selected != null)
                      ? builder.destinationsFor(selected)
                      : const {},
              combinedDestinations:
                  (showHl && builder != null && selected != null)
                      ? _chainedDestinations(builder, selected)
                      : const {},
              selectedCheckerLocation:
                  builder != null && showHl ? selected : null,
              movingPlayer: builder != null
                  ? widget.state.turn
                  : widget.highlightMovingPlayer,
            );
          }

          // Gestures are attached while move entry is live OR while the board
          // accepts a dice tap (the pre-roll gate, where the board is otherwise
          // non-interactive).
          if (!widget.interactive && widget.onDiceTap == null) {
            return CustomPaint(size: size, painter: painter);
          }
          final dragEnabled =
              widget.interactive && widget.interactionOptions.enableDrag;
          // A RawGestureDetector rather than GestureDetector so the TAP
          // recogniser's movement tolerances can be switched off — see
          // [_tapSurvivesTravel] for the dead zone that closes.
          return RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(
                  debugOwner: this,
                  // Movement never cancels the tap; only the pan claiming the
                  // gesture does. See [_tapSurvivesTravel].
                  preAcceptSlopTolerance: null,
                  postAcceptSlopTolerance: null,
                ),
                (recognizer) {
                  // The DOWN position is where the user aimed; the release may
                  // have drifted. Route by the aim.
                  recognizer.onTapDown =
                      (details) => _tapDownPosition = details.localPosition;
                  recognizer.onTapUp = (details) => _onTapUp(
                      geometry, _tapDownPosition ?? details.localPosition);
                  recognizer.onTapCancel = () => _tapDownPosition = null;
                },
              ),
              // Pan recognisers are attached only when drag is enabled, so with
              // drag off a pan simply falls through (does nothing) while taps
              // keep working. With both attached, Flutter's gesture arena routes
              // a press+release that never travelled far to the tap and a
              // travelling gesture to the pan handlers.
              if (dragEnabled)
                PanGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                  () => PanGestureRecognizer(debugOwner: this),
                  (recognizer) {
                    recognizer.onStart = (details) =>
                        _onPanStart(geometry, details.localPosition);
                    recognizer.onUpdate =
                        (details) => _onPanUpdate(details.localPosition);
                    recognizer.onEnd = (_) => _onPanEnd(geometry);
                  },
                ),
            },
            child: CustomPaint(size: size, painter: painter),
          );
        },
      ),
    );
    return Semantics(container: true, label: _semanticsLabel(), child: board);
  }

  /// What a screen reader hears for the board as a whole.
  ///
  /// The baseline is the two things a sighted player reads off the board first:
  /// whose turn it is, and what is on the dice. Per-checker semantics (a node
  /// per point, with counts and colours) is a much larger surface and is
  /// deliberately NOT attempted here — this label is the floor, not the
  /// ceiling. The roll named is [BoardView.state]'s, never the cosmetic
  /// [diceOverride]: a tumbling die is not a fact about the game.
  String _semanticsLabel() {
    final state = widget.state;
    final side = state.turn == Player.white ? 'White' : 'Black';
    final dice = state.dice;
    final roll = dice == null ? '' : ', roll ${dice.die1} and ${dice.die2}';
    final what = switch (state.phase) {
      GamePhase.awaitingRoll => '$side to roll.',
      GamePhase.moving => '$side to move$roll.',
      // The offer is the news in both of these, and the offering side is named
      // by the dialog that carries it — the board just says one is open.
      GamePhase.cubeOffered => 'A double is offered.',
      GamePhase.resignOffered => 'A resignation is offered.',
      GamePhase.gameOver => 'The game is over.',
    };
    return 'Backgammon board. $what';
  }
}

/// Gives the board its SHAPE: fills the slot it is given, with the aspect
/// clamped to [BoardView.minAspect] … [BoardView.maxAspect], and centres the
/// result. The [child] is then laid out with TIGHT constraints of exactly that
/// size, so the board's own [LayoutBuilder] reads the final paint size.
///
/// Centring matters under a tight slot (a parent that forces its own size):
/// the board takes the shape it is allowed and letterboxes in the leftover,
/// rather than being stretched to a shape the geometry cannot use.
class _BoardFrame extends StatelessWidget {
  const _BoardFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: SizedBox.fromSize(
          size: BoardView.boardSizeFor(constraints),
          child: child,
        ),
      ),
    );
  }
}
