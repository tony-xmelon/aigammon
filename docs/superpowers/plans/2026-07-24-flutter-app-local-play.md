# Flutter App + Local Play Implementation Plan (Plan 3 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A playable Flutter backgammon app: vs computer (4 difficulties) and hot-seat, full match play (cube, Crawford, resign), on Windows desktop (dev) and Android (CI-built APK distributed via Firebase App Distribution).

**Architecture:** `app/` Flutter project consuming `backgammon_core` (rules) and `engine_bindings` (AI) as path deps. Riverpod for state. A pure-Dart `GameController` runs the match state machine over the event-sourced `Game`, pulling decisions from `PlayerAgent`s (human via UI, AI via `EngineService`). The board is a `CustomPaint` with a geometry class shared by painter and hit-testing. Incremental human move entry via a new `MoveBuilder` in backgammon_core (prefix-filtering legal moves). Engine lifecycle behind a Riverpod provider with supervised re-spawn. Android release path: GitHub Actions cross-compiles the Rust engine with cargo-ndk, builds the APK, and (secret-gated) uploads to Firebase App Distribution.

**Tech Stack:** Flutter 3.44.8 (installed at C:\Users\anton\flutter, on PATH), flutter_riverpod, backgammon_core + engine_bindings (this repo), GitHub Actions (subosito/flutter-action, cargo-ndk), Firebase App Distribution.

**Environment facts:** Windows dev box; `flutter test` works; `flutter run -d windows` requires the VS Build Tools C++ workload (install was in flight when this plan was written — Task 1 verifies). Android SDK 36 local with licenses accepted (local Android runs possible but CI is the release path). Engine DLL staged at `packages/engine_bindings/native/windows/aigammon_engine.dll`; nets at `native/wildbg-nets/neural-nets/`. Engine API: `EngineService.spawn({libraryPath, netsPath})`, `rankMoves(board, mover, dice)`, `bestMove(...)`, `cubeInfo(board, mover)` (money-only), `evaluate(...)`, `dispose()`; `pickMove(ranked, difficulty, rng)`. Android loads `DynamicLibrary.open('libaigammon_engine.so')` — `WILDBG_LIB_PATH` env or explicit `libraryPath` must be plumbed; nets must ship as Flutter assets and be copied to a real directory at first run (tract needs file paths).

**Working agreements:** every task ends with `flutter analyze` clean + relevant tests green + commit. UI tasks include widget tests; pure-logic tasks are strict TDD. The `app/` package uses the same lints as the packages.

---

### Task 1: Flutter app scaffold + desktop build gate

**Files:** Create `app/` via `flutter create`, then adjust.

- [ ] Step 1: Verify the VS Build Tools install finished: `flutter doctor` must show Visual Studio with the C++ workload green (or at minimum no missing-component error). If still installing, wait/poll; if failed, report BLOCKED with the doctor output.
- [ ] Step 2: From repo root: `flutter create app --org com.xmelon --project-name aigammon_app --platforms windows,android --empty`. Then edit `app/pubspec.yaml`: description "AIGammon — backgammon with a neural-net engine."; add deps `flutter_riverpod: ^2.5.1`, `backgammon_core: {path: ../packages/backgammon_core}`, `engine_bindings: {path: ../packages/engine_bindings}`; dev deps keep `flutter_test`, add `flutter_lints` (keep created default). Keep `app/analysis_options.yaml` as created (flutter_lints).
- [ ] Step 3: Replace `app/lib/main.dart` with a minimal Riverpod app: `ProviderScope(child: MaterialApp(title: 'AIGammon', home: Scaffold(body: Center(child: Text('AIGammon')))))`. Add `app/test/smoke_test.dart` widget test pumping the app and expecting the text.
- [ ] Step 4: `flutter test` (green), `flutter analyze` (clean), `flutter build windows --debug` (must succeed — this is the C++-workload gate; report BLOCKED with exact errors if not).
- [ ] Step 5: Add an `app` job to `.github/workflows/ci.yml`: `subosito/flutter-action@v2` (channel stable), `flutter pub get`, `flutter analyze`, `flutter test` in `app/`.
- [ ] Step 6: Commit `feat(app): scaffold Flutter app with desktop build gate` (git add app .github).

### Task 2: MoveBuilder (backgammon_core)

Incremental human move entry. Pure Dart, strict TDD.

