@Tags(['emulator'])
library;

import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:http/http.dart' as http;
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

/// End-to-end integration tests that run the real REST clients (auth, Firestore,
/// Functions) against the local Firebase Emulator Suite. They are the proof that
/// the Cloud Functions (index.ts/turnflow.ts), the firestore.rules, and the
/// online_client transport actually agree.
///
/// Excluded from the default `dart test` run by the `emulator` tag (see
/// dart_test.yaml); run them with `dart test -P emulator` INSIDE a running
/// emulator, e.g. via `firebase/run-emulator-tests.ps1`.
///
/// The tests assume the four callables (createMatch/joinMatch/rollDice/
/// submitEvent) plus firestore.rules are deployed to the emulator on the default
/// ports (Firestore 8080, Auth 9099, Functions 5001) — exactly what
/// [OnlineConfig.emulator] targets.

/// A signed-in anonymous user with a full MatchApi stack over its own token.
class TestUser {
  final AuthClient auth;
  final FirestoreRestClient firestore;
  final FunctionsClient functions;
  final MatchApi api;
  final String uid;

  TestUser(this.auth, this.firestore, this.functions, this.api, this.uid);

  Future<String> token() => auth.validToken();

  void close() {
    auth.close();
    firestore.close();
    functions.close();
  }
}

/// Sign up a fresh anonymous user and wire up its transport clients.
Future<TestUser> signIn(OnlineConfig config) async {
  final auth = AuthClient(config);
  final session = await auth.signInAnonymously();
  final firestore = FirestoreRestClient(config, token: auth.validToken);
  final functions = FunctionsClient(config, token: auth.validToken);
  return TestUser(
    auth,
    firestore,
    functions,
    MatchApi(auth, firestore, functions),
    session.uid,
  );
}

/// Fold the full event log of [matchId] into a client-side [Game]. The opening
/// roll seeds `Game.start`; `isCrawford` comes out of band from the match doc.
/// Returns the folded game and the seq of the last event consumed.
Future<({Game game, int lastSeq})> foldFromStart(
  MatchApi reader,
  String matchId,
  bool isCrawford,
) async {
  final events = await reader.fetchEventsSince(matchId, -1);
  expect(events, isNotEmpty);
  expect(events.first.event, isA<OpeningRollEvent>());
  var game = Game.start(
    events.first.event as OpeningRollEvent,
    isCrawfordGame: isCrawford,
  );
  var lastSeq = events.first.seq;
  for (final e in events.skip(1)) {
    game = game.append(e.event);
    lastSeq = e.seq;
  }
  return (game: game, lastSeq: lastSeq);
}

