import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

void main() {
  FunctionsClient clientFor(MockClient inner) => FunctionsClient(
        OnlineConfig.emulator(),
        token: () async => 'idtok',
        inner: inner,
      );

  test('wraps payload in {data:...} and unwraps {result:...}', () async {
    late http.Request captured;
    final fc = clientFor(MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({
          'result': {'matchId': 'm1', 'code': 'ABC123'},
        }),
        200,
      );
    }));

    final result = await fc.call('createMatch', {'matchLength': 3});

    expect(captured.method, 'POST');
    expect(captured.url.toString(),
        'http://127.0.0.1:5001/demo-aigammon/us-central1/createMatch');
    expect(captured.headers['authorization'], 'Bearer idtok');
    expect(captured.headers['content-type'], contains('application/json'));
    expect(jsonDecode(captured.body), {
      'data': {'matchLength': 3},
    });
    expect(result, {'matchId': 'm1', 'code': 'ABC123'});
  });

  test('maps an {error:...} envelope to OnlineException with status code',
      () async {
    final fc = clientFor(MockClient((req) async => http.Response(
          jsonEncode({
            'error': {'message': 'not your turn', 'status': 'permission-denied'},
          }),
          200,
        )));
    expect(
      () => fc.call('rollDice', {'matchId': 'm1'}),
      throwsA(isA<OnlineException>()
          .having((e) => e.code, 'code', 'permission-denied')
          .having((e) => e.message, 'message', 'not your turn')),
    );
  });

  test('maps a bare 500 with no JSON body to OnlineException', () async {
    final fc = clientFor(
        MockClient((req) async => http.Response('internal error', 500)));
    expect(
      () => fc.call('rollDice', {'matchId': 'm1'}),
      throwsA(isA<OnlineException>().having((e) => e.code, 'code', 'http-500')),
    );
  });

  test('maps a 500 carrying an error envelope to its status', () async {
    final fc = clientFor(MockClient((req) async => http.Response(
          jsonEncode({
            'error': {'message': 'boom', 'status': 'internal'},
          }),
          500,
        )));
    expect(
      () => fc.call('submitEvent', {'matchId': 'm1'}),
      throwsA(isA<OnlineException>().having((e) => e.code, 'code', 'internal')),
    );
  });
}
