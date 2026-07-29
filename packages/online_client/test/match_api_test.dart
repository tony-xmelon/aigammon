import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

import 'mock_api.dart';

void main() {
  group('logDocId', () {
    test('zero-pads to eight digits', () {
      expect(logDocId(0), '00000000');
      expect(logDocId(7), '00000007');
      expect(logDocId(42), '00000042');
      expect(logDocId(99999999), '99999999');
    });

    test('padded ids sort lexicographically in numeric order', () {
      final ids = [logDocId(2), logDocId(10), logDocId(1)]..sort();
      expect(ids, [logDocId(1), logDocId(2), logDocId(10)]);
    });

    test('rejects negatives and overflow', () {
      expect(() => logDocId(-1), throwsArgumentError);
      expect(() => logDocId(100000000), throwsArgumentError);
    });
  });

  group('generateInviteCode', () {
    test('is eight characters from the confusable-free alphabet', () {
      for (var i = 0; i < 200; i++) {
        final code = generateInviteCode();
        expect(code, hasLength(kCodeLength));
        expect(code, matches(RegExp('^[$kCodeAlphabet]{$kCodeLength}\$')));
        expect(code, isNot(anyOf(contains('I'), contains('O'), contains('0'),
            contains('1'))));
      }
    });
  });

  group('createMatch', () {
    test('commits the match doc with a createdAt transform', () async {
      late http.Request captured;
      final api = await apiFor((req) async {
        captured = req;
        return ok({'writeResults': []});
      }, codeRandom: Random(7));

      final match = await api.createMatch(length: 5, cubeless: true);

      final write =
          (jsonDecode(captured.body) as Map)['writes'][0] as Map<String, Object?>;
      expect(write['currentDocument'], {'exists': false});
      expect(write['updateTransforms'], [
        {'fieldPath': 'createdAt', 'setToServerValue': 'REQUEST_TIME'},
      ]);
      final update = write['update'] as Map<String, Object?>;
      expect(update['name'], endsWith('/matches/${match.code}'));
      expect(update['fields'], {
        'hostUid': {'stringValue': 'uid-local'},
        'guestUid': {'nullValue': null},
        'length': {'integerValue': '5'},
        'cubeless': {'booleanValue': true},
        'status': {'stringValue': 'waiting'},
      });
      expect(match.hostUid, 'uid-local');
      expect(match.guestUid, isNull);
      expect(match.status, 'waiting');
      expect(match.sideOf('uid-local'), Player.white);
    });

    test('retries with a fresh code when the id is taken', () async {
      final codes = <String>[];
      var call = 0;
      final api = await apiFor((req) async {
        final name = (jsonDecode(req.body) as Map)['writes'][0]['update']['name']
            as String;
        codes.add(name.split('/').last);
        return call++ == 0 ? err(409, 'ALREADY_EXISTS') : ok({});
      });

      final match = await api.createMatch(length: 3, cubeless: false);

      expect(codes, hasLength(2));
      expect(codes[0], isNot(codes[1]), reason: 'a fresh code per attempt');
      expect(match.code, codes[1]);
    });

    test('gives up after the attempt budget', () async {
      final api = await apiFor((_) async => err(409, 'ALREADY_EXISTS'));
      await expectLater(
        api.createMatch(length: 3, cubeless: false, attempts: 3),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'code-collision')),
      );
    });
  });

  group('joinMatch', () {
    Future<http.Response> waitingDoc(http.Request req) async => ok({
          'name': 'projects/p/databases/(default)/documents/matches/ABCD1234',
          'fields': {
            'hostUid': {'stringValue': 'uid-host'},
            'guestUid': {'nullValue': null},
            'length': {'integerValue': '5'},
            'cubeless': {'booleanValue': false},
            'status': {'stringValue': 'waiting'},
            'createdAt': {'timestampValue': '2026-07-27T10:00:00Z'},
          },
          'updateTime': '2026-07-27T10:00:00.500000Z',
        });

    test('patches guestUid+status only, on an existing document', () async {
      late http.Request patchReq;
      final api = await apiFor((req) async {
        if (req.method == 'GET') return waitingDoc(req);
        patchReq = req;
        return ok({'fields': {}});
      });

      final joined = await api.joinMatch('ABCD1234');

      expect(patchReq.method, 'PATCH');
      expect(patchReq.url.queryParametersAll['updateMask.fieldPaths'],
          ['guestUid', 'status']);
      expect(patchReq.url.queryParameters['currentDocument.exists'], 'true');
      expect(jsonDecode(patchReq.body), {
        'fields': {
          'guestUid': {'stringValue': 'uid-local'},
          'status': {'stringValue': 'active'},
        },
      });
      expect(joined.guestUid, 'uid-local');
      expect(joined.status, 'active');
      expect(joined.sideOf('uid-local'), Player.black);
      expect(joined.sideOf('uid-host'), Player.white);
      expect(joined.createdAt, DateTime.utc(2026, 7, 27, 10));
    });

    test('an unknown code is NotFound and never attempts a write', () async {
      var writes = 0;
      final api = await apiFor((req) async {
        if (req.method == 'GET') return http.Response('{}', 404);
        writes++;
        return ok({});
      });
      await expectLater(
        api.joinMatch('NOSUCHCD'),
        throwsA(isA<NotFoundException>()),
      );
      expect(writes, 0);
    });

    test('joining your own match fails the precondition locally', () async {
      final api = await apiFor(waitingDoc, uid: 'uid-host');
      await expectLater(
        api.joinMatch('ABCD1234'),
        throwsA(isA<FailedPreconditionException>()
            .having((e) => e.message, 'message', contains('your own match'))),
      );
    });

    test('an already-seated match fails the precondition locally', () async {
      final api = await apiFor((req) async => ok({
            'fields': {
              'hostUid': {'stringValue': 'uid-host'},
              'guestUid': {'stringValue': 'uid-other'},
              'length': {'integerValue': '5'},
              'cubeless': {'booleanValue': false},
              'status': {'stringValue': 'active'},
            },
          }));
      await expectLater(
        api.joinMatch('ABCD1234'),
        throwsA(isA<FailedPreconditionException>()),
      );
    });

    test('a rules refusal after a clean read reads as a lost race', () async {
      // The seat WAS open when we looked, so the only way the rules can refuse
      // the transition now is that someone else took it in between.
      final api = await apiFor((req) async {
        if (req.method == 'GET') return waitingDoc(req);
        return err(403, 'PERMISSION_DENIED');
      });
      await expectLater(
        api.joinMatch('ABCD1234'),
        throwsA(isA<FailedPreconditionException>()
            .having((e) => e.message, 'message', contains('last seat'))),
      );
    });
  });

  group('submitEvent', () {
    test('writes the event as a JSON string at the seq-named doc id', () async {
      late http.Request captured;
      final api = await apiFor((req) async {
        captured = req;
        return ok({});
      });
      final event = MoveEvent(
        Player.white,
        Move([const CheckerMove(23, 18), const CheckerMove(18, 12)]),
      );

      await api.submitEvent(
          code: 'ABCD1234', seq: 42, gameNo: 2, event: event);

      final write =
          (jsonDecode(captured.body) as Map)['writes'][0] as Map<String, Object?>;
      final update = write['update'] as Map<String, Object?>;
      expect(update['name'], endsWith('/matches/ABCD1234/events/00000042'));
      final fields = update['fields'] as Map<String, Object?>;
      expect(fields['seq'], {'integerValue': '42'});
      expect(fields['gameNo'], {'integerValue': '2'});
      expect(fields['author'], {'stringValue': 'uid-local'});
      // The payload is one stringValue — nested arrays live inside the JSON
      // text, so the old list-of-maps hop workaround is unnecessary.
      final payload = (fields['event'] as Map)['stringValue'] as String;
      expect(jsonDecode(payload), event.toJson());
      expect(GameEvent.fromJson(Map<String, dynamic>.from(jsonDecode(payload))),
          event);
    });

    test('a seq collision surfaces as AlreadyExistsException', () async {
      final api = await apiFor((_) async => err(409, 'ALREADY_EXISTS'));
      await expectLater(
        api.submitEvent(
            code: 'C', seq: 3, gameNo: 1, event: DoubleEvent(Player.white)),
        throwsA(isA<AlreadyExistsException>()),
      );
    });

    test('a rules refusal surfaces as PermissionDeniedException', () async {
      final api = await apiFor((_) async => err(403, 'PERMISSION_DENIED'));
      await expectLater(
        api.submitEvent(
            code: 'C', seq: 3, gameNo: 1, event: DoubleEvent(Player.white)),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  group('fetchEventsSince', () {
    test('decodes RemoteEvents and filters on seq', () async {
      late http.Request captured;
      final api = await apiFor((req) async {
        captured = req;
        return http.Response(
          eventRows([
            (3, const OpeningRollEvent(whiteDie: 5, blackDie: 2)),
            (4, RollEvent(Player.white, 4, 1)),
          ]),
          200,
        );
      });

      final events = await api.fetchEventsSince('ABCD1234', 2);

      expect(captured.url.toString(), endsWith('/matches/ABCD1234:runQuery'));
      final sq =
          (jsonDecode(captured.body) as Map)['structuredQuery'] as Map;
      expect((sq['where'] as Map)['fieldFilter'], {
        'field': {'fieldPath': 'seq'},
        'op': 'GREATER_THAN',
        'value': {'integerValue': '2'},
      });
      expect(events.map((e) => e.seq), [3, 4]);
      expect(events[0].event, const OpeningRollEvent(whiteDie: 5, blackDie: 2));
      expect(events[0].gameNo, 1);
      expect(events[0].author, 'uid-local');
      expect(events[1].event, RollEvent(Player.white, 4, 1));
    });

    test('follows pages until a short page arrives', () async {
      final cursors = <int>[];
      final api = await apiFor((req) async {
        final sq =
            (jsonDecode(req.body) as Map)['structuredQuery'] as Map;
        final cursor = int.parse(((sq['where'] as Map)['fieldFilter']
            as Map)['value']['integerValue'] as String);
        cursors.add(cursor);
        // pageSize 2: full pages at 0 and 2, then a short page.
        if (cursor == -1) {
          return http.Response(
              eventRows([(0, DoubleEvent(Player.white)), (1, TakeEvent(Player.black))]),
              200);
        }
        if (cursor == 1) {
          return http.Response(
              eventRows([(2, DoubleEvent(Player.white)), (3, TakeEvent(Player.black))]),
              200);
        }
        return http.Response(eventRows([(4, DoubleEvent(Player.white))]), 200);
      });

      final events = await api.fetchEventsSince('C', -1, pageSize: 2);

      expect(events.map((e) => e.seq), [0, 1, 2, 3, 4]);
      expect(cursors, [-1, 1, 3], reason: 'each page resumes after its last seq');
    });

    test('an empty first page ends the walk', () async {
      var calls = 0;
      final api = await apiFor((_) async {
        calls++;
        return http.Response('[]', 200);
      });
      expect(await api.fetchEventsSince('C', 7), isEmpty);
      expect(calls, 1);
    });
  });

  group('roll documents', () {
    test('createRoll commits {n, roller, commit} at the padded id', () async {
      late http.Request captured;
      final api = await apiFor((req) async {
        captured = req;
        return ok({});
      });
      await api.createRoll(code: 'ABCD1234', n: 5, commit: hexA);
      final update = (jsonDecode(captured.body) as Map)['writes'][0]['update']
          as Map<String, Object?>;
      expect(update['name'], endsWith('/matches/ABCD1234/rolls/00000005'));
      expect(update['fields'], {
        'n': {'integerValue': '5'},
        'roller': {'stringValue': 'uid-local'},
        'commit': {'stringValue': hexA},
      });
    });

    test('submitEntropy patches only entropy', () async {
      late http.Request captured;
      final api = await apiFor((req) async {
        captured = req;
        return ok({'fields': {}});
      });
      await api.submitEntropy(code: 'C', n: 1, entropy: hexB);
      expect(captured.url.path, endsWith('/matches/C/rolls/00000001'));
      expect(captured.url.queryParametersAll['updateMask.fieldPaths'],
          ['entropy']);
      expect(jsonDecode(captured.body), {
        'fields': {
          'entropy': {'stringValue': hexB},
        },
      });
    });

    test('submitReveal patches only reveal', () async {
      late http.Request captured;
      final api = await apiFor((req) async {
        captured = req;
        return ok({'fields': {}});
      });
      await api.submitReveal(code: 'C', n: 1, reveal: hexC);
      expect(captured.url.queryParametersAll['updateMask.fieldPaths'],
          ['reveal']);
      expect(jsonDecode(captured.body), {
        'fields': {
          'reveal': {'stringValue': hexC},
        },
      });
    });

    test('a phase-skip refusal surfaces as PermissionDeniedException',
        () async {
      final api = await apiFor((_) async => err(403, 'PERMISSION_DENIED'));
      await expectLater(
        api.submitReveal(code: 'C', n: 0, reveal: hexC),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('fetchRoll decodes each phase, and null for an absent roll', () async {
      final api = await apiFor((req) async {
        if (req.url.path.endsWith('00000009')) {
          return http.Response('{}', 404);
        }
        return ok({
          'fields': {
            'n': {'integerValue': '2'},
            'roller': {'stringValue': 'uid-host'},
            'commit': {'stringValue': hexA},
            'entropy': {'stringValue': hexB},
          },
        });
      });

      expect(await api.fetchRoll('C', 9), isNull);
      final roll = (await api.fetchRoll('C', 2))!;
      expect(roll.n, 2);
      expect(roll.roller, 'uid-host');
      expect(roll.phase, FairDicePhase.entropy);
      expect(roll.isComplete, isFalse);
      expect(roll.completed, isNull);
    });

    test('a complete roll exposes a verifiable CompletedRoll', () async {
      const secret = hexA;
      final commit = commitFor(secret);
      final api = await apiFor((_) async => ok({
            'fields': {
              'n': {'integerValue': '0'},
              'roller': {'stringValue': 'uid-host'},
              'commit': {'stringValue': commit},
              'entropy': {'stringValue': hexB},
              'reveal': {'stringValue': secret},
            },
          }));
      final roll = (await api.fetchRoll('C', 0))!;
      expect(roll.phase, FairDicePhase.revealed);
      final completed = roll.completed!;
      completed.verifyCommit(); // must not throw
      expect(completed.dice, diceFrom(secret, hexB));
    });

    test('fetchRollsFrom queries n >= from and paginates', () async {
      final cursors = <int>[];
      final api = await apiFor((req) async {
        final sq = (jsonDecode(req.body) as Map)['structuredQuery'] as Map;
        final filter = (sq['where'] as Map)['fieldFilter'] as Map;
        expect(filter['op'], 'GREATER_THAN_OR_EQUAL');
        final cursor = int.parse(filter['value']['integerValue'] as String);
        cursors.add(cursor);
        if (cursor == 0) {
          return http.Response(
            rollRows([
              {'n': 0, 'roller': 'u', 'commit': hexA},
              {'n': 1, 'roller': 'u', 'commit': hexA},
            ]),
            200,
          );
        }
        return http.Response(
          rollRows([
            {'n': 2, 'roller': 'u', 'commit': hexA},
          ]),
          200,
        );
      });

      final rolls = await api.fetchRollsFrom('C', 0, pageSize: 2);
      expect(rolls.map((r) => r.n), [0, 1, 2]);
      expect(cursors, [0, 2]);
    });
  });

  group('MatchDoc', () {
    test('seats host white and guest black', () {
      const match = MatchDoc(
        code: 'ABCD1234',
        hostUid: 'h',
        guestUid: 'g',
        length: 5,
        cubeless: false,
        status: 'active',
      );
      expect(match.sideOf('h'), Player.white);
      expect(match.sideOf('g'), Player.black);
      expect(match.sideOf('x'), isNull);
      expect(match.isParticipant('g'), isTrue);
      expect(match.isParticipant('x'), isFalse);
      expect(match.isActive, isTrue);
    });

    test('rejects a malformed field map', () {
      expect(
        () => MatchDoc.fromFields('C', {'hostUid': 'h'}),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'malformed-match')),
      );
    });
  });

  group('RemoteEvent', () {
    test('round-trips every event kind through the JSON string field', () {
      final events = <GameEvent>[
        const OpeningRollEvent(whiteDie: 6, blackDie: 3),
        RollEvent(Player.black, 2, 2),
        MoveEvent(Player.white,
            Move([const CheckerMove(13, 7), const CheckerMove(8, 7)])),
        MoveEvent(Player.black, Move.none),
        DoubleEvent(Player.white),
        TakeEvent(Player.black),
        DropEvent(Player.black),
        ResignOfferEvent(Player.white, ResignValue.gammon),
        ResignAcceptEvent(Player.black),
        ResignDeclineEvent(Player.black),
      ];
      for (var i = 0; i < events.length; i++) {
        final decoded = RemoteEvent.fromFields({
          'seq': i,
          'gameNo': 1,
          'author': 'uid-x',
          'event': jsonEncode(events[i].toJson()),
        });
        expect(decoded.event, events[i], reason: 'event $i');
        expect(decoded.seq, i);
      }
    });

    test('rejects a map payload and bad seq/gameNo', () {
      expect(
        () => RemoteEvent.fromFields(
            {'seq': 0, 'gameNo': 1, 'event': <String, Object?>{}}),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'malformed-event')),
      );
      expect(
        () => RemoteEvent.fromFields({'seq': '0', 'gameNo': 1, 'event': '{}'}),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'malformed-event')),
      );
    });
  });

  group('uid', () {
    test('throws before sign-in', () {
      final config = OnlineConfig.emulator();
      final auth = AuthClient(config,
          inner: MockClient((_) async => http.Response('{}', 200)));
      final api = MatchApi(
        auth: auth,
        docs: FirestoreDocs(config, token: auth.validToken),
      );
      expect(() => api.uid, throwsStateError);
    });

    test('signIn is idempotent', () async {
      var signUps = 0;
      final inner = MockClient((req) async {
        signUps++;
        return http.Response(
          jsonEncode({
            'idToken': 't',
            'refreshToken': 'r',
            'localId': 'uid-1',
            'expiresIn': '3600',
          }),
          200,
        );
      });
      final config = OnlineConfig.emulator();
      final auth = AuthClient(config, inner: inner);
      final api = MatchApi(
        auth: auth,
        docs: FirestoreDocs(config, token: auth.validToken, inner: inner),
      );
      expect(await api.signIn(), 'uid-1');
      expect(await api.signIn(), 'uid-1');
      expect(signUps, 1);
    });
  });
}
