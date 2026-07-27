import 'dart:convert';

import 'package:http/http.dart' as http;

import 'online_config.dart';
import 'online_exception.dart';
import 'token_store.dart';

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

}

/// Firebase anonymous auth over the Identity Toolkit REST API.
///
/// Refreshes proactively: [validToken] exchanges the refresh token whenever
/// fewer than [refreshWindow] remain before expiry. The [now] clock is
/// injectable for deterministic tests.
///
/// ## The uid must outlive the process
///
/// The anonymous uid is the only identity the model has, and the security rules
/// gate every match document on it, so minting a fresh one on each launch
/// strands both seats of any match in progress. [store] is where the session is
/// kept between launches; [signInAnonymously] restores from it when it can and
/// only signs up a NEW user when it cannot. The default [InMemoryTokenStore]
/// keeps the old (process-lifetime) behaviour for callers with no storage.
class AuthClient {
  final OnlineConfig config;
  final http.Client _http;
  final DateTime Function() _now;

  /// Where the session is remembered between launches.
  final TokenStore store;

  /// Refresh when less than this remains before the token expires.
  static const Duration refreshWindow = Duration(minutes: 5);

  AuthSession? _session;

  AuthClient(
    this.config, {
    http.Client? inner,
    DateTime Function()? now,
    TokenStore? store,
  })  : _http = inner ?? http.Client(),
        _now = now ?? (() => DateTime.now().toUtc()),
        store = store ?? InMemoryTokenStore();

  /// The current session, or null before [signInAnonymously].
  AuthSession? get session => _session;

  /// Sign in as the anonymous user, REUSING the stored one when possible.
  ///
  /// Order matters: a stored refresh token is exchanged first, so a relaunch
  /// keeps the uid (and therefore access to any match in progress). Only when
  /// there is nothing stored, or the server refuses what was stored, is a brand
  /// new anonymous user signed up — which does orphan whatever the old uid was
  /// a participant of, so it is the last resort rather than the first move.
  Future<AuthSession> signInAnonymously() async {
    final restored = await _restore();
    if (restored != null) return restored;
    return _signUp();
  }

  /// Exchange a stored refresh token for a live session, or null when there is
  /// nothing usable to restore.
  Future<AuthSession?> _restore() async {
    StoredSession? stored;
    try {
      stored = await store.read();
    } catch (_) {
      // An unreadable store costs a new anonymous user, never a failed launch.
      return null;
    }
    if (stored == null) return null;
    try {
      await _refresh(AuthSession(
        uid: stored.uid,
        idToken: '',
        refreshToken: stored.refreshToken,
        // Any past instant: this session exists only to carry the token into
        // the exchange below.
        expiresAt: DateTime.utc(1970),
      ));
      return _session;
    } on OnlineException {
      // The refresh token is dead (revoked, or the project was reset). Drop it
      // so the next launch does not pay for the same rejection again.
      await _clearStore();
      _session = null;
      return null;
    }
  }

  /// Sign up a fresh anonymous user, returning (and caching) the session.
  Future<AuthSession> _signUp() async {
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
    await _remember();
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
    // The secure-token endpoint echoes the user id; trust it over the one we
    // carried in, so a restored session cannot end up mislabelled.
    final uid = body['user_id'] as String? ?? session.uid;
    _session = AuthSession(
      uid: uid,
      idToken: body['id_token'] as String,
      refreshToken: body['refresh_token'] as String,
      expiresAt: _now().add(Duration(seconds: expiresIn)),
    );
    await _remember();
    return _session!.idToken;
  }

  /// Persist the live session. A store that cannot be written is not fatal —
  /// this launch still works, only the NEXT one loses the uid.
  Future<void> _remember() async {
    final s = _session;
    if (s == null) return;
    try {
      await store.write(
          StoredSession(uid: s.uid, refreshToken: s.refreshToken));
    } catch (_) {
      // Best effort by design; see above.
    }
  }

  Future<void> _clearStore() async {
    try {
      await store.clear();
    } catch (_) {
      // Best effort by design.
    }
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
