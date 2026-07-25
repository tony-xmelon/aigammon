import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_client/online_client.dart';
import 'package:test/test.dart';

void main() {
  group('signInAnonymously', () {
    test('hits the emulator identitytoolkit URL with returnSecureToken', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'idToken': 'tok-1',
            'refreshToken': 'refresh-1',
            'localId': 'uid-1',
            'expiresIn': '3600',
          }),
          200,
        );
      });
      var clock = DateTime.utc(2026, 1, 1, 0, 0, 0);
      final auth = AuthClient(OnlineConfig.emulator(),
          inner: client, now: () => clock);

      final session = await auth.signInAnonymously();

      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=any');
      expect(jsonDecode(captured.body), {'returnSecureToken': true});
      expect(session.uid, 'uid-1');
      expect(session.idToken, 'tok-1');
      expect(session.refreshToken, 'refresh-1');
      expect(session.expiresAt, clock.add(const Duration(seconds: 3600)));
    });

    test('production URL carries the real API key', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({
            'idToken': 't',
            'refreshToken': 'r',
            'localId': 'u',
            'expiresIn': '3600',
          }),
          200,
        );
      });
      final auth = AuthClient(
        OnlineConfig.production(projectId: 'aigammon', apiKey: 'KEY123'),
        inner: client,
      );
      await auth.signInAnonymously();
      expect(captured.url.toString(),
          'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=KEY123');
    });

    test('maps a non-2xx auth error to OnlineException', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'error': {'message': 'CONFIGURATION_NOT_FOUND'},
            }),
            400,
          ));
      final auth = AuthClient(OnlineConfig.emulator(), inner: client);
      expect(
        () => auth.signInAnonymously(),
        throwsA(isA<OnlineException>()
            .having((e) => e.message, 'message', 'CONFIGURATION_NOT_FOUND')),
      );
    });
  });

  group('validToken', () {
    test('throws before sign-in', () {
      final auth = AuthClient(OnlineConfig.emulator(),
          inner: MockClient((_) async => http.Response('{}', 200)));
      expect(auth.validToken, throwsStateError);
    });

    test('returns the cached token when it is still fresh', () async {
      var clock = DateTime.utc(2026, 1, 1, 0, 0, 0);
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          jsonEncode({
            'idToken': 'fresh-tok',
            'refreshToken': 'r',
            'localId': 'u',
            'expiresIn': '3600',
          }),
          200,
        );
      });
      final auth =
          AuthClient(OnlineConfig.emulator(), inner: client, now: () => clock);
      await auth.signInAnonymously();

      // 10 minutes later — still >5min of headroom, no refresh.
      clock = clock.add(const Duration(minutes: 10));
      expect(await auth.validToken(), 'fresh-tok');
      expect(calls, 1, reason: 'no refresh call expected');
    });

    test('refreshes when fewer than 5 minutes remain', () async {
      var clock = DateTime.utc(2026, 1, 1, 0, 0, 0);
      http.Request? refreshReq;
      final client = MockClient((req) async {
        if (req.url.path.contains('accounts:signUp')) {
          return http.Response(
            jsonEncode({
              'idToken': 'old-tok',
              'refreshToken': 'refresh-A',
              'localId': 'u',
              'expiresIn': '3600',
            }),
            200,
          );
        }
        // securetoken refresh
        refreshReq = req;
        return http.Response(
          jsonEncode({
            'id_token': 'new-tok',
            'refresh_token': 'refresh-B',
            'expires_in': '3600',
            'user_id': 'u',
          }),
          200,
        );
      });
      final auth =
          AuthClient(OnlineConfig.emulator(), inner: client, now: () => clock);
      await auth.signInAnonymously();

      // 59 minutes later: only 1 minute of headroom → must refresh.
      clock = clock.add(const Duration(minutes: 59));
      final token = await auth.validToken();

      expect(token, 'new-tok');
      expect(refreshReq, isNotNull);
      expect(refreshReq!.url.toString(),
          'http://127.0.0.1:9099/securetoken.googleapis.com/v1/token?key=any');
      expect(refreshReq!.bodyFields, {
        'grant_type': 'refresh_token',
        'refresh_token': 'refresh-A',
      });
      // The new refresh token and expiry are cached.
      expect(auth.session!.refreshToken, 'refresh-B');
      expect(auth.session!.expiresAt, clock.add(const Duration(seconds: 3600)));
    });
  });
}
