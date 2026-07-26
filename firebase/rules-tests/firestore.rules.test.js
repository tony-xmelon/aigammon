// Firestore security-rules unit tests for AIGammon's serverless online play
// (Plan 16). Run inside a throwaway Firestore emulator:
//
//   pwsh firebase/run-emulator-tests.ps1          (Windows dev machine)
//   bash firebase/ci-emulator-suites.sh           (CI, emulator already up)
//
// Every `allow` path and every meaningful `deny` path in firestore.rules has
// at least one case here. Reads/writes that bypass the rules (seeding fixture
// state) go through testEnv.withSecurityRulesDisabled.

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');

const {
  doc,
  collection,
  setDoc,
  getDoc,
  getDocs,
  updateDoc,
  deleteDoc,
  serverTimestamp,
  setLogLevel,
} = require('firebase/firestore');

// Every deny-path test provokes a PERMISSION_DENIED, and the JS SDK logs each
// one to stderr at error level. That is ~70 lines of expected noise per run,
// and on Windows PowerShell native stderr under `$ErrorActionPreference =
// 'Stop'` is fatal to the harness script. Silence the SDK; mocha reports.
setLogLevel('silent');

const HOST = 'host-uid';
const GUEST = 'guest-uid';
const OUTSIDER = 'outsider-uid';

const HEX = 'a'.repeat(64);
const HEX2 = 'b'.repeat(64);
const HEX3 = 'c'.repeat(64);

let testEnv;
let hostDb;
let guestDb;
let outsiderDb;
let anonDb;

// --- fixtures ---------------------------------------------------------

function matchDoc(db, code) {
  return doc(db, 'matches', code);
}

function eventDoc(db, code, id) {
  return doc(db, 'matches', code, 'events', id);
}

function rollDoc(db, code, id) {
  return doc(db, 'matches', code, 'rolls', id);
}

/** Writes a match doc directly, bypassing rules. */
async function seedMatch(code, overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(matchDoc(ctx.firestore(), code), {
      hostUid: HOST,
      guestUid: null,
      length: 5,
      cubeless: false,
      status: 'waiting',
      createdAt: new Date(),
      ...overrides,
    });
  });
}

/** An already-joined (active) match with HOST + GUEST. */
async function seedActiveMatch(code, overrides = {}) {
  await seedMatch(code, { guestUid: GUEST, status: 'active', ...overrides });
}

/** Writes a roll doc directly, bypassing rules. */
async function seedRoll(code, id, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(rollDoc(ctx.firestore(), code, id), data);
  });
}

/** Writes an event doc directly, bypassing rules. */
async function seedEvent(code, id, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(eventDoc(ctx.firestore(), code, id), data);
  });
}

function newMatchPayload(overrides = {}) {
  return {
    hostUid: HOST,
    guestUid: null,
    length: 5,
    cubeless: false,
    status: 'waiting',
    createdAt: serverTimestamp(),
    ...overrides,
  };
}

function newEventPayload(overrides = {}) {
  return {
    seq: 0,
    gameNo: 1,
    event: '{"kind":"roll","dice":[3,1]}',
    author: HOST,
    ...overrides,
  };
}

function newRollPayload(overrides = {}) {
  return { n: 0, roller: HOST, commit: HEX, ...overrides };
}

// --- lifecycle --------------------------------------------------------

before(async function () {
  this.timeout(30000);
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-aigammon',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
      host: '127.0.0.1',
      port: 8080,
    },
  });
  hostDb = testEnv.authenticatedContext(HOST).firestore();
  guestDb = testEnv.authenticatedContext(GUEST).firestore();
  outsiderDb = testEnv.authenticatedContext(OUTSIDER).firestore();
  anonDb = testEnv.unauthenticatedContext().firestore();
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

// =====================================================================
// matches/{code}
// =====================================================================

