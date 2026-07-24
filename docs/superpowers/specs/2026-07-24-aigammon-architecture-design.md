# AIGammon — Architecture & Engine Integration Design

**Date:** 2026-07-24
**Status:** Approved

## Overview

AIGammon is a cross-platform mobile backgammon app built with Flutter. Four play
modes: vs computer, vs human on the same device (hot-seat), vs human on another
device (online), and a tutor mode that scores moves and shows best moves in any
mode. Full rules in v1: doubling cube, match play to N points, Crawford rule,
gammon/backgammon scoring.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Framework | Flutter | Single codebase, custom-drawn board UI, first-class C interop via `dart:ffi` |
| AI engine | wildbg (Rust, MIT/Apache-2.0), embedded | Strong neural-net engine, permissive license (App Store safe), runs offline |
| Rules of record | Pure Dart package (`backgammon_core`) | Testable, shared by all modes, fast iteration; engine only evaluates |
| Online backend | Firebase (anonymous Auth, Firestore, Cloud Functions) | Turn-based sync without running servers; server-authoritative dice |
| Game representation | Event-sourced append-only log | One primitive powers replay, undo, online sync, and post-game analysis |
| Inference backend | tract (pure Rust ONNX) | No ONNX Runtime binary to bundle; simpler mobile builds |

## 1. High-level architecture

Monorepo, strict dependency direction (UI → state → domain → engine/data):

```
aigammon/
├── app/                        # Flutter app (UI, state, navigation)
├── packages/
│   ├── backgammon_core/        # Pure Dart rules engine — zero dependencies
│   └── engine_bindings/        # dart:ffi bindings + isolate wrapper for wildbg
├── native/
│   └── wildbg/                 # Vendored wildbg (git submodule) + C shim + build scripts
├── firebase/                   # Cloud Functions (TypeScript), Firestore security rules
└── docs/
```

- **UI layer:** Flutter widgets. The board is a `CustomPaint` with gesture
  handling (tap or drag checkers). Implicit animations for checker movement.
  No game framework needed.
- **State layer:** Riverpod. A `GameController` runs every game as a state
  machine, identical across modes.
- **Domain:** `backgammon_core`, pure immutable Dart — the single source of
  truth for rules.
- **Engine:** wildbg behind a small FFI surface, running in a background
  isolate.
- **Backend:** Firebase — used only for online mode.

## 2. Domain model (`backgammon_core`)

- `BoardState` — 24 points + bar + borne-off per player. Immutable value type.
- `GameState` — board, dice, player to act, cube (value, owner, dead/live,
  Crawford), phase: `awaitingRoll | moving | cubeOffered | resignOffered |
  gameOver`.
- `MatchState` — match length, score, Crawford tracking, list of games.
- `MoveGenerator.legalMoves(state, dice)` — complete rules: bar entry, bear-off,
  forced moves, must-play-both-dice, higher-die-if-only-one-playable, doubles.
- **Event sourcing:** a game is an append-only log of `GameEvent`s (`Roll`,
  `Move`, `Double`, `Take`, `Drop`, `Resign`). Current state = fold(events).
  Replay, undo, online sync, and analysis all consume this one primitive.
- **Serialization:** JSON for events and states. Boards also export
  gnubg-compatible Position IDs for debugging and test fixtures.

## 3. Engine integration (wildbg via FFI)

- wildbg is vendored as a git submodule. A small Rust C-shim crate exports
  roughly four functions: `init`, `best_moves(position, dice, topN)` → ranked
  moves with equities, `evaluate(position)` → win/gammon/backgammon
  probabilities, `cube_info(position)`.
- Neural-net inference uses **tract** (pure Rust ONNX inference), avoiding an
  ONNX Runtime dependency in mobile builds.
- **Builds:** `cargo-ndk` → `jniLibs` for Android (arm64-v8a, armeabi-v7a,
  x86_64 for emulators); XCFramework for iOS device + simulator. Build scripts
  live in `native/wildbg/`, run in CI.
- **Dart side:** `EngineService` in a dedicated isolate; typed async API:
  `rankMoves(GameState, {topN})`, `cubeAdvice(GameState)`,
  `evaluate(GameState)`. The UI never blocks on inference.
