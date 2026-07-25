# Tutor Mode + Persistence Implementation Plan (Plan 4 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The learning loop that names the app: live hints and move scoring during play, cube advice that respects the match score, post-game blunder analysis, and local persistence of matches — plus the three recorded Plan-3 carry-overs (board flip, AI resign policy, match-aware cube advice).

**Architecture:** Tutor is a read-only overlay (spec §5): it evaluates via the existing `EngineService.rankMoves`/`evaluate` and never mutates game state. Match-aware cube decisions get the deferred Dart adapter: a generated match-equity table (MET) + Janowski cubeful equities over wildbg's cubeless probabilities, living in `engine_bindings` (`MatchCubeAdvisor`). Persistence uses drift (SQLite) in the app: matches/games stored as the SAME JSON event logs the core already emits; analysis results cached alongside. Post-game analysis replays the event log through the engine in the background. All new UI hangs off the existing GameScreen/GameController seams.

**Tech Stack:** existing stack + `drift`/`drift_flutter` (+ `sqlite3_flutter_libs`), gnubg's MET XML (vendored data file, MIT-compatible data), no new native code.

**Environment:** Windows dev box, Flutter 3.44.8, Developer Mode ON, engine DLL + nets staged, suites at: core 107, bindings 11+16, app 81 (78 in CI, goldens Windows-only) + desktop E2E. All commands via PowerShell with PATH refresh: `$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')`.

**Working agreements:** unchanged — TDD, analyzer clean, commit per task; engine-dependent tests tagged `engine` in engine_bindings, plain widget tests in app.

---

### Task 1: Match equity table (MET) module in engine_bindings

The deferred Plan-2 decision comes due: cube advice at match scores needs a MET.

**Files:** Create `packages/engine_bindings/tool/generate_met.dart`, `packages/engine_bindings/assets/met/Kazaross-XG2.xml` (vendored from gnubg source — fetch `https://raw.githubusercontent.com/gnubg/gnubg/master/met/Kazaross-XG2.xml` or the gnu.org cgit mirror; record provenance + license header), `packages/engine_bindings/lib/src/met.dart` (GENERATED — header comment says so), test `packages/engine_bindings/test/met_test.dart`.

- The generator parses the XML (pre/post-Crawford tables) and emits a Dart file: `class MatchEquityTable { static double preCrawford(int awayA, int awayB); static double postCrawford(int away); ... }` covering away scores 1..25, values = probability player A wins the match from that score.
- Tests: symmetry `preCrawford(a,b) + preCrawford(b,a) ≈ 1`; `preCrawford(1,1) == 0.5`; monotonicity in each argument; a regeneration-drift guard (test re-parses the XML at test time and compares against the generated constants); spot values quoted FROM THE VENDORED XML (read them out of the file in the test setup, not hardcoded from memory).
- Commit: `feat(bindings): Kazaross-XG2 match equity table (generated from vendored gnubg XML)`

### Task 2: MatchCubeAdvisor (Janowski + MET)

**Files:** Create `packages/engine_bindings/lib/src/match_cube_advisor.dart`; test `packages/engine_bindings/test/match_cube_advisor_test.dart` (pure math — NOT engine-tagged) + a small engine-tagged sanity test appended to the existing integration file.

API:
```dart
/// Match-aware cube decisions from cubeless probabilities (wildbg) using
/// match equities (MET) — the adapter Plan 2 deferred. Money game falls
/// back to wildbg's own cube_info via the caller; this class is for match
/// play (xAway/oAway >= 1). Crawford: doubling is illegal — callers guard.
class MatchCubeAdvisor {
  const MatchCubeAdvisor();
  MatchCubeAdvice advise({
    required Probabilities probs, // mover's perspective (the potential doubler)
    required int moverAway,
    required int opponentAway,
    required int cubeValue,       // current value (before doubling)
    required bool moverOwnsOrCentered,
  });
}
class MatchCubeAdvice { final bool shouldDouble; final bool shouldTake; final double takePoint; final double doublePoint; ... }
```
Method (document with references in code): compute match equities for the four cash/win outcomes (win/lose `cubeValue` and `2*cubeValue` points, gammon-adjusted using the cumulative gammon probabilities), derive take point and double point per standard MET-based formulas (dead-cube model v1 — document that cube-life refinement is a future nicety), decide double/take. Tests: hand-computed cases at 2-away/2-away (take point 0.5 exactly under dead cube — classic result), 1-away post-Crawford-ish guards, money-consistency limit (large away scores approach money take point ~0.20 gammonless dead-cube ~0.25? verify formulas from first principles in the test derivation comments), asymmetric gammonful cases computed by hand in test comments. The engine-tagged sanity: crushing-race position → advise says double/pass at 5-away/5-away.
Commit: `feat(bindings): match-aware cube advisor (Janowski/MET, dead-cube v1)`