describe('matches: create', () => {
  it('allows a signed-in host to open a waiting match', async () => {
    await assertSucceeds(setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload()));
  });

  it('allows a 1-point match and a 25-point match', async () => {
    await assertSucceeds(
      setDoc(matchDoc(hostDb, 'LEN00001'), newMatchPayload({ length: 1 })),
    );
    await assertSucceeds(
      setDoc(matchDoc(hostDb, 'LEN00025'), newMatchPayload({ length: 25 })),
    );
  });

  it('allows cubeless matches', async () => {
    await assertSucceeds(
      setDoc(matchDoc(hostDb, 'CUBELESS'), newMatchPayload({ cubeless: true })),
    );
  });

  it('denies an unauthenticated create', async () => {
    await assertFails(setDoc(matchDoc(anonDb, 'ABCD1234'), newMatchPayload()));
  });

  it('denies hostUid spoofing another uid', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ hostUid: GUEST })),
    );
  });

  it('denies a pre-filled guest seat', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ guestUid: GUEST })),
    );
  });

  it('denies a status other than waiting', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ status: 'active' })),
    );
  });

  it('denies an even match length', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ length: 6 })),
    );
  });

  it('denies a length below 1 or above 25', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ length: -1 })),
    );
    await assertFails(
      setDoc(matchDoc(hostDb, 'EFGH5678'), newMatchPayload({ length: 27 })),
    );
  });

  it('denies a non-int length', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ length: '5' })),
    );
  });

  it('denies a non-bool cubeless', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ cubeless: 'no' })),
    );
  });

  it('denies an unknown extra field', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ rating: 1800 })),
    );
  });

  it('denies a missing required field', async () => {
    const payload = newMatchPayload();
    delete payload.cubeless;
    await assertFails(setDoc(matchDoc(hostDb, 'ABCD1234'), payload));
  });

  it('denies a client-chosen createdAt', async () => {
    await assertFails(
      setDoc(matchDoc(hostDb, 'ABCD1234'), newMatchPayload({ createdAt: new Date(0) })),
    );
  });
});

describe('matches: read', () => {
  it('lets any signed-in user read a waiting match (join-by-code)', async () => {
    await seedMatch('ABCD1234');
    await assertSucceeds(getDoc(matchDoc(outsiderDb, 'ABCD1234')));
  });

  it('denies an unauthenticated read of a waiting match', async () => {
    await seedMatch('ABCD1234');
    await assertFails(getDoc(matchDoc(anonDb, 'ABCD1234')));
  });

  it('lets both participants read an active match', async () => {
    await seedActiveMatch('ABCD1234');
    await assertSucceeds(getDoc(matchDoc(hostDb, 'ABCD1234')));
    await assertSucceeds(getDoc(matchDoc(guestDb, 'ABCD1234')));
  });

  it('denies a non-participant read once the match is joined', async () => {
    await seedActiveMatch('ABCD1234');
    await assertFails(getDoc(matchDoc(outsiderDb, 'ABCD1234')));
  });

  it('denies a non-participant read of a completed match', async () => {
    await seedActiveMatch('ABCD1234', { status: 'complete' });
    await assertFails(getDoc(matchDoc(outsiderDb, 'ABCD1234')));
  });

  it('denies listing the matches collection (no invite-code scanning)', async () => {
    await seedMatch('ABCD1234');
    await assertFails(getDocs(collection(hostDb, 'matches')));
  });
});

describe('matches: join transition', () => {
  it('lets a guest claim the open seat and flip to active', async () => {
    await seedMatch('ABCD1234');
    await assertSucceeds(
      updateDoc(matchDoc(guestDb, 'ABCD1234'), { guestUid: GUEST, status: 'active' }),
    );
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const snap = await getDoc(matchDoc(ctx.firestore(), 'ABCD1234'));
      assert.equal(snap.data().guestUid, GUEST);
      assert.equal(snap.data().status, 'active');
    });
  });

  it('denies a second join once the seat is taken', async () => {
    await seedActiveMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(outsiderDb, 'ABCD1234'), {
        guestUid: OUTSIDER,
        status: 'active',
      }),
    );
  });

  it('denies the host joining their own match', async () => {
    await seedMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(hostDb, 'ABCD1234'), { guestUid: HOST, status: 'active' }),
    );
  });

  it('denies seating a uid other than the caller', async () => {
    await seedMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(guestDb, 'ABCD1234'), { guestUid: OUTSIDER, status: 'active' }),
    );
  });

  it('denies a join that leaves the status waiting', async () => {
    await seedMatch('ABCD1234');
    await assertFails(updateDoc(matchDoc(guestDb, 'ABCD1234'), { guestUid: GUEST }));
  });

  it('denies a join that also changes the match length', async () => {
    await seedMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(guestDb, 'ABCD1234'), {
        guestUid: GUEST,
        status: 'active',
        length: 1,
      }),
    );
  });

  it('denies a join that also rewrites hostUid', async () => {
    await seedMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(guestDb, 'ABCD1234'), {
        guestUid: GUEST,
        status: 'active',
        hostUid: GUEST,
      }),
    );
  });

  it('denies an unauthenticated join', async () => {
    await seedMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(anonDb, 'ABCD1234'), { guestUid: GUEST, status: 'active' }),
    );
  });
});

