// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/security/media_upload_policy.dart';

void main() {
  test('validateUploadSelection rejects oversize files', () {
    final policy = MediaUploadPolicy(
      maxUploadMb: 1,
      allowedExtensions: const ['png'],
      allowedMimeTypes: const ['image/png'],
    );

    final issue = validateUploadSelection(
      bytes: List<int>.filled(2 * 1024 * 1024, 0),
      filename: 'diagram.png',
      extension: 'png',
      mimeType: 'image/png',
      policy: policy,
    );

    expect(issue?.code, UploadValidationIssueCode.fileTooLarge);
  });

  test('validateUploadSelection rejects disallowed extensions', () {
    final policy = MediaUploadPolicy(
      maxUploadMb: 5,
      allowedExtensions: const ['png'],
      allowedMimeTypes: const ['image/png'],
    );

    final issue = validateUploadSelection(
      bytes: const [1, 2, 3],
      filename: 'payload.exe',
      extension: 'exe',
      mimeType: 'application/octet-stream',
      policy: policy,
    );

    expect(issue?.code, UploadValidationIssueCode.fileTypeNotAllowed);
  });

  test('validateUploadSelection infers allowed mime types from extensions', () {
    final policy = MediaUploadPolicy.fallback();

    final issue = validateUploadSelection(
      bytes: const [1, 2, 3],
      filename: 'notes.md',
      extension: 'md',
      mimeType: 'application/octet-stream',
      policy: policy,
    );

    expect(issue, isNull);
    expect(
      inferMimeTypeFromUpload(
        extension: 'md',
        mimeType: 'application/octet-stream',
      ),
      'text/markdown',
    );
  });
}
