// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Frontend session store that bridges cookie and token-based auth transport.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_config.dart';

final authStoreProvider = ChangeNotifierProvider<AuthStore>(
  (ref) => AuthStore(
    serverConfig: ref.read(serverConfigProvider),
    allowDefaultBaseUrl: false,
  )..load(),
);

/// Stores the current frontend auth/session model across cookie and token flows.
class AuthStore extends ChangeNotifier {
  final ServerConfigController? _serverConfig;
  final bool _allowDefaultBaseUrl;

  AuthStore({
    ServerConfigController? serverConfig,
    bool allowDefaultBaseUrl = true,
  }) : _serverConfig = serverConfig,
       _allowDefaultBaseUrl = allowDefaultBaseUrl;

  static const _tokenKey = 'token';
  static const _refreshTokenKey = 'refresh_token';
  static const _sessionIdKey = 'session_id';

  // Keep this field for compatibility with existing call sites, but avoid
  // storing bearer tokens in JS-readable state for web sessions.
  String? token;
  String? refreshToken;
  String? sessionId;
  String? role;
  bool mfaVerified = false;
  bool hasCookieSession = false;
  bool loaded = false;

  /// Web prefers cookie-backed sessions while non-web keeps token bundles.
  bool get usesCookieSessionTransport => kIsWeb;
  bool get usesTokenSessionTransport => !usesCookieSessionTransport;

  /// True when enough session material exists to attempt refresh or probing.
  bool get hasRefreshSession =>
      usesTokenSessionTransport ? _hasStoredTokenSession : hasCookieSession;

  /// Whether the app should treat the current user as authenticated.
  bool get isLoggedIn =>
      usesTokenSessionTransport ? _hasUsableSession : hasCookieSession;
  bool get isAdmin => role == 'admin';
  bool get isModerator => role == 'moderator';
  bool get isAdminLike => role == 'admin' || role == 'moderator';
  bool get canEditAnySpaceContent => isAdminLike;
  bool get canViewAnalytics => isAdminLike;
  bool get canManageUsersAndSpaces => isAdmin;
  bool get canViewBackups => isAdminLike;
  bool get canCreateBackups => isAdmin;
  bool get canRunSensitiveAdminActions => isAdminLike && mfaVerified;

  /// Hydrates session state from storage or cookie-backed backend probes.
  Future<void> load() async {
    await _serverConfig?.ensureLoaded();
    if (usesTokenSessionTransport) {
      await _hydrateFromPersistedTokenSession();
    } else {
      await _clearPersistedSession();
      await _hydrateFromCookieSession();
    }
    loaded = true;
    notifyListeners();
  }

  /// Stores a single access token, extracting role and MFA claims when present.
  Future<void> setToken(String? t) async {
    if (t == null || t.trim().isEmpty) {
      await clearSession();
      return;
    }

    final nextToken = t.trim();
    if (!_isUsableToken(nextToken)) {
      await clearSession();
      return;
    }

    token = usesTokenSessionTransport ? nextToken : null;
    role = _extractRole(nextToken);
    mfaVerified = _extractMfaVerified(nextToken);
    refreshToken = usesTokenSessionTransport
        ? _normalizedSessionValue(refreshToken)
        : null;
    sessionId = usesTokenSessionTransport
        ? _normalizedSessionValue(sessionId)
        : null;
    hasCookieSession = usesCookieSessionTransport;
    await _persistTokenSession();
    loaded = true;
    notifyListeners();
  }

  /// Stores the access token plus refresh/session identifiers for token flows.
  Future<void> setSessionBundle({
    required String accessToken,
    required String refreshToken,
    required String sessionId,
  }) async {
    final nextAccessToken = accessToken.trim();
    if (!_isUsableToken(nextAccessToken)) {
      await clearSession();
      return;
    }

    token = usesTokenSessionTransport ? nextAccessToken : null;
    role = _extractRole(nextAccessToken);
    mfaVerified = _extractMfaVerified(nextAccessToken);
    this.refreshToken = usesTokenSessionTransport
        ? _normalizedSessionValue(refreshToken)
        : null;
    this.sessionId = usesTokenSessionTransport
        ? _normalizedSessionValue(sessionId)
        : null;
    hasCookieSession = usesCookieSessionTransport;
    await _persistTokenSession();
    loaded = true;
    notifyListeners();
  }