### Task 3: Wire match-aware cube into agents + controller

**Files:** Modify `app/lib/game/player_agent.dart` (AiAgent), `app/lib/game/game_controller.dart` (pass away scores), tests.

- `AiAgent.considerDouble`/`chooseCubeResponse`: when the match context says match play (need away scores — thread them: GameController knows `match`; add them to the CALL: change `PlayerAgent.considerDouble(GameState state)` to `considerDouble(GameState state, MatchContext ctx)` where `MatchContext {int moverAway, int opponentAway}`? Smaller: GameController already constructs agents… simplest stable approach: add an optional `MatchContext` param object to the two cube verbs with a default of money — update interface + implementations + controller call sites + all fakes).
- AiAgent uses `MatchCubeAdvisor` with `evaluate()` probabilities for match play; keeps wildbg `cubeInfo` for money (matchLength… we always have a match; use the advisor whenever away scores are finite, i.e. always — retire the cubeInfo path for the BOT's decisions but KEEP cubeInfo for money-style tutor display? Decision: bot always uses the advisor (match-correct); document). Also implement the deferred AI resign policy: accept a resignation iff the offered value ≥ what the position's equity suggests (evaluate → if opponent's resign value multiplier covers the win probability class: accept when `probs.winGammon` (from acceptor perspective…) — implement the simple rule: accept unless the acceptor's evaluation shows ≥ the next-higher outcome class is likely (win_g > 0.5 of wins etc.); keep it simple, comment the heuristic, test both branches with fakes).
- Controller passes away scores from `match` (`matchLength - whiteScore` etc.).
- Tests updated (fakes grow the param; new cases: at 2-away/2-away the bot's take decision differs from money where the advisor says so — fake facade returns fixed probs, assert routing).
Commit: `feat(app): match-aware AI cube decisions and equity-based resign policy`

### Task 4: Board flip for hot-seat

**Files:** Modify `app/lib/screens/game_screen.dart`, `app/lib/screens/new_match_screen.dart`, tests.

- New-match (hot-seat only): toggle "Rotate board for Black" (default ON). GameScreen: when enabled and both human, pass `whiteAtBottom: state.turn == Player.white` styled through the pass-device overlay moment (orientation changes only while the overlay hides the board — flip together with overlay dismissal to avoid mid-turn rotation). vs-AI: human side always at bottom (pass `whiteAtBottom: humanIsWhite`).
- Widget tests: orientation flips across the overlay in hot-seat with toggle on; stays fixed with toggle off; vs-AI black human gets black-at-bottom (probe painter geometry.whiteAtBottom via the CustomPaint).
Commit: `feat(app): board orientation follows the active player in hot-seat`

### Task 5: Tutor settings + TutorService (equity loss, classification)

**Files:** Create `app/lib/tutor/tutor_service.dart`, `app/lib/tutor/move_assessment.dart`; modify `app/lib/screens/new_match_screen.dart` (tutor toggle, vs-computer + hot-seat), tests `app/test/tutor/tutor_service_test.dart`.

```dart
enum MoveMark { best, good, dubious, error, blunder } // thresholds: <0.02, <0.05, <0.11, <0.16, >=0.16 equity loss (gnubg-like; constants named, documented)
class MoveAssessment { final Move played; final Move best; final double equityLoss; final MoveMark mark; final List<ScoredMove> ranked; }
class TutorService {
  TutorService(EngineFacade engine);
  Future<List<ScoredMove>> hint(GameState state);            // ranked candidates (top N handled by UI)
  Future<MoveAssessment> assess(GameState before, Move played); // rank, find played (sameAs) in ranking, equity loss vs best
  Future<CubeAssessment> assessCube(...);                     // vs MatchCubeAdvisor recommendation (match-aware)
}
```
`EngineFacade` gains `evaluate` (add to the facade interface + adapters + fakes — small ripple). Pure tests with a fake facade: assessment marks per thresholds, played-move-not-in-ranking (transit representative) resolved via `sameAs` OR position-equivalence fallback (apply and compare boards — reuse core helpers), dance assessment (no legal moves → equityLoss 0, mark best).
Commit: `feat(app): tutor service with move assessment and marks`

### Task 6: Live tutor UI

**Files:** Modify `app/lib/screens/game_screen.dart` (+ small widgets under `app/lib/tutor/`), tests.

- When tutor is ON and it's a human's moving phase: a Hint button (action bar) → bottom-sheet-style in-tree panel listing top 5 ranked moves (notation via `CheckerMove.toString`, equity, delta vs best); tapping a row pre-loads the MoveBuilder? v1: NO — display only (document; entry stays manual).
- After a human commits a move: TutorService.assess runs async; result shows as a transient chip (mark icon + equity loss, e.g. "Blunder −0.31") near the HUD; taps expand to show the best move. NOT shown for AI moves.
- Cube moments: when the human faces a double (cube dialog) or considers doubling (pre-roll gate with legal double), a small advice line (match-aware via TutorService.assessCube) inside the existing dialog/action bar area.
- All tutor UI is absent when tutor is OFF (default OFF for hot-seat, ON for vs-computer? Decision: default ON for vs-computer easy/medium, OFF otherwise; the toggle rules — keep the toggle authoritative, defaults per mode; document).
- Widget tests with fake facade: hint panel lists ranked moves; assessment chip appears with correct mark after a scripted bad move; no tutor UI when off; cube advice line renders.
Commit: `feat(app): live hints, move marks, and cube advice overlay`

### Task 7: Persistence layer (drift)

**Files:** Create `app/lib/data/database.dart` (drift tables + DAO), `app/lib/data/match_repository.dart`; modify `app/pubspec.yaml` (drift, drift_flutter, sqlite3_flutter_libs, drift_dev+build_runner dev-deps); tests `app/test/data/match_repository_test.dart` (drift in-memory NativeDatabase — runs on host, no plugin needed).

Schema: `Matches` (id, createdAt, matchLength, mode, whiteType/blackType (human/ai+difficulty), finalWhiteScore, finalBlackScore, winner, completed bool), `Games` (id, matchId FK, gameNumber, eventsJson TEXT (the core event log), isCrawford, resultWinner/points/outcome, analysisJson TEXT NULL). Repository API: `startMatch(...) -> MatchRecord`, `recordGame(matchId, Game game, ...)`, `completeMatch(...)`, `watchMatches()`, `loadGameEvents(gameId) -> List<GameEvent>` (round-trip through `GameEvent.fromJson`), `saveAnalysis(gameId, json)`. GameController integration: a `MatchPersistence` hook interface the controller calls at game end / match end (implemented by the repository; a no-op impl for tests). Wire construction in new_match_screen; drift database provider in Riverpod (lazy, app-support dir via drift_flutter; in-memory for tests).
Tests: full round-trip (record → load → `Game.replay(loadedEvents)` state equals original final state), watchMatches emits, analysis save/load.
Commit: `feat(app): drift persistence for matches and event logs`

### Task 8: Post-game analysis + history + analysis screen

**Files:** Create `app/lib/tutor/game_analyzer.dart`, `app/lib/screens/history_screen.dart`, `app/lib/screens/analysis_screen.dart`; modify home (History button), game-end flow (auto-queue analysis when tutor on), tests.

- `GameAnalyzer(TutorService)`: walks a game's event log (`Game.replay` prefix states), assesses every human/both-sides MoveEvent (`assess`), produces `GameAnalysis { moves: [MoveAnalysis(eventIndex, player, assessment)], errorRate(player), blunderCount(player) }`, JSON (de)serializable → saved via repository. Pure tests with fake facade (scripted equities → known marks/rates).
- History screen: list matches (score, date, mode, completed); tap → games list → analysis screen.
- Analysis screen: step-through replay (prev/next buttons over `Game.replay` prefixes, non-interactive BoardView) with per-move mark badge, equity loss, best-move line; blunder list jump-links; per-player error-rate summary header. Runs `GameAnalyzer` on demand when no cached analysisJson (progress indicator; engine via facade provider).
- Widget tests with canned analysis JSON + fake facade: history renders records; analysis screen steps through and shows marks; blunder jump works.
- Extend the desktop E2E minimally: after its plies, assert a match record exists in the (in-memory? no — real app support dir) DB... keep E2E unchanged EXCEPT assert no errors with persistence active (the record write happens on game end which E2E may not reach — acceptable; add a repository-level integration covered by widget tests instead; document).
Commit: `feat(app): post-game analysis, match history, and replay screen`

### Task 9: Docs, full verification, CI, merge

- Update root README (tutor + history features, drift note), memory-worthy notes.
- Full matrix: core (107+), bindings (11+MET/advisor + 16+1 engine), app (all + goldens locally + integration_test once), `flutter build windows`, push branch, confirm ci.yml green (Linux runs `-x golden`), Android workflow green + Firebase distribution SUCCESS (secrets now live — verify a build lands in App Distribution and report the console link).
- Final whole-branch review (holistic), fixes, then finish-branch (merge master, push, delete branch).

---

## Deferred (recorded)
- Cube-life (Janowski x-parameter) refinement of MatchCubeAdvisor — dead-cube v1 shipped.
- Tutor tap-to-apply hint rows; move-entry auto-play of forced moves.
- Online play (Plan 5). Analysis of AI-vs-AI or opponent moves display toggle polish.