describe('matches: complete transition', () => {
  it('lets the host mark an active match complete', async () => {
    await seedActiveMatch('ABCD1234');
    await assertSucceeds(
      updateDoc(matchDoc(hostDb, 'ABCD1234'), { status: 'complete' }),
    );
  });

  it('lets the guest mark an active match complete', async () => {
    await seedActiveMatch('ABCD1234');
    await assertSucceeds(
      updateDoc(matchDoc(guestDb, 'ABCD1234'), { status: 'complete' }),
    );
  });

  it('denies a non-participant completing the match', async () => {
    await seedActiveMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(outsiderDb, 'ABCD1234'), { status: 'complete' }),
    );
  });

  it('denies completing a match that is still waiting', async () => {
    await seedMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(hostDb, 'ABCD1234'), { status: 'complete' }),
    );
  });

  it('denies completing while also changing another field', async () => {
    await seedActiveMatch('ABCD1234');
    await assertFails(
      updateDoc(matchDoc(hostDb, 'ABCD1234'), { status: 'complete', length: 1 }),
    );
  });

  it('denies reverting an active match to waiting', async () => {
    await seedActiveMatch('ABCD1234');
    await assertFails(updateDoc(matchDoc(hostDb, 'ABCD1234'), { status: 'waiting' }));
  });

  it('denies re-opening a completed match', async () => {
    await seedActiveMatch('ABCD1234', { status: 'complete' });
    await assertFails(updateDoc(matchDoc(hostDb, 'ABCD1234'), { status: 'active' }));
  });

  it('denies evicting the guest', async () => {
    await seedActiveMatch('ABCD1234');
    await assertFails(updateDoc(matchDoc(hostDb, 'ABCD1234'), { guestUid: null }));
  });
});

describe('matches: delete', () => {
  it('denies deletion by the host', async () => {
    await seedActiveMatch('ABCD1234');
    await assertFails(deleteDoc(matchDoc(hostDb, 'ABCD1234')));
  });
});

// =====================================================================
// matches/{code}/events/{eventId}
// =====================================================================

