// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Global theme tokens and Material theme builders for OpsAtlas.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

const double appRadiusMedium = 18;
const double appRadiusLarge = 28;

/// Shared spacing scale used across page frames, panels, and toolbars.
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

/// Shared motion durations so route and panel animation timing stays consistent.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration standard = Duration(milliseconds: 180);
  static const Duration emphasized = Duration(milliseconds: 260);
}

/// Flat section wrapper used to replace legacy boxed `Card` surfaces.
class AppFlatCard extends StatelessWidget {
  final Widget? child;
  final Color? color;
  final double? elevation;
  final ShapeBorder? shape;
  final bool borderOnForeground;
  final EdgeInsetsGeometry? margin;
  final Clip? clipBehavior;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final bool semanticContainer;

  const AppFlatCard({
    super.key,
    this.color,
    this.shadowColor,
    this.surfaceTintColor,
    this.elevation,
    this.shape,
    this.borderOnForeground = true,
    this.margin,
    this.clipBehavior,
    this.semanticContainer = true,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final edge = margin ?? EdgeInsets.zero;
    final effectiveClip = clipBehavior ?? Clip.none;

    return Padding(
      padding: edge,
      child: Material(
        color: color ?? Colors.transparent,
        elevation: elevation ?? 0,
        shadowColor: shadowColor ?? Colors.transparent,
        surfaceTintColor: surfaceTintColor ?? Colors.transparent,
        shape: shape ?? const RoundedRectangleBorder(),
        clipBehavior: effectiveClip,
        child: Ink(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}

BorderRadius _appRadius(double value) => BorderRadius.circular(value);

RoundedRectangleBorder _appShape(
  double value, {
  BorderSide side = BorderSide.none,
}) {
  return RoundedRectangleBorder(borderRadius: _appRadius(value), side: side);
}

UnderlineInputBorder _appUnderline(Color color, {double width = 1}) {
  return UnderlineInputBorder(
    borderSide: BorderSide(color: color, width: width),
  );
}

TextTheme _appTextTheme({
  required TextTheme base,
  required Color text,
  required Color muted,
}) {
  final themed = GoogleFonts.manropeTextTheme(base);
  return themed.copyWith(
    headlineLarge: themed.headlineLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.9,
      color: text,
    ),
    headlineMedium: themed.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.7,
      color: text,
    ),
    headlineSmall: themed.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: text,
    ),
    titleLarge: themed.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.28,
      color: text,
    ),
    titleMedium: themed.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
      color: text,
    ),
    bodyLarge: themed.bodyLarge?.copyWith(color: text, height: 1.52),
    bodyMedium: themed.bodyMedium?.copyWith(color: text, height: 1.48),
    bodySmall: themed.bodySmall?.copyWith(color: muted, height: 1.35),
    labelLarge: themed.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.05,
      color: text,
    ),
    labelMedium: themed.labelMedium?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.05,
      color: muted,
    ),
  );
}

/// Chooses a readable foreground color for arbitrary background swatches.
Color appBestForegroundColor(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

Color? _stateLayerColor(Set<WidgetState> states, Color base) {
  if (states.contains(WidgetState.pressed)) {
    return base.withValues(alpha: 0.16);
  }
  if (states.contains(WidgetState.focused)) {
    return base.withValues(alpha: 0.12);
  }
  if (states.contains(WidgetState.hovered)) {
    return base.withValues(alpha: 0.10);
  }
  return null;
}

MenuStyle _appMenuStyle(ColorScheme scheme) {
  return MenuStyle(
    backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLowest),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
    side: WidgetStatePropertyAll(
      BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.70)),
    ),
    shape: WidgetStatePropertyAll(_appShape(appRadiusMedium)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(vertical: AppSpacing.xs),
    ),
  );
}

ChipThemeData _appChipTheme({
  required ColorScheme scheme,
  required TextTheme textTheme,
  required Brightness brightness,
}) {
  return ChipThemeData(
    backgroundColor: scheme.surfaceContainerLow,
    disabledColor: scheme.surfaceContainer,
    selectedColor: scheme.primaryContainer,
    secondarySelectedColor: scheme.secondaryContainer,
    side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.70)),
    shape: const StadiumBorder(),
    labelStyle: textTheme.labelLarge?.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.w600,
    ),
    secondaryLabelStyle: textTheme.labelLarge?.copyWith(
      color: scheme.onPrimaryContainer,
      fontWeight: FontWeight.w700,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    showCheckmark: true,
    checkmarkColor: scheme.onPrimaryContainer,
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 18),
    brightness: brightness,
  );
}

SegmentedButtonThemeData _appSegmentedButtonTheme({
  required ColorScheme scheme,
  required TextTheme textTheme,
}) {
  return SegmentedButtonThemeData(
    style: ButtonStyle(
      shape: WidgetStatePropertyAll(_appShape(appRadiusMedium)),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? scheme.primary.withValues(alpha: 0.46)
              : scheme.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primaryContainer
            : scheme.surfaceContainerLow,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant,
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => _stateLayerColor(states, scheme.primary),
      ),
      textStyle: WidgetStatePropertyAll(
        textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      ),
    ),
  );
}

