// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// SOP creation and editing UI for the shared space workspace.

part of 'space_workspace_screen.dart';

class _SopEditorDialog extends ConsumerStatefulWidget {
  final String spaceId;
  final String? folderId;
  final JsonMap? existingSopDetail;
  const _SopEditorDialog({
    required this.spaceId,
    this.folderId,
    this.existingSopDetail,
  });

  @override
  ConsumerState<_SopEditorDialog> createState() => _SopEditorDialogState();
}

class _SopEditorDialogState extends ConsumerState<_SopEditorDialog>
    with SingleTickerProviderStateMixin {
  static const Set<int> _cadenceOptions = <int>{1, 3, 7, 14, 30};
  late final TextEditingController _titleCtrl;
  late final TextEditingController _slugCtrl;
  late String _overviewHtml;
  late final TabController _tabs;
  late final Future<List<JsonMap>> _membersFuture;
  final List<_SopStepDraft> _steps = [];
  final List<_SopApprovalStageDraft> _approvalStages = [];
  DateTime? _reviewDueAt;
  String? _reviewerUserId;
  bool _requiresApproval = false;
  bool _scheduleEnabled = false;
  int _scheduleCadenceDays = 7;
  DateTime? _scheduleNextDueAt;
  String? _scheduleOperatorUserId;
  final Set<String> _scheduleReminderChannels = <String>{'in_app'};
  bool _busy = false;
  String? _error;
  bool _slugTouched = false;

  bool get _isEdit => widget.existingSopDetail != null;
  String? get _sopId => widget.existingSopDetail?['id']?.toString();

  int _normalizeCadence(int value) {
    return _cadenceOptions.contains(value) ? value : 7;
  }

  int _normalizeStepSeverity(int value) {
    return switch (value) {
      1 || 2 || 3 || 4 => value,
      _ => 3,
    };
  }

  String? _memberValueOrNull(String? selected, List<JsonMap> members) {
    final value = (selected ?? '').trim();
    if (value.isEmpty) return null;
    final exists = members.any(
      (member) => (member['user_id'] ?? '').toString() == value,
    );
    return exists ? value : null;
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.existingSopDetail;
    _titleCtrl = TextEditingController(
      text: existing?['title']?.toString() ?? '',
    );
    _slugCtrl = TextEditingController(
      text: existing?['slug']?.toString() ?? '',
    );
    _overviewHtml = existing?['overview_md']?.toString() ?? '';
    _tabs = TabController(length: 2, vsync: this);
    _reviewDueAt = existing?['review_due_at'] is String
        ? DateTime.tryParse(existing!['review_due_at'].toString())
        : null;
    _reviewerUserId =
        (existing?['reviewer_user_id'] ?? '').toString().trim().isEmpty
        ? null
        : (existing?['reviewer_user_id'] ?? '').toString();
    _requiresApproval = existing?['requires_approval'] == true;
    _membersFuture = _loadMembers();
    final existingSchedules = _asJsonList(
      existing?['run_schedules'] ?? const [],
    );
    if (existingSchedules.isNotEmpty) {
      final firstSchedule = existingSchedules.first;
      _scheduleEnabled = firstSchedule['enabled'] != false;
      _scheduleCadenceDays = _normalizeCadence(
        (firstSchedule['cadence_days'] as num?)?.toInt() ?? 7,
      );
      _scheduleNextDueAt = firstSchedule['next_due_at'] is String
          ? DateTime.tryParse(firstSchedule['next_due_at'].toString())
          : null;
      _scheduleOperatorUserId =
          (firstSchedule['operator_user_id'] ?? '').toString().trim().isEmpty
          ? null
          : (firstSchedule['operator_user_id'] ?? '').toString();
      final channels = _asStringList(firstSchedule['reminder_channels']);
      _scheduleReminderChannels
        ..clear()
        ..addAll(channels.isEmpty ? const ['in_app'] : channels);
    }
    final existingApprovalStages = _asJsonList(
      existing?['approval_stages'] ?? const [],
    );
    for (final stage in existingApprovalStages) {
      _approvalStages.add(
        _SopApprovalStageDraft(
          order:
              (stage['stage_order'] as num?)?.toInt() ??
              (_approvalStages.length + 1),
          approverUserId: (stage['approver_user_id'] ?? '').toString(),
          label: (stage['label'] ?? '').toString(),
          delegateApproverUserId: (stage['delegate_approver_user_id'] ?? '')
              .toString(),
          delegateStartAt: stage['delegate_start_at'] is String
              ? DateTime.tryParse(stage['delegate_start_at'].toString())
              : null,
          delegateEndAt: stage['delegate_end_at'] is String
              ? DateTime.tryParse(stage['delegate_end_at'].toString())
              : null,
        ),
      );
    }

    final existingSteps = _asJsonList(existing?['steps'] ?? const []);
    if (existingSteps.isEmpty) {
      _steps.add(_SopStepDraft(order: 1));
    } else {
      for (final s in existingSteps) {
        _steps.add(
          _SopStepDraft(
            order: (s['step_order'] as num?)?.toInt() ?? (_steps.length + 1),
            title: s['title']?.toString() ?? '',
            body: s['body_md']?.toString() ?? '',
            requiresEvidence: s['requires_evidence'] == true,
            evidenceMinFiles: (s['evidence_min_files'] as num?)?.toInt() ?? 0,
            allowedExtensions:
                ((s['evidence_allowed_extensions'] as List?) ?? const [])
                    .map((e) => e.toString())
                    .join(', '),
            followUpSeverity: _normalizeStepSeverity(
              (s['follow_up_severity'] as num?)?.toInt() ?? 3,
            ),
            followUpOwnerUserId: (s['follow_up_owner_user_id'] ?? '')
                .toString(),
            followUpTitleTemplate: (s['follow_up_title_template'] ?? '')
                .toString(),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _slugCtrl.dispose();
    _tabs.dispose();
    for (final s in _steps) {
      s.dispose();
    }
    for (final stage in _approvalStages) {
      stage.dispose();
    }
    super.dispose();
  }

  Future<List<JsonMap>> _loadMembers() async {
    return _fetchSpaceMembersDetailed(ref, widget.spaceId);
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
    setState(
      () => _reviewDueAt = DateTime(picked.year, picked.month, picked.day, 9),
    );
  }

  Future<void> _pickScheduleNextDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _scheduleNextDueAt ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(
      () => _scheduleNextDueAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        9,
      ),
    );
  }

  Future<void> _pickApprovalDelegateDate(
    int index, {
    required bool start,
  }) async {
    final current = start
        ? _approvalStages[index].delegateStartAt
        : _approvalStages[index].delegateEndAt;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      final value = DateTime(picked.year, picked.month, picked.day, 9);
      if (start) {
        _approvalStages[index].delegateStartAt = value;
      } else {
        _approvalStages[index].delegateEndAt = value;
      }
    });
  }

  void _addApprovalStage() {
    setState(() {
      _approvalStages.add(
        _SopApprovalStageDraft(order: _approvalStages.length + 1),
      );
      _requiresApproval = true;
    });
  }

  void _removeApprovalStage(int index) {
    setState(() {
      final removed = _approvalStages.removeAt(index);
      removed.dispose();
      for (var i = 0; i < _approvalStages.length; i++) {
        _approvalStages[i].order = i + 1;
      }
    });
  }

  void _addStep() {
    setState(() => _steps.add(_SopStepDraft(order: _steps.length + 1)));
  }

  void _removeStep(int index) {
    if (_steps.length <= 1) {
      _steps[index].titleCtrl.clear();
      _steps[index].clearBody();
      return;
    }
    setState(() {
      final removed = _steps.removeAt(index);
      removed.dispose();
      for (var i = 0; i < _steps.length; i++) {
        _steps[i].order = i + 1;
      }
    });
  }

  Future<void> _editStepBody(int index) async {
    final updated = await _showLargeDialog<String>(
      context,
      _SopStepBodyDialog(
        spaceId: widget.spaceId,
        sopId: _sopId,
        stepIndex: index,
        stepTitle: _steps[index].titleCtrl.text.trim().isEmpty
            ? 'Step ${index + 1}'
            : _steps[index].titleCtrl.text.trim(),
        initialBody: _steps[index].bodyHtml,
      ),
    );
    if (updated == null) return;
    setState(() {
      _steps[index].bodyHtml = updated;
    });
  }

  Future<void> _editOverview() async {
    final updated = await _showLargeDialog<String>(
      context,
      _SopOverviewDialog(
        spaceId: widget.spaceId,
        sopId: _sopId,
        initialBody: _overviewHtml,
      ),
    );
    if (updated == null) return;
    setState(() {
      _overviewHtml = updated;
    });
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final title = _titleCtrl.text.trim();
      final slug = _slugCtrl.text.trim().isEmpty
          ? _slugify(title)
          : _slugCtrl.text.trim();
      if (title.isEmpty || slug.isEmpty) {
        setState(() => _error = _t(context, 'name_and_slug_required'));
        return;
      }
      final overviewHtml = _overviewHtml.trim() == 'null' ? '' : _overviewHtml;
      String sopId;
      if (_isEdit) {
        await api.dio.put(
          '/sop/sops/$_sopId',
          data: {
            'title': title,
            'slug': slug,
            'overview_md': overviewHtml,
            'folder_id':
                widget.existingSopDetail?['folder_id']?.toString() ??
                widget.folderId,
            'review_due_at': _reviewDueAt?.toIso8601String(),
            'reviewer_user_id': _reviewerUserId,
            'requires_approval': _requiresApproval,
          },
        );
        sopId = _sopId!;
      } else {
        final r = await api.dio.post(
          '/sop/sops',
          data: {
            'space_id': widget.spaceId,
            'folder_id': widget.folderId,
            'title': title,
            'slug': slug,
            'overview_md': overviewHtml,
            'review_due_at': _reviewDueAt?.toIso8601String(),
            'reviewer_user_id': _reviewerUserId,
            'requires_approval': _requiresApproval,
          },
        );
        sopId = _asJsonMap(r.data)['id'].toString();
      }

      final stepsPayload = <JsonMap>[];
      for (var i = 0; i < _steps.length; i++) {
        final st = _steps[i];
        final stepTitle = st.titleCtrl.text.trim();
        final body = await st.readBodyHtml();
        if (stepTitle.isEmpty && body.trim().isEmpty) continue;
        stepsPayload.add({
          'step_order': i + 1,
          'title': stepTitle.isEmpty ? 'Step ${i + 1}' : stepTitle,
          'body_md': body,
          'requires_evidence': st.requiresEvidence,
          'evidence_min_files': st.evidenceMinFiles,
          'evidence_allowed_extensions': st.allowedExtensions,
          'follow_up_severity': st.followUpSeverity,
          'follow_up_owner_user_id': st.followUpOwnerUserId.trim().isEmpty
              ? null
              : st.followUpOwnerUserId,
          'follow_up_title_template': st.followUpTitleTemplate,
        });
      }
      await api.dio.put('/sop/sops/$sopId/steps', data: stepsPayload);
      await api.dio.put(
        '/sop/sops/$sopId/approval-stages',
        data: [
          for (var i = 0; i < _approvalStages.length; i++)
            if (_approvalStages[i].approverUserId.trim().isNotEmpty)
              {
                'stage_order': i + 1,
                'approver_user_id': _approvalStages[i].approverUserId,
                'label': _approvalStages[i].label.trim(),
                'delegate_approver_user_id':
                    _approvalStages[i].delegateApproverUserId.trim().isEmpty
                    ? null
                    : _approvalStages[i].delegateApproverUserId,
                'delegate_start_at': _approvalStages[i].delegateStartAt
                    ?.toIso8601String(),
                'delegate_end_at': _approvalStages[i].delegateEndAt
                    ?.toIso8601String(),
              },
        ],
      );
      await api.dio.put(
        '/sop/sops/$sopId/run-schedules',
        data: _scheduleEnabled
            ? [
                {
                  'cadence_days': _scheduleCadenceDays,
                  'next_due_at': _scheduleNextDueAt?.toIso8601String(),
                  'operator_user_id': _scheduleOperatorUserId,
                  'enabled': _scheduleEnabled,
                  'reminder_channels': _scheduleReminderChannels.toList(),
                },
              ]
            : <JsonMap>[],
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
      title: _isEdit ? _t(context, 'edit_sop') : _t(context, 'new_sop'),
      subtitle: _t(context, 'sops'),
      onClose: _busy ? null : () => Navigator.pop(context, false),
      headerBadges: <Widget>[
        Chip(label: Text('${_steps.length} ${_t(context, 'steps')}')),
        if (_requiresApproval)
          Chip(label: Text(_t(context, 'requires_approval'))),
        if (_scheduleEnabled)
          Chip(
            label: Text(
              _tf(
                context,
                'sop_schedule_every_n_days_status',
                <String, Object?>{
                  'days': _scheduleCadenceDays,
                  'status': _t(context, 'enabled'),
                },
              ),
            ),
          ),
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
          _isEdit ? _t(context, 'save_sop') : _t(context, 'create_sop'),
        ),
      ),
      secondaryActions: <WorkspaceAction>[
        WorkspaceAction(
          label: _t(context, 'generate_slug'),
          icon: Icons.auto_fix_high,
          onSelected: _busy
              ? null
              : () => _slugCtrl.text = _slugify(_titleCtrl.text),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1080;
          final contentMaxWidth = wide ? 1160.0 : double.infinity;
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
                    decoration: InputDecoration(
                      labelText: _t(context, 'title_label'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    onChanged: (_) {
                      if (!_slugTouched && _slugCtrl.text.trim().isEmpty) {
                        _slugCtrl.text = _slugify(_titleCtrl.text);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _slugCtrl,
                    decoration: InputDecoration(
                      labelText: _t(context, 'slug'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    onChanged: (_) => _slugTouched = true,
                  ),
                  const SizedBox(height: 8),
                  WorkspaceInlineStrip(
                    spacing: 8,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.auto_fix_high, size: 18),
                        label: Text(_t(context, 'generate_slug')),
                        onPressed: _busy
                            ? null
                            : () => _slugCtrl.text = _slugify(_titleCtrl.text),
                      ),
                      FilterChip(
                        label: Text(_t(context, 'requires_approval')),
                        selected: _requiresApproval,
                        onSelected: _busy
                            ? null
                            : (value) =>
                                  setState(() => _requiresApproval = value),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
          final metadataPanel = AppFlatCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _t(context, 'governance'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 10),
                  FutureBuilder<List<JsonMap>>(
                    future: _membersFuture,
                    builder: (context, snapshot) {
                      final members = snapshot.data ?? const <JsonMap>[];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButtonFormField<String?>(
                            initialValue: _memberValueOrNull(
                              _reviewerUserId,
                              members,
                            ),
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: _t(context, 'reviewer'),
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
                            onChanged: _busy
                                ? null
                                : (value) =>
                                      setState(() => _reviewerUserId = value),
                          ),
                          const SizedBox(height: 10),
                          WorkspaceInlineStrip(
                            spacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _pickReviewDueDate,
                                icon: const Icon(Icons.event_outlined),
                                label: Text(
                                  _reviewDueAt == null
                                      ? _t(context, 'review_date')
                                      : '${_reviewDueAt!.year}-${_reviewDueAt!.month.toString().padLeft(2, '0')}-${_reviewDueAt!.day.toString().padLeft(2, '0')}',
                                ),
                              ),
                              if (_reviewDueAt != null)
                                TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () =>
                                            setState(() => _reviewDueAt = null),
                                  icon: const Icon(Icons.clear),
                                  label: Text(_t(context, 'clear_review_date')),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _t(context, 'approval_chain'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _addApprovalStage,
                            icon: const Icon(Icons.rule_folder_outlined),
                            label: Text(_t(context, 'add_approval_stage')),
                          ),
                          if (_approvalStages.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              _t(
                                context,
                                'publish_requires_all_approval_stages',
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 10),
                          ],
                          for (var i = 0; i < _approvalStages.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerLowest,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant
                                        .withValues(alpha: 0.72),
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${_t(context, 'stage')} ${i + 1}',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: _t(
                                              context,
                                              'remove_stage',
                                            ),
                                            onPressed: _busy
                                                ? null
                                                : () => _removeApprovalStage(i),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<String>(
                                        initialValue: _memberValueOrNull(
                                          _approvalStages[i].approverUserId,
                                          members,
                                        ),
                                        isExpanded: true,
                                        decoration: InputDecoration(
                                          labelText: _t(context, 'approver'),
                                          border: const OutlineInputBorder(
                                            borderRadius: BorderRadius.all(
                                              Radius.circular(16),
                                            ),
                                          ),
                                        ),
                                        items: [
                                          for (final member in members)
                                            DropdownMenuItem<String>(
                                              value: (member['user_id'] ?? '')
                                                  .toString(),
                                              child: Text(
                                                (member['name'] ??
                                                        member['email'] ??
                                                        _t(
                                                          context,
                                                          'member_label',
                                                        ))
                                                    .toString(),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                        ],
                                        onChanged: _busy
                                            ? null
                                            : (value) => setState(
                                                () =>
                                                    _approvalStages[i]
                                                            .approverUserId =
                                                        value ?? '',
                                              ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextField(
                                        controller:
                                            _approvalStages[i].labelCtrl,
                                        decoration: InputDecoration(
                                          labelText: _t(context, 'label'),
                                          border: const OutlineInputBorder(
                                            borderRadius: BorderRadius.all(
                                              Radius.circular(16),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<String?>(
                                        initialValue: _memberValueOrNull(
                                          _approvalStages[i]
                                              .delegateApproverUserId,
                                          members,
                                        ),
                                        isExpanded: true,
                                        decoration: InputDecoration(
                                          labelText: _t(
                                            context,
                                            'delegate_approver',
                                          ),
                                          border: const OutlineInputBorder(
                                            borderRadius: BorderRadius.all(
                                              Radius.circular(16),
                                            ),
                                          ),
                                        ),
                                        items: [
                                          DropdownMenuItem<String?>(
                                            value: null,
                                            child: Text(
                                              _t(context, 'unassigned'),
                                            ),
                                          ),
                                          for (final member in members)
                                            DropdownMenuItem<String?>(
                                              value: (member['user_id'] ?? '')
                                                  .toString(),
                                              child: Text(
                                                (member['name'] ??
                                                        member['email'] ??
                                                        _t(
                                                          context,
                                                          'member_label',
                                                        ))
                                                    .toString(),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                        ],
                                        onChanged: _busy
                                            ? null
                                            : (value) => setState(
                                                () =>
                                                    _approvalStages[i]
                                                            .delegateApproverUserId =
                                                        value ?? '',
                                              ),
                                      ),
                                      const SizedBox(height: 8),
                                      WorkspaceInlineStrip(
                                        spacing: 8,
                                        children: [
                                          OutlinedButton.icon(
                                            onPressed: _busy
                                                ? null
                                                : () =>
                                                      _pickApprovalDelegateDate(
                                                        i,
                                                        start: true,
                                                      ),
                                            icon: const Icon(
                                              Icons.event_available_outlined,
                                            ),
                                            label: Text(
                                              _approvalStages[i]
                                                          .delegateStartAt ==
                                                      null
                                                  ? _t(
                                                      context,
                                                      'delegate_start',
                                                    )
                                                  : _formatDate(
                                                      _approvalStages[i]
                                                          .delegateStartAt
                                                          ?.toIso8601String(),
                                                    ),
                                            ),
                                          ),
                                          OutlinedButton.icon(
                                            onPressed: _busy
                                                ? null
                                                : () =>
                                                      _pickApprovalDelegateDate(
                                                        i,
                                                        start: false,
                                                      ),
                                            icon: const Icon(
                                              Icons.event_busy_outlined,
                                            ),
                                            label: Text(
                                              _approvalStages[i]
                                                          .delegateEndAt ==
                                                      null
                                                  ? _t(context, 'delegate_end')
                                                  : _formatDate(
                                                      _approvalStages[i]
                                                          .delegateEndAt
                                                          ?.toIso8601String(),
                                                    ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          Text(
                            _t(context, 'recurring_run_schedule'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 10),
                          WorkspaceInlineStrip(
                            spacing: 8,
                            children: [
                              FilterChip(
                                label: Text(_t(context, 'recurring_run')),
                                selected: _scheduleEnabled,
                                onSelected: _busy
                                    ? null
                                    : (value) => setState(
                                        () => _scheduleEnabled = value,
                                      ),
                              ),
                              if (_scheduleEnabled)
                                SizedBox(
                                  width: 140,
                                  child: DropdownButtonFormField<int>(
                                    initialValue: _normalizeCadence(
                                      _scheduleCadenceDays,
                                    ),
                                    isExpanded: true,
                                    decoration: InputDecoration(
                                      labelText: _t(context, 'cadence'),
                                      border: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(16),
                                        ),
                                      ),
                                    ),
                                    items: [
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
                                        child: Text(
                                          _t(context, 'fourteen_days'),
                                        ),
                                      ),
                                      DropdownMenuItem(
                                        value: 30,
                                        child: Text(_t(context, 'thirty_days')),
                                      ),
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (value) => setState(
                                            () => _scheduleCadenceDays =
                                                value ?? 7,
                                          ),
                                  ),
                                ),
                            ],
                          ),
                          if (_scheduleEnabled) ...[
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : _pickScheduleNextDueDate,
                              icon: const Icon(Icons.schedule_outlined),
                              label: Text(
                                _scheduleNextDueAt == null
                                    ? _t(context, 'next_due')
                                    : '${_scheduleNextDueAt!.year}-${_scheduleNextDueAt!.month.toString().padLeft(2, '0')}-${_scheduleNextDueAt!.day.toString().padLeft(2, '0')}',
                              ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String?>(
                              initialValue: _memberValueOrNull(
                                _scheduleOperatorUserId,
                                members,
                              ),
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: _t(context, 'default_operator'),
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
                                      _memberNameOrFallback(context, member),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(
                                      () => _scheduleOperatorUserId = value,
                                    ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilterChip(
                                  label: Text(_t(context, 'reminder_in_app')),
                                  selected: _scheduleReminderChannels.contains(
                                    'in_app',
                                  ),
                                  onSelected: _busy
                                      ? null
                                      : (value) => setState(() {
                                          if (value) {
                                            _scheduleReminderChannels.add(
                                              'in_app',
                                            );
                                          } else {
                                            _scheduleReminderChannels.remove(
                                              'in_app',
                                            );
                                          }
                                        }),
                                ),
                                FilterChip(
                                  label: Text(_t(context, 'reminder_email')),
                                  selected: _scheduleReminderChannels.contains(
                                    'email',
                                  ),
                                  onSelected: _busy
                                      ? null
                                      : (value) => setState(() {
                                          if (value) {
                                            _scheduleReminderChannels.add(
                                              'email',
                                            );
                                          } else {
                                            _scheduleReminderChannels.remove(
                                              'email',
                                            );
                                          }
                                        }),
                                ),
                                FilterChip(
                                  label: Text(_t(context, 'reminder_webhook')),
                                  selected: _scheduleReminderChannels.contains(
                                    'webhook',
                                  ),
                                  onSelected: _busy
                                      ? null
                                      : (value) => setState(() {
                                          if (value) {
                                            _scheduleReminderChannels.add(
                                              'webhook',
                                            );
                                          } else {
                                            _scheduleReminderChannels.remove(
                                              'webhook',
                                            );
                                          }
                                        }),
                                ),
                              ],
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          );

          Widget buildOverviewContent() {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppFlatCard(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _overviewHtml.trim().isEmpty
                        ? Text(_t(context, 'no_content'))
                        : RichContentView(content: _overviewHtml),
                  ),
                ),
              ],
            );
          }

          Widget buildStepsContent() {
            return Column(
              children: [
                for (var i = 0; i < _steps.length; i++)
                  AppFlatCard(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_t(context, 'step')} ${i + 1}',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: _t(context, 'remove_step'),
                                onPressed: _busy ? null : () => _removeStep(i),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _steps[i].titleCtrl,
                            decoration: InputDecoration(
                              labelText: _t(context, 'step_title'),
                              border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHigh
                                  .withValues(alpha: 0.35),
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.6),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _steps[i].bodyHtml.trim().isEmpty
                                      ? _t(context, 'no_instructions_added_yet')
                                      : _richPreviewText(_steps[i].bodyHtml),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    FilledButton.tonalIcon(
                                      onPressed: _busy
                                          ? null
                                          : () => _editStepBody(i),
                                      icon: const Icon(Icons.edit_note),
                                      label: Text(
                                        _steps[i].bodyHtml.trim().isEmpty
                                            ? _t(context, 'add_instructions')
                                            : _t(context, 'edit_instructions'),
                                      ),
                                    ),
                                    if (_steps[i].bodyHtml.trim().isNotEmpty)
                                      OutlinedButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : () => setState(
                                                () => _steps[i].bodyHtml = '',
                                              ),
                                        icon: const Icon(Icons.clear),
                                        label: Text(_t(context, 'clear_body')),
                                      ),
                                    FilterChip(
                                      label: Text(
                                        _t(context, 'evidence_required'),
                                      ),
                                      selected: _steps[i].requiresEvidence,
                                      onSelected: _busy
                                          ? null
                                          : (value) => setState(
                                              () => _steps[i].requiresEvidence =
                                                  value,
                                            ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                LayoutBuilder(
                                  builder: (context, rowConstraints) {
                                    final compact =
                                        rowConstraints.maxWidth < 720;
                                    final minFilesField = SizedBox(
                                      width: compact ? double.infinity : 140,
                                      child: DropdownButtonFormField<int>(
                                        initialValue:
                                            _steps[i].evidenceMinFiles,
                                        isExpanded: true,
                                        decoration: InputDecoration(
                                          labelText: _t(context, 'min_files'),
                                        ),
                                        items: const [
                                          DropdownMenuItem(
                                            value: 0,
                                            child: Text('0'),
                                          ),
                                          DropdownMenuItem(
                                            value: 1,
                                            child: Text('1'),
                                          ),
                                          DropdownMenuItem(
                                            value: 2,
                                            child: Text('2'),
                                          ),
                                          DropdownMenuItem(
                                            value: 3,
                                            child: Text('3'),
                                          ),
                                        ],
                                        onChanged: _busy
                                            ? null
                                            : (value) => setState(() {
                                                _steps[i].evidenceMinFiles =
                                                    value ?? 0;
                                                if (_steps[i].evidenceMinFiles >
                                                    0) {
                                                  _steps[i].requiresEvidence =
                                                      true;
                                                }
                                              }),
                                      ),
                                    );
                                    final extensionsField = TextField(
                                      controller:
                                          _steps[i].allowedExtensionsCtrl,
                                      decoration: InputDecoration(
                                        labelText: _t(
                                          context,
                                          'allowed_extensions',
                                        ),
                                        helperText: _t(
                                          context,
                                          'allowed_extensions_help',
                                        ),
                                      ),
                                    );
                                    if (compact) {
                                      return Column(
                                        children: <Widget>[
                                          minFilesField,
                                          const SizedBox(height: 10),
                                          extensionsField,
                                        ],
                                      );
                                    }
                                    return Row(
                                      children: <Widget>[
                                        minFilesField,
                                        const SizedBox(width: 12),
                                        Expanded(child: extensionsField),
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 10),
                                LayoutBuilder(
                                  builder: (context, rowConstraints) {
                                    final compact =
                                        rowConstraints.maxWidth < 720;
                                    final severityField = SizedBox(
                                      width: compact ? double.infinity : 170,
                                      child: DropdownButtonFormField<int>(
                                        initialValue: _normalizeStepSeverity(
                                          _steps[i].followUpSeverity,
                                        ),
                                        isExpanded: true,
                                        decoration: InputDecoration(
                                          labelText: _t(
                                            context,
                                            'follow_up_severity',
                                          ),
                                        ),
                                        items: [
                                          DropdownMenuItem(
                                            value: 1,
                                            child: Text(
                                              _t(context, 'severity_1'),
                                            ),
                                          ),
                                          DropdownMenuItem(
                                            value: 2,
                                            child: Text(
                                              _t(context, 'severity_2'),
                                            ),
                                          ),
                                          DropdownMenuItem(
                                            value: 3,
                                            child: Text(
                                              _t(context, 'severity_3'),
                                            ),
                                          ),
                                          DropdownMenuItem(
                                            value: 4,
                                            child: Text(
                                              _t(context, 'severity_4'),
                                            ),
                                          ),
                                        ],
                                        onChanged: _busy
                                            ? null
                                            : (value) => setState(
                                                () =>
                                                    _steps[i].followUpSeverity =
                                                        value ?? 3,
                                              ),
                                      ),
                                    );
                                    final ownerField = FutureBuilder<List<JsonMap>>(
                                      future: _membersFuture,
                                      builder: (context, snapshot) {
                                        final members =
                                            snapshot.data ?? const <JsonMap>[];
                                        return DropdownButtonFormField<String?>(
                                          initialValue: _memberValueOrNull(
                                            _steps[i].followUpOwnerUserId,
                                            members,
                                          ),
                                          isExpanded: true,
                                          decoration: InputDecoration(
                                            labelText: _t(
                                              context,
                                              'follow_up_owner',
                                            ),
                                          ),
                                          items: [
                                            DropdownMenuItem<String?>(
                                              value: null,
                                              child: Text(
                                                _t(context, 'unassigned'),
                                              ),
                                            ),
                                            for (final member in members)
                                              DropdownMenuItem<String?>(
                                                value: (member['user_id'] ?? '')
                                                    .toString(),
                                                child: Text(
                                                  (member['name'] ??
                                                          member['email'] ??
                                                          _t(
                                                            context,
                                                            'member_label',
                                                          ))
                                                      .toString(),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                          ],
                                          onChanged: _busy
                                              ? null
                                              : (value) => setState(
                                                  () =>
                                                      _steps[i]
                                                              .followUpOwnerUserId =
                                                          value ?? '',
                                                ),
                                        );
                                      },
                                    );
                                    if (compact) {
                                      return Column(
                                        children: <Widget>[
                                          severityField,
                                          const SizedBox(height: 10),
                                          ownerField,
                                        ],
                                      );
                                    }
                                    return Row(
                                      children: <Widget>[
                                        severityField,
                                        const SizedBox(width: 12),
                                        Expanded(child: ownerField),
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _steps[i].followUpTitleCtrl,
                                  decoration: InputDecoration(
                                    labelText: _t(
                                      context,
                                      'follow_up_title_template',
                                    ),
                                    helperText: _t(
                                      context,
                                      'follow_up_title_template_help',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          }

          Widget buildContentPanel() {
            return AppFlatCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AnimatedBuilder(
                  animation: _tabs,
                  builder: (context, _) {
                    final activeTab = _tabs.index;
                    final activeContent = activeTab == 0
                        ? buildOverviewContent()
                        : buildStepsContent();
                    final sectionAction = activeTab == 0
                        ? OutlinedButton.icon(
                            onPressed: _busy ? null : _editOverview,
                            icon: const Icon(Icons.edit_outlined),
                            label: Text(
                              '${_t(context, 'edit')} ${_t(context, 'overview')}',
                            ),
                          )
                        : FilledButton.tonalIcon(
                            onPressed: _busy ? null : _addStep,
                            icon: const Icon(Icons.add),
                            label: Text(_t(context, 'add_step')),
                          );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LayoutBuilder(
                          builder: (context, headerConstraints) {
                            final stacked = headerConstraints.maxWidth < 900;
                            final tabs = TabBar(
                              controller: _tabs,
                              isScrollable: true,
                              tabs: [
                                Tab(text: _t(context, 'overview')),
                                Tab(text: _t(context, 'steps')),
                              ],
                            );
                            if (stacked) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  tabs,
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: sectionAction,
                                  ),
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: tabs),
                                const SizedBox(width: 12),
                                sectionAction,
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        activeContent,
                      ],
                    );
                  },
                ),
              ),
            );
          }

          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  identityPanel,
                  const SizedBox(height: 16),
                  buildContentPanel(),
                  const SizedBox(height: 16),
                  metadataPanel,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
