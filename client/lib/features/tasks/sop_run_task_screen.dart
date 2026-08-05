// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Dedicated SOP run task execution screen with evidence capture and forwarding.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html_editor_enhanced/html_editor.dart';

import '../../core/api/api_client.dart';
import '../../core/api/request_error.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/atlas_ui.dart';
import '../../core/widgets/media_upload_section.dart';
import '../../core/widgets/rich_content.dart';

typedef JsonMap = Map<String, dynamic>;

class SopRunTaskScreen extends ConsumerStatefulWidget {
  final JsonMap task;

  const SopRunTaskScreen({super.key, required this.task});

  @override
  ConsumerState<SopRunTaskScreen> createState() => _SopRunTaskScreenState();
}

class _SopRunTaskScreenState extends ConsumerState<SopRunTaskScreen> {
  late final HtmlEditorController _evidenceCtrl;
  bool _busy = false;
  String? _error;
  String? _loadedRunStepId;
  late Future<_SopRunTaskBundle> _bundleFuture;

  String get _taskId => (widget.task['id'] ?? '').toString().trim();
  String get _spaceId => (widget.task['space_id'] ?? '').toString().trim();
  String get _sopId => (widget.task['source_id'] ?? '').toString().trim();
  String get _runId => (widget.task['source_step_id'] ?? '').toString().trim();

  @override
  void initState() {
    super.initState();
    _evidenceCtrl = HtmlEditorController();
    _bundleFuture = _loadBundle();
  }

  Future<_SopRunTaskBundle> _loadBundle() async {
    final api = ref.read(apiClientProvider);
    final detailResponse = await api.dio.get('/sop/sops/$_sopId/detail');
    final sop = _asJsonMap(detailResponse.data);
    final runs = _asJsonList(sop['runs'] ?? const []);
    JsonMap? run;
    for (final candidate in runs) {
      if ((candidate['id'] ?? '').toString().trim() == _runId) {
        run = candidate;
        break;
      }
    }
    if (run == null) {
      throw StateError('SOP run could not be loaded.');
    }

    final membersResponse = await api.dio.get(
      '/spaces/$_spaceId/members/detailed',
    );
    final members = _asJsonList(membersResponse.data)
        .where((member) {
          final userId = (member['user_id'] ?? '').toString().trim();
          final role = (member['role'] ?? '').toString().trim().toLowerCase();
          return userId.isNotEmpty && role != 'viewer';
        })
        .toList(growable: false);

    final runSteps = _asJsonList(run['steps'] ?? const []);
    final stepDefinitions = <String, JsonMap>{
      for (final step in _asJsonList(sop['steps'] ?? const []))
        (step['id'] ?? '').toString().trim(): step,
    };
    JsonMap? currentRunStep;
    for (final step in runSteps) {
      if (step['completed'] != true) {
        currentRunStep = step;
        break;
      }
    }
    currentRunStep ??= runSteps.isEmpty ? null : runSteps.last;

    return _SopRunTaskBundle(
      sop: sop,
      run: run,
      members: members,
      currentRunStep: currentRunStep,
      stepDefinitions: stepDefinitions,
    );
  }

  void _reload() {
    setState(() {
      _error = null;
      _bundleFuture = _loadBundle();
    });
  }

  String _t(BuildContext context, String key) =>
      AppLocalizations.of(context).text(key);

  String _tf(BuildContext context, String key, Map<String, Object?> values) =>
      AppLocalizations.of(context).textWith(key, values);

  String _taskDraftKey(String runStepId) => 'sop-run-task:$_taskId:$runStepId';

  String _runStatusLabel(BuildContext context, String status) {
    switch (status.trim().toLowerCase()) {
      case 'completed':
        return _t(context, 'task_status_done');
      case 'in_progress':
        return _t(context, 'task_status_in_progress');
      default:
        return status.trim().isEmpty ? _t(context, 'task_status_todo') : status;
    }
  }

