// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Locale controller that bridges persisted choice with backend preferences.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/auth_store.dart';
import 'app_localizations.dart';

final localeControllerProvider = ChangeNotifierProvider<LocaleController>((
  ref,
) {
  final api = ref.read(apiClientProvider);
  final auth = ref.read(authStoreProvider);
  final controller = LocaleController(api, auth)..load();

  var wasLoggedIn = auth.isLoggedIn;
  ref.listen<AuthStore>(authStoreProvider, (_, next) {
    final isLoggedIn = next.isLoggedIn;
    if (isLoggedIn == wasLoggedIn) {
      return;
    }
    wasLoggedIn = isLoggedIn;
    controller.load();
  });

  return controller;
});

class LocalizationLanguageOption {
  final String code;
  final String name;
  final bool enabled;
  final bool isDefault;
  final bool isRtl;
  final List<String> fallbackOrder;
  final int bundleVersion;

  const LocalizationLanguageOption({
    required this.code,
    required this.name,
    required this.enabled,
    required this.isDefault,
    required this.isRtl,
    required this.fallbackOrder,
    required this.bundleVersion,
  });
}

class LocaleController extends ChangeNotifier {
  static const _storageKey = 'app_locale_code';

  final ApiClient _api;
  final AuthStore _auth;

  Locale? _locale;
  bool _useOrganizationDefault = false;
  String? _userLanguageCode;
  String _effectiveLanguageCode = 'en';
  bool _loadedFromServer = false;
  bool _loading = false;
  int _requestVersion = 0;

  List<LocalizationLanguageOption> _languageOptions = const [];
  String _defaultLanguageCode = 'en';
  List<String> _organizationFallbackOrder = const ['en'];

  LocaleController(this._api, this._auth);

  Locale? get locale => _locale;
  bool get useOrganizationDefault => _useOrganizationDefault;
  String? get userLanguageCode => _userLanguageCode;
  String get effectiveLanguageCode => _effectiveLanguageCode;
  bool get loadedFromServer => _loadedFromServer;
  bool get loading => _loading;
  String get defaultLanguageCode => _defaultLanguageCode;
  List<String> get organizationFallbackOrder =>
      List<String>.unmodifiable(_organizationFallbackOrder);
  List<LocalizationLanguageOption> get languageOptions =>
      List<LocalizationLanguageOption>.unmodifiable(_languageOptions);

  List<Locale> get supportedLocales {
    if (_languageOptions.isEmpty) {
      return AppLocalizations.supportedLocales;
    }

    final locales = <Locale>[];
    final seen = <String>{};
    for (final option in _languageOptions) {
      if (!option.enabled && !option.isDefault) {
        continue;
      }
      final code = _normalizeLanguageCode(option.code);
      if (code == null || seen.contains(code)) {
        continue;
      }
      seen.add(code);
      locales.add(Locale(code));
    }

    if (locales.isEmpty) {
      return AppLocalizations.supportedLocales;
    }
    return locales;
  }

  Future<void> load() async {
    final requestVersion = ++_requestVersion;
    _setLoading(true);

    var loaded = false;
    if (_auth.isLoggedIn) {
      loaded = await _loadRuntimeFromServer(requestVersion);
    }

    if (!loaded) {
      await _loadLocalFallback(requestVersion);
    }

    if (requestVersion != _requestVersion) {
      return;
    }
    _setLoading(false);
  }

  Future<void> refreshRuntime() async {
    await load();
  }

  Future<void> setSystemLocale() async {
    if (_auth.isLoggedIn) {
      final updated = await _updateRemotePreference(
        languageCode: null,
        includeLanguageCode: true,
        useOrgDefault: true,
        includeUseOrgDefault: true,
      );

      final sp = await SharedPreferences.getInstance();
      await sp.setString(_storageKey, 'system');

      if (updated) {
        await load();
        return;
      }

      _locale = null;
      _useOrganizationDefault = false;
      _userLanguageCode = null;
      _effectiveLanguageCode = 'en';
      _loadedFromServer = false;
      _languageOptions = const [];
      _defaultLanguageCode = 'en';
      _organizationFallbackOrder = const ['en'];
      AppLocalizations.clearRuntime();
      notifyListeners();
      return;
    }

    _locale = null;
    _useOrganizationDefault = false;
    _userLanguageCode = null;
    _effectiveLanguageCode = 'en';
    _loadedFromServer = false;
    _languageOptions = const [];
    _defaultLanguageCode = 'en';
    _organizationFallbackOrder = const ['en'];
    AppLocalizations.clearRuntime();

    final sp = await SharedPreferences.getInstance();
    await sp.setString(_storageKey, 'system');
    notifyListeners();
  }

