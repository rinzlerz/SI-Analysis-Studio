import 'package:flutter/material.dart';

import 'core/state/app_controller.dart';
import 'core/theme/app_theme.dart';
import 'features/analysis_input/new_analysis_screen.dart';
import 'features/history/history_screen.dart';
import 'features/home/home_screen.dart';
import 'features/settings/settings_screen.dart';
import 'shared/share_actions.dart';
import 'shared/widgets/common.dart';

class SiStudioApp extends StatelessWidget {
  const SiStudioApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SI Studio',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(),
      themeMode: ThemeMode.dark,
      home: AppShell(controller: controller),
    );
  }
}

/// Bottom navigation: Home, New Analysis, History, Settings (PRD 9.1).
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Share links (web): open the analysis carried in the URL.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) openLaunchShare(context, controller);
    });
  }

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.add_chart_outlined, Icons.add_chart, 'New Analysis'),
    (Icons.history, Icons.history, 'History'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.tab,
      builder: (context, index, _) {
        final pages = IndexedStack(
          index: index,
          children: [
            HomeScreen(controller: controller),
            NewAnalysisScreen(controller: controller),
            HistoryScreen(controller: controller),
            SettingsScreen(controller: controller),
          ],
        );
        return LayoutBuilder(builder: (context, box) {
          // Desktop browsers / tablets: side navigation and a readable width.
          if (box.maxWidth >= 900) {
            return Scaffold(
              body: Row(children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) => controller.tab.value = i,
                  labelType: NavigationRailLabelType.all,
                  backgroundColor: AppColors.surface,
                  indicatorColor: AppColors.accent.withValues(alpha: 0.18),
                  leading: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: SiLogo(size: 26)),
                  destinations: [
                    for (final (icon, sel, label) in _destinations)
                      NavigationRailDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: Text(label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: pages),
                  ),
                ),
              ]),
            );
          }
          return Scaffold(
            body: pages,
            bottomNavigationBar: NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => controller.tab.value = i,
              destinations: [
                for (final (icon, sel, label) in _destinations)
                  NavigationDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: label),
              ],
            ),
          );
        });
      },
    );
  }
}
