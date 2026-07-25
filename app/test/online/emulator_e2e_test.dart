@Tags(['emulator'])
library;

import 'dart:io';

import 'package:aigammon_app/game/player_agent.dart' show CubeAction;
import 'package:aigammon_app/online/online_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_client/online_client.dart';

/// Two-client full-MATCH end-to-end test through the REAL Firebase Emulator
/// Suite (Auth + Firestore + Cloud Functions + firestore.rules).
///
/// Where [OnlineMatchController]'s unit test drives a scripted [FakeMatchApi],
/// this test wires TWO controllers — each with its own anonymous user and its
/// own transport stack — to a single server-authoritative match and plays it to
/// completion. Every dice roll, every fold, and every score is produced by the
/// deployed functions and rules; nothing here shortcuts the server.
///
/// ## Gating
///
/// This is a heavy integration test that requires the emulator to be up. It is
/// GATED OFF unless the environment variable `AIGAMMON_EMULATOR=1` is set — a
/// plain `flutter test` skips it with a reason (see app/dart_test.yaml for why
/// an env gate rather than the `exclude_tags`/preset pattern used by
/// packages/online_client). `firebase/run-emulator-tests.ps1` sets the variable
/// and runs it inside a throwaway emulator via
/// `flutter test --tags emulator test/online/emulator_e2e_test.dart`.
///
/// ## What it plays
///
/// A 3-point (multi-game) match with a first-legal-move policy for both seats.
/// It also scripts exactly ONE cube sequence: from game 2 onward, white (A)
/// offers a double at its first pre-roll opportunity while the cube is centered,
/// and black (B) takes — so the take path and a doubled game are exercised and
/// the cube value 2 is observed. The loop runs until BOTH controllers report
/// `matchOver`, then asserts the two clients and the server all agree.

/// A signed-in anonymous user with a full [MatchApi] stack over its own token.
class _User {
  final AuthClient auth;
  final FirestoreRestClient firestore;
  final FunctionsClient functions;
  final MatchApi api;
  final String uid;

  _User(this.auth, this.firestore, this.functions, this.api, this.uid);

  void close() {
    auth.close();
    firestore.close();
    functions.close();
  }
}

Future<_User> _signIn(OnlineConfig config) async {
  final auth = AuthClient(config);
  final session = await auth.signInAnonymously();
  final firestore = FirestoreRestClient(config, token: auth.validToken);
  final functions = FunctionsClient(config, token: auth.validToken);
  return _User(
    auth,
    firestore,
    functions,
    MatchApi(auth, firestore, functions),
    session.uid,
  );
}

