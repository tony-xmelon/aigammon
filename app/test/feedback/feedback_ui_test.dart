import 'dart:async';

import 'package:aigammon_app/analytics/app_analytics.dart';
import 'package:aigammon_app/branding/app_version.dart';
import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/database.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/diagnostics/crash_log.dart';
import 'package:aigammon_app/feedback/feedback_link.dart';
import 'package:aigammon_app/screens/diagnostics_screen.dart';
import 'package:aigammon_app/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/test_database.dart';
import '../helpers/fake_observability.dart';

/// The two feedback affordances, driven through the UI.
///
/// Neither test launches anything: the opener is injected, so what is asserted
/// is the URL that WOULD be opened. That is the whole point of the seam — a
/// widget test has no browser, and `url_launcher`'s platform channel does not
/// answer under the test binding.
void main() {
  late List<Uri> opened;
  late RecordingAnalytics analytics;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    opened = [];
    analytics = RecordingAnalytics();
  });

  // The database is scoped to the Settings group deliberately: the Diagnostics
  // screen has no repository behind it, and standing an sqlite connection up
  // (and tearing it down) for a test that never touches one is pure cost.
  late AppDatabase db;
  late StreamController<AppSettings> feed;

  Widget settingsApp() => ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          settingsProvider.overrideWith((ref) => feed.stream),
          appAnalyticsProvider.overrideWithValue(analytics),
          urlOpenerProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      );

  group('Settings → Send feedback', () {
    setUp(() {
      db = newTestDatabase();
      feed = StreamController<AppSettings>();
    });

    tearDown(() async {
      await feed.close();
      await db.close();
    });

    testWidgets('opens the pre-filled GitHub issue and reports the event',
        (t) async {
      await t.pumpWidget(settingsApp());
      feed.add(AppSettings.defaults);
      await t.pumpAndSettle();

      await t.scrollUntilVisible(find.text('Send feedback'), 200);
      await t.tap(find.text('Send feedback'));
      await t.pump();

      expect(opened, hasLength(1));
      final uri = opened.single;
      expect(uri.host, 'github.com');
      expect(uri.path, '/tony-xmelon/aigammon/issues/new');
      // The live app version, not a literal: the point of the pre-fill is that
      // the report says which build it came from.
      expect(uri.queryParameters['body'], contains('App version: $appVersion'));
      // From Settings there is no crash to attach — this is the "I have an
      // idea" route.
      expect(uri.queryParameters['body'], isNot(contains('Diagnostics')));

      expect(analytics.countOf('feedback_opened'), 1);
    });
  });

  group('Diagnostics → Report an issue', () {
    testWidgets('attaches the error log', (t) async {
      final log = CrashLog()
        ..record(StateError('the dice went sideways'), source: 'flutter');

      await t.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(
          log: log,
          openUrl: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ));

      await t.tap(find.byTooltip('Report an issue on GitHub'));
      await t.pump();

      final body = opened.single.queryParameters['body']!;
      expect(body, contains('### Diagnostics'));
      expect(body, contains('the dice went sideways'));
      expect(body, contains('App version: $appVersion'));
    });

    testWidgets('is reachable with an empty log, and sends no empty block',
        (t) async {
      // "Nothing is logged and the app still misbehaves" is a report worth
      // sending, so this action — unlike Copy and Clear — is never disabled.
      await t.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(
          log: CrashLog(),
          openUrl: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ));

      await t.tap(find.byTooltip('Report an issue on GitHub'));
      await t.pump();

      expect(opened, hasLength(1));
      expect(
          opened.single.queryParameters['body'], isNot(contains('Diagnostics')));
    });
  });
}