describe('events: create', () => {
  beforeEach(() => seedActiveMatch('ABCD1234'));

  it('lets the host append an event', async () => {
    await assertSucceeds(
      setDoc(eventDoc(hostDb, 'ABCD1234', '00000000'), newEventPayload()),
    );
  });

  it('lets the guest append an event', async () => {
    await assertSucceeds(
      setDoc(
        eventDoc(guestDb, 'ABCD1234', '00000001'),
        newEventPayload({ seq: 1, author: GUEST }),
      ),
    );
  });

  it('accepts a zero-padded id for a multi-digit seq', async () => {
    await assertSucceeds(
      setDoc(
        eventDoc(hostDb, 'ABCD1234', '00000042'),
        newEventPayload({ seq: 42 }),
      ),
    );
  });

  it('denies a non-participant append', async () => {
    await assertFails(
      setDoc(
        eventDoc(outsiderDb, 'ABCD1234', '00000000'),
        newEventPayload({ author: OUTSIDER }),
      ),
    );
  });

  it('denies an unauthenticated append', async () => {
    await assertFails(
      setDoc(eventDoc(anonDb, 'ABCD1234', '00000000'), newEventPayload()),
    );
  });

  it('denies forging another participant as author', async () => {
    await assertFails(
      setDoc(
        eventDoc(guestDb, 'ABCD1234', '00000000'),
        newEventPayload({ author: HOST }),
      ),
    );
  });

  it('denies a doc id that disagrees with seq', async () => {
    await assertFails(
      setDoc(eventDoc(hostDb, 'ABCD1234', '00000007'), newEventPayload({ seq: 3 })),
    );
  });

  it('denies an unpadded doc id', async () => {
    await assertFails(
      setDoc(eventDoc(hostDb, 'ABCD1234', '7'), newEventPayload({ seq: 7 })),
    );
  });

  it('denies a non-numeric doc id', async () => {
    await assertFails(
      setDoc(eventDoc(hostDb, 'ABCD1234', 'abcdefgh'), newEventPayload({ seq: 0 })),
    );
  });

  it('denies a non-int seq', async () => {
    await assertFails(
      setDoc(eventDoc(hostDb, 'ABCD1234', '00000000'), newEventPayload({ seq: '0' })),
    );
  });

  it('denies a negative seq', async () => {
    await assertFails(
      setDoc(eventDoc(hostDb, 'ABCD1234', '-0000001'), newEventPayload({ seq: -1 })),
    );
  });

  it('denies gameNo below 1', async () => {
    await assertFails(
      setDoc(eventDoc(hostDb, 'ABCD1234', '00000000'), newEventPayload({ gameNo: 0 })),
    );
  });

  it('denies a non-int gameNo', async () => {
    await assertFails(
      setDoc(
        eventDoc(hostDb, 'ABCD1234', '00000000'),
        newEventPayload({ gameNo: 1.5 }),
      ),
    );
  });

  it('denies a map payload (event must be a JSON string)', async () => {
    await assertFails(
      setDoc(
        eventDoc(hostDb, 'ABCD1234', '00000000'),
        newEventPayload({ event: { kind: 'roll' } }),
      ),
    );
  });

  it('accepts a payload of exactly 4096 chars', async () => {
    await assertSucceeds(
      setDoc(
        eventDoc(hostDb, 'ABCD1234', '00000000'),
        newEventPayload({ event: 'x'.repeat(4096) }),
      ),
    );
  });

  it('denies a payload over 4096 chars', async () => {
    await assertFails(
      setDoc(
        eventDoc(hostDb, 'ABCD1234', '00000000'),
        newEventPayload({ event: 'x'.repeat(4097) }),
      ),
    );
  });

  it('denies an unknown extra field', async () => {
    await assertFails(
      setDoc(
        eventDoc(hostDb, 'ABCD1234', '00000000'),
        newEventPayload({ signature: 'nope' }),
      ),
    );
  });

  it('denies a missing required field', async () => {
    const payload = newEventPayload();
    delete payload.gameNo;
    await assertFails(setDoc(eventDoc(hostDb, 'ABCD1234', '00000000'), payload));
  });

  it('denies appending to a match that is only waiting (no guest yet)', async () => {
    await seedMatch('WAITING1');
    await assertFails(
      setDoc(eventDoc(outsiderDb, 'WAITING1', '00000000'), newEventPayload({ author: OUTSIDER })),
    );
  });

  it('denies re-claiming a seq already written (contiguity)', async () => {
    await seedEvent('ABCD1234', '00000000', newEventPayload());
    await assertFails(
      setDoc(
        eventDoc(guestDb, 'ABCD1234', '00000000'),
        newEventPayload({ author: GUEST }),
      ),
    );
  });
});

describe('events: read / mutate', () => {
  beforeEach(async () => {
    await seedActiveMatch('ABCD1234');
    await seedEvent('ABCD1234', '00000000', newEventPayload());
  });

  it('lets participants read the log', async () => {
    await assertSucceeds(getDoc(eventDoc(hostDb, 'ABCD1234', '00000000')));
    await assertSucceeds(getDocs(collection(guestDb, 'matches', 'ABCD1234', 'events')));
  });

  it('denies a non-participant reading the log', async () => {
    await assertFails(getDoc(eventDoc(outsiderDb, 'ABCD1234', '00000000')));
    await assertFails(getDocs(collection(outsiderDb, 'matches', 'ABCD1234', 'events')));
  });

  it('denies an unauthenticated read', async () => {
    await assertFails(getDoc(eventDoc(anonDb, 'ABCD1234', '00000000')));
  });

  it('denies rewriting an event', async () => {
    await assertFails(
      updateDoc(eventDoc(hostDb, 'ABCD1234', '00000000'), { gameNo: 2 }),
    );
  });

  it('denies deleting an event', async () => {
    await assertFails(deleteDoc(eventDoc(hostDb, 'ABCD1234', '00000000')));
  });
});

// =====================================================================
// matches/{code}/rolls/{n}  — commit / entropy / reveal
// =====================================================================

