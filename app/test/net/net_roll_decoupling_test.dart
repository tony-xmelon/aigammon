/// The dice beat is a LOCAL presentation, and the roll protocol must not know it
/// exists.
///
/// The live-play report behind this file read as if it did: "each time the joiner
/// rolls the dice, the host plays the animation first and then delivers the
/// result". The actual cause was in the socket limiter (see
/// `test/lan/lan_roll_latency_test.dart`), but the property the report ASSUMED
/// was broken is worth pinning down, because nothing else in the suite states it:
/// with a real [AnimationTimings.normal] screen mounted over the host's
/// controller, the host's witness duties — its entropy, and its fold of the roll
/// the guest derives from it — complete without one millisecond of the clock
/// being advanced.
///
/// Every assertion below is made after ZERO-duration pumps only. A beat frame is
/// 140ms and a settle pause 500ms, so anything the beat gated could not possibly
/// have happened yet: if a future change routes [NetMatchController]'s protocol
/// steps through a beat callback, an animation controller, or a `Future.delayed`
/// hung off the presentation, this test goes red on the spot.
library;

import 'dart:math';

import 'package:aigammon_app/board/board_view.dart';
import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/net/net_match_controller.dart';
import 'package:aigammon_app/screens/game_screen.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:match_transport/match_transport.dart';
import 'package:match_transport/testing.dart';

import '../helpers/board_driving.dart';
import 'net_harness.dart' show greedyFirstMove;

void main() {
  /// Flush every microtask the two controllers chain, WITHOUT letting a single
  /// timer fire. This is the whole instrument: real time never moves.
  Future<void> pumpNoTime(WidgetTester t, [int frames = 40]) async {
    for (var i = 0; i < frames; i++) {
      await t.pump();
    }
  }

  testWidgets(
      "the host answers the guest's roll without waiting on its own dice beat",
      (t) async {
    await t.binding.setSurfaceSize(const Size(900, 1300));
    addTearDown(() => t.binding.setSurfaceSize(null));

    final backend = InMemoryBackend(config: const MatchConfig(length: 3));
    // A 6-1 opening, already folded: White (the host seat) is on turn and moving,
    // so the FIRST pre-roll gate of the match belongs to the guest.
    backend.seedOpening(whiteDie: 6, blackDie: 1);
    final host = NetMatchController(
      transport: InMemoryTransport.host(backend),
      rng: Random(101),
    );
    final guest = NetMatchController(
      transport: InMemoryTransport.guest(backend),
      rng: Random(202),
    );
    addTearDown(host.disposeController);
    addTearDown(guest.disposeController);
    await host.playMatch();
    await guest.playMatch();

    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await pumpUntil(t, () => host.isReady && guest.isReady);
    // The host's board, with production animation timings: a 140ms beat frame,
    // six of them, then a 500ms settle pause.
    await t.pumpWidget(MaterialApp(
      home: GameScreen(
        key: ValueKey(host),
        controller: host,
        timings: AnimationTimings.normal,
      ),
    ));
    await t.pump();
    expect(host.state.turn, host.localSide);
    expect(host.state.phase, GamePhase.moving);

    // Hand the turn over: the host plays its opening move through the controller
    // (the screen's own entry path is covered elsewhere; what matters here is who
    // holds the next pre-roll gate).
    await pumpUntil(t, () => host.pendingMoveOf(host.localSide).value != null);
    host.submitMove(host.localSide, greedyFirstMove(host.state));
    await pumpUntil(t, () => guest.awaitingHumanTurn);

    // Let every timer the hand-over started run out, so the measurement below
    // starts from a quiet screen.
    await t.pump(const Duration(seconds: 3));

    final n = backend.rollCount + 1;
    final seqBefore = backend.events.length;

    // THE MEASUREMENT. From here on the clock does not move.
    guest.rollDice();
    await pumpNoTime(t);

    expect(backend.fetchRoll(n)?.entropy, isNotNull,
        reason: "the host's entropy must not wait on a beat frame");
    expect(backend.fetchRoll(n)?.reveal, isNotNull,
        reason: 'and the guest must be able to reveal against it at once');
    expect(backend.events.length, seqBefore + 1,
        reason: "the guest's RollEvent completed the handshake, still inside "
            'zero elapsed time');

    // Both peers hold the roll — so both screens have what they need to animate
    // it, at the same instant. Neither is waiting on the other's presentation.
    expect(host.lastSeq, backend.events.length);
    expect(guest.lastSeq, backend.events.length);

    // And the host's own presentation is DOWNSTREAM of that: its beat is now
    // running on the roller's pair, having started from the fold rather than
    // gating it.
    expect(boardPainterOf(t).activeDiceSide, guest.localSide,
        reason: "the host lights the guest's pair the moment the roll folds");
    expect(_boardViewDiceOverrideRoller(t), guest.localSide,
        reason: 'and it is tumbling, not settled — the beat began here, after '
            'the network step, not before it');
  });
}

/// The roller the board's dice override is currently tumbling for, or null when
/// no beat is live.
Player? _boardViewDiceOverrideRoller(WidgetTester t) =>
    t.widget<BoardView>(find.byType(BoardView)).diceOverride?.roller;
