// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Root application widget that applies branding, theming, localization, and routing.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/branding.dart';
import '../core/i18n/app_localizations.dart';
import '../core/i18n/locale_controller.dart';
import '../core/theme/theme.dart';
import '../core/theme/theme_controller.dart';
import '../core/web/browser_branding.dart';
import 'router.dart';

/// Top-level application widget that wires branding, theme, locale, and router.
class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final theme = ref.watch(themeControllerProvider);
    final localeCtrl = ref.watch(localeControllerProvider);
    final branding = ref.watch(brandingProvider).asData?.value;
    final fallbackLocale = localeCtrl.locale ?? const Locale('en');
    final localizations = AppLocalizations(fallbackLocale);
    final fallbackTitle = localizations.text('company_platform');
    final fallbackDescription = localizations.text('default_web_description');
    final resolvedWebDescription = branding?.resolvedWebDescription;
    final browserDescription =
        resolvedWebDescription == null ||
            resolvedWebDescription == defaultBrandingWebDescription
        ? fallbackDescription
        : resolvedWebDescription;
    final appTitle = branding?.resolvedAppTitle ?? fallbackTitle;
    syncBrowserBranding(
      title: appTitle,
      faviconUrl: branding?.faviconUrl,
      description: browserDescription,
      appleWebAppTitle: branding?.resolvedAppleWebAppTitle ?? appTitle,
      themeColorHex: branding?.resolvedThemeColorHex,
      manifestUrl: branding?.manifestUrl,
      appleTouchIconUrl: branding?.faviconUrl,
    );
    return MaterialApp.router(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(seedColor: branding?.lightSeedColor),
      darkTheme: buildDarkTheme(
        accentColor: branding?.darkAccentColor,
        backgroundColor: branding?.darkBackgroundColor,
      ),
      themeMode: theme.mode,
      locale: localeCtrl.locale,
      supportedLocales: localeCtrl.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}
