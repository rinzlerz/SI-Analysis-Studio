// Widget smoke test: the app starts, navigates and shows the configuration.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/app.dart';
import 'package:si_studio/core/state/app_controller.dart';

void main() {
  testWidgets('app shell navigates to New Analysis', (tester) async {
    final controller = await AppController.inMemory();
    await tester.pumpWidget(SiStudioApp(controller: controller));
    await tester.pump();
    expect(find.text('SI Studio'), findsWidgets);

    await tester.tap(find.byIcon(Icons.add_chart_outlined));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('A · Protocol'), findsOneWidget);
    expect(find.text('B · Protocol configuration'), findsOneWidget);
  });
}
