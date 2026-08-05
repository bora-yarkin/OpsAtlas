// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Rich content rendering and editor fallbacks for Markdown or HTML-backed content.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:html_editor_enhanced/html_editor.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/request_error.dart';
import '../i18n/app_localizations.dart';
import '../security/html_safety.dart';
import '../security/media_upload_policy.dart';

enum RichEditorRenderMode { platform, plainTextFallback }

final richEditorRenderModeProvider = Provider<RichEditorRenderMode>(
  (ref) => RichEditorRenderMode.plainTextFallback,
);

bool looksLikeHtml(String raw) {
  return looksLikeHtmlFragment(raw);
}

String toEditorHtml(String raw) {
  return markdownOrHtmlToSafeHtml(raw);
}

final Map<HtmlEditorController, String> _editorSnapshotByController =
    <HtmlEditorController, String>{};
final Map<HtmlEditorController, String> _editorDocumentTextByController =
    <HtmlEditorController, String>{};
final Map<HtmlEditorController, VoidCallback> _clearDraftStateByController =
    <HtmlEditorController, VoidCallback>{};
final Map<HtmlEditorController, _EditorDocumentTextSetter>
_setEditorDocumentTextByController =
    <HtmlEditorController, _EditorDocumentTextSetter>{};

typedef _EditorDocumentTextSetter =
    void Function(String plainText, {String? htmlOverride});

Future<String> readEditorHtml(HtmlEditorController controller) async {
  final fallback = _editorSnapshotByController[controller];
  try {
    final value = await controller.getText().timeout(
      const Duration(seconds: 4),
    );
    final normalized = _normalizeEditorContent(value);
    _editorSnapshotByController[controller] = normalized;
    return normalized;
  } on TimeoutException {
    return _normalizeEditorContent(fallback);
  } catch (_) {
    if (fallback != null) return _normalizeEditorContent(fallback);
    rethrow;
  }
}

Future<String> readEditorDocumentText(HtmlEditorController controller) async {
  final fallback = _editorDocumentTextByController[controller];
  if (fallback != null) {
    return _normalizeEditorContent(fallback);
  }
  final html = await readEditorHtml(controller);
  return htmlToEditorText(html);
}

Future<void> setEditorDocumentText(
  HtmlEditorController controller,
  String plainText, {
  String? htmlOverride,
}) async {
  final normalizedText = _normalizeEditorContent(plainText);
  final normalizedHtml = _normalizeEditorContent(
    htmlOverride ?? toEditorHtml(normalizedText),
  );
  final setter = _setEditorDocumentTextByController[controller];
  if (setter != null) {
    setter(normalizedText, htmlOverride: normalizedHtml);
    return;
  }
  _editorDocumentTextByController[controller] = normalizedText;
  _editorSnapshotByController[controller] = normalizedHtml;
  try {
    controller.setText(normalizedHtml);
  } catch (_) {
    // HtmlEditorController can be detached in tests or fallback mode.
  }
}

String _normalizeEditorContent(String? value) {
  final raw = (value ?? '').trim();
  if (raw == 'null' || raw == '<p><br></p>') return '';
  return raw;
}

String _draftKeyStorage(String key) => 'rich_editor_draft:$key';

class _RichEditorDraftState {
  final String plainText;
  final String html;

  const _RichEditorDraftState({required this.plainText, required this.html});
}

String _encodeDraftState(_RichEditorDraftState state) {
  return jsonEncode(<String, String>{
    'plain_text': state.plainText,
    'html': state.html,
  });
}

_RichEditorDraftState _decodeDraftState(String? raw) {
  final normalized = _normalizeEditorContent(raw);
  if (normalized.isEmpty) {
    return const _RichEditorDraftState(plainText: '', html: '');
  }
  try {
    final decoded = jsonDecode(normalized);
    if (decoded is Map) {
      final plainText = _normalizeEditorContent(decoded['plain_text']);
      final html = _normalizeEditorContent(decoded['html']);
      return _RichEditorDraftState(
        plainText: plainText,
        html: html.isEmpty
            ? _normalizeEditorContent(toEditorHtml(plainText))
            : html,
      );
    }
  } catch (_) {
    // Older drafts were stored as a plain string; treat them as markdown text.
  }
  return _RichEditorDraftState(
    plainText: normalized,
    html: _normalizeEditorContent(toEditorHtml(normalized)),
  );
}

