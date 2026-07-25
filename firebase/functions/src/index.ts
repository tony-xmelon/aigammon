/**
 * AIGammon Cloud Functions — match lifecycle + server-authoritative dice.
 *
 * All four callables (createMatch / joinMatch / rollDice / submitEvent) are the
 * ONLY write path to Firestore: firestore.rules DENY every client write, so
 * these functions (Admin SDK, which bypasses rules) own all mutations. See the
 * v1 trust model in docs/superpowers/plans/2026-07-25-online-play.md:
 *   - the server generates ALL dice (opening + rolls) with crypto randomness;
 *   - the server polices turn / seat / seq and a MINIMAL turn-flow mirror
 *     (turnflow.ts) but NOT full move legality (both clients validate that via
 *     backgammon_core; divergence = detection);
 *   - terminal outcomes (game/match end) arrive as a client `result` claim which
 *     the server trusts and folds into scores.
 */

import { randomInt } from 'crypto';
import { initializeApp } from 'firebase-admin/app';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { setGlobalOptions } from 'firebase-functions/v2';
import { CallableRequest, HttpsError, onCall } from 'firebase-functions/v2/https';
import {
  FlowError,
  FlowEventType,
  Phase,
  Seat,
  validateAndAdvance,
} from './turnflow';

initializeApp();
setGlobalOptions({ region: 'us-central1' });

const db = getFirestore();

// --- shared types -----------------------------------------------------------

interface MatchDoc {
  code: string;
  matchLength: number;
  status: 'waiting' | 'active' | 'complete';
  uids: string[];
  seats: { white: string; black?: string };
  scores: { white: number; black: number };
  crawfordPlayed: boolean;
  isCrawford?: boolean;
  gameNo: number;
  seq: number;
  turn: Seat | null;
  phase: Phase | null;
  phaseBeforeResign?: Phase | null;
  winner?: Seat;
}

interface ResultClaim {
  winner: Seat;
  points: number;
  outcome: string;
}

// The event types a client may submit via submitEvent (roll/openingRoll are
// server-only). Mirrors the whitelist in the plan's Task 2.
const SUBMITTABLE = new Set<FlowEventType>([
  'move',
  'double',
  'take',
  'drop',
  'resignOffer',
  'resignAccept',
  'resignDecline',
]);

const MATCH_LENGTHS = new Set([1, 3, 5, 7]);

// Code alphabet: A-Z minus confusables I and O, plus digits 2-9 (0 and 1 are
// confusable with O and I/L). 32 symbols → 32^6 ≈ 1.07e9 codes.
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 6;

// --- helpers ----------------------------------------------------------------

function requireAuth(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'sign-in required');
  }
  return uid;
}

/** Which seat the caller holds, or throw if not a participant. */
function seatOf(doc: MatchDoc, uid: string): Seat {
  if (doc.seats.white === uid) return 'white';
  if (doc.seats.black === uid) return 'black';
  throw new HttpsError('permission-denied', 'not a participant in this match');
}

