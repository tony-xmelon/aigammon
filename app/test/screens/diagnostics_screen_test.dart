import 'package:aigammon_app/diagnostics/crash_log.dart';
import 'package:aigammon_app/screens/diagnostics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, CrashLog log) => tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(log: log)));

  testWidgets('an empty log says so and disables the actions', (tester) async {
    await pump(tester, CrashLog());
    expect(find.textContaining('No errors recorded'), findsOneWidget);

    final copy = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.copy_all));
    expect(copy.onPressed, isNull,
        reason: 'copying an empty log would paste nothing useful');
  });

  testWidgets('errors are listed newest first, with the stack', (tester) async {
    final log = CrashLog()
      ..record('older failure')
      ..record('newest failure', stack: StackTrace.fromString('#0 aFrame'));

    await pump(tester, log);

    expect(find.text('newest failure'), findsOneWidget);
    expect(find.text('older failure'), findsOneWidget);
    expect(find.textContaining('aFrame'), findsOneWidget);

    // Newest first: the newest entry sits above the older one on screen.
    final newest = tester.getTopLeft(find.text('newest failure')).dy;
    final older = tester.getTopLeft(find.text('older failure')).dy;
    expect(newest, lessThan(older));
  });

  testWidgets('copy puts the shareable report on the clipboard',
      (tester) async {
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final log = CrashLog()..record(StateError('copy me'), source: 'flutter');
    await pump(tester, log);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.copy_all));
    await tester.pumpAndSettle();

    expect(clipboard, hasLength(1));
    final text = (clipboard.single.arguments as Map)['text'] as String;
    expect(text, contains('copy me'));
    expect(text, contains('flutter'));
    expect(find.text('Diagnostics copied to clipboard'), findsOneWidget);
  });

  testWidgets('clear empties the log and the list', (tester) async {
    final log = CrashLog()..record('goes away');
    await pump(tester, log);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(log.entries, isEmpty);
    expect(find.text('goes away'), findsNothing);
    expect(find.textContaining('No errors recorded'), findsOneWidget);
  });
}
