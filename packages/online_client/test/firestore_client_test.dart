import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

void main() {
  FirestoreRestClient clientFor(MockClient inner) => FirestoreRestClient(
        OnlineConfig.emulator(),
        token: () async => 'idtok',
        inner: inner,
      );

  group('getDocument', () {
    test('GETs the right URL and decodes fields', () async {
      late http.Request captured;
      final fs = clientFor(MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'name': 'projects/demo-aigammon/databases/(default)/documents/matches/m1',
            'fields': {
              'code': {'stringValue': 'ABC123'},
              'seq': {'integerValue': '4'},
              'status': {'stringValue': 'active'},
              'seats': {
                'mapValue': {
                  'fields': {
                    'white': {'stringValue': 'uidW'},
                    'black': {'stringValue': 'uidB'},
                  },
                },
              },
            },
          }),
          200,
        );
      }));

      final fields = await fs.getDocument('matches/m1');

      expect(captured.method, 'GET');
      expect(captured.url.toString(),
          'http://127.0.0.1:8080/v1/projects/demo-aigammon/databases/(default)/documents/matches/m1');
      expect(captured.headers['authorization'], 'Bearer idtok');
      expect(fields, {
        'code': 'ABC123',
        'seq': 4,
        'status': 'active',
        'seats': {'white': 'uidW', 'black': 'uidB'},
      });
    });

    test('returns null on 404', () async {
      final fs = clientFor(
          MockClient((req) async => http.Response('{"error":{}}', 404)));
      expect(await fs.getDocument('matches/missing'), isNull);
    });

    test('maps other errors to OnlineException with the REST status', () async {
      final fs = clientFor(MockClient((req) async => http.Response(
            jsonEncode({
              'error': {'message': 'nope', 'status': 'PERMISSION_DENIED'},
            }),
            403,
          )));
      expect(
        () => fs.getDocument('matches/m1'),
        throwsA(isA<OnlineException>()
            .having((e) => e.code, 'code', 'PERMISSION_DENIED')),
      );
    });
  });

  group('runQuery', () {
    test('POSTs a structuredQuery with the filter + orderBy shape', () async {
      late http.Request captured;
      final fs = clientFor(MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode([
            {
              'document': {
                'fields': {
                  'type': {'stringValue': 'roll'},
                  'seq': {'integerValue': '1'},
                  'gameNo': {'integerValue': '1'},
                },
              },
            },
            // A read-time-only row (no document) must be skipped.
            {'readTime': '2026-07-25T00:00:00Z'},
          ]),
          200,
        );
      }));

      final rows = await fs.runQuery(
        'matches/m1',
        'events',
        whereIntGreaterThan: ('seq', 0),
        orderByField: 'seq',
      );

      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'http://127.0.0.1:8080/v1/projects/demo-aigammon/databases/(default)/documents/matches/m1:runQuery');
      expect(jsonDecode(captured.body), {
        'structuredQuery': {
          'from': [
            {'collectionId': 'events'},
          ],
          'where': {
            'fieldFilter': {
              'field': {'fieldPath': 'seq'},
              'op': 'GREATER_THAN',
              'value': {'integerValue': '0'},
            },
          },
          'orderBy': [
            {
              'field': {'fieldPath': 'seq'},
              'direction': 'ASCENDING',
            },
          ],
        },
      });
      expect(rows, [
        {'type': 'roll', 'seq': 1, 'gameNo': 1},
      ]);
    });

    test('omits where/orderBy when not requested', () async {
      late http.Request captured;
      final fs = clientFor(MockClient((req) async {
        captured = req;
        return http.Response('[]', 200);
      }));
      await fs.runQuery('matches/m1', 'events');
      expect(jsonDecode(captured.body), {
        'structuredQuery': {
          'from': [
            {'collectionId': 'events'},
          ],
        },
      });
    });
  });
}
