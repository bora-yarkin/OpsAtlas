// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// HTML sanitization helpers used before rendering or editing rich content.

import 'package:markdown/markdown.dart' as md;

final RegExp _dangerousBlockTagPattern = RegExp(
  r'<\s*(script|style|iframe|object|embed|link|meta)\b[^>]*>.*?<\s*/\s*\1\s*>',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _dangerousTagPattern = RegExp(
  r'<\s*(script|style|iframe|object|embed|link|meta)\b[^>]*\/?>',
  caseSensitive: false,
);
final RegExp _eventAttributePattern = RegExp(
  r'''\s+on[a-zA-Z-]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)''',
  caseSensitive: false,
);

bool looksLikeHtmlFragment(String raw) {
  final text = raw.trimLeft();
  return text.startsWith('<') && RegExp(r'^<([a-zA-Z!])').hasMatch(text);
}

String markdownOrHtmlToSafeHtml(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  final html = looksLikeHtmlFragment(text)
      ? text
      : md.markdownToHtml(raw, extensionSet: md.ExtensionSet.gitHubFlavored);
  return sanitizeHtmlForDisplay(html);
}

String sanitizeHtmlForDisplay(String raw) {
  if (raw.trim().isEmpty) return '';
  var sanitized = raw;
  sanitized = sanitized.replaceAll(_dangerousBlockTagPattern, '');
  sanitized = sanitized.replaceAll(_dangerousTagPattern, '');
  sanitized = sanitized.replaceAll(_eventAttributePattern, '');
  sanitized = _replaceUnsafeAttributeUrls(
    sanitized,
    attributeName: 'href',
    validator: isSafeNavigableUrl,
    fallback: '#',
  );
  sanitized = _replaceUnsafeAttributeUrls(
    sanitized,
    attributeName: 'src',
    validator: isSafeEmbeddedResourceUrl,
    fallback: '',
  );
  return sanitized;
}

String htmlToEditorText(String raw) {
  final sanitized = sanitizeHtmlForDisplay(raw).trim();
  if (sanitized.isEmpty) {
    return '';
  }

  var text = sanitized;
  text = text.replaceAllMapped(
    RegExp(
      r'<img\b[^>]*src="([^"]+)"[^>]*alt="([^"]*)"[^>]*>',
      caseSensitive: false,
    ),
    (match) =>
        '![${_decodeHtmlEntities(match.group(2) ?? '')}](${match.group(1) ?? ''})',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'<img\b[^>]*alt="([^"]*)"[^>]*src="([^"]+)"[^>]*>',
      caseSensitive: false,
    ),
    (match) =>
        '![${_decodeHtmlEntities(match.group(1) ?? '')}](${match.group(2) ?? ''})',
  );
  text = text.replaceAllMapped(
    RegExp(r'<img\b[^>]*src="([^"]+)"[^>]*>', caseSensitive: false),
    (match) => '![](${match.group(1) ?? ''})',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    ),
    (match) {
      final label = _stripHtmlTags(match.group(2) ?? '').trim();
      final decoded = _decodeHtmlEntities(label);
      return '[${decoded.isEmpty ? (match.group(1) ?? '') : decoded}](${match.group(1) ?? ''})';
    },
  );
  text = _replaceBlockWithPrefix(text, tag: 'h1', prefix: '# ');
  text = _replaceBlockWithPrefix(text, tag: 'h2', prefix: '## ');
  text = _replaceBlockWithPrefix(text, tag: 'h3', prefix: '### ');
  text = _replaceBlockWithPrefix(text, tag: 'h4', prefix: '#### ');
  text = _replaceBlockWithPrefix(text, tag: 'h5', prefix: '##### ');
  text = _replaceBlockWithPrefix(text, tag: 'h6', prefix: '###### ');
  text = _replaceBlockWithPrefix(text, tag: 'blockquote', prefix: '> ');
  text = _replaceBlockWithPrefix(text, tag: 'li', prefix: '- ');
  text = text.replaceAllMapped(
    RegExp(r'<(strong|b)>(.*?)</\1>', caseSensitive: false, dotAll: true),
    (match) => '**${_stripHtmlTags(match.group(2) ?? '').trim()}**',
  );
  text = text.replaceAllMapped(
    RegExp(r'<(em|i)>(.*?)</\1>', caseSensitive: false, dotAll: true),
    (match) => '_${_stripHtmlTags(match.group(2) ?? '').trim()}_',
  );
  text = text.replaceAllMapped(
    RegExp(r'<code>(.*?)</code>', caseSensitive: false, dotAll: true),
    (match) =>
        '`${_decodeHtmlEntities(_stripHtmlTags(match.group(1) ?? '').trim())}`',
  );
  text = text.replaceAllMapped(
    RegExp(r'<pre\b[^>]*>(.*?)</pre>', caseSensitive: false, dotAll: true),
    (match) {
      final content = _decodeHtmlEntities(_stripHtmlTags(match.group(1) ?? ''));
      return '```\n${content.trim()}\n```';
    },
  );
  text = text.replaceAllMapped(
    RegExp(r'<table\b[^>]*>(.*?)</table>', caseSensitive: false, dotAll: true),
    (match) => _tableHtmlToMarkdown(match.group(1) ?? ''),
  );
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(
    RegExp(
      r'</(p|div|section|article|header|footer|aside)>',
      caseSensitive: false,
    ),
    '\n\n',
  );
  text = text.replaceAll(RegExp(r'</(ul|ol)>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<hr\s*/?>', caseSensitive: false), '\n---\n');
  text = _decodeHtmlEntities(_stripHtmlTags(text));
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