  Future<void> setLocale(Locale locale) async {
    final normalized = _normalizeLanguageCode(locale.languageCode);
    if (normalized == null) {
      return;
    }

    if (_auth.isLoggedIn) {
      final updated = await _updateRemotePreference(
        languageCode: normalized,
        includeLanguageCode: true,
        useOrgDefault: false,
        includeUseOrgDefault: true,
      );

      final sp = await SharedPreferences.getInstance();
      await sp.setString(_storageKey, normalized);

      if (updated) {
        await load();
        return;
      }

      _locale = Locale(normalized);
      _useOrganizationDefault = false;
      _userLanguageCode = normalized;
      _effectiveLanguageCode = normalized;
      _loadedFromServer = false;
      _languageOptions = const [];
      _defaultLanguageCode = normalized;
      _organizationFallbackOrder = <String>[normalized, 'en'];
      AppLocalizations.clearRuntime();
      notifyListeners();
      return;
    }

    _locale = Locale(normalized);
    _useOrganizationDefault = false;
    _userLanguageCode = normalized;
    _effectiveLanguageCode = normalized;
    _loadedFromServer = false;
    _languageOptions = const [];
    _defaultLanguageCode = normalized;
    _organizationFallbackOrder = <String>[normalized, 'en'];
    AppLocalizations.clearRuntime();

    final sp = await SharedPreferences.getInstance();
    await sp.setString(_storageKey, normalized);
    notifyListeners();
  }

  Future<bool> _updateRemotePreference({
    required String? languageCode,
    required bool includeLanguageCode,
    required bool useOrgDefault,
    required bool includeUseOrgDefault,
  }) async {
    if (!_auth.isLoggedIn) {
      return false;
    }
    final payload = <String, dynamic>{};
    if (includeLanguageCode) {
      payload['language_code'] = languageCode;
    }
    if (includeUseOrgDefault) {
      payload['use_org_default'] = useOrgDefault;
    }
    try {
      await _api.dio.patch('/localization/preferences/me', data: payload);
      return true;
    } on DioException {
      // keep client state unchanged when server write fails
      return false;
    } catch (_) {
      // keep client state unchanged when server write fails
      return false;
    }
  }