  /// Updates role information from `/auth/me` when a cookie session is active.
  void setRoleFromProfile(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return;
    }
    final changedRole = role != normalized;
    final changedSession = !hasCookieSession;
    if (!changedRole && !changedSession) {
      return;
    }
    role = normalized;
    hasCookieSession = true;
    notifyListeners();
  }

  /// Clears every local auth artifact and notifies listeners.
  Future<void> clearSession() async {
    _resetState();
    await _clearPersistedSession();
    loaded = true;
    notifyListeners();
  }

  void _resetState() {
    token = null;
    refreshToken = null;
    sessionId = null;
    role = null;
    mfaVerified = false;
    hasCookieSession = false;
  }

  bool get _hasStoredTokenSession =>
      _normalizedSessionValue(refreshToken) != null &&
      _normalizedSessionValue(sessionId) != null;

  bool get _hasUsableSession => _isUsableToken(token) || _hasStoredTokenSession;

  Future<void> _clearPersisted(SharedPreferences sp) async {
    await sp.remove(_tokenKey);
    await sp.remove(_refreshTokenKey);
    await sp.remove(_sessionIdKey);
  }

  Future<void> _clearPersistedSession() async {
    final sp = await SharedPreferences.getInstance();
    await _clearPersisted(sp);
  }

  Future<void> _persistTokenSession() async {
    if (!usesTokenSessionTransport) {
      return;
    }
    final sp = await SharedPreferences.getInstance();
    await _persistTokenValue(
      sp,
      _tokenKey,
      _isUsableToken(token) ? token : null,
    );
    await _persistTokenValue(sp, _refreshTokenKey, refreshToken);
    await _persistTokenValue(sp, _sessionIdKey, sessionId);
  }

  Future<void> _persistTokenValue(
    SharedPreferences sp,
    String key,
    String? value,
  ) async {
    final normalized = _normalizedSessionValue(value);
    if (normalized == null) {
      await sp.remove(key);
      return;
    }
    await sp.setString(key, normalized);
  }

  Future<void> _hydrateFromPersistedTokenSession() async {
    final sp = await SharedPreferences.getInstance();
    token = _normalizedSessionValue(sp.getString(_tokenKey));
    refreshToken = _normalizedSessionValue(sp.getString(_refreshTokenKey));
    sessionId = _normalizedSessionValue(sp.getString(_sessionIdKey));

    if (_isUsableToken(token)) {
      role = _extractRole(token);
      mfaVerified = _extractMfaVerified(token);
      hasCookieSession = false;
      return;
    }

    token = null;
    if (await _refreshPersistedTokenSession()) {
      return;
    }

    _resetState();
    await _clearPersistedSession();
  }

  /// Uses persisted refresh material to recover a valid access token on startup.
  Future<bool> _refreshPersistedTokenSession() async {
    if (!_hasStoredTokenSession) {
      return false;
    }
    final baseUrl = _resolvedApiBaseUrl();
    if (baseUrl == null) {
      return false;
    }

    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );

    try {
      final response = await dio.post(
        '/auth/refresh',
        data: <String, dynamic>{'refresh_token': refreshToken},
        options: Options(
          validateStatus: (status) =>
              status != null && status >= 200 && status < 500,
        ),
      );
      final data = response.data;
      if (response.statusCode != 200 || data is! Map) {
        return false;
      }

      final payload = data.cast<String, dynamic>();
      final nextAccessToken = (payload['access_token'] ?? '').toString().trim();
      if (!_isUsableToken(nextAccessToken)) {
        return false;
      }

      token = nextAccessToken;
      refreshToken =
          _normalizedSessionValue(payload['refresh_token']) ?? refreshToken;
      sessionId = _normalizedSessionValue(payload['session_id']) ?? sessionId;
      role = _extractRole(nextAccessToken);
      mfaVerified = _extractMfaVerified(nextAccessToken);
      hasCookieSession = false;
      await _persistTokenSession();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Probes cookie-backed auth state for browsers where JS should not keep JWTs.
  Future<void> _hydrateFromCookieSession() async {
    final baseUrl = _resolvedApiBaseUrl();
    if (baseUrl == null) {
      _resetState();
      return;
    }
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );

    try {
      final refreshResponse = await dio.post(
        '/auth/refresh',
        data: const <String, dynamic>{},
        options: _cookieOptions(),
      );
      final refreshed = _applySessionPayload(refreshResponse.data);
      if (refreshed) {
        return;
      }
    } catch (_) {
      // Fall through to /auth/me probe.
    }

    try {
      final meResponse = await dio.get('/auth/me', options: _cookieOptions());
      final data = meResponse.data;
      if (meResponse.statusCode == 200 && data is Map) {
        final payload = data.cast<String, dynamic>();
        final userId = (payload['id'] ?? '').toString().trim();
        if (userId.isEmpty) {
          throw StateError('Missing user id in /auth/me response');
        }
        final nextRole = (payload['global_role'] ?? '').toString().trim();
        if (nextRole.isNotEmpty) {
          role = nextRole.toLowerCase();
        }
        mfaVerified = false;
        token = null;
        refreshToken = null;
        sessionId = null;
        hasCookieSession = true;
        return;
      }
    } catch (_) {
      // Not authenticated.
    }

    _resetState();
  }

  /// Reads a login or refresh payload and converts it into frontend session state.
  bool _applySessionPayload(Object? rawPayload) {
    if (rawPayload is! Map) {
      return false;
    }
    final payload = rawPayload.cast<String, dynamic>();
    final accessToken = (payload['access_token'] ?? '').toString().trim();
    if (!_isUsableToken(accessToken)) {
      return false;
    }

    token = null;
    role = _extractRole(accessToken);
    mfaVerified = _extractMfaVerified(accessToken);
    refreshToken = null;
    sessionId = null;
    hasCookieSession = true;
    return true;
  }

  Options _cookieOptions() {
    return Options(
      extra: <String, dynamic>{'withCredentials': true},
      validateStatus: (status) =>
          status != null && status >= 200 && status < 500,
    );
  }

  String? _resolvedApiBaseUrl() {
    final configured = _normalizedSessionValue(_serverConfig?.effectiveBaseUrl);
    if (configured != null) {
      return configured;
    }
    return _allowDefaultBaseUrl ? fallbackLocalApiBaseUrl : null;
  }

  String? _normalizedSessionValue(Object? raw) {
    final value = (raw ?? '').toString().trim();
    return value.isEmpty ? null : value;
  }

  bool _isUsableToken(String? jwt) {
    if (jwt == null || jwt.isEmpty) return false;
    final payload = _decodePayload(jwt);
    if (payload == null) return false;
    final exp = payload['exp'];
    if (exp is int) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (exp <= nowSeconds) return false;
    }
    if (exp is num) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (exp.toInt() <= nowSeconds) return false;
    }
    return true;
  }

  /// Decodes the middle JWT payload segment without verifying the signature.
  Map<String, dynamic>? _decodePayload(String? jwt) {
    if (jwt == null || jwt.isEmpty) return null;
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is Map) {
        return payload.cast<String, dynamic>();
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Extracts the backend role claim from an access token payload.
  String? _extractRole(String? jwt) {
    final payload = _decodePayload(jwt);
    if (payload == null) return null;
    if (payload['role'] is String) return payload['role'] as String;
    return null;
  }

  /// Extracts the `mfa` claim used for sensitive admin gating in the UI.
  bool _extractMfaVerified(String? jwt) {
    final payload = _decodePayload(jwt);
    if (payload == null) return false;
    final raw = payload['mfa'];
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final normalized = raw.trim().toLowerCase();
      return normalized == '1' || normalized == 'true' || normalized == 'yes';
    }
    return false;
  }
}
