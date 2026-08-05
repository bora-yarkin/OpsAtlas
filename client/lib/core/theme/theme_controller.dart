// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Theme mode controller with persisted light and dark preference state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

final themeControllerProvider = ChangeNotifierProvider<ThemeController>((ref) {
  return ThemeController()..load();
});

class ThemeController extends ChangeNotifier {
  ThemeMode mode = ThemeMode.system;

  bool get isDark => mode == ThemeMode.dark;

  ThemeMode resolvedMode(Brightness platformBrightness) {
    if (mode != ThemeMode.system) {
      return mode;
    }
    return platformBrightness == Brightness.dark
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  bool isDarkFor(Brightness platformBrightness) {
    return resolvedMode(platformBrightness) == ThemeMode.dark;
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('theme_mode');
    mode = switch (raw) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode next) async {
    mode = next;
    final sp = await SharedPreferences.getInstance();
    final raw = switch (next) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    };
    await sp.setString('theme_mode', raw);
    notifyListeners();
  }

  Future<void> toggleLightDark() async {
    await setMode(mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  Future<void> toggleLightDarkFor(Brightness platformBrightness) async {
    await setMode(
      isDarkFor(platformBrightness) ? ThemeMode.light : ThemeMode.dark,
    );
  }
}
