import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/lan/lan_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_play/lan_play.dart';

import 'lan_harness.dart';

/// The HOST's controller, folding its own authority's log in process.
///
/// The opponent here is headless: the guest's decisions go straight into
/// [HostAuthority.onGuestMessage] (the same inbox a socket would feed), while
/// every host decision travels through the controller's public verbs. So these
/// tests are about the FOLD — that the host, which owns the state, still sees a
/// correct game by replaying the log like any peer.
void main() {
  /// Build a started host controller: authority + controller + a guest joining
  /// (which is what starts game 1).
  Future<
      ({
        HostAuthority authority,
        LanMatchController controller,
        RecordingPersistence persistence,
        ValueNotifier<bool> presence,
      })> hostFixture({
    int length = 1,
    bool cubeless = false,
    Player hostSide = Player.white,
    bool join = true,
  }) async {
    final authority =
        newAuthority(length: length, cubeless: cubeless, hostSide: hostSide);
    final persistence = RecordingPersistence();
    final presence = ValueNotifier<bool>(false);
    final controller = LanMatchController.host(
      authority: authority,
      persistence: persistence,
      guestConnected: presence,
    );
    addTearDown(() {
      controller.disposeController();
      authority.close();
      presence.dispose();
    });
    await controller.playMatch();
    if (join) {
      presence.value = true;
      guestHello(authority);
      await pumpEventQueue();
    }
    return (
      authority: authority,
      controller: controller,
      persistence: persistence,
      presence: presence,
    );
  }

  /// Drive the match to its end: the host acts through its controller, the
  /// guest straight into the authority.
  Future<void> playOut(
    LanMatchController controller,
    HostAuthority authority, {
    int maxSteps = 4000,
  }) async {
    var guard = 0;
    while (!controller.matchOver) {
      if (guard++ > maxSteps) fail('the match did not terminate');
      if (controller.awaitingNextGame) {
        controller.continueToNextGame();
        await pumpEventQueue();
        continue;
      }
      if (controller.state.turn == controller.localSide) {
        actInController(controller);
      } else {
        actInAuthority(authority, authority.guestSide);
      }
      await pumpEventQueue();
    }
  }

  /// Advance until the host's own pre-roll gate is open (where doubling and
  /// resigning are legal).
  Future<void> playToHostGate(
      LanMatchController controller, HostAuthority authority) async {
    var guard = 0;
    while (!controller.awaitingHumanTurn) {
      if (guard++ > 500) fail('never reached the host pre-roll gate');
      if (controller.state.turn == controller.localSide) {
        actInController(controller);
      } else {
        actInAuthority(authority, authority.guestSide);
      }
      await pumpEventQueue();
    }
  }

  test('is not ready until a guest joins; the join starts game 1', () async {
    final f = await hostFixture(join: false);

    expect(f.controller.isReady, isFalse);
    expect(() => f.controller.state, throwsStateError);
    expect(f.controller.gameNumber, 0);
    expect(f.controller.linkStatus.value, GuestConnectionStatus.connecting);

    f.presence.value = true;
    guestHello(f.authority);
    await pumpEventQueue();

    expect(f.controller.isReady, isTrue);
    expect(f.controller.gameNumber, 1);
    expect(f.controller.lastSeq, f.authority.lastSeq);
    expect(f.controller.state.phase, GamePhase.moving);
    expect(f.controller.linkStatus.value, GuestConnectionStatus.connected);
    await f.controller.ready; // already complete
  });

  test('folds a full 1-point game to completion through the local verbs',
      () async {
    final f = await hostFixture(length: 1);
    await playOut(f.controller, f.authority);

    expect(f.controller.matchOver, isTrue);
    expect(f.controller.state.phase, GamePhase.gameOver);
    expect(f.controller.lastSeq, f.authority.lastSeq);
    // The fold agrees with the authority it folded — the point of folding.
    expect(f.controller.match.whiteScore, f.authority.match.whiteScore);
    expect(f.controller.match.blackScore, f.authority.match.blackScore);
    expect(f.controller.match.winner, f.authority.match.winner);
    expect(f.controller.game.events.length,
        f.authority.game!.events.length);
    // A finished match never leaves a pending decision armed.
    expect(f.controller.pendingMoveOf(Player.white).value, isNull);
    expect(f.controller.awaitingHumanTurn, isFalse);
    expect(f.controller.isThinking, isFalse);
    expect(f.controller.error, isNull);
  });

  test('folds a multi-game match, pausing between games', () async {
    // 3 points: a single game (max 3) may decide it, but usually does not.
    final f = await hostFixture(length: 3);
    var pauses = 0;
    var guard = 0;
    while (!f.controller.matchOver) {
      if (guard++ > 6000) fail('the match did not terminate');
      if (f.controller.awaitingNextGame) {
        pauses++;
        // While paused the fold stays on the FINISHED game even though the
        // authority has already opened the next one.
        expect(f.controller.state.phase, GamePhase.gameOver);
        expect(f.controller.lastSeq, f.authority.lastSeq,
            reason: 'the next game buffers, it is not dropped');
        f.controller.continueToNextGame();
        await pumpEventQueue();
        expect(f.controller.state.phase, isNot(GamePhase.gameOver));
        continue;
      }
      if (f.controller.state.turn == f.controller.localSide) {
        actInController(f.controller);
      } else {
        actInAuthority(f.authority, f.authority.guestSide);
      }
      await pumpEventQueue();
    }

    await pumpEventQueue(); // let the persistence chain drain

    expect(f.controller.matchOver, isTrue);
    expect(f.controller.gameNumber, f.authority.gameNumber);
    expect(pauses, f.authority.gameNumber - 1,
        reason: 'one pause per finished game except the last');
    expect(f.persistence.games.length, f.authority.gameNumber);
    expect(f.persistence.matchFinishedCalls, 1);
    expect(f.persistence.finalState!.winner, f.authority.match.winner);
    expect(f.controller.persistenceError, isNull);
  });

  test('persistence records the finished game with its complete log', () async {
    final f = await hostFixture(length: 1);
    await playOut(f.controller, f.authority);
    await pumpEventQueue();

    expect(f.persistence.games.length, 1);
    final g = f.persistence.games.single;
    expect(g.gameNumber, 1);
    expect(g.isCrawford, isTrue, reason: 'a 1-point match is Crawford at once');
    expect(g.events.length, f.authority.log.length,
        reason: 'the whole game log');
    expect(g.result.winner, f.authority.match.winner);
    expect(g.matchAfter.isMatchOver, isTrue);
    expect(f.persistence.matchFinishedCalls, 1);
  });

  test('the cube: the host doubles, the guest takes, the cube changes hands',
      () async {
    final f = await hostFixture(length: 5);
    await playToHostGate(f.controller, f.authority);

    expect(f.controller.cubeless, isFalse);
    expect(f.controller.state.cube.value, 1);
    f.controller.offerDouble();
    await pumpEventQueue();

    expect(f.controller.state.phase, GamePhase.cubeOffered);
    expect(f.controller.awaitingHumanTurn, isFalse);
    // The DECISION is the guest's; the host holds no pending cube request.
    expect(f.controller.pendingCubeOf(f.controller.localSide).value, isNull);
    expect(f.controller.isThinking, isTrue);

    f.authority.onGuestMessage(SubmitMessage(TakeEvent(f.authority.guestSide)));
    await pumpEventQueue();

    expect(f.controller.state.cube.value, 2);
    expect(f.controller.state.cube.owner, f.authority.guestSide);
    expect(f.controller.awaitingHumanTurn, isTrue);
    expect(f.controller.error, isNull);
  });

  test('a cubeless match refuses to double on both surfaces', () async {
    final f = await hostFixture(length: 5, cubeless: true);
    await playToHostGate(f.controller, f.authority);

    expect(f.controller.cubeless, isTrue);
    expect(f.controller.offerDouble, throwsStateError);
    // Nothing reached the authority, so the log did not move.
    await pumpEventQueue();
    expect(f.controller.lastSeq, f.authority.lastSeq);
    expect(f.controller.state.cube.value, 1);
  });

  test('resignation: the host offers, the guest accepts, the score moves',
      () async {
    final f = await hostFixture(length: 5);
    await playToHostGate(f.controller, f.authority);

    f.controller.offerResign(ResignValue.single);
    await pumpEventQueue();
    expect(f.controller.state.phase, GamePhase.resignOffered);

    f.authority.onGuestMessage(
        SubmitMessage(ResignAcceptEvent(f.authority.guestSide)));
    await pumpEventQueue();

    expect(f.controller.state.phase, GamePhase.gameOver);
    expect(f.controller.awaitingNextGame, isTrue, reason: 'the match goes on');
    // The RESIGNER loses: the guest scores.
    final guestScore = f.authority.guestSide == Player.white
        ? f.controller.match.whiteScore
        : f.controller.match.blackScore;
    expect(guestScore, 1);
    expect(f.persistence.games.single.result.winner, f.authority.guestSide);
  });

  test('the guest resigns to the host: the pending resign request fires',
      () async {
    final f = await hostFixture(length: 5, hostSide: Player.black);
    // Advance to the GUEST's pre-roll so its resignation is legal.
    var guard = 0;
    while (!(f.controller.state.turn == f.authority.guestSide &&
        f.controller.state.phase == GamePhase.awaitingRoll)) {
      if (guard++ > 500) fail('never reached the guest pre-roll');
      if (f.controller.state.turn == f.controller.localSide) {
        actInController(f.controller);
      } else {
        actInAuthority(f.authority, f.authority.guestSide);
      }
      await pumpEventQueue();
    }

    f.authority.onGuestMessage(SubmitMessage(
        ResignOfferEvent(f.authority.guestSide, ResignValue.gammon)));
    await pumpEventQueue();

    final pending = f.controller.pendingResignOf(f.controller.localSide).value;
    expect(pending, isNotNull);
    expect(pending!.$2, ResignValue.gammon);

    f.controller.submitResignResponse(f.controller.localSide, true);
    await pumpEventQueue();

    expect(f.controller.state.phase, GamePhase.gameOver);
    expect(f.controller.match.matchLength, 5);
    final hostScore = f.controller.localSide == Player.white
        ? f.controller.match.whiteScore
        : f.controller.match.blackScore;
    expect(hostScore, 2, reason: 'an accepted gammon resignation is 2 points');
  });

  test('a rejected local action surfaces the reason and re-arms the decision',
      () async {
    final f = await hostFixture(length: 5);
    // Reach the host's MOVING phase, where a cube response is nonsense.
    var guard = 0;
    while (!(f.controller.state.turn == f.controller.localSide &&
        f.controller.state.phase == GamePhase.moving)) {
      if (guard++ > 500) fail('never reached a host moving phase');
      if (f.controller.state.turn == f.controller.localSide) {
        actInController(f.controller);
      } else {
        actInAuthority(f.authority, f.authority.guestSide);
      }
      await pumpEventQueue();
    }
    final seqBefore = f.authority.lastSeq;

    f.controller.submitCubeResponse(f.controller.localSide, CubeAction.take);
    await pumpEventQueue();

    // The authority refused it (level lastSeq → not a divergence).
    expect(f.authority.lastSeq, seqBefore);
    expect(f.controller.error, isA<LanMatchException>());
    expect((f.controller.error! as LanMatchException).code, 'rejected');
    // The gate re-opened: the real decision is still available.
    expect(f.controller.pendingMoveOf(f.controller.localSide).value, isNotNull);

    // And a legal action still lands, clearing the banner.
    actInController(f.controller);
    await pumpEventQueue();
    expect(f.authority.lastSeq, greaterThan(seqBefore));
    expect(f.controller.error, isNull);
  });

  test('lastMove publishes the folded move with its pre-move board', () async {
    final f = await hostFixture(length: 5);
    final seen = <AppliedMoveProbe>[];
    f.controller.lastMove.addListener(() {
      final applied = f.controller.lastMove.value;
      if (applied != null) {
        seen.add(AppliedMoveProbe(applied.move, applied.player, applied.preBoard));
      }
    });

    final boardBefore = f.controller.state.board;
    actInController(f.controller); // the host is on move first (white opens)
    await pumpEventQueue();

    expect(seen, hasLength(1));
    expect(seen.single.player, f.controller.localSide);
    expect(seen.single.preBoard, same(boardBefore),
        reason: 'the board the move was applied TO travels with the event');
    expect(f.controller.state.board, isNot(same(boardBefore)));
  });

  test('guest presence drives the link status', () async {
    final f = await hostFixture(length: 5);
    expect(f.controller.linkStatus.value, GuestConnectionStatus.connected);

    f.presence.value = false;
    expect(f.controller.linkStatus.value, GuestConnectionStatus.reconnecting,
        reason: 'a guest that has played and gone is reconnecting, not absent');

    f.presence.value = true;
    expect(f.controller.linkStatus.value, GuestConnectionStatus.connected);
  });

  test('disposeController is idempotent and stops the fold', () async {
    final f = await hostFixture(length: 5);
    final seqAtDispose = f.controller.lastSeq;

    f.controller.disposeController();
    f.controller.disposeController(); // idempotent

    // The authority plays on; the disposed controller does not follow.
    actInAuthority(f.authority, f.authority.state!.turn);
    await pumpEventQueue();
    expect(f.authority.lastSeq, greaterThan(seqAtDispose));
    expect(f.controller.lastSeq, seqAtDispose);
  });

  test('a controller disposed before readiness still completes ready',
      () async {
    final f = await hostFixture(join: false);
    expect(f.controller.isReady, isFalse);
    f.controller.disposeController();
    await f.controller.ready; // completes rather than hanging
    expect(f.controller.isReady, isFalse);
  });
}

/// A flattened copy of an [AppliedMove] observation (the notifier is reused, so
/// a test must snapshot what it saw).
class AppliedMoveProbe {
  AppliedMoveProbe(this.move, this.player, this.preBoard);
  final Move move;
  final Player player;
  final BoardState preBoard;
}
