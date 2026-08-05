// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Localization lookup and delegate glue for the Flutter client.

import 'package:flutter/widgets.dart';

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_tr.dart';

class AppLocalizations {
  final Locale locale;

  const AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    final current = Localizations.of<AppLocalizations>(
      context,
      AppLocalizations,
    );
    return current ?? const AppLocalizations(Locale('en'));
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const _builtInSupportedLocales = [
    Locale('en'),
    Locale('de'),
    Locale('tr'),
  ];
  static List<String> _runtimeSupportedLanguageCodes = const <String>[];
  static String _runtimeDefaultLanguageCode = 'en';
  static List<String> _runtimeOrganizationFallbackOrder = const <String>['en'];
  static Map<String, List<String>> _runtimeLanguageFallbackOrder =
      const <String, List<String>>{};
  static Map<String, Map<String, String>> _runtimeBundleValues =
      const <String, Map<String, String>>{};
  static Set<String> _runtimeRtlLanguageCodes = const <String>{};

  static List<Locale> get supportedLocales {
    final locales = <Locale>[];
    final seen = <String>{};
    final codes = <String>[..._runtimeSupportedLanguageCodes, ..._values.keys];
    for (final candidate in codes) {
      final normalized = _normalizeLanguageCode(candidate);
      if (normalized == null || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      locales.add(Locale(normalized));
    }
    return locales.isEmpty ? _builtInSupportedLocales : locales;
  }

  static const _values = <String, Map<String, String>>{
    'en': appLocalizationsEnValues,
    'de': appLocalizationsDeValues,
    'tr': appLocalizationsTrValues,
  };

  static void configureRuntime({
    required Iterable<String> enabledLanguageCodes,
    required String defaultLanguageCode,
    required Iterable<String> organizationFallbackOrder,
    required Map<String, List<String>> fallbackOrderByLanguage,
    required Map<String, Map<String, String>> bundles,
    required Iterable<String> rtlLanguageCodes,
  }) {
    _runtimeSupportedLanguageCodes = _normalizeLanguageCodeList(
      enabledLanguageCodes,
    );
    _runtimeDefaultLanguageCode =
        _normalizeLanguageCode(defaultLanguageCode) ?? 'en';
    _runtimeOrganizationFallbackOrder = _normalizeLanguageCodeList(
      organizationFallbackOrder,
      includeCode: _runtimeDefaultLanguageCode,
    );

    final nextFallbackByLanguage = <String, List<String>>{};
    fallbackOrderByLanguage.forEach((rawCode, rawFallback) {
      final code = _normalizeLanguageCode(rawCode);
      if (code == null) {
        return;
      }
      nextFallbackByLanguage[code] = _normalizeLanguageCodeList(
        rawFallback,
        includeCode: code,
      );
    });
    _runtimeLanguageFallbackOrder = nextFallbackByLanguage;

    final nextBundles = <String, Map<String, String>>{};
    bundles.forEach((rawCode, rawEntries) {
      final code = _normalizeLanguageCode(rawCode);
      if (code == null) {
        return;
      }
      final normalizedEntries = <String, String>{};
      rawEntries.forEach((rawKey, rawValue) {
        final key = rawKey.trim();
        if (key.isEmpty) {
          return;
        }
        normalizedEntries[key] = rawValue;
      });
      nextBundles[code] = normalizedEntries;
    });
    _runtimeBundleValues = nextBundles;

    _runtimeRtlLanguageCodes = _normalizeLanguageCodeList(
      rtlLanguageCodes,
    ).toSet();
  }

  static void clearRuntime() {
    _runtimeSupportedLanguageCodes = const <String>[];
    _runtimeDefaultLanguageCode = 'en';
    _runtimeOrganizationFallbackOrder = const <String>['en'];
    _runtimeLanguageFallbackOrder = const <String, List<String>>{};
    _runtimeBundleValues = const <String, Map<String, String>>{};
    _runtimeRtlLanguageCodes = const <String>{};
  }

  static bool isRtlLanguageCode(String? code) {
    final normalized = _normalizeLanguageCode(code);
    if (normalized == null) {
      return false;
    }
    return _runtimeRtlLanguageCodes.contains(normalized);
  }

  static List<String> _normalizeLanguageCodeList(
    Iterable<String> values, {
    String? includeCode,
  }) {
    final normalizedValues = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final normalized = _normalizeLanguageCode(value);
      if (normalized == null || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      normalizedValues.add(normalized);
    }
    final include = _normalizeLanguageCode(includeCode);
    if (include != null && !seen.contains(include)) {
      normalizedValues.insert(0, include);
    }
    return normalizedValues;
  }

  static String? _normalizeLanguageCode(String? raw) {
    if (raw == null) {
      return null;
    }
    final normalized = raw.trim().replaceAll('_', '-').toLowerCase();
    return normalized.isEmpty ? null : normalized;
  }

  List<String> _resolveLanguageCandidates() {
    final candidates = <String>[];
    final seen = <String>{};

    void append(String? code) {
      final normalized = _normalizeLanguageCode(code);
      if (normalized == null || seen.contains(normalized)) {
        return;
      }
      seen.add(normalized);
      candidates.add(normalized);
    }

    final fullLocaleCode = _normalizeLanguageCode(
      locale.countryCode == null || locale.countryCode!.trim().isEmpty
          ? locale.languageCode
          : '${locale.languageCode}-${locale.countryCode}',
    );
    final languageCode = _normalizeLanguageCode(locale.languageCode);

    append(fullLocaleCode);
    append(languageCode);

    if (fullLocaleCode != null) {
      for (final fallback
          in _runtimeLanguageFallbackOrder[fullLocaleCode] ??
              const <String>[]) {
        append(fallback);
      }
    }
    if (languageCode != null) {
      for (final fallback
          in _runtimeLanguageFallbackOrder[languageCode] ?? const <String>[]) {
        append(fallback);
      }
    }

    for (final fallback in _runtimeOrganizationFallbackOrder) {
      append(fallback);
    }
    append(_runtimeDefaultLanguageCode);
    append('en');

    return candidates;
  }

  String text(String key) {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) {
      return key;
    }

    for (final code in _resolveLanguageCandidates()) {
      final runtimeMap = _runtimeBundleValues[code];
      final runtimeValue = runtimeMap == null
          ? null
          : runtimeMap[normalizedKey];
      if (runtimeValue != null && runtimeValue.isNotEmpty) {
        return runtimeValue;
      }
      final builtInValue = _values[code]?[normalizedKey];
      if (builtInValue != null && builtInValue.isNotEmpty) {
        return builtInValue;
      }
    }
    return _values['en']![normalizedKey] ?? normalizedKey;
  }

  String textWith(String key, Map<String, Object?> values) {
    var resolved = text(key);
    values.forEach((token, value) {
      resolved = resolved.replaceAll('{$token}', '${value ?? ''}');
    });
    return resolved;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any(
      (supported) => supported.languageCode == locale.languageCode,
    );
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) =>
      false;
}
