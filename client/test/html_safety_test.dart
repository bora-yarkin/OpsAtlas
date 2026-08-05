// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/security/html_safety.dart';

void main() {
  test('sanitizeHtmlForDisplay strips scripts and unsafe hrefs', () {
    final html = sanitizeHtmlForDisplay(
      '<script>alert(1)</script><p><a href="javascript:alert(1)" onclick="evil()">Click</a></p>',
    );

    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('onclick=')));
    expect(html, contains('href="#"'));
  });

  test('markdownOrHtmlToSafeHtml preserves safe links', () {
    final html = markdownOrHtmlToSafeHtml('[Docs](https://example.com/docs)');

    expect(html, contains('href="https://example.com/docs"'));
    expect(isSafeNavigableUrl('https://example.com/docs'), isTrue);
    expect(isSafeNavigableUrl('javascript:alert(1)'), isFalse);
  });

  test('htmlToEditorText converts common rich content into editable text', () {
    final text = htmlToEditorText(
      '<h2>Runbook</h2><p>Review the <a href="https://example.com">guide</a>.</p><ul><li>Check alerts</li><li>Escalate</li></ul>',
    );

    expect(text, contains('## Runbook'));
    expect(text, contains('[guide](https://example.com)'));
    expect(text, contains('- Check alerts'));
    expect(text, contains('- Escalate'));
  });
}
