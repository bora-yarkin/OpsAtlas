// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// KB document creation and editing UI for the shared space workspace.

part of 'space_workspace_screen.dart';

class _KbDocEditorDialog extends ConsumerStatefulWidget {
  final String spaceId;
  final String? folderId;
  final JsonMap? existingDoc;

  const _KbDocEditorDialog({
    required this.spaceId,
    this.folderId,
    this.existingDoc,
  });

  @override
  ConsumerState<_KbDocEditorDialog> createState() => _KbDocEditorDialogState();
}

class _KbDocEditorDialogState extends ConsumerState<_KbDocEditorDialog> {
  static const List<int> _reviewReminderOptions = <int>[0, 1, 3, 7, 14];

  late final TextEditingController _titleCtrl;
  late final TextEditingController _slugCtrl;
  late final TextEditingController _tagsCtrl;
  late final HtmlEditorController _contentCtrl;
  late final String _initialContent;
  late final Future<List<JsonMap>> _foldersFuture;
  late final Future<List<JsonMap>> _membersFuture;
  late Future<List<JsonMap>> _reviewSuggestionsFuture;
  late final Future<JsonMap?> _diffFuture;
  DateTime? _reviewDueAt;
  String? _selectedFolderId;
  String? _reviewerUserId;
  int _reviewReminderDays = 3;
  bool _busy = false;
  bool _dirty = false;
  String? _error;
  bool _slugTouched = false;