  String _memberLabel(JsonMap member) {
    final name = (member['name'] ?? '').toString().trim();
    final email = (member['email'] ?? '').toString().trim();
    if (name.isNotEmpty) {
      return email.isEmpty || email.toLowerCase() == name.toLowerCase()
          ? name
          : '$name • $email';
    }
    return email.isEmpty ? (member['user_id'] ?? '').toString() : email;
  }

  String _formatDateTime(String? raw) {
    final parsed = DateTime.tryParse(raw ?? '')?.toLocal();
    if (parsed == null) {
      return '';
    }
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    final hour = parsed.hour.toString().padLeft(2, '0');
    final minute = parsed.minute.toString().padLeft(2, '0');
    return '${parsed.year}-$month-$day $hour:$minute';
  }

  String _buildNextTaskTitle({
    required JsonMap sop,
    required JsonMap? currentRunStep,
    required bool completed,
  }) {
    final sopTitle = (sop['title'] ?? '').toString().trim();
    if (completed || currentRunStep == null) {
      return 'Completed SOP run: $sopTitle';
    }
    final stepOrder = _asInt(currentRunStep['step_order']);
    final stepTitle = (currentRunStep['title'] ?? '').toString().trim();
    return 'Step $stepOrder • $stepTitle';
  }

  String _buildNextTaskDescription({
    required AppLocalizations l10n,
    required JsonMap sop,
    required JsonMap? currentRunStep,
    required JsonMap? stepDefinition,
    required bool completed,
  }) {
    final sopTitle = (sop['title'] ?? '').toString().trim();
    if (completed || currentRunStep == null) {
      return l10n.textWith('sop_run_finished_task_description', {
        'title': sopTitle,
      });
    }
    final body = (stepDefinition?['body_md'] ?? '').toString().trim();
    if (body.isEmpty) {
      return l10n.textWith('sop_run_step_task_description_short', {
        'title': sopTitle,
        'step': _asInt(currentRunStep['step_order']),
      });
    }
    return l10n.textWith('sop_run_step_task_description', {
      'title': sopTitle,
      'step': _asInt(currentRunStep['step_order']),
      'body': body,
    });
  }

