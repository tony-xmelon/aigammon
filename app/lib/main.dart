import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_settings.dart';
import 'data/settings_repository.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: AiGammonApp()));
}

class AiGammonApp extends ConsumerWidget {
  const AiGammonApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Follow the persisted theme preference; fall back to system while the
    // (sub-frame) initial load resolves.
    final themeMode =
        ref.watch(settingsProvider).valueOrNull?.themeMode ??
            AppSettings.defaults.themeMode;
    return MaterialApp(
      title: 'AIGammon',
      theme: ThemeData(colorSchemeSeed: Colors.brown, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.brown,
          brightness: Brightness.dark,
          useMaterial3: true),
      themeMode: themeMode,
      home: const HomeScreen(),
    );
  }
}
