// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Runtime branding models and providers for titles, icons, and theme overrides.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'server_config.dart';

const String defaultBrandingWebDescription =
    'OpsAtlas is a self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work.';

class BrandingConfig {
  final String? apiBaseUrl;
  final String? companyName;
  final String? applicationTitle;
  final String? applicationShortName;
  final String? webDescription;
  final String? appleWebAppTitle;
  final String? logoUrl;
  final String? lightLogoUrl;
  final String? darkLogoUrl;
  final String? faviconUrl;
  final String? loginBackgroundUrl;
  final String? lightSeedHex;
  final String? darkAccentHex;
  final String? darkBgHex;
  final String? browserThemeHex;
  final String? installBackgroundHex;
  final String resolvedAppTitle;
  final String resolvedApplicationShortName;
  final String resolvedWebDescription;
  final String resolvedAppleWebAppTitle;
  final String resolvedThemeColorHex;
  final String resolvedInstallBackgroundHex;
  final DateTime? updatedAt;

  const BrandingConfig({
    this.apiBaseUrl,
    this.companyName,
    this.applicationTitle,
    this.applicationShortName,
    this.webDescription,
    this.appleWebAppTitle,
    this.logoUrl,
    this.lightLogoUrl,
    this.darkLogoUrl,
    this.faviconUrl,
    this.loginBackgroundUrl,
    this.lightSeedHex,
    this.darkAccentHex,
    this.darkBgHex,
    this.browserThemeHex,
    this.installBackgroundHex,
    required this.resolvedAppTitle,
    required this.resolvedApplicationShortName,
    required this.resolvedWebDescription,
    required this.resolvedAppleWebAppTitle,
    required this.resolvedThemeColorHex,
    required this.resolvedInstallBackgroundHex,
    this.updatedAt,
  });

  factory BrandingConfig.fromJson(
    Map<String, dynamic> json, {
    String? apiBaseUrl,
  }) {
    final lightLogo = resolveApiAssetUrl(apiBaseUrl, json['light_logo_url']);
    final darkLogo = resolveApiAssetUrl(apiBaseUrl, json['dark_logo_url']);
    final companyName = _asTrimmed(json['company_name']);
    final applicationTitle = _asTrimmed(json['application_title']);
    final applicationShortName = _asTrimmed(json['application_short_name']);
    final webDescription = _asTrimmed(json['web_description']);
    final appleWebAppTitle = _asTrimmed(json['apple_web_app_title']);
    final lightSeedHex = _asTrimmed(json['light_seed_hex']);
    final darkAccentHex = _asTrimmed(json['dark_accent_hex']);
    final darkBgHex = _asTrimmed(json['dark_bg_hex']);
    final browserThemeHex = _asTrimmed(json['browser_theme_hex']);
    final installBackgroundHex = _asTrimmed(json['install_background_hex']);
    return BrandingConfig(
      apiBaseUrl: apiBaseUrl,
      companyName: companyName,
      applicationTitle: applicationTitle,
      applicationShortName: applicationShortName,
      webDescription: webDescription,
      appleWebAppTitle: appleWebAppTitle,
      logoUrl:
          resolveApiAssetUrl(apiBaseUrl, json['logo_url']) ??
          lightLogo ??
          darkLogo,
      lightLogoUrl: lightLogo,
      darkLogoUrl: darkLogo,
      faviconUrl: resolveApiAssetUrl(apiBaseUrl, json['favicon_url']),
      loginBackgroundUrl: resolveApiAssetUrl(
        apiBaseUrl,
        json['login_background_url'],
      ),
      lightSeedHex: lightSeedHex,
      darkAccentHex: darkAccentHex,
      darkBgHex: darkBgHex,
      browserThemeHex: browserThemeHex,
      installBackgroundHex: installBackgroundHex,
      resolvedAppTitle:
          _asTrimmed(json['resolved_app_title']) ??
          applicationTitle ??
          companyName ??
          'OpsAtlas',
      resolvedApplicationShortName:
          _asTrimmed(json['resolved_application_short_name']) ??
          applicationShortName ??
          applicationTitle ??
          companyName ??
          'OpsAtlas',
      resolvedWebDescription:
          _asTrimmed(json['resolved_web_description']) ??
          webDescription ??
          defaultBrandingWebDescription,
      resolvedAppleWebAppTitle:
          _asTrimmed(json['resolved_apple_web_app_title']) ??
          appleWebAppTitle ??
          applicationShortName ??
          applicationTitle ??
          companyName ??
          'OpsAtlas',
      resolvedThemeColorHex:
          _asTrimmed(json['resolved_theme_color_hex']) ??
          browserThemeHex ??
          lightSeedHex ??
          '#0F67E8',
      resolvedInstallBackgroundHex:
          _asTrimmed(json['resolved_install_background_hex']) ??
          installBackgroundHex ??
          darkBgHex ??
          '#0A0D12',
      updatedAt: json['updated_at'] is String
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
    );
  }

  Color? get lightSeedColor => parseHexColor(lightSeedHex);
  Color? get darkAccentColor => parseHexColor(darkAccentHex);
  Color? get darkBackgroundColor => parseHexColor(darkBgHex);
  Color? get browserThemeColor => parseHexColor(resolvedThemeColorHex);
  Color? get installBackgroundColor =>
      parseHexColor(resolvedInstallBackgroundHex);

  String get manifestUrl {
    final base = Uri.tryParse(apiBaseUrl ?? '');
    final baseUri = (base != null && base.hasScheme && base.host.isNotEmpty)
        ? base.resolve('/branding/manifest.webmanifest')
        : Uri(path: '/branding/manifest.webmanifest');
    if (updatedAt == null) {
      return baseUri.toString();
    }
    return baseUri
        .replace(
          queryParameters: <String, String>{
            'v': '${updatedAt!.millisecondsSinceEpoch}',
          },
        )
        .toString();
  }
}

final brandingProvider = FutureProvider<BrandingConfig>((ref) async {
  final serverConfig = ref.watch(serverConfigProvider);
  final apiBaseUrl = serverConfig.effectiveBaseUrl;
  if (apiBaseUrl == null || apiBaseUrl.trim().isEmpty) {
    return const BrandingConfig(
      resolvedAppTitle: 'OpsAtlas',
      resolvedApplicationShortName: 'OpsAtlas',
      resolvedWebDescription: defaultBrandingWebDescription,
      resolvedAppleWebAppTitle: 'OpsAtlas',
      resolvedThemeColorHex: '#0F67E8',
      resolvedInstallBackgroundHex: '#0A0D12',
    );
  }
  final api = ref.watch(apiClientProvider);
  final r = await api.dio.get('/branding');
  return BrandingConfig.fromJson(
    (r.data as Map).cast<String, dynamic>(),
    apiBaseUrl: apiBaseUrl,
  );
});

Color? parseHexColor(String? raw) {
  final value = _asTrimmed(raw);
  if (value == null) return null;
  final hex = value.startsWith('#') ? value.substring(1) : value;
  if (hex.length != 6) return null;
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  return Color(0xFF000000 | parsed);
}

String? _asTrimmed(Object? value) {
  if (value == null) return null;
  final s = value.toString().trim();
  return s.isEmpty ? null : s;
}