/** A 6-char match code from crypto randomness. */
function genCode(): string {
  let out = '';
  for (let i = 0; i < CODE_LENGTH; i++) {
    out += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return out;
}

/** A server opening roll (never a tie — ties are re-rolled, not recorded). */
function genOpeningRoll(): { whiteDie: number; blackDie: number } {
  let whiteDie = randomInt(1, 7);
  let blackDie = randomInt(1, 7);
  while (whiteDie === blackDie) {
    whiteDie = randomInt(1, 7);
    blackDie = randomInt(1, 7);
  }
  return { whiteDie, blackDie };
}

/** A server turn roll (doubles allowed). */
function genRoll(): { die1: number; die2: number } {
  return { die1: randomInt(1, 7), die2: randomInt(1, 7) };
}

/** Zero-padded event doc id so ids sort lexically in seq order too. */
function eventDocId(seq: number): string {
  return String(seq).padStart(9, '0');
}

/**
 * Crawford check mirroring MatchState.isCrawfordNext
 * (packages/backgammon_core/lib/src/match_state.dart:31-34): the game about to
 * be played is the Crawford game when nobody has already played it, the match is
 * not over, and someone is exactly one point from the target.
 */
function isCrawfordNext(
  whiteScore: number,
  blackScore: number,
  crawfordPlayed: boolean,
  matchLength: number,
): boolean {
  if (crawfordPlayed) return false;
  if (whiteScore >= matchLength || blackScore >= matchLength) return false;
  return whiteScore === matchLength - 1 || blackScore === matchLength - 1;
}

function openingWinner(whiteDie: number, blackDie: number): Seat {
  return whiteDie > blackDie ? 'white' : 'black';
}

function validateResultClaim(raw: unknown): ResultClaim {
  if (typeof raw !== 'object' || raw === null) {
    throw new HttpsError('invalid-argument', 'result claim must be an object');
  }
  const r = raw as Record<string, unknown>;
  if (r.winner !== 'white' && r.winner !== 'black') {
    throw new HttpsError('invalid-argument', 'result.winner must be white or black');
  }
  if (typeof r.points !== 'number' || !Number.isInteger(r.points) || r.points <= 0) {
    throw new HttpsError('invalid-argument', 'result.points must be a positive integer');
  }
  if (typeof r.outcome !== 'string') {
    throw new HttpsError('invalid-argument', 'result.outcome must be a string');
  }
  return { winner: r.winner, points: r.points, outcome: r.outcome };
}

// --- createMatch ------------------------------------------------------------

export const createMatch = onCall(async (request) => {
  const uid = requireAuth(request);
  const matchLength = (request.data ?? {}).matchLength;
  if (typeof matchLength !== 'number' || !MATCH_LENGTHS.has(matchLength)) {
    throw new HttpsError('invalid-argument', 'matchLength must be one of 1, 3, 5, 7');
  }

  // Retry ≤5 times on code collision. The `codes/{code}` reservation doc and the
  // match doc are written together in one transaction, so a code is never
  // observable before its match exists.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = genCode();
    const matchRef = db.collection('matches').doc();
    const codeRef = db.collection('codes').doc(code);
    const doc: MatchDoc = {
      code,
      matchLength,
      status: 'waiting',
      uids: [uid],
      seats: { white: uid },
      scores: { white: 0, black: 0 },
      crawfordPlayed: false,
      gameNo: 0,
      seq: -1,
      turn: null,
      phase: null,
    };
    try {
      await db.runTransaction(async (tx) => {
        const codeSnap = await tx.get(codeRef);
        if (codeSnap.exists) {
          throw new HttpsError('already-exists', 'code collision');
        }
        tx.set(codeRef, { matchId: matchRef.id, createdAt: FieldValue.serverTimestamp() });
        tx.set(matchRef, { ...doc, createdAt: FieldValue.serverTimestamp() });
      });
      return { matchId: matchRef.id, code };
    } catch (e) {
      if (e instanceof HttpsError && e.code === 'already-exists') {
        continue; // collision — try a fresh code
      }
      throw e;
    }
  }
  throw new HttpsError('resource-exhausted', 'could not allocate a unique code');
});

// --- joinMatch --------------------------------------------------------------

