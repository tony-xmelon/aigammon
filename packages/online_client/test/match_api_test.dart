import 'dart:convert';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

/// Build a MatchApi whose three REST clients all share one MockClient handler.
/// The handler routes by URL, so a single test can script functions + firestore.
MatchApi apiFor(Future<http.Response> Function(http.Request req) handler) {
  final inner = MockClient(handler);
  final config = OnlineConfig.emulator();
  final auth = AuthClient(config, inner: inner);
  final firestore =
      FirestoreRestClient(config, token: () async => 'idtok', inner: inner);
  final functions =
      FunctionsClient(config, token: () async => 'idtok', inner: inner);
  return MatchApi(auth, firestore, functions);
}

http.Response ok(Object json) => http.Response(jsonEncode(json), 200);

void main() {
  group('callable verbs', () {
    test('createMatch posts matchLength and returns id+code', () async {
      late http.Request captured;
      final api = apiFor((req) async {
        captured = req;
        return ok({
          'result': {'matchId': 'm1', 'code': 'ABC123'},
        });
      });
      final res = await api.createMatch(5);
      expect(captured.url.path, endsWith('/createMatch'));
      expect(jsonDecode(captured.body), {
        'data': {'matchLength': 5},
      });
      expect(res.matchId, 'm1');
      expect(res.code, 'ABC123');
    });

    test('joinMatch posts code and returns matchId', () async {
      late http.Request captured;
      final api = apiFor((req) async {
        captured = req;
        return ok({
          'result': {'matchId': 'm2'},
        });
      });
      final id = await api.joinMatch('abc123');
      expect(captured.url.path, endsWith('/joinMatch'));
      expect(jsonDecode(captured.body), {
        'data': {'code': 'abc123'},
      });
      expect(id, 'm2');
    });

    test('rollDice posts matchId and decodes a Dice', () async {
      late http.Request captured;
      final api = apiFor((req) async {
        captured = req;
        return ok({
          'result': {'die1': 3, 'die2': 5},
        });
      });
      final dice = await api.rollDice('m1');
      expect(captured.url.path, endsWith('/rollDice'));
      expect(jsonDecode(captured.body), {
        'data': {'matchId': 'm1'},
      });
      expect(dice, Dice(3, 5));
    });

    test('submitEvent serialises the event and returns seq', () async {
      late http.Request captured;
      final api = apiFor((req) async {
        captured = req;
        return ok({
          'result': {'seq': 7},
        });
      });
      final event = MoveEvent(
        Player.white,
        Move([const CheckerMove(23, 18), const CheckerMove(18, 12)]),
      );
      final seq = await api.submitEvent('m1', event);
      expect(captured.url.path, endsWith('/submitEvent'));
      expect(jsonDecode(captured.body), {
        'data': {'matchId': 'm1', 'event': event.toJson()},
      });
      expect(seq, 7);
    });

    test('submitEvent includes a result claim when given', () async {
      late http.Request captured;
      final api = apiFor((req) async {
        captured = req;
        return ok({
          'result': {'seq': 9},
        });
      });
      final event = DropEvent(Player.black);
      await api.submitEvent(
        'm1',
        event,
        result: const GameResultClaim(
          winner: Player.white,
          points: 2,
          outcome: GameOutcome.drop,
        ),
      );
      expect(jsonDecode(captured.body), {
        'data': {
          'matchId': 'm1',
          'event': event.toJson(),
          'result': {'winner': 'white', 'points': 2, 'outcome': 'drop'},
        },
      });
    });

    test('surfaces a callable error as OnlineException', () async {
      final api = apiFor((req) async => ok({
            'error': {'message': 'not your turn', 'status': 'permission-denied'},
          }));
      expect(
        () => api.rollDice('m1'),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'permission-denied')),
      );
    });
  });

  group('fetchMatch', () {
    test('decodes the match summary fields', () async {
      final api = apiFor((req) async => ok({
            'fields': {
              'status': {'stringValue': 'active'},
              'code': {'stringValue': 'ABC123'},
              'matchLength': {'integerValue': '5'},
              'gameNo': {'integerValue': '2'},
              'seq': {'integerValue': '12'},
              'seats': {
                'mapValue': {
                  'fields': {
                    'white': {'stringValue': 'uidW'},
                    'black': {'stringValue': 'uidB'},
                  },
                },
              },
              'scores': {
                'mapValue': {
                  'fields': {
                    'white': {'integerValue': '3'},
                    'black': {'integerValue': '1'},
                  },
                },
              },
              'turn': {'stringValue': 'black'},
              'phase': {'stringValue': 'moving'},
              'isCrawford': {'booleanValue': true},
              'crawfordPlayed': {'booleanValue': false},
            },
          }));
      final snap = await api.fetchMatch('m1');
      expect(snap.status, 'active');
      expect(snap.code, 'ABC123');
      expect(snap.matchLength, 5);
      expect(snap.gameNo, 2);
      expect(snap.seq, 12);
      expect(snap.whiteUid, 'uidW');
      expect(snap.blackUid, 'uidB');
      expect(snap.whiteScore, 3);
      expect(snap.blackScore, 1);
      expect(snap.turn, Player.black);
      expect(snap.phase, GamePhase.moving);
      expect(snap.isCrawford, isTrue);
      expect(snap.crawfordPlayed, isFalse);
      expect(snap.winner, isNull);
    });

    test('handles a waiting match with no black seat / null turn', () async {
      final api = apiFor((req) async => ok({
            'fields': {
              'status': {'stringValue': 'waiting'},
              'code': {'stringValue': 'ABC123'},
              'matchLength': {'integerValue': '3'},
              'gameNo': {'integerValue': '0'},
              'seq': {'integerValue': '-1'},
              'seats': {
                'mapValue': {
                  'fields': {
                    'white': {'stringValue': 'uidW'},
                  },
                },
              },
              'scores': {
                'mapValue': {
                  'fields': {
                    'white': {'integerValue': '0'},
                    'black': {'integerValue': '0'},
                  },
                },
              },
              'turn': {'nullValue': null},
              'phase': {'nullValue': null},
            },
          }));
      final snap = await api.fetchMatch('m1');
      expect(snap.blackUid, isNull);
      expect(snap.turn, isNull);
      expect(snap.phase, isNull);
      expect(snap.isCrawford, isFalse);
    });

    test('throws not-found when the doc is missing', () async {
      final api = apiFor((req) async => http.Response('{}', 404));
      expect(
        () => api.fetchMatch('missing'),
        throwsA(isA<OnlineException>().having((e) => e.code, 'code', 'not-found')),
      );
    });
  });

  group('fetchEventsSince', () {
    test('runs a seq>afterSeq query and decodes RemoteEvents', () async {
      late http.Request captured;
      final api = apiFor((req) async {
        captured = req;
        return ok([
          {
            'document': {
              'fields': {
                'type': {'stringValue': 'openingRoll'},
                'whiteDie': {'integerValue': '5'},
                'blackDie': {'integerValue': '2'},
                'gameNo': {'integerValue': '1'},
                'seq': {'integerValue': '3'},
              },
            },
          },
          {
            'document': {
              'fields': {
                'type': {'stringValue': 'roll'},
                'player': {'stringValue': 'white'},
                'die1': {'integerValue': '4'},
                'die2': {'integerValue': '1'},
                'gameNo': {'integerValue': '1'},
                'seq': {'integerValue': '4'},
              },
            },
          },
        ]);
      });

      final events = await api.fetchEventsSince('m1', 2);

      expect(captured.url.toString(), endsWith('/matches/m1:runQuery'));
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      final sq = body['structuredQuery'] as Map<String, Object?>;
      expect((sq['where'] as Map)['fieldFilter'], {
        'field': {'fieldPath': 'seq'},
        'op': 'GREATER_THAN',
        'value': {'integerValue': '2'},
      });
      expect(events.length, 2);
      expect(events[0].seq, 3);
      expect(events[0].gameNo, 1);
      expect(events[0].event,
          const OpeningRollEvent(whiteDie: 5, blackDie: 2));
      expect(events[1].seq, 4);
      expect(events[1].event, RollEvent(Player.white, 4, 1));
    });
  });

  group('pollEvents', () {
    // A canned runQuery response body for events with seq in [seqs].
    String eventsBody(List<int> seqs) => jsonEncode([
          for (final s in seqs)
            {
              'document': {
                'fields': {
                  'type': {'stringValue': 'roll'},
                  'player': {'stringValue': 'white'},
                  'die1': {'integerValue': '2'},
                  'die2': {'integerValue': '3'},
                  'gameNo': {'integerValue': '1'},
                  'seq': {'integerValue': '$s'},
                },
              },
            },
        ]);

    test('emits monotonically increasing seq, dedupes, stops on cancel',
        () async {
      // Scripted sequence of runQuery responses: the same seq 0 appears twice
      // (must dedupe), then a new seq 1 arrives, then repeats forever.
      final scripted = <String>[
        eventsBody([0]), // emit 0
        eventsBody([0]), // duplicate — ignored
        eventsBody([0, 1]), // 0 ignored, 1 emitted
      ];
      var call = 0;
      final api = apiFor((req) async {
        final body =
            call < scripted.length ? scripted[call] : eventsBody([0, 1]);
        call++;
        return http.Response(body, 200);
      });

      final seen = <int>[];
      final sub = api
          .pollEvents('m1', interval: const Duration(milliseconds: 1))
          .listen((e) => seen.add(e.seq));

      // Wait until both events have arrived.
      while (seen.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await sub.cancel();
      final countAtCancel = call;

      // Give the loop time to prove it stopped after cancel.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(seen, [0, 1]);
      expect(call, lessThanOrEqualTo(countAtCancel + 1),
          reason: 'polling must stop after cancel');
    });
  });
}