Future<void> clearRichEditorDraft(
  String key, {
  HtmlEditorController? controller,
}) async {
  if (controller != null) {
    _clearDraftStateByController[controller]?.call();
  }
  final sp = await SharedPreferences.getInstance();
  await sp.remove(_draftKeyStorage(key));
}

class _EditorSaveIntent extends Intent {
  const _EditorSaveIntent();
}

class _EditorSearchIntent extends Intent {
  const _EditorSearchIntent();
}

class _EditorPaletteIntent extends Intent {
  const _EditorPaletteIntent();
}

class RichContentView extends StatelessWidget {
  final String content;
  const RichContentView({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    final text = content.trim();
    if (text.isEmpty) {
      return Text(AppLocalizations.of(context).text('no_content'));
    }
    final html = markdownOrHtmlToSafeHtml(text);
    final cs = Theme.of(context).colorScheme;
    return SelectionArea(
      child: Html(
        data: html,
        style: <String, Style>{
          'html': Style(
            margin: Margins.zero,
            padding: HtmlPaddings.zero,
            fontSize: FontSize(15),
            lineHeight: const LineHeight(1.65),
          ),
          'body': Style(
            margin: Margins.zero,
            padding: HtmlPaddings.zero,
            color: cs.onSurface,
          ),
          'p': Style(margin: Margins.only(bottom: 14)),
          'ul': Style(margin: Margins.only(bottom: 14, left: 12)),
          'ol': Style(margin: Margins.only(bottom: 14, left: 12)),
          'li': Style(margin: Margins.only(bottom: 6)),
          'blockquote': Style(
            margin: Margins.only(bottom: 16),
            padding: HtmlPaddings.only(left: 14, top: 8, right: 8, bottom: 8),
            backgroundColor: cs.surfaceContainerLow,
            border: Border(left: BorderSide(color: cs.primary, width: 3)),
          ),
          'code': Style(
            backgroundColor: cs.surfaceContainerLow,
            padding: HtmlPaddings.symmetric(horizontal: 6, vertical: 3),
          ),
          'pre': Style(
            margin: Margins.only(bottom: 16),
            padding: HtmlPaddings.all(14),
            backgroundColor: cs.surfaceContainerLow,
            border: Border.all(color: cs.outlineVariant),
          ),
          'table': Style(
            margin: Margins.only(bottom: 16),
            backgroundColor: cs.surfaceContainerLowest,
            border: Border.all(color: cs.outlineVariant),
          ),
          'thead': Style(backgroundColor: cs.surfaceContainerHigh),
          'th': Style(
            padding: HtmlPaddings.all(10),
            backgroundColor: cs.surfaceContainerHigh,
            fontWeight: FontWeight.w700,
            border: Border.all(color: cs.outlineVariant),
          ),
          'td': Style(
            padding: HtmlPaddings.all(10),
            border: Border.all(color: cs.outlineVariant),
          ),
          'h1': Style(margin: Margins.only(bottom: 16), fontSize: FontSize(28)),
          'h2': Style(margin: Margins.only(bottom: 14), fontSize: FontSize(24)),
          'h3': Style(margin: Margins.only(bottom: 12), fontSize: FontSize(20)),
        },
      ),
    );
  }
}

class RichEditor extends StatelessWidget {
  final RichEditorAttachmentOptions? attachmentOptions;
  final HtmlEditorController controller;
  final String initialContent;
  final String hint;
  final double height;
  final bool compact;
  final String? draftKey;
  final VoidCallback? onSaveRequested;
  final VoidCallback? onSearchRequested;
  final VoidCallback? onCommandPaletteRequested;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<String>? onDraftRecovered;

  const RichEditor({
    super.key,
    required this.controller,
    required this.initialContent,
    required this.hint,
    this.height = 620,
    this.compact = false,
    this.attachmentOptions,
    this.draftKey,
    this.onSaveRequested,
    this.onSearchRequested,
    this.onCommandPaletteRequested,
    this.onDirtyChanged,
    this.onDraftRecovered,
  });

