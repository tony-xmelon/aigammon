/**
 * turnflow.ts — a MINIMAL, pure mirror of backgammon_core's GameState turn-flow
 * (packages/backgammon_core/lib/src/game_state.dart). It answers exactly one
 * question the server needs to police play WITHOUT a board:
 *
 *   given the current {phase, turn} and an incoming event of some type from a
 *   given seat, is the transition legal, and what are the next {phase, turn}?
 *
 * It deliberately does NOT validate move legality (both clients validate full
 * legality via backgammon_core; divergence is the detection mechanism — see the
 * v1 trust model in docs/superpowers/plans/2026-07-25-online-play.md). Game-over
 * on a `move` cannot be known here (no board), so terminal outcomes arrive as a
 * client `result` claim carried alongside the event; `resultRule` below tells the
 * caller whether a result claim is required/optional/forbidden for each type.
 *
 * INVARIANT mirrored from game_state.dart: in every phase the acting seat is the
 * one held in `turn`. offerDouble()/offerResign() flip `turn` to the opponent, so
 * the DECIDER of a pending cube/resign is the one now on `turn` — hence take/drop/
 * resignAccept/resignDecline are also submitted by `turn`. The caller enforces
 * seat === turn uniformly.
 */

export type Phase =
  | 'awaitingRoll'
  | 'moving'
  | 'cubeOffered'
  | 'resignOffered'
  | 'gameOver';

export type Seat = 'white' | 'black';

/** Event types that flow through validateAndAdvance. `roll` is included so
 * rollDice and submitEvent share one transition table, even though roll events
 * are appended by rollDice (server dice), never by a client submitEvent. */
export type FlowEventType =
  | 'roll'
  | 'move'
  | 'double'
  | 'take'
  | 'drop'
  | 'resignOffer'
  | 'resignAccept'
  | 'resignDecline';

export interface FlowState {
  phase: Phase;
  turn: Seat;
  /** Phase to restore on resignDecline. game_state.dart infers the prior phase
   * from dice presence (declineResign, game_state.dart:236-240); the server does
   * not track dice, so we stash the pre-offer phase here when a resignOffer
   * arrives and restore it verbatim on decline. Null outside a pending resign. */
  phaseBeforeResign: Phase | null;
}

export type ResultRule = 'none' | 'required' | 'optional';

export interface Advance {
  phase: Phase;
  turn: Seat;
  phaseBeforeResign: Phase | null;
  /** none: a result claim must NOT accompany this event.
   *  required: a result claim MUST accompany (drop, resignAccept — always
   *            terminal). optional: MAY accompany (a `move` that bears off the
   *            15th checker ends the game; the submitting client knows the board
   *            and sends the claim, which overrides phase to gameOver). */
  resultRule: ResultRule;
}

/** Thrown for any illegal transition. `code` maps to an HttpsError code in the
 * caller so turnflow stays free of firebase-functions imports (unit-testable). */
export class FlowError extends Error {
  constructor(
    message: string,
    readonly code: 'failed-precondition' | 'permission-denied' | 'invalid-argument',
  ) {
    super(message);
    this.name = 'FlowError';
  }
}

const opponent = (s: Seat): Seat => (s === 'white' ? 'black' : 'white');

/**
 * Validate that `type` from `seat` is legal in `state`, and return the resulting
 * {phase, turn, phaseBeforeResign} plus the result-claim rule. Throws FlowError
 * otherwise. Non-terminal transitions only — the caller applies a `result` claim
 * (scores, gameOver/next-game) on top when resultRule allows/requires one.
 */
export function validateAndAdvance(
  state: FlowState,
  type: FlowEventType,
  seat: Seat,
): Advance {
  // Uniform actor check (see INVARIANT above): only the seat on `turn` may act.
  if (seat !== state.turn) {
    throw new FlowError(`not your turn (turn=${state.turn}, actor=${seat})`, 'permission-denied');
  }
  const { phase } = state;
  const need = (ok: boolean, msg: string) => {
    if (!ok) throw new FlowError(msg, 'failed-precondition');
  };

  switch (type) {
    // roll(): awaitingRoll -> moving, same player (game_state.dart:169-172).
    case 'roll':
      need(phase === 'awaitingRoll', 'not awaiting a roll');
      return { phase: 'moving', turn: seat, phaseBeforeResign: null, resultRule: 'none' };

    // play(): moving -> awaitingRoll for the opponent, OR gameOver on bear-off
    // completion (game_state.dart:243-273). The board-less server can't tell;
    // a result claim (optional) promotes it to gameOver.
    case 'move':
      need(phase === 'moving', 'not in the moving phase');
      return { phase: 'awaitingRoll', turn: opponent(seat), phaseBeforeResign: null, resultRule: 'optional' };

    // offerDouble(): awaitingRoll -> cubeOffered, turn flips to the decider
    // (game_state.dart:174-180). Crawford/cube-ownership are enforced client-side.
    case 'double':
      need(phase === 'awaitingRoll', 'can only double before rolling');
      return { phase: 'cubeOffered', turn: opponent(seat), phaseBeforeResign: null, resultRule: 'none' };

    // take(): cubeOffered -> awaitingRoll, turn flips back to the doubler
    // (game_state.dart:182-189: turn -> turn.opponent, phase awaitingRoll).
    case 'take':
      need(phase === 'cubeOffered', 'no double is pending');
      return { phase: 'awaitingRoll', turn: opponent(seat), phaseBeforeResign: null, resultRule: 'none' };

    // drop(): cubeOffered -> gameOver, winner = the doubler (game_state.dart:191-201).
    // Always terminal: the client computes points from the pre-double cube and
    // sends the result claim, which the server trusts (v1).
    case 'drop':
      need(phase === 'cubeOffered', 'no double is pending');
      return { phase: 'gameOver', turn: seat, phaseBeforeResign: null, resultRule: 'required' };

    // offerResign(): awaitingRoll|moving -> resignOffered, turn flips to the
    // decider (game_state.dart:208-216). Stash the pre-offer phase for decline.
    case 'resignOffer':
      need(phase === 'awaitingRoll' || phase === 'moving', 'cannot resign now');
      return { phase: 'resignOffered', turn: opponent(seat), phaseBeforeResign: phase, resultRule: 'none' };

    // acceptResign(): resignOffered -> gameOver (game_state.dart:218-230).
    // Terminal; the client sends winner/points (cube * resign multiplier).
    case 'resignAccept':
      need(phase === 'resignOffered', 'no resignation is pending');
      return { phase: 'gameOver', turn: seat, phaseBeforeResign: null, resultRule: 'required' };

    // declineResign(): resignOffered -> restore the pre-offer phase, turn back to
    // the offerer (game_state.dart:232-241). Offerer == opponent of the current
    // decider (== seat). phaseBeforeResign holds the phase to restore.
    case 'resignDecline': {
      need(phase === 'resignOffered', 'no resignation is pending');
      const restored = state.phaseBeforeResign;
      need(restored === 'awaitingRoll' || restored === 'moving', 'no pre-resign phase to restore');
      return { phase: restored as Phase, turn: opponent(seat), phaseBeforeResign: null, resultRule: 'none' };
    }
  }
}
