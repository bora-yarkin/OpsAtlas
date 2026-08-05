// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Reusable media upload and attachment section widgets.

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/request_error.dart';
import '../i18n/app_localizations.dart';
import '../security/media_upload_policy.dart';
import 'media_preview_dialog.dart';

class MediaUploadSection extends ConsumerStatefulWidget {
  final String title;
  final String usage;
  final String? spaceId;
  final bool compact;
  final String emptyLabel;
  final void Function(String url, String filename)? onInsert;
  final String? attachEntityType;
  final String? attachEntityId;
  final bool showMetadataControls;
  final bool allowDetachAttachments;

  const MediaUploadSection({
    super.key,
    required this.title,
    required this.usage,
    this.spaceId,
    this.compact = false,
    this.emptyLabel = '',
    this.onInsert,
    this.attachEntityType,
    this.attachEntityId,
    this.showMetadataControls = true,
    this.allowDetachAttachments = true,
  });

  @override
  ConsumerState<MediaUploadSection> createState() => _MediaUploadSectionState();
}

class _MediaUploadSectionState extends ConsumerState<MediaUploadSection> {
  bool _loading = false;
  bool _uploading = false;
  bool _showMeta = false;
  bool _dragging = false;
  bool _didLoadInitialData = false;
  String? _error;
  List<Map<String, dynamic>> _items = const [];
  String _accessMode = 'space';
  final TextEditingController _folderCtrl = TextEditingController();
  final TextEditingController _tagsCtrl = TextEditingController();
  final TextEditingController _retentionCtrl = TextEditingController();
  DropzoneViewController? _dropzone;
  MediaUploadPolicy? _uploadPolicy;

