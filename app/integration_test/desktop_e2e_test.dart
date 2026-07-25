// Desktop end-to-end test with the REAL engine (Plan 3 Task 10).
//
// Boots the real app (real [ProviderScope] → real [EngineManager]/[EngineService]
// backed by the staged Windows DLL + neural nets resolved by walking up from the
// runtime CWD), navigates Home → "Play vs Computer" (match length 1, Expert),
// and plays the human side programmatically through the same interactive board
// and action-bar controls a person would use.
//
// This proves the whole live pipeline — UI taps → GameController loop → AI agent
// → engine isolate → back to the board — advances real plies with zero errors.
// It is deliberately NOT stubbed; the point of the task is the real engine.
//
// Run: `flutter test integration_test -d windows`
import 'package:aigammon_app/main.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/helpers/board_driving.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Home → vs Computer plays ≥4 real plies with the real engine, no errors',
    (tester) async {
      // A generous, deterministic surface so the board geometry is stable.
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Real scope: real EngineManager/EngineService, real DLL + nets.
      await tester.pumpWidget(const ProviderScope(child: AiGammonApp()));
      await tester.pumpAndSettle();

      // Home → match setup (vs Computer).
      await tester.tap(find.text('Play vs Computer'));
      await tester.pumpAndSettle();

      // Match length 1, Expert difficulty (human keeps the default White side).
      await tester.tap(find.text('1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expert'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start match'));
      await tester.pumpAndSettle();

      // Reach into the live tree for the running controller and the human agent.
      final controller =
          tester.widget<GameScreen>(find.byType(GameScreen)).controller;
      expect(controller.isLocalHuman(Player.white), isTrue,
          reason: 'default side is White, so White is the human');

      int plies() => controller.game.events.whereType<MoveEvent>().length;

      void assertHealthy() {
        // No loop/engine error was recorded (this drives the on-screen banner).
        expect(controller.error, isNull,
            reason: 'controller recorded an error: ${controller.error}');
        // Every committed position conserves 15 checkers a side.
        expect(controller.state.board.checkerCount(Player.white), 15,
            reason: 'white checker conservation');
        expect(controller.state.board.checkerCount(Player.black), 15,
            reason: 'black checker conservation');
      }

      const targetPlies = 4;
      var maxPlies = 0;

      // Bounded loop: acts on whichever human decision is open, otherwise pumps
      // real time so the engine isolate (spawned lazily on the first AI turn —
      // it loads a 40 MB DLL + nets, so the first call takes a beat) can answer.
      // The overall 5-minute timeout is the real safety net; the iteration cap
      // only bounds the worst case.
      for (var i = 0; i < 4000; i++) {
        // Advance both widget frames and real wall-clock so async isolate
        // messages land between pumps.
        await tester.pump(const Duration(milliseconds: 25));
        await Future<void>.delayed(const Duration(milliseconds: 25));

        assertHealthy();
        maxPlies = plies() > maxPlies ? plies() : maxPlies;

        if (maxPlies >= targetPlies) break;
        if (controller.matchOver || controller.awaitingNextGame) break;

        if (controller.pendingMoveOf(Player.white).value != null) {
          // The interactive board is live: commit the human's move (or pass).
          await commitFirstMove(tester);
        } else if (controller.awaitingHumanTurn) {
          // Pre-roll gate: roll the dice.
          final roll = find.widgetWithText(FilledButton, 'Roll');
          if (roll.evaluate().isNotEmpty && isButtonEnabled(tester, roll)) {
            await tester.tap(roll);
            await tester.pump();
          }
        }
        // Otherwise the AI is thinking — keep pumping.
      }

      assertHealthy();

      // Success: at least 4 plies advanced, OR the game legitimately ended
      // sooner (a 1-point match can end in a single game).
      final ended = controller.matchOver || controller.awaitingNextGame;
      expect(maxPlies >= targetPlies || ended, isTrue,
          reason: 'expected ≥$targetPlies plies or a finished game; '
              'got $maxPlies plies, ended=$ended');

      // ignore: avoid_print
      print('desktop_e2e: advanced $maxPlies real plies '
          '(matchOver=${controller.matchOver}, '
          'awaitingNextGame=${controller.awaitingNextGame})');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