bool isSafeNavigableUrl(String raw) {
  return _isAllowedUrl(
    raw,
    allowedSchemes: const {'http', 'https', 'mailto', 'tel'},
  );
}

bool isSafeEmbeddedResourceUrl(String raw) {
  return _isAllowedUrl(raw, allowedSchemes: const {'http', 'https'});
}

String buildSafeAttachmentLinkHtml(String url, String filename) {
  final escapedFile = escapeHtml(filename);
  if (!isSafeNavigableUrl(url)) {
    return '<p>$escapedFile</p>';
  }
  final escapedUrl = escapeHtml(url);
  return '<p><a href="$escapedUrl" target="_blank" rel="noopener noreferrer">$escapedFile</a></p>';
}

String escapeHtml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

String _replaceUnsafeAttributeUrls(
  String html, {
  required String attributeName,
  required bool Function(String raw) validator,
  required String fallback,
}) {
  final pattern = RegExp(
    '''($attributeName\\s*=\\s*)("[^"]*"|'[^']*'|[^\\s>]+)''',
    caseSensitive: false,
  );
  return html.replaceAllMapped(pattern, (match) {
    final rawValue = match.group(2) ?? '';
    final value = _stripWrappingQuotes(rawValue);
    if (validator(value)) {
      return match.group(0) ?? '';
    }
    final quote = rawValue.startsWith("'") ? "'" : '"';
    final escapedFallback = escapeHtml(fallback);
    return '${match.group(1)}$quote$escapedFallback$quote';
  });
}

String _stripWrappingQuotes(String raw) {
  if (raw.length >= 2) {
    final first = raw[0];
    final last = raw[raw.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return raw.substring(1, raw.length - 1);
    }
  }
  return raw;
}

String _replaceBlockWithPrefix(
  String input, {
  required String tag,
  required String prefix,
}) {
  return input.replaceAllMapped(
    RegExp('<$tag\\b[^>]*>(.*?)</$tag>', caseSensitive: false, dotAll: true),
    (match) {
      final content = _decodeHtmlEntities(
        _stripHtmlTags(match.group(1) ?? ''),
      ).trim().replaceAll(RegExp(r'\s+'), ' ');
      if (content.isEmpty) {
        return '';
      }
      if (prefix == '> ') {
        return content
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .map((line) => '$prefix$line')
            .join('\n');
      }
      return '$prefix$content\n\n';
    },
  );
}

String _tableHtmlToMarkdown(String raw) {
  final rowPattern = RegExp(
    r'<tr\b[^>]*>(.*?)</tr>',
    caseSensitive: false,
    dotAll: true,
  );
  final cellPattern = RegExp(
    r'<t[hd]\b[^>]*>(.*?)</t[hd]>',
    caseSensitive: false,
    dotAll: true,
  );
  final rows = <List<String>>[];
  for (final rowMatch in rowPattern.allMatches(raw)) {
    final rowHtml = rowMatch.group(1) ?? '';
    final cells = <String>[];
    for (final cellMatch in cellPattern.allMatches(rowHtml)) {
      final value = _decodeHtmlEntities(
        _stripHtmlTags(cellMatch.group(1) ?? ''),
      ).trim();
      cells.add(value);
    }
    if (cells.isNotEmpty) {
      rows.add(cells);
    }
  }
  if (rows.isEmpty) {
    return _decodeHtmlEntities(_stripHtmlTags(raw));
  }
  final lines = <String>[];
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    lines.add('| ${row.join(' | ')} |');
    if (index == 0) {
      lines.add('| ${List<String>.filled(row.length, '---').join(' | ')} |');
    }
  }
  return '${lines.join('\n')}\n\n';
}

String _stripHtmlTags(String raw) {
  return raw.replaceAll(RegExp(r'<[^>]+>'), '');
}

String _decodeHtmlEntities(String raw) {
  return raw
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

bool _isAllowedUrl(String raw, {required Set<String> allowedSchemes}) {
  final candidate = _normalizeUrlForCheck(raw);
  if (candidate.isEmpty) {
    return false;
  }
  if (candidate.startsWith('#') ||
      candidate.startsWith('/') ||
      candidate.startsWith('./') ||
      candidate.startsWith('../') ||
      candidate.startsWith('?')) {
    return true;
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null) {
    return false;
  }
  final scheme = uri.scheme.trim().toLowerCase();
  if (scheme.isEmpty) {
    return true;
  }
  return allowedSchemes.contains(scheme);
}

String _normalizeUrlForCheck(String raw) {
  return raw
      .trim()
      .replaceAll('&colon;', ':')
      .replaceAll('&#58;', ':')
      .replaceAll('&#x3a;', ':')
      .replaceAll('&#X3A;', ':')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[\u0000-\u001F\s]+'), '');
}
