import 'dart:convert';
import 'dart:math';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_client/online_client.dart';

/// The shared REST fixtures for the offline (no-emulator) suites: one
/// [MockClient] that a test scripts by URL, plus the response bodies Firestore
/// would send back.
///
/// Used by both `match_api_test.dart` (the document operations) and
/// `firestore_transport_test.dart` (the transport over them), so the two suites
/// cannot drift on what a Firestore reply looks like.

/// A MatchApi over one MockClient, pre-signed-in as [uid].
///
/// The handler routes by URL, so a single test can script auth + Firestore.
/// Sign-in is scripted here rather than faked so [MatchApi.uid] is populated
/// exactly the way production populates it.
Future<MatchApi> apiFor(
  Future<http.Response> Function(http.Request req) handler, {
  String uid = 'uid-local',
  Random? codeRandom,
}) async {
  final inner = MockClient((req) async {
    if (req.url.path.contains('accounts:signUp')) {
      return http.Response(
        jsonEncode({
          'idToken': 'idtok',
          'refreshToken': 'refresh',
          'localId': uid,
          'expiresIn': '3600',
        }),
        200,
      );
    }
    return handler(req);
  });
  final config = OnlineConfig.emulator();
  final auth = AuthClient(config, inner: inner);
  final api = MatchApi(
    auth: auth,
    docs: FirestoreDocs(config, token: auth.validToken, inner: inner),
    codeRandom: codeRandom,
  );
  await api.signIn();
  return api;
}

http.Response ok(Object json) => http.Response(jsonEncode(json), 200);

http.Response err(int status, String code, [String message = 'nope']) =>
    http.Response(
      jsonEncode({
        'error': {'status': code, 'message': message},
      }),
      status,
    );

/// A runQuery response body for events with the given (seq, gameNo, event) rows.
String eventRows(
  List<(int seq, GameEvent event)> rows, {
  int gameNo = 1,
  String author = 'uid-local',
}) =>
    jsonEncode([
      for (final (seq, event) in rows)
        {
          'document': {
            'name': 'projects/p/databases/(default)/documents/matches/C/events/'
                '${seq.toString().padLeft(8, '0')}',
            'fields': {
              'seq': {'integerValue': '$seq'},
              'gameNo': {'integerValue': '$gameNo'},
              'author': {'stringValue': author},
              'event': {'stringValue': jsonEncode(event.toJson())},
            },
          },
        },
    ]);

String rollRows(List<Map<String, Object?>> rolls) => jsonEncode([
      for (final r in rolls)
        {
          'document': {
            'name': 'projects/p/databases/(default)/documents/matches/C/rolls/'
                '${(r['n'] as int).toString().padLeft(8, '0')}',
            'fields': {
              for (final e in r.entries)
                e.key: e.value is int
                    ? {'integerValue': '${e.value}'}
                    : {'stringValue': '${e.value}'},
            },
          },
        },
    ]);

/// A `matches/{code}` GET response body.
http.Response matchRow({
  String code = 'C',
  String hostUid = 'uid-local',
  String? guestUid = 'uid-remote',
  int length = 1,
  bool cubeless = false,
  String status = 'active',
}) =>
    ok({
      'name': 'projects/p/databases/(default)/documents/matches/$code',
      'fields': {
        'hostUid': {'stringValue': hostUid},
        if (guestUid == null)
          'guestUid': {'nullValue': null}
        else
          'guestUid': {'stringValue': guestUid},
        'length': {'integerValue': '$length'},
        'cubeless': {'booleanValue': cubeless},
        'status': {'stringValue': status},
      },
    });

/// The collection a `:runQuery` body is asking about (`events` / `rolls`).
String queriedCollection(http.Request req) {
  final sq = (jsonDecode(req.body) as Map)['structuredQuery'] as Map;
  return (sq['from'] as List)[0]['collectionId'] as String;
}

/// The int cursor of a `:runQuery` body's field filter.
int queryCursor(http.Request req) {
  final sq = (jsonDecode(req.body) as Map)['structuredQuery'] as Map;
  final filter = (sq['where'] as Map)['fieldFilter'] as Map;
  return int.parse((filter['value'] as Map)['integerValue'] as String);
}

const hexA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const hexB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const hexC =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
