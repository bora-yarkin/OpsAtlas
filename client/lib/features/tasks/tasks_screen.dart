// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Task workspace screen, editors, and structured-search state.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/analytics_tracker.dart';
import '../../core/api/api_client.dart';
import '../../core/api/request_error.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/navigation/app_route_navigation.dart';
import '../../core/search/search_analytics.dart';
import '../../core/search/search_capabilities.dart';
import '../../core/search/search_diagnostics_widget.dart';
import '../../core/search/search_help.dart';
import '../../core/search/query_ast.dart';
import '../../core/search/search_state.dart';
import '../../core/search/search_validation.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/atlas_ui.dart';
import '../spaces/spaces_screen.dart';
import '../spaces/workspace_surface_shell.dart';
import 'manual_task_screen.dart';
import 'sop_run_task_screen.dart';

/// Builds shared search query parameters for task list endpoints.
Map<String, dynamic> _taskSearchQueryParameters(String query) {
  final normalized = normalizeSearchInput(query);
  if (normalized.isEmpty) {
    return const <String, dynamic>{};
  }
  return <String, dynamic>{
    'q': normalized,
    'search_ast': encodeSearchAstParamFromRawQuery(normalized),
  };
}

/// Loads tasks assigned to the current user.
final myTasksProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      query,
    ) async {
      final api = ref.watch(apiClientProvider);
      final queryParameters = _taskSearchQueryParameters(query);
      final r = await api.dio.get(
        '/tasks/my',
        queryParameters: queryParameters.isEmpty ? null : queryParameters,
      );
      return (r.data as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    });

/// Loads tasks for a specific space and query scope.
final spaceTasksProvider =
    FutureProvider.family<
      List<Map<String, dynamic>>,
      ({String query, String spaceId})
    >((ref, request) async {
      final api = ref.watch(apiClientProvider);
      final queryParameters = _taskSearchQueryParameters(request.query);
      final r = await api.dio.get(
        '/tasks/spaces/${request.spaceId}',
        queryParameters: queryParameters.isEmpty ? null : queryParameters,
      );
      return (r.data as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    });

enum _TasksSearchCategory { status, priority, source, space }

class _TasksSearchSuggestion {
  final String label;
  final String tokenText;
  final bool appendSpace;
  final String? subtitle;

  const _TasksSearchSuggestion({
    required this.label,
    required this.tokenText,
    required this.appendSpace,
    this.subtitle,
  });
}

/// Parsed structured-search model used by the tasks screen toolbar and filters.
class _TasksSearchQuery {
  final List<String> terms;
  final SearchExpressionNode? expression;
  final List<SearchParseDiagnostic> diagnostics;
  final Set<String> statusFilters;
  final Set<String> excludedStatusFilters;
  final Set<String> priorityFilters;
  final Set<String> excludedPriorityFilters;
  final Set<String> sourceFilters;
  final Set<String> excludedSourceFilters;
  final Set<String> spaceFilters;
  final Set<String> excludedSpaceFilters;
  final List<SearchFieldToken> structuredTokens;

  const _TasksSearchQuery({
    required this.terms,
    required this.expression,
    required this.diagnostics,
    required this.statusFilters,
    required this.excludedStatusFilters,
    required this.priorityFilters,
    required this.excludedPriorityFilters,
    required this.sourceFilters,
    required this.excludedSourceFilters,
    required this.spaceFilters,
    required this.excludedSpaceFilters,
    required this.structuredTokens,
  });

  bool get hasStructuredFilters =>
      statusFilters.isNotEmpty ||
      excludedStatusFilters.isNotEmpty ||
      priorityFilters.isNotEmpty ||
      excludedPriorityFilters.isNotEmpty ||
      sourceFilters.isNotEmpty ||
      excludedSourceFilters.isNotEmpty ||
      spaceFilters.isNotEmpty ||
      excludedSpaceFilters.isNotEmpty;

  bool get isEmpty => terms.isEmpty && !hasStructuredFilters;
}

class _TaskAssigneeChoice {
  final String id;
  final String label;
  final String? subtitle;

  const _TaskAssigneeChoice({
    required this.id,
    required this.label,
    this.subtitle,
  });
}

enum _TaskQuickFilter { overdue, dueSoon }

enum _TaskDisplayMode { list, board }

class _TaskPresetView {
  final String labelKey;
  final String query;
  final bool showOnlyMyTasks;
  final _TaskQuickFilter? quickFilter;

  const _TaskPresetView({
    required this.labelKey,
    required this.query,
    required this.showOnlyMyTasks,
    required this.quickFilter,
  });
}

const List<_TaskPresetView> _defaultTaskPresetViews = <_TaskPresetView>[
  _TaskPresetView(
    labelKey: 'task_preset_my_overdue',
    query: '',
    showOnlyMyTasks: true,
    quickFilter: _TaskQuickFilter.overdue,
  ),
  _TaskPresetView(
    labelKey: 'task_preset_this_week',
    query: '',
    showOnlyMyTasks: false,
    quickFilter: _TaskQuickFilter.dueSoon,
  ),
  _TaskPresetView(
    labelKey: 'task_preset_blocked',
    query: '@status:blocked',
    showOnlyMyTasks: false,
    quickFilter: null,
  ),
  _TaskPresetView(
    labelKey: 'task_preset_follow_up_tasks',
    query: '(sop_step OR incident_action_item)',
    showOnlyMyTasks: false,
    quickFilter: null,
  ),
];

class _TaskToolbarChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  const _TaskToolbarChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primaryContainer : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '$label $value',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskEditorDraft {
  final String spaceId;
  final String title;
  final String description;
  final String status;
  final String priority;
  final String assigneeUserId;
  final List<_TaskChecklistDraftItem> checklist;
  final DateTime? dueAt;

  const _TaskEditorDraft({
    required this.spaceId,
    required this.title,
    required this.description,
    required this.status,
    required this.priority,
    required this.assigneeUserId,
    required this.checklist,
    required this.dueAt,
  });
}

class _TaskChecklistDraftItem {
  final String id;
  final String label;
  final bool completed;

  const _TaskChecklistDraftItem({
    required this.id,
    required this.label,
    required this.completed,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'completed': completed,
  };
}

class _TaskChecklistDraftController {
  final String id;
  final TextEditingController controller;
  bool completed;

  _TaskChecklistDraftController({
    required this.id,
    required String label,
    required this.completed,
  }) : controller = TextEditingController(text: label);

  void dispose() {
    controller.dispose();
  }
}

String _formatTaskEditorDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month < 10 ? '0${local.month}' : '${local.month}';
  final day = local.day < 10 ? '0${local.day}' : '${local.day}';
  return '${local.year}-$month-$day';
}

String _taskEditorErrorText(BuildContext context, Object error) {
  return requestErrorMessage(error, context: context);
}

Future<T?> _showTaskFullScreenRoute<T>(BuildContext context, Widget child) {
  return Navigator.of(context).push<T>(
    CupertinoPageRoute<T>(
      builder: (routeContext) {
        return Scaffold(
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Theme.of(routeContext).colorScheme.surface,
                  Theme.of(routeContext).colorScheme.surfaceContainerLowest,
                  Theme.of(routeContext).colorScheme.surface,
                ],
              ),
            ),
            child: SafeArea(child: AtlasEdgeBackGesture(child: child)),
          ),
        );
      },
    ),
  );
}

/// Full-screen task editor used for both creation and editing flows.
class _TaskEditorScreen extends StatefulWidget {
  final String pageTitle;
  final String submitLabel;
  final bool allowSpaceSelection;
  final List<Map<String, dynamic>> spaces;
  final String initialSpaceId;
  final String initialTitle;
  final String initialDescription;
  final String initialStatus;
  final String initialPriority;
  final String initialAssigneeUserId;
  final List<_TaskChecklistDraftItem> initialChecklist;
  final bool showChecklistEditor;
  final DateTime? initialDueAt;
  final Future<List<_TaskAssigneeChoice>> Function(String spaceId)?
  loadAssignees;
  final Future<void> Function(_TaskEditorDraft draft) onSubmit;

  const _TaskEditorScreen({
    required this.pageTitle,
    required this.submitLabel,
    required this.allowSpaceSelection,
    required this.spaces,
    required this.initialSpaceId,
    required this.initialTitle,
    required this.initialDescription,
    required this.initialStatus,
    required this.initialPriority,
    required this.initialAssigneeUserId,
    required this.initialChecklist,
    required this.showChecklistEditor,
    required this.initialDueAt,
    required this.onSubmit,
    this.loadAssignees,
  });

  @override
  State<_TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends State<_TaskEditorScreen> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;
  late String _selectedSpaceId;
  late String _status;
  late String _priority;
  late String _selectedAssigneeId;
  late final List<_TaskChecklistDraftController> _checklistItems;
  DateTime? _dueAt;
  List<_TaskAssigneeChoice> _assigneeChoices = const <_TaskAssigneeChoice>[];
  bool _assigneesLoading = false;
  bool _busy = false;
  String? _assigneeLoadError;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _descCtrl = TextEditingController(text: widget.initialDescription);
    _selectedSpaceId = widget.initialSpaceId.trim();
    _status = widget.initialStatus;
    _priority = widget.initialPriority;
    _selectedAssigneeId = widget.initialAssigneeUserId.trim();
    _checklistItems = widget.initialChecklist.isEmpty
        ? <_TaskChecklistDraftController>[_newChecklistItem()]
        : widget.initialChecklist
              .map(
                (item) => _TaskChecklistDraftController(
                  id: item.id,
                  label: item.label,
                  completed: item.completed,
                ),
              )
              .toList(growable: true);
    _dueAt = widget.initialDueAt;
    if (widget.loadAssignees != null && _selectedSpaceId.isNotEmpty) {
      _loadAssigneesForSpace(_selectedSpaceId);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    for (final item in _checklistItems) {
      item.dispose();
    }
    super.dispose();
  }

