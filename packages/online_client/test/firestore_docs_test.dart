import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

void main() {
  FirestoreDocs docsFor(MockClient inner) => FirestoreDocs(
        OnlineConfig.emulator(),
        token: () async => 'idtok',
        inner: inner,
      );

  const base =
      'http://127.0.0.1:8080/v1/projects/demo-aigammon/databases/(default)/documents';

  group('get', () {
    test('GETs the document URL and decodes fields + updateTime', () async {
      late http.Request captured;
      final docs = docsFor(MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'name':
                'projects/demo-aigammon/databases/(default)/documents/matches/ABCD1234',
            'fields': {
              'hostUid': {'stringValue': 'uidH'},
              'guestUid': {'nullValue': null},
              'length': {'integerValue': '5'},
              'cubeless': {'booleanValue': false},
              'status': {'stringValue': 'waiting'},
            },
            'updateTime': '2026-07-27T10:00:00.000000Z',
          }),
          200,
        );
      }));

      final doc = await docs.get('matches/ABCD1234');

      expect(captured.method, 'GET');
      expect(captured.url.toString(), '$base/matches/ABCD1234');
      expect(captured.headers['authorization'], 'Bearer idtok');
      expect(doc!.id, 'ABCD1234');
      expect(doc.updateTime, '2026-07-27T10:00:00.000000Z');
      expect(doc.fields, {
        'hostUid': 'uidH',
        'guestUid': null,
        'length': 5,
        'cubeless': false,
        'status': 'waiting',
      });
    });

    test('returns null on 404', () async {
      final docs =
          docsFor(MockClient((_) async => http.Response('{"error":{}}', 404)));
      expect(await docs.get('matches/NOPE'), isNull);
    });

    test('a rules refusal throws PermissionDeniedException, not null', () async {
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'status': 'PERMISSION_DENIED', 'message': 'nope'},
            }),
            403,
          )));
      expect(
        () => docs.get('matches/ABCD1234'),
        throwsA(isA<PermissionDeniedException>()
            .having((e) => e.message, 'message', 'nope')),
      );
    });
  });

  group('create', () {
    test('commits an exists:false write with a server-timestamp transform',
        () async {
      late http.Request captured;
      final docs = docsFor(MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'writeResults': []}), 200);
      }));

      await docs.create(
        'matches/ABCD1234',
        {'hostUid': 'uidH', 'guestUid': null, 'length': 5, 'cubeless': true},
        serverTimestamps: ['createdAt'],
      );

      expect(captured.method, 'POST');
      expect(captured.url.toString(), '$base:commit');
      expect(jsonDecode(captured.body), {
        'writes': [
          {
            'update': {
              'name':
                  'projects/demo-aigammon/databases/(default)/documents/matches/ABCD1234',
              'fields': {
                'hostUid': {'stringValue': 'uidH'},
                'guestUid': {'nullValue': null},
                'length': {'integerValue': '5'},
                'cubeless': {'booleanValue': true},
              },
            },
            'currentDocument': {'exists': false},
            'updateTransforms': [
              {'fieldPath': 'createdAt', 'setToServerValue': 'REQUEST_TIME'},
            ],
          },
        ],
      });
    });

    test('omits updateTransforms when no server timestamps are requested',
        () async {
      late http.Request captured;
      final docs = docsFor(MockClient((req) async {
        captured = req;
        return http.Response('{}', 200);
      }));
      await docs.create('matches/A/events/00000003', {'seq': 3});
      final write =
          (jsonDecode(captured.body) as Map)['writes'][0] as Map<String, Object?>;
      expect(write.containsKey('updateTransforms'), isFalse);
      expect(write['currentDocument'], {'exists': false});
    });

    test('maps ALREADY_EXISTS to AlreadyExistsException', () async {
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'status': 'ALREADY_EXISTS', 'message': 'taken'},
            }),
            409,
          )));
      expect(
        () => docs.create('matches/A/events/00000003', {'seq': 3}),
        throwsA(isA<AlreadyExistsException>()),
      );
    });

    test('maps a failed exists:false precondition to AlreadyExistsException',
        () async {
      // The only precondition a create carries is exists:false, so Firestore's
      // FAILED_PRECONDITION on this path means exactly "the id is taken".
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode({
              'error': {
                'status': 'FAILED_PRECONDITION',
                'message': 'document already exists',
              },
            }),
            400,
          )));
      expect(
        () => docs.create('matches/A/events/00000003', {'seq': 3}),
        throwsA(isA<AlreadyExistsException>()
            .having((e) => e.message, 'message', 'document already exists')),
      );
    });

    test('a rules refusal on create stays PERMISSION_DENIED', () async {
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'status': 'PERMISSION_DENIED', 'message': 'denied'},
            }),
            403,
          )));
      expect(
        () => docs.create('matches/A/events/00000003', {'seq': 3}),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  group('patch', () {
    test('sends updateMask paths and an exists precondition by default',
        () async {
      late http.Request captured;
      final docs = docsFor(MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'name':
                'projects/demo-aigammon/databases/(default)/documents/matches/ABCD1234',
            'fields': {
              'status': {'stringValue': 'active'},
            },
            'updateTime': '2026-07-27T10:00:01Z',
          }),
          200,
        );
      }));

      final doc = await docs.patch(
        'matches/ABCD1234',
        {'guestUid': 'uidG', 'status': 'active'},
        updateMask: const ['guestUid', 'status'],
      );

      expect(captured.method, 'PATCH');
      expect(captured.url.queryParametersAll['updateMask.fieldPaths'],
          ['guestUid', 'status']);
      expect(captured.url.queryParameters['currentDocument.exists'], 'true');
      expect(jsonDecode(captured.body), {
        'fields': {
          'guestUid': {'stringValue': 'uidG'},
          'status': {'stringValue': 'active'},
        },
      });
      expect(doc.updateTime, '2026-07-27T10:00:01Z');
    });

    test('maps FAILED_PRECONDITION to FailedPreconditionException', () async {
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'status': 'FAILED_PRECONDITION', 'message': 'gone'},
            }),
            400,
          )));
      expect(
        () => docs.patch('matches/A', {'status': 'active'},
            updateMask: const ['status']),
        throwsA(isA<FailedPreconditionException>()),
      );
    });

    test('a rules refusal on patch surfaces as PermissionDeniedException',
        () async {
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'status': 'PERMISSION_DENIED', 'message': 'seat taken'},
            }),
            403,
          )));
      expect(
        () => docs.patch('matches/A', {'status': 'active'},
            updateMask: const ['status']),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  group('query', () {
    test('POSTs a structuredQuery with filter, order and limit', () async {
      late http.Request captured;
      final docs = docsFor(MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode([
            {
              'document': {
                'name':
                    'projects/demo-aigammon/databases/(default)/documents/matches/A/events/00000001',
                'fields': {
                  'seq': {'integerValue': '1'},
                },
              },
            },
            // A read-time-only row (no document) must be skipped.
            {'readTime': '2026-07-27T00:00:00Z'},
          ]),
          200,
        );
      }));

      final rows = await docs.query(
        'matches/A',
        'events',
        whereInt: ('seq', FieldOp.greaterThan, 0),
        orderBy: 'seq',
        limit: 25,
      );

      expect(captured.url.toString(), '$base/matches/A:runQuery');
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
          'limit': 25,
        },
      });
      expect(rows, hasLength(1));
      expect(rows.single.id, '00000001');
      expect(rows.single.fields, {'seq': 1});
    });

    test('uses GREATER_THAN_OR_EQUAL when asked', () async {
      late http.Request captured;
      final docs = docsFor(MockClient((req) async {
        captured = req;
        return http.Response('[]', 200);
      }));
      await docs.query('matches/A', 'rolls',
          whereInt: ('n', FieldOp.greaterThanOrEqual, 4));
      final sq =
          (jsonDecode(captured.body) as Map)['structuredQuery'] as Map;
      expect(((sq['where'] as Map)['fieldFilter'] as Map)['op'],
          'GREATER_THAN_OR_EQUAL');
    });

    test('surfaces a streamed error row as a typed exception', () async {
      // runQuery is a streaming method: its failures arrive as a one-element
      // ARRAY wrapping the usual error object — sometimes under a 200, since
      // the stream had already begun.
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode([
              {
                'error': {'status': 'PERMISSION_DENIED', 'message': 'no list'},
              },
            ]),
            200,
          )));
      expect(
        () => docs.query('matches/A', 'events'),
        throwsA(isA<PermissionDeniedException>()
            .having((e) => e.message, 'message', 'no list')),
      );
    });

    test('surfaces a non-2xx query failure as a typed exception', () async {
      final docs = docsFor(MockClient((_) async => http.Response(
            jsonEncode([
              {
                'error': {'status': 'PERMISSION_DENIED', 'message': 'no list'},
              },
            ]),
            403,
          )));
      expect(
        () => docs.query('matches/A', 'events'),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });
}
