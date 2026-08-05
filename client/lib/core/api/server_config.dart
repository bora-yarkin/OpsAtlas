// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Runtime API-base configuration for self-hosted mobile app deployments.

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String fallbackLocalApiBaseUrl = 'http://localhost:8000';
const String _compiledApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

final serverConfigProvider = ChangeNotifierProvider<ServerConfigController>((
  ref,
) {
  return ServerConfigController()..load();
});

/// Result of probing a candidate OpsAtlas deployment before login begins.
class OpsAtlasServerProbe {
  final String baseUrl;
  final String? companyName;
  final String appTitle;

  const OpsAtlasServerProbe({
    required this.baseUrl,
    this.companyName,
    required this.appTitle,
  });

  String get displayName =>
      companyName?.trim().isNotEmpty == true ? companyName!.trim() : appTitle;
}

/// Persists the user-selected server base URL for generalized mobile builds.
class ServerConfigController extends ChangeNotifier {
  static const _prefsKey = 'opsatlas_runtime_api_base_url_v1';

  final Future<SharedPreferences> Function() _sharedPreferencesLoader;
  final String _compiledBaseUrlValue;
  Future<void>? _loadFuture;

  bool loaded = false;
  String? _storedBaseUrl;

  ServerConfigController({
    Future<SharedPreferences> Function()? sharedPreferencesLoader,
    String compiledBaseUrl = _compiledApiBaseUrl,
  }) : _sharedPreferencesLoader =
           sharedPreferencesLoader ?? SharedPreferences.getInstance,
       _compiledBaseUrlValue = compiledBaseUrl;

  String? get compiledBaseUrl =>
      normalizeConfiguredApiBaseUrl(_compiledBaseUrlValue);

  bool get supportsUserManagedBaseUrl => !kIsWeb && compiledBaseUrl == null;

  String? get effectiveBaseUrl =>
      compiledBaseUrl ??
      _storedBaseUrl ??
      (kIsWeb ? fallbackLocalApiBaseUrl : null);

  String? get storedBaseUrl => _storedBaseUrl;

  String? get displayHost {
    final uri = Uri.tryParse(effectiveBaseUrl ?? '');
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    if (uri.hasPort) {
      return '${uri.host}:${uri.port}';
    }
    return uri.host;
  }

  /// Loads persisted server state once for the current app lifecycle.
  Future<void> load() {
    if (loaded) {
      return _loadFuture ?? Future<void>.value();
    }
    return _loadFuture ??= _loadImpl();
  }

  /// Awaits the initial load when dependent stores need the base URL first.
  Future<void> ensureLoaded() => load();

  Future<void> _loadImpl() async {
    if (supportsUserManagedBaseUrl) {
      final prefs = await _sharedPreferencesLoader();
      _storedBaseUrl = normalizeConfiguredApiBaseUrl(
        prefs.getString(_prefsKey) ?? '',
      );
    }
    loaded = true;
    notifyListeners();
  }

  /// Stores the validated base URL chosen by the user.
  Future<void> setBaseUrl(String raw) async {
    final normalized = normalizeConfiguredApiBaseUrl(raw);
    if (normalized == null) {
      throw const FormatException('Invalid OpsAtlas base URL');
    }
    if (!supportsUserManagedBaseUrl) {
      return;
    }
    _storedBaseUrl = normalized;
    final prefs = await _sharedPreferencesLoader();
    await prefs.setString(_prefsKey, normalized);
    loaded = true;
    notifyListeners();
  }

  /// Removes the persisted user-managed base URL.
  Future<void> clearStoredBaseUrl() async {
    if (!supportsUserManagedBaseUrl) {
      return;
    }
    _storedBaseUrl = null;
    final prefs = await _sharedPreferencesLoader();
    await prefs.remove(_prefsKey);
    loaded = true;
    notifyListeners();
  }
}

