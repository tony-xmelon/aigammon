import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: AiGammonApp()));
}

class AiGammonApp extends StatelessWidget {
  const AiGammonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIGammon',
      theme: ThemeData(colorSchemeSeed: Colors.brown, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.brown,
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const Scaffold(body: Center(child: Text('AIGammon'))),
    );
  }
}
