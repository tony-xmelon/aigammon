import 'dart:math';

import 'package:aigammon_app/data/persistence_hooks.dart';
import 'package:aigammon_app/game/player_agent.dart' show CubeAction;
import 'package:aigammon_app/online/online_match_controller.dart';
import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_client/online_client.dart';

import 'fake_online_backend.dart';

/// A [MatchPersistence] that records every hook call, so a test can assert
/// onGameFinished fired once per finished game (with the full event log + folded
/// result) and onMatchFinished at match end. [throwOnGame] scripts a single
/// non-fatal onGameFinished failure for that game number.
class RecordingPersistence implements MatchPersistence {
  final List<
      ({
        int gameNumber,
        bool isCrawford,
        List<GameEvent> events,
        GameResult result,
        MatchState matchAfter,
      })> games = [];
  int matchFinishedCalls = 0;
  MatchState? finalState;
  int throwOnGame = -1;

  @override
  Future<void> onGameFinished({
    required int gameNumber,
    required bool isCrawford,
    required List<GameEvent> events,
    required GameResult result,
    required MatchState matchAfter,
  }) async {
    if (gameNumber == throwOnGame) {
      throw StateError('scripted persistence failure');
    }
    games.add((
      gameNumber: gameNumber,
      isCrawford: isCrawford,
      events: events,
      result: result,
      matchAfter: matchAfter,
    ));
  }

  @override
  Future<void> onMatchFinished(MatchState finalState) async {
    matchFinishedCalls++;
    this.finalState = finalState;
  }
}

