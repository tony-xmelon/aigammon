import 'package:aigammon_app/data/app_settings.dart';
import 'package:aigammon_app/data/settings_repository.dart';
import 'package:aigammon_app/screens/new_match_screen.dart';
import 'package:engine_bindings/engine_bindings.dart' show Difficulty;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a NewMatchScreen with [settingsProvider] pinned to [settings]. The
/// container is warmed (the stream's first emission awaited) BEFORE the widget
/// builds, so the screen's synchronous initState read sees the cached value
/// rather than the loading state.
Future<void> _pump(
  WidgetTester t,
  AppSettings settings, {
  required bool vsComputer,
}) async {
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((ref) => Stream.value(settings)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future); // force the first emission
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: NewMatchScreen(vsComputer: vsComputer)),
    ),
  );
  await t.pumpAndSettle();
}

bool _segSelected<T>(WidgetTester t, T value) {
  final seg = t.widget<SegmentedButton<T>>(find.byType(SegmentedButton<T>));
  return seg.selected.contains(value);
}

bool _tutorSwitch(WidgetTester t) => t
    .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Tutor mode'))
    .value;

void main() {
  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  testWidgets('vs-computer selectors initialise from settings defaults',
      (t) async {
    const settings = AppSettings(
      themeMode: ThemeMode.system,
      animationSpeed: AnimationSpeed.normal,
      defaultMatchLength: 7,
      defaultDifficulty: Difficulty.hard,
      tutorOverride: null,
    );
    await _pump(t, settings, vsComputer: true);

    expect(_segSelected<int>(t, 7), isTrue, reason: 'match length from settings');
    expect(_segSelected<Difficulty>(t, Difficulty.hard), isTrue,
        reason: 'difficulty from settings');
    // Tutor override is null -> per-mode default (hard vs-computer = OFF).
    expect(_tutorSwitch(t), isFalse);

    // No selector shows a checkmark (it would squeeze the labels onto two lines).
    final segs = find.byWidgetPredicate((w) => w is SegmentedButton);
    expect(segs, findsWidgets);
    for (final w in t.widgetList(segs)) {
      expect((w as SegmentedButton).showSelectedIcon, isFalse);
    }
  });

  testWidgets('tutor override ON forces the tutor toggle on, even at expert',
      (t) async {
    const settings = AppSettings(
      themeMode: ThemeMode.system,
      animationSpeed: AnimationSpeed.normal,
      defaultMatchLength: 5,
      defaultDifficulty: Difficulty.expert,
      tutorOverride: true,
    );
    await _pump(t, settings, vsComputer: true);

    // Expert's per-mode default is OFF, but the override forces ON.
    expect(_segSelected<Difficulty>(t, Difficulty.expert), isTrue);
    expect(_tutorSwitch(t), isTrue);
  });

  testWidgets('the "Play without cube" toggle is offered and toggles (both '
      'local modes)', (t) async {
    // A tall surface so the toggle (below the selectors) is on screen.
    await t.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    const settings = AppSettings(
      themeMode: ThemeMode.system,
      animationSpeed: AnimationSpeed.normal,
      defaultMatchLength: 5,
      defaultDifficulty: Difficulty.medium,
      tutorOverride: null,
    );
    for (final vsComputer in [true, false]) {
      // Force a fresh screen State each iteration (an unkeyed NewMatchScreen of
      // the same type is otherwise reused across pumpWidget, carrying its
      // toggle state over).
      await t.pumpWidget(const SizedBox());
      await _pump(t, settings, vsComputer: vsComputer);
      final tile = find.widgetWithText(SwitchListTile, 'Play without cube');
      expect(tile, findsOneWidget, reason: 'offered for vsComputer=$vsComputer');
      // Off by default; tapping turns it on.
      expect(t.widget<SwitchListTile>(tile).value, isFalse);
      await t.ensureVisible(tile);
      await t.tap(tile);
      await t.pumpAndSettle();
      expect(t.widget<SwitchListTile>(tile).value, isTrue);
    }
  });

  testWidgets('tutor override OFF is not re-derived when difficulty changes',
      (t) async {
    const settings = AppSettings(
      themeMode: ThemeMode.system,
      animationSpeed: AnimationSpeed.normal,
      defaultMatchLength: 5,
      defaultDifficulty: Difficulty.easy,
      tutorOverride: false,
    );
    await _pump(t, settings, vsComputer: true);

    // Easy's per-mode default is ON, but the override pins it OFF.
    expect(_tutorSwitch(t), isFalse);

    // Switching to medium (also ON by per-mode default) must NOT flip it on.
    await t.tap(find.text('Medium'));
    await t.pumpAndSettle();
    expect(_tutorSwitch(t), isFalse,
        reason: 'a settings override suppresses per-mode auto-tracking');
  });
}
