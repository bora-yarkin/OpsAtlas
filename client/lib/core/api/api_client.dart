// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Dio client wrapper with auth headers, refresh retry, and session recovery.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_store.dart';
import 'server_config.dart';

/// Shared API transport configured with auth-aware interceptors.
final apiClientProvider = Provider<ApiClient>((ref) {
  final auth = ref.read(authStoreProvider);
  final serverConfig = ref.watch(serverConfigProvider);
  return ApiClient(
    auth,
    configuredBaseUrl: serverConfig.effectiveBaseUrl,
    allowDefaultBaseUrl: false,
  );
});

/// Wraps Dio with OpsAtlas session handling, refresh retry, and logout fallback.
class ApiClient {
  static const _retryAfterRefreshKey = 'retry_after_refresh';
  static const _skipRefreshKey = 'skip_refresh';
  static const _withCredentialsKey = 'withCredentials';
  static const _unconfiguredRuntimeBaseUrl = 'http://127.0.0.1:1';

  final AuthStore auth;
  final String? configuredBaseUrl;
  final bool allowDefaultBaseUrl;
  late final Dio dio;
  Future<bool>? _refreshInFlight;

  ApiClient(
    this.auth, {
    this.configuredBaseUrl,
    this.allowDefaultBaseUrl = true,
  }) {
    dio = Dio(
      BaseOptions(
        baseUrl: _resolvedBaseUrl(),
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra[_withCredentialsKey] = true;
          final t = auth.token;
          if (t != null) options.headers['Authorization'] = 'Bearer $t';
          handler.next(options);
        },
        onError: (error, handler) async {
          if (_canAttemptRefresh(error)) {
            final refreshed = await _refreshAccessToken();
            if (refreshed) {
              try {
                final replay = await _retryRequest(error.requestOptions);
                handler.resolve(replay);
                return;
              } on DioException catch (replayError) {
                handler.next(replayError);
                return;
              } catch (replayError) {
                handler.next(
                  DioException(
                    requestOptions: error.requestOptions,
                    error: replayError,
                    type: DioExceptionType.unknown,
                  ),
                );
                return;
              }
            }
          }

          final statusCode = error.response?.statusCode;
          if (statusCode == 401 && auth.isLoggedIn) {
            await auth.clearSession();
          }
          handler.next(error);
        },
      ),
    );
  }

  String _resolvedBaseUrl() {
    final normalized = (configuredBaseUrl ?? '').trim();
    if (normalized.isNotEmpty) {
      return normalized;
    }
    return allowDefaultBaseUrl
        ? fallbackLocalApiBaseUrl
        : _unconfiguredRuntimeBaseUrl;
  }

  /// Determines whether a failed request is eligible for refresh-token replay.
  bool _canAttemptRefresh(DioException error) {
    if (error.response?.statusCode != 401) {
      return false;
    }
    if (!auth.hasRefreshSession) {
      return false;
    }
    final options = error.requestOptions;
    if (options.extra[_retryAfterRefreshKey] == true) {
      return false;
    }
    if (options.extra[_skipRefreshKey] == true) {
      return false;
    }
    final path = options.path;
    if (path.startsWith('/auth/login') ||
        path.startsWith('/auth/onboarding') ||
        path.startsWith('/auth/refresh')) {
      return false;
    }
    return true;
  }

  /// Coalesces concurrent refresh attempts behind a single in-flight future.
  Future<bool> _refreshAccessToken() {
    _refreshInFlight ??= _performRefresh();
    return _refreshInFlight!;
  }

  /// Rotates the current session using `/auth/refresh` and updates local auth state.
  Future<bool> _performRefresh() async {
    try {
      final refreshPayload =
          auth.usesTokenSessionTransport &&
              (auth.refreshToken ?? '').trim().isNotEmpty
          ? <String, dynamic>{'refresh_token': auth.refreshToken}
          : const <String, dynamic>{};
      final response = await dio.post(
        '/auth/refresh',
        data: refreshPayload,
        options: Options(
          extra: <String, dynamic>{
            _skipRefreshKey: true,
            _withCredentialsKey: true,
          },
        ),
      );
      final data = response.data;
      if (data is! Map) {
        return _rehydrateAuthProfile();
      }

      final payload = data.cast<String, dynamic>();
      final nextAccessToken = (payload['access_token'] ?? '').toString().trim();
      final nextRefreshToken = (payload['refresh_token'] ?? '')
          .toString()
          .trim();
      final nextSessionId = (payload['session_id'] ?? '').toString().trim();

      if (nextAccessToken.isNotEmpty) {
        if (nextRefreshToken.isNotEmpty && nextSessionId.isNotEmpty) {
          await auth.setSessionBundle(
            accessToken: nextAccessToken,
            refreshToken: nextRefreshToken,
            sessionId: nextSessionId,
          );
        } else {
          await auth.setToken(nextAccessToken);
        }
        return true;
      }
      return _rehydrateAuthProfile();
    } on DioException {
      await auth.clearSession();
      return false;
    } catch (_) {
      await auth.clearSession();
      return false;
    } finally {
      _refreshInFlight = null;
    }
  }

  /// Rebuilds lightweight auth state from `/auth/me` when only cookies survive.
  Future<bool> _rehydrateAuthProfile() async {
    try {
      final response = await dio.get(
        '/auth/me',
        options: Options(
          extra: <String, dynamic>{
            _skipRefreshKey: true,
            _withCredentialsKey: true,
          },
        ),
      );
      final data = response.data;
      if (data is! Map) {
        await auth.clearSession();
        return false;
      }
      final payload = data.cast<String, dynamic>();
      auth.setRoleFromProfile((payload['global_role'] ?? '').toString());
      return true;
    } on DioException {
      await auth.clearSession();
      return false;
    } catch (_) {
      await auth.clearSession();
      return false;
    }
  }

  /// Replays the original request once a refresh succeeds.
  Future<Response<dynamic>> _retryRequest(RequestOptions options) {
    final replayExtra = Map<String, dynamic>.from(options.extra)
      ..[_retryAfterRefreshKey] = true;
    return dio.request<dynamic>(
      options.path,
      data: options.data,
      queryParameters: options.queryParameters,
      cancelToken: options.cancelToken,
      onReceiveProgress: options.onReceiveProgress,
      onSendProgress: options.onSendProgress,
      options: Options(
        method: options.method,
        headers: Map<String, dynamic>.from(options.headers),
        extra: replayExtra,
        contentType: options.contentType,
        responseType: options.responseType,
        sendTimeout: options.sendTimeout,
        receiveTimeout: options.receiveTimeout,
        followRedirects: options.followRedirects,
        validateStatus: options.validateStatus,
        receiveDataWhenStatusError: options.receiveDataWhenStatusError,
        listFormat: options.listFormat,
        maxRedirects: options.maxRedirects,
      ),
    );
  }
}