- **Match-play math lives in Dart:** wildbg supplies raw probabilities; a Dart
  module applies a match equity table and Janowski cube formulas to produce
  match-aware equities and cube decisions. An early implementation spike
  confirms how much of this wildbg's own cube API covers; the Dart layer is the
  match-play adapter either way, and is unit-tested against published tables.
- **Difficulty levels:** Expert plays the engine's best move; lower levels
  sample from the top-k moves with increasing randomness (equity-noise /
  temperature). One engine serves all difficulties.

## 4. Game modes & data flow

A single abstraction unifies all modes: `PlayerAgent`.

| Agent | Source of moves |
|---|---|
| `LocalHumanAgent` | board taps/drags |
| `AiAgent` | `EngineService` |
| `RemoteAgent` | Firestore event stream |

`GameController` requests decisions (roll, move, cube action) from the agent
whose turn it is, validates them via `backgammon_core`, appends the event, and
advances the state machine.

- **vs Computer / hot-seat:** both agents local; dice from `Random.secure()`.
  Hot-seat shows a pass-device prompt between turns.
- **Online:** `/matches/{id}` document (players, match metadata, invite code) +
  append-only `events` subcollection. Firestore security rules enforce turn
  order and event shape. **Dice are rolled by a Cloud Function**
  (server-authoritative — clients cannot influence rolls). Clients validate
  every incoming event with `backgammon_core`; on any divergence, state is
  rebuilt from the event log, which is authoritative.
- **Invites:** 6-character match code, shareable as a link. Anonymous Firebase
  Auth by default; account linking is a later feature.
- Online games are async/correspondence-friendly. FCM "your turn" push
  notifications are optional in v1.

## 5. Tutor mode

Tutor mode is a read-only overlay on any game mode — it never mutates game
state.

- **Live:** after each human move, the engine compares the chosen move against
  the best move; equity loss beyond thresholds is marked (dubious / error /
  blunder) with a subtle indicator. A hint button shows the top-N candidate
  moves ranked by equity. Cube advice is available on every double/take
  decision.
- **Post-game:** a background job replays the event log through the engine and
  produces per-move equity loss, a blunder list, and overall error rates per
  player (gnubg-style). Results are stored locally and browsable in an
  analysis screen with step-through board replay.
- Online, tutor analyzes only the local player's own moves. No ratings exist in
  v1, so live hints raise no fairness concerns yet; revisit if rated play is
  added.

## 6. Persistence

drift (SQLite) stores matches, event logs, analysis results, and settings.
Online games are cached locally in the same event schema as local games.

## 7. Error handling

- **Engine failure** (library load or inference error): AI opponent falls back
  to a simple pip-count heuristic with a visible notice; tutor features disable
  with a banner. The app never becomes unplayable.
- **Network:** Firestore offline persistence queues outgoing moves; streams
  resume on reconnect. If an opponent goes silent, the player can leave the
  match (no forfeit-claim logic in v1).
- **State divergence online:** the event log is the source of truth; clients
  rebuild state from it on mismatch.
- **Engine isolate crash:** supervised restart; in-flight requests are retried
  once, then surface the engine-failure fallback.

## 8. Testing

- `backgammon_core`: exhaustive unit tests. Move generation is validated
  against gnubg-generated fixtures (positions with known legal move sets),
  property tests enforce rules like maximal dice usage, plus Crawford and
  match-scoring edge cases.
- Match equity + Janowski math: tested against published tables.
- Engine bindings: on-device integration tests — golden positions must return
  sane probabilities (sum/range checks, no NaN) and known-best moves.
- `GameController`: full AI-vs-AI simulated games must complete with no illegal
  states across many seeds.
- Firebase: security-rules tests and Cloud Function tests on the Firebase
  emulator suite.
- UI: widget tests for move input; golden tests for board rendering.

## Out of scope for v1

Random matchmaking, ratings, tournaments, chat, account profiles, cloud
deep-analysis (gnubg server-side) — the architecture leaves room for each, but
none are designed here.

## References

- wildbg: https://github.com/carsten-wenderdel/wildbg (MIT/Apache-2.0)
- Announcement discussion: https://lists.nongnu.org/archive/html/bug-gnubg/2023-11/msg00002.html
