/// The user-visible app version, shown in the home screen footer.
///
/// Deliberately a plain const rather than a `package_info_plus` lookup: the
/// version is wanted on the FIRST frame of the first screen, on every platform
/// including the widget tests and the screenshot tour, and a platform-channel
/// round trip buys nothing here. `app_version_test.dart` fails the suite if it
/// ever drifts from `pubspec.yaml`, so it cannot go stale silently.
const String appVersion = '0.10.0';
