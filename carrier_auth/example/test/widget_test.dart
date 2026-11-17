import 'package:carrier_auth_example/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('unconfigured example cannot invoke live authentication', (
    tester,
  ) async {
    await tester.pumpWidget(const CarrierExampleApp());
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.textContaining('does not log in an account'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