IconButtonThemeData _appIconButtonTheme(ColorScheme scheme) {
  return IconButtonThemeData(
    style: ButtonStyle(
      shape: WidgetStatePropertyAll(_appShape(appRadiusMedium)),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.onSurfaceVariant,
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => _stateLayerColor(states, scheme.primary),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primaryContainer.withValues(alpha: 0.58)
            : null,
      ),
    ),
  );
}

SnackBarThemeData _appSnackBarTheme(ColorScheme scheme, TextTheme textTheme) {
  return SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: scheme.inverseSurface,
    contentTextStyle: textTheme.bodyMedium?.copyWith(
      color: scheme.onInverseSurface,
      fontWeight: FontWeight.w600,
    ),
    actionTextColor: scheme.primary,
    closeIconColor: scheme.onInverseSurface,
    shape: _appShape(
      appRadiusMedium,
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
    ),
  );
}

TooltipThemeData _appTooltipTheme(ColorScheme scheme, TextTheme textTheme) {
  return TooltipThemeData(
    waitDuration: const Duration(milliseconds: 320),
    showDuration: const Duration(seconds: 3),
    textStyle: textTheme.bodySmall?.copyWith(
      color: scheme.onInverseSurface,
      fontWeight: FontWeight.w600,
    ),
    decoration: BoxDecoration(
      color: scheme.inverseSurface.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
    ),
  );
}

/// Builds the default light theme used by most routes and branded variants.
ThemeData buildLightTheme({Color? seedColor}) {
  final baseSeed = seedColor ?? const Color(0xFF0A84FF);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: baseSeed,
        brightness: Brightness.light,
      ).copyWith(
        surface: const Color(0xFFF7F8FB),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFF1F4FA),
        surfaceContainer: const Color(0xFFE9EEF7),
        surfaceContainerHigh: const Color(0xFFE2E9F4),
        primary: seedColor == null ? const Color(0xFF0F67E8) : null,
        secondary: seedColor == null ? const Color(0xFF3C6D93) : null,
        tertiary: seedColor == null ? const Color(0xFF0D9488) : null,
      );

  final textTheme = _appTextTheme(
    base: Typography.material2021().black,
    text: scheme.onSurface,
    muted: scheme.onSurfaceVariant,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(fontSize: 20),
    ),
    cardTheme: const CardThemeData(
      color: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: _appShape(
        appRadiusLarge,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(appRadiusLarge),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLowest,
      textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: _appShape(appRadiusMedium),
    ),
    menuTheme: MenuThemeData(style: _appMenuStyle(scheme)),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: textTheme.bodyMedium,
      menuStyle: _appMenuStyle(scheme),
      inputDecorationTheme: InputDecorationTheme(
        border: _appUnderline(scheme.outlineVariant.withValues(alpha: 0.7)),
        enabledBorder: _appUnderline(
          scheme.outlineVariant.withValues(alpha: 0.7),
        ),
        focusedBorder: _appUnderline(scheme.primary, width: 1.6),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      border: _appUnderline(scheme.outlineVariant.withValues(alpha: 0.7)),
      enabledBorder: _appUnderline(
        scheme.outlineVariant.withValues(alpha: 0.7),
      ),
      focusedBorder: _appUnderline(scheme.primary, width: 1.6),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 10,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 12,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 12,
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 12,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 10,
        ),
      ),
    ),
    iconButtonTheme: _appIconButtonTheme(scheme),
    chipTheme: _appChipTheme(
      scheme: scheme,
      textTheme: textTheme,
      brightness: Brightness.light,
    ),
    segmentedButtonTheme: _appSegmentedButtonTheme(
      scheme: scheme,
      textTheme: textTheme,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.88)),
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return scheme.primary;
        }
        if (states.contains(WidgetState.disabled)) {
          return scheme.surfaceContainerHighest;
        }
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(scheme.onPrimary),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.onSurfaceVariant,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
    ),
    snackBarTheme: _appSnackBarTheme(scheme, textTheme),
    tooltipTheme: _appTooltipTheme(scheme, textTheme),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: scheme.primary),
      selectedLabelTextStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w700,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.15),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      shape: _appShape(appRadiusMedium),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.45),
      thickness: 1,
      space: 1,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      unselectedLabelStyle: textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(100),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      shape: _appShape(appRadiusMedium),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
  );
}

