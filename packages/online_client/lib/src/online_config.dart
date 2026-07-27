/// Connection settings for the online-play REST clients.
///
/// Two shapes are supported, selected by [isEmulator]:
///   * emulator — [emulatorHost] set; requests hit the local Firebase Emulator
///     Suite on the configured ports, no API key needed;
///   * production — [emulatorHost] null; requests hit the public Google
///     endpoints and [apiKey] (the project's Web API key) is required for auth.
///
/// Only TWO backends are addressed: Firestore (the whole game model lives in
/// documents) and Identity Toolkit / secure-token (anonymous auth). There are no
/// Cloud Functions in the serverless model — see Plan 16.
class OnlineConfig {
  /// The Firebase project id (e.g. `demo-aigammon` locally, `aigammon` in prod).
  final String projectId;

  /// The project's Web API key. Required for production Identity Toolkit calls;
  /// ignored (any value accepted) by the emulator.
  final String? apiKey;

  /// Host of the local emulator suite (e.g. `127.0.0.1`). Null → production.
  final String? emulatorHost;

  /// Emulator port for the Firestore REST API.
  final int firestorePort;

  /// Emulator port for the Auth (Identity Toolkit) REST API.
  final int authPort;

  const OnlineConfig({
    required this.projectId,
    this.apiKey,
    this.emulatorHost,
    this.firestorePort = 8080,
    this.authPort = 9099,
  });

  /// Whether requests target the local emulator suite.
  bool get isEmulator => emulatorHost != null;

  /// Local emulator defaults: `demo-aigammon` on `127.0.0.1` with the standard
  /// Firebase ports (Firestore 8080, Auth 9099).
  factory OnlineConfig.emulator({
    String projectId = 'demo-aigammon',
    String host = '127.0.0.1',
    int firestorePort = 8080,
    int authPort = 9099,
  }) =>
      OnlineConfig(
        projectId: projectId,
        emulatorHost: host,
        firestorePort: firestorePort,
        authPort: authPort,
      );

  /// Production configuration against the public Google endpoints.
  factory OnlineConfig.production({
    required String projectId,
    required String apiKey,
  }) =>
      OnlineConfig(projectId: projectId, apiKey: apiKey);

  /// Firestore's RESOURCE name prefix for the default database's document root
  /// — the host-less `projects/…/documents` path that a document's `name` field
  /// must carry inside a `:commit` write body.
  String get documentsResourcePrefix =>
      'projects/$projectId/databases/(default)/documents';

  /// Base URL for the Firestore REST v1 `documents` root (no trailing slash).
  /// Append `/<path>` for a document, or `:commit` / `:runQuery` for the
  /// corresponding RPCs.
  String get firestoreDocumentsBase {
    final root = isEmulator
        ? 'http://$emulatorHost:$firestorePort/v1'
        : 'https://firestore.googleapis.com/v1';
    return '$root/$documentsResourcePrefix';
  }

  /// Base URL for the Identity Toolkit REST v1 accounts endpoints.
  String get identityToolkitBase => isEmulator
      ? 'http://$emulatorHost:$authPort/identitytoolkit.googleapis.com/v1'
      : 'https://identitytoolkit.googleapis.com/v1';

  /// Base URL for the secure-token (refresh) endpoint.
  String get secureTokenBase => isEmulator
      ? 'http://$emulatorHost:$authPort/securetoken.googleapis.com/v1'
      : 'https://securetoken.googleapis.com/v1';

  /// API key to place in auth query strings. The emulator accepts any value.
  String get effectiveApiKey => isEmulator ? 'any' : (apiKey ?? '');
}
