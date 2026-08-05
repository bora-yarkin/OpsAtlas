// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/api/api_client.dart';
import 'package:opsatlas_client/core/api/auth_store.dart';
import 'package:opsatlas_client/core/i18n/app_localizations.dart';
import 'package:opsatlas_client/core/widgets/media_upload_section.dart';

void main() {
  testWidgets(
    'loads after inherited localizations are available',
    (tester) async {
      final apiClient = ApiClient(AuthStore());
      apiClient.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                data: const <dynamic>[],
              ),
            );
          },
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWith((ref) => apiClient)],
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(
              body: MediaUploadSection(
                title: 'Uploads',
                usage: 'sop_attachment',
                spaceId: 'space-1',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Uploads'), findsOneWidget);
    },
  );
}