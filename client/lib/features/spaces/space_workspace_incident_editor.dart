// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Incident creation and editing UI for the shared space workspace.

part of 'space_workspace_screen.dart';

class _IncidentEditorDialog extends ConsumerStatefulWidget {
  final String spaceId;
  final String? folderId;
  final JsonMap? existingIncidentDetail;
  const _IncidentEditorDialog({
    required this.spaceId,
    this.folderId,
    this.existingIncidentDetail,
  });

  @override
  ConsumerState<_IncidentEditorDialog> createState() =>
      _IncidentEditorDialogState();
}

class _IncidentEditorDialogState extends ConsumerState<_IncidentEditorDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _transitionNoteCtrl;
  late final HtmlEditorController _summaryCtrl;
  late final Future<List<JsonMap>> _templatesFuture;
  late final String _initialSummary;
  int _severity = 3;
  String _status = 'open';
  String _incidentType = 'service';
  String? _templateId;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existingIncidentDetail != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingIncidentDetail;
    _titleCtrl = TextEditingController(
      text: existing?['title']?.toString() ?? '',
    );
    _transitionNoteCtrl = TextEditingController();
    _initialSummary = existing?['summary_md']?.toString() ?? '';
    _summaryCtrl = HtmlEditorController();
    _severity = (existing?['severity'] as num?)?.toInt() ?? 3;
    _status = existing?['status']?.toString() ?? 'open';
    _incidentType = (existing?['incident_type'] ?? 'service').toString();
    _templateId = (existing?['template_id'] ?? '').toString().trim().isEmpty
        ? null
        : (existing?['template_id'] ?? '').toString();
    _templatesFuture = _loadTemplates();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _transitionNoteCtrl.dispose();
    super.dispose();
  }

  Future<List<JsonMap>> _loadTemplates() async {
    try {
      final api = ref.read(apiClientProvider);
      final r = await api.dio.get(
        '/incidents/spaces/${widget.spaceId}/templates',
      );
      final rows = _asJsonList(r.data);
      rows.sort(
        (a, b) => (a['name'] ?? '').toString().compareTo(
          (b['name'] ?? '').toString(),
        ),
      );
      return rows;
    } catch (_) {
      return const [];
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
      if (title.isEmpty && _templateId == null) {
        setState(() => _error = _t(context, 'title_required_when_no_template'));
        return;
      }
      final summaryBody = await readEditorDocumentText(_summaryCtrl);
      if (_isEdit) {
        await api.dio.put(
          '/incidents/${widget.existingIncidentDetail!['id']}',
          data: {
            'title': title,
            'status': _status,
            'severity': _severity,
            'folder_id':
                widget.existingIncidentDetail?['folder_id']?.toString() ??
                widget.folderId,
            'incident_type': _incidentType,
            'summary_md': summaryBody,
            'transition_note': _transitionNoteCtrl.text.trim(),
          },
        );
      } else {
        await api.dio.post(
          '/incidents',
          data: {
            'space_id': widget.spaceId,
            'folder_id': widget.folderId,
            'title': title,
            'severity': _severity,
            'incident_type': _incidentType,
            'template_id': _templateId,
            'summary_md': summaryBody,
          },
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
          ? _t(context, 'edit_incident')
          : _t(context, 'new_incident'),
      subtitle: _t(context, 'incidents'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      scrollBody: true,
      headerBadges: <Widget>[
        Chip(label: Text('${_t(context, 'severity')} $_severity')),
        Chip(label: Text(_incidentTypeText(context, _incidentType))),
        if (_isEdit) Chip(label: Text(_statusText(context, _status))),
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
          _isEdit
              ? _t(context, 'save_incident')
              : _t(context, 'create_incident'),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1080;
          final contentMaxWidth = wide ? 1120.0 : double.infinity;
          final editorHeight = constraints.maxWidth < 480 ? 420.0 : 640.0;
          final metadataPanel = AppFlatCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _t(context, 'incident_profile'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
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
                  LayoutBuilder(
                    builder: (context, rowConstraints) {
                      final compact = rowConstraints.maxWidth < 640;
                      final typeField = DropdownButtonFormField<String>(
                        initialValue: _incidentType,
                        isExpanded: true,
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
                      );
                      final severityField = DropdownButtonFormField<int>(
                        initialValue: _severity,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: _t(context, 'severity'),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(16)),
                          ),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 1,
                            child: Text(_t(context, 'severity_1')),
                          ),
                          DropdownMenuItem(
                            value: 2,
                            child: Text(_t(context, 'severity_2')),
                          ),
                          DropdownMenuItem(
                            value: 3,
                            child: Text(_t(context, 'severity_3')),
                          ),
                          DropdownMenuItem(
                            value: 4,
                            child: Text(_t(context, 'severity_4')),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _severity = v ?? 3),
                      );
                      if (compact) {
                        return Column(
                          children: <Widget>[
                            typeField,
                            const SizedBox(height: 12),
                            severityField,
                          ],
                        );
                      }
                      return Row(
                        children: <Widget>[
                          Expanded(child: typeField),
                          const SizedBox(width: 12),
                          Expanded(child: severityField),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_isEdit)
                    DropdownButtonFormField<String>(
                      initialValue: _status,
                      isExpanded: true,
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
                          : (v) => setState(() => _status = v ?? _status),
                    )
                  else
                    FutureBuilder<List<JsonMap>>(
                      future: _templatesFuture,
                      builder: (context, snapshot) {
                        final rows = snapshot.data ?? const <JsonMap>[];
                        final activeRows = rows
                            .where((row) => row['active'] != false)
                            .toList();
                        final hasSelected = activeRows.any(
                          (row) => row['id'] == _templateId,
                        );
                        return DropdownButtonFormField<String?>(
                          initialValue: hasSelected ? _templateId : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: _t(context, 'template_optional'),
                            border: const OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(16),
                              ),
                            ),
                          ),
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(_t(context, 'no_template')),
                            ),
                            for (final row in activeRows)
                              DropdownMenuItem<String?>(
                                value: (row['id'] ?? '').toString(),
                                child: Text(
                                  '${(row['name'] ?? '').toString()} (S${(row['severity'] ?? 3)})',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) {
                                  if (value == null) {
                                    setState(() => _templateId = null);
                                    return;
                                  }
                                  final selected = activeRows
                                      .where(
                                        (row) =>
                                            (row['id'] ?? '').toString() ==
                                            value,
                                      )
                                      .toList();
                                  if (selected.isEmpty) return;
                                  final template = selected.first;
                                  setState(() {
                                    _templateId = value;
                                    _incidentType =
                                        (template['incident_type'] ??
                                                _incidentType)
                                            .toString();
                                    _severity =
                                        (template['severity'] as num?)
                                            ?.toInt() ??
                                        _severity;
                                    final suggestedTitle =
                                        (template['title_template'] ?? '')
                                            .toString()
                                            .trim();
                                    if (_titleCtrl.text.trim().isEmpty &&
                                        suggestedTitle.isNotEmpty) {
                                      _titleCtrl.text = suggestedTitle;
                                    }
                                  });
                                },
                        );
                      },
                    ),
                  const SizedBox(height: 12),
                  if (_isEdit)
                    TextField(
                      controller: _transitionNoteCtrl,
                      decoration: InputDecoration(
                        labelText: _t(context, 'transition_note'),
                        helperText: _t(context, 'transition_note_help'),
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                      ),
                      maxLines: 3,
                      minLines: 2,
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                      ),
                      child: Text(
                        _t(context, 'incident_template_autofill_help'),
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
          final editorPanel = AppFlatCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: RichEditor(
                controller: _summaryCtrl,
                initialContent: _initialSummary,
                hint: _t(context, 'incident_summary'),
                height: editorHeight,
                compact: true,
                attachmentOptions: RichEditorAttachmentOptions(
                  usage: _isEdit
                      ? 'incident_attachment'
                      : 'incident_summary_image',
                  spaceId: widget.spaceId,
                  attachEntityType: _isEdit ? 'incident' : null,
                  attachEntityId: _isEdit
                      ? widget.existingIncidentDetail!['id']?.toString()
                      : null,
                ),
              ),
            ),
          );
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    metadataPanel,
                    const SizedBox(height: 16),
                    editorPanel,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