/// Builds the dark theme while still honoring runtime branding overrides.
ThemeData buildDarkTheme({Color? accentColor, Color? backgroundColor}) {
  final bg = backgroundColor ?? const Color(0xFF0A0D12);
  final accent = accentColor ?? const Color(0xFF4CA4FF);
  final bgAlt = Color.lerp(bg, Colors.white, 0.05) ?? const Color(0xFF161C27);
  final panel = Color.lerp(bg, accent, 0.10) ?? const Color(0xFF1A2535);
  final panelHi = Color.lerp(bg, accent, 0.15) ?? const Color(0xFF233346);
  const text = Color(0xFFE8EEF6);
  const muted = Color(0xFF97A9BF);
  final outline = Color.lerp(bg, Colors.white, 0.17) ?? const Color(0xFF314559);

  final scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: accent,
    onPrimary: const Color(0xFF031220),
    secondary: const Color(0xFF70AFDD),
    onSecondary: const Color(0xFF041523),
    error: const Color(0xFFFF6B6B),
    onError: Colors.black,
    surface: bg,
    onSurface: text,
    surfaceContainerLowest: bg,
    surfaceContainerLow: bgAlt,
    surfaceContainer: panel,
    surfaceContainerHigh: panelHi,
    surfaceContainerHighest:
        Color.lerp(bg, accent, 0.24) ?? const Color(0xFF2A4766),
    onSurfaceVariant: muted,
    outline: outline,
    outlineVariant: Color.lerp(outline, bg, 0.32) ?? const Color(0xFF22374E),
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: const Color(0xFFE7EEF6),
    onInverseSurface: const Color(0xFF08121D),
    inversePrimary: accent,
    tertiary:
        Color.lerp(accent, Colors.cyanAccent, 0.3) ?? const Color(0xFF82E2FF),
    onTertiary: const Color(0xFF08212A),
    tertiaryContainer: Color.lerp(bg, accent, 0.24) ?? const Color(0xFF163B4F),
    onTertiaryContainer: const Color(0xFFD8F6FF),
    primaryContainer: Color.lerp(bg, accent, 0.22) ?? const Color(0xFF11304B),
    onPrimaryContainer: const Color(0xFFCAE7FF),
    secondaryContainer:
        Color.lerp(bg, const Color(0xFF6FAAD9), 0.18) ??
        const Color(0xFF173347),
    onSecondaryContainer: const Color(0xFFD2ECFF),
    errorContainer: const Color(0xFF4B2020),
    onErrorContainer: const Color(0xFFFFDADA),
  );

  final textTheme = _appTextTheme(
    base: Typography.material2021().white,
    text: text,
    muted: muted,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: text,
      elevation: 0,
      centerTitle: false,
      scrolledUnderElevation: 0,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: text, fontSize: 20),
    ),
    cardTheme: const CardThemeData(
      color: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: panel,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: _appShape(
        appRadiusLarge,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(appRadiusLarge),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: panel,
      textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: _appShape(appRadiusMedium),
    ),
    menuTheme: MenuThemeData(style: _appMenuStyle(scheme)),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      menuStyle: _appMenuStyle(scheme),
      inputDecorationTheme: InputDecorationTheme(
        border: _appUnderline(outline.withValues(alpha: 0.72)),
        enabledBorder: _appUnderline(outline.withValues(alpha: 0.72)),
        focusedBorder: _appUnderline(accent, width: 1.6),
      ),
    ),
    dividerColor: outline.withValues(alpha: 0.8),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      labelStyle: const TextStyle(color: muted),
      hintStyle: TextStyle(color: muted.withValues(alpha: 0.9)),
      border: _appUnderline(outline.withValues(alpha: 0.72)),
      enabledBorder: _appUnderline(outline.withValues(alpha: 0.72)),
      focusedBorder: _appUnderline(accent, width: 1.6),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 10,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 12,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        side: BorderSide(color: outline.withValues(alpha: 0.75)),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 12,
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 12,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 10,
        ),
      ),
    ),
    iconButtonTheme: _appIconButtonTheme(scheme),
    chipTheme: _appChipTheme(
      scheme: scheme,
      textTheme: textTheme,
      brightness: Brightness.dark,
    ),
    segmentedButtonTheme: _appSegmentedButtonTheme(
      scheme: scheme,
      textTheme: textTheme,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.9)),
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return scheme.primary;
        }
        if (states.contains(WidgetState.disabled)) {
          return scheme.surfaceContainerHighest;
        }
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(scheme.onPrimary),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.onSurfaceVariant,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
    ),
    snackBarTheme: _appSnackBarTheme(scheme, textTheme),
    tooltipTheme: _appTooltipTheme(scheme, textTheme),
    listTileTheme: const ListTileThemeData(iconColor: muted, textColor: text),
    dividerTheme: DividerThemeData(
      color: outline.withValues(alpha: 0.65),
      thickness: 1,
      space: 1,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: accent,
      unselectedLabelColor: muted,
      labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      unselectedLabelStyle: textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: accent, width: 2),
        borderRadius: BorderRadius.circular(100),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: accent),
      unselectedIconTheme: const IconThemeData(color: muted),
      selectedLabelTextStyle: TextStyle(
        color: accent,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: const TextStyle(color: muted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: accent.withValues(alpha: 0.18),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected) ? accent : muted,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      shape: _appShape(appRadiusMedium),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
  );
}
