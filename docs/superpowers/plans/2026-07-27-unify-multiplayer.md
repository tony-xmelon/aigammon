# Unified Multiplayer Implementation Plan (Plan 17)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Collapse LAN play and online play into ONE trust model, ONE controller, and ONE dice protocol behind a `MatchTransport` interface with two thin implementations (socket, Firestore). Online gains real-time listeners (instant delivery, far fewer billed reads). No mid-match transport swap.

**The unification insight:** online's trust model (commit-reveal fair dice so neither peer trusts the other + both peers validate every opponent event, freezing on a cheat) is a strict SUPERSET of LAN's host-authoritative model. Adopting commit-reveal + mutual validation everywhere lets us DELETE `HostAuthority` (the LAN referee) and merge `LanMatchController` + `OnlineMatchController` into one controller. The transport becomes a dumb pipe: carry seq-numbered events + the 3-message roll handshake, expose a live inbound stream, a fetch-since-seq for resync, and a connection-state signal. Whoever binds the LAN socket is just a network role, no longer a game authority.

**Trust posture (unchanged from shipped online v0.10):** friends via invite code / nearby; a hostile peer can stall but cannot bias dice (commit binds before entropy) or land an illegal move (honest peer freezes). LAN moves from host-authoritative to symmetric — strictly fairer for two strangers; each LAN roll gains a 3-message handshake (microseconds over a local socket).

**Sequencing de-risks:** the unification lands on PROVEN mechanics first (Tasks 1-4 reuse the existing Firestore polling + socket relay); real-time listeners are isolated in Task 5 so a gRPC hiccup can't sink the merge.

**Packages:** new pure-Dart `packages/match_transport` holds the `MatchTransport` interface, the shared wire message types, and `fair_dice.dart` (moved from online_client). `packages/lan_play` and `packages/online_client` both depend on it and each provide one `MatchTransport`. The unified controller lives in `app/lib/net/` (it uses `ValueListenable`, so it stays in the Flutter app layer). All pure-Dart + Windows-headless-testable, as today.

---

### Task 1: `MatchTransport` interface + shared package + in-memory fake
- Create `packages/match_transport` (pure Dart, dep: `backgammon_core`). Define:
  - `MatchTransport` abstract interface: `Future<TransportSession> connect()` returning `{assignedSide, matchConfig, resumeToken?}`; `Stream<InboundFrame> inbound` (a broadcast-safe, replayable-from-buffer stream of `EventFrame{seq,gameNo,event,author}` and `RollFrame{n, commit?, entropy?, reveal?, roller}`); `Future<void> sendEvent(seq, gameNo, GameEvent)`; roll ops `createRoll(n, commit)`/`sendEntropy(n, entropy)`/`sendReveal(n, reveal)`; `Future<List<EventFrame>> eventsSince(int seq)` + `Future<RollFrame?> fetchRoll(int n)` (resync); `ValueListenable<TransportStatus> status` (connecting/connected/reconnecting/failed/frozen-n/a); `Capabilities {durable, rejoinable}`; `void dispose()`. Typed errors (`TransportRejected` = rules/relay refusal never-retry, `TransportContested` = seq/roll collision → resync, `TransportUnavailable` = transient).
  - Move `fair_dice.dart` (+ its tests) from `online_client` into this package unchanged (RollerSession/WitnessSession/CompletedRoll/diceMatchRoll/openingDiceMatchRoll/FairDiceCheatException). Update `online_client` to re-export or depend.
  - `InMemoryTransport` (test double): a bidirectional in-process pair for driving two unified controllers with scripted dice (fold the best of `app/test/online/fake_online_backend.dart` + `app/test/lan/lan_harness.dart`).
- Tests: interface contract tests against `InMemoryTransport` (event ordering, resync gap fill, roll-frame delivery, status transitions); fair_dice suite still green after the move.
- **Commit:** `feat(match): MatchTransport interface + shared fair-dice + in-memory transport`

### Task 2: Unified controller (`app/lib/net/net_match_controller.dart`)
- ONE `MatchController` implementation over a `MatchTransport`, folding the seq-contiguous event log (reuse the AppliedMove preBoard-at-fold contract, buffering during the game-over pause, watermark-guarded persistence). Adopt EVERY hardened behavior from both shipped controllers:
  - Commit-reveal for its OWN rolls (roller role); witness the opponent's — **due-roll-only** (`n == rollCount+1`, roller must be on-turn) to close the P16 dice-lookahead; backoff-on-incomplete-roll (no synchronous refetch spin); the opening roller is a deterministic seat (white/host-seat), documented.
  - Mutual validation on fold: every opponent event validated (author↔side, turn legality via the rules engine, RollEvent dice == completed roll doc via `diceMatchRoll`) → `cheat`-class FREEZE (distinct from self-healing transient errors; never unfreezes).
  - Resync = full replace-from-log with the three surviving watermarks (`_persistedThrough`/`_acknowledgedThrough`/`_matchPersisted`); match-identity reset on a foreign resume token.
  - Durable rejoin gated on `transport.capabilities.rejainable` (Firestore yes, socket no).
  - `submitting`/`linkStatus`/adaptive-poll-hint pass-through as today.