/// Yields to the event loop [times] times, letting the fakes' async chains and
/// any short timers run to completion.
Future<void> settle([int times = 24]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pumps the event loop until [done], failing with [reason] if it never becomes
/// true. Everything here is real-async but zero-delay, so this converges fast.
Future<void> pumpUntil(bool Function() done,
    {int rounds = 4000, String reason = 'condition never became true'}) async {
  for (var i = 0; i < rounds; i++) {
    if (done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(reason);
}

void main() {
  // Live matches under test, so a fake poll can be nudged with an error.
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());
  tearDown(() => backend.close());

  /// The two controllers of one match, wired to the same store.
  ({OnlineMatchController host, OnlineMatchController guest, FakeMatch match})
      pair({
    int length = 3,
    bool cubeless = false,
    MatchPersistence? hostPersistence,
    MatchPersistence? guestPersistence,
  }) {
    final m = backend.seedMatch(length: length, cubeless: cubeless);
    final host = OnlineMatchController(
      api: FakeMatchApi(backend, 'host'),
      matchDoc: m.doc,
      rng: Random(101),
      persistence: hostPersistence ?? const NoopPersistence(),
      pollInterval: const Duration(milliseconds: 1),
    );
    final guest = OnlineMatchController(
      api: FakeMatchApi(backend, 'guest'),
      matchDoc: m.doc,
      rng: Random(202),
      persistence: guestPersistence ?? const NoopPersistence(),
      pollInterval: const Duration(milliseconds: 1),
    );
    addTearDown(host.disposeController);
    addTearDown(guest.disposeController);
    return (host: host, guest: guest, match: m);
  }

  /// One decision for [c], deduplicated by [GameState] identity so a submission
  /// that has not been echoed back yet is never re-issued.
  void act(
    OnlineMatchController c,
    Map<OnlineMatchController, GameState?> lastActed, {
    void Function(OnlineMatchController)? onGameOver,
  }) {
    if (c.matchOver || c.frozen) return;
    if (c.awaitingNextGame) {
      onGameOver?.call(c);
      c.continueToNextGame();
      lastActed[c] = null;
      return;
    }
    if (!c.isReady) return;
    final GameState s;
    try {
      s = c.state;
    } on StateError {
      return;
    }
    if (identical(s, lastActed[c])) return;
    final side = c.localSide;
    if (c.pendingCubeOf(side).value != null) {
      c.submitCubeResponse(side, CubeAction.take);
    } else if (c.pendingResignOf(side).value != null) {
      c.submitResignResponse(side, true);
    } else if (c.pendingMoveOf(side).value != null) {
      final legal = s.legalMoves;
      c.submitMove(side, legal.isEmpty ? Move.none : legal.first);
    } else if (c.awaitingHumanTurn) {
      c.rollDice();
    }
    lastActed[c] = s;
  }

  /// Drives both controllers until the match is decided.
  Future<void> playOut(
    OnlineMatchController a,
    OnlineMatchController b, {
    void Function(OnlineMatchController)? onGameOver,
    int maxIters = 60000,
  }) async {
    final lastActed = <OnlineMatchController, GameState?>{};
    var iters = 0;
    while (!(a.matchOver && b.matchOver)) {
      if (a.frozen || b.frozen) {
        fail('a controller froze mid-match: ${a.cheatError ?? b.cheatError}');
      }
      if (++iters > maxIters) {
        fail('the match did not finish in $maxIters iterations '
            '(a: over=${a.matchOver} ready=${a.isReady} err=${a.error}; '
            'b: over=${b.matchOver} ready=${b.isReady} err=${b.error})');
      }
      act(a, lastActed, onGameOver: onGameOver);
      act(b, lastActed, onGameOver: onGameOver);
      await Future<void>.delayed(Duration.zero);
    }
    await settle();
  }

  // --- the happy path --------------------------------------------------------

  test('two controllers play a whole match through the commit-reveal protocol',
      () async {
    final p = pair(length: 3);
    await p.host.playMatch();
    await p.guest.playMatch();
    await pumpUntil(() => p.host.isReady && p.guest.isReady,
        reason: 'the host never made the opening roll both sides could fold');

    var pauses = 0;
    await playOut(p.host, p.guest, onGameOver: (c) {
      expect(c.state.phase, GamePhase.gameOver);
      pauses++;
    });

    // Both clients agree on the outcome and neither ended in a fault.
    expect(p.host.error, isNull);
    expect(p.guest.error, isNull);
    expect(p.host.cheatError, isNull);
    expect(p.guest.cheatError, isNull);
    expect(p.host.match.winner, isNotNull);
    expect(p.host.match.winner, p.guest.match.winner);
    expect(p.host.match.whiteScore, p.guest.match.whiteScore);
    expect(p.host.match.blackScore, p.guest.match.blackScore);
    expect(p.host.localSide, Player.white, reason: 'the host plays white');
    expect(p.guest.localSide, Player.black);

    final m = p.match;
    // The match document was closed out by (at least) one of the peers.
    expect(m.status, 'complete');
    expect(pauses, greaterThan(0), reason: 'a 3-point match takes >1 game');

    // Every roll ran the full protocol, exactly once per roll-bearing event, at
    // contiguous indices from 1 — the counter both clients derive from the log.
    final indices = m.rolls.keys.toList()..sort();
    expect(indices, [for (var i = 1; i <= m.rollCount; i++) i]);
    for (final roll in m.rolls.values) {
      expect(roll.doc.isComplete, isTrue, reason: 'roll ${roll.n} never finished');
      expect(commitMatches(roll.commit, roll.reveal!), isTrue);
    }

    // Openings are ALWAYS the host's; ordinary rolls are the mover's, and every
    // one carries exactly the dice its roll document derives.
    var n = 0;
    for (final re in m.events) {
      final event = re.event;
      if (event is! OpeningRollEvent && event is! RollEvent) continue;
      final roll = m.rolls[++n]!.doc.completed!;
      if (event is OpeningRollEvent) {
        expect(re.author, 'host', reason: 'openings are the host\'s to roll');
        expect(openingDiceMatchRoll(roll, event), isTrue);
      } else {
        expect(re.author, event is RollEvent && event.player == Player.white
            ? 'host'
            : 'guest');
        expect(diceMatchRoll(roll, event as RollEvent), isTrue);
      }
    }
  });

  test('cubeless travels in the match document and is honoured by both peers',
      () async {
    final p = pair(cubeless: true);
    expect(p.host.cubeless, isTrue);
    expect(p.guest.cubeless, isTrue);
  });

  // --- adaptive polling ------------------------------------------------------

  group('adaptive polling', () {
    const resting = Duration(seconds: 2);
    const fast = Duration(milliseconds: 500);

    /// A pair paced like PRODUCTION (the 2s default), so the resting and fast
    /// cadences are distinguishable. Nothing actually waits: the fake poller is
    /// change-driven and only records the pacing the real transport would use.
    ({
      OnlineMatchController host,
      OnlineMatchController guest,
      FakeMatchApi hostApi,
      FakeMatchApi guestApi,
      FakeMatch match
    }) paced() {
      final m = backend.seedMatch();
      final hostApi = FakeMatchApi(backend, 'host');
      final guestApi = FakeMatchApi(backend, 'guest');
      final host = OnlineMatchController(
          api: hostApi, matchDoc: m.doc, rng: Random(101));
      final guest = OnlineMatchController(
          api: guestApi, matchDoc: m.doc, rng: Random(202));
      addTearDown(host.disposeController);
      addTearDown(guest.disposeController);
      return (
        host: host,
        guest: guest,
        hostApi: hostApi,
        guestApi: guestApi,
        match: m
      );
    }

    test('tightens the loop for a handshake and relaxes when the roll folds',
        () async {
      final p = paced();
      expect(p.host.currentPollInterval, resting,
          reason: 'nothing is in flight before the match starts');

      // The host commits the opening roll immediately. With no guest client
      // running, rolls/1 sits at the commit phase: a handshake is outstanding
      // for both peers, and both must poll fast to see it move.
      await p.host.playMatch();
      await settle();
      expect(p.match.rolls[1]?.entropy, isNull,
          reason: 'no witness has contributed yet');
      expect(p.host.currentPollInterval, fast);
      expect(p.hostApi.pollPacing!(), fast,
          reason: 'the pacing the transport itself would wait');

      await p.guest.playMatch();
      expect(p.guest.currentPollInterval, fast,
          reason: 'a roll document it has not folded yet is a live handshake');

      await pumpUntil(() => p.host.isReady && p.guest.isReady,
          reason: 'the opening handshake never completed');
      expect(p.host.currentPollInterval, resting);
      expect(p.guest.currentPollInterval, resting);
      expect(p.hostApi.pollPacing!(), resting);
      expect(p.guestApi.pollPacing!(), resting);

      // And again for an ordinary turn roll: play on until someone is back at
      // the pre-roll gate, which is the resting state by definition.
      final lastActed = <OnlineMatchController, GameState?>{};
      await pumpUntil(() {
        if (p.host.awaitingHumanTurn || p.guest.awaitingHumanTurn) return true;
        act(p.host, lastActed);
        act(p.guest, lastActed);
        return false;
      }, reason: 'neither side reached the pre-roll gate');

      final mover = p.host.awaitingHumanTurn ? p.host : p.guest;
      final witness = identical(mover, p.host) ? p.guest : p.host;
      expect(mover.currentPollInterval, resting);
      expect(witness.currentPollInterval, resting);

      mover.rollDice();
      expect(mover.currentPollInterval, fast,
          reason: 'the fast window opens with the drive, before the commit '
              'write has even landed');
      await pumpUntil(
          () =>
              mover.currentPollInterval == resting &&
              witness.currentPollInterval == resting,
          reason: 'the fast window never closed after the roll folded');
    });

    test('a caller-supplied interval slower than 500ms caps the fast one',
        () async {
      final m = backend.seedMatch();
      final quick = OnlineMatchController(
        api: FakeMatchApi(backend, 'host'),
        matchDoc: m.doc,
        // What AIGAMMON_E2E_POLL_MS does: one knob has to override BOTH
        // cadences, or the emulator E2E would still crawl through handshakes.
        pollInterval: const Duration(milliseconds: 100),
      );
      addTearDown(quick.disposeController);
      expect(quick.fastPollInterval, const Duration(milliseconds: 100));

      final slow = OnlineMatchController(
        api: FakeMatchApi(backend, 'guest'),
        matchDoc: m.doc,
        pollInterval: const Duration(seconds: 10),
      );
      addTearDown(slow.disposeController);
      expect(slow.fastPollInterval, fast);
    });
  });

  // --- freeze vs. self-healing ----------------------------------------------

  group('cheat freeze', () {
    /// A live guest controller whose opponent (the host) is scripted directly
    /// into the store. [whiteDie]/[blackDie] pick who moves first.
    Future<({OnlineMatchController c, FakeMatch m, FakeMatchApi api})> guestAt({
      int whiteDie = 6,
      int blackDie = 3,
    }) async {
      final m = backend.seedMatch();
      seedOpening(m, whiteDie: whiteDie, blackDie: blackDie);
      final api = FakeMatchApi(backend, 'guest');
      final c = OnlineMatchController(
        api: api,
        matchDoc: m.doc,
        rng: Random(7),
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(c.disposeController);
      await c.playMatch();
      await pumpUntil(() => c.isReady);
      return (c: c, m: m, api: api);
    }

    test('a transient poll fault self-heals; an illegal opponent event freezes',
        () async {
      final g = await guestAt(); // white (the host) moves first
      final c = g.c;

      // 1. TRANSIENT: a poll blip is a banner, not a freeze, and the next
      //    successful fold clears it.
      g.api.emitPollError(const OnlineException('unavailable', 'blip'));
      await settle();
      expect(c.error, isNotNull);
      expect(c.frozen, isFalse);
      expect(c.isThinking, isTrue, reason: 'a blip must not change whose turn');

      final move = c.state.legalMoves.first;
      g.m.forgeEvent('host', 1, MoveEvent(Player.white, move));
      backend.bump(g.m.code);
      await pumpUntil(() => c.state.turn == Player.black);
      expect(c.error, isNull, reason: 'a good fold heals a transient fault');

      // 2. FREEZE: the host takes a cube nobody offered — the rules engine
      //    refuses it, so the match stops for good.
      g.m.forgeEvent('host', 1, TakeEvent(Player.white));
      backend.bump(g.m.code);
      await pumpUntil(() => c.frozen);

      final cheat = c.cheatError!;
      expect(cheat.code, 'illegal-event');
      expect(cheat.message, contains('match frozen'));
      expect(c.error, same(cheat));
      expect(c.awaitingHumanTurn, isFalse);
      expect(c.isThinking, isFalse);
      expect(c.pendingMoveOf(Player.black).value, isNull);

      // Not self-healing: further (even perfectly good) traffic changes nothing.
      backend.bump(g.m.code);
      await settle();
      expect(c.error, same(cheat));
    });

    test('an event claiming the other seat freezes', () async {
      final g = await guestAt();
      // The host writes an event for BLACK — our seat.
      g.m.forgeEvent('host', 1, DoubleEvent(Player.black));
      backend.bump(g.m.code);
      await pumpUntil(() => g.c.frozen);
      expect(g.c.cheatError!.code, 'wrong-author');
    });

    test('an event from a stranger freezes', () async {
      final g = await guestAt();
      g.m.forgeEvent('someone-else', 1, MoveEvent(Player.white, Move.none));
      backend.bump(g.m.code);
      await pumpUntil(() => g.c.frozen);
      expect(g.c.cheatError!.code, 'not-a-participant');
    });

    test('a tampered reveal freezes before any event folds', () async {
      final g = await guestAt();
      // A roll whose revealed secret is NOT the pre-image of the commitment —
      // the only way a roller could steer the dice after seeing our entropy.
      final honest = turnSecretsFor(3, 4);
      // A DIFFERENT seed, so the swapped secret really is a different pre-image
      // (same-seed searches share their secret and would verify just fine).
      final swapped = turnSecretsFor(6, 6, rng: Random(4242));
      g.m.putRoll(2, 'host', honest.commit,
          entropy: honest.entropy, reveal: swapped.secret);
      backend.bump(g.m.code);
      await pumpUntil(() => g.c.frozen);

      expect(g.c.cheatError!.code, 'fair-dice');
      expect(g.c.cheatError!.message, contains('tampered dice'));
    });

    test('a roll event whose dice differ from the roll document freezes',
        () async {
      // Black (us) opens and moves, so the NEXT roll is the host's.
      final g = await guestAt(whiteDie: 3, blackDie: 6);
      final c = g.c;
      expect(c.state.turn, Player.black);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);

      // A perfectly sound roll document deriving 3-4 …
      final s = turnSecretsFor(3, 4);
      g.m.putRoll(2, 'host', s.commit, entropy: s.entropy, reveal: s.secret);
      // … under an event claiming 6-6.
      g.m.forgeEvent('host', 1, RollEvent(Player.white, 6, 6));
      backend.bump(g.m.code);
      await pumpUntil(() => c.frozen);

      expect(c.cheatError!.code, 'dice-mismatch');
      expect(c.cheatError!.message, contains('match frozen'));
    });

    test('an opening roll from the guest freezes (openings are the host\'s)',
        () async {
      final m = backend.seedMatch();
      // The GUEST forges the opening, roll document and all.
      final s = openingSecretsFor(6, 3);
      m.putRoll(1, 'guest', s.commit, entropy: s.entropy, reveal: s.secret);
      m.forgeEvent('guest', 1, const OpeningRollEvent(whiteDie: 6, blackDie: 3));

      final c = OnlineMatchController(
        api: FakeMatchApi(backend, 'host'),
        matchDoc: m.doc,
        rng: Random(3),
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(c.disposeController);
      await c.playMatch();
      await pumpUntil(() => c.frozen);
      expect(c.cheatError!.code, 'opening-not-host');
    });
  });

  // --- resync ---------------------------------------------------------------

  group('resync', () {
    test('a submission that loses the sequence race resyncs and keeps the '
        'decision pending', () async {
      final m = backend.seedMatch();
      seedOpening(m, whiteDie: 3, blackDie: 6); // black (us) moves first
      final api = FakeMatchApi(backend, 'guest');
      final c = OnlineMatchController(
        api: api,
        matchDoc: m.doc,
        rng: Random(5),
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(c.disposeController);
      await c.playMatch();
      await pumpUntil(() => c.isReady);

      final before = api.calls['fetchEventsSince'] ?? 0;
      api.intercept = (op) => op == 'submitEvent'
          ? const AlreadyExistsException('events/1 already exists')
          : null;
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => (api.calls['fetchEventsSince'] ?? 0) > before);
      await settle();

      // A lost race is NOT a cheat, and it is NOT retried at the same seq: the
      // log is refetched and the decision stays pending for the user.
      expect(c.frozen, isFalse);
      expect(api.calls['submitEvent'], 1, reason: 'no blind retry at that seq');
      expect(c.pendingMoveOf(Player.black).value, isNotNull);

      // With the fault cleared the same decision goes through.
      api.intercept = null;
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);
      expect(c.error, isNull);
    });

    test('the roll counter survives a resync', () async {
      final m = backend.seedMatch();
      seedOpening(m, whiteDie: 3, blackDie: 6); // black (us) first; roll 1
      final api = FakeMatchApi(backend, 'guest');
      final c = OnlineMatchController(
        api: api,
        matchDoc: m.doc,
        rng: Random(5),
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(c.disposeController);
      await c.playMatch();
      await pumpUntil(() => c.isReady);

      // Force a full rebuild by losing the sequence race once.
      api.intercept = (op) => op == 'submitEvent'
          ? const AlreadyExistsException('taken')
          : null;
      c.submitMove(Player.black, c.state.legalMoves.first);
      await settle();
      api.intercept = null;

      // Black's move, then white's (scripted) roll 2 and its move.
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);
      var mirror = Game.replay([for (final e in m.events) e.event]);
      seedRoll(m,
          author: 'host', player: Player.white, die1: 5, die2: 2, gameNo: 1);
      mirror = mirror.append(RollEvent(Player.white, 5, 2));
      m.forgeEvent('host', 1,
          MoveEvent(Player.white, mirror.state.legalMoves.first));
      backend.bump(m.code);
      await pumpUntil(() => c.awaitingHumanTurn);

      // Two roll-bearing events are in the log (the opening and white's roll),
      // so OUR roll must claim index 3 — recounted from the log, not from a
      // counter the resync could have lost.
      expect(m.rollCount, 2);
      c.rollDice();
      await pumpUntil(() => m.rolls.containsKey(3));
      expect(m.rolls[3]!.roller, 'guest');
      expect(m.rolls.containsKey(4), isFalse);
      expect(c.frozen, isFalse);
    });

    test('a failed roll re-opens the gate and the retry RESUMES the same roll',
        () async {
      final m = backend.seedMatch();
      seedOpening(m, whiteDie: 3, blackDie: 6); // black (us) first
      final api = FakeMatchApi(backend, 'guest');
      final c = OnlineMatchController(
        api: api,
        matchDoc: m.doc,
        rng: Random(5),
        // Long enough that the automatic retry cannot fire during the test —
        // the manual retry is what is under test here.
        pollInterval: const Duration(seconds: 30),
      );
      addTearDown(c.disposeController);
      await c.playMatch();
      await pumpUntil(() => c.isReady);
      c.submitMove(Player.black, c.state.legalMoves.first);
      await pumpUntil(() => c.state.turn == Player.white);

      // White is scripted through its turn so we come back to our pre-roll.
      var mirror = Game.replay([for (final e in m.events) e.event]);
      seedRoll(m,
          author: 'host', player: Player.white, die1: 5, die2: 2, gameNo: 1);
      mirror = mirror.append(RollEvent(Player.white, 5, 2));
      m.forgeEvent('host', 1,
          MoveEvent(Player.white, mirror.state.legalMoves.first));
      backend.bump(m.code);
      await pumpUntil(() => c.awaitingHumanTurn);

      api.intercept = (op) =>
          op == 'createRoll' ? const OnlineException('unavailable', 'blip') : null;
      c.rollDice();
      await pumpUntil(() => c.error != null);
      expect(c.frozen, isFalse);
      expect(c.awaitingHumanTurn, isTrue,
          reason: 'one blip must not deadlock the pre-roll gate');
      expect(m.rolls.containsKey(3), isFalse);

      api.intercept = null;
      c.rollDice();
      await pumpUntil(() => m.rolls.containsKey(3));
      // Resumed, not restarted: exactly one roll document, at the same index.
      expect(api.calls['createRoll'], 2);
      expect(m.rolls.keys.toList()..sort(), [1, 2, 3]);
    });
  });

  // --- lifecycle ------------------------------------------------------------

  test('disposeController cancels polling and is idempotent', () async {
    final m = backend.seedMatch();
    seedOpening(m, whiteDie: 6, blackDie: 3);
    final c = OnlineMatchController(
      api: FakeMatchApi(backend, 'guest'),
      matchDoc: m.doc,
      pollInterval: const Duration(milliseconds: 1),
    );
    await c.playMatch();
    await pumpUntil(() => c.isReady);
    expect(backend.changes.isBroadcast, isTrue);

    c.disposeController();
    await settle();
    c.disposeController(); // idempotent

    // Nothing folds after disposal.
    final seq = m.events.last.seq;
    m.forgeEvent('host', 1, MoveEvent(Player.white, Move.none));
    backend.bump(m.code);
    await settle();
    expect(m.events.last.seq, seq + 1);
  });

  test('a non-participant cannot build a controller for the match', () {
    final m = backend.seedMatch();
    expect(
      () => OnlineMatchController(
          api: FakeMatchApi(backend, 'nobody'), matchDoc: m.doc),
      throwsArgumentError,
    );
  });

  // --- persistence ----------------------------------------------------------

  group('persistence', () {
    test('records each finished game (full events + result) and the match',
        () async {
      final rec = RecordingPersistence();
      final p = pair(length: 1, hostPersistence: rec);
      await p.host.playMatch();
      await p.guest.playMatch();
      await pumpUntil(() => p.host.isReady && p.guest.isReady);
      await playOut(p.host, p.guest);
      await settle();

      expect(p.host.matchOver, isTrue);
      expect(rec.games.length, 1, reason: 'a 1-point match is one game');
      final g = rec.games.single;
      expect(g.gameNumber, 1);
      expect(g.isCrawford, isTrue, reason: 'the first game of a 1-pointer');
      expect(g.events.first, isA<OpeningRollEvent>());
      expect(g.events.length, p.host.game.events.length);
      expect(g.result.winner, p.host.match.winner);
      expect(g.matchAfter.isMatchOver, isTrue);
      expect(rec.matchFinishedCalls, 1);
      expect(rec.finalState!.winner, p.host.match.winner);
      expect(p.host.persistenceError, isNull);
    });

    test('a persistence failure is non-fatal: sets persistenceError, folds on',
        () async {
      final rec = RecordingPersistence()..throwOnGame = 1;
      final p = pair(length: 1, guestPersistence: rec);
      await p.host.playMatch();
      await p.guest.playMatch();
      await pumpUntil(() => p.host.isReady && p.guest.isReady);
      await playOut(p.host, p.guest);
      await settle();

      expect(p.guest.matchOver, isTrue);
      expect(p.guest.persistenceError, isNotNull);
      expect(p.guest.error, isNull, reason: 'storage never touches the loop');
      expect(rec.games, isEmpty);
      expect(rec.matchFinishedCalls, 1, reason: 'chained after the failed hook');
    });
  });
}