/// Normalizes a user-entered domain or URL into a stable API base URL.
String? normalizeConfiguredApiBaseUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final withScheme = trimmed.contains('://')
      ? trimmed
      : '${_defaultSchemeForCandidate(trimmed)}://$trimmed';
  final parsed = Uri.tryParse(withScheme);
  if (parsed == null || parsed.host.trim().isEmpty) {
    return null;
  }
  if (parsed.host.contains(RegExp(r'[%\s]'))) {
    return null;
  }

  final scheme = parsed.scheme.trim().toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return null;
  }

  final normalizedPathSegments = parsed.pathSegments
      .where((segment) => segment.trim().isNotEmpty)
      .toList(growable: false);
  final normalized = Uri(
    scheme: scheme,
    userInfo: parsed.userInfo,
    host: parsed.host.trim(),
    port: parsed.hasPort ? parsed.port : null,
    pathSegments: normalizedPathSegments.isEmpty
        ? const <String>[]
        : normalizedPathSegments,
  );
  final asString = normalized.toString();
  return asString.endsWith('/')
      ? asString.substring(0, asString.length - 1)
      : asString;
}

/// Resolves relative API asset paths against the currently selected backend.
String? resolveApiAssetUrl(String? apiBaseUrl, Object? value) {
  final raw = _trimmed(value);
  if (raw == null) {
    return null;
  }

  final parsed = Uri.tryParse(raw);
  if (parsed != null && parsed.hasScheme) {
    return raw;
  }

  final base = Uri.tryParse(apiBaseUrl ?? '');
  if (base == null || !base.hasScheme || base.host.isEmpty) {
    return raw;
  }

  try {
    return base.resolveUri(Uri.parse(raw)).toString();
  } catch (_) {
    return raw;
  }
}

/// Probes a candidate domain to confirm it serves an OpsAtlas backend.
Future<OpsAtlasServerProbe> probeOpsAtlasServer(
  String raw, {
  Dio? client,
}) async {
  final normalized = normalizeConfiguredApiBaseUrl(raw);
  if (normalized == null) {
    throw const FormatException('Invalid OpsAtlas base URL');
  }

  final dio =
      client ??
      Dio(
        BaseOptions(
          baseUrl: normalized,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
          validateStatus: (status) =>
              status != null && status >= 200 && status < 500,
        ),
      );

  final brandingResponse = await dio.get('/branding');
  final data = brandingResponse.data;
  if (brandingResponse.statusCode != 200 || data is! Map) {
    throw DioException(
      requestOptions: brandingResponse.requestOptions,
      response: brandingResponse,
      type: DioExceptionType.badResponse,
      error: 'OpsAtlas branding endpoint unavailable',
    );
  }

  final payload = data.cast<String, dynamic>();
  final appTitle =
      _trimmed(payload['resolved_app_title']) ??
      _trimmed(payload['application_title']) ??
      _trimmed(payload['company_name']) ??
      'OpsAtlas';

  return OpsAtlasServerProbe(
    baseUrl: normalized,
    companyName: _trimmed(payload['company_name']),
    appTitle: appTitle,
  );
}

String? _trimmed(Object? value) {
  if (value == null) {
    return null;
  }
  final normalized = value.toString().trim();
  return normalized.isEmpty ? null : normalized;
}

String _defaultSchemeForCandidate(String raw) {
  final hostCandidate = raw.split('/').first.trim();
  if (_looksLikeLocalOrLanHost(hostCandidate)) {
    return 'http';
  }
  return 'https';
}

bool _looksLikeLocalOrLanHost(String raw) {
  final normalized = raw.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }
  final host = normalized.startsWith('[') && normalized.endsWith(']')
      ? normalized.substring(1, normalized.length - 1)
      : normalized.split(':').first;
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return true;
  }
  final match = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
  ).firstMatch(host);
  if (match == null) {
    return false;
  }
  final octets = <int>[
    for (var i = 1; i <= 4; i += 1) int.parse(match.group(i)!),
  ];
  if (octets.any((value) => value < 0 || value > 255)) {
    return false;
  }
  if (octets[0] == 10 || octets[0] == 127) {
    return true;
  }
  if (octets[0] == 192 && octets[1] == 168) {
    return true;
  }
  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) {
    return true;
  }
  return false;
}
