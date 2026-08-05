// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/api/api_client.dart';
import 'package:opsatlas_client/core/api/auth_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthStore session contract', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('extracts role and MFA claims from a usable access token', () async {
      final auth = AuthStore();

      await auth.setToken(_jwt(role: 'admin', mfa: true));

      expect(auth.isLoggedIn, isTrue);
      expect(auth.isAdmin, isTrue);
      expect(auth.isAdminLike, isTrue);
      expect(auth.canViewAnalytics, isTrue);
      expect(auth.canRunSensitiveAdminActions, isTrue);
    });

    test('rejects expired or malformed access tokens', () async {
      final auth = AuthStore();

      await auth.setToken(_jwt(role: 'moderator', expiresInSeconds: -5));
      expect(auth.isLoggedIn, isFalse);
      expect(auth.role, isNull);

      await auth.setToken('not-a-jwt');
      expect(auth.isLoggedIn, isFalse);
      expect(auth.role, isNull);
    });

    test('persists a token session bundle and reloads it from storage', () async {
      final auth = AuthStore();
      final token = _jwt(role: 'moderator', mfa: true);

      await auth.setSessionBundle(
        accessToken: token,
        refreshToken: 'refresh-token-1',
        sessionId: 'session-1',
      );

      final reloaded = AuthStore();
      await reloaded.load();

      expect(reloaded.isLoggedIn, isTrue);
      expect(reloaded.role, 'moderator');
      expect(reloaded.mfaVerified, isTrue);
      expect(reloaded.refreshToken, 'refresh-token-1');
      expect(reloaded.sessionId, 'session-1');
    });

    test('clearSession removes persisted token material', () async {
      final auth = AuthStore();
      await auth.setSessionBundle(
        accessToken: _jwt(role: 'admin', mfa: true),
        refreshToken: 'refresh-token-1',
        sessionId: 'session-1',
      );

      await auth.clearSession();

      final reloaded = AuthStore();
      await reloaded.load();

      expect(auth.isLoggedIn, isFalse);
      expect(reloaded.isLoggedIn, isFalse);
      expect(reloaded.role, isNull);
      expect(reloaded.refreshToken, isNull);
      expect(reloaded.sessionId, isNull);
    });

    test('setRoleFromProfile promotes cookie-backed profile state safely', () async {
      final auth = AuthStore()..loaded = true;

      auth.setRoleFromProfile(' moderator ');

      expect(auth.role, 'moderator');
      expect(auth.hasCookieSession, isTrue);
      expect(auth.isAdminLike, isTrue);
      expect(auth.canViewAnalytics, isTrue);
    });

    test('invalid session bundle clears any previously persisted session', () async {
      final auth = AuthStore();
      await auth.setSessionBundle(
        accessToken: _jwt(role: 'member'),
        refreshToken: 'refresh-token-1',
        sessionId: 'session-1',
      );

      await auth.setSessionBundle(
        accessToken: 'not-a-jwt',
        refreshToken: 'refresh-token-2',
        sessionId: 'session-2',
      );

      final reloaded = AuthStore();
      await reloaded.load();

      expect(auth.isLoggedIn, isFalse);
      expect(reloaded.isLoggedIn, isFalse);
      expect(reloaded.refreshToken, isNull);
      expect(reloaded.sessionId, isNull);
    });
  });

  group('ApiClient refresh contract', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('refreshes once and replays a protected request with the new token', () async {
      final auth = AuthStore();
      final originalAccessToken = _jwt(role: 'member');
      final refreshedAccessToken = _jwt(role: 'moderator');
      await auth.setSessionBundle(
        accessToken: originalAccessToken,
        refreshToken: 'refresh-token',
        sessionId: 'session-1',
      );

      final api = ApiClient(auth);
      final adapter = _ScriptedAdapter((request) {
        if (request.path == '/secure' && request.method == 'GET') {
          final authorization = request.headers['Authorization']?.toString();
          if (authorization == 'Bearer $originalAccessToken') {
            return _jsonResponse(request, 401, <String, Object>{'detail': 'expired'});
          }
          return _jsonResponse(
            request,
            200,
            <String, Object>{'ok': true, 'authorization': authorization ?? ''},
          );
        }
        if (request.path == '/auth/refresh' && request.method == 'POST') {
          return _jsonResponse(
            request,
            200,
            <String, Object>{
              'access_token': refreshedAccessToken,
              'refresh_token': 'refresh-token-2',
              'session_id': 'session-2',
            },
          );
        }
        return _jsonResponse(request, 404, <String, Object>{'detail': 'unexpected'});
      });
      api.dio.httpClientAdapter = adapter;

      final response = await api.dio.get('/secure');

      expect(response.statusCode, 200);
      expect(response.data, containsPair('ok', true));
      expect(response.data, containsPair('authorization', 'Bearer $refreshedAccessToken'));
      expect(auth.role, 'moderator');
      expect(auth.refreshToken, 'refresh-token-2');
      expect(auth.sessionId, 'session-2');
      expect(adapter.requests.map((request) => '${request.method} ${request.path}'), <String>[
        'GET /secure',
        'POST /auth/refresh',
        'GET /secure',
      ]);
    });

    test('clears local session when refresh fails', () async {
      final auth = AuthStore();
      await auth.setSessionBundle(
        accessToken: _jwt(role: 'member'),
        refreshToken: 'refresh-token',
        sessionId: 'session-1',
      );

      final api = ApiClient(auth);
      api.dio.httpClientAdapter = _ScriptedAdapter((request) {
        if (request.path == '/auth/refresh') {
          return _jsonResponse(request, 401, <String, Object>{'detail': 'invalid refresh'});
        }
        return _jsonResponse(request, 401, <String, Object>{'detail': 'expired'});
      });

      await expectLater(api.dio.get('/secure'), throwsA(isA<DioException>()));
      expect(auth.isLoggedIn, isFalse);
      expect(auth.role, isNull);
      expect(auth.refreshToken, isNull);
    });
  });
}

String _jwt({
  required String role,
  bool mfa = false,
  int expiresInSeconds = 3600,
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final header = _base64Json(<String, Object>{'alg': 'none', 'typ': 'JWT'});
  final payload = _base64Json(<String, Object>{
    'sub': 'user-1',
    'role': role,
    'mfa': mfa,
    'iat': now,
    'exp': now + expiresInSeconds,
  });
  return '$header.$payload.';
}

String _base64Json(Map<String, Object> payload) => base64Url
    .encode(utf8.encode(jsonEncode(payload)))
    .replaceAll('=', '');

ResponseBody _jsonResponse(
  RequestOptions request,
  int statusCode,
  Map<String, Object> payload,
) {
  return ResponseBody.fromString(
    jsonEncode(payload),
    statusCode,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    },
  );
}

class _ScriptedAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions request) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  _ScriptedAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
