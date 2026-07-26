import 'package:backgammon_core/backgammon_core.dart';

/// A move that has just landed, together with the board it was applied TO.
///
/// This is what a [MatchController] publishes on its `lastMove` stream for the
/// cosmetic animation layer (see `BoardView`). Carrying the pre-move board as
/// DATA is the whole point of the class: an animation needs the position the
/// moved checker started from, and that position is only knowable at the moment
/// the event is appended/folded.
///
/// ## Why not "read the observer's current state"?
///
/// The earlier contract published a bare [MoveEvent] and relied on the observer
/// still *seeing* the pre-move position when the notification fired — true only
/// because a widget's `state` property lags the controller by a frame. That
/// assumption breaks whenever the controller advances SEVERAL events between two
/// frames, which is the normal case in vs-AI play: the human's confirm, the AI's
/// roll and the AI's reply all land inside one microtask chain, with no frame
/// painted in between. The board then captured a base position that predated the
/// human's own committed move, froze there behind the dice-roll beat, and only
/// caught up when the animation ended — the "my move is undone, then replayed"
/// regression. With the base board carried alongside the event, the animation is
/// correct regardless of how many events land between frames.
class AppliedMove {
  const AppliedMove(this.event, this.preBoard);

  /// The applied move and its mover.
  final MoveEvent event;

  /// The board the move was applied to (i.e. BEFORE it landed) — the animation's
  /// starting position.
  final BoardState preBoard;

  /// The mover.
  Player get player => event.player;

  /// The move itself (its hops are in canonical, applied order).
  Move get move => event.move;

  @override
  String toString() => 'AppliedMove($event)';
}
