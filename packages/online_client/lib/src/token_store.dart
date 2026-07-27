/// Durable anonymous sessions (Plan 16, review follow-up).
///
/// Anonymous Firebase users are the ONLY identity in the serverless model, and
/// `firebase/firestore.rules` gates every match document on `request.auth.uid`.
/// A uid that does not survive a restart therefore does not just lose a
/// convenience — it strands BOTH seats: the returning player cannot read the
/// match it is a participant of, and the opponent is left waiting on a peer that
/// can never act again.
///
/// The session is kept out of this package on purpose. `online_client` is pure
/// Dart with no storage dependency (the Windows/FlutterFire constraint), so the
/// app layer supplies the persistence and this file only fixes the shape.
library;

/// The part of an authenticated session worth surviving a restart.
///
/// The id token deliberately is NOT stored: it expires within the hour, and the
/// refresh token is what mints a new one. Both are bearer credentials for this
/// anonymous user — an implementation should keep them somewhere no other app
/// can read.
class StoredSession {
  const StoredSession({required this.uid, required this.refreshToken});

  /// The anonymous user id the match documents are gated on.
  final String uid;

  /// Exchanged for a fresh id token at the secure-token endpoint.
  final String refreshToken;

  @override
  bool operator ==(Object other) =>
      other is StoredSession &&
      other.uid == uid &&
      other.refreshToken == refreshToken;

  @override
  int get hashCode => Object.hash(uid, refreshToken);

  @override
  String toString() => 'StoredSession($uid)';
}

/// Where an [AuthClient] remembers its anonymous session between launches.
///
/// Implementations must treat a failed read as "no session" rather than
/// throwing: an unreadable store should cost a new anonymous user, never a
/// launch that cannot sign in at all.
abstract interface class TokenStore {
  /// The stored session, or null when there is none.
  Future<StoredSession?> read();

  /// Persist [session], replacing whatever was there.
  Future<void> write(StoredSession session);

  /// Forget the stored session (a refresh token the server has rejected).
  Future<void> clear();
}

/// The default store: nothing survives the process.
///
/// Keeps [AuthClient] usable with no storage wired up — tests, and the
/// pre-existing behaviour — while making the loss explicit at the call site
/// rather than implicit in the client.
class InMemoryTokenStore implements TokenStore {
  StoredSession? _session;

  @override
  Future<StoredSession?> read() async => _session;

  @override
  Future<void> write(StoredSession session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}
