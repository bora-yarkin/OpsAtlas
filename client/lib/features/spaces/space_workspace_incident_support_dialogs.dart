// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Supporting incident dialogs such as timeline and reminder editors.

part of 'space_workspace_screen.dart';

// ignore_for_file: unused_element_parameter

class _TimelineEntryDialog extends ConsumerStatefulWidget {
  final String incidentId;
  final String spaceId;
  const _TimelineEntryDialog({required this.incidentId, required this.spaceId});

  @override
  ConsumerState<_TimelineEntryDialog> createState() =>
      _TimelineEntryDialogState();
}

class _TimelineEntryDialogState extends ConsumerState<_TimelineEntryDialog> {
  final HtmlEditorController _entryCtrl = HtmlEditorController();
  String _category = 'update';
  bool _pinned = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final entry = await readEditorDocumentText(_entryCtrl);
      if (entry.isEmpty) {
        setState(() => _error = _t(context, 'entry_required'));
        return;
      }
      final api = ref.read(apiClientProvider);
      await api.dio.post(
        '/incidents/${widget.incidentId}/timeline',
        data: {'entry_md': entry, 'category': _category, 'pinned': _pinned},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogScaffold(
      title: _t(context, 'add_timeline_entry'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      scrollBody: true,
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(_t(context, 'cancel')),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            label: Text(_t(context, 'add_entry')),
          ),
        ],
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _category,
                    decoration: InputDecoration(
                      labelText: _t(context, 'category'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'update',
                        child: Text(_t(context, 'timeline_category_update')),
                      ),
                      DropdownMenuItem(
                        value: 'detection',
                        child: Text(_t(context, 'timeline_category_detection')),
                      ),
                      DropdownMenuItem(
                        value: 'mitigation',
                        child: Text(
                          _t(context, 'timeline_category_mitigation'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'communication',
                        child: Text(
                          _t(context, 'timeline_category_communication'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'resolution',
                        child: Text(
                          _t(context, 'timeline_category_resolution'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'follow_up',
                        child: Text(_t(context, 'timeline_category_follow_up')),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) =>
                              setState(() => _category = value ?? _category),
                  ),
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: Text(_t(context, 'pin_key_event')),
                  selected: _pinned,
                  onSelected: _busy
                      ? null
                      : (value) => setState(() => _pinned = value),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: RichEditor(
              controller: _entryCtrl,
              initialContent: '',
              hint: _t(context, 'timeline_entry'),
              height: 640,
              compact: true,
              attachmentOptions: RichEditorAttachmentOptions(
                usage: 'incident_timeline_image',
                spaceId: widget.spaceId,
                attachEntityType: 'incident',
                attachEntityId: widget.incidentId,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IncidentPostmortemDialog extends ConsumerStatefulWidget {
  final String incidentId;
  final String initialContent;

  const _IncidentPostmortemDialog({
    required this.incidentId,
    required this.initialContent,
  });

  @override
  ConsumerState<_IncidentPostmortemDialog> createState() =>
      _IncidentPostmortemDialogState();
}

class _IncidentPostmortemDialogState
    extends ConsumerState<_IncidentPostmortemDialog> {
  final HtmlEditorController _ctrl = HtmlEditorController();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final content = await readEditorDocumentText(_ctrl);
      final api = ref.read(apiClientProvider);
      await api.dio.put(
        '/incidents/${widget.incidentId}/meta',
        data: {'postmortem_md': content},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogScaffold(
      title: _t(context, 'edit_postmortem'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      scrollBody: true,
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(_t(context, 'cancel')),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_t(context, 'save_postmortem')),
          ),
        ],
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: RichEditor(
              controller: _ctrl,
              initialContent: widget.initialContent,
              hint: _t(context, 'postmortem'),
              height: 640,
              compact: true,
              attachmentOptions: RichEditorAttachmentOptions(
                usage: 'incident_attachment',
                attachEntityType: 'incident',
                attachEntityId: widget.incidentId,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IncidentActionItemDialog extends ConsumerStatefulWidget {
  final String incidentId;
  final String spaceId;
  final JsonMap? existingItem;

  const _IncidentActionItemDialog({
    required this.incidentId,
    required this.spaceId,
    this.existingItem,
  });

  @override
  ConsumerState<_IncidentActionItemDialog> createState() =>
      _IncidentActionItemDialogState();
}

class _IncidentActionItemDialogState
    extends ConsumerState<_IncidentActionItemDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _notesCtrl;
  late final Future<List<JsonMap>> _membersFuture;
  String _status = 'open';
  String? _ownerUserId;
  DateTime? _dueAt;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existingItem != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingItem;
    _titleCtrl = TextEditingController(
      text: existing?['title']?.toString() ?? '',
    );
    _notesCtrl = TextEditingController(
      text: existing?['notes_md']?.toString() ?? '',
    );
    _status = existing?['status']?.toString() ?? 'open';
    _ownerUserId = (existing?['owner_user_id'] ?? '').toString().trim().isEmpty
        ? null
        : (existing?['owner_user_id'] ?? '').toString();
    _dueAt = existing?['due_at'] is String
        ? DateTime.tryParse(existing!['due_at'].toString())
        : null;
    _membersFuture = _loadMembers();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<List<JsonMap>> _loadMembers() async {
    return _fetchSpaceMembersDetailed(ref, widget.spaceId);
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() => _dueAt = DateTime(picked.year, picked.month, picked.day, 9));
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final payload = {
        'title': _titleCtrl.text.trim(),
        'owner_user_id': _ownerUserId,
        'due_at': _dueAt?.toIso8601String(),
        'status': _status,
        'notes_md': _notesCtrl.text.trim(),
      };
      if (_isEdit) {
        await api.dio.put(
          '/incidents/${widget.incidentId}/action-items/${widget.existingItem!['id']}',
          data: payload,
        );
      } else {
        await api.dio.post(
          '/incidents/${widget.incidentId}/action-items',
          data: payload,
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
    return _DialogScaffold(
      title: _isEdit
          ? _t(context, 'edit_action_item')
          : _t(context, 'new_action_item'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                labelText: _t(context, 'title_label'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FutureBuilder<List<JsonMap>>(
                    future: _membersFuture,
                    builder: (context, snapshot) {
                      final members = snapshot.data ?? const <JsonMap>[];
                      return DropdownButtonFormField<String?>(
                        initialValue: _ownerUserId,
                        decoration: InputDecoration(
                          labelText: _t(context, 'owner_prefix'),
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
                                _memberNameOrFallback(context, member),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _ownerUserId = value),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _status,
                    decoration: InputDecoration(
                      labelText: _t(context, 'status'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'open',
                        child: Text(_statusText(context, 'open')),
                      ),
                      DropdownMenuItem(
                        value: 'in_progress',
                        child: Text(_t(context, 'task_status_in_progress')),
                      ),
                      DropdownMenuItem(
                        value: 'blocked',
                        child: Text(_t(context, 'task_status_blocked')),
                      ),
                      DropdownMenuItem(
                        value: 'done',
                        child: Text(_t(context, 'task_status_done')),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _status = value ?? _status),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickDueDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    _dueAt == null
                        ? _t(context, 'due_date')
                        : _formatDate(_dueAt!.toIso8601String()),
                  ),
                ),
                if (_dueAt != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: _t(context, 'clear_due_date'),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _dueAt = null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _notesCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  labelText: _t(context, 'note'),
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context, false),
                  child: Text(_t(context, 'cancel')),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    _isEdit
                        ? _t(context, 'save_action_item')
                        : _t(context, 'create_action_item'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IncidentLinkDialog extends ConsumerStatefulWidget {
  final String incidentId;
  final String spaceId;

  const _IncidentLinkDialog({required this.incidentId, required this.spaceId});

  @override
  ConsumerState<_IncidentLinkDialog> createState() =>
      _IncidentLinkDialogState();
}

class _IncidentLinkDialogState extends ConsumerState<_IncidentLinkDialog> {
  late final Future<_IncidentLinkOptions> _optionsFuture;
  String _targetType = 'doc';
  String? _targetId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _optionsFuture = _loadOptions();
  }

  Future<_IncidentLinkOptions> _loadOptions() async {
    final api = ref.read(apiClientProvider);
    final responses = await Future.wait([
      api.dio.get(
        '/kb/spaces/${widget.spaceId}/docs',
        queryParameters: {'published_only': false},
      ),
      api.dio.get(
        '/sop/spaces/${widget.spaceId}/sops',
        queryParameters: {'published_only': false},
      ),
    ]);
    return _IncidentLinkOptions(
      docs: _asJsonList(responses[0].data),
      sops: _asJsonList(responses[1].data),
    );
  }

  Future<void> _save() async {
    if ((_targetId ?? '').isEmpty) {
      setState(() => _error = _t(context, 'select_record_to_link'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await api.dio.post(
        '/incidents/${widget.incidentId}/links',
        data: {'target_type': _targetType, 'target_id': _targetId, 'label': ''},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogScaffold(
      title: _t(context, 'link_sop_or_doc'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      body: FutureBuilder<_IncidentLinkOptions>(
        future: _optionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '${_t(context, 'failed_to_load_link_options')}: ${snapshot.error}',
              ),
            );
          }
          final options =
              snapshot.data ?? const _IncidentLinkOptions(docs: [], sops: []);
          final records = _targetType == 'doc' ? options.docs : options.sops;
          final selectedExists = records.any(
            (row) => (row['id'] ?? '').toString() == (_targetId ?? ''),
          );
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _targetType,
                  decoration: InputDecoration(
                    labelText: _t(context, 'record_type'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'doc',
                      child: Text(_t(context, 'kb_doc')),
                    ),
                    DropdownMenuItem(
                      value: 'sop',
                      child: Text(_t(context, 'sops')),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _targetType = value ?? _targetType;
                          _targetId = null;
                        }),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: records.isEmpty
                      ? Center(
                          child: Text(
                            _targetType == 'doc'
                                ? _t(context, 'no_kb_docs_available_in_space')
                                : _t(context, 'no_sops_available_in_space'),
                          ),
                        )
                      : DropdownButtonFormField<String>(
                          initialValue: selectedExists ? _targetId : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: _t(context, 'record'),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(16),
                              ),
                            ),
                          ),
                          items: [
                            for (final record in records)
                              DropdownMenuItem<String>(
                                value: (record['id'] ?? '').toString(),
                                child: Text(
                                  '${record['title'] ?? _t(context, 'untitled')} (${record['slug'] ?? ''})',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _targetId = value),
                        ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
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
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.pop(context, false),
                      child: Text(_t(context, 'cancel')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: Text(_t(context, 'link_record')),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IncidentProfileDialog extends ConsumerStatefulWidget {
  final String incidentId;
  final String spaceId;
  final JsonMap existing;

  const _IncidentProfileDialog({
    required this.incidentId,
    required this.spaceId,
    required this.existing,
  });

  @override
  ConsumerState<_IncidentProfileDialog> createState() =>
      _IncidentProfileDialogState();
}

class _IncidentProfileDialogState
    extends ConsumerState<_IncidentProfileDialog> {
  late final Future<List<JsonMap>> _membersFuture;
  late final TextEditingController _escalationNotesCtrl;
  late final TextEditingController _blastRadiusCtrl;
  String _incidentType = 'service';
  String? _onCallUserId;
  String _escalationPolicy = 'standard';
  String _escalationStatus = 'normal';
  bool _publicEnabled = true;
  bool _privateEnabled = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _incidentType = _stringOptionOrFallback(
      existing['incident_type'],
      _incidentTypeOptions,
      'service',
    );
    _onCallUserId =
        (existing['on_call_user_id'] ?? '').toString().trim().isEmpty
        ? null
        : (existing['on_call_user_id'] ?? '').toString();
    _escalationPolicy = _stringOptionOrFallback(
      existing['escalation_policy'],
      _escalationPolicyOptions,
      'standard',
    );
    _escalationStatus = _stringOptionOrFallback(
      existing['escalation_status'],
      _escalationStateOptions,
      'normal',
    );
    _escalationNotesCtrl = TextEditingController(
      text: (existing['escalation_notes'] ?? '').toString(),
    );
    _blastRadiusCtrl = TextEditingController(
      text: (existing['blast_radius_summary'] ?? '').toString(),
    );
    _publicEnabled = existing['public_status_enabled'] != false;
    _privateEnabled = existing['private_status_enabled'] != false;
    _membersFuture = _loadMembers();
  }

  @override
  void dispose() {
    _escalationNotesCtrl.dispose();
    _blastRadiusCtrl.dispose();
    super.dispose();
  }

  Future<List<JsonMap>> _loadMembers() async {
    return _fetchSpaceMembersDetailed(ref, widget.spaceId);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await api.dio.put(
        '/incidents/${widget.incidentId}/profile',
        data: {
          'incident_type': _incidentType,
          'on_call_user_id': _onCallUserId,
          'escalation_policy': _escalationPolicy,
          'escalation_status': _escalationStatus,
          'escalation_notes': _escalationNotesCtrl.text.trim(),
          'blast_radius_summary': _blastRadiusCtrl.text.trim(),
          'public_status_enabled': _publicEnabled,
          'private_status_enabled': _privateEnabled,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogScaffold(
      title: _t(context, 'incident_profile'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      body: FutureBuilder<List<JsonMap>>(
        future: _membersFuture,
        builder: (context, snapshot) {
          final members = snapshot.data ?? const <JsonMap>[];
          final selectedOnCallUserId =
              members.any(
                (member) =>
                    (member['user_id'] ?? '').toString() == _onCallUserId,
              )
              ? _onCallUserId
              : null;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _incidentType,
                        decoration: InputDecoration(
                          labelText: _t(context, 'incident_type'),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(16)),
                          ),
                        ),
                        items: [
                          for (final value in _incidentTypeOptions)
                            DropdownMenuItem(
                              value: value,
                              child: Text(_incidentTypeText(context, value)),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () => _incidentType = v ?? _incidentType,
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: selectedOnCallUserId,
                        decoration: InputDecoration(
                          labelText: _t(context, 'on_call_owner'),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(16)),
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
                                (member['name'] ??
                                        member['email'] ??
                                        _t(context, 'member_label'))
                                    .toString(),
                              ),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _onCallUserId = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _escalationPolicy,
                        decoration: InputDecoration(
                          labelText: _t(context, 'escalation_policy'),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(16)),
                          ),
                        ),
                        items: [
                          for (final value in _escalationPolicyOptions)
                            DropdownMenuItem(
                              value: value,
                              child: Text(
                                _escalationPolicyText(context, value),
                              ),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () =>
                                    _escalationPolicy = v ?? _escalationPolicy,
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _escalationStatus,
                        decoration: InputDecoration(
                          labelText: _t(context, 'escalation_state'),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(16)),
                          ),
                        ),
                        items: [
                          for (final value in _escalationStateOptions)
                            DropdownMenuItem(
                              value: value,
                              child: Text(_escalationStateText(context, value)),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () =>
                                    _escalationStatus = v ?? _escalationStatus,
                              ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _blastRadiusCtrl,
                  decoration: InputDecoration(
                    labelText: _t(context, 'blast_radius_summary'),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _escalationNotesCtrl,
                  decoration: InputDecoration(
                    labelText: _t(context, 'escalation_notes'),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                  ),
                  minLines: 3,
                  maxLines: 5,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _publicEnabled,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_t(context, 'enable_public_status_stream')),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _publicEnabled = v),
                ),
                SwitchListTile(
                  value: _privateEnabled,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_t(context, 'enable_private_status_stream')),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _privateEnabled = v),
                ),
                if (_error != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.pop(context, false),
                      child: Text(_t(context, 'cancel')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: _busy
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
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IncidentImpactDialog extends ConsumerStatefulWidget {
  final String incidentId;
  final JsonMap? existingImpact;

  const _IncidentImpactDialog({required this.incidentId, this.existingImpact});

  @override
  ConsumerState<_IncidentImpactDialog> createState() =>
      _IncidentImpactDialogState();
}

class _IncidentImpactDialogState extends ConsumerState<_IncidentImpactDialog> {
  late final TextEditingController _serviceCtrl;
  late final TextEditingController _notesCtrl;
  String _impactLevel = 'degraded';
  String _blastRadius = 'single-service';
  bool _customerFacing = true;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existingImpact != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingImpact;
    _serviceCtrl = TextEditingController(
      text: (existing?['service_name'] ?? '').toString(),
    );
    _notesCtrl = TextEditingController(
      text: (existing?['notes_md'] ?? '').toString(),
    );
    _impactLevel = _stringOptionOrFallback(
      existing?['impact_level'],
      _impactLevelOptions,
      'degraded',
    );
    _blastRadius = _stringOptionOrFallback(
      existing?['blast_radius'],
      _blastRadiusOptions,
      'single-service',
    );
    _customerFacing = existing?['customer_facing'] != false;
  }

  @override
  void dispose() {
    _serviceCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final serviceName = _serviceCtrl.text.trim();
      if (serviceName.isEmpty) {
        setState(() => _error = _t(context, 'service_name_required'));
        return;
      }
      final payload = {
        'service_name': serviceName,
        'impact_level': _impactLevel,
        'blast_radius': _blastRadius,
        'customer_facing': _customerFacing,
        'notes_md': _notesCtrl.text.trim(),
      };
      if (_isEdit) {
        await api.dio.put(
          '/incidents/${widget.incidentId}/impacts/${widget.existingImpact!['id']}',
          data: payload,
        );
      } else {
        await api.dio.post(
          '/incidents/${widget.incidentId}/impacts',
          data: payload,
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
    return _DialogScaffold(
      title: _isEdit
          ? _t(context, 'edit_impacted_service')
          : _t(context, 'add_impacted_service'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _serviceCtrl,
              decoration: InputDecoration(
                labelText: _t(context, 'service_name'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _impactLevel,
                    decoration: InputDecoration(
                      labelText: _t(context, 'impact_level'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: [
                      for (final value in _impactLevelOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_impactLevelText(context, value)),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) =>
                              setState(() => _impactLevel = v ?? _impactLevel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _blastRadius,
                    decoration: InputDecoration(
                      labelText: _t(context, 'blast_radius'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: [
                      for (final value in _blastRadiusOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_blastRadiusText(context, value)),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) =>
                              setState(() => _blastRadius = v ?? _blastRadius),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _customerFacing,
              contentPadding: EdgeInsets.zero,
              title: Text(_t(context, 'customer_facing')),
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _customerFacing = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _notesCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  labelText: _t(context, 'notes'),
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context, false),
                  child: Text(_t(context, 'cancel')),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    _isEdit ? _t(context, 'save') : _t(context, 'create'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IncidentStatusUpdateDialog extends ConsumerStatefulWidget {
  final String incidentId;
  final JsonMap incidentDetail;
  final bool allowPublic;
  final bool allowPrivate;

  const _IncidentStatusUpdateDialog({
    required this.incidentId,
    required this.incidentDetail,
    required this.allowPublic,
    required this.allowPrivate,
  });

  @override
  ConsumerState<_IncidentStatusUpdateDialog> createState() =>
      _IncidentStatusUpdateDialogState();
}

class _IncidentStatusUpdateDialogState
    extends ConsumerState<_IncidentStatusUpdateDialog> {
  late final TextEditingController _statusCtrl;
  late final HtmlEditorController _messageCtrl;
  late final HtmlEditorController _postmortemCtrl;
  late final String _initialPostmortem;
  String _streamType = 'private';
  late String _incidentStatus;
  bool _busy = false;
  String? _error;

  String get _currentIncidentStatus =>
      (widget.incidentDetail['status'] ?? 'open').toString();

  bool get _showPostmortemEditor => _incidentStatus == 'resolved';

  @override
  void initState() {
    super.initState();
    _statusCtrl = TextEditingController(text: 'update');
    _messageCtrl = HtmlEditorController();
    _postmortemCtrl = HtmlEditorController();
    _initialPostmortem =
        widget.incidentDetail['postmortem_md']?.toString() ?? '';
    _incidentStatus = _currentIncidentStatus;
    if (!widget.allowPrivate && widget.allowPublic) {
      _streamType = 'public';
    }
  }

  @override
  void dispose() {
    _statusCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fallbackStatusLabel = _incidentStatus == _currentIncidentStatus
          ? 'update'
          : _statusText(context, _incidentStatus);
      final message = await readEditorDocumentText(_messageCtrl);
      if (message.isEmpty) {
        setState(() => _error = _t(context, 'message_required'));
        return;
      }
      final api = ref.read(apiClientProvider);
      if (_incidentStatus != _currentIncidentStatus) {
        await api.dio.put(
          '/incidents/${widget.incidentId}',
          data: {
            'title': (widget.incidentDetail['title'] ?? '').toString(),
            'status': _incidentStatus,
            'severity':
                (widget.incidentDetail['severity'] as num?)?.toInt() ?? 3,
            'incident_type':
                (widget.incidentDetail['incident_type'] ?? 'service')
                    .toString(),
            'summary_md': widget.incidentDetail['summary_md']?.toString() ?? '',
            'transition_note': '',
          },
        );
      }
      if (_showPostmortemEditor) {
        final postmortem = await readEditorDocumentText(_postmortemCtrl);
        await api.dio.put(
          '/incidents/${widget.incidentId}/meta',
          data: {
            'postmortem_md': postmortem.isEmpty
                ? _initialPostmortem
                : postmortem,
          },
        );
      }
      await api.dio.post(
        '/incidents/${widget.incidentId}/status-updates',
        data: {
          'stream_type': _streamType,
          'status': _statusCtrl.text.trim().isEmpty
              ? fallbackStatusLabel
              : _statusCtrl.text.trim(),
          'message_md': message,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final streamOptions = <String>[
      if (widget.allowPrivate || !widget.allowPublic) 'private',
      if (widget.allowPublic) 'public',
    ];
    final selectedStream = _stringOptionOrFallback(
      _streamType,
      streamOptions,
      streamOptions.isEmpty ? 'private' : streamOptions.first,
    );
    return _DialogScaffold(
      title: _t(context, 'status_update'),
      subtitle: _t(context, 'incidents'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      headerBadges: <Widget>[
        _StatusChip(_currentIncidentStatus),
        if (_incidentStatus != _currentIncidentStatus)
          Chip(label: Text(_statusText(context, _incidentStatus))),
      ],
      primaryAction: FilledButton.icon(
        onPressed: _busy ? null : _save,
        icon: _busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.send_outlined),
        label: Text(_t(context, 'publish_update')),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1120;
          final settingsPanel = AppFlatCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.incidentDetail['title']?.toString() ??
                        _t(context, 'incidents'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  WorkspaceInlineStrip(
                    spacing: 8,
                    children: [
                      _StatusChip(_currentIncidentStatus),
                      Chip(
                        label: Text(
                          '${_t(context, 'severity')} '
                          '${widget.incidentDetail['severity'] ?? 3}',
                        ),
                      ),
                      Chip(
                        label: Text(
                          _incidentTypeText(
                            context,
                            (widget.incidentDetail['incident_type'] ??
                                    'service')
                                .toString(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: selectedStream,
                    decoration: InputDecoration(
                      labelText: _t(context, 'stream'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: [
                      for (final value in streamOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_t(context, value)),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _streamType = v ?? _streamType),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _incidentStatus,
                    decoration: InputDecoration(
                      labelText: _t(context, 'status'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'open',
                        child: Text(_statusText(context, 'open')),
                      ),
                      DropdownMenuItem(
                        value: 'monitoring',
                        child: Text(_statusText(context, 'monitoring')),
                      ),
                      DropdownMenuItem(
                        value: 'resolved',
                        child: Text(_statusText(context, 'resolved')),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _incidentStatus = value ?? _incidentStatus,
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _statusCtrl,
                    decoration: InputDecoration(
                      labelText: _t(context, 'status_label'),
                      hintText: _incidentStatus == _currentIncidentStatus
                          ? _t(context, 'status_update')
                          : _statusText(context, _incidentStatus),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                  ),
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
          );
          final updatePanel = AppFlatCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _t(context, 'status_updates'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  RichEditor(
                    controller: _messageCtrl,
                    initialContent: '',
                    hint: _t(context, 'message'),
                    height: wide ? 520 : 420,
                    compact: true,
                    attachmentOptions: RichEditorAttachmentOptions(
                      usage: 'incident_attachment',
                      spaceId: widget.incidentDetail['space_id']?.toString(),
                      attachEntityType: 'incident',
                      attachEntityId: widget.incidentId,
                    ),
                  ),
                ],
              ),
            ),
          );
          final postmortemPanel = _showPostmortemEditor
              ? AppFlatCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _t(context, 'postmortem'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        RichEditor(
                          controller: _postmortemCtrl,
                          initialContent: _initialPostmortem,
                          hint: _t(context, 'postmortem'),
                          height: wide ? 420 : 360,
                          compact: true,
                          attachmentOptions: RichEditorAttachmentOptions(
                            usage: 'incident_attachment',
                            spaceId: widget.incidentDetail['space_id']
                                ?.toString(),
                            attachEntityType: 'incident',
                            attachEntityId: widget.incidentId,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : null;
          if (!wide) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                settingsPanel,
                const SizedBox(height: 16),
                updatePanel,
                if (postmortemPanel != null) ...<Widget>[
                  const SizedBox(height: 16),
                  postmortemPanel,
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 360,
                child: SingleChildScrollView(child: settingsPanel),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    updatePanel,
                    if (postmortemPanel != null) ...<Widget>[
                      const SizedBox(height: 16),
                      postmortemPanel,
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _IncidentTemplateManagerDialog extends ConsumerStatefulWidget {
  final String spaceId;
  const _IncidentTemplateManagerDialog({required this.spaceId});

  @override
  ConsumerState<_IncidentTemplateManagerDialog> createState() =>
      _IncidentTemplateManagerDialogState();
}

class _IncidentTemplateManagerDialogState
    extends ConsumerState<_IncidentTemplateManagerDialog> {
  late Future<List<JsonMap>> _future;
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<JsonMap>> _load() async {
    final api = ref.read(apiClientProvider);
    final r = await api.dio.get(
      '/incidents/spaces/${widget.spaceId}/templates',
    );
    return _asJsonList(r.data);
  }

  void _refresh() {
    setState(() {
      _error = null;
      _future = _load();
    });
  }

  Future<void> _openTemplate({JsonMap? existing}) async {
    final changed = await _showLargeDialog<bool>(
      context,
      _IncidentTemplateDialog(
        spaceId: widget.spaceId,
        existingTemplate: existing,
      ),
      announcement: existing == null
          ? _t(context, 'new_incident_template')
          : _t(context, 'edit_incident_template'),
    );
    if (changed == true) {
      _changed = true;
      _refresh();
    }
  }

  Future<void> _deleteTemplate(String templateId) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t(context, 'delete_template')),
        content: Text(_t(context, 'delete_incident_template_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_t(context, 'delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = ref.read(apiClientProvider);
    try {
      await api.dio.delete('/incidents/templates/$templateId');
      _changed = true;
      _refresh();
    } catch (e) {
      setState(() => _error = _errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogScaffold(
      title: _t(context, 'incident_templates'),
      onClose: () => Navigator.pop(context, _changed),
      body: FutureBuilder<List<JsonMap>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '${_t(context, 'failed_to_load_templates')}: ${snapshot.error}',
              ),
            );
          }
          final rows = snapshot.data ?? const <JsonMap>[];
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => _openTemplate(),
                      icon: const Icon(Icons.add),
                      label: Text(_t(context, 'new_template')),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
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
              Expanded(
                child: rows.isEmpty
                    ? Center(child: Text(_t(context, 'no_templates_yet')))
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          return Material(
                            color: Colors.transparent,
                            child: ListTile(
                              leading: const Icon(Icons.inventory_2_outlined),
                              title: Text((row['name'] ?? '').toString()),
                              subtitle: Text(
                                '${(row['incident_type'] ?? '').toString()} • S${(row['severity'] ?? 3)}'
                                '${row['active'] == false ? ' • ${_t(context, 'inactive')}' : ''}',
                              ),
                              onTap: () => _openTemplate(existing: row),
                              trailing: IconButton(
                                tooltip: _t(context, 'delete'),
                                onPressed: () => _deleteTemplate(
                                  (row['id'] ?? '').toString(),
                                ),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _IncidentTemplateDialog extends ConsumerStatefulWidget {
  final String spaceId;
  final JsonMap? existingTemplate;

  const _IncidentTemplateDialog({required this.spaceId, this.existingTemplate});

  @override
  ConsumerState<_IncidentTemplateDialog> createState() =>
      _IncidentTemplateDialogState();
}

class _IncidentTemplateDialogState
    extends ConsumerState<_IncidentTemplateDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _titleCtrl;
  late final HtmlEditorController _summaryCtrl;
  late final HtmlEditorController _postmortemCtrl;
  late final String _initialSummaryTemplate;
  late final String _initialPostmortemTemplate;
  late final TextEditingController _impactsCtrl;
  String _incidentType = 'service';
  int _severity = 3;
  bool _active = true;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existingTemplate != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingTemplate;
    _nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    _titleCtrl = TextEditingController(
      text: (existing?['title_template'] ?? '').toString(),
    );
    _summaryCtrl = HtmlEditorController();
    _postmortemCtrl = HtmlEditorController();
    _initialSummaryTemplate = (existing?['summary_template_md'] ?? '')
        .toString();
    _initialPostmortemTemplate = (existing?['postmortem_template_md'] ?? '')
        .toString();
    _incidentType = (existing?['incident_type'] ?? 'service').toString();
    _severity = (existing?['severity'] as num?)?.toInt() ?? 3;
    _active = existing?['active'] != false;
    final impacts = _asJsonList(existing?['default_impacts'] ?? const []);
    _impactsCtrl = TextEditingController(
      text: impacts
          .map(
            (row) =>
                '${(row['service_name'] ?? '').toString()}|'
                '${(row['impact_level'] ?? 'degraded').toString()}|'
                '${(row['blast_radius'] ?? 'single-service').toString()}|'
                '${row['customer_facing'] == true ? 'true' : 'false'}|'
                '${(row['notes_md'] ?? '').toString()}',
          )
          .join('\n'),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _titleCtrl.dispose();
    _impactsCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _parseImpacts() {
    final out = <Map<String, dynamic>>[];
    for (final raw in _impactsCtrl.text.split('\n')) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      if (parts.isEmpty) continue;
      out.add({
        'service_name': parts[0].trim(),
        'impact_level': parts.length > 1 && parts[1].trim().isNotEmpty
            ? parts[1].trim()
            : 'degraded',
        'blast_radius': parts.length > 2 && parts[2].trim().isNotEmpty
            ? parts[2].trim()
            : 'single-service',
        'customer_facing': parts.length > 3
            ? parts[3].trim().toLowerCase() == 'true'
            : true,
        'notes_md': parts.length > 4 ? parts.sublist(4).join('|').trim() : '',
      });
    }
    return out;
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_nameCtrl.text.trim().isEmpty) {
        setState(() => _error = _t(context, 'template_name_required'));
        return;
      }
      final summaryTemplate = await readEditorDocumentText(_summaryCtrl);
      final postmortemTemplate = await readEditorDocumentText(_postmortemCtrl);
      final payload = {
        'name': _nameCtrl.text.trim(),
        'incident_type': _incidentType,
        'severity': _severity,
        'title_template': _titleCtrl.text.trim(),
        'summary_template_md': summaryTemplate,
        'postmortem_template_md': postmortemTemplate,
        'default_impacts': _parseImpacts(),
        'active': _active,
      };
      final api = ref.read(apiClientProvider);
      if (_isEdit) {
        await api.dio.put(
          '/incidents/templates/${widget.existingTemplate!['id']}',
          data: payload,
        );
      } else {
        await api.dio.post(
          '/incidents/spaces/${widget.spaceId}/templates',
          data: payload,
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
    return _DialogScaffold(
      title: _isEdit
          ? _t(context, 'edit_incident_template')
          : _t(context, 'new_incident_template'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      scrollBody: true,
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(_t(context, 'cancel')),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_isEdit ? _t(context, 'save') : _t(context, 'create')),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: _t(context, 'template_name'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _incidentType,
                    decoration: InputDecoration(
                      labelText: _t(context, 'incident_type'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: [
                      for (final value in _incidentTypeOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_incidentTypeText(context, value)),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(
                            () => _incidentType = v ?? _incidentType,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _severity,
                    decoration: InputDecoration(
                      labelText: _t(context, 'severity'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1')),
                      DropdownMenuItem(value: 2, child: Text('2')),
                      DropdownMenuItem(value: 3, child: Text('3')),
                      DropdownMenuItem(value: 4, child: Text('4')),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _severity = v ?? _severity),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                labelText: _t(context, 'suggested_title'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _t(context, 'summary_template_html'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 560,
              child: RichEditor(
                controller: _summaryCtrl,
                initialContent: _initialSummaryTemplate,
                hint: _t(context, 'summary_template_hint'),
                height: 440,
                compact: true,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _t(context, 'postmortem_template_html'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 560,
              child: RichEditor(
                controller: _postmortemCtrl,
                initialContent: _initialPostmortemTemplate,
                hint: _t(context, 'postmortem_template_hint'),
                height: 440,
                compact: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _impactsCtrl,
              minLines: 3,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: _t(context, 'default_impacts_format'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
            ),
            SwitchListTile(
              value: _active,
              contentPadding: EdgeInsets.zero,
              title: Text(_t(context, 'active_label')),
              onChanged: _busy ? null : (v) => setState(() => _active = v),
            ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
