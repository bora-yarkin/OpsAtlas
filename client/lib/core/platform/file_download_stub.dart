// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Non-web file download stub used by conditional imports.

Future<void> downloadBytes({
  required List<int> bytes,
  required String filename,
  required String mimeType,
}) async {
  return;
}