describe('rolls: full commit-reveal dance', () => {
  beforeEach(() => seedActiveMatch('ABCD1234'));

  it('runs commit -> entropy -> reveal in order', async () => {
    await assertSucceeds(
      setDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), newRollPayload()),
    );
    await assertSucceeds(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000000'), { entropy: HEX2 }),
    );
    await assertSucceeds(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { reveal: HEX3 }),
    );
  });

  it('runs the same dance with the guest as roller', async () => {
    await assertSucceeds(
      setDoc(
        rollDoc(guestDb, 'ABCD1234', '00000001'),
        newRollPayload({ n: 1, roller: GUEST }),
      ),
    );
    await assertSucceeds(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000001'), { entropy: HEX2 }),
    );
    await assertSucceeds(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000001'), { reveal: HEX3 }),
    );
  });
});

describe('rolls: create (commit phase)', () => {
  beforeEach(() => seedActiveMatch('ABCD1234'));

  it('denies a non-participant committing', async () => {
    await assertFails(
      setDoc(
        rollDoc(outsiderDb, 'ABCD1234', '00000000'),
        newRollPayload({ roller: OUTSIDER }),
      ),
    );
  });

  it('denies an unauthenticated commit', async () => {
    await assertFails(
      setDoc(rollDoc(anonDb, 'ABCD1234', '00000000'), newRollPayload()),
    );
  });

  it('denies naming someone else as roller', async () => {
    await assertFails(
      setDoc(
        rollDoc(guestDb, 'ABCD1234', '00000000'),
        newRollPayload({ roller: HOST }),
      ),
    );
  });

  it('denies smuggling entropy into the create', async () => {
    await assertFails(
      setDoc(
        rollDoc(hostDb, 'ABCD1234', '00000000'),
        newRollPayload({ entropy: HEX2 }),
      ),
    );
  });

  it('denies smuggling reveal into the create', async () => {
    await assertFails(
      setDoc(
        rollDoc(hostDb, 'ABCD1234', '00000000'),
        newRollPayload({ reveal: HEX3 }),
      ),
    );
  });

  it('denies a commit that is not 64 lowercase hex chars', async () => {
    await assertFails(
      setDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), newRollPayload({ commit: 'abc' })),
    );
    await assertFails(
      setDoc(
        rollDoc(hostDb, 'ABCD1234', '00000001'),
        newRollPayload({ n: 1, commit: 'A'.repeat(64) }),
      ),
    );
    await assertFails(
      setDoc(
        rollDoc(hostDb, 'ABCD1234', '00000002'),
        newRollPayload({ n: 2, commit: 42 }),
      ),
    );
  });

  it('denies a doc id that disagrees with n', async () => {
    await assertFails(
      setDoc(rollDoc(hostDb, 'ABCD1234', '00000003'), newRollPayload({ n: 4 })),
    );
  });

  it('denies an unpadded doc id', async () => {
    await assertFails(setDoc(rollDoc(hostDb, 'ABCD1234', '3'), newRollPayload({ n: 3 })));
  });

  it('denies a missing field', async () => {
    const payload = newRollPayload();
    delete payload.n;
    await assertFails(setDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), payload));
  });

  it('denies re-creating a roll that already exists', async () => {
    await seedRoll('ABCD1234', '00000000', newRollPayload());
    await assertFails(
      setDoc(
        rollDoc(guestDb, 'ABCD1234', '00000000'),
        newRollPayload({ roller: GUEST }),
      ),
    );
  });
});

describe('rolls: entropy phase', () => {
  beforeEach(async () => {
    await seedActiveMatch('ABCD1234');
    await seedRoll('ABCD1234', '00000000', newRollPayload());
  });

  it('denies the roller contributing their own entropy', async () => {
    await assertFails(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { entropy: HEX2 }),
    );
  });

  it('denies a non-participant contributing entropy', async () => {
    await assertFails(
      updateDoc(rollDoc(outsiderDb, 'ABCD1234', '00000000'), { entropy: HEX2 }),
    );
  });

  it('denies an unauthenticated entropy write', async () => {
    await assertFails(
      updateDoc(rollDoc(anonDb, 'ABCD1234', '00000000'), { entropy: HEX2 }),
    );
  });

  it('denies non-hex entropy', async () => {
    await assertFails(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000000'), { entropy: 'zz' }),
    );
  });

  it('denies entropy bundled with other fields', async () => {
    await assertFails(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000000'), {
        entropy: HEX2,
        commit: HEX3,
      }),
    );
    await assertFails(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000000'), {
        entropy: HEX2,
        reveal: HEX3,
      }),
    );
  });

  it('denies overwriting entropy once written', async () => {
    await seedRoll('ABCD1234', '00000001', newRollPayload({ n: 1, entropy: HEX2 }));
    await assertFails(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000001'), { entropy: HEX3 }),
    );
  });

  it('denies entropy after the reveal already landed', async () => {
    await seedRoll(
      'ABCD1234',
      '00000002',
      newRollPayload({ n: 2, entropy: HEX2, reveal: HEX3 }),
    );
    await assertFails(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000002'), { entropy: HEX }),
    );
  });
});

