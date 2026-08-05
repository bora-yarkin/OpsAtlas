// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Dedicated execution screen for manual tasks with checklist progress and evidence.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/request_error.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/atlas_ui.dart';
import '../../core/widgets/media_upload_section.dart';
import '../../core/widgets/rich_content.dart';

typedef JsonMap = Map<String, dynamic>;

class ManualTaskScreen extends ConsumerStatefulWidget {
  final JsonMap task;

  const ManualTaskScreen({super.key, required this.task});

  @override
  ConsumerState<ManualTaskScreen> createState() => _ManualTaskScreenState();
}

class _ManualTaskChecklistItem {
  final String id;
  final String label;
  bool completed;

  _ManualTaskChecklistItem({
    required this.id,
    required this.label,
    required this.completed,
  });

  factory _ManualTaskChecklistItem.fromJson(JsonMap json) {
    return _ManualTaskChecklistItem(
      id: (json['id'] ?? '').toString().trim(),
      label: (json['label'] ?? '').toString().trim(),
      completed: json['completed'] == true,
    );
  }

  JsonMap toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'completed': completed,
  };
}

class _ManualTaskAssigneeChoice {
  final String id;
  final String label;
  final String? subtitle;

  const _ManualTaskAssigneeChoice({
    required this.id,
    required this.label,
    this.subtitle,
  });
}

class _ManualTaskScreenState extends ConsumerState<ManualTaskScreen> {
  late Map<String, dynamic> _task;
  late List<_ManualTaskChecklistItem> _checklist;
  late final TextEditingController _noteCtrl;
  late Future<List<JsonMap>> _commentsFuture;
  bool _busy = false;
  bool _didSaveChanges = false;
  String? _error;

  String get _taskId => (_task['id'] ?? '').toString().trim();
  String get _spaceId => (_task['space_id'] ?? '').toString().trim();
  String get _status =>
      (_task['status'] ?? 'todo').toString().trim().toLowerCase();
  bool get _readOnly => _status == 'done';
  bool get _hasChecklist => _checklist.isNotEmpty;
  bool get _allStepsComplete =>
      _checklist.isNotEmpty && _checklist.every((item) => item.completed);

  @override
  void initState() {
    super.initState();
    _task = Map<String, dynamic>.from(widget.task);
    _checklist = _decodeChecklist(_task['checklist']);
    _noteCtrl = TextEditingController();
    _commentsFuture = _loadComments();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  List<_ManualTaskChecklistItem> _decodeChecklist(Object? raw) {
    if (raw is! List) {
      return <_ManualTaskChecklistItem>[];
    }
    return raw
        .whereType<Map>()
        .map(
          (entry) =>
              _ManualTaskChecklistItem.fromJson(entry.cast<String, dynamic>()),
        )
        .where((item) => item.label.isNotEmpty)
        .toList(growable: true);
  }

  String _t(BuildContext context, String key) =>
      AppLocalizations.of(context).text(key);

  String _formatDue(String raw) {
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) {
      return raw;
    }
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    return '${parsed.year}-$month-$day';
  }

  String _statusLabel(BuildContext context, String status) {
    switch (status.trim().toLowerCase()) {
      case 'in_progress':
        return _t(context, 'task_status_in_progress');
      case 'blocked':
        return _t(context, 'task_status_blocked');
      case 'done':
        return _t(context, 'task_status_done');
      default:
        return _t(context, 'task_status_todo');
    }
  }

  String _priorityLabel(BuildContext context, String priority) {
    switch (priority.trim().toLowerCase()) {
      case 'low':
        return _t(context, 'priority_low');
      case 'high':
        return _t(context, 'priority_high');
      case 'critical':
        return _t(context, 'priority_critical');
      default:
        return _t(context, 'priority_medium');
    }
  }

  Future<List<JsonMap>> _loadComments() async {
    final api = ref.read(apiClientProvider);
    final response = await api.dio.get('/tasks/$_taskId/comments');
    return (response.data as List)
        .cast<Map>()
        .map((entry) => entry.cast<String, dynamic>())
        .toList(growable: false);
  }

