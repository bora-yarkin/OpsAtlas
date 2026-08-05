// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Platform switch for clean web URL strategy helpers.

import 'url_strategy_stub.dart' if (dart.library.html) 'url_strategy_web.dart';

void configureUrlStrategy() {
  applyUrlStrategy();
}