  bool get _isEdit => widget.existingDoc != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingDoc;
    _titleCtrl = TextEditingController(
      text: existing?['title']?.toString() ?? '',
    );
    _slugCtrl = TextEditingController(
      text: existing?['slug']?.toString() ?? '',
    );
    _tagsCtrl = TextEditingController(
      text: ((existing?['tags'] as List?) ?? const [])
          .map((e) => e.toString())
          .join(', '),
    );
    _initialContent = existing?['content_md']?.toString() ?? '';
    _reviewDueAt = existing?['review_due_at'] is String
        ? DateTime.tryParse(existing!['review_due_at'].toString())
        : null;
    _selectedFolderId = existing?['folder_id']?.toString() ?? widget.folderId;
    _reviewerUserId =
        (existing?['reviewer_user_id'] ?? '').toString().trim().isEmpty
        ? null
        : existing?['reviewer_user_id']?.toString();
    _reviewReminderDays =
        (existing?['review_reminder_days'] as num?)?.toInt() ?? 3;
    _contentCtrl = HtmlEditorController();
    _foldersFuture = _loadFolders();
    _membersFuture = _loadMembers();
    _reviewSuggestionsFuture = _loadReviewerSuggestions();
    _diffFuture = _loadDiff();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _slugCtrl.dispose();
    _tagsCtrl.dispose();
    super.dispose();
  }

  Future<List<JsonMap>> _loadFolders() async {
    final api = ref.read(apiClientProvider);
    final r = await api.dio.get(
      '/kb/spaces/${widget.spaceId}/folders',
      queryParameters: const {'flat': true},
    );
    return _asJsonList(r.data);
  }

  Future<List<JsonMap>> _loadMembers() async {
    return _fetchSpaceMembersDetailed(ref, widget.spaceId);
  }

  Future<List<JsonMap>> _loadReviewerSuggestions() async {
    final api = ref.read(apiClientProvider);
    final tags = _parsedTags();
    final r = await api.dio.get(
      '/kb/spaces/${widget.spaceId}/reviewer-suggestions',
      queryParameters: {
        if (_isEdit) 'doc_id': widget.existingDoc!['id'],
        if (tags.isNotEmpty) 'tag': tags.join(','),
      },
    );
    return _asJsonList(r.data);
  }

  Future<JsonMap?> _loadDiff() async {
    if (!_isEdit) return null;
    try {
      final api = ref.read(apiClientProvider);
      final r = await api.dio.get('/kb/docs/${widget.existingDoc!['id']}/diff');
      return _asJsonMap(r.data);
    } catch (_) {
      return null;
    }
  }

  String get _draftKey => _isEdit
      ? 'kb-doc:${widget.existingDoc!['id']}'
      : 'kb-doc:new:${widget.spaceId}:${widget.folderId ?? 'root'}';

  void _markDirty() {
    if (_dirty) return;
    setState(() => _dirty = true);
  }

  List<String> _parsedTags() {
    return _tagsCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<void> _pickReviewDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _reviewDueAt ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      _reviewDueAt = DateTime(picked.year, picked.month, picked.day, 9);
      _dirty = true;
    });
  }

  Future<void> _attemptClose() async {
    if (_busy) return;
    // Keep closing deterministic on web platform views; draft autosave already preserves edits.
    if (mounted) {
      Navigator.pop(context, false);
    }
  }

  void _showCommandPalette() {
    showAppDialog<void>(
      context: context,
      announcement: _t(context, 'document_commands'),
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    leading: const Icon(Icons.save_outlined),
                    title: Text(_t(context, 'save_document')),
                    onTap: () {
                      Navigator.pop(context);
                      _save();
                    },
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    leading: const Icon(Icons.auto_fix_high),
                    title: Text(_t(context, 'generate_slug')),
                    onTap: () {
                      Navigator.pop(context);
                      _slugCtrl.text = _slugify(_titleCtrl.text);
                      _slugTouched = true;
                      _markDirty();
                    },
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: Text(_t(context, 'ai_suggest_title')),
                    onTap: () {
                      Navigator.pop(context);
                      _suggestMetadata();
                    },
                  ),
                ),
                if (_isEdit)
                  Material(
                    color: Colors.transparent,
                    child: ListTile(
                      leading: const Icon(Icons.link),
                      title: Text(_t(context, 'copy_link')),
                      onTap: () {
                        Navigator.pop(context);
                        _copyText(
                          context,
                          _docLink(
                            widget.spaceId,
                            (_slugCtrl.text.trim().isEmpty
                                ? _slugify(_titleCtrl.text)
                                : _slugCtrl.text.trim()),
                          ),
                          _t(context, 'document_link_copied'),
                        );
                      },
                    ),
                  ),
                if (_isEdit)
                  Material(
                    color: Colors.transparent,
                    child: ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(_t(context, 'copy_direct_link')),
                      onTap: () {
                        Navigator.pop(context);
                        _copyText(
                          context,
                          _docIdLink(
                            widget.spaceId,
                            widget.existingDoc!['id']?.toString() ?? '',
                          ),
                          _t(context, 'direct_doc_link_copied'),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _applyDiffChoice(JsonMap row, {required bool accept}) async {
    final current = await readEditorDocumentText(_contentCtrl);
    final lines = current.split('\n').toList();
    final kind = (row['kind'] ?? 'replace').toString();
    final leftText = (row['left_text'] ?? '').toString();
    final rightText = (row['right_text'] ?? '').toString();
    int index =
        ((accept ? row['right_line_no'] : row['left_line_no']) as num?)
            ?.toInt() ??
        1;
    index = index <= 0 ? 0 : index - 1;

    switch (kind) {
      case 'insert':
        if (accept) {
          if (index > lines.length) {
            lines.add(rightText);
          } else if (index == lines.length || lines[index] != rightText) {
            lines.insert(index, rightText);
          }
        } else {
          if (index < lines.length) {
            lines.removeAt(index);
          }
        }
        break;
      case 'delete':
        if (accept) {
          if (index < lines.length) {
            lines.removeAt(index);
          }
        } else {
          if (index > lines.length) {
            lines.add(leftText);
          } else {
            lines.insert(index, leftText);
          }
        }
        break;
      default:
        final replacement = accept ? rightText : leftText;
        if (index >= lines.length) {
          lines.add(replacement);
        } else {
          lines[index] = replacement;
        }
        break;
    }

    await setEditorDocumentText(_contentCtrl, lines.join('\n'));
    _markDirty();
  }

  Future<void> _suggestMetadata() async {
    try {
      final currentContent = await readEditorDocumentText(_contentCtrl);
      final api = ref.read(apiClientProvider);
      final r = await api.dio.post(
        '/ai/suggest/doc-metadata',
        data: {
          'existing_title': _titleCtrl.text.trim().isEmpty
              ? null
              : _titleCtrl.text.trim(),
          'text': currentContent,
          'max_tags': 5,
        },
      );
      final data = _asJsonMap(r.data);
      if (_titleCtrl.text.trim().isEmpty &&
          (data['title']?.toString().isNotEmpty ?? false)) {
        _titleCtrl.text = data['title'].toString();
      }
      if (!_slugTouched) {
        _slugCtrl.text = _slugify(_titleCtrl.text);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_t(context, 'ai_suggestion_ready_tags')}: ${(data['tags'] as List?)?.join(', ') ?? _t(context, 'none')}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_t(context, 'ai_suggestion_failed')}: ${_errorText(e)}',
            ),
          ),
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final title = _titleCtrl.text.trim();
      final slug = (_slugCtrl.text.trim().isEmpty
          ? _slugify(title)
          : _slugCtrl.text.trim());
      if (title.isEmpty || slug.isEmpty) {
        setState(() => _error = _t(context, 'name_and_slug_required'));
        return;
      }
      final contentBody = await readEditorDocumentText(_contentCtrl);
      final payload = {
        'title': title,
        'slug': slug,
        'content_md': contentBody,
        'folder_id': _selectedFolderId,
        'tags': _parsedTags(),
        'review_due_at': _reviewDueAt?.toIso8601String(),
        'reviewer_user_id': _reviewerUserId,
        'review_reminder_days': _reviewReminderDays,
      };
      Response<dynamic> response;
      if (_isEdit) {
        response = await api.dio.put(
          '/kb/docs/${widget.existingDoc!['id']}',
          data: {
            ...payload,
            'base_updated_at': widget.existingDoc!['updated_at'],
          },
        );
      } else {
        response = await api.dio.post(
          '/kb/docs',
          data: {'space_id': widget.spaceId, ...payload},
        );
      }
      await clearRichEditorDraft(_draftKey, controller: _contentCtrl);
      final saved = _asJsonMap(response.data);
      final finalSlug = (saved['slug'] ?? slug).toString();
      if (mounted && finalSlug != slug) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_t(context, 'slug_adjusted_to_avoid_collision')}: $finalSlug',
            ),
          ),
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) {
          _attemptClose();
        }
      },
      child: _DialogScaffold(
        title: _isEdit ? _t(context, 'edit_doc') : _t(context, 'new_doc'),
        subtitle: _t(context, 'kb_doc'),
        onClose: _busy ? null : _attemptClose,
        scrollBody: true,
        headerBadges: <Widget>[
          if (_dirty)
            Chip(
              avatar: const Icon(Icons.save_as_outlined, size: 18),
              label: Text(_t(context, 'autosaving_draft')),
            ),
          if (_reviewDueAt != null)
            Chip(
              avatar: const Icon(Icons.event_outlined, size: 18),
              label: Text(
                '${_t(context, 'review_due')} ${_reviewDueAt!.year}-${_reviewDueAt!.month.toString().padLeft(2, '0')}-${_reviewDueAt!.day.toString().padLeft(2, '0')}',
              ),
            ),
          if (_parsedTags().isNotEmpty)
            Chip(label: Text('${_parsedTags().length} ${_t(context, 'tags')}')),
        ],
        primaryAction: FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(
            _isEdit ? _t(context, 'save_changes') : _t(context, 'create_doc'),
          ),
        ),
        secondaryActions: <WorkspaceAction>[
          WorkspaceAction(
            label: _t(context, 'generate_slug'),
            icon: Icons.auto_fix_high,
            onSelected: _busy
                ? null
                : () {
                    _slugCtrl.text = _slugify(_titleCtrl.text);
                    _slugTouched = true;
                    _markDirty();
                  },
          ),
          WorkspaceAction(
            label: _t(context, 'ai_suggest_title'),
            icon: Icons.auto_awesome_outlined,
            onSelected: _busy ? null : _suggestMetadata,
          ),
          WorkspaceAction(
            label: _t(context, 'search_kb'),
            icon: Icons.search,
            onSelected: () => _showDocSearchDialog(context, widget.spaceId),
          ),
          WorkspaceAction(
            label: _t(context, 'document_commands'),
            icon: Icons.keyboard_command_key,
            onSelected: _showCommandPalette,
          ),
          if (_isEdit)
            WorkspaceAction(
              label: _t(context, 'copy_link'),
              icon: Icons.link_outlined,
              onSelected: () => _copyText(
                context,
                _docLink(
                  widget.spaceId,
                  (_slugCtrl.text.trim().isEmpty
                      ? _slugify(_titleCtrl.text)
                      : _slugCtrl.text.trim()),
                ),
                _t(context, 'document_link_copied'),
              ),
            ),
        ],
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1080;
            final contentMaxWidth = wide ? 1120.0 : double.infinity;
            final editorHeight = constraints.maxWidth < 480 ? 420.0 : 620.0;
            final identityPanel = AppFlatCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _t(context, 'metadata'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _titleCtrl,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                      ).copyWith(labelText: _t(context, 'name')),
                      onChanged: (_) {
                        _markDirty();
                        if (!_slugTouched && _slugCtrl.text.trim().isEmpty) {
                          _slugCtrl.text = _slugify(_titleCtrl.text);
                        }
                        if (_error != null) setState(() => _error = null);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _slugCtrl,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                      ).copyWith(labelText: _t(context, 'slug')),
                      onChanged: (_) {
                        _slugTouched = true;
                        _markDirty();
                        if (_error != null) setState(() => _error = null);
                      },
                    ),
                    const SizedBox(height: 12),
                    FutureBuilder<List<JsonMap>>(
                      future: _foldersFuture,
                      builder: (context, snapshot) {
                        final folders = snapshot.data ?? const <JsonMap>[];
                        final folderIds = folders
                            .map((folder) => (folder['id'] ?? '').toString())
                            .where((id) => id.trim().isNotEmpty)
                            .toSet();
                        final selectedFolderId =
                            _selectedFolderId != null &&
                                folderIds.contains(_selectedFolderId)
                            ? _selectedFolderId
                            : null;
                        return DropdownButtonFormField<String?>(
                          initialValue: selectedFolderId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: _t(context, 'folder'),
                            border: const OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(16),
                              ),
                            ),
                          ),
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(_t(context, 'root')),
                            ),
                            for (final folder in folders)
                              DropdownMenuItem<String?>(
                                value: (folder['id'] ?? '').toString(),
                                child: Text(
                                  (folder['path'] ?? folder['name'] ?? 'Folder')
                                      .toString(),
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            setState(() {
                              _selectedFolderId = value;
                              _dirty = true;
                            });
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tagsCtrl,
                      decoration:
                          const InputDecoration(
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(16),
                              ),
                            ),
                          ).copyWith(
                            labelText: _t(context, 'tags_comma_separated'),
                          ),
                      onChanged: (_) {
                        _markDirty();
                        setState(() {
                          _reviewSuggestionsFuture = _loadReviewerSuggestions();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            );
            final reviewPanel = AppFlatCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _t(context, 'set_review'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _pickReviewDueDate,
                      icon: const Icon(Icons.event_outlined),
                      label: Text(
                        _reviewDueAt == null
                            ? _t(context, 'set_review')
                            : '${_t(context, 'review_due')} ${_reviewDueAt!.year}-${_reviewDueAt!.month.toString().padLeft(2, '0')}-${_reviewDueAt!.day.toString().padLeft(2, '0')}',
                      ),
                    ),
                    if (_reviewDueAt != null) ...<Widget>[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _reviewDueAt = null;
                            _dirty = true;
                          });
                        },
                        icon: const Icon(Icons.close),
                        label: Text(_t(context, 'clear_review_date')),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FutureBuilder<List<JsonMap>>(
                      future: _membersFuture,
                      builder: (context, snapshot) {
                        final members = snapshot.data ?? const <JsonMap>[];
                        final memberIds = members
                            .map(
                              (member) => (member['user_id'] ?? '').toString(),
                            )
                            .where((id) => id.trim().isNotEmpty)
                            .toSet();
                        final reviewerUserId =
                            _reviewerUserId != null &&
                                memberIds.contains(_reviewerUserId)
                            ? _reviewerUserId
                            : null;
                        final reviewReminderDays =
                            _reviewReminderOptions.contains(_reviewReminderDays)
                            ? _reviewReminderDays
                            : 3;
                        return Column(
                          children: [
                            DropdownButtonFormField<String?>(
                              initialValue: reviewerUserId,
                              isExpanded: true,
                              menuMaxHeight: 320,
                              decoration: InputDecoration(
                                labelText: _t(context, 'assigned_reviewer'),
                                border: const OutlineInputBorder(
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(16),
                                  ),
                                ),
                              ),
                              items: [
                                DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text(_t(context, 'unassigned')),
                                ),
                                for (final member in members)
                                  DropdownMenuItem<String?>(
                                    value: (member['user_id'] ?? '').toString(),
                                    child: Text(
                                      _memberLabel(context, member),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (value) {
                                setState(() {
                                  _reviewerUserId = value;
                                  _dirty = true;
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<int>(
                              initialValue: reviewReminderDays,
                              isExpanded: true,
                              menuMaxHeight: 320,
                              decoration: InputDecoration(
                                labelText: _t(context, 'reminder'),
                                border: const OutlineInputBorder(
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(16),
                                  ),
                                ),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 0,
                                  child: Text(_t(context, 'same_day')),
                                ),
                                DropdownMenuItem(
                                  value: 1,
                                  child: Text(_t(context, 'one_day')),
                                ),
                                DropdownMenuItem(
                                  value: 3,
                                  child: Text(_t(context, 'three_days')),
                                ),
                                DropdownMenuItem(
                                  value: 7,
                                  child: Text(_t(context, 'seven_days')),
                                ),
                                DropdownMenuItem(
                                  value: 14,
                                  child: Text(_t(context, 'fourteen_days')),
                                ),
                              ],
                              onChanged: (value) {
                                setState(() {
                                  _reviewReminderDays = value ?? 3;
                                  _dirty = true;
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            FutureBuilder<List<JsonMap>>(
                              future: _reviewSuggestionsFuture,
                              builder: (context, snapshot) {
                                final suggestions =
                                    snapshot.data ?? const <JsonMap>[];
                                if (suggestions.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Align(
                                  alignment: Alignment.centerLeft,
                                  child: WorkspaceInlineStrip(
                                    spacing: 6,
                                    children: <Widget>[
                                      Text(_t(context, 'suggested_reviewers')),
                                      for (final suggestion in suggestions)
                                        ActionChip(
                                          label: Text(
                                            '${suggestion['name'] ?? 'Reviewer'} (${suggestion['open_reviews'] ?? 0})',
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _reviewerUserId =
                                                  (suggestion['user_id'] ?? '')
                                                      .toString();
                                              _dirty = true;
                                            });
                                          },
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
            final editorPanel = AppFlatCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: RichEditor(
                  controller: _contentCtrl,
                  initialContent: _initialContent,
                  hint: _t(context, 'write_document_content'),
                  height: editorHeight,
                  compact: true,
                  draftKey: _draftKey,
                  onSaveRequested: _save,
                  onSearchRequested: () =>
                      _showDocSearchDialog(context, widget.spaceId),
                  onCommandPaletteRequested: _showCommandPalette,
                  onDirtyChanged: (dirty) {
                    if (dirty) _markDirty();
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
                    usage: 'kb_doc_image',
                    spaceId: widget.spaceId,
                    attachEntityType: _isEdit ? 'doc' : null,
                    attachEntityId: _isEdit
                        ? widget.existingDoc!['id']?.toString()
                        : null,
                  ),
                ),
              ),
            );
            final diffPanel = _isEdit
                ? FutureBuilder<JsonMap?>(
                    future: _diffFuture,
                    builder: (context, snapshot) {
                      final diff = snapshot.data;
                      final rows = diff == null
                          ? const <JsonMap>[]
                          : _asJsonList(diff['rows'] ?? const []);
                      if (rows.isEmpty) return const SizedBox.shrink();
                      return AppFlatCard(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _t(context, 'inline_change_annotations'),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              _DocInlineAnnotations(
                                rows: rows,
                                onAccept: (row) =>
                                    _applyDiffChoice(row, accept: true),
                                onReject: (row) =>
                                    _applyDiffChoice(row, accept: false),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  )
                : const SizedBox.shrink();
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: contentMaxWidth),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      identityPanel,
                      const SizedBox(height: 16),
                      reviewPanel,
                      const SizedBox(height: 16),
                      editorPanel,
                      if (_isEdit) ...<Widget>[
                        const SizedBox(height: 12),
                        diffPanel,
                      ],
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
