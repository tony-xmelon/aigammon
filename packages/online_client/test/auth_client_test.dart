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

  group('durable sessions (TokenStore)', () {
    /// A signUp response body for [uid].
    String signUpBody(String uid) => jsonEncode({
          'idToken': 'tok-$uid',
          'refreshToken': 'refresh-$uid',
          'localId': uid,
          'expiresIn': '3600',
        });

    /// A secure-token refresh response.
    String refreshBody(String uid, {String suffix = '2'}) => jsonEncode({
          'id_token': 'tok-$uid-$suffix',
          'refresh_token': 'refresh-$uid-$suffix',
          'user_id': uid,
          'expires_in': '3600',
        });

    test('a restart REUSES the stored uid instead of minting a new one',
        () async {
      // The uid is the only identity the security rules know, so a new one on
      // every launch locks the returning player out of their own match and
      // leaves the opponent waiting on a peer that can never move again.
      final store = InMemoryTokenStore();
      final calls = <String>[];

      http.Client clientFor(String signUpUid) => MockClient((req) async {
            final isRefresh = req.url.path.contains('token');
            calls.add(isRefresh ? 'refresh' : 'signUp');
            return http.Response(
                isRefresh ? refreshBody('uid-1') : signUpBody(signUpUid), 200);
          });

      // First launch: nothing stored, so a fresh anonymous user is signed up.
      final first = AuthClient(OnlineConfig.emulator(),
          inner: clientFor('uid-1'), store: store);
      final a = await first.signInAnonymously();
      expect(a.uid, 'uid-1');
      expect(calls, ['signUp']);
      expect(await store.read(),
          const StoredSession(uid: 'uid-1', refreshToken: 'refresh-uid-1'));

      // Second launch, same device: the stored refresh token is exchanged and
      // the SAME uid comes back — no signUp at all.
      final second = AuthClient(OnlineConfig.emulator(),
          inner: clientFor('uid-SHOULD-NOT-BE-USED'), store: store);
      final b = await second.signInAnonymously();
      expect(b.uid, 'uid-1', reason: 'the seat survives the restart');
      expect(b.idToken, 'tok-uid-1-2', reason: 'a freshly minted id token');
      expect(calls, ['signUp', 'refresh'],
          reason: 'a restore must never sign up');
      // The rotated refresh token replaced the stored one.
      expect((await store.read())!.refreshToken, 'refresh-uid-1-2');
    });

    test('a rejected refresh token falls back to a new user and is dropped',
        () async {
      final store = InMemoryTokenStore();
      await store
          .write(const StoredSession(uid: 'gone', refreshToken: 'revoked'));
      final calls = <String>[];
      final client = MockClient((req) async {
        final isRefresh = req.url.path.contains('token');
        calls.add(isRefresh ? 'refresh' : 'signUp');
        if (isRefresh) {
          return http.Response(
              jsonEncode({
                'error': {'message': 'TOKEN_EXPIRED'}
              }),
              400);
        }
        return http.Response(signUpBody('uid-new'), 200);
      });

      final auth = AuthClient(OnlineConfig.emulator(),
          inner: client, store: store);
      final session = await auth.signInAnonymously();

      // Tried the stored token first, then fell back rather than throwing.
      expect(calls, ['refresh', 'signUp']);
      expect(session.uid, 'uid-new');
      // The dead token is gone, so the next launch does not pay for it again.
      expect((await store.read())!.uid, 'uid-new');
    });

    test('an unreadable store costs a new user, never a failed launch',
        () async {
      final client = MockClient((req) async =>
          http.Response(signUpBody('uid-fresh'), 200));
      final auth = AuthClient(OnlineConfig.emulator(),
          inner: client, store: _BrokenStore());

      final session = await auth.signInAnonymously();
      expect(session.uid, 'uid-fresh');
    });

    test('with no store the session still works, it just does not persist',
        () async {
      final client = MockClient((req) async =>
          http.Response(signUpBody('uid-x'), 200));
      final auth = AuthClient(OnlineConfig.emulator(), inner: client);
      expect((await auth.signInAnonymously()).uid, 'uid-x');
    });
  });
}

/// Every operation throws — the store equivalent of a corrupt database file.
class _BrokenStore implements TokenStore {
  @override
  Future<StoredSession?> read() async => throw StateError('unreadable');

  @override
  Future<void> write(StoredSession session) async =>
      throw StateError('unwritable');

  @override
  Future<void> clear() async => throw StateError('unclearable');
}
