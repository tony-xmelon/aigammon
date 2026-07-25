import 'dart:async';
import 'dart:math';

import 'package:aigammon_app/game/player_agent.dart';
import 'package:aigammon_app/online/online_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_client/online_client.dart';

/// A scriptable [MatchApi] stand-in. Events reach the controller through
/// [emit] (the poll stream); [fetchEventsSince]/[fetchMatch] serve the canned
/// [log]/[snapshot] the divergence path refetches. Submissions and rolls are
/// recorded; [throwsRemaining] scripts leading submit failures.
class FakeMatchApi implements MatchApi {
  final _poll = StreamController<RemoteEvent>();

  /// The authoritative log served by [fetchEventsSince] (empty unless a test
  /// arms the divergence rebuild).
  List<RemoteEvent> log = [];

  /// The snapshot served by [fetchMatch] (divergence rebuild).
  MatchSnapshot? snapshot;

  /// Number of leading [submitEvent] calls that should throw before succeeding.
  int throwsRemaining = 0;

  final List<(GameEvent, GameResultClaim?)> submissions = [];
  final List<int> fetchSinceArgs = [];
  int fetchMatchCalls = 0;
  int rollDiceCalls = 0;
  int _seq = 100;

  void emit(RemoteEvent e) => _poll.add(e);

  bool get hasPollListener => _poll.hasListener;

  @override
  Stream<RemoteEvent> pollEvents(String matchId,
          {Duration interval = const Duration(seconds: 2)}) =>
      _poll.stream;

  @override
  Future<List<RemoteEvent>> fetchEventsSince(String matchId, int afterSeq) async {
    fetchSinceArgs.add(afterSeq);
    return [for (final e in log) if (e.seq > afterSeq) e];
  }

  @override
  Future<MatchSnapshot> fetchMatch(String matchId) async {
    fetchMatchCalls++;
    return snapshot!;
  }

  @override
  Future<int> submitEvent(String matchId, GameEvent event,
      {GameResultClaim? result}) async {
    submissions.add((event, result));
    if (throwsRemaining > 0) {
      throwsRemaining--;
      throw const OnlineException('unavailable', 'scripted failure');
    }
    return ++_seq;
  }

  @override
  Future<Dice> rollDice(String matchId) async {
    rollDiceCalls++;
    return Dice(1, 2);
  }

  @override
  Future<({String matchId, String code})> createMatch(int matchLength) =>
      throw UnimplementedError();