  Future<List<_ManualTaskAssigneeChoice>> _loadAssigneeChoices() async {
    final api = ref.read(apiClientProvider);
    final response = await api.dio.get('/spaces/$_spaceId/members/detailed');
    final rows = (response.data as List)
        .cast<Map>()
        .map((entry) => entry.cast<String, dynamic>())
        .toList(growable: false);
    final deduped = <String, _ManualTaskAssigneeChoice>{};
    for (final row in rows) {
      final userId = (row['user_id'] ?? '').toString().trim();
      if (userId.isEmpty) {
        continue;
      }
      final name = (row['name'] ?? '').toString().trim();
      final email = (row['email'] ?? '').toString().trim();
      final role = (row['role'] ?? '').toString().trim();
      deduped[userId] = _ManualTaskAssigneeChoice(
        id: userId,
        label: name.isEmpty ? (email.isEmpty ? userId : email) : name,
        subtitle:
            <String>[
              if (email.isNotEmpty && email.toLowerCase() != name.toLowerCase())
                email,
              if (role.isNotEmpty) role,
            ].join(' • ').trim().isEmpty
            ? null
            : <String>[
                if (email.isNotEmpty &&
                    email.toLowerCase() != name.toLowerCase())
                  email,
                if (role.isNotEmpty) role,
              ].join(' • '),
      );
    }
    final choices = deduped.values.toList(growable: false)
      ..sort(
        (left, right) =>
            left.label.toLowerCase().compareTo(right.label.toLowerCase()),
      );
    return choices;
  }

