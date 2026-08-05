// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Flutter entrypoint for the OpsAtlas client application.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'core/web/url_strategy.dart';

/// Boots the Flutter app after configuring clean URL handling for web routes.
void main() {
  configureUrlStrategy();
  runApp(const ProviderScope(child: App()));
}
