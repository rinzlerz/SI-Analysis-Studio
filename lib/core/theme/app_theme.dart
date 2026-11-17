import 'package:flutter/material.dart';

import '../../simulation/model/result.dart';

/// Oscilloscope-inspired dark theme for SI Studio.
class AppColors {
  static const background = Color(0xFF0B0F14);
  static const surface = Color(0xFF131A22);
  static const surfaceHigh = Color(0xFF1A232E);
  static const outline = Color(0xFF2A3644);
  static const grid = Color(0xFF1E2935);
  static const gridMajor = Color(0xFF2B3A4A);
  static const text = Color(0xFFE6EDF3);
  static const textDim = Color(0xFF8B9BAB);
  static const accent = Color(0xFF2DD4BF);

  static const good = Color(0xFF3FB950);
  static const warning = Color(0xFFE3B341);
  static const critical = Color(0xFFF85149);
  static const info = Color(0xFF8B9BAB);

  // Copper / stackup.
  static const copper = Color(0xFFD08A4A);
  static const ground = Color(0xFF4F9D69);
  static const power = Color(0xFFC0564F);
  static const dielectric = Color(0xFF3A4A3A);

  /// High-contrast scope channel colours.
  static const traces = <Color>[
    Color(0xFFFFD60A), // CH1 yellow
    Color(0xFF2DD4BF), // CH2 cyan
    Color(0xFFFF4FD8), // CH3 magenta
    Color(0xFF5AA9FF), // CH4 blue
    Color(0xFF7EE787), // green
    Color(0xFFFF9F43), // orange
  ];

  static Color status(SiStatus s) => switch (s) {
        SiStatus.good => good,
        SiStatus.warning => warning,
        SiStatus.critical => critical,
        SiStatus.info => info,
      };

  static Color traceKind(TraceKind k, int index) => switch (k) {
        TraceKind.ideal => const Color(0xFF8B9BAB),
        TraceKind.tx => traces[3],
        TraceKind.rx => traces[0],
        TraceKind.incident => traces[4],
        TraceKind.reflected => traces[2],
        TraceKind.commonMode => traces[5],
        TraceKind.other => traces[1],
      };
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    outline: AppColors.outline,
    error: AppColors.critical,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    brightness: Brightness.dark,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.text,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: base.cardTheme.copyWith(
      color: AppColors.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.outline),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.surfaceHigh,
      border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.outline)),
      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.outline)),
      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.accent, width: 1.5)),
      labelStyle: TextStyle(color: AppColors.textDim),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.accent.withValues(alpha: 0.18),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.outline, space: 1),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: TextStyle(color: AppColors.text),
      actionTextColor: AppColors.accent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: AppColors.outline),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
      textStyle: TextStyle(color: AppColors.text, fontSize: 12.5),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.all(Radius.circular(6)),
        border: Border.fromBorderSide(BorderSide(color: AppColors.outline)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: const BorderSide(color: AppColors.outline),
      selectedColor: AppColors.accent.withValues(alpha: 0.22),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.outline),
        minimumSize: const Size(0, 40),
      ),
    ),
  );
}

/// Monospaced-figure text style for numeric read-outs.
const TextStyle kNumStyle = TextStyle(
  fontFeatures: [FontFeature.tabularFigures()],
  fontFamily: 'monospace',
);