- DELETE `app/lib/online/online_match_controller.dart` and `app/lib/lan/lan_match_controller.dart` once this replaces them (do it in Task 3/4 as each transport lands; here just add the new controller + its fake-transport tests).
- Tests (against `InMemoryTransport`, both roles): full scripted match incl. cube take+drop, resign, dance, opening + regular rolls; opponent illegal event → freeze; tampered reveal → FairDiceCheat freeze; RollEvent≠rolldoc → freeze; transient error self-heals; resync path + roll-counter recovery; dice-lookahead squat gets no entropy. This suite is the merged superset of both old controller suites.
- **Commit:** `feat(net): unified match controller over MatchTransport`

### Task 3: SocketTransport (refactor `packages/lan_play`)
- DELETE `host_authority.dart` (+ its tests). `HostServer`/`GuestClient` become a **bidirectional relay** implementing `MatchTransport`: keep the WebSocket bind/connect, room-code auth, single-guest slot, generation-guarded reconnect, heartbeat, discovery (UDP beacon/prober), `LanTimings`. Strip all referee logic — the server peer just relays each side's frames to the other and echoes for resync (it must retain the seq log in memory to answer `eventsSince`/`fetchRoll` after a reconnect). Both peers now run the unified controller; "host" = whoever binds. Assigned side comes from the match config the host sets (host=white, joiner=black — document).
- Rewire `app/lib/screens/lan_screen.dart` + `app/lib/lan/lan_transport.dart` to build a `SocketTransport` + the unified controller; delete `LanMatchController`.
- Tests: lan_play relay tests (frame relay both ways, resync-after-reconnect, room-code/busy/heartbeat unchanged); two unified controllers over a REAL loopback socket pair playing a full match incl. reconnect (port the `lan_full_match_test` convergence assertions).
- **Commit:** `refactor(lan): socket transport relay, HostAuthority deleted`

### Task 4: FirestoreTransport — polling first (refactor `packages/online_client` + app)
- Implement `MatchTransport` over the existing Firestore document model (matches/events/rolls docs + rules UNCHANGED; commit-reveal roll docs stay) using the CURRENT REST polling (known-good) — `inbound` is fed by the poll loop; `eventsSince`/`fetchRoll` are direct gets; anonymous auth + durable TokenStore + rejoin (`capabilities.rejoinable = true`) carried over. Keep adaptive fast/slow poll.
- Rewire `app/lib/screens/online_screen.dart` + `online_providers.dart` to build a `FirestoreTransport` + the unified controller; delete `OnlineMatchController`.
- Tests: online_client transport tests (unit + emulator) reframed to the interface; two unified controllers over the Firestore emulator playing a full match + the adversarial legs (rules-blocked forgeries, illegal-event freeze, tampered-reveal freeze, lookahead-squat-no-entropy) — port from the shipped E2E.
- **Commit:** `refactor(online): Firestore transport (polling), OnlineMatchController deleted`

### Task 5: Real-time listeners on FirestoreTransport
- Replace the poll loop with a Firestore **Listen** stream via `package:grpc` (pure Dart, Windows-testable, works against the emulator) on `firestore.googleapis.com` authed with the idToken: listen to the events + active-roll subcollections; map change deltas to `InboundFrame`s. **Fallback:** on stream error/close, fall back to the Task-4 polling loop and retry the listener with backoff (never leave the match dead). Bill note: a listen is charged per delivered document, not per poll — document the quota win in DEPLOY.md (revise the ~5-10 matches/day figure upward). Emulator variant wired.
- Tests: emulator listener delivers events/rolls in order incl. mid-match; listener-drop → poll fallback → listener recovery; the full-match + adversarial E2E re-run green on the listener path; unit tests for the delta→frame mapping against a fake gRPC stream.
- **Commit:** `feat(online): real-time Firestore listeners with polling fallback`

### Task 6: Verify, review, merge, ship v0.11.0
Full matrix (all packages) + the whole emulator pipeline + both loopback/E2E suites; whole-branch review (trust-model equivalence: the unified controller must preserve every security property of both shipped systems — adversarial re-verification of the freeze paths and the lookahead defense on BOTH transports; confirm HostAuthority's deletion lost no protection); UX tour additions if screens changed; DEPLOY.md quota update; delete dead code; memory update; feedback→resolution report + the final architecture summary (one controller, one trust model, two transports). Bump 0.11.0+13.
