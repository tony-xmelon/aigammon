import 'dart:convert';

import 'package:http/http.dart' as http;

import 'online_config.dart';
import 'online_exception.dart';

/// An active anonymous authentication session.
class AuthSession {
  final String uid;
  final String idToken;
  final String refreshToken;

  /// When [idToken] expires (UTC).
  final DateTime expiresAt;

  const AuthSession({
    required this.uid,
    required this.idToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  AuthSession _withToken({
    required String idToken,
    required String refreshToken,
    required DateTime expiresAt,
  }) =>
      AuthSession(
        uid: uid,
        idToken: idToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
      );
}

/// Firebase anonymous auth over the Identity Toolkit REST API.
///
/// Refreshes proactively: [validToken] exchanges the refresh token whenever
/// fewer than [refreshWindow] remain before expiry. The [now] clock is
/// injectable for deterministic tests.
class AuthClient {
  final OnlineConfig config;
  final http.Client _http;
  final DateTime Function() _now;

  /// Refresh when less than this remains before the token expires.
  static const Duration refreshWindow = Duration(minutes: 5);

  AuthSession? _session;

  AuthClient(
    this.config, {
    http.Client? inner,
    DateTime Function()? now,
  })  : _http = inner ?? http.Client(),
        _now = now ?? (() => DateTime.now().toUtc());

  /// The current session, or null before [signInAnonymously].
  AuthSession? get session => _session;

  /// Sign up a fresh anonymous user, returning (and caching) the session.
  Future<AuthSession> signInAnonymously() async {
    final url = Uri.parse(
      '${config.identityToolkitBase}/accounts:signUp?key=${config.effectiveApiKey}',
    );
    final res = await _http.post(
      url,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'returnSecureToken': true}),
    );
    final body = _decodeOrThrow(res);
    final expiresIn = int.parse(body['expiresIn'] as String);
    _session = AuthSession(
      uid: body['localId'] as String,
      idToken: body['idToken'] as String,
      refreshToken: body['refreshToken'] as String,
      expiresAt: _now().add(Duration(seconds: expiresIn)),
    );
    return _session!;
  }

  /// Return a valid id token, refreshing first if it is within [refreshWindow]
  /// of expiry. Throws [StateError] if not signed in.
  Future<String> validToken() async {
    final session = _session;
    if (session == null) {
      throw StateError('not signed in — call signInAnonymously() first');
    }
    if (_now().add(refreshWindow).isBefore(session.expiresAt)) {
      return session.idToken;
    }
    return _refresh(session);
  }

  Future<String> _refresh(AuthSession session) async {
    final url = Uri.parse(
      '${config.secureTokenBase}/token?key=${config.effectiveApiKey}',
    );
    final res = await _http.post(
      url,
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': session.refreshToken,
      },
    );
    final body = _decodeOrThrow(res);
    final expiresIn = int.parse(body['expires_in'] as String);
    _session = session._withToken(
      idToken: body['id_token'] as String,
      refreshToken: body['refresh_token'] as String,
      expiresAt: _now().add(Duration(seconds: expiresIn)),
    );
    return _session!.idToken;
  }

  Map<String, Object?> _decodeOrThrow(http.Response res) {
    Map<String, Object?> body;
    try {
      body = jsonDecode(res.body) as Map<String, Object?>;
    } catch (_) {
      throw OnlineException('http-${res.statusCode}', res.body);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final err = body['error'];
      final message = err is Map ? (err['message']?.toString() ?? res.body) : res.body;
      throw OnlineException('http-${res.statusCode}', message);
    }
    return body;
  }

  /// Close the underlying HTTP client.
  void close() => _http.close();
}
