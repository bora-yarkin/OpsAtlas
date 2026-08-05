// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Web implementation for synchronizing document title and branding metadata.

// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

String? _lastTitle;
String? _lastFaviconUrl;
String? _lastDescription;
String? _lastAppleTitle;
String? _lastThemeColorHex;
String? _lastManifestUrl;
String? _lastAppleTouchIconUrl;

void applyBrowserBranding({
  required String title,
  String? faviconUrl,
  String? description,
  String? appleWebAppTitle,
  String? themeColorHex,
  String? manifestUrl,
  String? appleTouchIconUrl,
}) {
  if (_lastTitle != title) {
    html.document.title = title;
    _lastTitle = title;
  }

  final normalizedDescription = _normalizedValue(description);
  if (_lastDescription != normalizedDescription) {
    _ensureMetaTag(name: 'description').content =
        normalizedDescription ??
        'OpsAtlas is a self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work.';
    _lastDescription = normalizedDescription;
  }

  final normalizedAppleTitle = _normalizedValue(appleWebAppTitle) ?? title;
  if (_lastAppleTitle != normalizedAppleTitle) {
    _ensureMetaTag(name: 'apple-mobile-web-app-title').content =
        normalizedAppleTitle;
    _lastAppleTitle = normalizedAppleTitle;
  }

  final normalizedThemeColor = _normalizedValue(themeColorHex);
  if (_lastThemeColorHex != normalizedThemeColor) {
    _ensureMetaTag(name: 'theme-color').content =
        normalizedThemeColor ?? '#0F67E8';
    _lastThemeColorHex = normalizedThemeColor;
  }

  final normalizedUrl = _normalizedUrl(faviconUrl);
  if (_lastFaviconUrl != normalizedUrl) {
    final link = _ensureFaviconLink();
    if (normalizedUrl == null) {
      link.href = 'favicon.png';
      link.type = 'image/png';
    } else {
      link.href = normalizedUrl;
      final mimeType = _faviconMimeType(normalizedUrl);
      if (mimeType == null) {
        link.attributes.remove('type');
      } else {
        link.type = mimeType;
      }
    }
    _lastFaviconUrl = normalizedUrl;
  }

  final normalizedManifestUrl = _normalizedValue(manifestUrl);
  if (_lastManifestUrl != normalizedManifestUrl) {
    _ensureManifestLink().href =
        normalizedManifestUrl ?? '/branding/manifest.webmanifest';
    _lastManifestUrl = normalizedManifestUrl;
  }

  final normalizedAppleTouchIcon =
      _normalizedValue(appleTouchIconUrl) ?? normalizedUrl;
  if (_lastAppleTouchIconUrl != normalizedAppleTouchIcon) {
    _ensureAppleTouchIconLink().href =
        normalizedAppleTouchIcon ?? 'icons/Icon-192.png';
    _lastAppleTouchIconUrl = normalizedAppleTouchIcon;
  }
}

html.LinkElement _ensureFaviconLink() {
  final existing = html.document.head?.querySelector('link[rel~="icon"]');
  if (existing is html.LinkElement) {
    existing.rel = 'icon';
    return existing;
  }

  final link = html.LinkElement()
    ..rel = 'icon'
    ..href = 'favicon.png'
    ..type = 'image/png';
  html.document.head?.append(link);
  return link;
}

html.LinkElement _ensureManifestLink() {
  final existing = html.document.head?.querySelector('link[rel="manifest"]');
  if (existing is html.LinkElement) {
    existing.rel = 'manifest';
    return existing;
  }
  final link = html.LinkElement()
    ..rel = 'manifest'
    ..href = '/branding/manifest.webmanifest';
  html.document.head?.append(link);
  return link;
}

html.LinkElement _ensureAppleTouchIconLink() {
  final existing = html.document.head?.querySelector(
    'link[rel="apple-touch-icon"]',
  );
  if (existing is html.LinkElement) {
    existing.rel = 'apple-touch-icon';
    return existing;
  }
  final link = html.LinkElement()
    ..rel = 'apple-touch-icon'
    ..href = 'icons/Icon-192.png';
  html.document.head?.append(link);
  return link;
}

html.MetaElement _ensureMetaTag({required String name}) {
  final existing = html.document.head?.querySelector('meta[name="$name"]');
  if (existing is html.MetaElement) {
    existing.name = name;
    return existing;
  }
  final meta = html.MetaElement()..name = name;
  html.document.head?.append(meta);
  return meta;
}

String? _normalizedUrl(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _normalizedValue(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _faviconMimeType(String url) {
  final uri = Uri.tryParse(url);
  final path = (uri?.path ?? url).trim().toLowerCase();
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.ico')) return 'image/x-icon';
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
  if (path.endsWith('.gif')) return 'image/gif';
  if (path.endsWith('.webp')) return 'image/webp';
  return null;
}