export const joinMatch = onCall(async (request) => {
  const uid = requireAuth(request);
  const rawCode = (request.data ?? {}).code;
  if (typeof rawCode !== 'string' || rawCode.trim().length === 0) {
    throw new HttpsError('invalid-argument', 'code is required');
  }
  const code = rawCode.trim().toUpperCase();

  const matchId = await db.runTransaction(async (tx) => {
    const codeSnap = await tx.get(db.collection('codes').doc(code));
    if (!codeSnap.exists) {
      throw new HttpsError('not-found', 'no match with that code');
    }
    const id = codeSnap.data()!.matchId as string;
    const matchRef = db.collection('matches').doc(id);
    const matchSnap = await tx.get(matchRef);
    if (!matchSnap.exists) {
      throw new HttpsError('not-found', 'match not found');
    }
    const doc = matchSnap.data() as MatchDoc;
    if (doc.status !== 'waiting') {
      throw new HttpsError('failed-precondition', 'match is not open to join');
    }
    if (doc.seats.white === uid) {
      throw new HttpsError('failed-precondition', 'cannot join your own match');
    }

    // Game 1 opening roll (server dice). Scores are 0-0, so the game is Crawford
    // only in a 1-point match (matchLength-1 === 0).
    const { whiteDie, blackDie } = genOpeningRoll();
    const turn = openingWinner(whiteDie, blackDie);
    const isCrawford = isCrawfordNext(0, 0, false, doc.matchLength);

    tx.update(matchRef, {
      'seats.black': uid,
      uids: FieldValue.arrayUnion(uid),
      status: 'active',
      gameNo: 1,
      seq: 0,
      turn,
      phase: 'moving',
      phaseBeforeResign: null,
      isCrawford,
    });
    tx.set(matchRef.collection('events').doc(eventDocId(0)), {
      type: 'openingRoll',
      whiteDie,
      blackDie,
      gameNo: 1,
      seq: 0,
      createdAt: FieldValue.serverTimestamp(),
    });
    return id;
  });

  return { matchId };
});

// --- rollDice ---------------------------------------------------------------

