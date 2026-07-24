import 'package:flutter_test/flutter_test.dart';
import 'package:aigammon_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('app boots', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AiGammonApp()));
    expect(find.text('AIGammon'), findsOneWidget);
  });
}