  Future<void> _markCurrentStepDone(_SopRunTaskBundle bundle) async {
    final currentStep = bundle.currentRunStep;
    if (currentStep == null || _busy) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final note = await readEditorDocumentText(_evidenceCtrl);
      final runStepId = (currentStep['id'] ?? '').toString().trim();
      await api.dio.put(
        '/sop/runs/$_runId/steps/$runStepId',
        data: <String, Object?>{'completed': true, 'evidence_note': note},
      );
      await clearRichEditorDraft(
        _taskDraftKey(runStepId),
        controller: _evidenceCtrl,
      );

      final refreshed = await _loadBundle();
      final nextStep = refreshed.currentRunStep;
      final runSteps = _asJsonList(refreshed.run['steps'] ?? const []);
      final runCompleted =
          runSteps.isNotEmpty &&
          runSteps.every((step) => step['completed'] == true);

      if (runCompleted) {
        await api.dio.post('/sop/runs/$_runId/complete');
      }

      final stepDefinition = nextStep == null
          ? null
          : refreshed.stepDefinitions[(nextStep['step_id'] ?? '')
                .toString()
                .trim()];
      await api.dio.put(
        '/tasks/$_taskId',
        data: <String, Object?>{
          'title': _buildNextTaskTitle(
            sop: refreshed.sop,
            currentRunStep: runCompleted ? null : nextStep,
            completed: runCompleted,
          ),
          'description': _buildNextTaskDescription(
            l10n: l10n,
            sop: refreshed.sop,
            currentRunStep: runCompleted ? null : nextStep,
            stepDefinition: stepDefinition,
            completed: runCompleted,
          ),
          'status': runCompleted ? 'done' : 'in_progress',
        },
      );

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            runCompleted
                ? _t(context, 'sop_run_completed')
                : _t(context, 'sop_run_advanced_to_next_step'),
          ),
        ),
      );
      setState(() {
        _bundleFuture = Future<_SopRunTaskBundle>.value(refreshed);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = requestErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _forwardTask(_SopRunTaskBundle bundle) async {
    if (_busy) {
      return;
    }
    final currentAssigneeId = (widget.task['assignee_user_id'] ?? '')
        .toString()
        .trim();
    final options = bundle.members
        .where(
          (member) =>
              (member['user_id'] ?? '').toString().trim().isNotEmpty &&
              (member['user_id'] ?? '').toString().trim() != currentAssigneeId,
        )
        .toList(growable: false);
    if (options.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t(context, 'no_forward_targets_available'))),
      );
      return;
    }

    String selectedUserId = (options.first['user_id'] ?? '').toString().trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(_t(context, 'forward_task')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(_t(context, 'forward_task_help')),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: selectedUserId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _t(context, 'assignee'),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final member in options)
                      DropdownMenuItem<String>(
                        value: (member['user_id'] ?? '').toString().trim(),
                        child: Text(
                          _memberLabel(member),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => selectedUserId = value ?? ''),
                ),
              ],
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

    if (confirmed != true || selectedUserId.trim().isEmpty) {
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
        data: <String, Object?>{
          'assignee_user_id': selectedUserId,
          'status': 'todo',
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
      setState(() => _error = requestErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _buildStepProgress(
    BuildContext context, {
    required _SopRunTaskBundle bundle,
  }) {
    final runSteps = _asJsonList(bundle.run['steps'] ?? const []);
    final currentStepId = (bundle.currentRunStep?['id'] ?? '')
        .toString()
        .trim();
    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _t(context, 'steps'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            for (final step in runSteps)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _RunStepProgressTile(
                  title: (step['title'] ?? '').toString(),
                  stepLabel: _tf(context, 'sop_run_step_label', {
                    'step': _asInt(step['step_order']),
                  }),
                  completed: step['completed'] == true,
                  active:
                      currentStepId.isNotEmpty &&
                      (step['id'] ?? '').toString().trim() == currentStepId,
                  completedAt: _formatDateTime(
                    step['completed_at']?.toString(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentStepPanel(
    BuildContext context, {
    required _SopRunTaskBundle bundle,
  }) {
    final currentStep = bundle.currentRunStep;
    if (currentStep == null) {
      return AppFlatCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(_t(context, 'sop_run_completed')),
        ),
      );
    }
    final stepId = (currentStep['step_id'] ?? '').toString().trim();
    final stepDefinition = bundle.stepDefinitions[stepId];
    final runStepId = (currentStep['id'] ?? '').toString().trim();
    final initialEvidence = (currentStep['evidence_note'] ?? '').toString();
    if (_loadedRunStepId != runStepId) {
      _loadedRunStepId = runStepId;
    }

    return AppFlatCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _tf(context, 'sop_run_current_step_title', {
                'step': _asInt(currentStep['step_order']),
              }),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              (currentStep['title'] ?? '').toString(),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            if ((stepDefinition?['body_md'] ?? '')
                .toString()
                .trim()
                .isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              RichContentView(
                content: (stepDefinition?['body_md'] ?? '').toString(),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(
                  avatar: const Icon(Icons.rule_folder_outlined, size: 18),
                  label: Text(
                    currentStep['evidence_required'] == true
                        ? _t(context, 'evidence_required')
                        : _t(context, 'evidence_optional'),
                  ),
                ),
                if (_asInt(currentStep['evidence_min_files']) > 0)
                  Chip(
                    avatar: const Icon(Icons.attach_file_outlined, size: 18),
                    label: Text(
                      _tf(context, 'sop_run_evidence_min_files', {
                        'count': _asInt(currentStep['evidence_min_files']),
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            RichEditor(
              key: ValueKey<String>('evidence:$runStepId'),
              controller: _evidenceCtrl,
              initialContent: initialEvidence,
              hint: _t(context, 'sop_run_evidence_hint'),
              height: 280,
              compact: true,
              draftKey: _taskDraftKey(runStepId),
            ),
            const SizedBox(height: 16),
            MediaUploadSection(
              title: _t(context, 'evidence_attachments'),
              usage: 'sop_attachment',
              spaceId: _spaceId,
              compact: true,
              emptyLabel: _t(context, 'sop_run_no_evidence_files'),
              attachEntityType: 'sop_run_step',
              attachEntityId: runStepId,
              showMetadataControls: false,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AtlasCompactPageFrame(
      title: l10n.text('sop_run_task'),
      leading: IconButton(
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        icon: const Icon(Icons.arrow_back),
      ),
      actions: <Widget>[
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  final refreshed = await _bundleFuture;
                  if (!mounted) {
                    return;
                  }
                  await _forwardTask(refreshed);
                },
          icon: const Icon(Icons.forward_to_inbox_outlined),
          label: Text(_t(context, 'forward_task')),
        ),
        FutureBuilder<_SopRunTaskBundle>(
          future: _bundleFuture,
          builder: (context, snapshot) {
            final bundle = snapshot.data;
            return FilledButton.icon(
              onPressed:
                  _busy || bundle == null || bundle.currentRunStep == null
                  ? null
                  : () => _markCurrentStepDone(bundle),
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(_t(context, 'mark_step_done')),
            );
          },
        ),
      ],
      child: FutureBuilder<_SopRunTaskBundle>(
        future: _bundleFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      requestErrorMessage(snapshot.error!),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _reload,
                      child: Text(_t(context, 'retry')),
                    ),
                  ],
                ),
              ),
            );
          }
          final bundle = snapshot.data!;
          final runSteps = _asJsonList(bundle.run['steps'] ?? const []);
          final completedCount = runSteps
              .where((step) => step['completed'] == true)
              .length;
          final currentStep = bundle.currentRunStep;
          final sopTitle = (bundle.sop['title'] ?? '').toString();

          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: ListView(
                children: <Widget>[
                  AppFlatCard(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            sopTitle,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              Chip(
                                avatar: const Icon(
                                  Icons.play_circle_outline,
                                  size: 18,
                                ),
                                label: Text(
                                  _runStatusLabel(
                                    context,
                                    (bundle.run['status'] ?? '').toString(),
                                  ),
                                ),
                              ),
                              Chip(
                                avatar: const Icon(
                                  Icons.stacked_line_chart_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  _tf(context, 'sop_run_progress', {
                                    'done': completedCount,
                                    'total': runSteps.length,
                                  }),
                                ),
                              ),
                              if (currentStep != null)
                                Chip(
                                  avatar: const Icon(
                                    Icons.flag_outlined,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _tf(context, 'sop_run_current_step_short', {
                                      'step': _asInt(currentStep['step_order']),
                                    }),
                                  ),
                                ),
                            ],
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
                  ),
                  const SizedBox(height: 16),
                  _buildCurrentStepPanel(context, bundle: bundle),
                  const SizedBox(height: 16),
                  _buildStepProgress(context, bundle: bundle),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SopRunTaskBundle {
  final JsonMap sop;
  final JsonMap run;
  final List<JsonMap> members;
  final JsonMap? currentRunStep;
  final Map<String, JsonMap> stepDefinitions;

  const _SopRunTaskBundle({
    required this.sop,
    required this.run,
    required this.members,
    required this.currentRunStep,
    required this.stepDefinitions,
  });
}

class _RunStepProgressTile extends StatelessWidget {
  final String title;
  final String stepLabel;
  final bool completed;
  final bool active;
  final String completedAt;

  const _RunStepProgressTile({
    required this.title,
    required this.stepLabel,
    required this.completed,
    required this.active,
    required this.completedAt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: active
          ? cs.primaryContainer.withValues(alpha: 0.55)
          : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              completed
                  ? Icons.check_circle
                  : active
                  ? Icons.play_circle_fill
                  : Icons.radio_button_unchecked,
              color: completed
                  ? cs.primary
                  : active
                  ? cs.primary
                  : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    stepLabel,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (completedAt.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      completedAt,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

JsonMap _asJsonMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  return <String, dynamic>{};
}

List<JsonMap> _asJsonList(Object? value) {
  if (value is! List) {
    return const <JsonMap>[];
  }
  return value
      .whereType<Map>()
      .map((entry) => entry.cast<String, dynamic>())
      .toList(growable: false);
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
}
