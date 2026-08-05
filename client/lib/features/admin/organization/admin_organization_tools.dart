// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Administrative tool dialogs and shared helpers for organization management.

part of 'admin_organization_screen.dart';

typedef _SessionPolicySubmit =
    Future<void> Function(Map<String, dynamic> payload);

class _SessionPolicyDialog extends StatefulWidget {
  const _SessionPolicyDialog({
    required this.initialPolicy,
    required this.l10n,
    required this.onSubmit,
  });

  final Map<String, dynamic> initialPolicy;
  final AppLocalizations l10n;
  final _SessionPolicySubmit onSubmit;

  @override
  State<_SessionPolicyDialog> createState() => _SessionPolicyDialogState();
}

class _SessionPolicyDialogState extends State<_SessionPolicyDialog> {
  late final TextEditingController _thisBrowserCtrl;
  late final TextEditingController _rememberDeviceCtrl;
  late final TextEditingController _warningCtrl;

  late bool _allowRememberDevice;
  late String _defaultProfile;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _allowRememberDevice =
        widget.initialPolicy['allow_remember_device'] == true;
    _defaultProfile =
        (widget.initialPolicy['default_profile'] ?? 'this_browser')
            .toString()
            .trim();
    _thisBrowserCtrl = TextEditingController(
      text: '${_readPolicyInt('this_browser_days', 1)}',
    );
    _rememberDeviceCtrl = TextEditingController(
      text: '${_readPolicyInt('remember_device_days', 14)}',
    );
    _warningCtrl = TextEditingController(
      text: '${_readPolicyInt('warning_minutes', 15)}',
    );
  }

  @override
  void dispose() {
    _thisBrowserCtrl.dispose();
    _rememberDeviceCtrl.dispose();
    _warningCtrl.dispose();
    super.dispose();
  }

  int _readPolicyInt(String key, int fallback) {
    final raw = widget.initialPolicy[key];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse((raw ?? '').toString()) ?? fallback;
  }

  List<String> get _availableProfiles => <String>[
    'this_browser',
    if (_allowRememberDevice) 'remember_device',
  ];

  String get _effectiveDefaultProfile {
    if (_availableProfiles.contains(_defaultProfile)) {
      return _defaultProfile;
    }
    return _availableProfiles.first;
  }

  Future<void> _submit() async {
    final thisBrowserDays = int.tryParse(_thisBrowserCtrl.text.trim());
    final rememberDeviceDays = int.tryParse(_rememberDeviceCtrl.text.trim());
    final warningMinutes = int.tryParse(_warningCtrl.text.trim());
    if (thisBrowserDays == null ||
        rememberDeviceDays == null ||
        warningMinutes == null) {
      setState(() {
        _error = widget.l10n.text('enter_valid_whole_number');
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(<String, dynamic>{
        'allow_remember_device': _allowRememberDevice,
        'default_profile': _allowRememberDevice
            ? _effectiveDefaultProfile
            : 'this_browser',
        'this_browser_days': thisBrowserDays,
        'remember_device_days': rememberDeviceDays,
        'warning_minutes': warningMinutes,
      });
      if (!mounted) {
        return;
      }
      Navigator.pop(context, true);
    } on DioException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = requestErrorMessage(error, context: context);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.l10n.text('session_policy')),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.l10n.text('session_policy_help'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _allowRememberDevice,
                onChanged: _saving
                    ? null
                    : (value) {
                        setState(() {
                          _allowRememberDevice = value;
                          if (!_allowRememberDevice) {
                            _defaultProfile = 'this_browser';
                          }
                        });
                      },
                title: Text(widget.l10n.text('allow_remember_device_sign_in')),
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<String>(
                key: ValueKey<String>(
                  '${_allowRememberDevice ? '1' : '0'}:$_effectiveDefaultProfile',
                ),
                initialValue: _effectiveDefaultProfile,
                decoration: InputDecoration(
                  labelText: widget.l10n.text('default_session_profile'),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final profile in _availableProfiles)
                    DropdownMenuItem<String>(
                      value: profile,
                      child: Text(
                        profile == 'remember_device'
                            ? widget.l10n.text('remember_this_device')
                            : widget.l10n.text('this_browser_only'),
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _defaultProfile = value;
                        });
                      },
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _thisBrowserCtrl,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: widget.l10n.text('this_browser_duration_days'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _rememberDeviceCtrl,
                enabled: _allowRememberDevice && !_saving,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: widget.l10n.text('remember_device_duration_days'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _warningCtrl,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: widget.l10n.text('session_warning_window_minutes'),
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: Text(widget.l10n.text('cancel')),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(widget.l10n.text('save')),
        ),
      ],
    );
  }
}

extension _AdminOrganizationScreenStateTools on _AdminOrganizationScreenState {
  void _toggleMoreActionsExpanded() {
    (this as dynamic).setState(() {
      _moreActionsExpanded = !_moreActionsExpanded;
    });
  }

  Future<void> _openMediaManager() async {
    if (!mounted) return;
    await context.push('/organization/media');
  }

