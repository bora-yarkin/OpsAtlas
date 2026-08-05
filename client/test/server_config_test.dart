// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/api/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('normalizeConfiguredApiBaseUrl', () {
    test('adds https for normal hostnames', () {
      expect(
        normalizeConfiguredApiBaseUrl('ops.example.com'),
        'https://ops.example.com',
      );
    });

    test('adds http for localhost-style development targets', () {
      expect(
        normalizeConfiguredApiBaseUrl('localhost:8000'),
        'http://localhost:8000',
      );
      expect(
        normalizeConfiguredApiBaseUrl('192.168.1.5:8000'),
        'http://192.168.1.5:8000',
      );
    });

    test('trims trailing slashes and preserves path prefixes', () {
      expect(
        normalizeConfiguredApiBaseUrl('https://ops.example.com/root/'),
        'https://ops.example.com/root',
      );
    });

    test('rejects invalid inputs', () {
      expect(normalizeConfiguredApiBaseUrl(''), isNull);
      expect(normalizeConfiguredApiBaseUrl('nota url with spaces'), isNull);
      expect(normalizeConfiguredApiBaseUrl('ftp://ops.example.com'), isNull);
    });
  });

  test(
    'ServerConfigController persists a user-managed server domain',
    () async {
      final controller = ServerConfigController(compiledBaseUrl: '');
      await controller.load();

      await controller.setBaseUrl('ops.example.com');

      final reloaded = ServerConfigController(compiledBaseUrl: '');
      await reloaded.load();

      expect(controller.supportsUserManagedBaseUrl, isTrue);
      expect(controller.effectiveBaseUrl, 'https://ops.example.com');
      expect(reloaded.effectiveBaseUrl, 'https://ops.example.com');
      expect(reloaded.displayHost, 'ops.example.com');
    },
  );

  test('probeOpsAtlasServer validates the public branding contract', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://ops.example.com',
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
      ),
    );
    dio.httpClientAdapter = _ScriptedAdapter((request) {
      if (request.path == '/branding' && request.method == 'GET') {
        return _jsonResponse(request, 200, <String, Object>{
          'company_name': 'Acme Ops',
          'resolved_app_title': 'Acme OpsAtlas',
        });
      }
      return _jsonResponse(request, 404, <String, Object>{
        'detail': 'unexpected',
      });
    });

    final probe = await probeOpsAtlasServer('ops.example.com', client: dio);

    expect(probe.baseUrl, 'https://ops.example.com');
    expect(probe.companyName, 'Acme Ops');
    expect(probe.displayName, 'Acme Ops');
  });
}

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

  _ScriptedAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
