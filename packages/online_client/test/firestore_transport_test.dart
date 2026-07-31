import 'dart:async';
import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:http/http.dart' as http;
import 'package:match_transport/match_transport.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

import 'mock_api.dart';

/// [FirestoreTransport] against a scripted REST client: the transport CONTRACT
/// (`packages/match_transport/lib/src/match_transport.dart`) expressed in terms
/// of the shipped Firestore document model.
///
/// The four things only this suite can pin down, because they are invisible from
/// the emulator side:
///
///  * the **0-based↔1-based seq bridge**, in both directions;
///  * the **read-budget watermarks** — which documents are never read twice, and
///    that a direct pull SEEDS the poll instead of being re-fetched;
///  * the **typed-error mapping** from `firestore.rules` refusals onto
///    contested / rejected / unavailable;
///  * the **adaptive cadence** and what [MatchTransport.inboundCadence] reports.
void main() {
  /// The seated match both peers see: host = white = `uid-local`.
  const seated = MatchDoc(
    code: 'C',
    hostUid: 'uid-local',
    guestUid: 'uid-remote',
    length: 3,
    cubeless: false,
    status: 'active',
  );

  /// A transport over [handler], already connected (so [seated] is the session).
  ///
  /// [poll] defaults to a cadence far longer than any test, so a test sees ONLY
  /// the reads it asks for; the polling tests turn it down themselves.
  Future<FirestoreTransport> connected(
    Future<http.Response> Function(http.Request req) handler, {
    MatchDoc match = seated,
    String uid = 'uid-local',
    Duration poll = const Duration(seconds: 30),
  }) async {
    final api = await apiFor(handler, uid: uid);
    final t = FirestoreTransport(
      api: api,
      code: 'C',
      match: match,
      pollInterval: poll,
    );
    addTearDown(t.dispose);
    await t.connect();
    return t;
  }

  /// Answers every read with an empty page and every write with success.
  Future<http.Response> quiet(http.Request req) async {
    if (req.url.path.endsWith(':runQuery')) return http.Response('[]', 200);
    return ok({});
  }

  /// Waits (in real time) for [done], failing on timeout.
  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 5),
    String reason = 'condition never became true',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  // =========================================================================
  group('connect', () {
    test('seats this device from the match document and names both authors',
        () async {
      final t = await connected(quiet);
      final s = await t.connect();
      expect(s.assignedSide, Player.white, reason: 'the host plays white');
      expect(s.localAuthor, 'uid-local');
      expect(s.hostAuthor, 'uid-local');
      expect(s.guestAuthor, 'uid-remote');
      expect(s.isHost, isTrue);
      expect(s.sideOf('uid-remote'), Player.black);
      expect(s.config, const MatchConfig(length: 3));
      expect(s.matchCode, 'C');
      expect(t.status, TransportStatus.connected);
      expect(t.capabilities.durable, isTrue);
      expect(t.capabilities.rejoinable, isTrue);
    });

    test('the guest is seated black by the same document', () async {
      final t = await connected(quiet, uid: 'uid-remote');
      final s = await t.connect();
      expect(s.assignedSide, Player.black);
      expect(s.isHost, isFalse);
      expect(s.sideOf('uid-local'), Player.white);
    });

    test('the resume token is the invite code — a stable match identity',
        () async {
      // The code IS the document id, claimed write-once by the create, so it can
      // never name two matches: re-connecting to the same code is the SAME
      // identity (the controller keeps its watermarks), a different code is not.
      final t = await connected(quiet);
      expect((await t.connect()).resumeToken, 'C');

      final api = await apiFor(quiet);
      final other = FirestoreTransport(
        api: api,
        code: 'D',
        match: const MatchDoc(
          code: 'D',
          hostUid: 'uid-local',
          guestUid: 'uid-remote',
          length: 1,
          cubeless: false,
          status: 'active',
        ),
      );
      addTearDown(other.dispose);
      expect((await other.connect()).resumeToken, isNot('C'));
    });

    test('cubeless travels from the match document into the config', () async {
      final t = await connected(quiet,
          match: const MatchDoc(
            code: 'C',
            hostUid: 'uid-local',
            guestUid: 'uid-remote',
            length: 5,
            cubeless: true,
            status: 'active',
          ));
      expect((await t.connect()).config,
          const MatchConfig(length: 5, cubeless: true));
    });

    test('waits for the guest seat, then reports the opponent present',
        () async {
      // The seat identities travel on the session, so a controller handed a null
      // guestAuthor would freeze on the opponent's first event. The host's
      // connect therefore polls the match document until somebody joins.
      var reads = 0;
      final api = await apiFor((req) async {
        if (req.method == 'GET') {
          reads++;
          return matchRow(
              guestUid: reads < 3 ? null : 'uid-remote',
              status: reads < 3 ? 'waiting' : 'active');
        }
        return quiet(req);
      });
      final t = FirestoreTransport(
        api: api,
        code: 'C',
        pollInterval: const Duration(milliseconds: 5),
      );
      addTearDown(t.dispose);
      expect(t.opponentPresent, isFalse);
      final presence = <bool>[];
      t.opponentPresence.listen(presence.add);

      final s = await t.connect();
      expect(s.guestAuthor, 'uid-remote');
      expect(t.opponentPresent, isTrue);
      expect(reads, 3, reason: 'the match document is read until the seat fills');
      await pumpEventQueue();
      expect(presence, [true]);
    });

    test('the seat wait BACKS OFF instead of billing a flat cadence forever',
        () async {
      // "Create a match, then go and tell your friend" is the longest idle
      // window in the product, and every cycle of this wait bills TWICE against
      // the free tier (the read, plus the `matchOf(code)` rules-get it
      // evaluates). A flat cadence with no ceiling turns an unattended lobby
      // into an unbounded meter. The screen's own lobby wait has backed off for
      // this reason since v0.11; this loop had not.
      final at = <DateTime>[];
      final api = await apiFor((req) async {
        if (req.method == 'GET') {
          at.add(DateTime.now());
          return matchRow(guestUid: null, status: 'waiting');
        }
        return quiet(req);
      });
      const poll = Duration(milliseconds: 10);
      final t = FirestoreTransport(api: api, code: 'C', pollInterval: poll);
      addTearDown(t.dispose);
      // Nobody ever joins, so this never completes; the teardown ends it.
      unawaited(t.connect().then<void>((_) {}, onError: (Object _) {}));
      await Future<void>.delayed(const Duration(seconds: 1));

      // A flat 10ms cadence would be ~100 reads in that second. The backoff
      // settles at the ceiling long before then.
      expect(at.length, greaterThan(3), reason: 'it must still be polling');
      expect(at.length, lessThan(40),
          reason: 'a flat cadence would have billed ~100 reads by now');
      // And it is CAPPED, not still doubling. The ceiling is 8 * poll = 80ms,
      // so anything at or under ~1.5 ceilings is the capped schedule plus timer
      // jitter; the old bound of 400ms was FIVE ceilings and would have passed
      // against a cap that had quietly widened by 4x.
      final last = at.last.difference(at[at.length - 2]);
      expect(last, lessThanOrEqualTo(const Duration(milliseconds: 120)));
    });

    test('the seat-wait schedule reaches its ceiling and stays there', () {
      // The wall-clock test above can only bound the cadence loosely. The
      // schedule itself is exact, so assert it exactly — that is what catches a
      // ceiling that widens, a doubling that never stops, and (the one that
      // would be a SPIN rather than a cost) a shift that overflows to a
      // zero-length sleep once a lobby has been left open for hours.
      const poll = Duration(seconds: 2);
      Duration at(int cycle) => FirestoreTransport.seatWaitFor(poll, cycle);
      for (var c = 0; c < 5; c++) {
        expect(at(c), poll, reason: 'cycle $c is still at the resting cadence');
      }
      expect(at(5), poll * 2);
      expect(at(6), poll * 4);
      expect(at(7), poll * 8, reason: 'the ceiling');
      expect(at(8), poll * 8, reason: 'and it does not move past it');
      expect(at(1000), poll * 8, reason: 'nor after an hour in the lobby');
      expect(at(1 << 40), poll * 8, reason: 'nor when the shift would overflow');
    });

    test('a device with no seat in the match is rejected', () async {
      final api = await apiFor(quiet, uid: 'uid-stranger');
      final stranger = FirestoreTransport(api: api, code: 'C', match: seated);
      addTearDown(stranger.dispose);
      await expectLater(stranger.connect(), throwsA(isA<TransportRejected>()));
    });

    test('an unknown code is a rejection, not a retry', () async {
      final api = await apiFor((req) async {
        if (req.method == 'GET') return http.Response('', 404);
        return quiet(req);
      });
      final t = FirestoreTransport(api: api, code: 'C');
      addTearDown(t.dispose);
      await expectLater(
        t.connect(),
        throwsA(isA<TransportRejected>()
            .having((e) => e.code, 'code', 'NOT_FOUND')),
      );
    });
  });

  // =========================================================================
  group('seq mapping', () {
    test('sendEvent writes the 1-based seq at the 0-based document id',
        () async {
      final writes = <Map<String, Object?>>[];
      final t = await connected((req) async {
        if (req.url.path.endsWith(':commit')) {
          final body = jsonDecode(req.body) as Map;
          writes.add(((body['writes'] as List).single as Map)
              .cast<String, Object?>());
        }
        return quiet(req);
      });

      await t.sendEvent(seq: 1, gameNo: 1, event: DoubleEvent(Player.white));
      await t.sendEvent(seq: 7, gameNo: 2, event: TakeEvent(Player.black));

      final first = writes.first['update'] as Map;
      expect(first['name'], endsWith('/matches/C/events/00000000'),
          reason: 'contract seq 1 is document 0');
      expect((first['fields'] as Map)['seq'], {'integerValue': '0'});
      final second = writes.last['update'] as Map;
      expect(second['name'], endsWith('/matches/C/events/00000006'));
      expect((second['fields'] as Map)['seq'], {'integerValue': '6'});
    });

    test('eventsSince(0) reads the WHOLE log and renumbers it from 1', () async {
      final cursors = <int>[];
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          cursors.add(queryCursor(req));
          return http.Response(
            eventRows([
              (0, const OpeningRollEvent(whiteDie: 6, blackDie: 3)),
              (1, DoubleEvent(Player.white)),
            ]),
            200,
          );
        }
        return quiet(req);
      });

      final frames = await t.eventsSince(0);
      expect(cursors, [-1], reason: 'seq > -1 is every document');
      expect(frames.map((f) => f.seq), [1, 2]);
      expect(frames.first.event, isA<OpeningRollEvent>());
      expect(frames.first.author, 'uid-local');
      expect(frames.first.gameNo, 1);

      await t.eventsSince(4);
      expect(cursors, [-1, 3], reason: 'contract seq 4 is document 3');
    });

    test('a polled event arrives renumbered from 1', () async {
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          return http.Response(
              eventRows([(0, const OpeningRollEvent(whiteDie: 6, blackDie: 3))]),
              200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      final frames = <InboundFrame>[];
      t.inbound.listen(frames.add);
      await waitFor(() => frames.isNotEmpty, reason: 'nothing was polled');
      expect((frames.first as EventFrame).seq, 1);
    });
  });

  // =========================================================================
  group('read budget', () {
    test('a direct pull SEEDS the poll: nothing is read twice', () async {
      // The controller primes with eventsSince(0) right after connect. The poll
      // cursor must adopt that answer instead of re-reading the same log a cycle
      // later — one full log re-read per match session is exactly what the
      // watermark exists to avoid.
      final cursors = <int>[];
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          final cursor = queryCursor(req);
          cursors.add(cursor);
          if (cursor < 0) {
            return http.Response(
                eventRows([
                  (0, const OpeningRollEvent(whiteDie: 6, blackDie: 3)),
                  (1, DoubleEvent(Player.white)),
                ]),
                200);
          }
          return http.Response('[]', 200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      expect(await t.eventsSince(0), hasLength(2));
      await waitFor(() => cursors.length >= 3,
          reason: 'the poll loop never ran');
      expect(cursors.first, -1);
      expect(cursors.skip(1), everyElement(1),
          reason: 'every later read starts past the primed events');
    });

    test('a polled event advances the cursor past itself', () async {
      final cursors = <int>[];
      var served = false;
      await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          cursors.add(queryCursor(req));
          if (served) return http.Response('[]', 200);
          served = true;
          return http.Response(
              eventRows([(0, DoubleEvent(Player.white)), (1, TakeEvent(Player.black))]),
              200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      await waitFor(() => cursors.length >= 3);
      expect(cursors.first, -1);
      expect(cursors[1], 1, reason: 'the two delivered events are retired');
    });

    test('a roll is re-emitted only when its phase advances, then retired',
        () async {
      final phases = <Map<String, Object?>>[
        {'n': 1, 'roller': 'u', 'commit': hexA},
        {'n': 1, 'roller': 'u', 'commit': hexA},
        {'n': 1, 'roller': 'u', 'commit': hexA, 'entropy': hexB},
        {'n': 1, 'roller': 'u', 'commit': hexA, 'entropy': hexB, 'reveal': hexC},
      ];
      var calls = 0;
      final cursors = <int>[];
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'events') {
            return http.Response('[]', 200);
          }
          cursors.add(queryCursor(req));
          final body =
              calls < phases.length ? rollRows([phases[calls]]) : '[]';
          calls++;
          return http.Response(body, 200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      final seen = <FairDicePhase>[];
      t.inbound.listen((f) {
        if (f is RollFrame) seen.add(f.phase);
      });
      await waitFor(() => calls > phases.length,
          reason: 'the roll poll never got past the scripted phases');

      expect(seen, [
        FairDicePhase.committed,
        FairDicePhase.entropy,
        FairDicePhase.revealed,
      ], reason: 'the unchanged second cycle must not re-emit');
      expect(cursors.take(4), everyElement(1));
      expect(cursors[4], 2,
          reason: 'a roll that completed can never change again');
    });

    test('a completed roll fetched directly is retired too', () async {
      final cursors = <int>[];
      final t = await connected((req) async {
        if (req.method == 'GET') {
          return ok({
            'name': 'projects/p/databases/(default)/documents/matches/C/rolls/'
                '00000001',
            'fields': {
              'n': {'integerValue': '1'},
              'roller': {'stringValue': 'u'},
              'commit': {'stringValue': hexA},
              'entropy': {'stringValue': hexB},
              'reveal': {'stringValue': hexC},
            },
          });
        }
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') cursors.add(queryCursor(req));
          return http.Response('[]', 200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      final frame = await t.fetchRoll(1);
      expect(frame!.isComplete, isTrue);
      expect(frame.n, 1);
      expect(frame.completed, isNotNull);
      await waitFor(() => cursors.isNotEmpty);
      expect(cursors.first, 2, reason: 'the poll starts above the finished roll');
    });

    test('rollsSince is exact regardless of the watermark', () async {
      // A direct pull must answer what it was asked for — the floor is the POLL
      // loop's business only, or a full replace would come back short.
      final cursors = <int>[];
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'events') {
            return http.Response('[]', 200);
          }
          cursors.add(queryCursor(req));
          return http.Response(
              rollRows([
                {
                  'n': 1,
                  'roller': 'u',
                  'commit': hexA,
                  'entropy': hexB,
                  'reveal': hexC,
                },
                {'n': 2, 'roller': 'u', 'commit': hexA},
              ]),
              200);
        }
        return quiet(req);
      });

      expect((await t.rollsSince(1)).map((r) => r.n), [1, 2]);
      expect(cursors, [1]);
      // Roll 1 has been retired by that answer, but asking again still returns it.
      expect((await t.rollsSince(1)).map((r) => r.n), [1, 2]);
      expect(cursors, [1, 1]);
    });
  });

  // =========================================================================
  group('error mapping', () {
    test('a taken seq is CONTESTED and carries the contested seq', () async {
      final t = await connected((req) async {
        if (req.url.path.endsWith(':commit')) {
          return err(409, 'ALREADY_EXISTS', 'taken');
        }
        return quiet(req);
      });
      await expectLater(
        t.sendEvent(seq: 4, gameNo: 1, event: DoubleEvent(Player.white)),
        throwsA(isA<TransportContested>()
            .having((e) => e.peerLastSeq, 'peerLastSeq', 4)),
      );
    });

    test('a taken roll index is CONTESTED', () async {
      final t = await connected((req) async {
        if (req.url.path.endsWith(':commit')) {
          return err(409, 'ALREADY_EXISTS', 'taken');
        }
        return quiet(req);
      });
      await expectLater(
          t.createRoll(2, hexA), throwsA(isA<TransportContested>()));
    });

    test('a rules refusal is REJECTED and never retryable', () async {
      final t = await connected((req) async {
        if (req.method == 'PATCH') return err(403, 'PERMISSION_DENIED');
        return quiet(req);
      });
      await expectLater(
          t.sendEntropy(1, hexB), throwsA(isA<TransportRejected>()));
      await expectLater(
          t.sendReveal(1, hexA), throwsA(isA<TransportRejected>()));
    });

    test('anything else is UNAVAILABLE — it may or may not have landed',
        () async {
      final t = await connected((req) async {
        if (req.url.path.endsWith(':commit')) return err(503, 'UNAVAILABLE');
        return quiet(req);
      });
      await expectLater(
        t.sendEvent(seq: 1, gameNo: 1, event: DoubleEvent(Player.white)),
        throwsA(isA<TransportUnavailable>()),
      );
    });

    test('a poll blip surfaces on inbound WITHOUT closing it, and self-heals',
        () async {
      var calls = 0;
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          calls++;
          if (calls == 1) return err(503, 'UNAVAILABLE');
          return http.Response(
              eventRows([(0, DoubleEvent(Player.white))]), 200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      final errors = <Object>[];
      final frames = <InboundFrame>[];
      var closed = false;
      t.inbound.listen(frames.add,
          onError: errors.add, onDone: () => closed = true);
      final statuses = <TransportStatus>[];
      t.statusStream.listen((e) => statuses.add(e.status));

      await waitFor(() => errors.isNotEmpty, reason: 'the blip never surfaced');
      expect(errors.single, isA<TransportUnavailable>());
      expect(t.status, TransportStatus.reconnecting);
      expect(t.statusReason, isNotNull);

      await waitFor(() => frames.isNotEmpty,
          reason: 'the loop stopped after one failure');
      expect(closed, isFalse, reason: 'inbound must never end to signal trouble');
      expect(t.status, TransportStatus.connected);
      expect(t.statusReason, isNull);
      expect(statuses,
          containsAllInOrder([
            TransportStatus.reconnecting,
            TransportStatus.connected,
          ]));
    });

    test('an UNDECODABLE event document is terminal, not a poll-forever drain',
        () async {
      // The quota bug this closes: `events/{seq}` is write-once, so a document
      // whose `event` string is not a `GameEvent` will never decode. The old
      // code let `jsonDecode`/`GameEvent.fromJson` escape as a bare
      // `FormatException`, which the loop caught as generic IO and retried at
      // the poll cadence — ~43,000 reads a day against a 50,000 quota, on one
      // bad document, forever.
      var queries = 0;
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          queries++;
          // A well-formed envelope carrying an `event` string that is not JSON.
          return http.Response(
            jsonEncode([
              {
                'document': {
                  'name': 'projects/p/databases/(default)/documents/matches/C'
                      '/events/00000000',
                  'fields': {
                    'seq': {'integerValue': '0'},
                    'gameNo': {'integerValue': '1'},
                    'author': {'stringValue': 'uid-remote'},
                    'event': {'stringValue': 'not json at all'},
                  },
                },
              },
            ]),
            200,
          );
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      final errors = <Object>[];
      var closed = false;
      t.inbound.listen((_) {}, onError: errors.add, onDone: () => closed = true);

      await waitFor(() => errors.isNotEmpty, reason: 'the fault never surfaced');
      expect(errors.single, isA<TransportRejected>()
          .having((e) => e.code, 'code', 'malformed-event'));
      expect(t.status, TransportStatus.failed,
          reason: 'a document that will never decode is not "reconnecting"');
      expect(closed, isFalse,
          reason: 'inbound must never end to signal trouble');

      // And the loop is STOPPED: many poll intervals later, no further reads.
      final after = queries;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(queries, after, reason: 'the poll loop kept re-reading it');
      expect(errors.length, 1, reason: 'and kept re-reporting it');
    });

    test('an undecodable ROLL document is terminal the same way', () async {
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'events') {
            return http.Response('[]', 200);
          }
          return http.Response(
            jsonEncode([
              {
                'document': {
                  'name': 'projects/p/databases/(default)/documents/matches/C'
                      '/rolls/1',
                  'fields': {
                    'n': {'integerValue': '1'},
                    'roller': {'stringValue': 'uid-remote'},
                    // `commit` must be a string; an integer is undecodable.
                    'commit': {'integerValue': '7'},
                  },
                },
              },
            ]),
            200,
          );
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));

      final errors = <Object>[];
      t.inbound.listen((_) {}, onError: errors.add);
      await waitFor(() => errors.isNotEmpty);
      expect(errors.single, isA<TransportRejected>()
          .having((e) => e.code, 'code', 'malformed-roll'));
      expect(t.status, TransportStatus.failed);
    });

    test('every operation refuses to run before connect, and after dispose',
        () async {
      final api = await apiFor(quiet);
      final t = FirestoreTransport(api: api, code: 'C', match: seated);
      expect(
        () => t.sendEvent(seq: 1, gameNo: 1, event: DoubleEvent(Player.white)),
        throwsA(isA<TransportUnavailable>()
            .having((e) => e.code, 'code', 'not-connected')),
      );
      await t.connect();
      await t.dispose();
      expect(t.connect, throwsA(isA<TransportUnavailable>()));
      expect(() => t.eventsSince(0), throwsA(isA<TransportUnavailable>()));
    });
  });

  // =========================================================================
  group('pacing', () {
    test('the pace hint switches the cadence the loop uses', () async {
      final t = await connected(quiet, poll: const Duration(seconds: 2));
      expect(t.inboundCadence, const Duration(seconds: 2));
      t.setPaceHint(fast: true);
      expect(t.inboundCadence, const Duration(milliseconds: 500));
      t.setPaceHint(fast: false);
      expect(t.inboundCadence, const Duration(seconds: 2));
    });

    test('a resting cadence slower than the fast one caps it', () async {
      // The single-knob property the emulator E2E relies on: turning the resting
      // interval down to 100ms must turn BOTH cadences down.
      final api = await apiFor(quiet);
      final t = FirestoreTransport(
        api: api,
        code: 'C',
        match: seated,
        pollInterval: const Duration(milliseconds: 100),
      );
      addTearDown(t.dispose);
      await t.connect();
      expect(t.fastPollInterval, const Duration(milliseconds: 100));
      t.setPaceHint(fast: true);
      expect(t.inboundCadence, const Duration(milliseconds: 100));
    });

    test('a fast hint really does poll faster', () async {
      var calls = 0;
      final api = await apiFor((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'events') calls++;
          return http.Response('[]', 200);
        }
        return quiet(req);
      });
      final t = FirestoreTransport(
        api: api,
        code: 'C',
        match: seated,
        pollInterval: const Duration(seconds: 30),
        fastPollInterval: const Duration(milliseconds: 5),
      );
      addTearDown(t.dispose);
      t.setPaceHint(fast: true);
      await t.connect();
      await waitFor(() => calls >= 3,
          reason: 'the fast cadence was not used for the loop');
    });

    test('the reported cadence is real, so the controller can pace its retries',
        () async {
      final t = await connected(quiet, poll: const Duration(seconds: 2));
      expect(t.inboundCadence, isNot(Duration.zero));
      expect(t.suggestedGateTimeout, const Duration(seconds: 8),
          reason: 'a committed write needs several poll cycles to come back');
    });
  });

  // =========================================================================
  group('lifecycle', () {
    test('a healthy session never asks the controller to replay', () async {
      // No ResetFrame: the poll cursor is exact, so a gap is impossible, and the
      // match identity cannot change under a transport bound to one code. A
      // rejoin is a NEW transport, and it re-primes on connect anyway.
      final t = await connected((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          if (queriedCollection(req) == 'rolls') return http.Response('[]', 200);
          return http.Response(
              eventRows([(0, DoubleEvent(Player.white))]), 200);
        }
        return quiet(req);
      }, poll: const Duration(milliseconds: 5));
      final frames = <InboundFrame>[];
      t.inbound.listen(frames.add);
      await waitFor(() => frames.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(frames.whereType<ResetFrame>(), isEmpty);
    });

    test('complete flips the match document, and only its status', () async {
      final patches = <Uri>[];
      final t = await connected((req) async {
        if (req.method == 'PATCH') {
          patches.add(req.url);
          return matchRow(status: 'complete');
        }
        return quiet(req);
      });
      await t.complete();
      expect(patches.single.path, endsWith('/matches/C'));
      expect(patches.single.queryParametersAll['updateMask.fieldPaths'],
          ['status']);
    });

    test('dispose stops the poll loop, is idempotent, and leaves the api open',
        () async {
      var calls = 0;
      final api = await apiFor((req) async {
        if (req.url.path.endsWith(':runQuery')) {
          calls++;
          return http.Response('[]', 200);
        }
        return quiet(req);
      });
      final t = FirestoreTransport(
        api: api,
        code: 'C',
        match: seated,
        pollInterval: const Duration(milliseconds: 5),
      );
      await t.connect();
      await waitFor(() => calls > 0);
      await t.dispose();
      await t.dispose();
      final atDispose = calls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, lessThanOrEqualTo(atDispose + 1),
          reason: 'polling must stop with the transport');
      // The API stack belongs to the app, not to one match: still usable.
      expect(await api.fetchEventsSince('C', -1), isEmpty);
      api.close();
    });
  });
}
