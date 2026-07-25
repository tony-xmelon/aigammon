import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:online_client/online_client.dart';

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
/// Signs in an anonymous Firebase user, then wires the Firestore and Functions
/// REST clients to that session's token. Being a plain (non-autoDispose)
/// [FutureProvider], the resolved [MatchApi] — and its anonymous session — are
/// cached for the app lifetime; the clients are closed when the [ProviderScope]
/// is torn down.
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

  final auth = AuthClient(config);
  await auth.signInAnonymously();

  Future<String> token() => auth.validToken();
  final firestore = FirestoreRestClient(config, token: token);
  final functions = FunctionsClient(config, token: token);

  ref.onDispose(auth.close);
  ref.onDispose(firestore.close);
  ref.onDispose(functions.close);

  return MatchApi(auth, firestore, functions);
});