  bool get _attachmentMode =>
      (widget.attachEntityType?.trim().isNotEmpty ?? false) &&
      (widget.attachEntityId?.trim().isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    _accessMode = widget.usage.trim().toLowerCase().startsWith('branding_')
        ? 'public'
        : widget.spaceId == null
        ? 'private'
        : 'space';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoadInitialData) {
      return;
    }
    _didLoadInitialData = true;
    _load();
  }

  @override
  void dispose() {
    _folderCtrl.dispose();
    _tagsCtrl.dispose();
    _retentionCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted || message.trim().isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<MediaUploadPolicy> _ensureUploadPolicy(ApiClient api) async {
    final cached = _uploadPolicy;
    if (cached != null) {
      return cached;
    }
    final fetched = await fetchMediaUploadPolicy(api);
    _uploadPolicy = fetched;
    return fetched;
  }

  String _uploadValidationMessage(
    UploadValidationIssue issue,
    AppLocalizations l10n,
  ) {
    return switch (issue.code) {
      UploadValidationIssueCode.fileTooLarge =>
        '${issue.filename}: ${l10n.text('upload_file_too_large')} (${issue.maxUploadMb} MB)',
      UploadValidationIssueCode.fileTypeNotAllowed =>
        '${issue.filename}: ${l10n.text('upload_file_type_not_allowed')}',
    };
  }

  Future<List<_PendingUpload>> _filterValidUploads(
    ApiClient api,
    List<_PendingUpload> files,
    AppLocalizations l10n,
  ) async {
    final policy = await _ensureUploadPolicy(api);
    final valid = <_PendingUpload>[];
    UploadValidationIssue? firstIssue;
    for (final file in files) {
      final issue = validateUploadSelection(
        bytes: file.bytes,
        filename: file.filename,
        extension: file.extension,
        mimeType: file.mimeType,
        usage: widget.usage,
        policy: policy,
      );
      if (issue != null) {
        firstIssue ??= issue;
        continue;
      }
      valid.add(file);
    }
    if (firstIssue != null) {
      _showSnack(_uploadValidationMessage(firstIssue, l10n));
    }
    return valid;
  }

  Future<void> _load() async {
    final fallbackErrorMessage = AppLocalizations.of(
      context,
    ).text('request_failed');
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await _ensureUploadPolicy(api);
      final rows = _attachmentMode
          ? await _loadAttachments(api)
          : await _loadAssetLibrary(api);
      if (!mounted) return;
      setState(() => _items = rows);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = _dioMessage(e, fallbackMessage: fallbackErrorMessage),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildUsageGuidance(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final usageRule =
        _uploadPolicy?.usageRules[widget.usage.trim().toLowerCase()];
    if (usageRule == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final usageLabel = _localizedUsageLabel(l10n, usageRule);
    final guidanceLines = _localizedUsageGuidance(l10n, usageRule);
    final details = <String>[];
    if (usageRule.maxUploadMb != null) {
      details.add(
        l10n.textWith('upload_guidance_max_mb', {
          'maxUploadMb': usageRule.maxUploadMb,
        }),
      );
    }
    if (usageRule.minWidth != null || usageRule.minHeight != null) {
      final minWidth = usageRule.minWidth?.toString() ?? '?';
      final minHeight = usageRule.minHeight?.toString() ?? '?';
      details.add(
        l10n.textWith('upload_guidance_min_dimensions', {
          'width': minWidth,
          'height': minHeight,
        }),
      );
    }
    if (usageRule.maxWidth != null || usageRule.maxHeight != null) {
      final maxWidth = usageRule.maxWidth?.toString() ?? '?';
      final maxHeight = usageRule.maxHeight?.toString() ?? '?';
      details.add(
        l10n.textWith('upload_guidance_max_dimensions', {
          'width': maxWidth,
          'height': maxHeight,
        }),
      );
    }
    if (usageRule.squareRequired) {
      details.add(l10n.text('upload_guidance_square_artwork'));
    } else if (usageRule.aspectRatioMin != null ||
        usageRule.aspectRatioMax != null) {
      final minRatio = usageRule.aspectRatioMin?.toStringAsFixed(2) ?? '?';
      final maxRatio = usageRule.aspectRatioMax?.toStringAsFixed(2) ?? '?';
      details.add(
        l10n.textWith('upload_guidance_ratio', {
          'minRatio': minRatio,
          'maxRatio': maxRatio,
        }),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            usageLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (details.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              details.join(' • '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          for (final guidance in guidanceLines) ...<Widget>[
            const SizedBox(height: 6),
            Text(guidance, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  String _localizedUsageLabel(
    AppLocalizations l10n,
    MediaUsageUploadRule usageRule,
  ) {
    return switch (widget.usage.trim().toLowerCase()) {
      'branding_logo_light' => l10n.text('light_logo'),
      'branding_logo_dark' => l10n.text('dark_logo'),
      'branding_favicon' => l10n.text('favicon_label'),
      'branding_login_bg' => l10n.text('login_background'),
      _ => usageRule.label ?? widget.title,
    };
  }

  List<String> _localizedUsageGuidance(
    AppLocalizations l10n,
    MediaUsageUploadRule usageRule,
  ) {
    return switch (widget.usage.trim().toLowerCase()) {
      'branding_logo_light' => <String>[
        l10n.text('branding_logo_light_guidance_1'),
        l10n.text('branding_logo_light_guidance_2'),
        l10n.text('branding_logo_light_guidance_3'),
      ],
      'branding_logo_dark' => <String>[
        l10n.text('branding_logo_dark_guidance_1'),
        l10n.text('branding_logo_dark_guidance_2'),
        l10n.text('branding_logo_dark_guidance_3'),
      ],
      'branding_favicon' => <String>[
        l10n.text('branding_favicon_guidance_1'),
        l10n.text('branding_favicon_guidance_2'),
        l10n.text('branding_favicon_guidance_3'),
      ],
      'branding_login_bg' => <String>[
        l10n.text('branding_login_background_guidance_1'),
        l10n.text('branding_login_background_guidance_2'),
        l10n.text('branding_login_background_guidance_3'),
      ],
      _ => usageRule.guidance,
    };
  }

  Future<List<Map<String, dynamic>>> _loadAssetLibrary(ApiClient api) async {
    final query = <String, dynamic>{'usage': widget.usage, 'limit': 24};
    if (widget.spaceId != null) {
      query['space_id'] = widget.spaceId;
    }
    final folder = _folderCtrl.text.trim();
    if (folder.isNotEmpty) {
      query['folder_path'] = folder;
    }
    final tag = _firstTag(_tagsCtrl.text);
    if (tag != null) {
      query['tag'] = tag;
    }
    final r = await api.dio.get('/media', queryParameters: query);
    return _toJsonRows(r.data);
  }

  Future<List<Map<String, dynamic>>> _loadAttachments(ApiClient api) async {
    final r = await api.dio.get(
      '/media/attachments',
      queryParameters: {
        'entity_type': widget.attachEntityType,
        'entity_id': widget.attachEntityId,
      },
    );
    return _toJsonRows(r.data);
  }

  Future<void> _uploadFromPicker() async {
    final l10n = AppLocalizations.of(context);
    if (_uploading) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final files = <_PendingUpload>[];
    for (final file in picked.files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      files.add(
        _PendingUpload(
          bytes: bytes,
          filename: file.name,
          extension: file.extension,
          mimeType: null,
        ),
      );
    }
    if (files.isEmpty) {
      if (!mounted) return;
      _showSnack(l10n.text('unable_to_read_selected_files'));
      return;
    }
    await _uploadFiles(files);
  }

  Future<void> _uploadFiles(List<_PendingUpload> files) async {
    final l10n = AppLocalizations.of(context);
    if (_uploading || files.isEmpty) return;
    final api = ref.read(apiClientProvider);
    final validFiles = await _filterValidUploads(api, files, l10n);
    if (validFiles.isEmpty) {
      return;
    }
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final created = <Map<String, dynamic>>[];
      String? localError;

      for (final file in validFiles) {
        try {
          final uploaded = await _uploadSingle(api, file);
          created.add(uploaded);
        } on DioException catch (e) {
          localError = _dioMessage(
            e,
            fallbackMessage: l10n.text('request_failed'),
          );
        } catch (e) {
          localError = e.toString();
        }
      }

      if (mounted) {
        if (localError != null) {
          setState(() => _error = localError);
        }
        if (created.isNotEmpty) {
          if (widget.onInsert != null) {
            for (final item in created) {
              final url = (item['url'] ?? '').toString();
              if (url.isEmpty) continue;
              widget.onInsert!(
                url,
                (item['original_filename'] ?? 'media').toString(),
              );
            }
          }
          await _load();
          if (mounted) {
            final label = created.length == 1
                ? l10n.text('media_file_uploaded')
                : '${created.length} ${l10n.text('media_files_uploaded_suffix')}';
            _showSnack(label);
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  Future<Map<String, dynamic>> _uploadSingle(
    ApiClient api,
    _PendingUpload file,
  ) async {
    final retention = int.tryParse(_retentionCtrl.text.trim());
    final form = FormData.fromMap({
      'usage': widget.usage,
      if (widget.spaceId != null) 'space_id': widget.spaceId,
      'access_mode': _accessMode,
      if (_folderCtrl.text.trim().isNotEmpty)
        'folder_path': _folderCtrl.text.trim(),
      if (_tagsCtrl.text.trim().isNotEmpty) 'tags': _tagsCtrl.text.trim(),
      if (retention != null && retention > 0) 'retention_days': retention,
      'file': MultipartFile.fromBytes(
        file.bytes,
        filename: file.filename,
        contentType: _resolveMediaType(
          file.extension,
          inferMimeTypeFromUpload(
            extension: file.extension,
            mimeType: file.mimeType,
          ),
        ),
      ),
    });
    final uploadResp = await api.dio.post('/media/upload', data: form);
    final created = _toJsonRow(uploadResp.data);

    if (_attachmentMode) {
      final assetId = created['id']?.toString();
      if (assetId != null && assetId.isNotEmpty) {
        await api.dio.post(
          '/media/$assetId/attachments',
          data: {
            'entity_type': widget.attachEntityType,
            'entity_id': widget.attachEntityId,
          },
        );
      }
    }
    return created;
  }

  Future<void> _detachAttachment(String assetId) async {
    if (!_attachmentMode || assetId.isEmpty) return;
    final fallbackErrorMessage = AppLocalizations.of(
      context,
    ).text('request_failed');
    try {
      final api = ref.read(apiClientProvider);
      await api.dio.delete(
        '/media/$assetId/attachments',
        queryParameters: {
          'entity_type': widget.attachEntityType,
          'entity_id': widget.attachEntityId,
        },
      );
      await _load();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = _dioMessage(e, fallbackMessage: fallbackErrorMessage),
      );
    }
  }

  Future<void> _onDropFile(DropzoneFileInterface file) async {
    if (_dropzone == null || _uploading) return;
    final controller = _dropzone!;
    final filename = await controller.getFilename(file);
    final mime = await controller.getFileMIME(file);
    final bytes = await controller.getFileData(file);
    if (bytes.isEmpty) return;
    await _uploadFiles([
      _PendingUpload(
        bytes: bytes,
        filename: filename,
        extension: _extFromFilename(filename),
        mimeType: mime,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final thumbSize = widget.compact ? 58.0 : 74.0;
    final title = _attachmentMode
        ? '${widget.title} (${l10n.text('attached_suffix')})'
        : widget.title;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(widget.compact ? 10 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _uploading ? null : _uploadFromPicker,
                  icon: _uploading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file),
                  label: Text(
                    _uploading ? l10n.text('uploading') : l10n.text('upload'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: l10n.text('refresh'),
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (kIsWeb) ...[const SizedBox(height: 8), _buildDropZone(context)],
            if (!_attachmentMode && widget.showMetadataControls) ...[
              const SizedBox(height: 8),
              _buildMetadataControls(context),
            ],
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(_error!, style: TextStyle(color: cs.error)),
            ],
            _buildUsageGuidance(context),
            const SizedBox(height: 8),
            if (_loading && _items.isEmpty)
              const LinearProgressIndicator()
            else if (_items.isEmpty)
              Text(
                widget.emptyLabel.trim().isEmpty
                    ? l10n.text('no_media_uploaded_yet')
                    : widget.emptyLabel,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in _items.take(widget.compact ? 12 : 18))
                    _MediaThumb(
                      size: thumbSize,
                      assetId: (item['id'] ?? '').toString(),
                      url: (item['url'] ?? '').toString(),
                      filename: (item['original_filename'] ?? '').toString(),
                      contentType: item['content_type']?.toString(),
                      onInsert: widget.onInsert == null
                          ? null
                          : () => widget.onInsert!(
                              (item['url'] ?? '').toString(),
                              (item['original_filename'] ?? '').toString(),
                            ),
                      onDetach: _attachmentMode && widget.allowDetachAttachments
                          ? () =>
                                _detachAttachment((item['id'] ?? '').toString())
                          : null,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataControls(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _uploading
                ? null
                : () => setState(() => _showMeta = !_showMeta),
            icon: Icon(_showMeta ? Icons.expand_less : Icons.expand_more),
            label: Text(l10n.text('upload_options')),
          ),
        ),
        if (_showMeta)
          Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _accessMode,
                      decoration: InputDecoration(
                        labelText: l10n.text('access_mode'),
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'space',
                          child: Text(l10n.text('space_members')),
                        ),
                        DropdownMenuItem(
                          value: 'private',
                          child: Text(l10n.text('owner_only')),
                        ),
                        DropdownMenuItem(
                          value: 'authenticated',
                          child: Text(l10n.text('any_signed_in_user')),
                        ),
                        DropdownMenuItem(
                          value: 'public',
                          child: Text(l10n.text('public_label')),
                        ),
                      ],
                      onChanged: _uploading
                          ? null
                          : (v) =>
                                setState(() => _accessMode = v ?? _accessMode),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _retentionCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.text('retention_days'),
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _folderCtrl,
                decoration: InputDecoration(
                  labelText: l10n.text('folder_path_example'),
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                  isDense: true,
                ),
                onSubmitted: (_) => _load(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _tagsCtrl,
                decoration: InputDecoration(
                  labelText: l10n.text('tags_comma_separated'),
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                  isDense: true,
                ),
                onSubmitted: (_) => _load(),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildDropZone(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: widget.compact ? 64 : 74,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (_dragging ? cs.primary : cs.outlineVariant).withValues(
            alpha: 0.8,
          ),
        ),
        color: (_dragging ? cs.primaryContainer : cs.surfaceContainerLow)
            .withValues(alpha: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DropzoneView(
            operation: DragOperation.copy,
            cursor: CursorType.grab,
            onCreated: (controller) => _dropzone = controller,
            onHover: () {
              if (!_dragging && mounted) setState(() => _dragging = true);
            },
            onLeave: () {
              if (_dragging && mounted) setState(() => _dragging = false);
            },
            onDropFile: (file) async {
              if (mounted) setState(() => _dragging = false);
              await _onDropFile(file);
            },
            onDropString: (_) {
              if (mounted) setState(() => _dragging = false);
            },
            onDropInvalid: (_) {
              if (mounted) setState(() => _dragging = false);
            },
          ),
          IgnorePointer(
            child: Center(
              child: Text(
                _uploading
                    ? l10n.text('uploading_dropped_file')
                    : l10n.text('drag_drop_files_here'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaThumb extends StatelessWidget {
  final double size;
  final String assetId;
  final String url;
  final String filename;
  final String? contentType;
  final VoidCallback? onInsert;
  final VoidCallback? onDetach;

  const _MediaThumb({
    required this.size,
    required this.assetId,
    required this.url,
    required this.filename,
    this.contentType,
    this.onInsert,
    this.onDetach,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isImage = _isImageAsset(contentType, filename);
    return Container(
      width: size + 96,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
            ),
            clipBehavior: Clip.antiAlias,
            child: url.isEmpty
                ? const Icon(Icons.image_not_supported_outlined)
                : isImage
                ? Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  )
                : Icon(_previewIcon(contentType, filename)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: url.isEmpty
                  ? null
                  : () => showMediaPreviewDialog(
                      context: context,
                      filename: filename.isEmpty ? assetId : filename,
                      url: url,
                      contentType: contentType,
                    ),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  filename.isEmpty ? assetId : filename,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ),
          ),
          if (onInsert != null)
            IconButton(
              tooltip: l10n.text('insert'),
              onPressed: onInsert,
              icon: const Icon(Icons.input_outlined),
            ),
          if (onDetach != null)
            IconButton(
              tooltip: l10n.text('detach'),
              onPressed: onDetach,
              icon: const Icon(Icons.link_off),
            ),
        ],
      ),
    );
  }
}

bool _isImageAsset(String? contentType, String filename) {
  final normalized = (contentType ?? '').toLowerCase();
  if (normalized.startsWith('image/')) return true;
  final lower = filename.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.svg');
}

IconData _previewIcon(String? contentType, String filename) {
  final normalized = (contentType ?? '').toLowerCase();
  if (normalized == 'application/pdf' ||
      filename.toLowerCase().endsWith('.pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  if (normalized.startsWith('video/')) {
    return Icons.movie_outlined;
  }
  if (normalized.startsWith('audio/')) {
    return Icons.audiotrack_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

class _PendingUpload {
  final Uint8List bytes;
  final String filename;
  final String? extension;
  final String? mimeType;

  const _PendingUpload({
    required this.bytes,
    required this.filename,
    this.extension,
    this.mimeType,
  });
}

List<Map<String, dynamic>> _toJsonRows(dynamic data) {
  if (data is List) {
    return data.cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
  return const [];
}

Map<String, dynamic> _toJsonRow(dynamic data) {
  if (data is Map) return data.cast<String, dynamic>();
  return <String, dynamic>{};
}

String? _firstTag(String raw) {
  final parts = raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  return parts.first;
}

String? _extFromFilename(String filename) {
  final idx = filename.lastIndexOf('.');
  if (idx <= 0 || idx >= filename.length - 1) return null;
  return filename.substring(idx + 1);
}

String _dioMessage(DioException e, {required String fallbackMessage}) {
  return dioErrorMessage(e, fallbackMessage: fallbackMessage);
}

DioMediaType? _resolveMediaType(String? extension, String? mimeType) {
  final parsed = _parseDioMediaType(mimeType);
  if (parsed != null) return parsed;
  final ext = (extension ?? '').toLowerCase();
  return switch (ext) {
    'png' => DioMediaType('image', 'png'),
    'jpg' || 'jpeg' => DioMediaType('image', 'jpeg'),
    'gif' => DioMediaType('image', 'gif'),
    'webp' => DioMediaType('image', 'webp'),
    'svg' => DioMediaType('image', 'svg+xml'),
    'pdf' => DioMediaType('application', 'pdf'),
    'txt' => DioMediaType('text', 'plain'),
    _ => null,
  };
}

DioMediaType? _parseDioMediaType(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    return DioMediaType.parse(raw);
  } catch (_) {
    return null;
  }
}
