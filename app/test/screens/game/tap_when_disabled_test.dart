import 'package:aigammon_app/screens/game/tap_when_disabled.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness({required VoidCallback? onPressed, required VoidCallback onDisabledTap}) =>
      MaterialApp(
        home: Scaffold(
          body: TapWhenDisabled(
            onDisabledTap: onDisabledTap,
            child: OutlinedButton(onPressed: onPressed, child: const Text('Go')),
          ),
        ),
      );

  testWidgets('a tap on a DISABLED child reaches onDisabledTap', (t) async {
    var disabledTaps = 0;
    await t.pumpWidget(
      harness(onPressed: null, onDisabledTap: () => disabledTaps++),
    );
    await t.tap(find.text('Go'));
    await t.pump();
    expect(disabledTaps, 1);
  });

  testWidgets('a tap on an ENABLED child fires its own onPressed, not '
      'onDisabledTap', (t) async {
    var presses = 0;
    var disabledTaps = 0;
    await t.pumpWidget(
      harness(onPressed: () => presses++, onDisabledTap: () => disabledTaps++),
    );
    await t.tap(find.text('Go'));
    await t.pump();
    expect(presses, 1);
    expect(disabledTaps, 0);
  });
}