void main() {
  final config = OnlineConfig.emulator();

  // The match code alphabet: A-Z minus I and O, plus 2-9 (see index.ts).
  final codePattern = RegExp(r'^[A-HJ-NP-Z2-9]{6}$');

  late TestUser a; // creator -> seat white
  late TestUser b; // joiner  -> seat black
  final extras = <TestUser>[];

  setUp(() async {
    a = await signIn(config);
    b = await signIn(config);
  });

  tearDown(() {
    a.close();
    b.close();
    for (final u in extras) {
      u.close();
    }
    extras.clear();
  });

  /// Map a seat to the user holding it (white == creator a, black == joiner b).
  TestUser userForSeat(Player seat) => seat == Player.white ? a : b;

  group('lifecycle', () {
    test('createMatch -> waiting; joinMatch -> active with opening roll',
        () async {
      final created = await a.api.createMatch(3);
      expect(created.code, matches(codePattern),
          reason: 'code must be 6 chars over the confusable-free alphabet');
      expect(created.matchId, isNotEmpty);

      // Before anyone joins: waiting, only the white seat filled, no play yet.
      final waiting = await a.api.fetchMatch(created.matchId);
      expect(waiting.status, 'waiting');
      expect(waiting.code, created.code);
      expect(waiting.matchLength, 3);
      expect(waiting.whiteUid, a.uid);
      expect(waiting.blackUid, isNull);
      expect(waiting.gameNo, 0);
      expect(waiting.seq, -1);
      expect(waiting.turn, isNull);
      expect(waiting.phase, isNull);

      // B joins -> active, both seats filled, game 1 opening auto-appended.
      final joinedId = await b.api.joinMatch(created.code);
      expect(joinedId, created.matchId);

      final active = await a.api.fetchMatch(created.matchId);
      expect(active.status, 'active');
      expect(active.whiteUid, a.uid);
      expect(active.blackUid, b.uid);
      expect(active.gameNo, 1);
      expect(active.seq, 0);
      expect(active.phase, GamePhase.moving);

      // Event seq 0 is a valid, non-tie opening roll.
      final events = await a.api.fetchEventsSince(created.matchId, -1);
      expect(events, hasLength(1));
      final first = events.single;
      expect(first.seq, 0);
      expect(first.gameNo, 1);
      final opening = first.event as OpeningRollEvent;
      expect(opening.whiteDie, inInclusiveRange(1, 6));
      expect(opening.blackDie, inInclusiveRange(1, 6));
      expect(opening.whiteDie, isNot(equals(opening.blackDie)),
          reason: 'opening ties are re-rolled, never recorded');

      // The turn belongs to the higher opening die.
      final expectedFirst =
          opening.whiteDie > opening.blackDie ? Player.white : Player.black;
      expect(active.turn, expectedFirst);
      expect(active.turn, opening.firstPlayer);
    });

    test('joining a full match is rejected', () async {
      final created = await a.api.createMatch(3);
      await b.api.joinMatch(created.code);
      final c = await signIn(config);
      extras.add(c);
      await expectLater(
        c.api.joinMatch(created.code),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'FAILED_PRECONDITION')),
      );
    });
  });

  group('full game', () {
    test('plays game 1 to completion; server + local fold stay consistent',
        () async {
      final created = await a.api.createMatch(3);
      await b.api.joinMatch(created.code);

      final start = await a.api.fetchMatch(created.matchId);
      final folded = await foldFromStart(a.api, created.matchId, start.isCrawford);
      var game = folded.game;
      var lastSeq = folded.lastSeq;

      // Drive game 1 with a first-legal-move policy. Each half-move is one
      // server action followed by a fetch that must round-trip exactly what we
      // just caused. Bounded to keep the suite quick.
      var guard = 0;
      while (game.state.phase != GamePhase.gameOver && guard < 400) {
        guard++;
        final seat = game.state.turn;
        final actor = userForSeat(seat);

        if (game.state.phase == GamePhase.awaitingRoll) {
          final dice = await actor.api.rollDice(created.matchId);
          final fresh = await actor.api.fetchEventsSince(created.matchId, lastSeq);
          expect(fresh, hasLength(1));
          expect(fresh.single.seq, greaterThan(lastSeq));
          expect(fresh.single.event, RollEvent(seat, dice.die1, dice.die2),
              reason: 'the appended roll must equal the callable result');
          game = game.append(fresh.single.event);
          lastSeq = fresh.single.seq;
          continue;
        }

        // moving: submit the first legal move (empty == a forced pass). If it
        // ends the game, compute the result locally FIRST and submit the claim.
        final legal = game.state.legalMoves;
        final move = legal.isEmpty ? Move.none : legal.first;
        final moveEvent = MoveEvent(seat, move);
        final localNext = game.append(moveEvent);
        GameResultClaim? claim;
        if (localNext.state.phase == GamePhase.gameOver) {
          final r = localNext.state.result!;
          claim = GameResultClaim(
              winner: r.winner, points: r.points, outcome: r.outcome);
        }

        await actor.api.submitEvent(created.matchId, moveEvent, result: claim);
        final fresh = await actor.api.fetchEventsSince(created.matchId, lastSeq);
        expect(fresh, isNotEmpty);
        expect(fresh.first.seq, greaterThan(lastSeq));
        expect(fresh.first.event, moveEvent,
            reason: 'the stored move must round-trip to what we submitted');
        game = game.append(fresh.first.event);
        lastSeq = fresh.first.seq;

        if (claim != null) {
          // Terminal move. If the match continues, the server auto-appends the
          // next game's opening roll as an additional event.
          final after = await actor.api.fetchMatch(created.matchId);
          if (after.status == 'active') {
            expect(fresh, hasLength(2));
            expect(fresh[1].seq, greaterThan(fresh.first.seq));
            expect(fresh[1].event, isA<OpeningRollEvent>());
            expect(fresh[1].gameNo, 2);
            lastSeq = fresh[1].seq;
          } else {
            expect(after.status, 'complete');
            expect(fresh, hasLength(1));
          }
        } else {
          expect(fresh, hasLength(1));
        }
      }

      expect(game.state.phase, GamePhase.gameOver,
          reason: 'game 1 must finish within the iteration bound');

      // The local game-1 result must match the server's folded scores.
      final result = game.state.result!;
      final summary = await a.api.fetchMatch(created.matchId);
      final expectedWhite =
          result.winner == Player.white ? result.points : 0;
      final expectedBlack =
          result.winner == Player.black ? result.points : 0;
      expect(summary.whiteScore, expectedWhite);
      expect(summary.blackScore, expectedBlack);

      if (summary.status == 'complete') {
        // A backgammon (3 pts) in game 1 ends the 3-point match outright.
        expect(summary.winner, result.winner);
        expect(summary.phase, GamePhase.gameOver);
      } else {
        expect(summary.status, 'active');
        expect(summary.gameNo, 2);
        expect(summary.phase, GamePhase.moving,
            reason: 'the next game is seeded and awaiting the first move');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('turn + author enforcement', () {
    late String matchId;
    late Player onTurn;

    setUp(() async {
      final created = await a.api.createMatch(3);
      matchId = created.matchId;
      await b.api.joinMatch(created.code);
      final snap = await a.api.fetchMatch(matchId);
      onTurn = snap.turn!;
    });

    test('off-turn move is rejected (permission denied)', () async {
      final offTurn = onTurn.opponent;
      // Author check passes (player == own seat); the turn check rejects it.
      await expectLater(
        userForSeat(offTurn)
            .api
            .submitEvent(matchId, MoveEvent(offTurn, Move.none)),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'PERMISSION_DENIED')),
      );
    });

    test('event stamped with the wrong seat is rejected', () async {
      // The on-turn user submits an event authored as the opponent -> rejected
      // by the author check BEFORE the turn flow even runs.
      await expectLater(
        userForSeat(onTurn)
            .api
            .submitEvent(matchId, MoveEvent(onTurn.opponent, Move.none)),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'PERMISSION_DENIED')),
      );
    });

    test('off-turn roll is rejected (permission denied, actor checked first)',
        () async {
      await expectLater(
        userForSeat(onTurn.opponent).api.rollDice(matchId),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'PERMISSION_DENIED')),
      );
    });

    test('on-turn roll in the moving phase is rejected (failed precondition)',
        () async {
      // After the opening the on-turn player must MOVE, not roll: the phase
      // guard fires (this is the failed-precondition path for rollDice).
      await expectLater(
        userForSeat(onTurn).api.rollDice(matchId),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'FAILED_PRECONDITION')),
      );
    });
  });

  group('rules enforcement', () {
    late String matchId;

    setUp(() async {
      final created = await a.api.createMatch(3);
      matchId = created.matchId;
      await b.api.joinMatch(created.code);
    });

    test('a participant cannot write the match doc directly (rules deny)',
        () async {
      // Raw Firestore REST PATCH with A's real ID token — a client write, which
      // firestore.rules deny unconditionally (`allow write: if false`).
      final url = Uri.parse(
        '${config.firestoreDocumentsBase}/matches/$matchId'
        '?updateMask.fieldPaths=status',
      );
      final client = http.Client();
      try {
        final res = await client.patch(
          url,
          headers: {
            'Authorization': 'Bearer ${await a.token()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'fields': {
              'status': {'stringValue': 'HACKED'}
            }
          }),
        );
        expect(res.statusCode, 403,
            reason: 'client writes must be denied by the rules');
        expect(res.body, contains('PERMISSION_DENIED'));
      } finally {
        client.close();
      }

      // And the write really did not land.
      final after = await a.api.fetchMatch(matchId);
      expect(after.status, 'active');
    });

    test('a non-participant cannot read the match doc', () async {
      final c = await signIn(config);
      extras.add(c);
      await expectLater(
        c.api.fetchMatch(matchId),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'PERMISSION_DENIED')),
      );
    });
  });

  group('cube path', () {
    test('double -> take flows through the turn phases', () async {
      final created = await a.api.createMatch(3);
      await b.api.joinMatch(created.code);
      final start = await a.api.fetchMatch(created.matchId);
      final folded =
          await foldFromStart(a.api, created.matchId, start.isCrawford);
      var game = folded.game;

      // The opening winner makes one legal move so the opponent reaches
      // awaitingRoll and may double.
      final mover = game.state.turn;
      final move = game.state.legalMoves.first;
      await userForSeat(mover)
          .api
          .submitEvent(created.matchId, MoveEvent(mover, move));
      game = game.append(MoveEvent(mover, move));

      // Opponent doubles.
      final doubler = game.state.turn;
      await userForSeat(doubler)
          .api
          .submitEvent(created.matchId, DoubleEvent(doubler));
      game = game.append(DoubleEvent(doubler));

      var snap = await a.api.fetchMatch(created.matchId);
      expect(snap.phase, GamePhase.cubeOffered);
      expect(snap.turn, doubler.opponent, reason: 'turn flips to the decider');

      // Decider takes.
      final decider = game.state.turn;
      await userForSeat(decider)
          .api
          .submitEvent(created.matchId, TakeEvent(decider));
      game = game.append(TakeEvent(decider));

      snap = await a.api.fetchMatch(created.matchId);
      expect(snap.phase, GamePhase.awaitingRoll);
      expect(snap.turn, doubler, reason: 'after a take the doubler is on roll');
    });

    test('double -> drop ends a 1-point match with a result claim', () async {
      final created = await a.api.createMatch(1);
      await b.api.joinMatch(created.code);
      final start = await a.api.fetchMatch(created.matchId);
      // A 1-point match's only game IS the Crawford game.
      expect(start.isCrawford, isTrue);
      final folded =
          await foldFromStart(a.api, created.matchId, start.isCrawford);
      var game = folded.game;

      // Opening winner moves -> opponent reaches awaitingRoll.
      final mover = game.state.turn;
      final move = game.state.legalMoves.first;
      await userForSeat(mover)
          .api
          .submitEvent(created.matchId, MoveEvent(mover, move));
      game = game.append(MoveEvent(mover, move));

      // The server's turn-flow mirror does NOT enforce Crawford (that is a
      // client rule), so a double is accepted at the transport level even here.
      // We therefore build the cube events directly rather than folding them
      // through GameState (which would reject a Crawford double).
      final doubler = game.state.turn; // opponent, now on roll
      final decider = doubler.opponent;

      await userForSeat(doubler)
          .api
          .submitEvent(created.matchId, DoubleEvent(doubler));
      var snap = await a.api.fetchMatch(created.matchId);
      expect(snap.phase, GamePhase.cubeOffered);
      expect(snap.turn, decider);

      // Decider drops: the doubler wins the pre-double cube value (1).
      await userForSeat(decider).api.submitEvent(
            created.matchId,
            DropEvent(decider),
            result: GameResultClaim(
              winner: doubler,
              points: 1,
              outcome: GameOutcome.drop,
            ),
          );

      snap = await a.api.fetchMatch(created.matchId);
      expect(snap.status, 'complete');
      expect(snap.phase, GamePhase.gameOver);
      expect(snap.winner, doubler);
      final winnerScore =
          doubler == Player.white ? snap.whiteScore : snap.blackScore;
      expect(winnerScore, 1, reason: 'reaching matchLength completes the match');
    });
  });
}
