// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Platform switch for file download helpers.

import 'file_download_stub.dart'
    if (dart.library.html) 'file_download_web.dart'
    as impl;

Future<void> downloadBytes({
  required List<int> bytes,
  required String filename,
  required String mimeType,
}) {
  return impl.downloadBytes(
    bytes: bytes,
    filename: filename,
    mimeType: mimeType,
  );
}
