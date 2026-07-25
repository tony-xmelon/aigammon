import 'dart:async';

import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MaterialApp _materialApp(WidgetTester t) =>
    t.widget<MaterialApp>(find.byType(MaterialApp));

void main() {
  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  testWidgets('MaterialApp.themeMode follows settings and reacts to changes',
      (t) async {
    // Drive settingsProvider from a controller (rather than the real drift
    // watch) so the widget test stays off drift's watch-timer, matching the
    // repository-vs-widget split used elsewhere in the suite.
    final controller = StreamController<AppSettings>();
    addTearDown(controller.close);

    await t.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => controller.stream),
      ],
      child: const AiGammonApp(),
    ));

    // Before the first emission the app falls back to the system theme.
    await t.pump();
    expect(_materialApp(t).themeMode, ThemeMode.system);

    controller.add(AppSettings.defaults.copyWith(themeMode: ThemeMode.light));
    await t.pumpAndSettle();
    expect(_materialApp(t).themeMode, ThemeMode.light);

    controller.add(AppSettings.defaults.copyWith(themeMode: ThemeMode.dark));
    await t.pumpAndSettle();
    expect(_materialApp(t).themeMode, ThemeMode.dark,
        reason: 'the live app re-themes when the settings stream re-emits');
  });
}