  @override
  Widget build(BuildContext context) {
    return _RichEditorInner(
      controller: controller,
      initialContent: initialContent,
      hint: hint,
      height: height,
      compact: compact,
      attachmentOptions: attachmentOptions,
      draftKey: draftKey,
      onSaveRequested: onSaveRequested,
      onSearchRequested: onSearchRequested,
      onCommandPaletteRequested: onCommandPaletteRequested,
      onDirtyChanged: onDirtyChanged,
      onDraftRecovered: onDraftRecovered,
    );
  }
}

class _RichEditorInner extends ConsumerStatefulWidget {
  final RichEditorAttachmentOptions? attachmentOptions;
  final HtmlEditorController controller;
  final String initialContent;
  final String hint;
  final double height;
  final bool compact;
  final String? draftKey;
  final VoidCallback? onSaveRequested;
  final VoidCallback? onSearchRequested;
  final VoidCallback? onCommandPaletteRequested;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<String>? onDraftRecovered;

  const _RichEditorInner({
    required this.controller,
    required this.initialContent,
    required this.hint,
    required this.height,
    required this.compact,
    required this.attachmentOptions,
    required this.draftKey,
    required this.onSaveRequested,
    required this.onSearchRequested,
    required this.onCommandPaletteRequested,
    required this.onDirtyChanged,
    required this.onDraftRecovered,
  });

  @override
  ConsumerState<_RichEditorInner> createState() => _RichEditorInnerState();
}

class _RichEditorInnerState extends ConsumerState<_RichEditorInner> {
  static const double _attachmentRowHeight = 48;
  static const double _attachmentRowGap = 8;
  static const double _compactToolbarChromeHeight = 132;
  static const double _fullToolbarChromeHeight = 176;
  static const double _editorDecorationAllowance = 12;
  static const double _minimumEditorHeight = 120;
  static const double _maximumEditorHeight = 900;
  static const double _editorRadius = 16;

  bool _uploading = false;
  bool _draftReady = false;
  bool _dirty = false;
  bool _draftWritesSuppressed = false;
  String _plainTextContent = '';
  String _currentHtml = '';
  late final TextEditingController _fallbackTextCtrl;
  Timer? _autosaveTimer;
  MediaUploadPolicy? _uploadPolicy;

  bool get _hasAttachments => widget.attachmentOptions != null;

  @override
  void initState() {
    super.initState();
    _currentHtml = _normalizeEditorContent(toEditorHtml(widget.initialContent));
    _plainTextContent = _initialEditableText(
      widget.initialContent,
      _currentHtml,
    );
    _fallbackTextCtrl = TextEditingController(text: _plainTextContent);
    _publishSnapshot(_currentHtml, plainText: _plainTextContent);
    _clearDraftStateByController[widget.controller] = _clearDraftState;
    _setEditorDocumentTextByController[widget.controller] =
        _applyProgrammaticTextUpdate;
    _loadDraft();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _clearDraftStateByController.remove(widget.controller);
    _setEditorDocumentTextByController.remove(widget.controller);
    _editorDocumentTextByController.remove(widget.controller);
    _editorSnapshotByController.remove(widget.controller);
    _fallbackTextCtrl.dispose();
    super.dispose();
  }

  void _publishSnapshot(String content, {String? plainText}) {
    _editorSnapshotByController[widget.controller] = _normalizeEditorContent(
      content,
    );
    _editorDocumentTextByController[widget.controller] =
        _normalizeEditorContent(plainText ?? htmlToEditorText(content));
  }

  String _initialEditableText(String initialContent, String normalizedHtml) {
    final normalizedInitial = _normalizeEditorContent(initialContent);
    if (normalizedInitial.isEmpty) {
      return '';
    }
    if (!looksLikeHtml(normalizedInitial)) {
      return initialContent;
    }
    return htmlToEditorText(normalizedHtml);
  }

