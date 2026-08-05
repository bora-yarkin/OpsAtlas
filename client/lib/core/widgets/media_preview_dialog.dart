// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Media preview dialog for attachments and uploaded assets.

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../i18n/app_localizations.dart';
import '../security/html_safety.dart';
import 'app_dialog.dart';

Future<void> showMediaPreviewDialog({
  required BuildContext context,
  required String filename,
  required String url,
  String? contentType,
}) async {
  final l10n = AppLocalizations.of(context);
  await showAppDialog<void>(
    context: context,
    announcement: l10n.text('preview_media'),
    builder: (context) => AlertDialog(
      title: SelectableText(
        filename.trim().isEmpty ? l10n.text('preview_media') : filename.trim(),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      content: SizedBox(
        width: 880,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MediaPreviewBody(
                url: url,
                filename: filename,
                contentType: contentType,
              ),
              const SizedBox(height: 12),
              SelectableText(url, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('close')),
        ),
      ],
    ),
  );
}

class _MediaPreviewBody extends StatelessWidget {
  final String url;
  final String filename;
  final String? contentType;

  const _MediaPreviewBody({
    required this.url,
    required this.filename,
    required this.contentType,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final normalizedType = (contentType ?? '').trim().toLowerCase();
    final kind = _mediaKind(normalizedType, filename);
    final cs = Theme.of(context).colorScheme;

    if (url.trim().isEmpty || !isSafeEmbeddedResourceUrl(url)) {
      return SelectableText(l10n.text('preview_unavailable'));
    }
    final safeUrl = escapeHtml(url);
    if (kind == _PreviewKind.image) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: InteractiveViewer(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                Center(child: SelectableText(l10n.text('preview_unavailable'))),
          ),
        ),
      );
    }
    if (kind == _PreviewKind.pdf) {
      return SizedBox(
        height: 560,
        child: Html(
          data:
              '<iframe src="$safeUrl" style="width:100%;height:560px;border:none;" title="${escapeHtml(filename)}"></iframe>',
        ),
      );
    }
    if (kind == _PreviewKind.video) {
      return SizedBox(
        height: 420,
        child: Html(
          data:
              '<video controls style="width:100%;max-height:420px;" src="$safeUrl"></video>',
        ),
      );
    }
    if (kind == _PreviewKind.audio) {
      return SizedBox(
        height: 100,
        child: Html(
          data: '<audio controls style="width:100%;" src="$safeUrl"></audio>',
        ),
      );
    }
    if (kind == _PreviewKind.office) {
      final officeViewerUrl =
          'https://view.officeapps.live.com/op/embed.aspx?src=${Uri.encodeComponent(url)}';
      return SizedBox(
        height: 560,
        child: Html(
          data:
              '<iframe src="${escapeHtml(officeViewerUrl)}" style="width:100%;height:560px;border:none;" title="${escapeHtml(filename)}"></iframe>',
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cs.surfaceContainerLow,
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(_fileIcon(kind), size: 28, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              l10n.text('preview_unavailable'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

enum _PreviewKind { image, pdf, video, audio, office, other }

_PreviewKind _mediaKind(String contentType, String filename) {
  if (contentType.startsWith('image/')) return _PreviewKind.image;
  if (contentType == 'application/pdf') return _PreviewKind.pdf;
  if (contentType.startsWith('video/')) return _PreviewKind.video;
  if (contentType.startsWith('audio/')) return _PreviewKind.audio;
  if (contentType ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      contentType ==
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
      contentType ==
          'application/vnd.openxmlformats-officedocument.presentationml.presentation') {
    return _PreviewKind.office;
  }

  final lower = filename.toLowerCase();
  if (lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.svg')) {
    return _PreviewKind.image;
  }
  if (lower.endsWith('.pdf')) return _PreviewKind.pdf;
  if (lower.endsWith('.mp4') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.m4v')) {
    return _PreviewKind.video;
  }
  if (lower.endsWith('.mp3') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.ogg') ||
      lower.endsWith('.m4a')) {
    return _PreviewKind.audio;
  }
  if (lower.endsWith('.docx') ||
      lower.endsWith('.xlsx') ||
      lower.endsWith('.pptx')) {
    return _PreviewKind.office;
  }
  return _PreviewKind.other;
}

IconData _fileIcon(_PreviewKind kind) {
  return switch (kind) {
    _PreviewKind.pdf => Icons.picture_as_pdf_outlined,
    _PreviewKind.video => Icons.movie_outlined,
    _PreviewKind.audio => Icons.audiotrack_outlined,
    _PreviewKind.office => Icons.description_outlined,
    _PreviewKind.image => Icons.image_outlined,
    _PreviewKind.other => Icons.insert_drive_file_outlined,
  };
}
