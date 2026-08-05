// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/i18n/app_localizations.dart';

void main() {
  tearDown(() {
    AppLocalizations.clearRuntime();
  });

  test('runtime bundles can override built-in values', () {
    AppLocalizations.configureRuntime(
      enabledLanguageCodes: const <String>['en'],
      defaultLanguageCode: 'en',
      organizationFallbackOrder: const <String>['en'],
      fallbackOrderByLanguage: const <String, List<String>>{},
      bundles: const <String, Map<String, String>>{
        'en': <String, String>{'login': 'Sign In Custom'},
      },
      rtlLanguageCodes: const <String>[],
    );

    const l10n = AppLocalizations(Locale('en'));
    expect(l10n.text('login'), 'Sign In Custom');
  });

  test('text resolution falls back through runtime language order', () {
    AppLocalizations.configureRuntime(
      enabledLanguageCodes: const <String>['tr', 'en'],
      defaultLanguageCode: 'tr',
      organizationFallbackOrder: const <String>['tr', 'en'],
      fallbackOrderByLanguage: const <String, List<String>>{
        'de': <String>['tr'],
      },
      bundles: const <String, Map<String, String>>{
        'tr': <String, String>{'greeting_custom': 'Merhaba'},
      },
      rtlLanguageCodes: const <String>[],
    );

    const german = AppLocalizations(Locale('de'));
    expect(german.text('greeting_custom'), 'Merhaba');
  });

  test('unknown key returns key when no built-in/runtime value exists', () {
    const l10n = AppLocalizations(Locale('en'));

    expect(l10n.text('totally_unknown_key_123'), 'totally_unknown_key_123');
  });

  test('rtl language codes are normalized', () {
    AppLocalizations.configureRuntime(
      enabledLanguageCodes: const <String>['en', 'ar'],
      defaultLanguageCode: 'en',
      organizationFallbackOrder: const <String>['en'],
      fallbackOrderByLanguage: const <String, List<String>>{},
      bundles: const <String, Map<String, String>>{},
      rtlLanguageCodes: const <String>['AR_eg'],
    );

    expect(AppLocalizations.isRtlLanguageCode('ar-eg'), isTrue);
    expect(AppLocalizations.isRtlLanguageCode('ar_EG'), isTrue);
    expect(AppLocalizations.isRtlLanguageCode('en'), isFalse);
  });

  test('supportedLocales includes runtime enabled languages once', () {
    AppLocalizations.configureRuntime(
      enabledLanguageCodes: const <String>['fr', 'en', 'fr'],
      defaultLanguageCode: 'en',
      organizationFallbackOrder: const <String>['en'],
      fallbackOrderByLanguage: const <String, List<String>>{},
      bundles: const <String, Map<String, String>>{},
      rtlLanguageCodes: const <String>[],
    );

    final languageCodes = AppLocalizations.supportedLocales
        .map((locale) => locale.languageCode)
        .toList();

    expect(languageCodes, contains('fr'));
    expect(languageCodes.where((code) => code == 'fr').length, 1);
  });
}