**Files:** Create `packages/backgammon_core/lib/src/move_builder.dart` (+ barrel export); Test `packages/backgammon_core/test/move_builder_test.dart`.

API (implement exactly; full-turn legality stays with `GameState.play` — MoveBuilder only narrows choices):
```dart
/// Builds a full-turn Move hop by hop, always staying inside the legal set.
/// Constructed from the current legal moves; each chosen hop filters the
/// candidate moves to those whose hop multiset contains the chosen prefix.
class MoveBuilder {
  MoveBuilder(List<Move> legalMoves);          // snapshot, e.g. state.legalMoves
  List<CheckerMove> get chosenHops;            // in chosen order
  /// Sources (from-values incl. CheckerMove.bar) that can start a next hop.
  Set<int> get selectableSources;
  /// Destinations legal for one more hop from [source] given hops so far.
  Set<int> get destinationsFor(int source);    // to-values incl. CheckerMove.off
  /// Adds a hop; throws ArgumentError if not currently selectable.
  void addHop(int from, int to);
  void undoHop();                               // removes last; no-op if empty
  void reset();
  /// True when chosenHops exactly matches some legal move (sameAs).
  bool get isComplete;
  /// True when no further hop can extend the current prefix.
  bool get isDeadEnd;                           // == isComplete for maximal-play rule
  Move build();                                 // throws StateError unless isComplete
}
```
Implementation approach: keep the filtered candidate list; a prefix matches a candidate if the candidate's hop multiset contains the chosen hops as a sub-multiset AND some ordering of the candidate plays the chosen hops first — simplest correct filter: candidate remains if there is a permutation of it whose first `chosenHops.length` hops equal `chosenHops` in order, where "equal" ignores isHit. Because turns are ≤4 hops, brute-force permutations are fine. `selectableSources`/`destinationsFor` derive from surviving candidates' next-hop options. `isComplete` = some candidate `sameAs(Move(chosenHops))` — and because all legal moves are equal length (maximal rule), `isComplete == (chosenHops.length == legal.first.length)`.

Tests (write real ones): opening 3-1 — sources {23,12,7,5} (verify against generator), choose 7→4 then destinations for 5 include 4, complete after 2 hops, build() sameAs golden-point; undoHop restores; addHop with illegal source throws; dance (empty legal list) → no sources, isComplete false, build() throws; a transit case (24/20 via either intermediate) — both intermediate routes accepted hop-by-hop.
Commit: `feat(core): MoveBuilder for incremental human move entry`.

### Task 3: PlayerAgent + DiceRoller (app, pure Dart)

**Files:** Create `app/lib/game/player_agent.dart`, `app/lib/game/dice_roller.dart`; Test `app/test/game/player_agent_test.dart`.

```dart
/// One side's decision source. The controller awaits these; the human agent
/// completes them from UI callbacks, the AI agent from EngineService.
abstract interface class PlayerAgent {
  Future<Move> chooseMove(GameState state);
  Future<CubeAction> chooseCubeResponse(GameState state);   // take or drop
  /// Whether to double before rolling; called only when doubling is legal.
  Future<bool> considerDouble(GameState state);
  void dispose() {}
}
enum CubeAction { take, drop }

class DiceRoller {
  DiceRoller([Random? rng]) : _rng = rng ?? Random.secure();
  Dice roll();                        // uniform 1-6 pair
  Dice rollOpening();                 // re-rolls doubles internally
}

/// Human: the UI pushes decisions into pending completers.
class LocalHumanAgent implements PlayerAgent {
  // chooseMove returns a Future completed by submitMove(Move);
  // chooseCubeResponse completed by submitCubeResponse(CubeAction);
  // considerDouble completed by submitDoubleDecision(bool).
  // Exposes ValueListenable<bool> waitingForMove etc. for the UI. Only one
  // pending request of each kind at a time (StateError otherwise).
}

class AiAgent implements PlayerAgent {
  AiAgent(this.service, this.difficulty, [Random? rng]);
  // chooseMove: ranked = await service.rankMoves(...); Move.none if empty;
  //   else pickMove(ranked, difficulty, rng).move.
  // considerDouble: money-only heuristic via service.cubeInfo: double when
  //   advice.shouldDouble (skip when state.isCrawfordGame — controller
  //   already guards legality). chooseCubeResponse: advice.shouldAccept
  //   ? take : drop.
}
```
Tests with a fake EngineService-shaped class (define a thin `EngineFacade` interface in the same file that both `EngineService` and fakes satisfy: `rankMoves`, `cubeInfo` — AiAgent depends on the interface, not the concrete class). TDD: human agent completer flow (submit before request throws; request then submit completes), AI agent picks expert=top move, dance path, cube responses. Commit: `feat(app): player agents and secure dice roller`.

