import 'dart:math';

import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:match_transport/match_transport.dart';

import '../helpers/board_driving.dart';

/// The game screen over a [NetMatchController] — the ONE controller both LAN and
/// online play now use.
///
/// Ported from `app/test/lan/lan_game_screen_test.dart`, which mounted a
/// host-authority-backed controller. There is no authority to seed from any more,
/// so the opening roll is seeded as a SOUND commit-reveal document plus the event
/// it derives (exactly what the peers would have produced), and the opponent's
/// endpoint exists but never plays — which is what makes `opponentPresent` true.
///
/// What it proves is that the screen needs nothing beyond the `MatchController`
/// surface for networked play, on either transport.
void main() {
  const surface = Size(900, 1300);

  Widget harness(NetMatchController c) => MaterialApp(
        home: GameScreen(key: ValueKey(c), controller: c),
      );

  /// A host-seat controller on a backend whose game 1 has already opened 6-1
  /// (White, the host seat, on turn and moving).
  Future<({NetMatchController controller, InMemoryBackend backend})> start({
    int length = 5,
    bool cubeless = false,
  }) async {
    final backend = InMemoryBackend(
        config: MatchConfig(length: length, cubeless: cubeless));
    // The joiner's endpoint: never folded, but its presence is what a real
    // socket/uid would signal.
    final peer = InMemoryTransport.guest(backend);
    addTearDown(peer.dispose);
    backend.seedOpening(whiteDie: 6, blackDie: 1);
    final controller = NetMatchController(
      transport: InMemoryTransport.host(backend),
      rng: Random(7),
    );
    addTearDown(controller.disposeController);
    await controller.playMatch();
    return (controller: controller, backend: backend);
  }

  testWidgets('renders a networked match and commits the local side\'s move',
      (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final rig = await start();
    final controller = rig.controller;

    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await pumpUntil(t, () => controller.isReady);
    await t.pumpWidget(harness(controller));
    await t.pump();

    expect(find.byType(GameScreen), findsOneWidget);
    // Match context is on screen: the score line names the game number.
    expect(find.textContaining('Game 1'), findsWidgets);

    expect(controller.localSide, TransportSession.hostSide);
    expect(controller.state.turn, controller.localSide,
        reason: 'a 6-1 opening hands White, the host seat, the first move');
    expect(controller.state.phase, GamePhase.moving);

    final seqBefore = rig.backend.events.length;
    await commitFirstMove(t);
    await pumpUntil(t, () => rig.backend.events.length > seqBefore);

    // The hand-entered move reached the log as the LOCAL side's event.
    final landed = rig.backend.events.last;
    expect(landed.event, isA<MoveEvent>());
    expect((landed.event as MoveEvent).player, controller.localSide);
    expect(landed.author, rig.backend.hostAuthor);
    expect(controller.state.turn, isNot(controller.localSide));
    expect(controller.frozen, isFalse);
    expect(find.byType(GameScreen), findsOneWidget);
  });

  testWidgets('a cubeless networked match hides the cube controls', (t) async {
    await t.binding.setSurfaceSize(surface);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final rig = await start(cubeless: true);
    final controller = rig.controller;

    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await pumpUntil(t, () => controller.isReady);
    await t.pumpWidget(harness(controller));
    await t.pump();

    expect(controller.cubeless, isTrue);
    expect(find.text('Double'), findsNothing);
  });
}