  Future<void> _saveProgress({required bool complete}) async {
    if (_busy) {
      return;
    }
    final api = ref.read(apiClientProvider);
    final note = _noteCtrl.text.trim();
    final nextStatus = complete
        ? 'done'
        : _checklist.any((item) => item.completed)
        ? 'in_progress'
        : 'todo';

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.dio.put(
        '/tasks/$_taskId',
        data: <String, dynamic>{
          'status': nextStatus,
          'checklist': _checklist
              .map((item) => item.toJson())
              .toList(growable: false),
        },
      );
      if (note.isNotEmpty) {
        await api.dio.post(
          '/tasks/$_taskId/comments',
          data: <String, dynamic>{'body': note},
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _task = <String, dynamic>{
          ..._task,
          'status': nextStatus,
          'checklist': _checklist
              .map((item) => item.toJson())
              .toList(growable: false),
        };
        _didSaveChanges = true;
        _commentsFuture = _loadComments();
        _noteCtrl.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            complete
                ? _t(context, 'task_completed')
                : _t(context, 'task_progress_saved'),
          ),
        ),
      );
      if (complete) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = requestErrorMessage(error, context: context));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _forwardTask() async {
    if (_busy) {
      return;
    }
    final currentAssigneeId = (_task['assignee_user_id'] ?? '')
        .toString()
        .trim();
    final options = (await _loadAssigneeChoices())
        .where((choice) => choice.id != currentAssigneeId)
        .toList(growable: false);
    if (!mounted || options.isEmpty) {
      return;
    }
    String selectedUserId = options.first.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(_t(context, 'forward_task')),
          content: SizedBox(
            width: 440,
            child: DropdownButtonFormField<String>(
              initialValue: selectedUserId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _t(context, 'assignee'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
              items: <DropdownMenuItem<String>>[
                for (final option in options)
                  DropdownMenuItem<String>(
                    value: option.id,
                    child: Text(
                      option.subtitle == null
                          ? option.label
                          : '${option.label} • ${option.subtitle!}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) =>
                  setDialogState(() => selectedUserId = (value ?? '').trim()),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(_t(context, 'cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(_t(context, 'forward_task')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || selectedUserId.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await api.dio.put(
        '/tasks/$_taskId',
        data: <String, dynamic>{
          'assignee_user_id': selectedUserId,
          'status': 'todo',
          'checklist': _checklist
              .map((item) => item.toJson())
              .toList(growable: false),
        },
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_t(context, 'task_forwarded'))));
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = requestErrorMessage(error, context: context));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _buildSummaryCard(BuildContext context) {
    final description = (_task['description'] ?? '').toString().trim();
    final dueAt = (_task['due_at'] ?? '').toString().trim();
    final spaceName = (_task['space_name'] ?? '').toString().trim();
    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              (_task['title'] ?? '').toString().trim().isEmpty
                  ? _t(context, 'task_title')
                  : (_task['title'] ?? '').toString().trim(),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                Chip(
                  avatar: const Icon(Icons.sync_alt_outlined, size: 18),
                  label: Text(_statusLabel(context, _status)),
                ),
                Chip(
                  avatar: const Icon(Icons.flag_outlined, size: 18),
                  label: Text(
                    _priorityLabel(
                      context,
                      (_task['priority'] ?? '').toString(),
                    ),
                  ),
                ),
                if (spaceName.isNotEmpty)
                  Chip(
                    avatar: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(spaceName),
                  ),
                if (dueAt.isNotEmpty)
                  Chip(
                    avatar: const Icon(Icons.event_outlined, size: 18),
                    label: Text(_formatDue(dueAt)),
                  ),
              ],
            ),
            if (description.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              RichContentView(content: description),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChecklistCard(BuildContext context) {
    final theme = Theme.of(context);
    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _t(context, 'task_checklist'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            if (_checklist.isEmpty)
              Text(
                _t(context, 'task_no_checklist_items'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (var index = 0; index < _checklist.length; index++)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _checklist[index].completed,
                  onChanged: _readOnly || _busy
                      ? null
                      : (value) {
                          setState(() {
                            _checklist[index].completed = value ?? false;
                          });
                        },
                  title: Text(_checklist[index].label),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateCard(BuildContext context) {
    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _t(context, 'task_update_note'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              enabled: !_busy,
              minLines: 5,
              maxLines: 8,
              decoration: InputDecoration(
                hintText: _t(context, 'task_update_note_hint'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentsCard(BuildContext context) {
    return FutureBuilder<List<JsonMap>>(
      future: _commentsFuture,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final comments = snapshot.data ?? const <JsonMap>[];
        return AppFlatCard(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _t(context, 'task_updates'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                if (loading)
                  const LinearProgressIndicator(minHeight: 2)
                else if (comments.isEmpty)
                  Text(
                    _t(context, 'task_no_updates'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  for (final comment in comments)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            [
                              (comment['author_name'] ?? '').toString().trim(),
                              if ((comment['created_at'] ?? '')
                                  .toString()
                                  .trim()
                                  .isNotEmpty)
                                _formatDue(
                                  (comment['created_at'] ?? '').toString(),
                                ),
                            ].where((value) => value.isNotEmpty).join(' • '),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 4),
                          Text((comment['body'] ?? '').toString()),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canComplete = !_readOnly && (!_hasChecklist || _allStepsComplete);
    final primaryLabel = canComplete
        ? _t(context, 'complete_task')
        : _t(context, 'task_save_progress');
    return AtlasCompactPageFrame(
      title: (_task['title'] ?? '').toString().trim().isEmpty
          ? _t(context, 'task_title')
          : (_task['title'] ?? '').toString().trim(),
      leading: IconButton(
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: _busy ? null : () => Navigator.pop(context, _didSaveChanges),
        icon: const Icon(Icons.arrow_back),
      ),
      actions: <Widget>[
        OutlinedButton.icon(
          onPressed: _busy || _readOnly ? null : _forwardTask,
          icon: const Icon(Icons.redo),
          label: Text(_t(context, 'forward_task')),
        ),
        FilledButton.icon(
          onPressed: _busy || _readOnly
              ? null
              : () => _saveProgress(complete: canComplete),
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  canComplete ? Icons.task_alt_outlined : Icons.save_outlined,
                ),
          label: Text(primaryLabel),
        ),
      ],
      child: ListView(
        children: <Widget>[
          _buildSummaryCard(context),
          const SizedBox(height: 16),
          _buildChecklistCard(context),
          const SizedBox(height: 16),
          _buildUpdateCard(context),
          const SizedBox(height: 16),
          AppFlatCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: MediaUploadSection(
                title: _t(context, 'evidence_attachments'),
                usage: 'task_attachment',
                spaceId: _spaceId.isEmpty ? null : _spaceId,
                compact: true,
                attachEntityType: 'task',
                attachEntityId: _taskId,
                emptyLabel: _t(context, 'task_no_attachments'),
                showMetadataControls: false,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildCommentsCard(context),
        ],
      ),
    );
  }
}
