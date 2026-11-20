// Widget smoke test: the app starts, navigates and shows the configuration.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:si_studio/app.dart';
import 'package:si_studio/core/state/app_controller.dart';
import 'package:si_studio/simulation/engine.dart';

void main() {
  testWidgets('app shell navigates to New Analysis', (tester) async {
    // Tall phone-sized screen (width < 900 keeps the bottom navigation bar).
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = await AppController.inMemory();
    await tester.pumpWidget(SiStudioApp(controller: controller));
    await tester.pump();
    expect(find.text('SI Studio'), findsWidgets);
    expect(find.text('Try an example'.toUpperCase()), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_chart_outlined));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('A · Protocol'), findsOneWidget);
    expect(find.text('Ethernet RGMII'), findsOneWidget);
    expect(find.text('B · Protocol configuration'), findsOneWidget);
    expect(find.text('Generate Quick SI Analysis'), findsOneWidget);
  });

  testWidgets('DDR configuration builds', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = await AppController.inMemory();
    controller.setProtocol(Protocol.ddr);
    await tester.pumpWidget(SiStudioApp(controller: controller));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add_chart_outlined));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Standard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide screens use side navigation', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = await AppController.inMemory();
    await tester.pumpWidget(SiStudioApp(controller: controller));
    await tester.pump();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
