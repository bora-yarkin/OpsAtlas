// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Supporting widgets and helpers for the SOP editor experience.

part of 'space_workspace_screen.dart';

class _SopStepDraft {
  int order;
  final TextEditingController titleCtrl;
  final TextEditingController allowedExtensionsCtrl;
  final TextEditingController followUpTitleCtrl;
  String bodyHtml;
  bool requiresEvidence;
  int evidenceMinFiles;
  int followUpSeverity;
  String followUpOwnerUserId;
  _SopStepDraft({
    required this.order,
    String title = '',
    String body = '',
    this.requiresEvidence = false,
    this.evidenceMinFiles = 0,
    String allowedExtensions = '',
    this.followUpSeverity = 3,
    this.followUpOwnerUserId = '',
    String followUpTitleTemplate = '',
  }) : titleCtrl = TextEditingController(text: title),
       allowedExtensionsCtrl = TextEditingController(text: allowedExtensions),
       followUpTitleCtrl = TextEditingController(text: followUpTitleTemplate),
       bodyHtml = body;

  List<String> get allowedExtensions => allowedExtensionsCtrl.text
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();

  void dispose() {
    titleCtrl.dispose();
    allowedExtensionsCtrl.dispose();
    followUpTitleCtrl.dispose();
  }

  void clearBody() {
    bodyHtml = '';
  }

  Future<String> readBodyHtml() async {
    return bodyHtml;
  }

  String get followUpTitleTemplate => followUpTitleCtrl.text.trim();
}

class _SopApprovalStageDraft {
  int order;
  String approverUserId;
  String delegateApproverUserId;
  DateTime? delegateStartAt;
  DateTime? delegateEndAt;
  final TextEditingController labelCtrl;

  _SopApprovalStageDraft({
    required this.order,
    this.approverUserId = '',
    this.delegateApproverUserId = '',
    this.delegateStartAt,
    this.delegateEndAt,
    String label = '',
  }) : labelCtrl = TextEditingController(text: label);

  String get label => labelCtrl.text;

  void dispose() {
    labelCtrl.dispose();
  }
}

class _SopStepBodyDialog extends ConsumerStatefulWidget {
  final String spaceId;
  final String? sopId;
  final int stepIndex;
  final String stepTitle;
  final String initialBody;

  const _SopStepBodyDialog({
    required this.spaceId,
    required this.sopId,
    required this.stepIndex,
    required this.stepTitle,
    required this.initialBody,
  });

  @override
  ConsumerState<_SopStepBodyDialog> createState() => _SopStepBodyDialogState();
}

class _SopOverviewDialog extends ConsumerStatefulWidget {
  final String spaceId;
  final String? sopId;
  final String initialBody;

  const _SopOverviewDialog({
    required this.spaceId,
    required this.sopId,
    required this.initialBody,
  });

  @override
  ConsumerState<_SopOverviewDialog> createState() => _SopOverviewDialogState();
}

class _SopOverviewDialogState extends ConsumerState<_SopOverviewDialog> {
  late final HtmlEditorController _controller;
  bool _saving = false;
  bool _dirty = false;
  String? _error;

  String get _draftKey => 'sop-overview:${widget.sopId ?? 'new'}';

  @override
  void initState() {
    super.initState();
    _controller = HtmlEditorController();
  }

  Future<void> _attemptClose() async {
    if (_saving) return;
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final body = await readEditorDocumentText(_controller);
      await clearRichEditorDraft(_draftKey, controller: _controller);
      if (!mounted) return;
      Navigator.pop(context, body);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _errorText(e));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) {
          _attemptClose();
        }
      },
      child: _DialogScaffold(
        title: _t(context, 'overview'),
        onClose: _saving ? null : _attemptClose,
        scrollBody: true,
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _saving ? null : _attemptClose,
              child: Text(_t(context, 'cancel')),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_t(context, 'save')),
            ),
          ],
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: RichEditor(
                controller: _controller,
                initialContent: widget.initialBody,
                hint: _t(context, 'sop_overview'),
                height: 640,
                compact: true,
                draftKey: _draftKey,
                onSaveRequested: _save,
                onCommandPaletteRequested: _save,
                onDirtyChanged: (dirty) {
                  if (dirty && !_dirty) {
                    setState(() => _dirty = true);
                  }
                },
                onDraftRecovered: (_) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(_t(context, 'recovered_autosaved_draft')),
                    ),
                  );
                },
                attachmentOptions: RichEditorAttachmentOptions(
                  usage: widget.sopId == null
                      ? 'sop_overview_image'
                      : 'sop_attachment',
                  spaceId: widget.spaceId,
                  attachEntityType: widget.sopId == null ? null : 'sop',
                  attachEntityId: widget.sopId,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SopStepBodyDialogState extends ConsumerState<_SopStepBodyDialog> {
  late final HtmlEditorController _controller;
  bool _saving = false;
  bool _dirty = false;
  String? _error;

  String get _draftKey =>
      'sop-step:${widget.sopId ?? 'new'}:${widget.stepIndex}';

  @override
  void initState() {
    super.initState();
    _controller = HtmlEditorController();
  }

  Future<void> _attemptClose() async {
    if (_saving) return;
    // Nested dialogs over web platform views (HtmlEditor iframe) are not reliably clickable.
    // We always autosave drafts, so close directly.
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final body = await readEditorDocumentText(_controller);
      await clearRichEditorDraft(_draftKey, controller: _controller);
      if (!mounted) return;
      Navigator.pop(context, body);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _errorText(e));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) {
          _attemptClose();
        }
      },
      child: _DialogScaffold(
        title: widget.stepTitle,
        onClose: _saving ? null : _attemptClose,
        scrollBody: true,
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _saving ? null : _attemptClose,
              child: Text(_t(context, 'cancel')),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_t(context, 'save_step')),
            ),
          ],
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: RichEditor(
                controller: _controller,
                initialContent: widget.initialBody,
                hint: _t(context, 'step_instructions'),
                height: 640,
                compact: true,
                draftKey: _draftKey,
                onSaveRequested: _save,
                onCommandPaletteRequested: _save,
                onDirtyChanged: (dirty) {
                  if (dirty && !_dirty) {
                    setState(() => _dirty = true);
                  }
                },
                onDraftRecovered: (_) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        _t(context, 'recovered_autosaved_step_draft'),
                      ),
                    ),
                  );
                },
                attachmentOptions: RichEditorAttachmentOptions(
                  usage: 'sop_step_image',
                  spaceId: widget.spaceId,
                  attachEntityType: widget.sopId == null ? null : 'sop',
                  attachEntityId: widget.sopId,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