  Future<bool> _loadRuntimeFromServer(int requestVersion) async {
    try {
      final response = await _api.dio.get('/localization/runtime');
      if (requestVersion != _requestVersion) {
        return false;
      }
      final data = response.data;
      if (data is! Map) {
        return false;
      }
      _applyRuntimePayload(data.cast<String, dynamic>());
      return true;
    } on DioException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadLocalFallback(int requestVersion) async {
    final sp = await SharedPreferences.getInstance();
    if (requestVersion != _requestVersion) {
      return;
    }

    final rawCode = sp.getString(_storageKey);
    final normalized = _normalizeLanguageCode(rawCode);
    if (rawCode == null || rawCode.isEmpty || rawCode == 'system') {
      _locale = null;
      _effectiveLanguageCode = 'en';
      _defaultLanguageCode = 'en';
      _organizationFallbackOrder = const ['en'];
      _userLanguageCode = null;
    } else if (normalized == null) {
      _locale = null;
      _effectiveLanguageCode = 'en';
      _defaultLanguageCode = 'en';
      _organizationFallbackOrder = const ['en'];
      _userLanguageCode = null;
    } else {
      _locale = Locale(normalized);
      _effectiveLanguageCode = normalized;
      _defaultLanguageCode = normalized;
      _organizationFallbackOrder = <String>[normalized, 'en'];
      _userLanguageCode = normalized;
    }

    _useOrganizationDefault = false;
    _loadedFromServer = false;
    _languageOptions = const [];
    AppLocalizations.clearRuntime();
    notifyListeners();
  }

  void _applyRuntimePayload(Map<String, dynamic> payload) {
    final catalog = _asMap(payload['catalog']);
    final userPreference = _asMap(payload['user_preference']);
    final bundlesPayload = _asMap(payload['bundles']);

    final defaultLanguage =
        _normalizeLanguageCode(catalog['default_language_code']) ?? 'en';
    final organizationFallback = _normalizeLanguageCodeList(
      _asList(catalog['organization_fallback_order']),
      includeCode: defaultLanguage,
    );

    final languages = <LocalizationLanguageOption>[];
    final fallbackByLanguage = <String, List<String>>{};
    final enabledLanguageCodes = <String>[];
    final rtlCodes = <String>[];

    for (final raw in _asList(catalog['languages'])) {
      final row = _asMap(raw);
      final code = _normalizeLanguageCode(row['code']);
      if (code == null) {
        continue;
      }
      final isDefault = row['is_default'] == true || code == defaultLanguage;
      final enabled = row['enabled'] == true || isDefault;
      final isRtl = row['is_rtl'] == true;
      final fallback = _normalizeLanguageCodeList(
        _asList(row['fallback_order']),
        includeCode: code,
      );
      fallbackByLanguage[code] = fallback;
      if (enabled) {
        enabledLanguageCodes.add(code);
      }
      if (isRtl) {
        rtlCodes.add(code);
      }

      final rawName = row['name'];
      final name = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : code.toUpperCase();
      final bundleVersion = switch (row['bundle_version']) {
        int value => value,
        num value => value.toInt(),
        _ => 1,
      };

      languages.add(
        LocalizationLanguageOption(
          code: code,
          name: name,
          enabled: enabled,
          isDefault: isDefault,
          isRtl: isRtl,
          fallbackOrder: fallback,
          bundleVersion: bundleVersion,
        ),
      );
    }

    if (languages.isEmpty) {
      languages.add(
        LocalizationLanguageOption(
          code: defaultLanguage,
          name: defaultLanguage.toUpperCase(),
          enabled: true,
          isDefault: true,
          isRtl: false,
          fallbackOrder: <String>[defaultLanguage],
          bundleVersion: 1,
        ),
      );
      enabledLanguageCodes.add(defaultLanguage);
      fallbackByLanguage[defaultLanguage] = <String>[defaultLanguage];
    }

    languages.sort((a, b) {
      if (a.isDefault != b.isDefault) {
        return a.isDefault ? -1 : 1;
      }
      return a.code.compareTo(b.code);
    });

    final bundles = <String, Map<String, String>>{};
    bundlesPayload.forEach((rawCode, rawEntries) {
      final code = _normalizeLanguageCode(rawCode);
      if (code == null) {
        return;
      }
      if (rawEntries is! Map) {
        return;
      }
      final entries = <String, String>{};
      rawEntries.forEach((rawKey, rawValue) {
        if (rawKey is! String) {
          return;
        }
        final key = rawKey.trim();
        if (key.isEmpty) {
          return;
        }
        if (rawValue is String) {
          entries[key] = rawValue;
          return;
        }
        entries[key] = rawValue?.toString() ?? '';
      });
      bundles[code] = entries;
    });

    _defaultLanguageCode = defaultLanguage;
    _organizationFallbackOrder = organizationFallback;
    _languageOptions = languages;
    _loadedFromServer = true;

    _useOrganizationDefault = userPreference['use_org_default'] == true;
    _userLanguageCode = _normalizeLanguageCode(userPreference['language_code']);
    _effectiveLanguageCode =
        _normalizeLanguageCode(userPreference['effective_language_code']) ??
        defaultLanguage;
    _locale = Locale(_effectiveLanguageCode);

    AppLocalizations.configureRuntime(
      enabledLanguageCodes: enabledLanguageCodes,
      defaultLanguageCode: defaultLanguage,
      organizationFallbackOrder: organizationFallback,
      fallbackOrderByLanguage: fallbackByLanguage,
      bundles: bundles,
      rtlLanguageCodes: rtlCodes,
    );

    notifyListeners();
  }

  void _setLoading(bool value) {
    if (_loading == value) {
      return;
    }
    _loading = value;
    notifyListeners();
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return const <String, dynamic>{};
  }

  static List<dynamic> _asList(Object? value) {
    if (value is List) {
      return value;
    }
    return const <dynamic>[];
  }

  static String? _normalizeLanguageCode(Object? raw) {
    if (raw is! String) {
      return null;
    }
    final normalized = raw.trim().replaceAll('_', '-').toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    final primary = normalized.split('-').first.trim();
    if (primary.isEmpty) {
      return null;
    }
    return primary;
  }

  static List<String> _normalizeLanguageCodeList(
    List<dynamic> rawValues, {
    String? includeCode,
  }) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in rawValues) {
      final normalized = _normalizeLanguageCode(raw);
      if (normalized == null || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      out.add(normalized);
    }
    final include = _normalizeLanguageCode(includeCode);
    if (include != null && !seen.contains(include)) {
      out.insert(0, include);
    }
    return out;
  }
}