export const rollDice = onCall(async (request) => {
  const uid = requireAuth(request);
  const matchId = (request.data ?? {}).matchId;
  if (typeof matchId !== 'string' || matchId.length === 0) {
    throw new HttpsError('invalid-argument', 'matchId is required');
  }

  const dice = await db.runTransaction(async (tx) => {
    const matchRef = db.collection('matches').doc(matchId);
    const snap = await tx.get(matchRef);
    if (!snap.exists) {
      throw new HttpsError('not-found', 'match not found');
    }
    const doc = snap.data() as MatchDoc;
    const seat = seatOf(doc, uid);
    if (doc.status !== 'active') {
      throw new HttpsError('failed-precondition', 'match is not active');
    }

    // Single source of truth for the transition (awaitingRoll -> moving, same
    // player). Throws FlowError -> mapped below if it isn't the caller's roll.
    advanceOrThrow(
      { phase: doc.phase!, turn: doc.turn!, phaseBeforeResign: doc.phaseBeforeResign ?? null },
      'roll',
      seat,
    );

    const { die1, die2 } = genRoll();
    const seq = doc.seq + 1;
    tx.set(matchRef.collection('events').doc(eventDocId(seq)), {
      type: 'roll',
      player: seat,
      die1,
      die2,
      gameNo: doc.gameNo,
      seq,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.update(matchRef, { seq, phase: 'moving' });
    return { die1, die2 };
  });

  return dice;
});

// --- submitEvent ------------------------------------------------------------

export const submitEvent = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data ?? {};
  const matchId = data.matchId;
  const event = data.event;
  const rawResult = data.result;
  if (typeof matchId !== 'string' || matchId.length === 0) {
    throw new HttpsError('invalid-argument', 'matchId is required');
  }
  if (typeof event !== 'object' || event === null) {
    throw new HttpsError('invalid-argument', 'event must be an object');
  }
  const type = (event as Record<string, unknown>).type;
  if (typeof type !== 'string' || !SUBMITTABLE.has(type as FlowEventType)) {
    throw new HttpsError('invalid-argument', `event type not submittable: ${String(type)}`);
  }
  const eventType = type as FlowEventType;

  const seq = await db.runTransaction(async (tx) => {
    const matchRef = db.collection('matches').doc(matchId);
    const snap = await tx.get(matchRef);
    if (!snap.exists) {
      throw new HttpsError('not-found', 'match not found');
    }
    const doc = snap.data() as MatchDoc;
    const seat = seatOf(doc, uid);
    if (doc.status !== 'active') {
      throw new HttpsError('failed-precondition', 'match is not active');
    }

    // Never trust the client's player field: REJECT a mismatch (auditability)
    // rather than silently overwriting it.
    if ((event as Record<string, unknown>).player !== seat) {
      throw new HttpsError('permission-denied', 'event.player does not match your seat');
    }

    const adv = advanceOrThrow(
      { phase: doc.phase!, turn: doc.turn!, phaseBeforeResign: doc.phaseBeforeResign ?? null },
      eventType,
      seat,
    );

    // Result-claim rule enforcement.
    const hasResult = rawResult !== undefined && rawResult !== null;
    if (adv.resultRule === 'none' && hasResult) {
      throw new HttpsError('invalid-argument', `${eventType} must not carry a result claim`);
    }
    if (adv.resultRule === 'required' && !hasResult) {
      throw new HttpsError('invalid-argument', `${eventType} requires a result claim`);
    }

    const clientSeq = doc.seq + 1;

    // Append the client event at seq+1. gameNo is set server-side; seq stamped;
    // client's own gameNo/seq (if any) are overwritten.
    tx.set(matchRef.collection('events').doc(eventDocId(clientSeq)), {
      ...(event as Record<string, unknown>),
      gameNo: doc.gameNo,
      seq: clientSeq,
      createdAt: FieldValue.serverTimestamp(),
    });

    if (!hasResult) {
      // Non-terminal: apply the mirrored transition.
      tx.update(matchRef, {
        seq: clientSeq,
        phase: adv.phase,
        turn: adv.turn,
        phaseBeforeResign: adv.phaseBeforeResign,
      });
      return clientSeq;
    }

    // Terminal: fold the trusted result claim into scores.
    const result = validateResultClaim(rawResult);
    const newWhite = doc.scores.white + (result.winner === 'white' ? result.points : 0);
    const newBlack = doc.scores.black + (result.winner === 'black' ? result.points : 0);

    // Crawford bookkeeping mirrors MatchState.applyResult (match_state.dart:36-44):
    // the crawford flag flips once the game that WAS the Crawford game is played.
    const crawfordJustPlayed = isCrawfordNext(
      doc.scores.white,
      doc.scores.black,
      doc.crawfordPlayed,
      doc.matchLength,
    );
    const crawfordPlayed = doc.crawfordPlayed || crawfordJustPlayed;
    const matchOver = newWhite >= doc.matchLength || newBlack >= doc.matchLength;

    if (matchOver) {
      const winner: Seat = newWhite >= doc.matchLength ? 'white' : 'black';
      tx.update(matchRef, {
        seq: clientSeq,
        phase: 'gameOver',
        scores: { white: newWhite, black: newBlack },
        crawfordPlayed,
        status: 'complete',
        winner,
      });
      return clientSeq;
    }

    // Match continues: start the next game with a fresh server opening roll,
    // appended as an ADDITIONAL event at seq+2.
    const { whiteDie, blackDie } = genOpeningRoll();
    const nextTurn = openingWinner(whiteDie, blackDie);
    const nextGameNo = doc.gameNo + 1;
    const openingSeq = clientSeq + 1;
    const isCrawford = isCrawfordNext(newWhite, newBlack, crawfordPlayed, doc.matchLength);

    tx.set(matchRef.collection('events').doc(eventDocId(openingSeq)), {
      type: 'openingRoll',
      whiteDie,
      blackDie,
      gameNo: nextGameNo,
      seq: openingSeq,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.update(matchRef, {
      seq: openingSeq,
      gameNo: nextGameNo,
      phase: 'moving',
      turn: nextTurn,
      phaseBeforeResign: null,
      scores: { white: newWhite, black: newBlack },
      crawfordPlayed,
      isCrawford,
    });
    // The client event that ended the prior game still lives at clientSeq; the
    // caller keys off it, so return clientSeq (not the opening seq).
    return clientSeq;
  });

  return { seq };
});

// --- turnflow bridge --------------------------------------------------------

/** Run the pure transition mirror, translating FlowError -> HttpsError so the
 * firebase-functions dependency stays out of turnflow.ts. */
function advanceOrThrow(
  state: { phase: Phase; turn: Seat; phaseBeforeResign: Phase | null },
  type: FlowEventType,
  seat: Seat,
) {
  try {
    return validateAndAdvance(state, type, seat);
  } catch (e) {
    if (e instanceof FlowError) {
      throw new HttpsError(e.code, e.message);
    }
    throw e;
  }
}