  Future<void> _loadDraft() async {
    if (widget.draftKey == null || widget.draftKey!.trim().isEmpty) {
      if (mounted) {
        setState(() => _draftReady = true);
      }
      return;
    }
    final sp = await SharedPreferences.getInstance();
    final restored = _decodeDraftState(
      sp.getString(_draftKeyStorage(widget.draftKey!)),
    );
    final initialHtml = _normalizeEditorContent(
      toEditorHtml(widget.initialContent),
    );
    final initialPlainText = _normalizeEditorContent(_plainTextContent);
    if (!mounted) return;
    final restoredPlainText = _normalizeEditorContent(restored.plainText);
    if (restored.html.isNotEmpty &&
        restoredPlainText.isNotEmpty &&
        restoredPlainText != initialPlainText &&
        restored.html != initialHtml) {
      _plainTextContent = restored.plainText;
      _currentHtml = restored.html;
      _fallbackTextCtrl
        ..text = restored.plainText
        ..selection = TextSelection.collapsed(
          offset: restored.plainText.length,
        );
      _publishSnapshot(restored.html, plainText: restored.plainText);
      _setDirty(true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onDraftRecovered?.call(restored.plainText);
      });
    }
    setState(() => _draftReady = true);
  }

  void _setDirty(bool next) {
    if (next) {
      _draftWritesSuppressed = false;
    }
    if (_dirty == next) return;
    _dirty = next;
    widget.onDirtyChanged?.call(next);
  }

  void _clearDraftState() {
    _autosaveTimer?.cancel();
    _draftWritesSuppressed = true;
    _setDirty(false);
  }

