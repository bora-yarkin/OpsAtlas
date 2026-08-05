// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared browser-branding facade used by the root application widget.

import 'browser_branding_stub.dart'
    if (dart.library.html) 'browser_branding_web.dart';

void syncBrowserBranding({
  required String title,
  String? faviconUrl,
  String? description,
  String? appleWebAppTitle,
  String? themeColorHex,
  String? manifestUrl,
  String? appleTouchIconUrl,
}) {
  applyBrowserBranding(
    title: title,
    faviconUrl: faviconUrl,
    description: description,
    appleWebAppTitle: appleWebAppTitle,
    themeColorHex: themeColorHex,
    manifestUrl: manifestUrl,
    appleTouchIconUrl: appleTouchIconUrl,
  );
}