  _TaskChecklistDraftController _newChecklistItem() {
    return _TaskChecklistDraftController(
      id: UniqueKey().toString(),
      label: '',
      completed: false,
    );
  }

  String _spaceNameFor(String spaceId) {
    for (final space in widget.spaces) {
      if ((space['id'] ?? '').toString().trim() == spaceId) {
        final name = (space['name'] ?? '').toString().trim();
        if (name.isNotEmpty) return name;
      }
    }
    return '';
  }

  String _statusLabel(AppLocalizations l10n, String status) {
    return switch (status) {
      'in_progress' => l10n.text('task_status_in_progress'),
      'blocked' => l10n.text('task_status_blocked'),
      'done' => l10n.text('task_status_done'),
      _ => l10n.text('task_status_todo'),
    };
  }

  String _priorityLabel(AppLocalizations l10n, String priority) {
    return switch (priority) {
      'low' => l10n.text('priority_low'),
      'high' => l10n.text('priority_high'),
      'critical' => l10n.text('priority_critical'),
      _ => l10n.text('priority_medium'),
    };
  }

  Future<void> _loadAssigneesForSpace(String spaceId) async {
    final loader = widget.loadAssignees;
    if (loader == null || spaceId.trim().isEmpty) return;
    setState(() {
      _assigneesLoading = true;
      _assigneeLoadError = null;
      if (widget.allowSpaceSelection) {
        _selectedAssigneeId = '';
      }
    });
    try {
      final loaded = await loader(spaceId);
      if (!mounted || _selectedSpaceId != spaceId) return;
      final dedupedChoices = <String, _TaskAssigneeChoice>{
        for (final choice in loaded) choice.id: choice,
      }.values.toList(growable: false);
      final hasSelected =
          _selectedAssigneeId.isNotEmpty &&
          dedupedChoices.any((choice) => choice.id == _selectedAssigneeId);
      setState(() {
        _assigneeChoices = hasSelected || _selectedAssigneeId.isEmpty
            ? dedupedChoices
            : <_TaskAssigneeChoice>[
                _TaskAssigneeChoice(
                  id: _selectedAssigneeId,
                  label: _selectedAssigneeId,
                ),
                ...dedupedChoices,
              ];
        _assigneesLoading = false;
      });
    } catch (_) {
      if (!mounted || _selectedSpaceId != spaceId) return;
      setState(() {
        _assigneesLoading = false;
        _assigneeLoadError = AppLocalizations.of(
          context,
        ).text('load_members_role_hint');
      });
    }
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null) return;
    setState(() {
      _dueAt = DateTime(picked.year, picked.month, picked.day, 9);
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final title = _titleCtrl.text.trim();
    if (title.isEmpty || _selectedSpaceId.isEmpty) {
      setState(() => _error = l10n.text('task_title'));
      return;
    }
    final checklist = _checklistItems
        .map(
          (item) => _TaskChecklistDraftItem(
            id: item.id,
            label: item.controller.text.trim(),
            completed: item.completed,
          ),
        )
        .where((item) => item.label.isNotEmpty)
        .toList(growable: false);
    if (widget.showChecklistEditor && checklist.isEmpty) {
      setState(() => _error = l10n.text('task_checklist_required'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        _TaskEditorDraft(
          spaceId: _selectedSpaceId,
          title: title,
          description: _descCtrl.text.trim(),
          status: _status,
          priority: _priority,
          assigneeUserId: _selectedAssigneeId,
          checklist: checklist,
          dueAt: _dueAt,
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _taskEditorErrorText(context, error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _buildChecklistPanel(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!widget.showChecklistEditor) {
      return const SizedBox.shrink();
    }
    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.text('task_checklist'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _checklistItems.add(_newChecklistItem());
                        }),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.text('task_add_checklist_item')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (
              var index = 0;
              index < _checklistItems.length;
              index++
            ) ...<Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Checkbox(
                    value: _checklistItems[index].completed,
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _checklistItems[index].completed =
                                value ?? false,
                          ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _checklistItems[index].controller,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText:
                            '${l10n.text('task_checklist_item_label')} ${index + 1}',
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: l10n.text('remove'),
                    onPressed: _busy || _checklistItems.length == 1
                        ? null
                        : () => setState(() {
                            final removed = _checklistItems.removeAt(index);
                            removed.dispose();
                          }),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              if (index != _checklistItems.length - 1)
                const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataPanel(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final currentSpaceName = _spaceNameFor(_selectedSpaceId);
    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.text('metadata'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (widget.allowSpaceSelection)
              DropdownButtonFormField<String>(
                initialValue: _selectedSpaceId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.text('space'),
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final space in widget.spaces)
                    DropdownMenuItem<String>(
                      value: (space['id'] ?? '').toString(),
                      child: Text(
                        (space['name'] ?? '').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null || value.isEmpty) return;
                        setState(() => _selectedSpaceId = value);
                        _loadAssigneesForSpace(value);
                      },
              )
            else
              InputDecorator(
                decoration: InputDecoration(
                  labelText: l10n.text('space'),
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
                child: Text(
                  currentSpaceName.isEmpty
                      ? l10n.text('tasks')
                      : currentSpaceName,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _status,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('status'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: 'todo',
                        child: Text(l10n.text('task_status_todo')),
                      ),
                      DropdownMenuItem<String>(
                        value: 'in_progress',
                        child: Text(l10n.text('task_status_in_progress')),
                      ),
                      DropdownMenuItem<String>(
                        value: 'blocked',
                        child: Text(l10n.text('task_status_blocked')),
                      ),
                      DropdownMenuItem<String>(
                        value: 'done',
                        child: Text(l10n.text('task_status_done')),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value == null || value.isEmpty) return;
                            setState(() => _status = value);
                          },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _priority,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('priority'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: 'low',
                        child: Text(l10n.text('priority_low')),
                      ),
                      DropdownMenuItem<String>(
                        value: 'medium',
                        child: Text(l10n.text('priority_medium')),
                      ),
                      DropdownMenuItem<String>(
                        value: 'high',
                        child: Text(l10n.text('priority_high')),
                      ),
                      DropdownMenuItem<String>(
                        value: 'critical',
                        child: Text(l10n.text('priority_critical')),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value == null || value.isEmpty) return;
                            setState(() => _priority = value);
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey<String>(
                'task-editor-assignee-$_selectedSpaceId-$_selectedAssigneeId',
              ),
              initialValue: _selectedAssigneeId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.text('assignee'),
                helperText: _assigneeLoadError,
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
              items: <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(
                  value: '',
                  child: Text(l10n.text('unassigned')),
                ),
                ..._assigneeChoices.map(
                  (choice) => DropdownMenuItem<String>(
                    value: choice.id,
                    child: Text(
                      choice.subtitle == null
                          ? choice.label
                          : '${choice.label} • ${choice.subtitle!}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: _assigneesLoading || _busy
                  ? null
                  : (value) => setState(
                      () => _selectedAssigneeId = (value ?? '').trim(),
                    ),
            ),
            if (_assigneesLoading)
              const Padding(
                padding: EdgeInsets.only(top: AppSpacing.xs),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 12),
            Text(
              l10n.text('due_date'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            WorkspaceInlineStrip(
              spacing: AppSpacing.xs,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickDueDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    _dueAt == null
                        ? l10n.text('due_date')
                        : _formatTaskEditorDate(_dueAt!),
                  ),
                ),
                if (_dueAt != null)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _dueAt = null),
                    icon: const Icon(Icons.clear),
                    label: Text(l10n.text('clear_due_date')),
                  ),
              ],
            ),
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

  Widget _buildEditorPanel(BuildContext context, {required bool wide}) {
    final l10n = AppLocalizations.of(context);
    final currentSpaceName = _spaceNameFor(_selectedSpaceId);
    final descriptionField = TextField(
      controller: _descCtrl,
      expands: true,
      minLines: null,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        labelText: l10n.text('description_acceptance'),
        alignLabelWithHint: true,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
    );
    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _titleCtrl,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              decoration: InputDecoration(
                labelText: l10n.text('task_title'),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            WorkspaceInlineStrip(
              spacing: AppSpacing.xs,
              children: <Widget>[
                if (currentSpaceName.isNotEmpty)
                  Chip(
                    avatar: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(currentSpaceName),
                  ),
                Chip(
                  avatar: const Icon(Icons.flag_outlined, size: 18),
                  label: Text(_priorityLabel(l10n, _priority)),
                ),
                Chip(
                  avatar: const Icon(Icons.sync_alt_outlined, size: 18),
                  label: Text(_statusLabel(l10n, _status)),
                ),
                if (_dueAt != null)
                  Chip(
                    avatar: const Icon(Icons.event_outlined, size: 18),
                    label: Text(_formatTaskEditorDate(_dueAt!)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            SizedBox(height: wide ? 520 : 360, child: descriptionField),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AtlasCompactPageFrame(
      title: widget.pageTitle,
      leading: IconButton(
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        icon: const Icon(Icons.arrow_back),
      ),
      actions: <Widget>[
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(widget.submitLabel),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 980;
          final contentMaxWidth = wide ? 1120.0 : double.infinity;
          final metadataPanel = _buildMetadataPanel(context);
          final editorPanel = _buildEditorPanel(context, wide: wide);
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: ListView(
                children: <Widget>[
                  editorPanel,
                  const SizedBox(height: 16),
                  _buildChecklistPanel(context),
                  if (widget.showChecklistEditor) const SizedBox(height: 16),
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

/// Task workspace with search, presets, scopes, and list/board presentation.
class TasksScreen extends ConsumerStatefulWidget {
  final String? initialSearchQuery;
  final String? initialSpaceId;
  final bool autoOpenCreateDialog;

  const TasksScreen({
    super.key,
    this.initialSearchQuery,
    this.initialSpaceId,
    this.autoOpenCreateDialog = false,
  });

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  static const _queryPrefsKey = 'tasks_screen_query';
  static const _searchSurfaceId = 'tasks';

  String? _selectedSpaceId;
  bool _showOnlyMyTasks = true;
  final TextEditingController _queryCtrl = TextEditingController();
  final TextEditingController _savedViewNameCtrl = TextEditingController();
  bool _prefsLoaded = false;
  List<String> _recentQueries = const <String>[];
  List<SearchSavedView> _savedViews = const <SearchSavedView>[];
  String _lastTrackedResultSignature = '';
  _TaskQuickFilter? _quickFilter;
  _TaskDisplayMode _displayMode = _TaskDisplayMode.list;
  bool _autoOpenedCreateDialog = false;
  late WorkspaceScopeValue _scope;

  @override
  void initState() {
    super.initState();
    final initialSpaceId = (widget.initialSpaceId ?? '').trim();
    _scope = WorkspaceScopeValue(
      mode: WorkspaceScopeMode.current,
      currentSpaceId: initialSpaceId,
      selectedSpaceIds: initialSpaceId.isEmpty
          ? const <String>[]
          : <String>[initialSpaceId],
    );
    if (initialSpaceId.isNotEmpty) {
      _selectedSpaceId = initialSpaceId;
      _showOnlyMyTasks = false;
    }
    _queryCtrl.addListener(_persistAndSyncQuery);
    _loadSearchState();
  }

  @override
  void dispose() {
    _queryCtrl
      ..removeListener(_persistAndSyncQuery)
      ..dispose();
    _savedViewNameCtrl.dispose();
    super.dispose();
  }

  void _openRoute(String route) {
    atlasOpenRoute(context, route);
  }

  List<WorkspaceScopeSpace> _scopeSpaces(List<Map<String, dynamic>> spaces) {
    return spaces
        .map(
          (space) => WorkspaceScopeSpace(
            id: (space['id'] ?? '').toString(),
            label: ((space['name'] ?? space['id']) ?? '').toString(),
          ),
        )
        .where((space) => space.id.trim().isNotEmpty)
        .toList(growable: false);
  }

  List<String> _effectiveScopeSpaceIds(List<Map<String, dynamic>> spaces) {
    final availableIds = _scopeSpaces(
      spaces,
    ).map((space) => space.id.trim()).where((id) => id.isNotEmpty).toSet();
    final currentId = (_selectedSpaceId ?? _scope.currentSpaceId).trim();
    switch (_scope.mode) {
      case WorkspaceScopeMode.current:
        return availableIds.contains(currentId)
            ? <String>[currentId]
            : const <String>[];
      case WorkspaceScopeMode.selected:
        return _scope.selectedSpaceIds
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty && availableIds.contains(id))
            .toList(growable: false);
      case WorkspaceScopeMode.all:
        return _scopeSpaces(spaces)
            .map((space) => space.id)
            .where((id) => id.trim().isNotEmpty)
            .toList(growable: false);
    }
  }

  String _scopeSummaryText(
    List<Map<String, dynamic>> spaces,
    String currentId,
  ) {
    final labels = <String, String>{
      for (final space in _scopeSpaces(spaces)) space.id: space.label,
    };
    return switch (_scope.mode) {
      WorkspaceScopeMode.current =>
        labels[currentId] ?? AppLocalizations.of(context).text('current_space'),
      WorkspaceScopeMode.selected =>
        _scope.selectedSpaceIds.length == 1
            ? (labels[_scope.selectedSpaceIds.first] ??
                  _scope.selectedSpaceIds.first)
            : AppLocalizations.of(context)
                  .text('selected_space_count')
                  .replaceAll('{count}', '${_scope.selectedSpaceIds.length}'),
      WorkspaceScopeMode.all => AppLocalizations.of(
        context,
      ).text('all_accessible_spaces'),
    };
  }

  Future<void> _openScopePicker(List<Map<String, dynamic>> spaces) async {
    final l10n = AppLocalizations.of(context);
    final selectedId = (_selectedSpaceId ?? '').trim();
    final next = await showWorkspaceScopeDialog(
      context: context,
      title: l10n.text('browse_scope'),
      closeLabel: l10n.text('close'),
      applyLabel: l10n.text('apply'),
      currentSpaceLabel: l10n.text('current_space'),
      selectedSpacesLabel: l10n.text('selected_spaces'),
      allAccessibleSpacesLabel: l10n.text('all_accessible_spaces'),
      emptySelectionLabel: l10n.text('selected_spaces_empty'),
      spaces: _scopeSpaces(spaces),
      initialValue: _scope.copyWith(
        currentSpaceId: selectedId.isEmpty ? _scope.currentSpaceId : selectedId,
      ),
      allowSelectingCurrentSpace: true,
    );
    if (next == null || !mounted) {
      return;
    }
    setState(() {
      _scope = next;
      if (next.currentSpaceId.trim().isNotEmpty) {
        _selectedSpaceId = next.currentSpaceId.trim();
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadTasksForScope({
    required List<Map<String, dynamic>> spaces,
    required String currentSpaceId,
    required String normalizedQuery,
  }) async {
    final api = ref.read(apiClientProvider);
    if (_showOnlyMyTasks) {
      final response = await api.dio.get(
        '/tasks/my',
        queryParameters: _taskSearchQueryParameters(normalizedQuery),
      );
      return (response.data as List)
          .cast<Map>()
          .map((entry) => entry.cast<String, dynamic>())
          .toList(growable: false);
    }

    final scopeSpaces = _scopeSpaces(spaces);
    final scopeIds = _effectiveScopeSpaceIds(spaces);
    final spaceNameById = <String, String>{
      for (final space in scopeSpaces) space.id: space.label,
    };
    final rows = await Future.wait(
      scopeIds.map((spaceId) async {
        final response = await api.dio.get(
          '/tasks/spaces/$spaceId',
          queryParameters: _taskSearchQueryParameters(normalizedQuery),
        );
        return (response.data as List)
            .cast<Map>()
            .map((entry) {
              final row = entry.cast<String, dynamic>();
              return <String, dynamic>{
                ...row,
                'space_name':
                    (row['space_name'] ?? spaceNameById[spaceId] ?? '')
                        .toString(),
              };
            })
            .toList(growable: false);
      }),
    );
    return rows
        .expand((items) => items)
        .cast<Map<String, dynamic>>()
        .toList(growable: false);
  }

  void _refreshTasksView() {
    ref.invalidate(spacesProvider(''));
  }

  Future<void> _loadSearchState() async {
    final prefs = await SharedPreferences.getInstance();
    final routeQuery = normalizeSearchInput(widget.initialSearchQuery ?? '');
    final persistedQuery = normalizeSearchInput(
      prefs.getString(_queryPrefsKey) ?? '',
    );
    final effective = routeQuery.isNotEmpty ? routeQuery : persistedQuery;
    final recent = await SearchStateStore.loadRecentQueries(_searchSurfaceId);
    final views = await SearchStateStore.loadSavedViews(_searchSurfaceId);

    if (!mounted) {
      return;
    }
    setState(() {
      _queryCtrl.text = effective;
      _recentQueries = recent;
      _savedViews = views;
      _prefsLoaded = true;
    });
  }

  Future<void> _persistAndSyncQuery() async {
    if (!_prefsLoaded || !mounted) return;
    final normalized = normalizeSearchInput(_queryCtrl.text);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queryPrefsKey, normalized);

    if (!mounted) return;
    final state = GoRouterState.of(context);
    final current = state.uri;
    final nextParams = Map<String, String>.from(current.queryParameters);
    if (normalized.isEmpty) {
      nextParams.remove('search');
    } else {
      nextParams['search'] = normalized;
    }
    final nextUri = Uri(
      path: '/tasks',
      queryParameters: nextParams.isEmpty ? null : nextParams,
    );
    if (current.path != nextUri.path || current.query != nextUri.query) {
      context.replace(nextUri.toString());
    }
  }

  Future<void> _rememberCurrentQuery() async {
    final normalized = normalizeSearchInput(_queryCtrl.text);
    if (normalized.isEmpty) {
      return;
    }
    await SearchStateStore.rememberQuery(_searchSurfaceId, normalized);
    final recent = await SearchStateStore.loadRecentQueries(_searchSurfaceId);
    if (!mounted) return;
    setState(() => _recentQueries = recent);
  }

  Future<void> _saveCurrentQueryView() async {
    final name = _savedViewNameCtrl.text.trim();
    final query = normalizeSearchInput(_queryCtrl.text);
    if (name.isEmpty || query.isEmpty) {
      return;
    }
    await SearchStateStore.saveView(_searchSurfaceId, name: name, query: query);
    final views = await SearchStateStore.loadSavedViews(_searchSurfaceId);
    if (!mounted) return;
    setState(() {
      _savedViewNameCtrl.clear();
      _savedViews = views;
    });
  }

  Future<void> _applySavedView(SearchSavedView view) async {
    _queryCtrl.value = TextEditingValue(
      text: normalizeSearchInput(view.query),
      selection: TextSelection.collapsed(offset: view.query.length),
    );
    await SearchStateStore.touchView(_searchSurfaceId, view.id);
    await _rememberCurrentQuery();
  }

  Future<void> _deleteSavedView(SearchSavedView view) async {
    await SearchStateStore.deleteView(_searchSurfaceId, view.id);
    final views = await SearchStateStore.loadSavedViews(_searchSurfaceId);
    if (!mounted) return;
    setState(() => _savedViews = views);
  }

  Future<void> _applyDefaultTaskView(_TaskPresetView preset) async {
    final normalized = normalizeSearchInput(preset.query);
    _queryCtrl.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _showOnlyMyTasks = preset.showOnlyMyTasks;
      _quickFilter = preset.quickFilter;
      _displayMode = _TaskDisplayMode.board;
    });
    await _rememberCurrentQuery();
  }

  Future<void> _openSavedViewsDialog(AppLocalizations l10n) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(l10n.text('load_saved_view')),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        l10n.text('default_task_views'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: <Widget>[
                          for (final preset in _defaultTaskPresetViews)
                            ActionChip(
                              label: Text(l10n.text(preset.labelKey)),
                              onPressed: () async {
                                await _applyDefaultTaskView(preset);
                                if (dialogContext.mounted) {
                                  Navigator.pop(dialogContext);
                                }
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        controller: _savedViewNameCtrl,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: l10n.text('saved_view_name'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          await _saveCurrentQueryView();
                          final views = await SearchStateStore.loadSavedViews(
                            _searchSurfaceId,
                          );
                          if (!context.mounted) return;
                          setDialogState(() => _savedViews = views);
                        },
                        icon: const Icon(Icons.save_outlined),
                        label: Text(l10n.text('save_view')),
                      ),
                      if (_savedViews.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: <Widget>[
                            for (final view in _savedViews)
                              InputChip(
                                label: Text(view.name),
                                onPressed: () async {
                                  await _applySavedView(view);
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                },
                                onDeleted: () async {
                                  await _deleteSavedView(view);
                                  final views =
                                      await SearchStateStore.loadSavedViews(
                                        _searchSurfaceId,
                                      );
                                  if (!context.mounted) return;
                                  setDialogState(() => _savedViews = views);
                                },
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.text('close')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _trackQueryResults({
    required int resultCount,
    required String selectedSpaceId,
  }) {
    final normalized = normalizeSearchInput(_queryCtrl.text);
    if (normalized.isEmpty) {
      _lastTrackedResultSignature = '';
      return;
    }
    final surface = _showOnlyMyTasks ? 'tasks_my' : 'tasks_space';
    final signature = '$surface|$selectedSpaceId|$normalized|$resultCount';
    if (_lastTrackedResultSignature == signature) {
      return;
    }
    _lastTrackedResultSignature = signature;

    final diagnostics = validateSearchQueryAst(
      parseSearchQueryAst(normalized),
      capability: tasksSearchCapability,
    ).diagnostics;

    final path = _showOnlyMyTasks
        ? '/tasks'
        : Uri(
            path: '/tasks',
            queryParameters: <String, String>{'spaceId': selectedSpaceId},
          ).toString();
    trackSearchEvent(
      ref,
      eventType: 'search_query_issued',
      surface: surface,
      query: normalized,
      path: path,
      spaceId: _showOnlyMyTasks ? null : selectedSpaceId,
      entityType: 'task',
      extraMeta: <String, Object?>{
        'diagnostics_count': diagnostics.length,
        'diagnostic_codes': diagnostics.map((d) => d.code).toList(),
      },
    );
    trackSearchEvent(
      ref,
      eventType: resultCount > 0 ? 'search_results_shown' : 'search_no_result',
      surface: surface,
      query: normalized,
      path: path,
      spaceId: _showOnlyMyTasks ? null : selectedSpaceId,
      entityType: 'task',
      results: resultCount,
    );
  }

  _TasksSearchCategory? _normalizeSearchCategory(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'status' || 'state' => _TasksSearchCategory.status,
      'priority' || 'prio' => _TasksSearchCategory.priority,
      'source' || 'source_kind' || 'linked_to' => _TasksSearchCategory.source,
      'space' || 'space_id' || 'spaceid' => _TasksSearchCategory.space,
      _ => null,
    };
  }

  String _searchCategoryToken(_TasksSearchCategory category) {
    return switch (category) {
      _TasksSearchCategory.status => 'status',
      _TasksSearchCategory.priority => 'priority',
      _TasksSearchCategory.source => 'source',
      _TasksSearchCategory.space => 'space',
    };
  }

  String _searchCategoryLabel(
    _TasksSearchCategory category,
    AppLocalizations l10n,
  ) {
    return switch (category) {
      _TasksSearchCategory.status => l10n.text('status'),
      _TasksSearchCategory.priority => l10n.text('priority'),
      _TasksSearchCategory.source => l10n.text('source'),
      _TasksSearchCategory.space => l10n.text('space'),
    };
  }

  _TasksSearchQuery _parseTasksSearchQuery(String raw) {
    final ast = parseSearchQueryAst(raw);
    final validation = validateSearchQueryAst(
      ast,
      capability: tasksSearchCapability,
    );
    final statusFilters = <String>{};
    final excludedStatusFilters = <String>{};
    final priorityFilters = <String>{};
    final excludedPriorityFilters = <String>{};
    final sourceFilters = <String>{};
    final excludedSourceFilters = <String>{};
    final spaceFilters = <String>{};
    final excludedSpaceFilters = <String>{};
    final structuredTokens = <SearchFieldToken>[];

    for (final token in ast.fieldTokens) {
      final category = _normalizeSearchCategory(token.normalizedField);
      if (category == null || !token.hasValue) {
        continue;
      }
      final value = token.normalizedValue;
      if (value.isEmpty) {
        continue;
      }
      structuredTokens.add(token);
      switch (category) {
        case _TasksSearchCategory.status:
          if (token.isNegated) {
            excludedStatusFilters.add(value);
          } else {
            statusFilters.add(value);
          }
          break;
        case _TasksSearchCategory.priority:
          if (token.isNegated) {
            excludedPriorityFilters.add(value);
          } else {
            priorityFilters.add(value);
          }
          break;
        case _TasksSearchCategory.source:
          if (token.isNegated) {
            excludedSourceFilters.add(value);
          } else {
            sourceFilters.add(value);
          }
          break;
        case _TasksSearchCategory.space:
          if (token.isNegated) {
            excludedSpaceFilters.add(value);
          } else {
            spaceFilters.add(value);
          }
          break;
      }
    }

    return _TasksSearchQuery(
      terms: ast.normalizedTerms,
      expression: ast.expression,
      diagnostics: validation.diagnostics,
      statusFilters: statusFilters,
      excludedStatusFilters: excludedStatusFilters,
      priorityFilters: priorityFilters,
      excludedPriorityFilters: excludedPriorityFilters,
      sourceFilters: sourceFilters,
      excludedSourceFilters: excludedSourceFilters,
      spaceFilters: spaceFilters,
      excludedSpaceFilters: excludedSpaceFilters,
      structuredTokens: structuredTokens,
    );
  }

  bool _matchesTaskSearchQuery(
    Map<String, dynamic> task,
    _TasksSearchQuery query,
    String selectedSpaceName,
  ) {
    if (query.isEmpty) {
      return true;
    }

    final taskId = (task['id'] ?? '').toString().toLowerCase();
    final title = (task['title'] ?? '').toString().toLowerCase();
    final description = (task['description'] ?? '').toString().toLowerCase();
    final status = (task['status'] ?? '').toString().toLowerCase();
    final priority = (task['priority'] ?? '').toString().toLowerCase();
    final spaceId = (task['space_id'] ?? '').toString().toLowerCase();
    final spaceName = (task['space_name'] ?? selectedSpaceName)
        .toString()
        .toLowerCase();
    final assigneeName = (task['assignee_name'] ?? '').toString().toLowerCase();
    final assigneeEmail = (task['assignee_email'] ?? '')
        .toString()
        .toLowerCase();
    final sourceKind = (task['source_kind'] ?? '').toString().toLowerCase();
    final sourceId = (task['source_id'] ?? '').toString().toLowerCase();
    final sourceStepId = (task['source_step_id'] ?? '')
        .toString()
        .toLowerCase();
    final text =
        '$taskId $title $description $status $priority $spaceId $spaceName $assigneeName $assigneeEmail $sourceKind $sourceId $sourceStepId';

    return evaluateSearchExpression(
      query.expression,
      matchesField: (token) {
        final category = _normalizeSearchCategory(token.normalizedField);
        if (category == null || !token.hasValue) {
          return true;
        }
        final value = token.normalizedValue;
        if (value.isEmpty) {
          return true;
        }
        final baseMatch = switch (category) {
          _TasksSearchCategory.status => status.contains(value),
          _TasksSearchCategory.priority => priority.contains(value),
          _TasksSearchCategory.source =>
            sourceKind.contains(value) ||
                sourceId.contains(value) ||
                sourceStepId.contains(value),
          _TasksSearchCategory.space =>
            spaceId.contains(value) || spaceName.contains(value),
        };
        return token.isNegated ? !baseMatch : baseMatch;
      },
      matchesText: (token) => text.contains(token.normalizedValue),
    );
  }

  List<_TasksSearchSuggestion> _tasksSearchSuggestions(
    AppLocalizations l10n,
    List<Map<String, dynamic>> spaces,
  ) {
    final context = parseAtTokenSuggestionContext(_queryCtrl.text);
    if (context == null) {
      return _recentQueries
          .take(6)
          .map(
            (query) => _TasksSearchSuggestion(
              label: query,
              tokenText: query,
              appendSpace: false,
              subtitle: l10n.text('search'),
            ),
          )
          .toList(growable: false);
    }

    if (!context.hasValueSeparator) {
      final category = _normalizeSearchCategory(context.fieldLower);
      if (context.hasTrailingWhitespace && category != null) {
        return _taskSearchValueSuggestions(
          category: category,
          partialLower: '',
          l10n: l10n,
          spaces: spaces,
        );
      }
      final partial = context.partialFieldLower;
      return _TasksSearchCategory.values
          .where((category) {
            final token = _searchCategoryToken(category);
            final label = _searchCategoryLabel(category, l10n).toLowerCase();
            if (partial.isEmpty) return true;
            return token.contains(partial) || label.contains(partial);
          })
          .map(
            (category) => _TasksSearchSuggestion(
              label:
                  '@${_searchCategoryToken(category)} - ${_searchCategoryLabel(category, l10n)}',
              tokenText: '@${_searchCategoryToken(category)}:',
              appendSpace: false,
              subtitle: l10n.text('search'),
            ),
          )
          .toList(growable: false);
    }

    final category = _normalizeSearchCategory(context.fieldLower);
    if (category == null) {
      return const <_TasksSearchSuggestion>[];
    }
    return _taskSearchValueSuggestions(
      category: category,
      partialLower: context.partialValueLower,
      l10n: l10n,
      spaces: spaces,
    );
  }

  List<_TasksSearchSuggestion> _taskSearchValueSuggestions({
    required _TasksSearchCategory category,
    required String partialLower,
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> spaces,
  }) {
    switch (category) {
      case _TasksSearchCategory.status:
        final rows = <({String value, String label})>[
          (value: 'todo', label: l10n.text('task_status_todo')),
          (value: 'in_progress', label: l10n.text('task_status_in_progress')),
          (value: 'blocked', label: l10n.text('task_status_blocked')),
          (value: 'done', label: l10n.text('task_status_done')),
        ];
        return rows
            .where(
              (row) =>
                  row.value.contains(partialLower) ||
                  row.label.toLowerCase().contains(partialLower),
            )
            .map(
              (row) => _TasksSearchSuggestion(
                label: row.label,
                tokenText: '@status:${_encodeSearchTokenValue(row.value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _TasksSearchCategory.priority:
        final rows = <({String value, String label})>[
          (value: 'low', label: l10n.text('priority_low')),
          (value: 'medium', label: l10n.text('priority_medium')),
          (value: 'high', label: l10n.text('priority_high')),
          (value: 'critical', label: l10n.text('priority_critical')),
        ];
        return rows
            .where(
              (row) =>
                  row.value.contains(partialLower) ||
                  row.label.toLowerCase().contains(partialLower),
            )
            .map(
              (row) => _TasksSearchSuggestion(
                label: row.label,
                tokenText: '@priority:${_encodeSearchTokenValue(row.value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _TasksSearchCategory.source:
        final rows = <({String value, String label})>[
          (value: 'sop_run', label: l10n.text('task_source_sop_run')),
          (value: 'sop_step', label: l10n.text('task_source_sop_step')),
          (value: 'sop', label: l10n.text('task_source_sop')),
          (value: 'incident', label: l10n.text('task_source_incident')),
          (
            value: 'incident_action_item',
            label: l10n.text('task_source_incident_action_item'),
          ),
          (value: 'manual', label: l10n.text('task_source_unknown')),
        ];
        return rows
            .where(
              (row) =>
                  row.value.contains(partialLower) ||
                  row.label.toLowerCase().contains(partialLower),
            )
            .map(
              (row) => _TasksSearchSuggestion(
                label: row.label,
                tokenText: '@source:${_encodeSearchTokenValue(row.value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _TasksSearchCategory.space:
        final rows = spaces
            .map((space) {
              final id = (space['id'] ?? '').toString().trim();
              final name = (space['name'] ?? '').toString().trim();
              return (id: id, name: name);
            })
            .where((row) => row.id.isNotEmpty)
            .where(
              (row) =>
                  row.id.toLowerCase().contains(partialLower) ||
                  row.name.toLowerCase().contains(partialLower),
            )
            .take(8)
            .toList(growable: false);
        return rows
            .map(
              (row) => _TasksSearchSuggestion(
                label: row.name.isEmpty ? row.id : '${row.name} (${row.id})',
                tokenText: '@space:${_encodeSearchTokenValue(row.id)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
    }
  }

  String _encodeSearchTokenValue(String value) {
    return value.contains(' ') ? '"$value"' : value;
  }

  void _applySearchSuggestion(_TasksSearchSuggestion suggestion) {
    final currentQuery = _queryCtrl.text;
    final token = suggestion.tokenText.trim();
    final nextText = token.startsWith('@') || token.startsWith('-@')
        ? applyAtTokenSuggestion(
            raw: _queryCtrl.text,
            suggestionToken: suggestion.tokenText,
            appendSpace: suggestion.appendSpace,
          )
        : normalizeSearchInput(token);
    _queryCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    final selectedSpaceId = (_selectedSpaceId ?? '').trim();
    final surface = _showOnlyMyTasks ? 'tasks_my' : 'tasks_space';
    final path = _showOnlyMyTasks || selectedSpaceId.isEmpty
        ? '/tasks'
        : Uri(
            path: '/tasks',
            queryParameters: <String, String>{'spaceId': selectedSpaceId},
          ).toString();
    trackSearchSuggestionAccepted(
      ref,
      surface: surface,
      query: currentQuery,
      nextQuery: nextText,
      path: path,
      entityType: 'task',
      spaceId: _showOnlyMyTasks || selectedSpaceId.isEmpty
          ? null
          : selectedSpaceId,
      suggestionToken: suggestion.tokenText,
      suggestionLabel: suggestion.label,
    );
    _rememberCurrentQuery();
    setState(() {});
  }

  void _removeStructuredSearchToken(SearchFieldToken token) {
    final nextText = removeSearchRangeFromQuery(
      _queryCtrl.text,
      start: token.start,
      end: token.end,
    );
    _queryCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    setState(() {});
  }

  Future<List<_TaskAssigneeChoice>> _loadTaskAssigneeChoices(
    String spaceId, {
    String? directReportsForUserId,
  }) async {
    final normalizedSpaceId = spaceId.trim();
    if (normalizedSpaceId.isEmpty) {
      return const <_TaskAssigneeChoice>[];
    }
    final api = ref.read(apiClientProvider);
    final response = await api.dio.get(
      '/spaces/$normalizedSpaceId/members/detailed',
      queryParameters: (directReportsForUserId ?? '').trim().isEmpty
          ? null
          : <String, dynamic>{
              'direct_reports_for_user_id': directReportsForUserId,
            },
    );
    final members = (response.data as List)
        .cast<Map>()
        .map((entry) => entry.cast<String, dynamic>())
        .toList(growable: false);
    if (members.isEmpty && (directReportsForUserId ?? '').trim().isNotEmpty) {
      return _loadTaskAssigneeChoices(normalizedSpaceId);
    }
    members.sort((left, right) {
      final leftLabel = ((left['name'] ?? left['email'] ?? '') as Object)
          .toString()
          .trim()
          .toLowerCase();
      final rightLabel = ((right['name'] ?? right['email'] ?? '') as Object)
          .toString()
          .trim()
          .toLowerCase();
      return leftLabel.compareTo(rightLabel);
    });
    final choicesById = <String, _TaskAssigneeChoice>{};
    for (final member in members) {
      final id = (member['user_id'] ?? '').toString().trim();
      if (id.isEmpty) {
        continue;
      }
      final name = (member['name'] ?? '').toString().trim();
      final email = (member['email'] ?? '').toString().trim();
      final role = (member['role'] ?? '').toString().trim();
      final subtitleParts = <String>[
        if (email.isNotEmpty && email.toLowerCase() != name.toLowerCase())
          email,
        if (role.isNotEmpty) role,
      ];
      choicesById[id] = _TaskAssigneeChoice(
        id: id,
        label: name.isEmpty ? (email.isEmpty ? id : email) : name,
        subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' • '),
      );
    }
    return choicesById.values.toList(growable: false);
  }

  DateTime? _taskDueDate(Map<String, dynamic> task) {
    final raw = task['due_at'];
    if (raw is DateTime) {
      return raw.toLocal();
    }
    final text = (raw ?? '').toString().trim();
    if (text.isEmpty) {
      return null;
    }
    return DateTime.tryParse(text)?.toLocal();
  }

  List<_TaskChecklistDraftItem> _taskChecklistDraft(Map<String, dynamic> task) {
    final raw = task['checklist'];
    if (raw is! List) {
      return const <_TaskChecklistDraftItem>[];
    }
    return raw
        .whereType<Map>()
        .map((entry) => entry.cast<String, dynamic>())
        .map(
          (entry) => _TaskChecklistDraftItem(
            id: (entry['id'] ?? '').toString().trim().isEmpty
                ? UniqueKey().toString()
                : (entry['id'] ?? '').toString().trim(),
            label: (entry['label'] ?? '').toString().trim(),
            completed: entry['completed'] == true,
          ),
        )
        .where((item) => item.label.isNotEmpty)
        .toList(growable: false);
  }

  bool _isManualTask(Map<String, dynamic> task) {
    final sourceKind = (task['source_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return sourceKind.isEmpty || sourceKind == 'manual';
  }

  void _openTaskPrimaryAction(BuildContext context, Map<String, dynamic> task) {
    final sourceKind = (task['source_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (sourceKind == 'sop_run') {
      _openSopRunTask(context, task);
      return;
    }
    if (_isManualTask(task)) {
      _openManualTask(context, task);
      return;
    }
    _openEditTask(context, task);
  }

  bool _matchesQuickFilter(Map<String, dynamic> task) {
    if (_quickFilter == null) {
      return true;
    }
    final dueAt = _taskDueDate(task);
    if (dueAt == null) {
      return false;
    }
    final status = (task['status'] ?? '').toString().trim().toLowerCase();
    if (status == 'done') {
      return false;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(dueAt.year, dueAt.month, dueAt.day);
    return switch (_quickFilter!) {
      _TaskQuickFilter.overdue => dueDay.isBefore(today),
      _TaskQuickFilter.dueSoon =>
        !dueDay.isBefore(today) &&
            dueDay.isBefore(today.add(const Duration(days: 8))),
    };
  }

  bool _isTaskOverdue(Map<String, dynamic> task) {
    final dueAt = _taskDueDate(task);
    if (dueAt == null) {
      return false;
    }
    final status = (task['status'] ?? '').toString().trim().toLowerCase();
    if (status == 'done') {
      return false;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return dueAt.isBefore(today);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final spacesAsync = ref.watch(spacesProvider(''));

    return AtlasCompactPageFrame(
      title: l10n.text('tasks'),
      actions: <Widget>[
        FilledButton.icon(
          onPressed: () => _openCreateTask(context),
          icon: const Icon(Icons.add_task_outlined),
          label: Text(l10n.text('create')),
        ),
        OutlinedButton.icon(
          onPressed: _refreshTasksView,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.text('refresh')),
        ),
      ],
      child: spacesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AtlasEmptyState(
          icon: Icons.error_outline,
          title: l10n.text('failed_to_load_spaces'),
          subtitle: error.toString(),
          action: FilledButton.icon(
            onPressed: _refreshTasksView,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.text('refresh')),
          ),
        ),
        data: (rawSpaces) {
          final spaces = rawSpaces
              .cast<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
          final parsedSearch = _parseTasksSearchQuery(_queryCtrl.text);
          final searchSuggestions = _tasksSearchSuggestions(l10n, spaces);
          if (spaces.isEmpty) {
            return AtlasEmptyState(
              icon: Icons.hub_outlined,
              title: l10n.text('no_spaces_found'),
              action: FilledButton.icon(
                onPressed: () => context.go('/spaces'),
                icon: const Icon(Icons.hub_outlined),
                label: Text(l10n.text('spaces')),
              ),
            );
          }
          if (widget.autoOpenCreateDialog && !_autoOpenedCreateDialog) {
            _autoOpenedCreateDialog = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _openCreateTask(context);
              }
            });
          }

          final selected = spaces.firstWhere(
            (space) => (space['id'] ?? '').toString() == _selectedSpaceId,
            orElse: () => spaces.first,
          );
          final selectedId = (selected['id'] ?? '').toString();
          final selectedName = (selected['name'] ?? '').toString();
          if (_scope.currentSpaceId.trim().isEmpty && selectedId.isNotEmpty) {
            _scope = _scope.copyWith(
              currentSpaceId: selectedId,
              selectedSpaceIds: <String>[selectedId],
            );
          }

          final normalizedQuery = normalizeSearchInput(_queryCtrl.text);
          final scopeSummary = _scopeSummaryText(spaces, selectedId);

          return FutureBuilder<List<Map<String, dynamic>>>(
            future: _loadTasksForScope(
              spaces: spaces,
              currentSpaceId: selectedId,
              normalizedQuery: normalizedQuery,
            ),
            builder: (context, tasksSnapshot) {
              if (tasksSnapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (tasksSnapshot.hasError) {
                return AtlasEmptyState(
                  icon: Icons.error_outline,
                  title: l10n.text('failed_to_load_tasks'),
                  subtitle: tasksSnapshot.error.toString(),
                  action: FilledButton.icon(
                    onPressed: _refreshTasksView,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.text('refresh')),
                  ),
                );
              }
              final tasks =
                  tasksSnapshot.data ?? const <Map<String, dynamic>>[];
              final filteredTasks = tasks
                  .where(
                    (task) => _matchesTaskSearchQuery(
                      task,
                      parsedSearch,
                      selectedName,
                    ),
                  )
                  .where(_matchesQuickFilter)
                  .toList(growable: false);

              final quickFilters = <Widget>[
                _TaskToolbarChip(
                  label: l10n.text('my_assigned_tasks'),
                  value:
                      '${tasks.where((task) => (task['assignee_email'] ?? '').toString().trim().isNotEmpty).length}',
                  icon: Icons.person_outline,
                  selected: _showOnlyMyTasks && _quickFilter == null,
                  onPressed: () {
                    setState(() {
                      _showOnlyMyTasks = true;
                      _quickFilter = null;
                      _queryCtrl.text = '';
                    });
                  },
                ),
                _TaskToolbarChip(
                  label: l10n.text('tasks'),
                  value:
                      '${tasks.where((task) => (task['status'] ?? '').toString().trim().toLowerCase() != 'done').length}',
                  icon: Icons.play_circle_outline,
                  selected: !_showOnlyMyTasks && _quickFilter == null,
                  onPressed: () {
                    setState(() {
                      _showOnlyMyTasks = false;
                      _quickFilter = null;
                      _queryCtrl.text = '';
                    });
                  },
                ),
                _TaskToolbarChip(
                  label: l10n.text('overdue'),
                  value: '${tasks.where(_isTaskOverdue).length}',
                  icon: Icons.warning_amber_outlined,
                  selected: _quickFilter == _TaskQuickFilter.overdue,
                  onPressed: () {
                    setState(() {
                      _showOnlyMyTasks = false;
                      _quickFilter = _TaskQuickFilter.overdue;
                      _queryCtrl.text = '';
                    });
                  },
                ),
                _TaskToolbarChip(
                  label: l10n.text('task_status_blocked'),
                  value:
                      '${tasks.where((task) => (task['status'] ?? '').toString().trim().toLowerCase() == 'blocked').length}',
                  icon: Icons.block_outlined,
                  selected:
                      normalizeSearchInput(_queryCtrl.text) ==
                      '@status:blocked',
                  onPressed: () {
                    setState(() {
                      _showOnlyMyTasks = false;
                      _quickFilter = null;
                      _queryCtrl.text = '@status:blocked';
                    });
                  },
                ),
              ];
              final secondaryActions = <WorkspaceAction>[
                if (_queryCtrl.text.trim().isNotEmpty)
                  WorkspaceAction(
                    label: l10n.text('save_view'),
                    icon: Icons.bookmark_add_outlined,
                    onSelected: () {
                      _savedViewNameCtrl.text = '';
                      _openSavedViewsDialog(l10n);
                    },
                  ),
                WorkspaceAction(
                  label: l10n.text('load_saved_view'),
                  icon: Icons.bookmark_outline,
                  onSelected: () => _openSavedViewsDialog(l10n),
                ),
                WorkspaceAction(
                  label: l10n.text('search_how_to'),
                  icon: Icons.info_outline,
                  onSelected: () => showSearchHowToDialog(
                    context,
                    capability: tasksSearchCapability,
                  ),
                ),
                WorkspaceAction(
                  label: '${l10n.text('open_space_section')}: $selectedName',
                  icon: Icons.open_in_new_outlined,
                  onSelected: _showOnlyMyTasks || selectedId.isEmpty
                      ? null
                      : () => _openRoute('/spaces/$selectedId'),
                ),
              ];

              _trackQueryResults(
                resultCount: filteredTasks.length,
                selectedSpaceId: selectedId,
              );

              return WorkspaceSurfaceShell(
                headerSections: [
                  WorkspaceSurfaceToolbar(
                    moreTooltip: l10n.text('more'),
                    scope: SizedBox(
                      width: 260,
                      child: WorkspaceScopeButton(
                        label: l10n.text('browse_scope'),
                        summary: _showOnlyMyTasks
                            ? l10n.text('my_assigned_tasks')
                            : scopeSummary,
                        onPressed: () => _openScopePicker(spaces),
                      ),
                    ),
                    search: SizedBox(
                      width: 280,
                      child: TextField(
                        controller: _queryCtrl,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _rememberCurrentQuery(),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          labelText: l10n.text('search'),
                          hintText: structuredSearchHint(
                            l10n: l10n,
                            capability: tasksSearchCapability,
                          ),
                          suffixIcon: _queryCtrl.text.trim().isEmpty
                              ? null
                              : IconButton(
                                  tooltip: l10n.text('clear_search'),
                                  onPressed: () {
                                    setState(() => _queryCtrl.clear());
                                  },
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                      ),
                    ),
                    primaryActions: <Widget>[
                      IconButton(
                        tooltip: l10n.text('task_view_list'),
                        onPressed: () => setState(
                          () => _displayMode = _TaskDisplayMode.list,
                        ),
                        icon: Icon(
                          Icons.view_list_outlined,
                          color: _displayMode == _TaskDisplayMode.list
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.text('task_view_board'),
                        onPressed: () => setState(
                          () => _displayMode = _TaskDisplayMode.board,
                        ),
                        icon: Icon(
                          Icons.view_column_outlined,
                          color: _displayMode == _TaskDisplayMode.board
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.text('refresh'),
                        onPressed: _refreshTasksView,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                    secondaryActions: secondaryActions,
                  ),
                  WorkspaceInlineStrip(
                    spacing: AppSpacing.xs,
                    children: quickFilters,
                  ),
                  if (parsedSearch.structuredTokens.isNotEmpty)
                    WorkspaceInlineStrip(
                      spacing: AppSpacing.xs,
                      children: <Widget>[
                        for (final token in parsedSearch.structuredTokens)
                          InputChip(
                            label: Text(token.toChipLabel()),
                            onDeleted: () =>
                                _removeStructuredSearchToken(token),
                          ),
                      ],
                    ),
                  if (parseAtTokenSuggestionContext(_queryCtrl.text) != null &&
                      searchSuggestions.isNotEmpty)
                    Material(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: searchSuggestions.length,
                          itemBuilder: (context, index) {
                            final suggestion = searchSuggestions[index];
                            return ListTile(
                              dense: true,
                              title: Text(suggestion.label),
                              subtitle: suggestion.subtitle == null
                                  ? null
                                  : Text(suggestion.subtitle!),
                              onTap: () => _applySearchSuggestion(suggestion),
                            );
                          },
                        ),
                      ),
                    ),
                  if (parsedSearch.diagnostics.isNotEmpty)
                    SearchDiagnosticsList(
                      diagnostics: parsedSearch.diagnostics,
                    ),
                ],
                body: filteredTasks.isEmpty
                    ? AtlasEmptyState(
                        icon: Icons.task_alt_outlined,
                        title: parsedSearch.isEmpty
                            ? (_showOnlyMyTasks
                                  ? l10n.text('no_tasks_assigned_in_space')
                                  : l10n.text('no_tasks_in_space'))
                            : l10n.text('no_matching_items'),
                      )
                    : _displayMode == _TaskDisplayMode.board
                    ? _buildTaskBoardPanel(
                        context,
                        l10n: l10n,
                        tasks: filteredTasks,
                      )
                    : Material(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLowest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant
                                .withValues(alpha: 0.72),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.xs,
                          ),
                          itemCount: filteredTasks.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final task = filteredTasks[index];
                            final taskSpaceId = (task['space_id'] ?? '')
                                .toString()
                                .trim();
                            final title =
                                (task['title'] ?? '').toString().trim().isEmpty
                                ? l10n.text('no_data')
                                : (task['title'] ?? '').toString().trim();
                            final status = _taskStatusLabel(
                              l10n,
                              (task['status'] ?? '').toString(),
                            );
                            final priority = _taskPriorityLabel(
                              l10n,
                              (task['priority'] ?? '').toString(),
                            );
                            final due = (task['due_at'] ?? '').toString();
                            final sourceRoute = _taskSourceRoute(task);
                            final sourceLabel = _taskSourceLabel(l10n, task);

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.task_alt_outlined),
                              title: Text(title),
                              subtitle: Text(
                                '$status • $priority'
                                '${due.isEmpty ? '' : ' • ${l10n.text('task_due')}: ${_formatDue(due)}'}'
                                '${(!_showOnlyMyTasks && _scope.mode != WorkspaceScopeMode.current && (task['space_name'] ?? '').toString().trim().isNotEmpty) ? ' • ${(task['space_name'] ?? '').toString().trim()}' : ''}'
                                '${sourceLabel.isEmpty ? '' : ' • $sourceLabel'}',
                              ),
                              trailing: WorkspaceActionMenu(
                                tooltip: l10n.text('more'),
                                actions: <WorkspaceAction>[
                                  if (sourceRoute != null)
                                    WorkspaceAction(
                                      label: l10n.text('open_task_source'),
                                      icon: Icons.call_made_outlined,
                                      onSelected: () => _openRoute(sourceRoute),
                                    ),
                                  if (taskSpaceId.isNotEmpty)
                                    WorkspaceAction(
                                      label: l10n.text('open_space_section'),
                                      icon: Icons.open_in_new_outlined,
                                      onSelected: () =>
                                          _openRoute('/spaces/$taskSpaceId'),
                                    ),
                                  WorkspaceAction(
                                    label: l10n.text('edit_task'),
                                    icon: Icons.edit_outlined,
                                    onSelected: () =>
                                        _openEditTask(context, task),
                                  ),
                                ],
                              ),
                              onTap: () =>
                                  _openTaskPrimaryAction(context, task),
                            );
                          },
                        ),
                      ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openCreateTask(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final spaces = await ref.read(spacesProvider('').future);
    if (!context.mounted) return;
    final parsedSpaces = spaces
        .cast<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (parsedSpaces.isEmpty) return;
    final preselectedSpaceId = (_selectedSpaceId ?? '').trim();
    final initialSpaceId =
        parsedSpaces.any(
          (space) =>
              (space['id'] ?? '').toString().trim() == preselectedSpaceId,
        )
        ? preselectedSpaceId
        : (parsedSpaces.first['id'] ?? '').toString().trim();
    final api = ref.read(apiClientProvider);
    final created = await _showTaskFullScreenRoute<bool>(
      context,
      _TaskEditorScreen(
        pageTitle: l10n.text('create'),
        submitLabel: l10n.text('create'),
        allowSpaceSelection: true,
        spaces: parsedSpaces,
        initialSpaceId: initialSpaceId,
        initialTitle: '',
        initialDescription: '',
        initialStatus: 'todo',
        initialPriority: 'medium',
        initialAssigneeUserId: '',
        initialChecklist: const <_TaskChecklistDraftItem>[],
        showChecklistEditor: true,
        initialDueAt: null,
        loadAssignees: _loadTaskAssigneeChoices,
        onSubmit: (draft) => api.dio.post(
          '/tasks',
          data: <String, dynamic>{
            'space_id': draft.spaceId,
            'title': draft.title,
            'description': draft.description,
            'status': draft.status,
            'priority': draft.priority,
            'assignee_user_id': draft.assigneeUserId.isEmpty
                ? null
                : draft.assigneeUserId,
            'source_kind': 'manual',
            'checklist': draft.checklist
                .map((item) => item.toJson())
                .toList(growable: false),
            'due_at': draft.dueAt?.toUtc().toIso8601String(),
          },
        ),
      ),
    );

    if (created == true) {
      final normalized = normalizeSearchInput(_queryCtrl.text);
      ref.invalidate(myTasksProvider(normalized));
      if (_selectedSpaceId != null && _selectedSpaceId!.isNotEmpty) {
        ref.invalidate(
          spaceTasksProvider((spaceId: _selectedSpaceId!, query: normalized)),
        );
      }
    }
  }

  Future<void> _openEditTask(
    BuildContext context,
    Map<String, dynamic> task,
  ) async {
    final l10n = AppLocalizations.of(context);
    final api = ref.read(apiClientProvider);
    final taskSpaceId = (task['space_id'] ?? '').toString().trim();
    await trackEntityOpen(
      ref,
      entityType: 'task',
      entityId: (task['id'] ?? '').toString(),
      path: taskSpaceId.isEmpty
          ? '/tasks'
          : '/tasks?spaceId=$taskSpaceId&search=${(task['id'] ?? '').toString()}',
      spaceId: taskSpaceId.isEmpty ? null : taskSpaceId,
      surface: 'tasks_edit',
      meta: <String, Object?>{
        'status': (task['status'] ?? '').toString(),
        'priority': (task['priority'] ?? '').toString(),
      },
    );
    if (!context.mounted) return;
    final taskId = (task['id'] ?? '').toString().trim();
    if (taskId.isEmpty) return;
    final taskSpaceName = (task['space_name'] ?? '').toString().trim();
    final saved = await _showTaskFullScreenRoute<bool>(
      context,
      _TaskEditorScreen(
        pageTitle: l10n.text('edit_task'),
        submitLabel: l10n.text('save'),
        allowSpaceSelection: false,
        spaces: <Map<String, dynamic>>[
          <String, dynamic>{'id': taskSpaceId, 'name': taskSpaceName},
        ],
        initialSpaceId: taskSpaceId,
        initialTitle: (task['title'] ?? '').toString(),
        initialDescription: (task['description'] ?? '').toString(),
        initialStatus: (task['status'] ?? 'todo').toString(),
        initialPriority: (task['priority'] ?? 'medium').toString(),
        initialAssigneeUserId: (task['assignee_user_id'] ?? '')
            .toString()
            .trim(),
        initialChecklist: _taskChecklistDraft(task),
        showChecklistEditor: _isManualTask(task),
        initialDueAt: _taskDueDate(task),
        loadAssignees: taskSpaceId.isEmpty
            ? null
            : (spaceId) {
                final taskSourceKind = (task['source_kind'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                final currentAssigneeUserId = (task['assignee_user_id'] ?? '')
                    .toString()
                    .trim();
                if (taskSourceKind == 'sop_run' &&
                    currentAssigneeUserId.isNotEmpty) {
                  return _loadTaskAssigneeChoices(
                    spaceId,
                    directReportsForUserId: currentAssigneeUserId,
                  );
                }
                return _loadTaskAssigneeChoices(spaceId);
              },
        onSubmit: (draft) => api.dio.put(
          '/tasks/$taskId',
          data: <String, dynamic>{
            'title': draft.title,
            'description': draft.description,
            'status': draft.status,
            'priority': draft.priority,
            'assignee_user_id': draft.assigneeUserId.isEmpty
                ? null
                : draft.assigneeUserId,
            if (_isManualTask(task))
              'checklist': draft.checklist
                  .map((item) => item.toJson())
                  .toList(growable: false),
            'due_at': draft.dueAt?.toUtc().toIso8601String(),
          },
        ),
      ),
    );

    if (saved == true) {
      final normalized = normalizeSearchInput(_queryCtrl.text);
      ref.invalidate(myTasksProvider(normalized));
      if (taskSpaceId.isNotEmpty) {
        ref.invalidate(
          spaceTasksProvider((spaceId: taskSpaceId, query: normalized)),
        );
      }
    }
  }

  Future<void> _openSopRunTask(
    BuildContext context,
    Map<String, dynamic> task,
  ) async {
    final taskSpaceId = (task['space_id'] ?? '').toString().trim();
    await trackEntityOpen(
      ref,
      entityType: 'task',
      entityId: (task['id'] ?? '').toString(),
      path: taskSpaceId.isEmpty
          ? '/tasks'
          : '/tasks?spaceId=$taskSpaceId&search=${(task['id'] ?? '').toString()}',
      spaceId: taskSpaceId.isEmpty ? null : taskSpaceId,
      surface: 'tasks_sop_run',
      meta: <String, Object?>{
        'source_kind': (task['source_kind'] ?? '').toString(),
        'source_id': (task['source_id'] ?? '').toString(),
        'source_step_id': (task['source_step_id'] ?? '').toString(),
      },
    );
    if (!context.mounted) return;
    final saved = await _showTaskFullScreenRoute<bool>(
      context,
      SopRunTaskScreen(task: task),
    );
    if (saved == true) {
      final normalized = normalizeSearchInput(_queryCtrl.text);
      ref.invalidate(myTasksProvider(normalized));
      if (taskSpaceId.isNotEmpty) {
        ref.invalidate(
          spaceTasksProvider((spaceId: taskSpaceId, query: normalized)),
        );
      }
    }
  }

  Future<void> _openManualTask(
    BuildContext context,
    Map<String, dynamic> task,
  ) async {
    final taskSpaceId = (task['space_id'] ?? '').toString().trim();
    await trackEntityOpen(
      ref,
      entityType: 'task',
      entityId: (task['id'] ?? '').toString(),
      path: taskSpaceId.isEmpty
          ? '/tasks'
          : '/tasks?spaceId=$taskSpaceId&search=${(task['id'] ?? '').toString()}',
      spaceId: taskSpaceId.isEmpty ? null : taskSpaceId,
      surface: 'tasks_manual',
      meta: <String, Object?>{
        'status': (task['status'] ?? '').toString(),
        'priority': (task['priority'] ?? '').toString(),
      },
    );
    if (!context.mounted) return;
    final saved = await _showTaskFullScreenRoute<bool>(
      context,
      ManualTaskScreen(task: task),
    );
    if (saved == true) {
      final normalized = normalizeSearchInput(_queryCtrl.text);
      ref.invalidate(myTasksProvider(normalized));
      if (taskSpaceId.isNotEmpty) {
        ref.invalidate(
          spaceTasksProvider((spaceId: taskSpaceId, query: normalized)),
        );
      }
    }
  }

  String _taskStatusLabel(AppLocalizations l10n, String status) {
    return switch (status) {
      'in_progress' => l10n.text('task_status_in_progress'),
      'blocked' => l10n.text('task_status_blocked'),
      'done' => l10n.text('task_status_done'),
      _ => l10n.text('task_status_todo'),
    };
  }

  String _taskPriorityLabel(AppLocalizations l10n, String priority) {
    return switch (priority) {
      'low' => l10n.text('priority_low'),
      'high' => l10n.text('priority_high'),
      'critical' => l10n.text('priority_critical'),
      _ => l10n.text('priority_medium'),
    };
  }

  Widget _buildTaskBoardPanel(
    BuildContext context, {
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> tasks,
  }) {
    final buckets = <String, List<Map<String, dynamic>>>{
      'todo': <Map<String, dynamic>>[],
      'in_progress': <Map<String, dynamic>>[],
      'blocked': <Map<String, dynamic>>[],
      'done': <Map<String, dynamic>>[],
    };
    for (final task in tasks) {
      final status = _taskStatusValue(task);
      (buckets[status] ?? buckets['todo']!).add(task);
    }
    for (final rows in buckets.values) {
      rows.sort(_compareTasksForBoard);
    }

    final columns = <Widget>[
      for (final status in <String>['todo', 'in_progress', 'blocked', 'done'])
        _buildTaskBoardColumn(
          context,
          l10n: l10n,
          status: status,
          tasks: buckets[status] ?? const <Map<String, dynamic>>[],
        ),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columnsPerRow = constraints.maxWidth >= 1240
                ? 4
                : constraints.maxWidth >= 760
                ? 2
                : 1;
            if (columnsPerRow == 1) {
              return ListView.separated(
                itemCount: columns.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (_, index) => columns[index],
              );
            }

            final rows = <Widget>[];
            for (
              var index = 0;
              index < columns.length;
              index += columnsPerRow
            ) {
              final slice = columns
                  .skip(index)
                  .take(columnsPerRow)
                  .toList(growable: false);
              rows.add(
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (
                        var offset = 0;
                        offset < columnsPerRow;
                        offset++
                      ) ...<Widget>[
                        Expanded(
                          child: offset < slice.length
                              ? slice[offset]
                              : const SizedBox.shrink(),
                        ),
                        if (offset + 1 < columnsPerRow)
                          const SizedBox(width: AppSpacing.sm),
                      ],
                    ],
                  ),
                ),
              );
            }
            return ListView(children: rows);
          },
        ),
      ),
    );
  }

  Widget _buildTaskBoardColumn(
    BuildContext context, {
    required AppLocalizations l10n,
    required String status,
    required List<Map<String, dynamic>> tasks,
  }) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.surfaceContainerLow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _taskStatusLabel(l10n, status),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Chip(label: Text('${tasks.length}')),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (tasks.isEmpty)
              Text(
                l10n.text('no_data'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ...tasks.map(
                (task) => Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: _buildTaskBoardCard(context, l10n: l10n, task: task),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskBoardCard(
    BuildContext context, {
    required AppLocalizations l10n,
    required Map<String, dynamic> task,
  }) {
    final taskSpaceId = (task['space_id'] ?? '').toString().trim();
    final title = (task['title'] ?? '').toString().trim().isEmpty
        ? l10n.text('no_data')
        : (task['title'] ?? '').toString().trim();
    final priority = _taskPriorityLabel(
      l10n,
      (task['priority'] ?? '').toString(),
    );
    final due = (task['due_at'] ?? '').toString().trim();
    final sourceRoute = _taskSourceRoute(task);
    final sourceLabel = _taskSourceLabel(l10n, task);

    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openTaskPrimaryAction(context, task),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                priority,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (due.isNotEmpty || sourceLabel.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  [
                    if (due.isNotEmpty)
                      '${l10n.text('task_due')}: ${_formatDue(due)}',
                    if (sourceLabel.isNotEmpty) sourceLabel,
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: AppSpacing.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (sourceRoute != null)
                    IconButton(
                      tooltip: l10n.text('open_task_source'),
                      onPressed: () => _openRoute(sourceRoute),
                      icon: const Icon(Icons.call_made_outlined),
                    ),
                  IconButton(
                    tooltip: l10n.text('open_space_section'),
                    onPressed: taskSpaceId.isEmpty
                        ? null
                        : () => _openRoute('/spaces/$taskSpaceId'),
                    icon: const Icon(Icons.open_in_new_outlined),
                  ),
                  IconButton(
                    tooltip: l10n.text('edit_task'),
                    onPressed: () => _openEditTask(context, task),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _taskStatusValue(Map<String, dynamic> task) {
    final status = (task['status'] ?? '').toString().trim().toLowerCase();
    return switch (status) {
      'in_progress' => 'in_progress',
      'blocked' => 'blocked',
      'done' => 'done',
      _ => 'todo',
    };
  }

  int _compareTasksForBoard(
    Map<String, dynamic> left,
    Map<String, dynamic> right,
  ) {
    final leftDue = _taskDueDate(left);
    final rightDue = _taskDueDate(right);
    if (leftDue != null && rightDue != null) {
      final byDue = leftDue.compareTo(rightDue);
      if (byDue != 0) {
        return byDue;
      }
    } else if (leftDue != null) {
      return -1;
    } else if (rightDue != null) {
      return 1;
    }

    final byPriority = _taskPriorityRank(
      (right['priority'] ?? '').toString(),
    ).compareTo(_taskPriorityRank((left['priority'] ?? '').toString()));
    if (byPriority != 0) {
      return byPriority;
    }

    final leftTitle = (left['title'] ?? '').toString().trim().toLowerCase();
    final rightTitle = (right['title'] ?? '').toString().trim().toLowerCase();
    return leftTitle.compareTo(rightTitle);
  }

  int _taskPriorityRank(String priority) {
    return switch (priority.trim().toLowerCase()) {
      'critical' => 4,
      'high' => 3,
      'medium' => 2,
      'low' => 1,
      _ => 0,
    };
  }

  String _taskSourceLabel(AppLocalizations l10n, Map<String, dynamic> task) {
    final sourceKind = (task['source_kind'] ?? '').toString().trim();
    if (sourceKind.isEmpty || sourceKind == 'manual') {
      return '';
    }
    return switch (sourceKind) {
      'sop_run' => l10n.text('task_source_sop_run'),
      'sop' => l10n.text('task_source_sop'),
      'sop_step' => l10n.text('task_source_sop_step'),
      'incident' => l10n.text('task_source_incident'),
      'incident_action_item' => l10n.text('task_source_incident_action_item'),
      _ => l10n.text('task_source_unknown'),
    };
  }

  String? _taskSourceRoute(Map<String, dynamic> task) {
    final sourceKind = (task['source_kind'] ?? '').toString().trim();
    final sourceId = (task['source_id'] ?? '').toString().trim();
    final sourceStepId = (task['source_step_id'] ?? '').toString().trim();
    final spaceId = (task['space_id'] ?? '').toString().trim();
    if (sourceKind.isEmpty || sourceId.isEmpty || spaceId.isEmpty) {
      return null;
    }

    switch (sourceKind) {
      case 'sop_run':
        return Uri(
          path: '/spaces/$spaceId',
          queryParameters: {
            'sopId': sourceId,
            if (sourceStepId.isNotEmpty) 'sopRunId': sourceStepId,
          },
        ).toString();
      case 'sop':
        return Uri(
          path: '/spaces/$spaceId',
          queryParameters: {'sopId': sourceId},
        ).toString();
      case 'sop_step':
        return Uri(
          path: '/spaces/$spaceId',
          queryParameters: {
            'sopId': sourceId,
            if (sourceStepId.isNotEmpty) 'sopStepId': sourceStepId,
          },
        ).toString();
      case 'incident':
        return Uri(
          path: '/spaces/$spaceId',
          queryParameters: {'incidentId': sourceId},
        ).toString();
      case 'incident_action_item':
        return Uri(
          path: '/spaces/$spaceId',
          queryParameters: {
            'incidentId': sourceId,
            if (sourceStepId.isNotEmpty) 'actionItemId': sourceStepId,
          },
        ).toString();
      default:
        return null;
    }
  }

  String _formatDue(String raw) {
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    return '${parsed.year}-${_two(parsed.month)}-${_two(parsed.day)}';
  }

  String _two(int value) => value < 10 ? '0$value' : '$value';
}
