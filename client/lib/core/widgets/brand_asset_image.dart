// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Brand-aware image widgets for logos, icons, and themed assets.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class BrandAssetImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final Widget fallback;

  const BrandAssetImage({
    super.key,
    required this.url,
    required this.fit,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedUrl = _normalizedUrl(url);
    if (resolvedUrl == null) {
      return fallback;
    }
    if (_isSvgUrl(resolvedUrl)) {
      return SvgPicture.network(
        resolvedUrl,
        fit: fit,
        placeholderBuilder: (_) => fallback,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return Image.network(
      resolvedUrl,
      fit: fit,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

String? _normalizedUrl(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _isSvgUrl(String url) {
  final uri = Uri.tryParse(url);
  final filename = uri?.queryParameters['filename']?.trim().toLowerCase();
  if (filename != null && filename.endsWith('.svg')) {
    return true;
  }
  final path = (uri?.path ?? url).trim().toLowerCase();
  return path.endsWith('.svg');
}
