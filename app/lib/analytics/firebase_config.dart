import 'package:flutter/foundation.dart';

/// Whether this build may talk to FlutterFire at all.
///
/// **Android and iOS only, deliberately.** This app is developed and tested on
/// Windows; FlutterFire's desktop support is partial and unofficial, and
/// Crashlytics and Performance Monitoring have no desktop implementation at
/// all. Rather than discover that per-plugin at runtime, the app decides ONCE,
/// here, and hands every caller a no-op implementation everywhere else. Nothing
/// outside `lib/analytics/` is allowed to ask the question.
///
/// Uses [defaultTargetPlatform] rather than `dart:io`'s `Platform`: it is
/// available on every target (including web, where `dart:io` is not) and it is
/// overridable in tests via `debugDefaultTargetPlatformOverride`, which is what
/// lets `test/analytics/desktop_guard_test.dart` prove Windows never reaches
/// Firebase.
bool get isFirebaseSupportedPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// The Firebase project's numeric "Project number", also known as the Cloud
/// Messaging **sender ID**. Injected via
/// `--dart-define=AIGAMMON_FIREBASE_SENDER_ID=...`.
const String _senderIdDefine =
    String.fromEnvironment('AIGAMMON_FIREBASE_SENDER_ID');

/// The Android app's Firebase App ID (`1:<sender>:android:<hash>`), injected via
/// `--dart-define=AIGAMMON_FIREBASE_ANDROID_APP_ID=...`.
const String _androidAppIdDefine =
    String.fromEnvironment('AIGAMMON_FIREBASE_ANDROID_APP_ID');

/// The iOS app's Firebase App ID (`1:<sender>:ios:<hash>`), injected via
/// `--dart-define=AIGAMMON_FIREBASE_IOS_APP_ID=...`.
const String _iosAppIdDefine =
    String.fromEnvironment('AIGAMMON_FIREBASE_IOS_APP_ID');

/// The shared project id / Web API key, REUSED from online play's existing
/// defines rather than duplicated — one Firebase project backs both.
const String _projectDefine =
    String.fromEnvironment('AIGAMMON_FIREBASE_PROJECT');
const String _apiKeyDefine =
    String.fromEnvironment('AIGAMMON_FIREBASE_API_KEY');

/// Everything `Firebase.initializeApp` needs, as plain data.
///
/// **Why data and not `FirebaseOptions` directly.** This type is pure Dart with
/// no FlutterFire import, so the resolution rules below are unit-testable on
/// Windows with no plugins registered. `firebase_observability.dart` is the
/// only place that turns it into a `FirebaseOptions`.
///
/// **Why dart-defines and not `google-services.json`.** The project has shipped
/// without platform config files since online play landed (Plan 5): every
/// Firebase value arrives as a build-time define sourced from a GitHub repo
/// Variable or secret. Keeping that discipline means a fork or a local build
/// simply has no Firebase, rather than silently inheriting someone else's
/// project from a checked-in file.
@immutable
class FirebaseAppConfig {
  const FirebaseAppConfig({
    required this.projectId,
    required this.apiKey,
    required this.appId,
    required this.messagingSenderId,
  });

  final String projectId;
  final String apiKey;

  /// The PLATFORM-specific app id. There is no cross-platform value: Android
  /// and iOS are separate Firebase apps inside the one project.
  final String appId;

  final String messagingSenderId;

  /// Resolves the config for [platform] from the compiled-in dart-defines, or
  /// `null` when this build was not given a complete set.
  ///
  /// Incomplete is the NORMAL case for a local build and for any fork: it is
  /// not an error and must not be reported as one — it simply means this binary
  /// has no telemetry. All four values are required together; a partial set is
  /// treated as absent rather than passed to `initializeApp`, which would fail
  /// at runtime with a far less obvious message.
  static FirebaseAppConfig? fromEnvironment({
    TargetPlatform? platform,
  }) {
    final target = platform ?? defaultTargetPlatform;
    final appId = switch (target) {
      TargetPlatform.android => _androidAppIdDefine,
      TargetPlatform.iOS => _iosAppIdDefine,
      // Every other platform is guarded out before this is ever called; being
      // explicit here means a future desktop port fails closed, not open.
      _ => '',
    };
    if (_projectDefine.isEmpty ||
        _apiKeyDefine.isEmpty ||
        _senderIdDefine.isEmpty ||
        appId.isEmpty) {
      return null;
    }
    return FirebaseAppConfig(
      projectId: _projectDefine,
      apiKey: _apiKeyDefine,
      appId: appId,
      messagingSenderId: _senderIdDefine,
    );
  }
}
