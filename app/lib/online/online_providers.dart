import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:online_client/online_client.dart';

import '../data/database.dart';
import 'online_session_store.dart';

/// The Web API key for the production Firebase project, injected at build time
/// via `--dart-define=AIGAMMON_FIREBASE_API_KEY=...`. Empty when unset.
const _apiKeyDefine = String.fromEnvironment('AIGAMMON_FIREBASE_API_KEY');

/// The production Firebase project id, injected via
/// `--dart-define=AIGAMMON_FIREBASE_PROJECT=...`. Empty when unset.
const _projectDefine = String.fromEnvironment('AIGAMMON_FIREBASE_PROJECT');

/// The active online-play configuration, or `null` when this build has no online
/// backend wired up (the online UI then shows a "not configured" card).
///
/// Resolution order:
///   1. Both `AIGAMMON_FIREBASE_API_KEY` and `AIGAMMON_FIREBASE_PROJECT`
///      dart-defines present → a production config against those.
///   2. Otherwise, in a debug build → the local emulator suite.
///   3. Otherwise (a release build with no defines) → `null`.
final onlineConfigProvider = Provider<OnlineConfig?>((ref) {
  if (_apiKeyDefine.isNotEmpty && _projectDefine.isNotEmpty) {
    return OnlineConfig.production(
      projectId: _projectDefine,
      apiKey: _apiKeyDefine,
    );
  }
  return kDebugMode ? OnlineConfig.emulator() : null;
});

/// The shared [MatchApi] for the app, built once per session.
///
/// This is the APP-lifetime half of online play: the anonymous session and the
/// HTTP clients. The PER-MATCH half is a [FirestoreTransport] over it, built by
/// `online_screen.dart` when a match is entered and owned by the
/// `NetMatchController` it is handed to — so nothing here is per-match, and
/// nothing here is disposed when a match ends.
///
/// Signs in an anonymous Firebase user, then talks to Firestore documents
/// DIRECTLY — there are no Cloud Functions in the serverless model, so
/// `firebase/firestore.rules` is the only server-side logic. Being a plain
/// (non-autoDispose) [FutureProvider], the resolved [MatchApi] — and its
/// anonymous session — are cached for the app lifetime; the HTTP clients are
/// closed when the [ProviderScope] is torn down.
///
/// Throws an [OnlineException] `not-configured` when [onlineConfigProvider] is
/// `null`; callers surface that as the friendly not-configured state (though the
/// UI gates on the config directly and never reaches this in that case).
final matchApiProvider = FutureProvider<MatchApi>((ref) async {
  final config = ref.watch(onlineConfigProvider);
  if (config == null) {
    throw const OnlineException(
      'not-configured',
      'Online play is not configured in this build.',
    );
  }

  // The token store is what makes the anonymous uid survive a restart. Without
  // it every launch is a new user, and a match in progress becomes unreadable
  // to the player who was in it (see `online_session_store.dart`).
  final api = MatchApi.forConfig(
    config,
    tokenStore: ref.watch(onlineSessionStoreProvider),
  );
  ref.onDispose(api.close);
  await api.signIn();
  return api;
});

/// The durable half of the device's online identity: the anonymous session and
/// the match it was last in.
final onlineSessionStoreProvider = Provider<OnlineSessionStore>(
    (ref) => OnlineSessionStore(ref.watch(databaseProvider)));
