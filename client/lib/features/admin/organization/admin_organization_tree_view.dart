// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Tree rendering and interaction helpers for the organization management screen.

part of 'admin_organization_screen.dart';

extension _AdminOrganizationScreenStateTreeView
    on _AdminOrganizationScreenState {
  void _removeTreeStructuredSearchTokenFromUi(SearchFieldToken token) {
    (this as dynamic).setState(() {
      _removeTreeStructuredSearchToken(token);
    });
  }

  Future<void> _openItemViewDialog(
    _ItemRef ref,
    _TreeData data, {
    required bool canEdit,
  }) async {
    final l10n = AppLocalizations.of(context);
    final meta = _metaForItem(ref, data);
    final metaDrafts = _metaDraftsFromValue(meta);
    metaDrafts.sort(
      (a, b) =>
          a.name.trim().toLowerCase().compareTo(b.name.trim().toLowerCase()),
    );
    final documentDrafts = metaDrafts
        .where((item) => item.type == _MetaValueType.file)
        .toList();
    final fieldDrafts = metaDrafts
        .where((item) => item.type != _MetaValueType.file)
        .toList();
    final parentRefs = _parentRefsFor(ref, data);
    final childRefs = _childRefsFor(ref, data);
    final linkedSpaceRefs = _linkedSpaceRefsFor(ref, data);
    final userRefData = ref.kind == _ItemKind.user
        ? data.userById[ref.id]
        : null;
    final roleLinkBindingCount = ref.kind == _ItemKind.role
        ? data.itemLinks.where((link) {
            if (link['active'] == false) return false;
            final grantRole = (link['grant_role'] ?? '').toString().trim();
            return grantRole == ref.id;
          }).length
        : 0;
    final auditFuture = _auditEventsFutureForRef(ref);
    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('view_item'),
      builder: (context) => AlertDialog(
        title: Row(
          children: <Widget>[
            Icon(_itemIcon(ref), size: 20),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                '${l10n.text('view_item')} • ${_itemLabel(ref, data)}',
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 860,
          height: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Row(
                    children: <Widget>[
                      Icon(_itemIcon(ref), size: 18),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          _itemSubtitle(ref, data),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                l10n.text('relationship_inspector'),
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Wrap(
                                spacing: AppSpacing.sm,
                                runSpacing: AppSpacing.sm,
                                children: <Widget>[
                                  _RelationshipGroup(
                                    title: l10n.text('parents_label'),
                                    refs: parentRefs,
                                    data: data,
                                    iconForRef: _itemIcon,
                                    labelForRef: _itemLabel,
                                    emptyText: l10n.text('no_data'),
                                  ),
                                  _RelationshipGroup(
                                    title: l10n.text('children_label'),
                                    refs: childRefs,
                                    data: data,
                                    iconForRef: _itemIcon,
                                    labelForRef: _itemLabel,
                                    emptyText: l10n.text('no_data'),
                                  ),
                                  _RelationshipGroup(
                                    title: l10n.text('linked_spaces_label'),
                                    refs: linkedSpaceRefs,
                                    data: data,
                                    iconForRef: _itemIcon,
                                    labelForRef: _itemLabel,
                                    emptyText: l10n.text('no_data'),
                                  ),
                                ],
                              ),
                              if (userRefData != null) ...<Widget>[
                                const SizedBox(height: AppSpacing.sm),
                                Text(
                                  l10n.text('effective_access_debugger'),
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Wrap(
                                  spacing: AppSpacing.sm,
                                  runSpacing: AppSpacing.xs,
                                  children: <Widget>[
                                    Chip(
                                      label: Text(
                                        '${l10n.text('resolved_role_label')}: ${_resolvedRoleLabelForUser(userRefData, data, l10n)}',
                                      ),
                                    ),
                                    Chip(
                                      label: Text(
                                        '${l10n.text('role_source_label')}: ${_resolvedRoleSourceForUser(userRefData, data, l10n)}',
                                      ),
                                    ),
                                    Chip(
                                      label: Text(
                                        '${l10n.text('space_visibility_label')}: ${linkedSpaceRefs.length}',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (ref.kind == _ItemKind.role) ...<Widget>[
                                const SizedBox(height: AppSpacing.sm),
                                Chip(
                                  label: Text(
                                    '${l10n.text('link_bindings_label')}: $roleLinkBindingCount',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        l10n.text('audit_timeline'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      FutureBuilder<List<Map<String, dynamic>>>(
                        future: auditFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: AppSpacing.sm,
                              ),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          }
                          if (snapshot.hasError) {
                            return Text(
                              snapshot.error.toString(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            );
                          }
                          final events =
                              snapshot.data ?? const <Map<String, dynamic>>[];
                          if (events.isEmpty) {
                            return Text(
                              l10n.text('no_audit_events'),
                              style: Theme.of(context).textTheme.bodySmall,
                            );
                          }
                          return Column(
                            children: <Widget>[
                              for (final event in events.take(25)) ...<Widget>[
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                      AppSpacing.sm,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          _auditEventSummary(event, l10n),
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(height: AppSpacing.xxs),
                                        Text(
                                          '${_auditActionLabel((event['action'] ?? '').toString(), l10n)} • ${_auditWhenLabel(event, l10n)}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                        ),
                                        if (_trimmedOrNull(
                                              event['actor_name'],
                                            ) !=
                                            null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: AppSpacing.xxs,
                                            ),
                                            child: Text(
                                              '${l10n.text('owner_prefix')}: ${_trimmedOrNull(event['actor_name'])}',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ),
                                        if (_auditChangesPreview(event) !=
                                            null) ...<Widget>[
                                          const SizedBox(height: AppSpacing.xs),
                                          SelectableText(
                                            _auditChangesPreview(event)!,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontFamily: 'monospace',
                                                ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.xs),
                              ],
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        l10n.text('meta_documents'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      if (documentDrafts.isEmpty)
                        Text(
                          l10n.text('no_documents_available'),
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      else
                        Column(
                          children: <Widget>[
                            for (final draft in documentDrafts) ...[
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(AppSpacing.sm),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Row(
                                        children: <Widget>[
                                          const Icon(
                                            Icons.description_outlined,
                                            size: 18,
                                          ),
                                          const SizedBox(width: AppSpacing.xs),
                                          Expanded(
                                            child: Text(
                                              draft.name.trim().isEmpty
                                                  ? l10n.text('meta_document')
                                                  : draft.name.trim(),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelLarge
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: AppSpacing.xs),
                                      SelectableText(
                                        _metaDraftValueLabel(l10n, draft),
                                        maxLines: 2,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                      const SizedBox(height: AppSpacing.xs),
                                      Wrap(
                                        spacing: AppSpacing.xs,
                                        runSpacing: AppSpacing.xs,
                                        children: <Widget>[
                                          OutlinedButton.icon(
                                            onPressed:
                                                draft.textValue.trim().isEmpty
                                                ? null
                                                : () async {
                                                    await showMediaPreviewDialog(
                                                      context: context,
                                                      filename:
                                                          draft.name
                                                              .trim()
                                                              .isEmpty
                                                          ? l10n.text(
                                                              'meta_document',
                                                            )
                                                          : draft.name.trim(),
                                                      url: draft.textValue
                                                          .trim(),
                                                    );
                                                  },
                                            icon: const Icon(
                                              Icons.visibility_outlined,
                                            ),
                                            label: Text(l10n.text('view_file')),
                                          ),
                                          TextButton.icon(
                                            onPressed:
                                                draft.textValue.trim().isEmpty
                                                ? null
                                                : () async {
                                                    await Clipboard.setData(
                                                      ClipboardData(
                                                        text: draft.textValue
                                                            .trim(),
                                                      ),
                                                    );
                                                    if (!context.mounted) {
                                                      return;
                                                    }
                                                    ScaffoldMessenger.maybeOf(
                                                      context,
                                                    )?.showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          l10n.text(
                                                            'link_copied',
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  },
                                            icon: const Icon(
                                              Icons.copy_outlined,
                                            ),
                                            label: Text(l10n.text('copy_link')),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                            ],
                          ],
                        ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        l10n.text('meta_fields'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      if (fieldDrafts.isEmpty)
                        Text(
                          l10n.text('no_fields_available'),
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      else
                        Column(
                          children: <Widget>[
                            for (final draft in fieldDrafts) ...[
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(AppSpacing.sm),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      SizedBox(
                                        width: 250,
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Icon(
                                              _metaTypeIcon(draft.type),
                                              size: 18,
                                            ),
                                            const SizedBox(
                                              width: AppSpacing.xs,
                                            ),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: <Widget>[
                                                  Text(
                                                    draft.name.trim().isEmpty
                                                        ? l10n.text('metadata')
                                                        : draft.name.trim(),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .labelLarge
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                  const SizedBox(
                                                    height: AppSpacing.xxs,
                                                  ),
                                                  Text(
                                                    _metaTypeLabel(
                                                      l10n,
                                                      draft.type,
                                                    ),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .onSurfaceVariant,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.sm),
                                      Expanded(
                                        child: SelectableText(
                                          _metaDraftValueLabel(l10n, draft),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                            ],
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          if (canEdit)
            FilledButton.tonal(
              onPressed: () async {
                Navigator.pop(context);
                await _AdminOrganizationScreenStateTools(
                  this,
                )._openItemTranslationReviewDialog(ref, data);
              },
              child: Text(l10n.text('translation_review')),
            ),
          if (canEdit)
            FilledButton.tonal(
              onPressed: () async {
                Navigator.pop(context);
                await _openEditorForRef(ref, data);
              },
              child: Text(l10n.text('edit_item')),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.text('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _handleRowAction(
    _VisibleTreeRow row,
    String action,
    _TreeData data,
  ) async {
    final user = row.ref.kind == _ItemKind.user
        ? data.userById[row.ref.id] ?? const <String, dynamic>{}
        : const <String, dynamic>{};
    final userId = (user['id'] ?? '').toString().trim();
    if (action == 'view') {
      await _openItemViewDialog(row.ref, data, canEdit: true);
      return;
    }
    if (action == 'edit') {
      await _openEditorForRef(row.ref, data);
      return;
    }
    if (action == 'translation_review') {
      await _AdminOrganizationScreenStateTools(
        this,
      )._openItemTranslationReviewDialog(row.ref, data);
      return;
    }
    if (action == 'invite_user') {
      if (userId.isEmpty) return;
      await _issueUserOnboardingToken(
        userId: userId,
        endpoint: 'invite',
        titleKey: 'invite_user',
        successKey: 'invite_issued',
      );
      return;
    }
    if (action == 'reset_user_password') {
      if (userId.isEmpty) return;
      await _issueUserOnboardingToken(
        userId: userId,
        endpoint: 'password-reset',
        titleKey: 'reset_password',
        successKey: 'password_reset_issued',
      );
      return;
    }
    if (action == 'activate_user') {
      if (userId.isEmpty) return;
      await _setUserActiveState(userId: userId, active: true);
      return;
    }
    if (action == 'deactivate_user') {
      if (userId.isEmpty) return;
      await _setUserActiveState(userId: userId, active: false);
      return;
    }
    if (action == 'add_child') {
      await _openAddChildDialog(row, data);
      return;
    }
    if (action == 'replace') {
      await _replaceItemDialog(row, data);
      return;
    }
    if (action == 'remove_item') {
      await _removeItemFromCurrentLocation(row, data);
      return;
    }
    if (action == 'delete') {
      if (row.ref.kind == _ItemKind.department) {
        await _deleteUnit(
          data.unitById[row.ref.id] ?? const <String, dynamic>{},
        );
      } else if (row.ref.kind == _ItemKind.space) {
        await _deleteSpace(
          data.spaceById[row.ref.id] ?? const <String, dynamic>{},
        );
      } else if (row.ref.kind == _ItemKind.role) {
        await _deleteRole(
          data.roleByKey[row.ref.id] ?? const <String, dynamic>{},
        );
      }
    }
  }

  Widget _buildTreeRow(_VisibleTreeRow row, _TreeData data, bool canEdit) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final selected = _selectedItemKey == row.ref.key;
    final builtInRole =
        row.ref.kind == _ItemKind.role &&
        data.roleByKey[row.ref.id]?['built_in'] == true;
    final canDelete = _canDeleteRef(row.ref, data);

    final rowContent = Material(
      color: Colors.transparent,
      child: InkWell(
        splashFactory: NoSplash.splashFactory,
        highlightColor: cs.primary.withValues(alpha: 0.08),
        hoverColor: cs.primary.withValues(alpha: 0.05),
        onTap: () => _toggleRowExpansion(row),
        child: Container(
          height: 60,
          color: selected
              ? cs.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          padding: EdgeInsets.only(
            left: AppSpacing.sm + (row.depth * 18),
            right: AppSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 28,
                child: row.hasChildren
                    ? Center(
                        child: IconButton(
                          constraints: const BoxConstraints.tightFor(
                            width: 24,
                            height: 24,
                          ),
                          padding: EdgeInsets.zero,
                          splashRadius: 14,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _toggleRowExpansion(row),
                          icon: Icon(
                            row.expanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            size: 18,
                          ),
                          tooltip: row.expanded
                              ? l10n.text('collapse')
                              : l10n.text('expand'),
                        ),
                      )
                    : null,
              ),
              Icon(_itemIcon(row.ref), size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _itemLabel(row.ref, data),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _itemSubtitle(row.ref, data),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                enabled: canEdit,
                tooltip: l10n.text('more'),
                onSelected: (value) => _handleRowAction(row, value, data),
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'view',
                    child: Text(l10n.text('view_item')),
                  ),
                  PopupMenuItem<String>(
                    value: 'edit',
                    child: Text(l10n.text('edit_item')),
                  ),
                  PopupMenuItem<String>(
                    value: 'translation_review',
                    child: Text(l10n.text('translation_review')),
                  ),
                  if (row.ref.kind != _ItemKind.role)
                    PopupMenuItem<String>(
                      value: 'add_child',
                      child: Text(l10n.text('add_child_item')),
                    ),
                  PopupMenuItem<String>(
                    value: 'replace',
                    child: Text(l10n.text('replace_item_keep_children')),
                  ),
                  if (row.parent != null || row.isManualRootShortcut)
                    PopupMenuItem<String>(
                      value: 'remove_item',
                      child: Text(l10n.text('remove_item')),
                    ),
                  if (canDelete && !builtInRole)
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Text(l10n.text('delete_item')),
                    ),
                ],
                icon: const Icon(Icons.more_vert),
              ),
            ],
          ),
        ),
      ),
    );
    return KeyedSubtree(
      key: ValueKey<String>(row.instanceKey),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[rowContent, const Divider(height: 1)],
      ),
    );
  }

  Widget? _buildTreeBranch(
    _LinkRef link, {
    required _TreeData data,
    required bool canEdit,
    required _OrgUnifiedSearchQuery query,
    required int depth,
    required Set<String> path,
    required List<String> ancestorPath,
    required Map<String, List<_LinkRef>> childrenCache,
    required Map<String, bool> branchMatchCache,
  }) {
    if (path.contains(link.ref.key)) return null;
    if (!query.isEmpty &&
        !_branchMatches(
          link.ref,
          data,
          query,
          path,
          childrenCache,
          branchMatchCache,
        )) {
      return null;
    }

    final children = childrenCache.putIfAbsent(
      link.ref.key,
      () => _childrenOf(link.ref, data),
    );
    final hasChildren = children.isNotEmpty;
    final instanceKey = _branchInstanceKey(link, ancestorPath);
    final searching = !query.isEmpty;
    final hideParentContext = searching && query.hideParentContext;
    final matchesSelf = !searching || _itemMatchesQuery(link.ref, data, query);

    List<Widget> buildChildWidgets({required int childDepth}) {
      if (!hasChildren) {
        return const <Widget>[];
      }
      final nextPath = <String>{...path, link.ref.key};
      final nextAncestorPath = <String>[...ancestorPath, link.ref.key];
      final childWidgets = <Widget>[];
      for (final child in children) {
        final childWidget = _buildTreeBranch(
          child,
          data: data,
          canEdit: canEdit,
          query: query,
          depth: childDepth,
          path: nextPath,
          ancestorPath: nextAncestorPath,
          childrenCache: childrenCache,
          branchMatchCache: branchMatchCache,
        );
        if (childWidget != null) {
          childWidgets.add(childWidget);
        }
      }
      return childWidgets;
    }

    Widget buildBranch(bool expanded, {required int childDepth}) {
      final row = _VisibleTreeRow(
        instanceKey: instanceKey,
        ref: link.ref,
        parent: link.parent,
        linkKind: link.linkKind,
        depth: depth,
        ancestorKeys: ancestorPath,
        hasChildren: hasChildren,
        expanded: expanded,
        isManualRootShortcut: link.isManualRootShortcut,
      );

      final childWidgets = expanded
          ? buildChildWidgets(childDepth: childDepth)
          : const <Widget>[];

      return KeyedSubtree(
        key: ValueKey<String>(instanceKey),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildTreeRow(row, data, canEdit),
            ClipRect(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOutCubic,
                alignment: Alignment.topCenter,
                child: hasChildren && expanded
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: childWidgets,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      );
    }

    if (searching) {
      if (hideParentContext && !matchesSelf) {
        final promotedChildren = buildChildWidgets(childDepth: depth);
        if (promotedChildren.isEmpty) {
          return null;
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: promotedChildren,
        );
      }
      return buildBranch(true, childDepth: depth + 1);
    }

    if (!hasChildren) {
      return buildBranch(false, childDepth: depth + 1);
    }

    final expandedNotifier = _expandedNotifierForKey(instanceKey);
    return ValueListenableBuilder<bool>(
      valueListenable: expandedNotifier,
      builder: (context, expanded, _) =>
          buildBranch(expanded, childDepth: depth + 1),
    );
  }

  Widget _buildOrganizationTreeScreen(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = ref.watch(authStoreProvider);

    if (!auth.isAdmin) {
      return Center(
        child: AtlasEmptyState(
          icon: Icons.lock_outline,
          title: l10n.text('no_admin_tools_available'),
        ),
      );
    }

    final meAsync = ref.watch(adminOrgMeProvider);
    final itemsAsync = ref.watch(adminOrganizationItemsProvider);
    final linksAsync = ref.watch(adminOrganizationItemLinksProvider);
    final customizationAsync = ref.watch(adminCustomizationProvider);

    final items = itemsAsync.asData?.value ?? const <Map<String, dynamic>>[];
    final links = linksAsync.asData?.value ?? const <Map<String, dynamic>>[];

    final loading =
        meAsync.isLoading || itemsAsync.isLoading || linksAsync.isLoading;
    final hasAllTreeData = itemsAsync.hasValue && linksAsync.hasValue;

    final data = _buildTreeData(items: items, itemLinks: links);

    final query = _effectiveTreeSearchQuery();
    final treeSearchDiagnostics = validateSearchQueryAst(
      parseSearchQueryAst(_searchCtrl.text),
      capability: orgTreeSearchCapability,
    ).diagnostics;
    final childrenCache = <String, List<_LinkRef>>{};
    final branchMatchCache = <String, bool>{};
    final rootLinks = hasAllTreeData ? _rootLinks(data) : const <_LinkRef>[];
    final showMoreRoot = hasAllTreeData && query.isEmpty;
    final visibleRootLinks = query.isEmpty
        ? rootLinks
        : <_LinkRef>[
            for (final root in rootLinks)
              if (_branchMatches(
                root.ref,
                data,
                query,
                <String>{},
                childrenCache,
                branchMatchCache,
              ))
                root,
          ];
    final treeSearchSuggestions = _treeSearchSuggestions(l10n, data);
    final hasExpandedRows = _expandedKeys.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _AdminOrganizationScreenStateTools(
                    this,
                  )._buildSearchAndTreeControls(
                    l10n: l10n,
                    data: data,
                    hasExpandedRows: hasExpandedRows,
                  ),
                  if (query.structuredTokens.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: <Widget>[
                        for (final token in query.structuredTokens)
                          InputChip(
                            label: Text(token.toChipLabel()),
                            onDeleted: () =>
                                _removeTreeStructuredSearchTokenFromUi(token),
                          ),
                      ],
                    ),
                  ],
                  if (treeSearchSuggestions.isNotEmpty) ...<Widget>[
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
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: treeSearchSuggestions.length,
                          itemBuilder: (context, index) {
                            final suggestion = treeSearchSuggestions[index];
                            return ListTile(
                              dense: true,
                              title: Text(suggestion.label),
                              subtitle: suggestion.subtitle == null
                                  ? null
                                  : Text(suggestion.subtitle!),
                              onTap: () =>
                                  _applyTreeSearchSuggestion(suggestion),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                  if (treeSearchDiagnostics.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    SearchDiagnosticsList(diagnostics: treeSearchDiagnostics),
                  ],
                  if (loading) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: !hasAllTreeData
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : visibleRootLinks.isEmpty && !showMoreRoot
                  ? Center(
                      child: AtlasEmptyState(
                        icon: Icons.search_off_outlined,
                        title: l10n.text('no_matching_items'),
                        subtitle: query.hideParentContext
                            ? null
                            : l10n.text('search_parent_paths'),
                      ),
                    )
                  : ListView.builder(
                      controller: _treeScrollCtrl,
                      itemCount:
                          visibleRootLinks.length + (showMoreRoot ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (showMoreRoot && index == 0) {
                          return _AdminOrganizationScreenStateTools(
                            this,
                          )._buildMoreRootBranch(
                            l10n: l10n,
                            data: data,
                            customizationAsync: customizationAsync,
                          );
                        }
                        final rootIndex = showMoreRoot ? index - 1 : index;
                        final branch = _buildTreeBranch(
                          visibleRootLinks[rootIndex],
                          data: data,
                          canEdit: auth.isAdmin,
                          query: query,
                          depth: 0,
                          path: <String>{},
                          ancestorPath: const <String>[],
                          childrenCache: childrenCache,
                          branchMatchCache: branchMatchCache,
                        );
                        return branch ?? const SizedBox.shrink();
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