  Future<void> _openBackupsManager() async {
    if (!mounted) return;
    await context.push('/organization/backups');
  }

  Future<void> _openLocalizationManagerDialog() async {
    final l10n = AppLocalizations.of(context);
    final api = ref.read(apiClientProvider);
    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('i18n_management'),
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.text('i18n_management')),
        content: SizedBox(
          width: 760,
          child: _LocalizationManagerDialog(
            api: api,
            l10n: l10n,
            onApplied: _refreshAll,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.text('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _openSessionPolicyDialog() async {
    final l10n = AppLocalizations.of(context);
    final api = ref.read(apiClientProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);

    Map<String, dynamic> policy;
    try {
      final response = await api.dio.get('/admin/session-policy');
      final payload = response.data;
      if (payload is! Map) {
        throw StateError(l10n.text('failed_to_load_session_policy'));
      }
      policy = payload.cast<String, dynamic>();
    } on DioException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
      return;
    } catch (_) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.text('failed_to_load_session_policy'))),
      );
      return;
    }

    if (!mounted) {
      return;
    }

    final saved = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('session_policy'),
      builder: (_) => _SessionPolicyDialog(
        initialPolicy: policy,
        l10n: l10n,
        onSubmit: (payload) async {
          await _runWithMfaRetry<Response<dynamic>>(
            (api) => api.dio.patch('/admin/session-policy', data: payload),
          );
        },
      ),
    );

    if (saved == true && mounted) {
      _refreshAll();
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.text('session_policy_saved'))),
      );
    }
  }

  Future<void> _openToolLauncherDialog({
    required String announcement,
    required String title,
    required String subtitle,
    required List<_OrganizationToolLauncherAction> actions,
  }) async {
    final l10n = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      announcement: announcement,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 720,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: actions.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final action = actions[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(action.icon),
                      title: Text(action.label),
                      subtitle: Text(action.subtitle),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        Navigator.pop(dialogContext);
                        await action.onTap();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.text('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _openAccessGovernanceToolsDialog(_TreeData data) async {
    final l10n = AppLocalizations.of(context);
    await _openToolLauncherDialog(
      announcement: l10n.text('access_governance_tools'),
      title: l10n.text('access_governance_tools'),
      subtitle: l10n.text('access_governance_tools_help'),
      actions: <_OrganizationToolLauncherAction>[
        _OrganizationToolLauncherAction(
          icon: Icons.account_tree_outlined,
          label: l10n.text('role_binding_editor'),
          subtitle: l10n.text('role_binding_editor_help'),
          onTap: () => _openRoleBindingEditor(data),
        ),
        _OrganizationToolLauncherAction(
          icon: Icons.manage_search_outlined,
          label: l10n.text('why_access_debugger'),
          subtitle: l10n.text('why_access_debugger_help'),
          onTap: () => _openWhyAccessDebugger(data),
        ),
        _OrganizationToolLauncherAction(
          icon: Icons.insights_outlined,
          label: l10n.text('role_impact_simulator'),
          subtitle: l10n.text('role_impact_simulator_help'),
          onTap: () => _openRoleImpactSimulator(data),
        ),
      ],
    );
  }

  Future<void> _openGraphToolsDialog() async {
    final l10n = AppLocalizations.of(context);
    await _openToolLauncherDialog(
      announcement: l10n.text('graph_tools'),
      title: l10n.text('graph_tools'),
      subtitle: l10n.text('graph_tools_help'),
      actions: <_OrganizationToolLauncherAction>[
        _OrganizationToolLauncherAction(
          icon: Icons.rule_folder_outlined,
          label: l10n.text('validate_graph'),
          subtitle: l10n.text('validate_graph_help'),
          onTap: _validateOrganizationGraph,
        ),
        _OrganizationToolLauncherAction(
          icon: Icons.download_outlined,
          label: l10n.text('export_graph'),
          subtitle: l10n.text('export_graph_help'),
          onTap: _exportOrganizationGraphPackage,
        ),
        _OrganizationToolLauncherAction(
          icon: Icons.upload_file_outlined,
          label: l10n.text('import_graph'),
          subtitle: l10n.text('import_graph_help'),
          onTap: _importOrganizationGraphPackage,
        ),
      ],
    );
  }

  Future<void> _openWhyAccessDebugger(_TreeData data) async {
    final l10n = AppLocalizations.of(context);
    final users = _refsForKind(_ItemKind.user, data)
      ..sort(
        (a, b) => _itemLabel(
          a,
          data,
        ).toLowerCase().compareTo(_itemLabel(b, data).toLowerCase()),
      );
    final spaces = _refsForKind(_ItemKind.space, data)
      ..sort(
        (a, b) => _itemLabel(
          a,
          data,
        ).toLowerCase().compareTo(_itemLabel(b, data).toLowerCase()),
      );
    if (users.isEmpty || spaces.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(l10n.text('why_access_requires_user_and_space')),
        ),
      );
      return;
    }

    var selectedUserId = users.first.id;
    var selectedSpaceId = spaces.first.id;
    var loading = false;
    Map<String, dynamic>? result;

    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('why_access_debugger'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final grants = (result?['matching_grants'] is List)
              ? (result?['matching_grants'] as List)
                    .whereType<Map>()
                    .map((row) => row.cast<String, dynamic>())
                    .toList(growable: false)
              : const <Map<String, dynamic>>[];
          final directDepartmentIds = (result?['direct_department_ids'] is List)
              ? (result?['direct_department_ids'] as List)
                    .map((value) => value.toString())
                    .toList(growable: false)
              : const <String>[];
          final directDepartments = directDepartmentIds
              .map(
                (id) => _resolvedRefLabel(
                  kind: _ItemKind.department,
                  id: id,
                  data: data,
                  l10n: l10n,
                ),
              )
              .toList(growable: false);
          final ancestorDepartmentIds =
              (result?['ancestor_department_ids'] is List)
              ? (result?['ancestor_department_ids'] as List)
                    .map((value) => value.toString())
                    .toList(growable: false)
              : const <String>[];
          final ancestorDepartments = ancestorDepartmentIds
              .map(
                (id) => _resolvedRefLabel(
                  kind: _ItemKind.department,
                  id: id,
                  data: data,
                  l10n: l10n,
                ),
              )
              .toList(growable: false);

          return AlertDialog(
            title: Text(l10n.text('why_access_debugger')),
            content: SizedBox(
              width: 900,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      SizedBox(
                        width: 320,
                        child: DropdownButtonFormField<String>(
                          initialValue: selectedUserId,
                          decoration: InputDecoration(
                            labelText: l10n.text('user'),
                          ),
                          items: <DropdownMenuItem<String>>[
                            for (final user in users)
                              DropdownMenuItem<String>(
                                value: user.id,
                                child: Text(
                                  _itemLabel(user, data),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setDialogState(() {
                              selectedUserId = value;
                            });
                          },
                        ),
                      ),
                      SizedBox(
                        width: 320,
                        child: DropdownButtonFormField<String>(
                          initialValue: selectedSpaceId,
                          decoration: InputDecoration(
                            labelText: l10n.text('space'),
                          ),
                          items: <DropdownMenuItem<String>>[
                            for (final space in spaces)
                              DropdownMenuItem<String>(
                                value: space.id,
                                child: Text(
                                  _itemLabel(space, data),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setDialogState(() {
                              selectedSpaceId = value;
                            });
                          },
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: loading
                            ? null
                            : () async {
                                final messenger = ScaffoldMessenger.maybeOf(
                                  context,
                                );
                                setDialogState(() {
                                  loading = true;
                                });
                                try {
                                  final response =
                                      await _runWithMfaRetry<Response<dynamic>>(
                                        (api) => api.dio.get(
                                          '/admin/org/why-access',
                                          queryParameters: <String, dynamic>{
                                            'user_id': selectedUserId,
                                            'space_id': selectedSpaceId,
                                          },
                                        ),
                                      );
                                  final payload = (response.data as Map)
                                      .cast<String, dynamic>();
                                  if (!context.mounted) return;
                                  setDialogState(() {
                                    result = payload;
                                  });
                                } on DioException catch (error) {
                                  if (context.mounted) {
                                    messenger?.showSnackBar(
                                      SnackBar(
                                        content: Text(_dioMessage(error)),
                                      ),
                                    );
                                  }
                                } catch (error) {
                                  if (context.mounted) {
                                    messenger?.showSnackBar(
                                      SnackBar(content: Text(error.toString())),
                                    );
                                  }
                                } finally {
                                  if (context.mounted) {
                                    setDialogState(() {
                                      loading = false;
                                    });
                                  }
                                }
                              },
                        icon: loading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.manage_search_outlined),
                        label: Text(l10n.text('explain_access')),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (result != null) ...<Widget>[
                    Builder(
                      builder: (context) {
                        final finalRole =
                            (result?['final_role'] ?? l10n.text('none'))
                                .toString();
                        final effectiveRole =
                            (result?['final_effective_role'] ??
                                    l10n.text('none'))
                                .toString();
                        return Text(
                          l10n
                              .text('why_access_final_role_format')
                              .replaceAll('{finalRole}', finalRole)
                              .replaceAll('{effectiveRole}', effectiveRole),
                        );
                      },
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n
                          .text('why_access_system_role_format')
                          .replaceAll(
                            '{systemRole}',
                            (result?['system_role'] ?? l10n.text('none'))
                                .toString(),
                          )
                          .replaceAll(
                            '{effectiveRole}',
                            (result?['system_role_effective'] ??
                                    l10n.text('none'))
                                .toString(),
                          ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n
                          .text('why_access_direct_departments_format')
                          .replaceAll(
                            '{departments}',
                            directDepartments.isEmpty
                                ? l10n.text('none')
                                : directDepartments.join(', '),
                          ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n
                          .text('why_access_ancestor_departments_format')
                          .replaceAll(
                            '{departments}',
                            ancestorDepartments.isEmpty
                                ? l10n.text('none')
                                : ancestorDepartments.join(', '),
                          ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (grants.isEmpty)
                      Text(l10n.text('why_access_no_matching_grants'))
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: grants.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final grant = grants[index];
                            final departmentId = (grant['department_id'] ?? '')
                                .toString()
                                .trim();
                            final rawDepartmentName =
                                (grant['department_name'] ?? '')
                                    .toString()
                                    .trim();
                            final departmentName =
                                rawDepartmentName.isNotEmpty &&
                                    rawDepartmentName != departmentId
                                ? rawDepartmentName
                                : _resolvedRefLabel(
                                    kind: _ItemKind.department,
                                    id: departmentId,
                                    data: data,
                                    l10n: l10n,
                                  );
                            final source = (grant['source'] ?? '')
                                .toString()
                                .replaceAll('_', ' ');
                            final grantRole = (grant['grant_role'] ?? 'unknown')
                                .toString();
                            final effectiveRole =
                                (grant['effective_role'] ?? 'unknown')
                                    .toString();
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.alt_route_outlined),
                              title: Text(
                                l10n
                                    .text('why_access_grant_row_format')
                                    .replaceAll(
                                      '{departmentName}',
                                      departmentName,
                                    )
                                    .replaceAll('{grantRole}', grantRole)
                                    .replaceAll(
                                      '{effectiveRole}',
                                      effectiveRole,
                                    ),
                              ),
                              subtitle: Text(source),
                            );
                          },
                        ),
                      ),
                  ],
                ],
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
      ),
    );
  }

  Future<void> _openRoleImpactSimulator(_TreeData data) async {
    final l10n = AppLocalizations.of(context);
    final users = _refsForKind(_ItemKind.user, data)
      ..sort(
        (a, b) => _itemLabel(
          a,
          data,
        ).toLowerCase().compareTo(_itemLabel(b, data).toLowerCase()),
      );
    final departments = _refsForKind(_ItemKind.department, data)
      ..sort(
        (a, b) => _itemLabel(
          a,
          data,
        ).toLowerCase().compareTo(_itemLabel(b, data).toLowerCase()),
      );
    final spaces = _refsForKind(_ItemKind.space, data)
      ..sort(
        (a, b) => _itemLabel(
          a,
          data,
        ).toLowerCase().compareTo(_itemLabel(b, data).toLowerCase()),
      );
    final spaceGrantRoleOptions = data.roleByKey.keys.toSet().toList()..sort();
    final globalRoleOptions = <String>[
      'viewer',
      'member',
      'moderator',
      'admin',
    ];

    if (users.isEmpty || departments.isEmpty || spaces.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            l10n.text('role_impact_requires_user_department_space'),
          ),
        ),
      );
      return;
    }

    var includeGlobalChange = true;
    var includeSpaceGrant = true;
    var removeSpaceGrant = false;
    var selectedUserId = users.first.id;
    var selectedGlobalRole = 'member';
    var selectedDepartmentId = departments.first.id;
    var selectedSpaceId = spaces.first.id;
    var selectedGrantRole = spaceGrantRoleOptions.contains('member')
        ? 'member'
        : spaceGrantRoleOptions.first;
    var inheritToDescendants = true;
    var running = false;
    Map<String, dynamic>? result;

    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('role_impact_simulator'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final accessImpact = (result?['access_impact'] is Map)
              ? (result?['access_impact'] as Map).cast<String, dynamic>()
              : const <String, dynamic>{};
          final changes = (accessImpact['changes'] is List)
              ? (accessImpact['changes'] as List)
                    .whereType<Map>()
                    .map((row) => row.cast<String, dynamic>())
                    .toList(growable: false)
              : const <Map<String, dynamic>>[];

          return AlertDialog(
            title: Text(l10n.text('role_impact_simulator')),
            content: SizedBox(
              width: 920,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.text('simulate_global_role_change')),
                    value: includeGlobalChange,
                    onChanged: (value) => setDialogState(() {
                      includeGlobalChange = value;
                    }),
                  ),
                  if (includeGlobalChange)
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: <Widget>[
                        SizedBox(
                          width: 320,
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedUserId,
                            decoration: InputDecoration(
                              labelText: l10n.text('user'),
                            ),
                            items: <DropdownMenuItem<String>>[
                              for (final user in users)
                                DropdownMenuItem<String>(
                                  value: user.id,
                                  child: Text(
                                    _itemLabel(user, data),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(() {
                                selectedUserId = value;
                              });
                            },
                          ),
                        ),
                        SizedBox(
                          width: 220,
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedGlobalRole,
                            decoration: InputDecoration(
                              labelText: l10n.text('global_role'),
                            ),
                            items: <DropdownMenuItem<String>>[
                              for (final role in globalRoleOptions)
                                DropdownMenuItem<String>(
                                  value: role,
                                  child: Text(role),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(() {
                                selectedGlobalRole = value;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.text('simulate_space_grant_change')),
                    value: includeSpaceGrant,
                    onChanged: (value) => setDialogState(() {
                      includeSpaceGrant = value;
                    }),
                  ),
                  if (includeSpaceGrant) ...<Widget>[
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        l10n.text('remove_existing_department_space_grant'),
                      ),
                      value: removeSpaceGrant,
                      onChanged: (value) => setDialogState(() {
                        removeSpaceGrant = value ?? false;
                      }),
                    ),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: <Widget>[
                        SizedBox(
                          width: 280,
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedDepartmentId,
                            decoration: InputDecoration(
                              labelText: l10n.text('departments'),
                            ),
                            items: <DropdownMenuItem<String>>[
                              for (final department in departments)
                                DropdownMenuItem<String>(
                                  value: department.id,
                                  child: Text(
                                    _itemLabel(department, data),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(() {
                                selectedDepartmentId = value;
                              });
                            },
                          ),
                        ),
                        SizedBox(
                          width: 280,
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedSpaceId,
                            decoration: InputDecoration(
                              labelText: l10n.text('space'),
                            ),
                            items: <DropdownMenuItem<String>>[
                              for (final space in spaces)
                                DropdownMenuItem<String>(
                                  value: space.id,
                                  child: Text(
                                    _itemLabel(space, data),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(() {
                                selectedSpaceId = value;
                              });
                            },
                          ),
                        ),
                        if (!removeSpaceGrant)
                          SizedBox(
                            width: 220,
                            child: DropdownButtonFormField<String>(
                              initialValue: selectedGrantRole,
                              decoration: InputDecoration(
                                labelText: l10n.text('grant_role'),
                              ),
                              items: <DropdownMenuItem<String>>[
                                for (final role in spaceGrantRoleOptions)
                                  DropdownMenuItem<String>(
                                    value: role,
                                    child: Text(role),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                setDialogState(() {
                                  selectedGrantRole = value;
                                });
                              },
                            ),
                          ),
                      ],
                    ),
                    if (!removeSpaceGrant)
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.text('inherit_to_descendants')),
                        value: inheritToDescendants,
                        onChanged: (value) => setDialogState(() {
                          inheritToDescendants = value;
                        }),
                      ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton.icon(
                    onPressed: running
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.maybeOf(
                              context,
                            );
                            final payload = <String, dynamic>{
                              'global_role_changes': includeGlobalChange
                                  ? <Map<String, dynamic>>[
                                      {
                                        'user_id': selectedUserId,
                                        'role_key': selectedGlobalRole,
                                      },
                                    ]
                                  : const <Map<String, dynamic>>[],
                              'space_grant_changes':
                                  includeSpaceGrant && !removeSpaceGrant
                                  ? <Map<String, dynamic>>[
                                      {
                                        'department_id': selectedDepartmentId,
                                        'space_id': selectedSpaceId,
                                        'grant_role': selectedGrantRole,
                                        'inherit_to_descendants':
                                            inheritToDescendants,
                                        'active': true,
                                      },
                                    ]
                                  : const <Map<String, dynamic>>[],
                              'space_grant_removals':
                                  includeSpaceGrant && removeSpaceGrant
                                  ? <Map<String, dynamic>>[
                                      {
                                        'department_id': selectedDepartmentId,
                                        'space_id': selectedSpaceId,
                                      },
                                    ]
                                  : const <Map<String, dynamic>>[],
                            };
                            setDialogState(() {
                              running = true;
                            });
                            try {
                              final response =
                                  await _runWithMfaRetry<Response<dynamic>>(
                                    (api) => api.dio.post(
                                      '/admin/org/role-impact/simulate',
                                      data: payload,
                                    ),
                                  );
                              final simulation = (response.data as Map)
                                  .cast<String, dynamic>();
                              if (!context.mounted) return;
                              setDialogState(() {
                                result = simulation;
                              });
                            } on DioException catch (error) {
                              if (context.mounted) {
                                messenger?.showSnackBar(
                                  SnackBar(content: Text(_dioMessage(error))),
                                );
                              }
                            } catch (error) {
                              if (context.mounted) {
                                messenger?.showSnackBar(
                                  SnackBar(content: Text(error.toString())),
                                );
                              }
                            } finally {
                              if (context.mounted) {
                                setDialogState(() {
                                  running = false;
                                });
                              }
                            }
                          },
                    icon: running
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.insights_outlined),
                    label: Text(l10n.text('run_simulation')),
                  ),
                  if (result != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      l10n
                          .text('role_impact_simulated_counts_format')
                          .replaceAll(
                            '{globalChanges}',
                            '${result?['simulated_global_role_changes'] ?? 0}',
                          )
                          .replaceAll(
                            '{spaceGrantChanges}',
                            '${result?['simulated_space_grant_changes'] ?? 0}',
                          )
                          .replaceAll(
                            '{spaceGrantRemovals}',
                            '${result?['simulated_space_grant_removals'] ?? 0}',
                          ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n
                          .text('role_impact_membership_changes_format')
                          .replaceAll(
                            '{membershipChanges}',
                            '${accessImpact['changed_membership_count'] ?? 0}',
                          )
                          .replaceAll(
                            '{userCount}',
                            '${accessImpact['affected_user_count'] ?? 0}',
                          )
                          .replaceAll(
                            '{spaceCount}',
                            '${accessImpact['affected_space_count'] ?? 0}',
                          ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (changes.isEmpty)
                      Text(l10n.text('role_impact_no_changes_detected'))
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: changes.length > 30 ? 30 : changes.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final row = changes[index];
                            final userId = (row['user_id'] ?? '')
                                .toString()
                                .trim();
                            final rawUserName = (row['user_name'] ?? '')
                                .toString()
                                .trim();
                            final userLabel =
                                rawUserName.isNotEmpty && rawUserName != userId
                                ? rawUserName
                                : _resolvedRefLabel(
                                    kind: _ItemKind.user,
                                    id: userId,
                                    data: data,
                                    l10n: l10n,
                                  );
                            final spaceId = (row['space_id'] ?? '')
                                .toString()
                                .trim();
                            final rawSpaceName = (row['space_name'] ?? '')
                                .toString()
                                .trim();
                            final spaceLabel =
                                rawSpaceName.isNotEmpty &&
                                    rawSpaceName != spaceId
                                ? rawSpaceName
                                : _resolvedRefLabel(
                                    kind: _ItemKind.space,
                                    id: spaceId,
                                    data: data,
                                    l10n: l10n,
                                  );
                            final beforeRole = (row['before_role'] ?? 'none')
                                .toString();
                            final afterRole = (row['after_role'] ?? 'none')
                                .toString();
                            return ListTile(
                              dense: true,
                              title: Text(
                                l10n
                                    .text('role_impact_change_row_format')
                                    .replaceAll('{user}', userLabel)
                                    .replaceAll('{space}', spaceLabel),
                              ),
                              subtitle: Text(
                                l10n
                                    .text('role_impact_change_roles_format')
                                    .replaceAll('{beforeRole}', beforeRole)
                                    .replaceAll('{afterRole}', afterRole),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ],
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
      ),
    );
  }

  Future<void> _validateOrganizationGraph() async {
    final l10n = AppLocalizations.of(context);
    try {
      final response = await _runWithMfaRetry<Response<dynamic>>(
        (api) => api.dio.get('/admin/org/graph/integrity'),
      );
      final payload = (response.data as Map).cast<String, dynamic>();
      final issues = (payload['issues'] is List)
          ? (payload['issues'] as List)
                .whereType<Map>()
                .map((row) => row.cast<String, dynamic>())
                .toList(growable: false)
          : const <Map<String, dynamic>>[];
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        announcement: l10n.text('validate_graph'),
        builder: (context) => AlertDialog(
          title: Text(l10n.text('validate_graph')),
          content: SizedBox(
            width: 840,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n
                      .text('validate_graph_counts_format')
                      .replaceAll('{items}', '${payload['item_count'] ?? 0}')
                      .replaceAll('{links}', '${payload['link_count'] ?? 0}')
                      .replaceAll('{issues}', '${payload['issue_count'] ?? 0}'),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (issues.isEmpty)
                  Text(l10n.text('no_graph_integrity_issues_detected'))
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: issues.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final issue = issues[index];
                        final code = (issue['code'] ?? 'unknown').toString();
                        final severity = (issue['severity'] ?? 'warning')
                            .toString();
                        final message = (issue['message'] ?? '')
                            .toString()
                            .trim();
                        final target =
                            (issue['item_id'] ?? issue['link_id'] ?? '')
                                .toString();
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            severity == 'error'
                                ? Icons.error_outline
                                : Icons.warning_amber_outlined,
                          ),
                          title: Text(
                            '$code${target.isEmpty ? '' : ' · $target'}',
                          ),
                          subtitle: Text(message),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.text('close')),
            ),
          ],
        ),
      );
    } on DioException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _exportOrganizationGraphPackage() async {
    final l10n = AppLocalizations.of(context);
    try {
      final response = await _runWithMfaRetry<Response<dynamic>>(
        (api) => api.dio.post('/admin/org/graph/export'),
      );
      final payload = (response.data as Map).cast<String, dynamic>();
      final encoded = const JsonEncoder.withIndent('  ').convert(payload);
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        ':',
        '-',
      );
      await downloadBytes(
        bytes: utf8.encode(encoded),
        filename: 'organization_graph_$timestamp.json',
        mimeType: 'application/json',
      );
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(l10n.text('organization_graph_export_downloaded')),
        ),
      );
    } on DioException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _importOrganizationGraphPackage() async {
    final l10n = AppLocalizations.of(context);
    try {
      final picked = await FilePicker.platform.pickFiles(
        withData: true,
        type: FileType.custom,
        allowedExtensions: <String>['json'],
      );
      if (picked == null || picked.files.isEmpty) return;
      final bytes = picked.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw StateError(l10n.text('selected_file_is_empty'));
      }
      final raw = utf8.decode(bytes).trim();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw StateError(l10n.text('import_payload_must_be_json_object'));
      }
      final package = decoded.cast<String, dynamic>();

      final dryRunResponse = await _runWithMfaRetry<Response<dynamic>>(
        (api) => api.dio.post(
          '/admin/org/graph/import',
          data: <String, dynamic>{'dry_run': true, 'package': package},
        ),
      );
      final dryRun = (dryRunResponse.data as Map).cast<String, dynamic>();
      final errors = (dryRun['errors'] is List)
          ? (dryRun['errors'] as List).map((e) => e.toString()).toList()
          : const <String>[];
      final warnings = (dryRun['warnings'] is List)
          ? (dryRun['warnings'] as List).map((e) => e.toString()).toList()
          : const <String>[];
      if (!mounted) return;

      final approved = await showAppDialog<bool>(
        context: context,
        announcement: l10n.text('import_graph'),
        builder: (context) => AlertDialog(
          title: Text(l10n.text('import_graph')),
          content: SizedBox(
            width: 760,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n
                      .text('import_graph_dry_run_summary_format')
                      .replaceAll(
                        '{validation}',
                        dryRun['validated'] == true
                            ? l10n.text('valid')
                            : l10n.text('invalid'),
                      )
                      .replaceAll(
                        '{createdItems}',
                        '${dryRun['created_items'] ?? 0}',
                      )
                      .replaceAll(
                        '{updatedItems}',
                        '${dryRun['updated_items'] ?? 0}',
                      )
                      .replaceAll(
                        '{upsertedLinks}',
                        '${dryRun['upserted_links'] ?? 0}',
                      )
                      .replaceAll(
                        '{roleRebound}',
                        '${dryRun['role_rebound'] ?? 0}',
                      ),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (errors.isNotEmpty) ...<Widget>[
                  Text(
                    l10n.text('errors'),
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  for (final error in errors.take(10))
                    Text(
                      '• $error',
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                ],
                if (warnings.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    l10n.text('warnings'),
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  for (final warning in warnings.take(10)) Text('• $warning'),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: errors.isNotEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(l10n.text('import')),
            ),
          ],
        ),
      );
      if (approved != true) return;

      await _runWithMfaRetry<Response<dynamic>>(
        (api) => api.dio.post(
          '/admin/org/graph/import',
          data: <String, dynamic>{'dry_run': false, 'package': package},
        ),
      );
      _refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(l10n.text('organization_graph_import_applied'))),
      );
    } on DioException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  String _translationContentKindForRef(_ItemRef itemRef) {
    return switch (itemRef.kind) {
      _ItemKind.department => 'org_department',
      _ItemKind.space => 'org_space',
      _ItemKind.user => 'org_user',
      _ItemKind.role => 'org_role',
    };
  }

  Future<void> _openItemTranslationReviewDialog(
    _ItemRef itemRef,
    _TreeData data,
  ) async {
    final api = ref.read(apiClientProvider);
    final l10n = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('translation_review'),
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.text('translation_review')),
        content: SizedBox(
          width: 860,
          child: _ItemTranslationReviewDialog(
            api: api,
            l10n: l10n,
            contentKind: _translationContentKindForRef(itemRef),
            contentId: itemRef.id,
            title: _itemLabel(itemRef, data),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.text('close')),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndTreeControls({
    required AppLocalizations l10n,
    required _TreeData data,
    required bool hasExpandedRows,
  }) {
    final createButton = PopupMenuButton<String>(
      tooltip: l10n.text('new_item'),
      onSelected: (value) => _openCreateItemMenu(value, data),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'user',
          child: Text(l10n.text('new_user')),
        ),
        PopupMenuItem<String>(
          value: 'space',
          child: Text(l10n.text('new_space')),
        ),
        PopupMenuItem<String>(
          value: 'department',
          child: Text(l10n.text('new_department')),
        ),
        PopupMenuItem<String>(
          value: 'role',
          child: Text(l10n.text('new_role')),
        ),
        PopupMenuItem<String>(
          value: 'existing_root',
          child: Text(l10n.text('add_existing_to_root')),
        ),
      ],
      icon: const Icon(Icons.add_circle_outline),
    );
    final searchField = TextField(
      controller: _searchCtrl,
      focusNode: _searchFocusNode,
      onSubmitted: (_) => _rememberTreeSearchQuery(),
      decoration: InputDecoration(
        isDense: true,
        labelText: l10n.text('search_items'),
        hintText: structuredSearchHint(
          l10n: l10n,
          capability: orgTreeSearchCapability,
          baseHint: l10n.text('search_hint_org_items_tokens'),
        ),
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchCtrl.text.trim().isEmpty
            ? null
            : IconButton(
                onPressed: _searchCtrl.clear,
                tooltip: l10n.text('clear_search'),
                icon: const Icon(Icons.close),
              ),
      ),
    );
    final actionButtons = <Widget>[
      createButton,
      SearchHowToButton(capability: orgTreeSearchCapability),
      IconButton(
        onPressed: _searchCtrl.text.trim().isEmpty
            ? null
            : () => _openTreeSavedViewsDialog(l10n),
        tooltip: l10n.text('save_view'),
        icon: const Icon(Icons.bookmark_add_outlined),
      ),
      IconButton(
        onPressed: () => _openTreeSavedViewsDialog(l10n),
        tooltip: l10n.text('load_saved_view'),
        icon: const Icon(Icons.bookmark_outline),
      ),
      IconButton(
        onPressed: _openGraphToolsDialog,
        tooltip: l10n.text('graph_tools'),
        icon: const Icon(Icons.rule_folder_outlined),
      ),
      IconButton(
        tooltip: l10n.text(hasExpandedRows ? 'collapse_all' : 'expand_all'),
        onPressed: hasExpandedRows ? _collapseAll : () => _expandAll(data),
        icon: Icon(hasExpandedRows ? Icons.unfold_less : Icons.unfold_more),
      ),
      IconButton(
        onPressed: _refreshAll,
        tooltip: l10n.text('refresh'),
        icon: const Icon(Icons.refresh),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              searchField,
              const SizedBox(height: AppSpacing.xs),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (
                      var index = 0;
                      index < actionButtons.length;
                      index++
                    ) ...<Widget>[
                      if (index > 0) const SizedBox(width: AppSpacing.xs),
                      actionButtons[index],
                    ],
                  ],
                ),
              ),
            ],
          );
        }
        return Row(
          children: <Widget>[
            createButton,
            const SizedBox(width: AppSpacing.xs),
            Expanded(child: searchField),
            const SizedBox(width: AppSpacing.xs),
            SearchHowToButton(capability: orgTreeSearchCapability),
            const SizedBox(width: AppSpacing.xs),
            ...actionButtons.skip(2),
          ],
        );
      },
    );
  }

  Widget _buildMoreRootActionRow({
    required AppLocalizations l10n,
    required IconData icon,
    required String label,
    required String subtitle,
    required Future<void> Function() onTap,
    Widget? trailing,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          await onTap();
        },
        child: Container(
          height: 60,
          padding: const EdgeInsets.only(
            left: AppSpacing.sm + 18,
            right: AppSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              trailing ?? const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMoreRootBranch({
    required AppLocalizations l10n,
    required _TreeData data,
    required AsyncValue<Map<String, dynamic>> customizationAsync,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Material(
          color: Colors.transparent,
          child: InkWell(
            splashFactory: NoSplash.splashFactory,
            highlightColor: cs.primary.withValues(alpha: 0.08),
            hoverColor: cs.primary.withValues(alpha: 0.05),
            onTap: _toggleMoreActionsExpanded,
            child: Container(
              height: 60,
              padding: const EdgeInsets.only(
                left: AppSpacing.sm,
                right: AppSpacing.xs,
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: IconButton(
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 24,
                        ),
                        padding: EdgeInsets.zero,
                        splashRadius: 14,
                        visualDensity: VisualDensity.compact,
                        onPressed: _toggleMoreActionsExpanded,
                        icon: Icon(
                          _moreActionsExpanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: 18,
                        ),
                        tooltip: _moreActionsExpanded
                            ? l10n.text('collapse')
                            : l10n.text('expand'),
                      ),
                    ),
                  ),
                  const Icon(Icons.more_horiz, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l10n.text('more'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.text('organization_access'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        ClipRect(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _moreActionsExpanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.inventory_2_outlined,
                        label: l10n.text('global_items'),
                        subtitle: l10n.text('global_items_help'),
                        onTap: () => _openGlobalItemsDialog(data),
                      ),
                      const Divider(height: 1),
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.admin_panel_settings_outlined,
                        label: l10n.text('access_governance_tools'),
                        subtitle: l10n.text('access_governance_tools_help'),
                        onTap: () => _openAccessGovernanceToolsDialog(data),
                      ),
                      const Divider(height: 1),
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.hub_outlined,
                        label: l10n.text('graph_tools'),
                        subtitle: l10n.text('graph_tools_help'),
                        onTap: _openGraphToolsDialog,
                      ),
                      const Divider(height: 1),
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.translate_outlined,
                        label: l10n.text('i18n_management'),
                        subtitle: l10n.text('translation_admin_ui'),
                        onTap: _openLocalizationManagerDialog,
                      ),
                      const Divider(height: 1),
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.timer_outlined,
                        label: l10n.text('session_policy'),
                        subtitle: l10n.text('session_policy_help'),
                        onTap: _openSessionPolicyDialog,
                      ),
                      const Divider(height: 1),
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.palette_outlined,
                        label: l10n.text('branding_theme'),
                        subtitle: l10n.text('admin_branding_theme_help'),
                        onTap: _openBrandingCustomizerDialog,
                        trailing: customizationAsync.isLoading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.chevron_right, size: 18),
                      ),
                      const Divider(height: 1),
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.perm_media_outlined,
                        label: l10n.text('media_manager'),
                        subtitle: l10n.text('media_manager_help'),
                        onTap: _openMediaManager,
                      ),
                      const Divider(height: 1),
                      _buildMoreRootActionRow(
                        l10n: l10n,
                        icon: Icons.backup_outlined,
                        label: l10n.text('backups'),
                        subtitle: l10n.text('admin_backups_help'),
                        onTap: _openBackupsManager,
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}