describe('rolls: reveal phase', () => {
  beforeEach(() => seedActiveMatch('ABCD1234'));

  it('denies a reveal before entropy exists (phase skip)', async () => {
    await seedRoll('ABCD1234', '00000000', newRollPayload());
    await assertFails(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { reveal: HEX3 }),
    );
  });

  it('denies a reveal by the non-roller', async () => {
    await seedRoll('ABCD1234', '00000000', newRollPayload({ entropy: HEX2 }));
    await assertFails(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000000'), { reveal: HEX3 }),
    );
  });

  it('denies a reveal by a non-participant', async () => {
    await seedRoll('ABCD1234', '00000000', newRollPayload({ entropy: HEX2 }));
    await assertFails(
      updateDoc(rollDoc(outsiderDb, 'ABCD1234', '00000000'), { reveal: HEX3 }),
    );
  });

  it('denies non-hex reveal', async () => {
    await seedRoll('ABCD1234', '00000000', newRollPayload({ entropy: HEX2 }));
    await assertFails(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { reveal: 'deadbeef' }),
    );
  });

  it('denies overwriting a reveal once written', async () => {
    await seedRoll(
      'ABCD1234',
      '00000000',
      newRollPayload({ entropy: HEX2, reveal: HEX3 }),
    );
    await assertFails(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { reveal: HEX }),
    );
  });

  it('denies a reveal bundled with other field changes', async () => {
    await seedRoll('ABCD1234', '00000000', newRollPayload({ entropy: HEX2 }));
    await assertFails(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), {
        reveal: HEX3,
        commit: HEX3,
      }),
    );
  });
});

describe('rolls: immutability, read, delete', () => {
  beforeEach(async () => {
    await seedActiveMatch('ABCD1234');
    await seedRoll('ABCD1234', '00000000', newRollPayload());
  });

  it('denies changing commit', async () => {
    await assertFails(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { commit: HEX3 }),
    );
  });

  it('denies changing roller', async () => {
    await assertFails(
      updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { roller: GUEST }),
    );
  });

  it('denies changing n', async () => {
    await assertFails(updateDoc(rollDoc(hostDb, 'ABCD1234', '00000000'), { n: 9 }));
  });

  it('denies adding an unknown field', async () => {
    await assertFails(
      updateDoc(rollDoc(guestDb, 'ABCD1234', '00000000'), { dice: [3, 1] }),
    );
  });

  it('lets participants read rolls', async () => {
    await assertSucceeds(getDoc(rollDoc(hostDb, 'ABCD1234', '00000000')));
    await assertSucceeds(getDocs(collection(guestDb, 'matches', 'ABCD1234', 'rolls')));
  });

  it('denies a non-participant reading rolls', async () => {
    await assertFails(getDoc(rollDoc(outsiderDb, 'ABCD1234', '00000000')));
  });

  it('denies an unauthenticated read', async () => {
    await assertFails(getDoc(rollDoc(anonDb, 'ABCD1234', '00000000')));
  });

  it('denies deleting a roll', async () => {
    await assertFails(deleteDoc(rollDoc(hostDb, 'ABCD1234', '00000000')));
  });
});

// =====================================================================
// catch-all
// =====================================================================

describe('everything else', () => {
  it('denies reads and writes outside the match model', async () => {
    await assertFails(getDoc(doc(hostDb, 'users', HOST)));
    await assertFails(setDoc(doc(hostDb, 'users', HOST), { rating: 1800 }));
    await assertFails(
      setDoc(doc(hostDb, 'matches', 'ABCD1234', 'chat', 'x'), { text: 'hi' }),
    );
  });
});