void main() {
  // Env gate: skip entirely unless explicitly asked to run against the emulator.
  // Trim because cmd.exe's `set VAR=1 && ...` captures a trailing space into the
  // value; treat any non-empty, non-"0" value as enabled.
  final gate = Platform.environment['AIGAMMON_EMULATOR']?.trim();
  final runEmulator = gate != null && gate.isNotEmpty && gate != '0';
  final skipReason = runEmulator
      ? null
      : 'Set AIGAMMON_EMULATOR=1 and run inside the Firebase Emulator Suite '
          '(see firebase/run-emulator-tests.ps1).';

  final config = OnlineConfig.emulator();

  test(
    'two clients play a full 3-point match through the emulator; '
    'clients + server stay consistent',
    () async {
      // --- setup: two users, a created + joined 3-point match ----------------
      final a = await _signIn(config); // creator -> seat white
      final b = await _signIn(config); // joiner  -> seat black
      OnlineMatchController? ctrlA;
      OnlineMatchController? ctrlB;
      try {
        final created = await a.api.createMatch(3); // multi-game match
        expect(created.matchId, isNotEmpty);
        final joinedId = await b.api.joinMatch(created.code);
        expect(joinedId, created.matchId);
        final matchId = created.matchId;

        // Each controller is seeded from its own view of the freshly-active
        // match (game 1's opening roll is already appended server-side).
        final snapA = await a.api.fetchMatch(matchId);
        final snapB = await b.api.fetchMatch(matchId);
        expect(snapA.status, 'active');
        expect(snapA.gameNo, 1);

        ctrlA = OnlineMatchController(
          api: a.api,
          matchId: matchId,
          localSide: Player.white,
          initialSnapshot: snapA,
          pollInterval: const Duration(milliseconds: 300),
        );
        ctrlB = OnlineMatchController(
          api: b.api,
          matchId: matchId,
          localSide: Player.black,
          initialSnapshot: snapB,
          pollInterval: const Duration(milliseconds: 300),
        );

        // Track cube-2 sightings and any transient error either controller
        // surfaces during the run (both should be clear by the end).
        var cubeReachedTwo = false;
        final transientErrors = <Object>[];
        void observe(OnlineMatchController c) {
          if (c.error != null) transientErrors.add(c.error!);
          if (c.isReady && !c.awaitingNextGame && !c.matchOver) {
            try {
              if (c.state.cube.value >= 2) cubeReachedTwo = true;
            } on StateError {
              // state not readable in this fold; ignore.
            }
          }
        }

        ctrlA.addListener(() => observe(ctrlA!));
        ctrlB.addListener(() => observe(ctrlB!));

        await ctrlA.playMatch();
        await ctrlB.playMatch();
        await ctrlA.ready;
        await ctrlB.ready;
        expect(ctrlA.isReady, isTrue);
        expect(ctrlB.isReady, isTrue);

        // --- drive loop --------------------------------------------------------
        // Each controller only ever acts on ITS OWN seat, so the two never race
        // for the same decision. Actions are de-duplicated by GameState identity:
        // a controller acts at most once per folded state, so a submit that has
        // not yet been echoed back by the poll is never re-issued (which would
        // otherwise double-submit a move/roll).
        var gamesCompletedA = 0;
        var doubledOnce = false;
        final lastActed = <OnlineMatchController, GameState?>{};

        void act(OnlineMatchController c, {required bool isA}) {
          if (c.matchOver) return;
          if (c.awaitingNextGame) {
            c.continueToNextGame();
            if (isA) gamesCompletedA++;
            lastActed[c] = null; // force a fresh decision in the next game
            return;
          }
          if (!c.isReady) return;
          final GameState s;
          try {
            s = c.state;
          } on StateError {
            return;
          }
          if (identical(s, lastActed[c])) return; // already acted on this fold
          if (s.cube.value >= 2) cubeReachedTwo = true;
          final side = c.localSide;

          if (c.pendingCubeOf(side).value != null) {
            c.submitCubeResponse(side, CubeAction.take);
            lastActed[c] = s;
            return;
          }
          if (c.pendingResignOf(side).value != null) {
            c.submitResignResponse(side, true);
            lastActed[c] = s;
            return;
          }
          if (c.pendingMoveOf(side).value != null) {
            final legal = s.legalMoves;
            c.submitMove(side, legal.isEmpty ? Move.none : legal.first);
            lastActed[c] = s;
            return;
          }
          if (c.awaitingHumanTurn) {
            // Script: A doubles ONCE, at its first centered-cube opportunity
            // from game 2 onward; otherwise just roll.
            final canDouble = isA &&
                !doubledOnce &&
                gamesCompletedA >= 1 &&
                s.cube.owner == null &&
                !s.isCrawfordGame;
            if (canDouble) {
              doubledOnce = true;
              c.offerDouble();
            } else {
              c.rollDice();
            }
            lastActed[c] = s;
            return;
          }
          // Opponent's turn / in flight: nothing to do; mark this fold acted so
          // we don't spin. The next fold produces a new GameState object.
          lastActed[c] = s;
        }

        const maxIters = 8000; // safety net; the real bound is the test timeout
        var iters = 0;
        while (!(ctrlA.matchOver && ctrlB.matchOver)) {
          iters++;
          if (iters > maxIters) {
            fail('match did not complete within $maxIters iterations.\n'
                '${_diag('A', ctrlA)}\n${_diag('B', ctrlB)}\n'
                'gamesCompletedA=$gamesCompletedA doubledOnce=$doubledOnce '
                'cubeReachedTwo=$cubeReachedTwo');
          }
          act(ctrlA, isA: true);
          act(ctrlB, isA: false);
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }

        // --- assertions --------------------------------------------------------
        // 1. No lingering error on either controller.
        expect(ctrlA.error, isNull, reason: 'A ended with an error');
        expect(ctrlB.error, isNull, reason: 'B ended with an error');

        // 2. The scripted cube sequence really happened.
        expect(doubledOnce, isTrue, reason: 'A never got to double');
        expect(cubeReachedTwo, isTrue,
            reason: 'the cube never reached 2 (double/take did not flow)');

        // 3. The two clients agree on the final match outcome.
        expect(ctrlA.match.whiteScore, ctrlB.match.whiteScore);
        expect(ctrlA.match.blackScore, ctrlB.match.blackScore);
        expect(ctrlA.match.winner, ctrlB.match.winner);
        expect(ctrlA.match.winner, isNotNull);

        // 4. Both clients' last-game folded histories are identical.
        final eventsA = ctrlA.game.events;
        final eventsB = ctrlB.game.events;
        expect(eventsA.length, eventsB.length,
            reason: 'clients folded a different number of last-game events');
        for (var i = 0; i < eventsA.length; i++) {
          expect(eventsA[i], eventsB[i],
              reason: 'last-game event $i differs between clients');
        }

        // 5. The server snapshot agrees with the clients.
        final server = await a.api.fetchMatch(matchId);
        expect(server.status, 'complete');
        expect(server.winner, ctrlA.match.winner);
        expect(server.whiteScore, ctrlA.match.whiteScore);
        expect(server.blackScore, ctrlA.match.blackScore);

        // 6. A full independent replay of the ENTIRE server event log folds to
        //    the same scores/winner (validates every stored event, per game).
        final all = await a.api.fetchEventsSince(matchId, -1);
        final byGame = <int, List<GameEvent>>{};
        for (final re in all) {
          (byGame[re.gameNo] ??= <GameEvent>[]).add(re.event);
        }
        final gameNos = byGame.keys.toList()..sort();
        expect(gameNos.length, greaterThanOrEqualTo(1));
        var replayed = MatchState(matchLength: server.matchLength);
        for (final gn in gameNos) {
          final crawford = replayed.isCrawfordNext;
          final g = Game.replay(byGame[gn]!, isCrawfordGame: crawford);
          if (g.state.phase == GamePhase.gameOver) {
            replayed = replayed.applyResult(g.state.result!);
          }
        }
        expect(replayed.whiteScore, server.whiteScore,
            reason: 'independent replay disagrees on white score');
        expect(replayed.blackScore, server.blackScore,
            reason: 'independent replay disagrees on black score');
        expect(replayed.winner, server.winner,
            reason: 'independent replay disagrees on the winner');
        expect(replayed.isMatchOver, isTrue);

        // The server's last-game event count matches the clients' last game.
        expect(byGame[gameNos.last]!.length, eventsA.length,
            reason: "server's last game length differs from the clients'");

        // Transient poll/submit errors are tolerated mid-run, but every one must
        // have cleared (the controllers ended clean, asserted above). This is
        // informational: surface it if the run was bumpy.
        if (transientErrors.isNotEmpty) {
          // ignore: avoid_print
          print('note: ${transientErrors.length} transient error(s) observed '
              'during the run (all cleared by completion).');
        }
      } finally {
        ctrlA?.disposeController();
        ctrlB?.disposeController();
        a.close();
        b.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );
}

String _diag(String label, OnlineMatchController c) {
  final buf = StringBuffer('controller $label: matchOver=${c.matchOver} '
      'awaitingNextGame=${c.awaitingNextGame} '
      'awaitingHumanTurn=${c.awaitingHumanTurn} isReady=${c.isReady} '
      'error=${c.error}');
  if (c.isReady && !c.awaitingNextGame && !c.matchOver) {
    try {
      final s = c.state;
      buf.write(' phase=${s.phase} turn=${s.turn} cube=${s.cube.value}');
    } on StateError {
      // ignore
    }
  }
  buf.write(' scores=${c.match.whiteScore}-${c.match.blackScore}');
  return buf.toString();
}
