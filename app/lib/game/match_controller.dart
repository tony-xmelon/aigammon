import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';

import 'applied_move.dart';
import 'player_agent.dart';

/// The surface [GameScreen] needs to run a match, implemented by the local
/// [GameController] and the online `OnlineMatchController`.
///
/// The screen observes this as a [Listenable] and drives all interaction
/// through the members below. Instead of exposing the [PlayerAgent] pair
/// directly (which an online controller does not have), it offers an
/// INTERACTION SURFACE: [isLocalHuman] plus the `pending*Of` / `submit*`
/// verbs, keyed by [Player] side. A hot-seat controller reports BOTH sides as
/// locally human; an online controller reports only the local player's side.
///
/// ## `pending*Of` contract
///
/// The `pending*Of` accessors are only meaningful for a side for which
/// [isLocalHuman] returns `true`. Callers MUST gate on [isLocalHuman] before
/// observing or reading a pending listenable; for a non-local (e.g. AI or
/// remote) side an implementation may return a constant always-null listenable.
///
/// There is deliberately no `pendingDoubleOf`: a locally-human side is never
/// prompted with a per-turn "double?" request — doubling is driven through the
/// pre-roll [offerDouble] verb instead (see [GameController] and Plan 4).
abstract interface class MatchController implements Listenable {
  /// The current game's derived state.
  GameState get state;

  /// The running match score.
  MatchState get match;

  /// The 1-based number of the current game within the match (1 for the first
  /// game). `0` before the first game has started. Shown in the move-history
  /// sheet's score context.
  int get gameNumber;

  /// The current event-sourced game (the tutor/assessment reads its log).
  Game get game;

  /// The most recently applied move, or `null` before any move has landed. Fires
  /// (as a [Listenable]) each time a move is appended/folded so a cosmetic
  /// animation layer can sequence the move's hops.
  ///
  /// The value carries the applied move, its mover, AND the board it was applied
  /// to — see [AppliedMove] for why the pre-move board must travel WITH the
  /// event rather than being read back off the observer's own (frame-lagged)
  /// view of [state]. Each fire publishes a fresh [AppliedMove] instance, so
  /// repeating an identical move still notifies.
  ValueListenable<AppliedMove?> get lastMove;

  /// True while a decision is in flight (an AI/engine await).
  bool get isThinking;

  /// The last error that stopped the loop, or `null` when healthy.
  Object? get error;

  /// The last non-fatal persistence failure, or `null`. Every implementation
  /// records finished games through a [MatchPersistence] seam, so a storage
  /// fault surfaces here rather than interrupting play.
  Object? get persistenceError;

  /// True once the match has been decided.
  bool get matchOver;

  /// Whether this match is played WITHOUT the doubling cube. When true, doubling
  /// is never legal (no AI double prompts, [offerDouble] throws) and the UI hides
  /// the cube chip / Double button. Online and on the LAN it is the host's
  /// choice, carried in the match document / welcome and honoured by both peers.
  bool get cubeless;

  /// True while paused between games waiting for [continueToNextGame].
  bool get awaitingNextGame;

  /// Resumes the loop after a game ends. Valid only while [awaitingNextGame].
  void continueToNextGame();

  /// True while the local side may roll / double / resign now (its pre-roll
  /// gate is open).
  bool get awaitingHumanTurn;

  /// Runs the match until it completes or the controller is disposed. The
  /// screen fires this once in `initState`.
  Future<void> playMatch();

  /// Pre-roll verb: roll the dice. Valid only while [awaitingHumanTurn].
  void rollDice();

  /// Pre-roll verb: offer a double. Valid only while [awaitingHumanTurn] and
  /// doubling is legal.
  void offerDouble();

  /// Pre-roll verb: offer to resign for [value]. Valid only while
  /// [awaitingHumanTurn].
  void offerResign(ResignValue value);

  /// The match-score context for [actor], anchored to [actor]'s perspective.
  MatchContext contextFor(Player actor);

  /// Stops the loop and releases resources. Idempotent.
  void disposeController();

  // --- Interaction surface (replaces direct agent access) ------------------

  /// Whether [side] is controlled by a local human (hot-seat: both sides;
  /// online: only the local player's side).
  bool isLocalHuman(Player side);

  /// The pending move-entry request for a locally-human [side], or a listenable
  /// whose value is `null` when none is pending. Only meaningful when
  /// [isLocalHuman] is `true` for [side] (see the class contract).
  ValueListenable<GameState?> pendingMoveOf(Player side);

  /// Submits [move] for a locally-human [side]'s pending move request.
  void submitMove(Player side, Move move);

  /// The pending cube-response request for a locally-human [side], or a
  /// null-valued listenable. See the class contract.
  ValueListenable<GameState?> pendingCubeOf(Player side);

  /// Submits the take/drop [action] for a locally-human [side].
  void submitCubeResponse(Player side, CubeAction action);

  /// The pending resign-response request (state + offered value) for a
  /// locally-human [side], or a null-valued listenable. See the class contract.
  ValueListenable<(GameState, ResignValue)?> pendingResignOf(Player side);

  /// Submits the accept/decline decision for a locally-human [side].
  void submitResignResponse(Player side, bool accept);
}
