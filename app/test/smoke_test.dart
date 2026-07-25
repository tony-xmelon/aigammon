import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots', (tester) async {
    // The app now reads its theme from settingsProvider on boot. Serve it from
    // a plain stream (rather than the real drift-backed store) so this widget
    // test needs no database and stays off drift's watch-timer.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(AppSettings.defaults)),
      ],
      child: const AiGammonApp(),
    ));
    expect(find.text('AIGammon'), findsOneWidget);
  });
}
