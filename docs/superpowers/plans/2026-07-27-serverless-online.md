# Serverless Online Play Implementation Plan (Plan 16)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Online play on Firebase's free Spark plan — zero Cloud Functions. Firestore documents + security rules + anonymous Auth; dice fairness via a client commit-reveal protocol; both clients validate with the full rules engine (honest-client trust model, same as LAN).

**Approved trade-off:** a hacked client can stall a match but cannot win by cheating (illegal events refused by the honest client; dice unbiasable via commit-reveal). Invite-code friends-only play.

**Architecture:**
- `matches/{code}`: doc ID **is** the invite code (8 random alphanumerics, `Random.secure`). Fields: `hostUid`, `guestUid` (null until join), `length`, `cubeless`, `status` ('waiting'|'active'|'complete'), `createdAt`. Readable pre-join iff `status=='waiting'` (join-by-code = direct doc get); post-join participants only.
- `matches/{code}/events/{seq}`: docId = zero-padded seq (uniqueness = contiguity weapon: create fails on existing id). Fields: `seq`, `gameNo`, `event` (backgammon_core JSON), `author` (uid). CREATE-only (no update/delete in rules); `author == request.auth.uid`; structural shape checks (field types, size). Turn/side/legality enforced client-side by the honest peer (fold refuses illegal events and surfaces a cheat error).
- `matches/{code}/rolls/{n}`: commit-reveal per roll. Phases as fields with rules-enforced ordering + immutability: roller creates `{commit: sha256hex(secretA)}`; opponent updates adding `entropy` (secretB) iff absent; roller updates adding `reveal` (secretA) iff entropy exists; each field write-once, owner-checked. Dice = deterministic derivation from sha256(secretA || secretB) (both compute; opponent verifies `sha256hex(reveal) == commit` — Firestore rules cannot hash; verification is client-side, mismatch = cheat flag). The subsequent RollEvent in the event log must carry exactly the derived dice (honest peer validates).
- Auth: anonymous sign-in via Identity Toolkit REST (pure Dart — NO FlutterFire, per the established Windows constraint). Existing REST transport/polling stays.
- History: stays local (drift), unchanged.

---

### Task 1: Data model + security rules + rules tests
`firebase/firestore.rules` rewritten for the model above (matches read gates, join transition — guest may set `guestUid` iff currently null and `status=='waiting'`, then `status:'active'`; events create-only with author/shape checks; rolls phase ordering/immutability/ownership; deny everything else incl. deletes). Emulator rules tests (extend `firebase/run-emulator-tests.ps1` suite — @firebase/rules-unit-testing): every allow and every deny path (non-participant read, second join, event update/delete, wrong-author event, roll phase skips, field overwrite attempts, oversized payloads).

### Task 2: Commit-reveal roll protocol (packages/online_client)
`lib/src/fair_dice.dart`: pure-Dart protocol engine — secret generation (32 bytes, `Random.secure`), sha256 via `package:crypto`, phase state machine for BOTH roles (roller: commit→await entropy→reveal→derive; opponent: await commit→contribute→await reveal→verify+derive), dice derivation (first bytes of sha256(secretA||secretB) mod 6 + 1, rejection-sampled for uniformity), `FairDiceCheat` error on hash mismatch. Unit tests: derivation determinism + uniformity smoke (chi-square-ish over 10k), verify/cheat paths, role state machines, vector fixtures (fixed secrets → fixed dice, cross-checked in the test by independent recomputation).

### Task 3: Transport rewrite (packages/online_client)
`match_api.dart` reworked: callables → direct Firestore document REST (create match doc, join via get+update, event create, rolls doc phases, polling unchanged in spirit — poll events + active roll doc). Anonymous auth REST (`accounts:signUp` with API key → idToken/refresh, refresh handling). Keep the transport interface the controller consumes as stable as possible (the controller folds seq-contiguous events — unchanged). Emulator integration tests for each op incl. rules-rejection surfacing (typed errors).

### Task 4: Controller adaptation (app)
`OnlineMatchController`: rolling = drive the fair-dice protocol (both roles), write RollEvent with derived dice; folding gains opponent-event VALIDATION (turn/side/legality via the rules engine + dice-vs-protocol check) — an invalid event → `cheat`-class error state (match frozen with a clear message, never silently accepted; distinct from transient errors so it doesn't self-heal). Tests: fake-transport both roles through a scripted match; tampered opponent event → frozen with cheat error; tampered reveal → FairDiceCheat surfaced; transient errors still self-heal.

### Task 5: Two-client emulator E2E
Rewrite `firebase/ci-emulator-suites.sh` + the two-client test: full match over the Firestore emulator ONLY (no functions emulator) — both clients, commit-reveal rolls, completion, plus adversarial legs: direct-write forgery attempts that rules must block, and a rules-passing-but-illegal event that the honest client must freeze on.

### Task 6: Teardown, CI, docs, ship v0.10.0
Delete `firebase/functions/` + turnflow.ts (git history keeps them); ci.yml online job drops the functions build, keeps rules+emulator suites; rewrite `firebase/DEPLOY.md` for Spark: enable anonymous auth (console), `firebase deploy --only firestore:rules`, Web API key + project id into repo Variables — explicitly "no Blaze, no card". Full matrix, whole-branch review (rules adversarial pass), merge, ship v0.10.0, memory, report incl. the user's deploy steps.