  @override
  Future<String> joinMatch(String code) => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A deterministic full game as an ordered [RemoteEvent] log, produced by
/// random-but-seeded legal play (server dice + first/any legal move) until a
/// checker is borne off. Mirrors how the real server would append events.
({List<RemoteEvent> events, Game game}) playoutGame({
  required int matchLength,
  required Dice opening,
  required Random rng,
  int startSeq = 0,
  int gameNo = 1,
}) {
  final events = <RemoteEvent>[];
  var seq = startSeq;
  final open = OpeningRollEvent(whiteDie: opening.die1, blackDie: opening.die2);
  events.add(RemoteEvent(seq: seq++, gameNo: gameNo, event: open));
  final isCrawford = MatchState(matchLength: matchLength).isCrawfordNext;
  var game = Game.start(open, isCrawfordGame: isCrawford);

  var guard = 0;
  while (game.state.phase != GamePhase.gameOver) {
    if (guard++ > 5000) {
      throw StateError('playout did not terminate');
    }
    final s = game.state;
    late GameEvent ev;
    switch (s.phase) {
      case GamePhase.awaitingRoll:
        ev = RollEvent(s.turn, rng.nextInt(6) + 1, rng.nextInt(6) + 1);
      case GamePhase.moving:
        final legal = s.legalMoves;
        final move = legal.isEmpty ? Move.none : legal[rng.nextInt(legal.length)];
        ev = MoveEvent(s.turn, move);
      case GamePhase.cubeOffered:
      case GamePhase.resignOffered:
      case GamePhase.gameOver:
        throw StateError('unexpected phase in pure move playout: ${s.phase}');
    }
    game = game.append(ev);
    events.add(RemoteEvent(seq: seq++, gameNo: gameNo, event: ev));
  }
  return (events: events, game: game);
}

MatchSnapshot snap({
  required int matchLength,
  int whiteScore = 0,
  int blackScore = 0,
  bool crawfordPlayed = false,
  bool isCrawford = false,
  int gameNo = 1,
  int seq = 0,
  Player turn = Player.white,
  GamePhase phase = GamePhase.moving,
  String status = 'active',
}) =>
    MatchSnapshot(
      status: status,
      code: 'ABCDEF',
      matchLength: matchLength,
      gameNo: gameNo,
      seq: seq,
      whiteUid: 'w',
      blackUid: 'b',
      whiteScore: whiteScore,
      blackScore: blackScore,
      turn: turn,
      phase: phase,
      isCrawford: isCrawford,
      crawfordPlayed: crawfordPlayed,
      winner: null,
    );

void main() {
  // Feed one poll event and let the controller's stream listener run.
  Future<void> feed(FakeMatchApi api, RemoteEvent e) async {
    api.emit(e);
    await pumpEventQueue();
  }

  test('folds a full 1-point game, driving local decisions with submissions',
      () async {
    final api = FakeMatchApi();
    // A full game so we know its winner; the local side is the winner, so the
    // terminal (bear-off) move is a LOCAL submission carrying a result claim.
    final opening = Dice(6, 3);
    final play = playoutGame(
        matchLength: 1, opening: opening, rng: Random(7), gameNo: 1);
    final events = play.events;
    final winner = (events.last.event as MoveEvent).player;
    final local = winner;
    final finalResult = play.game.state.result!;

    final controller = OnlineMatchController(
      api: api,
      matchId: 'm1',
      localSide: local,
      initialSnapshot: snap(matchLength: 1, isCrawford: true, turn: winner),
    );
    addTearDown(controller.disposeController);

    // Track how many distinct local move-entry requests fired.
    var pendingMoveFires = 0;
    controller.pendingMoveOf(local).addListener(() {
      if (controller.pendingMoveOf(local).value != null) pendingMoveFires++;
    });

    await controller.playMatch();

    // Feed the opening (first mover starts in the moving phase with these dice).
    await feed(api, events.first);

    var localRolls = 0;
    var localMoves = 0;
    for (final re in events.skip(1)) {
      final ev = re.event;
      if (ev is RollEvent) {
        if (ev.player == local) {
          expect(controller.awaitingHumanTurn, isTrue);
          controller.rollDice();
          await pumpEventQueue();
          localRolls++;
        }
        await feed(api, re);
      } else if (ev is MoveEvent) {
        if (ev.player == local) {
          expect(controller.pendingMoveOf(local).value, isNotNull);
          controller.submitMove(local, ev.move);
          await pumpEventQueue();
          localMoves++;
          final (subEvent, subClaim) = api.submissions.last;
          expect(subEvent, isA<MoveEvent>());
          expect((subEvent as MoveEvent).player, local);
        }
        await feed(api, re);
      }
    }

    expect(controller.matchOver, isTrue);
    expect(controller.state.phase, GamePhase.gameOver);
    expect(controller.match.winner, winner);
    expect(pendingMoveFires, localMoves);
    expect(api.rollDiceCalls, localRolls);

    // The terminal submission carried the correct result claim.
    final (termEvent, termClaim) = api.submissions.last;
    expect(termEvent, isA<MoveEvent>());
    expect(termClaim, isNotNull);
    expect(termClaim!.winner, finalResult.winner);
    expect(termClaim.points, finalResult.points);
    expect(termClaim.outcome, finalResult.outcome);
  });

  test('ignores duplicate and out-of-order sequence numbers', () async {
    final api = FakeMatchApi();
    final open = const OpeningRollEvent(whiteDie: 6, blackDie: 3); // white first
    final g0 = Game.start(open, isCrawfordGame: false);
    final whiteMove = g0.state.legalMoves.first;
    final g1 = g0.append(MoveEvent(Player.white, whiteMove));
    expect(g1.state.turn, Player.black);
    expect(g1.state.phase, GamePhase.awaitingRoll);

    final ev0 = RemoteEvent(seq: 0, gameNo: 1, event: open);
    final ev1 =
        RemoteEvent(seq: 1, gameNo: 1, event: MoveEvent(Player.white, whiteMove));
    final ev2 =
        RemoteEvent(seq: 2, gameNo: 1, event: RollEvent(Player.black, 5, 2));

    final controller = OnlineMatchController(
      api: api,
      matchId: 'm2',
      localSide: Player.white,
      initialSnapshot: snap(matchLength: 3),
    );
    addTearDown(controller.disposeController);
    await controller.playMatch();

    await feed(api, ev0); // opening → white moving

    // seq 2 arrives before seq 1: ignored (would be an out-of-turn append and
    // trip divergence if it were wrongly applied).
    await feed(api, ev2);
    await feed(api, ev2);
    expect(controller.state.turn, Player.white);
    expect(controller.state.phase, GamePhase.moving);

    await feed(api, ev1); // the real next event
    expect(controller.state.turn, Player.black);
    expect(controller.state.phase, GamePhase.awaitingRoll);

    await feed(api, ev2); // now in-order → applied
    expect(controller.state.phase, GamePhase.moving);
    expect(controller.state.dice, Dice(5, 2));

    // No divergence was triggered by the stray events.
    expect(controller.error, isNull);
    expect(api.fetchMatchCalls, 0);
  });

  test('diverges on an illegal event: refetches, rebuilds, clears error',
      () async {
    final api = FakeMatchApi();
    final open = const OpeningRollEvent(whiteDie: 6, blackDie: 3);
    final g0 = Game.start(open, isCrawfordGame: false);
    final whiteMove = g0.state.legalMoves.first;

    final controller = OnlineMatchController(
      api: api,
      matchId: 'm3',
      localSide: Player.white,
      initialSnapshot: snap(matchLength: 3),
    );
    addTearDown(controller.disposeController);

    final errors = <Object?>[];
    controller.addListener(() => errors.add(controller.error));

    await controller.playMatch();
    await feed(api, RemoteEvent(seq: 0, gameNo: 1, event: open));

    // Arm the authoritative rebuild: opening + white's real move.
    api.log = [
      RemoteEvent(seq: 0, gameNo: 1, event: open),
      RemoteEvent(seq: 1, gameNo: 1, event: MoveEvent(Player.white, whiteMove)),
    ];
    api.snapshot = snap(
        matchLength: 3, gameNo: 1, seq: 1, turn: Player.black);

    // Inject an illegal event (a roll while white is mid-move) at the next seq.
    await feed(api, RemoteEvent(seq: 1, gameNo: 1, event: RollEvent(Player.white, 3, 4)));
    await pumpEventQueue();

    // Refetched the whole log + a fresh snapshot exactly once.
    expect(api.fetchMatchCalls, 1);
    expect(api.fetchSinceArgs.where((a) => a == -1).length, 2); // catch-up + rebuild
    // Error was set transiently, then cleared.
    expect(errors.any((e) => e != null), isTrue);
    expect(controller.error, isNull);
    // Rebuilt to the authoritative state: white moved, black to roll.
    expect(controller.state.turn, Player.black);
    expect(controller.state.phase, GamePhase.awaitingRoll);
  });

  test('retries a failed submission once; surfaces error on double failure',
      () async {
    // Reach a local moving state so submitMove is valid.
    Future<OnlineMatchController> movingController(FakeMatchApi api) async {
      final open = const OpeningRollEvent(whiteDie: 6, blackDie: 3);
      final c = OnlineMatchController(
        api: api,
        matchId: 'm4',
        localSide: Player.white,
        initialSnapshot: snap(matchLength: 3),
      );
      await c.playMatch();
      await feed(api, RemoteEvent(seq: 0, gameNo: 1, event: open));
      return c;
    }

    // First attempt throws, retry succeeds → exactly 2 calls, no error.
    final api1 = FakeMatchApi()..throwsRemaining = 1;
    final c1 = await movingController(api1);
    addTearDown(c1.disposeController);
    final move = c1.state.legalMoves.first;
    c1.submitMove(Player.white, move);
    await pumpEventQueue();
    expect(api1.submissions.length, 2);
    expect(c1.error, isNull);
    expect(c1.pendingMoveOf(Player.white).value, isNotNull); // still pending

    // Both attempts throw → exactly 2 calls, error surfaced, still pending.
    final api2 = FakeMatchApi()..throwsRemaining = 5;
    final c2 = await movingController(api2);
    addTearDown(c2.disposeController);
    c2.submitMove(Player.white, c2.state.legalMoves.first);
    await pumpEventQueue();
    expect(api2.submissions.length, 2);
    expect(c2.error, isNotNull);
    expect(c2.pendingMoveOf(Player.white).value, isNotNull);
  });

  test('buffers next-game events until continueToNextGame', () async {
    final api = FakeMatchApi();
    // 7-point match: a single game (max 3 points) never ends it, so game 2
    // always follows.
    final play = playoutGame(
        matchLength: 7, opening: Dice(6, 3), rng: Random(3), gameNo: 1);
    final events = play.events;
    final winner = (events.last.event as MoveEvent).player;

    final controller = OnlineMatchController(
      api: api,
      matchId: 'm5',
      localSide: Player.white,
      initialSnapshot: snap(matchLength: 7),
    );
    addTearDown(controller.disposeController);
    await controller.playMatch();

    for (final re in events) {
      await feed(api, re);
    }

    expect(controller.matchOver, isFalse);
    expect(controller.awaitingNextGame, isTrue);
    expect(controller.state.phase, GamePhase.gameOver);
    expect(controller.match.winner, isNull);
    final scoreAfterG1 =
        winner == Player.white ? controller.match.whiteScore : controller.match.blackScore;
    expect(scoreAfterG1, greaterThan(0));

    // Server appends game 2's opening (and a first move) while we're paused.
    final nextSeq = events.last.seq + 1;
    final open2 = const OpeningRollEvent(whiteDie: 6, blackDie: 2); // white first
    final g2 = Game.start(open2, isCrawfordGame: false);
    final g2move = g2.state.legalMoves.first;
    await feed(api, RemoteEvent(seq: nextSeq, gameNo: 2, event: open2));
    await feed(api,
        RemoteEvent(seq: nextSeq + 1, gameNo: 2, event: MoveEvent(Player.white, g2move)));

    // Buffered: still showing the finished game 1.
    expect(controller.awaitingNextGame, isTrue);
    expect(controller.state.phase, GamePhase.gameOver);

    controller.continueToNextGame();

    // Drained: now folding game 2.
    expect(controller.awaitingNextGame, isFalse);
    expect(controller.match.winner, isNull);
    // Game 2 opening winner (white) has moved once, black now to roll.
    expect(controller.state.turn, Player.black);
    expect(controller.state.phase, GamePhase.awaitingRoll);
  });

  test('disposeController cancels polling and is idempotent', () async {
    final api = FakeMatchApi();
    final controller = OnlineMatchController(
      api: api,
      matchId: 'm6',
      localSide: Player.white,
      initialSnapshot: snap(matchLength: 3),
    );
    await controller.playMatch();
    expect(api.hasPollListener, isTrue);

    controller.disposeController();
    await pumpEventQueue();
    expect(api.hasPollListener, isFalse);

    // Idempotent: a second call does nothing and does not throw.
    controller.disposeController();
    expect(api.hasPollListener, isFalse);
  });

  test('remote double: pending cube fires; drop submits claim to the doubler',
      () async {
    final api = FakeMatchApi();
    final open = const OpeningRollEvent(whiteDie: 6, blackDie: 3); // white first
    final g0 = Game.start(open, isCrawfordGame: false);
    final whiteMove = g0.state.legalMoves.first;

    final controller = OnlineMatchController(
      api: api,
      matchId: 'm7',
      localSide: Player.white,
      initialSnapshot: snap(matchLength: 7),
    );
    addTearDown(controller.disposeController);
    await controller.playMatch();

    await feed(api, RemoteEvent(seq: 0, gameNo: 1, event: open));
    await feed(api,
        RemoteEvent(seq: 1, gameNo: 1, event: MoveEvent(Player.white, whiteMove)));
    // Black (opponent) doubles from its pre-roll; white becomes the decider.
    await feed(api, RemoteEvent(seq: 2, gameNo: 1, event: DoubleEvent(Player.black)));

    expect(controller.state.phase, GamePhase.cubeOffered);
    expect(controller.pendingCubeOf(Player.white).value, isNotNull);

    controller.submitCubeResponse(Player.white, CubeAction.drop);
    await pumpEventQueue();

    expect(api.submissions.length, 1);
    final (event, claim) = api.submissions.single;
    expect(event, isA<DropEvent>());
    expect((event as DropEvent).player, Player.white);
    expect(claim, isNotNull);
    expect(claim!.winner, Player.black); // the doubler wins
    expect(claim.points, 1); // pre-double cube value
    expect(claim.outcome, GameOutcome.drop);
  });
}
