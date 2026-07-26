import 'package:aigammon_app/lan/lan_match_controller.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/board_driving.dart';
import 'lan_harness.dart';

/// The game screen over a [LanMatchController].
///
/// The host's controller is the one that can be driven without a socket, so
/// this smoke test mounts that one and plays the local side's move by hand; the
/// headless guest answers straight into the authority. It proves the screen
/// needs nothing beyond the [MatchController] surface for LAN play.
void main() {
  const surface = Size(900, 1300);

  Widget harness(LanMatchController c) => MaterialApp(
        home: GameScreen(key: ValueKey(c), controller: c),
      );

  testWidgets('renders a LAN match and commits the local side\'s move',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final authority = newAuthority(length: 5);
    final controller = LanMatchController.host(authority: authority);
    addTearDown(() {
      controller.disposeController();
      authority.close();
    });

    // The guest joining starts game 1; the screen must not mount before that
    // (state throws until the opening roll folds).
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    guestHello(authority);
    await pumpUntil(t, () => controller.isReady);
    await t.pumpWidget(harness(controller));
    await t.pump();

    expect(find.byType(GameScreen), findsOneWidget);
    // Match context is on screen: the score line names the game number.
    expect(find.textContaining('Game 1'), findsWidgets);

    final whoseTurn = controller.state.turn;
    if (whoseTurn != controller.localSide) {
      // The guest opened; let it play so the host gets the board.
      actInAuthority(authority, authority.guestSide);
      await pumpUntil(t, () => controller.state.turn == controller.localSide);
      // The host now has a pre-roll gate; roll through the screen's own verb.
      await pumpUntil(t, () => controller.awaitingHumanTurn);
      controller.rollDice();
      await pumpUntil(t, () => controller.state.phase == GamePhase.moving);
    }

    final seqBefore = authority.lastSeq;
    await commitFirstMove(t);
    await pumpUntil(t, () => authority.lastSeq > seqBefore);

    // The hand-entered move reached the authority as the LOCAL side's event.
    expect(authority.log.last.event, isA<MoveEvent>());
    expect((authority.log.last.event as MoveEvent).player, controller.localSide);
    expect(controller.state.turn, isNot(controller.localSide));
    expect(find.byType(GameScreen), findsOneWidget);
  });

  testWidgets('a cubeless LAN match hides the cube controls', (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final authority = newAuthority(length: 5, cubeless: true);
    final controller = LanMatchController.host(authority: authority);
    addTearDown(() {
      controller.disposeController();
      authority.close();
    });

    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    guestHello(authority);
    await pumpUntil(t, () => controller.isReady);
    await t.pumpWidget(harness(controller));
    await t.pump();

    expect(controller.cubeless, isTrue);
    expect(find.text('Double'), findsNothing);
  });
}