  void _scheduleAutosave({required String plainText, required String html}) {
    final key = widget.draftKey;
    if (key == null || key.trim().isEmpty) return;
    final normalizedPlainText = _normalizeEditorContent(plainText);
    final normalizedHtml = _normalizeEditorContent(html);
    final initialHtml = _normalizeEditorContent(
      toEditorHtml(widget.initialContent),
    );
    final initialPlainText = _normalizeEditorContent(
      _initialEditableText(widget.initialContent, initialHtml),
    );
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 550), () async {
      if (_draftWritesSuppressed) return;
      final sp = await SharedPreferences.getInstance();
      if (normalizedHtml.isEmpty ||
          normalizedHtml == initialHtml ||
          normalizedPlainText == initialPlainText) {
        await sp.remove(_draftKeyStorage(key));
      } else {
        await sp.setString(
          _draftKeyStorage(key),
          _encodeDraftState(
            _RichEditorDraftState(
              plainText: normalizedPlainText,
              html: normalizedHtml,
            ),
          ),
        );
      }
    });
  }

  void _updateFallbackText(String nextText, {String? htmlOverride}) {
    final normalized = _normalizeEditorContent(nextText);
    _plainTextContent = normalized;
    _currentHtml = _normalizeEditorContent(
      htmlOverride ?? toEditorHtml(normalized),
    );
    _fallbackTextCtrl.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
    _publishSnapshot(_currentHtml, plainText: normalized);
    _setDirty(
      _currentHtml !=
          _normalizeEditorContent(toEditorHtml(widget.initialContent)),
    );
    _scheduleAutosave(plainText: normalized, html: _currentHtml);
  }

  void _applyProgrammaticTextUpdate(String nextText, {String? htmlOverride}) {
    final normalized = _normalizeEditorContent(nextText);
    final normalizedHtml = _normalizeEditorContent(
      htmlOverride ?? toEditorHtml(normalized),
    );
    _plainTextContent = normalized;
    _currentHtml = normalizedHtml;
    _publishSnapshot(normalizedHtml, plainText: normalized);
    _setDirty(
      normalizedHtml !=
          _normalizeEditorContent(toEditorHtml(widget.initialContent)),
    );
    _scheduleAutosave(plainText: normalized, html: normalizedHtml);

    if (ref.read(richEditorRenderModeProvider) ==
        RichEditorRenderMode.plainTextFallback) {
      _fallbackTextCtrl.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
      return;
    }

    try {
      widget.controller.setText(normalizedHtml);
    } catch (_) {
      // Ignore detached HtmlEditorController writes in tests.
    }
  }

  void _appendFallbackMarkup(String markup) {
    final current = _fallbackTextCtrl.text.trimRight();
    final spacer = current.isEmpty ? '' : '\n\n';
    _updateFallbackText('$current$spacer$markup');
  }

  List<Toolbar> get _toolbarButtons => <Toolbar>[
    StyleButtons(style: false),
    FontButtons(clearAll: false),
    ColorButtons(),
    ListButtons(listStyles: false),
    ParagraphButtons(
      alignLeft: true,
      alignCenter: true,
      alignRight: true,
      alignJustify: true,
      textDirection: false,
      lineHeight: false,
      caseConverter: false,
    ),
    InsertButtons(
      picture: false,
      audio: false,
      video: false,
      otherFile: false,
      table: true,
      hr: false,
    ),
    OtherButtons(
      codeview: false,
      fullscreen: false,
      copy: true,
      paste: true,
      help: false,
    ),
  ];

  Future<void> _openRichEditorDialog() async {
    final l10n = AppLocalizations.of(context);
    final popupController = HtmlEditorController();
    final applied = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080, maxHeight: 820),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          l10n.text('rich_editor'),
                          style: Theme.of(dialogContext).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          dialogContext,
                        ).closeButtonTooltip,
                        onPressed: () => Navigator.pop(dialogContext, false),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.text('rich_editor_help'),
                    style: Theme.of(
                      dialogContext,
                    ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(_editorRadius),
                      child: HtmlEditor(
                        controller: popupController,
                        htmlEditorOptions: HtmlEditorOptions(
                          hint: widget.hint,
                          autoAdjustHeight: false,
                          initialText: _currentHtml,
                        ),
                        htmlToolbarOptions: HtmlToolbarOptions(
                          toolbarPosition: ToolbarPosition.aboveEditor,
                          toolbarType: ToolbarType.nativeScrollable,
                          defaultToolbarButtons: _toolbarButtons,
                        ),
                        otherOptions: OtherOptions(
                          height: 620,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(_editorRadius),
                            border: Border.all(color: cs.outlineVariant),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: Text(l10n.text('cancel')),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () async {
                          final html = await readEditorHtml(popupController);
                          if (!mounted || !dialogContext.mounted) {
                            return;
                          }
                          _updateFallbackText(
                            htmlToEditorText(html),
                            htmlOverride: html,
                          );
                          Navigator.pop(dialogContext, true);
                        },
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(l10n.text('apply_rich_editor_changes')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (applied == true && mounted) {
      setState(() {});
    }
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

  Future<void> _pickAndAttach() async {
    final l10n = AppLocalizations.of(context);
    if (_uploading) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    final files = picked.files
        .where((f) => f.bytes != null && f.bytes!.isNotEmpty)
        .toList();
    if (files.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.text('unable_to_read_selected_files'))),
      );
      return;
    }

    setState(() => _uploading = true);
    var insertedImages = 0;
    var attachedFiles = 0;
    String? localError;

    final api = ref.read(apiClientProvider);
    final options = widget.attachmentOptions!;
    final policy = await _ensureUploadPolicy(api);
    final renderMode = ref.read(richEditorRenderModeProvider);

    for (final file in files) {
      try {
        final filename = file.name.trim().isEmpty
            ? 'upload.bin'
            : file.name.trim();
        final bytes = file.bytes!;
        final ext = file.extension?.toLowerCase();
        final validationIssue = validateUploadSelection(
          bytes: bytes,
          filename: filename,
          extension: ext,
          mimeType: null,
          policy: policy,
        );
        if (validationIssue != null) {
          localError ??= _uploadValidationMessage(validationIssue, l10n);
          continue;
        }
        final form = FormData.fromMap({
          'usage': options.usage,
          if (options.spaceId != null) 'space_id': options.spaceId,
          'access_mode': options.spaceId == null ? 'private' : 'space',
          'file': MultipartFile.fromBytes(bytes, filename: filename),
        });
        final upload = await api.dio.post('/media/upload', data: form);
        final item = _toMap(upload.data);
        final assetId = (item['id'] ?? '').toString();
        final url = (item['url'] ?? '').toString();
        final contentType =
            (item['content_type'] ?? _contentTypeFromExtension(ext))
                .toString()
                .toLowerCase();

        if (options.attachEntityType != null &&
            options.attachEntityId != null &&
            assetId.isNotEmpty) {
          await api.dio.post(
            '/media/$assetId/attachments',
            data: {
              'entity_type': options.attachEntityType,
              'entity_id': options.attachEntityId,
            },
          );
          attachedFiles += 1;
        }

        if (url.isNotEmpty && contentType.startsWith('image/')) {
          if (renderMode == RichEditorRenderMode.plainTextFallback) {
            _appendFallbackMarkup('![$filename]($url)');
          } else {
            widget.controller.insertNetworkImage(url, filename: filename);
          }
          insertedImages += 1;
        } else if (url.isNotEmpty) {
          if (renderMode == RichEditorRenderMode.plainTextFallback) {
            _appendFallbackMarkup('[$filename]($url)');
          } else {
            widget.controller.insertHtml(
              buildSafeAttachmentLinkHtml(url, filename),
            );
          }
        }
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
      setState(() => _uploading = false);
      if (localError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(localError)));
      } else {
        final parts = <String>[];
        if (insertedImages > 0) {
          parts.add('$insertedImages ${l10n.text('images_inserted_suffix')}');
        }
        if (attachedFiles > 0) {
          parts.add('$attachedFiles ${l10n.text('files_attached_suffix')}');
        }
        if (parts.isEmpty) parts.add(l10n.text('upload_complete'));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(parts.join(' • '))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final renderMode = ref.watch(richEditorRenderModeProvider);
    if (!_draftReady) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedHeight =
            constraints.hasBoundedHeight && constraints.maxHeight.isFinite;
        final reservedHeight = _reservedHeight;
        final targetHeight = widget.height
            .clamp(_minimumEditorHeight, _maximumEditorHeight)
            .toDouble();
        final editorHeight = hasBoundedHeight
            ? _resolveBoundedEditorHeight(
                constraints.maxHeight,
                reservedHeight,
                targetHeight,
              )
            : targetHeight;
        final editorHostHeight =
            editorHeight +
            (widget.compact
                ? _compactToolbarChromeHeight
                : _fullToolbarChromeHeight);

        return Focus(
          autofocus: true,
          child: Shortcuts(
            shortcuts: <ShortcutActivator, Intent>{
              const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                  const _EditorSaveIntent(),
              const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
                  const _EditorSaveIntent(),
              const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  const _EditorSearchIntent(),
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                  const _EditorSearchIntent(),
              const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                  const _EditorPaletteIntent(),
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                  const _EditorPaletteIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _EditorSaveIntent: CallbackAction<_EditorSaveIntent>(
                  onInvoke: (_) {
                    widget.onSaveRequested?.call();
                    return null;
                  },
                ),
                _EditorSearchIntent: CallbackAction<_EditorSearchIntent>(
                  onInvoke: (_) {
                    widget.onSearchRequested?.call();
                    return null;
                  },
                ),
                _EditorPaletteIntent: CallbackAction<_EditorPaletteIntent>(
                  onInvoke: (_) {
                    widget.onCommandPaletteRequested?.call();
                    return null;
                  },
                ),
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_hasAttachments)
                    Padding(
                      padding: const EdgeInsets.only(bottom: _attachmentRowGap),
                      child: SizedBox(
                        height: _attachmentRowHeight,
                        child: Row(
                          children: [
                            Tooltip(
                              message:
                                  widget.attachmentOptions!.attachEntityId ==
                                      null
                                  ? l10n.text('attach_and_insert')
                                  : l10n.text('attach_item_and_insert'),
                              child: FilledButton.tonalIcon(
                                onPressed: _uploading ? null : _pickAndAttach,
                                icon: _uploading
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.attach_file),
                                label: Text(
                                  _uploading
                                      ? l10n.text('uploading')
                                      : l10n.text('attachment'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.text('attachment_inline_hint'),
                                style: Theme.of(context).textTheme.bodySmall,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SizedBox(
                    height: editorHostHeight,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(_editorRadius),
                      child:
                          renderMode == RichEditorRenderMode.plainTextFallback
                          ? _buildPlainTextFallback(context, editorHostHeight)
                          : HtmlEditor(
                              controller: widget.controller,
                              htmlEditorOptions: HtmlEditorOptions(
                                hint: widget.hint,
                                autoAdjustHeight: false,
                                initialText: _currentHtml,
                              ),
                              htmlToolbarOptions: HtmlToolbarOptions(
                                toolbarPosition: ToolbarPosition.aboveEditor,
                                toolbarType: widget.compact
                                    ? ToolbarType.nativeScrollable
                                    : ToolbarType.nativeGrid,
                                defaultToolbarButtons: _toolbarButtons,
                              ),
                              otherOptions: OtherOptions(
                                height: editorHeight,
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(
                                    _editorRadius,
                                  ),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                              ),
                              callbacks: Callbacks(
                                onChangeContent: (changed) {
                                  final normalized = _normalizeEditorContent(
                                    changed,
                                  );
                                  _currentHtml = normalized;
                                  _plainTextContent = htmlToEditorText(
                                    normalized,
                                  );
                                  _publishSnapshot(
                                    normalized,
                                    plainText: _plainTextContent,
                                  );
                                  _setDirty(
                                    normalized !=
                                        _normalizeEditorContent(
                                          toEditorHtml(widget.initialContent),
                                        ),
                                  );
                                  _scheduleAutosave(
                                    plainText: _plainTextContent,
                                    html: normalized,
                                  );
                                },
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  double get _reservedHeight {
    final toolbarHeight = widget.compact
        ? _compactToolbarChromeHeight
        : _fullToolbarChromeHeight;
    final attachmentHeight = _hasAttachments
        ? _attachmentRowHeight + _attachmentRowGap
        : 0;
    return toolbarHeight + attachmentHeight + _editorDecorationAllowance;
  }

  double _resolveBoundedEditorHeight(
    double maxHeight,
    double reservedHeight,
    double targetHeight,
  ) {
    final clampedTarget = math.min(targetHeight, maxHeight);
    final availableHeight = maxHeight - reservedHeight;
    if (availableHeight >= _minimumEditorHeight) {
      return math.min(clampedTarget, availableHeight);
    }
    final fallbackHeight = maxHeight * 0.4;
    return math.max(
      _minimumEditorHeight,
      math.min(clampedTarget, fallbackHeight),
    );
  }

  Widget _buildPlainTextFallback(
    BuildContext context,
    double editorHostHeight,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      child: Column(
        children: <Widget>[
          Container(
            height: widget.compact
                ? _compactToolbarChromeHeight
                : _fullToolbarChromeHeight,
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.82),
              border: Border(bottom: BorderSide(color: cs.outlineVariant)),
            ),
            child: LayoutBuilder(
              builder: (context, headerConstraints) {
                final compactHeader = headerConstraints.maxWidth < 320;
                final headerLabel = AppLocalizations.of(
                  context,
                ).text('draft_content_markdown');
                final richEditorLabel = AppLocalizations.of(
                  context,
                ).text('rich_editor');
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            headerLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (compactHeader)
                          Tooltip(
                            message: richEditorLabel,
                            child: IconButton(
                              onPressed: _openRichEditorDialog,
                              icon: const Icon(Icons.auto_awesome_outlined),
                            ),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: _openRichEditorDialog,
                            icon: const Icon(Icons.auto_awesome_outlined),
                            label: Text(richEditorLabel),
                          ),
                      ],
                    ),
                    if (!compactHeader) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        widget.hint,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                key: const ValueKey<String>('rich-editor-plain-text-fallback'),
                controller: _fallbackTextCtrl,
                expands: true,
                minLines: null,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  alignLabelWithHint: true,
                  filled: true,
                  fillColor: cs.surfaceContainerLow,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_editorRadius),
                  ),
                ),
                onChanged: (value) {
                  _updateFallbackText(value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RichEditorAttachmentOptions {
  final String usage;
  final String? spaceId;
  final String? attachEntityType;
  final String? attachEntityId;

  const RichEditorAttachmentOptions({
    required this.usage,
    this.spaceId,
    this.attachEntityType,
    this.attachEntityId,
  });
}

Map<String, dynamic> _toMap(dynamic value) {
  if (value is Map) return value.cast<String, dynamic>();
  return <String, dynamic>{};
}

String _contentTypeFromExtension(String? ext) {
  final lower = ext?.toLowerCase() ?? '';
  switch (lower) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'md':
      return 'text/markdown';
    default:
      return 'application/octet-stream';
  }
}

String _dioMessage(DioException e, {required String fallbackMessage}) {
  return dioErrorMessage(e, fallbackMessage: fallbackMessage);
}
