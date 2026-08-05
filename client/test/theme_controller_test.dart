// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opsatlas_client/core/theme/theme_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('system dark resolves as dark for UI decisions', () {
    final controller = ThemeController()..mode = ThemeMode.system;

    expect(controller.isDarkFor(Brightness.dark), isTrue);
    expect(controller.isDarkFor(Brightness.light), isFalse);
  });

  test('toggle from system dark switches directly to light', () async {
    final controller = ThemeController()..mode = ThemeMode.system;

    await controller.toggleLightDarkFor(Brightness.dark);

    expect(controller.mode, ThemeMode.light);
  });

  test('toggle from system light switches directly to dark', () async {
    final controller = ThemeController()..mode = ThemeMode.system;

    await controller.toggleLightDarkFor(Brightness.light);

    expect(controller.mode, ThemeMode.dark);
  });
}
