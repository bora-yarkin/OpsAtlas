// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Relationship mutation helpers for the organization management screen.

part of 'admin_organization_screen.dart';

extension _AdminOrganizationScreenStateRelationshipActions
    on _AdminOrganizationScreenState {
  void _setRelationshipState(VoidCallback update) {
    (this as dynamic).setState(update);
  }

  Future<List<Map<String, dynamic>>> _loadAuditEventsForRef(
    _ItemRef itemRef,
  ) async {
    final api = ref.read(apiClientProvider);
    final response = await api.dio.get(
      '/admin/org/audit',
      queryParameters: <String, dynamic>{
        'item_kind': _itemKindApiName(itemRef.kind),
        'item_id': itemRef.id,
        'limit': 120,
      },
    );
    return (response.data as List)
        .cast<Map>()
        .map((row) => row.cast<String, dynamic>())
        .toList();
  }

  Future<List<Map<String, dynamic>>> _auditEventsFutureForRef(
    _ItemRef itemRef,
  ) {
    return _auditEventsFutureByItemKey.putIfAbsent(
      itemRef.key,
      () => _loadAuditEventsForRef(itemRef),
    );
  }

  Future<void> _openRoleBindingEditor(_TreeData data) async {
    final l10n = AppLocalizations.of(context);
    var parentKind = _ItemKind.department;
    var childKind = _ItemKind.space;
    String? parentId;
    String? childId;
    var grantRole = 'member';
    var inheritToDescendants = true;
    final bindingParentKinds = <_ItemKind>[
      _ItemKind.department,
      _ItemKind.user,
      _ItemKind.role,
    ];

    Map<String, dynamic>? findSelectedLink() {
      if (parentId == null || childId == null) return null;
      final parentKindApi = _itemKindApiName(parentKind);
      final childKindApi = _itemKindApiName(childKind);
      for (final link in data.itemLinks) {
        if (link['active'] == false) continue;
        if ((link['parent_kind'] ?? '').toString().trim().toLowerCase() !=
            parentKindApi) {
          continue;
        }
        if ((link['child_kind'] ?? '').toString().trim().toLowerCase() !=
            childKindApi) {
          continue;
        }
        if ((link['parent_id'] ?? '').toString().trim() != parentId) continue;
        if ((link['child_id'] ?? '').toString().trim() != childId) continue;
        return link;
      }
      return null;
    }

    void syncDraftFromLink() {
      final selectedLink = findSelectedLink();
      if (selectedLink != null) {
        grantRole = (selectedLink['grant_role'] ?? '').toString().trim().isEmpty
            ? 'member'
            : (selectedLink['grant_role'] ?? '').toString().trim();
        inheritToDescendants = selectedLink['inherit_to_descendants'] != false;
      } else {
        grantRole = parentKind == _ItemKind.role
            ? (parentId ?? 'member')
            : 'member';
        inheritToDescendants = parentKind != _ItemKind.role;
      }
      if (parentKind == _ItemKind.role) {
        grantRole = parentId ?? grantRole;
        inheritToDescendants = false;
      }
    }

    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('role_binding_editor'),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final parentOptions = _refsForKind(
            parentKind,
            data,
          ).where((ref) => ref.id.trim().isNotEmpty).toList();
          if (parentId == null ||
              !parentOptions.any((ref) => ref.id == parentId)) {
            parentId = parentOptions.isNotEmpty ? parentOptions.first.id : null;
          }

          final childKindOptions = _childKindsForParentKind(parentKind);
          if (!childKindOptions.contains(childKind)) {
            childKind = childKindOptions.isNotEmpty
                ? childKindOptions.first
                : _ItemKind.user;
          }

          final childOptions = _refsForKind(childKind, data)
              .where((ref) => ref.id.trim().isNotEmpty)
              .where((ref) {
                if (parentKind == childKind && parentId != null) {
                  return ref.id != parentId;
                }
                return true;
              })
              .toList();
          if (childId == null ||
              !childOptions.any((ref) => ref.id == childId)) {
            childId = childOptions.isNotEmpty ? childOptions.first.id : null;
          }

          final selectedLink = findSelectedLink();
          final selectedLinkId = (selectedLink?['id'] ?? '').toString().trim();
          final canSaveBinding = parentId != null && childId != null;
          final roleOptions =
              _refsForKind(_ItemKind.role, data)
                  .map((ref) => ref.id)
                  .where((roleKey) => roleKey.trim().isNotEmpty)
                  .toSet()
                  .toList()
                ..sort();
          if (!roleOptions.contains(grantRole)) {
            grantRole = 'member';
          }
          if (!roleOptions.contains('member')) {
            roleOptions.insert(0, 'member');
          }

          final bindingRows =
              data.itemLinks.where((link) {
                if (link['active'] == false) return false;
                final parentKindRaw = (link['parent_kind'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                final childKindRaw = (link['child_kind'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                final parentItemKind = _itemKindFromApiName(parentKindRaw);
                final childItemKind = _itemKindFromApiName(childKindRaw);
                if (parentItemKind == null || childItemKind == null) {
                  return false;
                }
                return _isSupportedLinkPair(parentItemKind, childItemKind);
              }).toList()..sort((a, b) {
                final aParentKind = _itemKindFromApiName(
                  (a['parent_kind'] ?? '').toString(),
                );
                final aChildKind = _itemKindFromApiName(
                  (a['child_kind'] ?? '').toString(),
                );
                final bParentKind = _itemKindFromApiName(
                  (b['parent_kind'] ?? '').toString(),
                );
                final bChildKind = _itemKindFromApiName(
                  (b['child_kind'] ?? '').toString(),
                );
                if (aParentKind == null ||
                    aChildKind == null ||
                    bParentKind == null ||
                    bChildKind == null) {
                  return 0;
                }
                final aRef = _ItemRef(
                  kind: aParentKind,
                  id: (a['parent_id'] ?? '').toString(),
                );
                final bRef = _ItemRef(
                  kind: bParentKind,
                  id: (b['parent_id'] ?? '').toString(),
                );
                final aParentLabel = _itemLabel(aRef, data).toLowerCase();
                final bParentLabel = _itemLabel(bRef, data).toLowerCase();
                final parentOrder = aParentLabel.compareTo(bParentLabel);
                if (parentOrder != 0) return parentOrder;
                final aChildRef = _ItemRef(
                  kind: aChildKind,
                  id: (a['child_id'] ?? '').toString(),
                );
                final bChildRef = _ItemRef(
                  kind: bChildKind,
                  id: (b['child_id'] ?? '').toString(),
                );
                return _itemLabel(aChildRef, data).toLowerCase().compareTo(
                  _itemLabel(bChildRef, data).toLowerCase(),
                );
              });

          return AlertDialog(
            title: Text(l10n.text('role_binding_editor')),
            content: SizedBox(
              width: 980,
              height: 620,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.text('role_binding_editor_help'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      SizedBox(
                        width: 220,
                        child: DropdownButtonFormField<_ItemKind>(
                          initialValue: parentKind,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.text('parent_kind'),
                          ),
                          items: <DropdownMenuItem<_ItemKind>>[
                            for (final kind in bindingParentKinds)
                              DropdownMenuItem<_ItemKind>(
                                value: kind,
                                child: Text(_itemKindLabel(kind, l10n)),
                              ),
                          ],
                          onChanged: (value) => setDialogState(() {
                            parentKind = value ?? parentKind;
                            childKind = _childKindsForParentKind(
                              parentKind,
                            ).first;
                            parentId = null;
                            childId = null;
                            syncDraftFromLink();
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 320,
                        child: DropdownButtonFormField<String?>(
                          initialValue: parentId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.text('parent_item'),
                          ),
                          items: <DropdownMenuItem<String?>>[
                            for (final ref in parentOptions)
                              DropdownMenuItem<String?>(
                                value: ref.id,
                                child: Text(
                                  _itemLabel(ref, data),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) => setDialogState(() {
                            parentId = value;
                            syncDraftFromLink();
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 220,
                        child: DropdownButtonFormField<_ItemKind>(
                          initialValue: childKind,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.text('child_kind'),
                          ),
                          items: <DropdownMenuItem<_ItemKind>>[
                            for (final kind in childKindOptions)
                              DropdownMenuItem<_ItemKind>(
                                value: kind,
                                child: Text(_itemKindLabel(kind, l10n)),
                              ),
                          ],
                          onChanged: (value) => setDialogState(() {
                            childKind = value ?? childKind;
                            childId = null;
                            syncDraftFromLink();
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 320,
                        child: DropdownButtonFormField<String?>(
                          initialValue: childId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.text('child_item'),
                          ),
                          items: <DropdownMenuItem<String?>>[
                            for (final ref in childOptions)
                              DropdownMenuItem<String?>(
                                value: ref.id,
                                child: Text(
                                  _itemLabel(ref, data),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) => setDialogState(() {
                            childId = value;
                            syncDraftFromLink();
                          }),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: <Widget>[
                      if (parentKind == _ItemKind.department &&
                          childKind == _ItemKind.space)
                        SizedBox(
                          width: 280,
                          child: DropdownButtonFormField<String>(
                            initialValue: grantRole,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: l10n.text('grant_role'),
                            ),
                            items: <DropdownMenuItem<String>>[
                              for (final roleKey in roleOptions)
                                DropdownMenuItem<String>(
                                  value: roleKey,
                                  child: Text(
                                    data.roleByKey[roleKey]?['name']
                                            ?.toString() ??
                                        roleKey,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) => setDialogState(() {
                              grantRole = value ?? grantRole;
                            }),
                          ),
                        )
                      else
                        Expanded(
                          child: Text(
                            parentKind == _ItemKind.role
                                ? l10n.text('role_binding_role_parent_help')
                                : l10n.text('role_binding_default_grant_help'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.text('inherit_to_descendants')),
                          value: parentKind == _ItemKind.role
                              ? false
                              : inheritToDescendants,
                          onChanged: parentKind == _ItemKind.role
                              ? null
                              : (value) => setDialogState(() {
                                  inheritToDescendants = value;
                                }),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: !canSaveBinding
                            ? null
                            : () async {
                                final parentKindApi = _itemKindApiName(
                                  parentKind,
                                );
                                final childKindApi = _itemKindApiName(
                                  childKind,
                                );
                                final effectiveGrantRole =
                                    parentKind == _ItemKind.role
                                    ? (parentId ?? 'member')
                                    : (parentKind == _ItemKind.department &&
                                              childKind == _ItemKind.space
                                          ? grantRole
                                          : 'member');
                                await _call(
                                  (api) => api.dio.post(
                                    '/admin/org/item-links',
                                    data: {
                                      'parent_kind': parentKindApi,
                                      'parent_id': parentId,
                                      'child_kind': childKindApi,
                                      'child_id': childId,
                                      'grant_role': effectiveGrantRole,
                                      'inherit_to_descendants':
                                          parentKind == _ItemKind.role
                                          ? false
                                          : inheritToDescendants,
                                      'active': true,
                                    },
                                  ),
                                  successMessage: l10n.text('save_changes'),
                                );
                                if (context.mounted) Navigator.pop(context);
                              },
                        icon: const Icon(Icons.link_outlined),
                        label: Text(l10n.text('save_binding')),
                      ),
                      OutlinedButton.icon(
                        onPressed: selectedLinkId.isEmpty
                            ? null
                            : () async {
                                await _call(
                                  (api) => api.dio.delete(
                                    '/admin/org/item-links/$selectedLinkId',
                                  ),
                                  successMessage: l10n.text('save_changes'),
                                );
                                if (context.mounted) Navigator.pop(context);
                              },
                        icon: const Icon(Icons.link_off_outlined),
                        label: Text(l10n.text('remove_binding')),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    l10n.text('existing_bindings'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Expanded(
                    child: bindingRows.isEmpty
                        ? Center(child: Text(l10n.text('no_matching_items')))
                        : ListView.separated(
                            itemCount: bindingRows.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final link = bindingRows[index];
                              final parentItemKind = _itemKindFromApiName(
                                (link['parent_kind'] ?? '').toString(),
                              );
                              final childItemKind = _itemKindFromApiName(
                                (link['child_kind'] ?? '').toString(),
                              );
                              if (parentItemKind == null ||
                                  childItemKind == null) {
                                return const SizedBox.shrink();
                              }
                              final parentRef = _ItemRef(
                                kind: parentItemKind,
                                id: (link['parent_id'] ?? '').toString(),
                              );
                              final childRef = _ItemRef(
                                kind: childItemKind,
                                id: (link['child_id'] ?? '').toString(),
                              );
                              final parentLabel = _itemLabel(parentRef, data);
                              final childLabel = _itemLabel(childRef, data);
                              final grantRoleLabel = (link['grant_role'] ?? '')
                                  .toString();
                              final inherit =
                                  link['inherit_to_descendants'] != false;
                              return ListTile(
                                dense: true,
                                leading: const Icon(
                                  Icons.account_tree_outlined,
                                ),
                                title: Text('$parentLabel -> $childLabel'),
                                subtitle: Text(
                                  '${l10n.text('grant_role')}: $grantRoleLabel • ${l10n.text('inherit_to_descendants')}: ${inherit ? l10n.text('meta_value_true') : l10n.text('meta_value_false')}',
                                ),
                                onTap: () => setDialogState(() {
                                  parentKind = parentItemKind;
                                  childKind = childItemKind;
                                  parentId = parentRef.id;
                                  childId = childRef.id;
                                  syncDraftFromLink();
                                }),
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
          );
        },
      ),
    );
  }

  Future<void> _bulkLinkItemsToParent({
    required _ItemRef parent,
    required List<_ItemRef> children,
    required _TreeData data,
  }) async {
    final l10n = AppLocalizations.of(context);
    Future<bool> confirmBulkMutation(Map<String, dynamic> plan) async {
      try {
        final preview = await _runWithMfaRetry<Response<dynamic>>(
          (api) =>
              api.dio.post('/admin/org/item-links/bulk/preview', data: plan),
        );
        final result = (preview.data as Map).cast<String, dynamic>();
        final impact = (result['access_impact'] is Map)
            ? (result['access_impact'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        final rawChanges = (impact['changes'] is List)
            ? (impact['changes'] as List)
                  .whereType<Map>()
                  .map((row) => row.cast<String, dynamic>())
                  .toList(growable: false)
            : const <Map<String, dynamic>>[];
        final changes = rawChanges.take(25).toList(growable: false);
        if (!mounted) return false;
        final approved = await showAppDialog<bool>(
          context: context,
          announcement: l10n.text('access_impact_preview'),
          builder: (context) => AlertDialog(
            title: Text(l10n.text('access_impact_preview')),
            content: SizedBox(
              width: 760,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n
                        .text('bulk_mutations_with_rebind_summary_format')
                        .replaceAll(
                          '{updated}',
                          '${result['link_updated'] ?? 0}',
                        )
                        .replaceAll(
                          '{deleted}',
                          '${result['link_deleted'] ?? 0}',
                        )
                        .replaceAll(
                          '{roleRebound}',
                          '${result['role_rebound'] ?? 0}',
                        ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    l10n
                        .text('role_impact_membership_changes_format')
                        .replaceAll(
                          '{membershipChanges}',
                          '${impact['changed_membership_count'] ?? 0}',
                        )
                        .replaceAll(
                          '{userCount}',
                          '${impact['affected_user_count'] ?? 0}',
                        )
                        .replaceAll(
                          '{spaceCount}',
                          '${impact['affected_space_count'] ?? 0}',
                        ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (changes.isEmpty)
                    Text(l10n.text('no_effective_access_changes_detected'))
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: changes.length,
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
                              rawSpaceName.isNotEmpty && rawSpaceName != spaceId
                              ? rawSpaceName
                              : _resolvedRefLabel(
                                  kind: _ItemKind.space,
                                  id: spaceId,
                                  data: data,
                                  l10n: l10n,
                                );
                          final beforeRole =
                              (row['before_role'] ?? l10n.text('none'))
                                  .toString();
                          final afterRole =
                              (row['after_role'] ?? l10n.text('none'))
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
                  if ((impact['truncated'] ?? false) == true)
                    Padding(
                      padding: EdgeInsets.only(top: AppSpacing.xs),
                      child: Text(
                        l10n.text('preview_truncated_first_25_changes'),
                      ),
                    ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.text('apply')),
              ),
            ],
          ),
        );
        return approved == true;
      } on DioException catch (error) {
        if (!mounted) return false;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
        return false;
      } catch (error) {
        if (!mounted) return false;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(error.toString())));
        return false;
      }
    }

    final payloads = <Map<String, dynamic>>[];
    for (final child in children) {
      if (child.key == parent.key) continue;
      if (!_isSupportedLinkPair(parent.kind, child.kind)) continue;
      final parentKind = _itemKindApiName(parent.kind);
      final childKind = _itemKindApiName(child.kind);
      final exists = data.itemLinks.any(
        (link) => _isItemLinkRow(
          link,
          parentKind: parentKind,
          parentId: parent.id,
          childKind: childKind,
          childId: child.id,
        ),
      );
      if (exists) continue;
      final isRoleBinding =
          parent.kind == _ItemKind.role && child.kind == _ItemKind.user;
      payloads.add({
        'parent_kind': parentKind,
        'parent_id': parent.id,
        'child_kind': childKind,
        'child_id': child.id,
        'grant_role': isRoleBinding ? parent.id : 'member',
        'inherit_to_descendants': !isRoleBinding,
        'active': true,
      });
    }
    if (payloads.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(l10n.text('no_bulk_linkable_items'))),
        );
      }
      return;
    }
    final plan = <String, dynamic>{
      'link': payloads,
      'unlink': const <Map<String, dynamic>>[],
      'rebind_roles': const <Map<String, dynamic>>[],
      'dry_run': false,
    };
    final approved = await confirmBulkMutation(plan);
    if (!approved) return;
    await _call(
      (api) => api.dio.post('/admin/org/item-links/bulk/mutate', data: plan),
      successMessage: l10n.text('save_changes'),
    );
  }

  Future<void> _bulkUnlinkItemsFromParent({
    required _ItemRef parent,
    required List<_ItemRef> children,
    required _TreeData data,
  }) async {
    final l10n = AppLocalizations.of(context);
    final unlinkPairs = <Map<String, dynamic>>[];
    final seenPairs = <String>{};
    for (final child in children) {
      if (!_isSupportedLinkPair(parent.kind, child.kind)) continue;
      final parentKind = _itemKindApiName(parent.kind);
      final childKind = _itemKindApiName(child.kind);
      for (final link in data.itemLinks) {
        final matches = _isItemLinkRow(
          link,
          parentKind: parentKind,
          parentId: parent.id,
          childKind: childKind,
          childId: child.id,
        );
        if (!matches) continue;
        final key = '$parentKind:${parent.id}:$childKind:${child.id}';
        if (!seenPairs.add(key)) continue;
        unlinkPairs.add({
          'parent_kind': parentKind,
          'parent_id': parent.id,
          'child_kind': childKind,
          'child_id': child.id,
        });
      }
    }
    if (unlinkPairs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(l10n.text('no_bulk_unlinkable_items'))),
        );
      }
      return;
    }
    final plan = <String, dynamic>{
      'link': const <Map<String, dynamic>>[],
      'unlink': unlinkPairs,
      'rebind_roles': const <Map<String, dynamic>>[],
      'dry_run': false,
    };
    bool approved;
    try {
      approved = await _runWithMfaRetry<bool>((api) async {
        final preview = await api.dio.post(
          '/admin/org/item-links/bulk/preview',
          data: plan,
        );
        final result = (preview.data as Map).cast<String, dynamic>();
        final impact = (result['access_impact'] is Map)
            ? (result['access_impact'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        if (!mounted) return false;
        final confirmed = await showAppDialog<bool>(
          context: context,
          announcement: l10n.text('access_impact_preview'),
          builder: (context) => AlertDialog(
            title: Text(l10n.text('access_impact_preview')),
            content: Text(
              l10n
                  .text('bulk_mutations_membership_summary_format')
                  .replaceAll('{created}', '${result['link_created'] ?? 0}')
                  .replaceAll('{updated}', '${result['link_updated'] ?? 0}')
                  .replaceAll('{deleted}', '${result['link_deleted'] ?? 0}')
                  .replaceAll(
                    '{membershipChanges}',
                    '${impact['changed_membership_count'] ?? 0}',
                  ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.text('apply')),
              ),
            ],
          ),
        );
        return confirmed == true;
      });
    } on DioException catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
      }
      return;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }
    if (!approved) return;
    await _call(
      (api) => api.dio.post('/admin/org/item-links/bulk/mutate', data: plan),
      successMessage: l10n.text('save_changes'),
    );
  }

  Future<void> _bulkRebindUserRoles({
    required List<_ItemRef> refs,
    required String roleKey,
  }) async {
    final l10n = AppLocalizations.of(context);
    final userIds = refs
        .where((ref) => ref.kind == _ItemKind.user)
        .map((ref) => ref.id)
        .toSet();
    if (userIds.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(l10n.text('select_users_for_role_rebind'))),
        );
      }
      return;
    }
    final normalizedRole = roleKey.trim().toLowerCase();
    final plan = <String, dynamic>{
      'link': const <Map<String, dynamic>>[],
      'unlink': const <Map<String, dynamic>>[],
      'rebind_roles': [
        {'role_key': normalizedRole, 'user_ids': userIds.toList()},
      ],
      'dry_run': false,
    };
    bool approved;
    try {
      approved = await _runWithMfaRetry<bool>((api) async {
        final preview = await api.dio.post(
          '/admin/org/item-links/bulk/preview',
          data: plan,
        );
        final result = (preview.data as Map).cast<String, dynamic>();
        final impact = (result['access_impact'] is Map)
            ? (result['access_impact'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        if (!mounted) return false;
        final confirmed = await showAppDialog<bool>(
          context: context,
          announcement: l10n.text('access_impact_preview'),
          builder: (context) => AlertDialog(
            title: Text(l10n.text('access_impact_preview')),
            content: Text(
              l10n
                  .text('role_rebind_membership_summary_format')
                  .replaceAll('{userCount}', '${userIds.length}')
                  .replaceAll(
                    '{membershipChanges}',
                    '${impact['changed_membership_count'] ?? 0}',
                  ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.text('apply')),
              ),
            ],
          ),
        );
        return confirmed == true;
      });
    } on DioException catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
      }
      return;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }
    if (!approved) return;
    await _call(
      (api) => api.dio.post('/admin/org/item-links/bulk/mutate', data: plan),
      successMessage: l10n.text('save_changes'),
    );
  }

  _VisibleTreeRow _rootVisibleRowForRef(_ItemRef ref, _TreeData data) {
    final hasChildren = _childrenOf(ref, data).isNotEmpty;
    return _VisibleTreeRow(
      instanceKey: 'bulk:${ref.key}',
      ref: ref,
      parent: null,
      linkKind: _LinkKind.root,
      depth: 0,
      ancestorKeys: const <String>[],
      hasChildren: hasChildren,
      expanded: false,
      isManualRootShortcut: _manualRootShortcutKeys.contains(ref.key),
    );
  }

  Future<_ItemRef?> _pickGlobalItemDialog({
    required _TreeData data,
    required Set<_ItemKind> allowedKinds,
    required String announcement,
    required String title,
    _ItemRef? exclude,
  }) async {
    final l10n = AppLocalizations.of(context);
    final searchCtrl = TextEditingController();
    final searchFocusNode = FocusNode();

    List<_GlobalItemsSearchSuggestion> pickerSearchSuggestions() {
      final context = parseAtTokenSuggestionContext(searchCtrl.text);
      if (context == null) {
        return const <_GlobalItemsSearchSuggestion>[];
      }

      List<_GlobalItemsSearchSuggestion> onlyAllowedKindValueSuggestions(
        List<_GlobalItemsSearchSuggestion> suggestions,
      ) {
        final allowed = allowedKinds.map((kind) => kind.name).toSet();
        return suggestions
            .where((suggestion) {
              final lower = suggestion.tokenText.toLowerCase();
              return allowed.any((kind) => lower.contains(':$kind'));
            })
            .toList(growable: false);
      }

      List<_GlobalItemsSearchSuggestion> onlyAllowedAliasSuggestions(
        List<_GlobalItemsSearchSuggestion> suggestions,
      ) {
        return suggestions
            .where((suggestion) {
              final tokenAst = parseSearchQueryAst(suggestion.tokenText);
              final tokenField = tokenAst.fieldTokens.isEmpty
                  ? ''
                  : tokenAst.fieldTokens.first.normalizedField;
              final kind = _itemKindFromToken(tokenField);
              return kind == null || allowedKinds.contains(kind);
            })
            .toList(growable: false);
      }

      if (!context.hasValueSeparator) {
        final kindAlias = _itemKindFromToken(context.fieldLower);
        if (context.hasTrailingWhitespace && kindAlias != null) {
          if (!allowedKinds.contains(kindAlias)) {
            return const <_GlobalItemsSearchSuggestion>[];
          }
          return _globalItemsKindAliasValueSuggestions(
            fieldToken: context.fieldLower,
            kind: kindAlias,
            partialLower: '',
            data: data,
          );
        }

        final category = _normalizeGlobalItemsSearchCategory(
          context.fieldLower,
        );
        if (context.hasTrailingWhitespace && category != null) {
          final values = _globalItemsSearchValueSuggestions(
            category: category,
            partialLower: '',
            l10n: l10n,
          );
          if (category == _GlobalItemsSearchCategory.kind) {
            return onlyAllowedKindValueSuggestions(values);
          }
          return values;
        }

        final partial = context.partialFieldLower;
        final categorySuggestions = _GlobalItemsSearchCategory.values
            .where((category) {
              final token = _globalItemsSearchCategoryToken(category);
              final label = _globalItemsSearchCategoryLabel(
                category,
                l10n,
              ).toLowerCase();
              if (partial.isEmpty) return true;
              return token.contains(partial) || label.contains(partial);
            })
            .map(
              (category) => _GlobalItemsSearchSuggestion(
                label:
                    '@${_globalItemsSearchCategoryToken(category)} - ${_globalItemsSearchCategoryLabel(category, l10n)}',
                tokenText: '@${_globalItemsSearchCategoryToken(category)}:',
                appendSpace: false,
                subtitle: l10n.text('search'),
              ),
            )
            .toList(growable: false);

        final aliasSuggestions = onlyAllowedAliasSuggestions(
          _globalItemsFieldAliasSuggestions(l10n, partial),
        );

        return [...categorySuggestions, ...aliasSuggestions];
      }

      final kindAlias = _itemKindFromToken(context.fieldLower);
      if (kindAlias != null) {
        if (!allowedKinds.contains(kindAlias)) {
          return const <_GlobalItemsSearchSuggestion>[];
        }
        return _globalItemsKindAliasValueSuggestions(
          fieldToken: context.fieldLower,
          kind: kindAlias,
          partialLower: context.partialValueLower,
          data: data,
        );
      }

      final category = _normalizeGlobalItemsSearchCategory(context.fieldLower);
      if (category == null) {
        return const <_GlobalItemsSearchSuggestion>[];
      }
      final values = _globalItemsSearchValueSuggestions(
        category: category,
        partialLower: context.partialValueLower,
        l10n: l10n,
      );
      if (category == _GlobalItemsSearchCategory.kind) {
        return onlyAllowedKindValueSuggestions(values);
      }
      return values;
    }

    final selected = await showAppDialog<_ItemRef>(
      context: context,
      announcement: announcement,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final parsedQuery = _parseGlobalItemsSearchQuery(searchCtrl.text);
          final queryDiagnostics = validateSearchQueryAst(
            parseSearchQueryAst(searchCtrl.text),
            capability: globalItemsSearchCapability,
          ).diagnostics;
          final searchSuggestions = pickerSearchSuggestions();
          final filtered =
              _allGlobalItemRefs(data).where((ref) {
                if (!allowedKinds.contains(ref.kind)) return false;
                if (exclude != null &&
                    ref.kind == exclude.kind &&
                    ref.id == exclude.id) {
                  return false;
                }
                return _globalItemMatchesParsedQuery(ref, data, parsedQuery);
              }).toList()..sort((a, b) {
                final al = _itemLabel(a, data).toLowerCase();
                final bl = _itemLabel(b, data).toLowerCase();
                if (al == bl) return a.kind.name.compareTo(b.kind.name);
                return al.compareTo(bl);
              });

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 920,
              height: 560,
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: searchCtrl,
                          focusNode: searchFocusNode,
                          onChanged: (_) => setDialogState(() {}),
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: l10n.text('search_global_items'),
                            hintText: structuredSearchHint(
                              l10n: l10n,
                              capability: globalItemsSearchCapability,
                              baseHint: l10n.text(
                                'search_hint_global_items_tokens',
                              ),
                            ),
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: searchCtrl.text.trim().isEmpty
                                ? null
                                : IconButton(
                                    tooltip: l10n.text('clear_search'),
                                    onPressed: () => setDialogState(() {
                                      searchCtrl.clear();
                                      searchFocusNode.requestFocus();
                                    }),
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      SearchHowToButton(
                        capability: globalItemsSearchCapability,
                      ),
                    ],
                  ),
                  if (parsedQuery.structuredTokens.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: <Widget>[
                        for (final token in parsedQuery.structuredTokens)
                          InputChip(
                            label: Text(token.toChipLabel()),
                            onDeleted: () => setDialogState(() {
                              final nextText = removeSearchRangeFromQuery(
                                searchCtrl.text,
                                start: token.start,
                                end: token.end,
                              );
                              searchCtrl.value = TextEditingValue(
                                text: nextText,
                                selection: TextSelection.collapsed(
                                  offset: nextText.length,
                                ),
                              );
                              searchFocusNode.requestFocus();
                            }),
                          ),
                      ],
                    ),
                  ],
                  if (searchSuggestions.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
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
                              onTap: () => setDialogState(() {
                                final nextText = applyAtTokenSuggestion(
                                  raw: searchCtrl.text,
                                  suggestionToken: suggestion.tokenText,
                                  appendSpace: suggestion.appendSpace,
                                );
                                searchCtrl.value = TextEditingValue(
                                  text: nextText,
                                  selection: TextSelection.collapsed(
                                    offset: nextText.length,
                                  ),
                                );
                                searchFocusNode.requestFocus();
                              }),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                  if (queryDiagnostics.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    SearchDiagnosticsList(diagnostics: queryDiagnostics),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(child: Text(l10n.text('no_matching_items')))
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final ref = filtered[index];
                              return ListTile(
                                dense: true,
                                leading: Icon(_itemIcon(ref)),
                                title: Text(_itemLabel(ref, data)),
                                subtitle: Text(_itemSubtitle(ref, data)),
                                onTap: () => Navigator.pop(context, ref),
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
                child: Text(l10n.text('cancel')),
              ),
            ],
          );
        },
      ),
    );

    searchFocusNode.dispose();
    searchCtrl.dispose();
    return selected;
  }

  Future<void> _openAddChildDialog(_VisibleTreeRow row, _TreeData data) async {
    final l10n = AppLocalizations.of(context);

    if (row.ref.kind == _ItemKind.role) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(l10n.text('roles_do_not_support_child_items')),
          ),
        );
      }
      return;
    }

    if (row.ref.kind == _ItemKind.space) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              l10n.text('spaces_inherit_membership_from_departments'),
            ),
          ),
        );
      }
      return;
    }

    if (row.ref.kind == _ItemKind.user) {
      final selected = await _pickGlobalItemDialog(
        data: data,
        allowedKinds: <_ItemKind>{_ItemKind.user},
        announcement: l10n.text('add_child_to_user'),
        title: l10n.text('add_child_item'),
        exclude: row.ref,
      );
      if (selected == null) return;

      await _ensureItemLink(
        parentKind: 'user',
        parentId: row.ref.id,
        childKind: 'user',
        childId: selected.id,
        links: data.itemLinks,
        grantRole: 'member',
        inheritToDescendants: true,
      );
      return;
    }

    final selected = await _pickGlobalItemDialog(
      data: data,
      allowedKinds: <_ItemKind>{
        _ItemKind.department,
        _ItemKind.space,
        _ItemKind.user,
      },
      announcement: l10n.text('add_child_to_department'),
      title: l10n.text('add_child_item'),
      exclude: row.ref,
    );
    if (selected == null) return;

    if (selected.kind == _ItemKind.department) {
      await _ensureItemLink(
        parentKind: 'department',
        parentId: row.ref.id,
        childKind: 'department',
        childId: selected.id,
        links: data.itemLinks,
        grantRole: 'member',
        inheritToDescendants: true,
      );
      return;
    }
    if (selected.kind == _ItemKind.space) {
      await _ensureSpaceUnitLink(
        spaceId: selected.id,
        unitId: row.ref.id,
        links: data.itemLinks,
      );
      return;
    }
    if (selected.kind == _ItemKind.user) {
      await _assignUserToUnit(
        userId: selected.id,
        unitId: row.ref.id,
        links: data.itemLinks,
      );
    }
  }

  Future<void> _replaceItemDialog(_VisibleTreeRow row, _TreeData data) async {
    final l10n = AppLocalizations.of(context);

    if (row.ref.kind == _ItemKind.user) {
      final options = data.users
          .where((u) => (u['id'] ?? '').toString() != row.ref.id)
          .toList();
      if (options.isEmpty) return;
      options.sort((a, b) {
        final an = (a['name'] ?? a['email'] ?? '').toString().toLowerCase();
        final bn = (b['name'] ?? b['email'] ?? '').toString().toLowerCase();
        return an.compareTo(bn);
      });
      String replacementId = (options.first['id'] ?? '').toString();

      final approved = await showAppDialog<bool>(
        context: context,
        announcement: l10n.text('replace_user'),
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l10n.text('replace_item')),
            content: SizedBox(
              width: 620,
              child: DropdownButtonFormField<String>(
                initialValue: replacementId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.text('replace_with_user'),
                ),
                items: [
                  for (final user in options)
                    DropdownMenuItem<String>(
                      value: (user['id'] ?? '').toString(),
                      child: Text(
                        (user['name'] ?? user['email'] ?? '').toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setDialogState(() {
                  replacementId = value ?? replacementId;
                }),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.text('save')),
              ),
            ],
          ),
        ),
      );

      if (approved == true) {
        final reports = data.reportsByManager[row.ref.id] ?? const <String>{};
        for (final reportId in reports) {
          await _replaceUserManager(
            reportUserId: reportId,
            fromManagerUserId: row.ref.id,
            toManagerUserId: replacementId,
            links: data.itemLinks,
          );
        }
      }
      return;
    }

    if (row.ref.kind == _ItemKind.department) {
      final options = data.units
          .where((u) => (u['id'] ?? '').toString() != row.ref.id)
          .toList();
      if (options.isEmpty) return;
      options.sort((a, b) {
        final an = (a['name'] ?? '').toString().toLowerCase();
        final bn = (b['name'] ?? '').toString().toLowerCase();
        return an.compareTo(bn);
      });
      String replacementId = (options.first['id'] ?? '').toString();

      final approved = await showAppDialog<bool>(
        context: context,
        announcement: l10n.text('replace_department'),
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l10n.text('replace_item')),
            content: SizedBox(
              width: 620,
              child: DropdownButtonFormField<String>(
                initialValue: replacementId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.text('replace_with_department'),
                ),
                items: [
                  for (final unit in options)
                    DropdownMenuItem<String>(
                      value: (unit['id'] ?? '').toString(),
                      child: Text((unit['name'] ?? '').toString()),
                    ),
                ],
                onChanged: (value) => setDialogState(() {
                  replacementId = value ?? replacementId;
                }),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.text('save')),
              ),
            ],
          ),
        ),
      );

      if (approved == true) {
        for (final childId
            in data.childUnitsByParent[row.ref.id] ?? const <String>{}) {
          await _ensureItemLink(
            parentKind: 'department',
            parentId: replacementId,
            childKind: 'department',
            childId: childId,
            links: data.itemLinks,
            grantRole: 'member',
            inheritToDescendants: true,
          );
          await _unlinkItemLink(
            parentKind: 'department',
            parentId: row.ref.id,
            childKind: 'department',
            childId: childId,
            links: data.itemLinks,
          );
        }
        for (final spaceId
            in data.spacesByUnit[row.ref.id] ?? const <String>{}) {
          await _ensureSpaceUnitLink(
            spaceId: spaceId,
            unitId: replacementId,
            links: data.itemLinks,
          );
          await _unlinkSpaceFromUnit(
            spaceId: spaceId,
            unitId: row.ref.id,
            links: data.itemLinks,
          );
        }
        for (final userId in data.usersByUnit[row.ref.id] ?? const <String>{}) {
          await _replaceUserUnit(
            userId: userId,
            fromUnitId: row.ref.id,
            toUnitId: replacementId,
            links: data.itemLinks,
          );
        }
      }
      return;
    }

    if (row.ref.kind == _ItemKind.space) {
      final options = data.spaces
          .where((s) => (s['id'] ?? '').toString() != row.ref.id)
          .toList();
      if (options.isEmpty) return;
      options.sort((a, b) {
        final an = (a['name'] ?? '').toString().toLowerCase();
        final bn = (b['name'] ?? '').toString().toLowerCase();
        return an.compareTo(bn);
      });
      String replacementId = (options.first['id'] ?? '').toString();

      final approved = await showAppDialog<bool>(
        context: context,
        announcement: l10n.text('replace_space'),
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l10n.text('replace_item')),
            content: SizedBox(
              width: 620,
              child: DropdownButtonFormField<String>(
                initialValue: replacementId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.text('replace_with_space'),
                ),
                items: [
                  for (final space in options)
                    DropdownMenuItem<String>(
                      value: (space['id'] ?? '').toString(),
                      child: Text((space['name'] ?? '').toString()),
                    ),
                ],
                onChanged: (value) => setDialogState(() {
                  replacementId = value ?? replacementId;
                }),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.text('save')),
              ),
            ],
          ),
        ),
      );

      if (approved == true) {
        for (final unitId
            in data.unitsBySpace[row.ref.id] ?? const <String>{}) {
          await _ensureSpaceUnitLink(
            spaceId: replacementId,
            unitId: unitId,
            links: data.itemLinks,
          );
          await _unlinkSpaceFromUnit(
            spaceId: row.ref.id,
            unitId: unitId,
            links: data.itemLinks,
          );
        }
      }
      return;
    }

    final keys = data.roleByKey.keys.where((k) => k != row.ref.id).toList()
      ..sort();
    if (keys.isEmpty) return;
    String replacementRole = keys.first;
    final approved = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('replace_role'),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.text('replace_item')),
          content: SizedBox(
            width: 620,
            child: DropdownButtonFormField<String>(
              initialValue: replacementRole,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.text('replace_with_role'),
              ),
              items: [
                for (final roleKey in keys)
                  DropdownMenuItem<String>(
                    value: roleKey,
                    child: Text(
                      (data.roleByKey[roleKey]?['name'] ?? roleKey).toString(),
                    ),
                  ),
              ],
              onChanged: (value) => setDialogState(() {
                replacementRole = value ?? replacementRole;
              }),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.text('save')),
            ),
          ],
        ),
      ),
    );

    if (approved == true) {
      for (final user in data.users) {
        final userId = (user['id'] ?? '').toString();
        if (userId.isEmpty) continue;
        final currentRole = _resolvedRoleKeyForUser(user, data);
        if (currentRole != row.ref.id) continue;
        await _setUserRoleBinding(
          userId: userId,
          roleKey: replacementRole,
          links: data.itemLinks,
          users: data.users,
        );
      }
    }
  }

  Future<void> _detachFromParent(_VisibleTreeRow row, _TreeData data) async {
    if (row.parent == null) return;
    switch (row.linkKind) {
      case _LinkKind.departmentToDepartment:
        await _unlinkItemLink(
          parentKind: 'department',
          parentId: row.parent!.id,
          childKind: 'department',
          childId: row.ref.id,
          links: data.itemLinks,
        );
        return;
      case _LinkKind.departmentToSpace:
        await _unlinkSpaceFromUnit(
          spaceId: row.ref.id,
          unitId: row.parent!.id,
          links: data.itemLinks,
        );
        return;
      case _LinkKind.departmentToUser:
        await _removeUserFromUnit(
          userId: row.ref.id,
          unitId: row.parent!.id,
          links: data.itemLinks,
        );
        return;
      case _LinkKind.spaceToUser:
        return;
      case _LinkKind.userToUser:
        await _unlinkItemLink(
          parentKind: 'user',
          parentId: row.parent!.id,
          childKind: 'user',
          childId: row.ref.id,
          links: data.itemLinks,
        );
        return;
      case _LinkKind.root:
        return;
    }
  }

  Future<void> _removeItemFromCurrentLocation(
    _VisibleTreeRow row,
    _TreeData data,
  ) async {
    if (row.parent != null) {
      await _detachFromParent(row, data);
      return;
    }
    if (row.isManualRootShortcut) {
      _setRelationshipState(() {
        _manualRootShortcutKeys.remove(row.ref.key);
      });
      await _persistManualRootShortcuts();
    }
  }

  Future<void> _openEditorForRef(_ItemRef ref, _TreeData data) async {
    if (ref.kind == _ItemKind.department) {
      await _openUnitEditor(existing: data.unitById[ref.id], data: data);
    } else if (ref.kind == _ItemKind.space) {
      await _openSpaceEditor(existing: data.spaceById[ref.id], data: data);
    } else if (ref.kind == _ItemKind.user) {
      await _openUserEditor(existing: data.userById[ref.id], data: data);
    } else {
      await _openRoleEditor(existing: data.roleByKey[ref.id]);
    }
  }

  Map<String, dynamic> _metaForItem(_ItemRef ref, _TreeData data) {
    final raw = switch (ref.kind) {
      _ItemKind.department => data.unitById[ref.id]?['meta'],
      _ItemKind.space => data.spaceById[ref.id]?['meta'],
      _ItemKind.user => data.userById[ref.id]?['meta'],
      _ItemKind.role => data.roleByKey[ref.id]?['meta'],
    };
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return const <String, dynamic>{};
  }

  String _metaDraftValueLabel(AppLocalizations l10n, _MetaDraft draft) {
    final text = draft.textValue.trim();
    return switch (draft.type) {
      _MetaValueType.boolean =>
        draft.boolValue
            ? l10n.text('meta_value_true')
            : l10n.text('meta_value_false'),
      _MetaValueType.number => text.isEmpty ? '-' : text,
      _MetaValueType.file => text.isEmpty ? l10n.text('not_selected') : text,
      _MetaValueType.text => text.isEmpty ? '-' : text,
    };
  }

  IconData _metaTypeIcon(_MetaValueType type) {
    return switch (type) {
      _MetaValueType.text => Icons.notes_outlined,
      _MetaValueType.number => Icons.pin_outlined,
      _MetaValueType.boolean => Icons.toggle_on_outlined,
      _MetaValueType.file => Icons.description_outlined,
    };
  }

  List<_ItemRef> _sortItemRefs(Iterable<_ItemRef> refs, _TreeData data) {
    final deduped = <String, _ItemRef>{
      for (final ref in refs)
        if (_itemExistsInData(ref, data)) ref.key: ref,
    }.values.toList();
    deduped.sort((a, b) {
      final rankDiff = _itemSortRank(a, data).compareTo(_itemSortRank(b, data));
      if (rankDiff != 0) return rankDiff;
      final al = _itemLabel(a, data).toLowerCase();
      final bl = _itemLabel(b, data).toLowerCase();
      if (al != bl) return al.compareTo(bl);
      final kindDiff = a.kind.name.compareTo(b.kind.name);
      if (kindDiff != 0) return kindDiff;
      return a.id.compareTo(b.id);
    });
    return deduped;
  }

  int _itemSortRank(_ItemRef ref, _TreeData data) {
    switch (ref.kind) {
      case _ItemKind.department:
        final unitType = (data.unitById[ref.id]?['unit_type'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        return unitType == 'region' ? 0 : 1;
      case _ItemKind.space:
        return 2;
      case _ItemKind.user:
        return 3;
      case _ItemKind.role:
        return 4;
    }
  }

  List<_ItemRef> _parentRefsFor(_ItemRef ref, _TreeData data) {
    final refs = <_ItemRef>[];
    switch (ref.kind) {
      case _ItemKind.department:
        for (final parentId
            in data.parentUnitsByChildUnit[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.department, id: parentId));
        }
      case _ItemKind.space:
        for (final unitId in data.unitsBySpace[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.department, id: unitId));
        }
      case _ItemKind.user:
        for (final managerId
            in data.managerIdsByReport[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.user, id: managerId));
        }
        for (final unitId in data.orgUnitsByUser[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.department, id: unitId));
        }
      case _ItemKind.role:
        break;
    }
    return _sortItemRefs(refs, data);
  }

  List<_ItemRef> _childRefsFor(_ItemRef ref, _TreeData data) {
    final refs = <_ItemRef>[];
    switch (ref.kind) {
      case _ItemKind.department:
        for (final childId
            in data.childUnitsByParent[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.department, id: childId));
        }
        for (final spaceId in data.spacesByUnit[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.space, id: spaceId));
        }
        for (final userId in data.usersByUnit[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.user, id: userId));
        }
      case _ItemKind.space:
        break;
      case _ItemKind.user:
        for (final reportId
            in data.reportsByManager[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.user, id: reportId));
        }
      case _ItemKind.role:
        break;
    }
    return _sortItemRefs(refs, data);
  }

  List<_ItemRef> _linkedSpaceRefsFor(_ItemRef ref, _TreeData data) {
    final refs = <_ItemRef>[];
    switch (ref.kind) {
      case _ItemKind.department:
        for (final spaceId in data.spacesByUnit[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.space, id: spaceId));
        }
      case _ItemKind.space:
        refs.add(ref);
      case _ItemKind.user:
        for (final spaceId in data.spacesByUser[ref.id] ?? const <String>{}) {
          refs.add(_ItemRef(kind: _ItemKind.space, id: spaceId));
        }
      case _ItemKind.role:
        for (final link in data.itemLinks) {
          if (link['active'] == false) continue;
          final grantRole = (link['grant_role'] ?? '').toString().trim();
          if (grantRole != ref.id) continue;
          final childKind = (link['child_kind'] ?? '').toString().trim();
          if (childKind != 'space') continue;
          final childId = (link['child_id'] ?? '').toString().trim();
          if (childId.isEmpty) continue;
          refs.add(_ItemRef(kind: _ItemKind.space, id: childId));
        }
    }
    return _sortItemRefs(refs, data);
  }

  String _resolvedRoleLabelForUser(
    Map<String, dynamic> user,
    _TreeData data,
    AppLocalizations l10n,
  ) {
    final roleKey = _resolvedRoleKeyForUser(user, data);
    final role = data.roleByKey[roleKey];
    if (role != null) {
      if (_TreeData.builtInRoleKeys.contains(roleKey)) {
        return switch (roleKey) {
          'admin' => l10n.text('admin'),
          'moderator' => l10n.text('moderator'),
          'viewer' => l10n.text('viewer'),
          _ => l10n.text('member'),
        };
      }
      final level = (role['effective_level'] ?? 'member').toString().trim();
      return '${(role['name'] ?? roleKey).toString()} (${level.toUpperCase()})';
    }
    return roleKey;
  }

  String _resolvedRoleSourceForUser(
    Map<String, dynamic> user,
    _TreeData data,
    AppLocalizations l10n,
  ) {
    final userId = (user['id'] ?? '').toString().trim();
    if (userId.isNotEmpty) {
      final linkedRole = _linkedRoleKeyForUser(userId, data);
      if (linkedRole != null) {
        return l10n.text('role_source_link_binding');
      }
    }
    return l10n.text('role_source_global');
  }

  String _resolvedRefLabel({
    required _ItemKind kind,
    required String id,
    required _TreeData data,
    required AppLocalizations l10n,
  }) {
    final normalized = id.trim();
    if (normalized.isEmpty) {
      return l10n.text('unknown');
    }
    final label = _itemLabel(_ItemRef(kind: kind, id: normalized), data).trim();
    if (label.isEmpty || label == normalized) {
      return l10n.text('unknown');
    }
    return label;
  }
}