### Task 4: GameController (app, pure Dart)

**Files:** Create `app/lib/game/game_controller.dart`; Test `app/test/game/game_controller_test.dart`.

A `ChangeNotifier` that runs ONE MATCH. Holds `MatchState`, current `Game` (event-sourced), the two agents, a `DiceRoller`, and exposes: `GameState get state`, `MatchState get match`, `Stream<GameEvent> get events` (broadcast, for animations later), `bool get isThinking` (an AI decision in flight), phase-appropriate verbs for the UI (`offerDouble()`, `resign(ResignValue)` for the human side), and `Future<void> playMatch()` driving the loop:
1. New game: `matchState.isCrawfordNext` → `Game.start(OpeningRollEvent(...), isCrawfordGame: ...)` with dice from `rollOpening()` (record white/black die).
2. Loop on `state.phase`: `awaitingRoll` → first ask the on-turn agent `considerDouble` when doubling is legal (cube centered/owned, not Crawford, opponent decision pending path), else roll via DiceRoller and append RollEvent; `moving` → `agent.chooseMove` → append MoveEvent; `cubeOffered` → other agent `chooseCubeResponse` → Take/DropEvent; `resignOffered` → opponent accept/decline (v1: AI always accepts single resignations offered by humans? NO — keep symmetric: route to agent; add `chooseResignResponse` returning accept:bool to PlayerAgent with AI default accept when `advice` says winning is worse — simplest v1: AI accepts iff `evaluate(...).equity` ≥ resign value threshold; if that's fiddly, v1 AI always accepts and a TODO records it — decide, document).
3. `gameOver` → `matchState = matchState.applyResult(result)`; notify; if `!matchState.isMatchOver` start next game; else complete `playMatch()`.
Cancellation: `disposeController()` stops the loop (a `_cancelled` flag checked after every await; agents' dispose called).
All engine/agent awaits wrapped: on exception, surface via `error` field + notify (UI shows a banner; Task 8).
TDD with scripted fake agents + seeded DiceRoller (inject `Random(n)`): a full hot-seat-style match of 2 scripted games completes with correct score; double/take path; double/drop ends game at pre-double stake; resign path; Crawford game gets `isCrawfordGame: true` and controller never asks `considerDouble` in it; cancellation mid-await. Commit: `feat(app): GameController match loop`.

### Task 5: Engine lifecycle + platform paths (app)

**Files:** Create `app/lib/engine/engine_provider.dart`, modify `app/pubspec.yaml` (assets), create `app/lib/engine/nets_installer.dart`; Test `app/test/engine/nets_installer_test.dart` (+ a manual desktop check in Task 10).

- Bundle nets as assets: copy `native/wildbg-nets/neural-nets/{contact,race}.onnx` into `app/assets/nets/` (committed — 1.5 MB total) and declare under `flutter: assets:`. A comment + README note records they are copies of the canonical files in native/ (CI could later verify hashes match).
- `NetsInstaller.ensureInstalled()`: if `Platform.isWindows` (dev) and the repo-relative `../native/wildbg-nets/neural-nets` exists → return that path (no copy). Else copy the two assets from the bundle to `<application support dir>/nets/` (use `path_provider`; add dep) if missing or size-mismatched, return that directory. Unit-test the copy logic with a temp dir by factoring the pure part as `ensureInstalledTo(Directory, AssetReader)` where AssetReader is a function `Future<ByteData> Function(String key)` — fake it in tests.
- `engineServiceProvider`: a Riverpod `AsyncNotifierProvider` that: resolves `libraryPath` (Windows dev: `../packages/engine_bindings/native/windows/aigammon_engine.dll` if it exists, else rely on `WILDBG_LIB_PATH`; Android: `'libaigammon_engine.so'` — bare name, the loader finds jniLibs), awaits nets path, spawns `EngineService`, and SUPERVISES: wrap calls so that on a `StateError('engine isolate died…')` the provider invalidates itself and re-spawns once per failure (simple: expose `Future<T> withEngine<T>(Future<T> Function(EngineService) fn)` that retries once after re-spawn). Dispose on provider dispose.
Commit: `feat(app): engine lifecycle provider with bundled nets`.

### Task 6: Board geometry + painter

**Files:** Create `app/lib/board/board_geometry.dart`, `app/lib/board/board_painter.dart`, `app/lib/board/board_theme.dart`; Test `app/test/board/board_geometry_test.dart` + golden `app/test/board/board_painter_test.dart`.

- `BoardGeometry(Size size, {required bool whiteAtBottom})`: computes `Rect pointRect(int index)` (24 points: two 6-point quadrants per side split by the bar; index 0 = White's 1-point at bottom-right when whiteAtBottom), `Rect barRect(Player)`, `Rect offRect(Player)`, `Offset checkerCenter(int pointIndex, int stackPosition)` (stacks of >5 compress), `double checkerRadius`, and inverse hit-testing `int? locationAt(Offset)` returning a point index, `CheckerMove.bar` (24) for the bar, or `off` sentinel `-1` for the bear-off tray, null otherwise. PURE — fully unit-testable: round-trip tests (`locationAt(pointRect(i).center) == i` for all 24 + bar + off), symmetry tests, stacking compression.
- `BoardTheme`: colors (board felt, dark/light points, checker colors + borders, highlight, bar), const light + dark instances.
- `BoardPainter extends CustomPainter`: paints board, points (alternating triangles), bar, checkers from a `BoardState` (+ optional highlight sets: `Set<int> highlightedSources`, `Set<int> highlightedDestinations`, selected source), dice pips for current roll, cube (value + owner position), borne-off trays with counts. Golden test: pump a `CustomPaint` with `BoardState.initial()` at fixed size, `matchesGoldenFile` (generate with `flutter test --update-goldens`, commit the golden PNG).
Commit: `feat(app): board geometry, theme, and painter with goldens`.

### Task 7: Board interaction widget

**Files:** Create `app/lib/board/board_view.dart`; Test `app/test/board/board_view_test.dart`.

`BoardView` — stateful widget owning a `MoveBuilder` for the current turn:
- Inputs: `GameState state`, `bool interactive` (human on turn & phase==moving), callbacks `onMoveCommitted(Move)`, orientation.
- Tap flow: tap a highlighted source → select (destinations highlight, from `builder.destinationsFor`); tap destination → `addHop`; auto-commit when `isComplete` AND no other legal move shares the prefix? NO — explicit confirm: when complete, show a check button; Undo button calls `undoHop`. (Simple, unambiguous; refine in Plan 4.) Tapping selected source deselects. When exactly one legal move exists and it is the dance (`Move.none` case = empty legal list), show a "No moves — pass" button instead.
- Rebuilds the MoveBuilder whenever `state` changes identity.
- Widget tests using `tester.tapAt(geometry.pointRect(i).center)`: play the golden-point 3-1 (select 7 tap 4, select 5 tap 4, confirm) and assert `onMoveCommitted` got a move `sameAs` expected; undo path; dance pass button; non-interactive mode ignores taps.
Commit: `feat(app): interactive board with incremental move entry`.

### Task 8: Game screen

**Files:** Create `app/lib/screens/game_screen.dart`, `app/lib/widgets/` (hud pieces as needed); Test `app/test/screens/game_screen_test.dart`.

`GameScreen(controller)` assembles: `BoardView` (interactive when human turn + moving), HUD (match score + match length + Crawford badge, dice display, cube display, whose turn, "thinking…" indicator bound to `controller.isThinking`), action bar (Roll button when human awaitingRoll — also the place the human can instead tap Double when legal; Resign menu offering single/gammon/backgammon), modal dialogs driven by controller state: double offered to human (Take/Pass), resign offered to human (Accept/Decline), game end (points won, next-game button), match end (winner, back home). Hot-seat: between turns when both agents are human, an opaque "Pass the device to X — tap to continue" overlay gates the reveal of the new roll (only when a previous turn actually ended; skip for the first turn). Error banner surface for `controller.error`.
Widget tests with fake agents/controller: dialogs appear on the right phases; roll button advances; pass-device overlay shows in hot-seat and not in vs-AI. Commit: `feat(app): game screen with HUD, dialogs, hot-seat overlay`.

### Task 9: Home + match setup + navigation

**Files:** Create `app/lib/screens/home_screen.dart`, `app/lib/screens/new_match_screen.dart`, modify `app/lib/main.dart`; Test `app/test/screens/home_test.dart`.

Home: title, "Play vs Computer", "Two Players (hot-seat)". New-match screen: match length selector (1/3/5/7, default 5), for vs-computer a difficulty selector (Easy/Medium/Hard/Expert, default Medium) and side picker (White/Black/Random). Creates the agents (AiAgent from `engineServiceProvider` via the `withEngine` facade; LocalHumanAgent(s)), builds `GameController`, pushes `GameScreen`. Material 3 theming, light/dark from system. Widget tests: navigation flow with a stubbed engine provider override (Riverpod `ProviderScope(overrides: ...)`). Commit: `feat(app): home and match setup`.

### Task 10: Desktop end-to-end verification

**Files:** Create `app/integration_test/desktop_e2e_test.dart` (+ dev_dep `integration_test` sdk package).

Integration test (runs on Windows desktop via `flutter test integration_test -d windows`): boots the real app with the REAL engine (DLL + repo nets), starts a 1-point vs-computer match as White with a seeded controller override if needed, and plays a scripted opening: programmatically drive the human side by locating the controller (expose it via a test hook/provider) and submitting the top-ranked move fetched from the engine, then lets the AI answer; asserts the game advances ≥4 plies with no exceptions and the board state stays checker-conserving. ALSO: manual smoke — `flutter run -d windows`, play a few moves by hand; capture a screenshot (any tool) and report observations (rendering glitches, hit-test feel). If `flutter build windows` was blocked in Task 1 and still is, this task is where it must be resolved.
Commit: `test(app): desktop E2E with real engine`.

### Task 11: Android build + Firebase App Distribution workflow

**Files:** Create `.github/workflows/android.yml`; modify `app/android/` config as needed (min SDK, jniLibs path), `native/README.md` note.

- Workflow (on push to master + manual dispatch): job `apk` on ubuntu-latest: checkout recursive; rust toolchain + `cargo install cargo-ndk` + `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`; NDK via `android-actions/setup-android` or the runner's preinstalled NDK (document which); `cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o app/android/app/src/main/jniLibs build --release` in `native/engine_shim`; subosito/flutter-action; `flutter build apk --release` in `app/` (default debug signing is fine for distribution-testing; note about real signing later); upload-artifact the APK. Second step (same job): IF `secrets.FIREBASE_SERVICE_ACCOUNT` and `secrets.FIREBASE_ANDROID_APP_ID` are present, run `wzieba/Firebase-Distribution-Github-Action@v1` (or `firebase appdistribution:distribute` via CLI) with groups `testers`. Guard with `if: ${{ secrets... != '' }}` via an env indirection (GitHub can't use secrets directly in `if` — use a setup step exporting a flag).
- Ensure `app/android/app/build.gradle*`: minSdk ≥ 24 (dart:ffi + isolates fine), abiFilters match built ABIs.
- Push, watch the run, iterate until the APK job is green (the distribution step will be skipped until the user adds the two secrets — the workflow log must say so clearly).
- Update README: how to register the Android app (applicationId `com.xmelon.aigammon_app` — read the actual value from the created project and document THAT) in the Firebase console, obtain the App ID + service account JSON, and add the two GitHub secrets.
Commit: `ci(android): engine cross-compile, APK build, secret-gated Firebase distribution`.

### Task 12: Docs, memory, final review, merge

- Update root-level docs: brief `README.md` at repo root (project overview, packages, how to run: desktop dev, tests, CI badges optional).
- Run EVERYTHING: core suite, bindings suites (default + `-P engine`), `flutter analyze` + `flutter test` in app, `flutter build windows`, and confirm the latest CI run (including android.yml) is green.
- Dispatch the final whole-branch code review (holistic, per the subagent-driven process), fix what it requires, then finish the branch (merge to master + push, per the user's established preference — confirm via the finishing skill's options).

---

## Deferred / out of scope for Plan 3
- Tutor overlays, hints, analysis (Plan 4); persistence (drift) beyond in-memory matches (Plan 4); online play (Plan 5).
- Animations/polish beyond basic (Plan 4 pass); sounds.
- Release signing for Android (needs a keystore decision with the user); iOS entirely (CI/macOS later).
- Match-aware cube ADVICE (money-only cube_info limitation — recorded in Plan 2); the AI's considerDouble uses money advice even at match scores (acceptable v1 bot behavior; revisit with the tutor).
