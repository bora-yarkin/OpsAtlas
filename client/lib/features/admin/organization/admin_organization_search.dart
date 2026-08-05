// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Structured search behavior for the organization management screen.

part of 'admin_organization_screen.dart';

extension _AdminOrganizationScreenStateSearch on _AdminOrganizationScreenState {
  String _normalizedOrgUnitType(Object? rawValue) {
    final value = (rawValue ?? '').toString().trim().toLowerCase();
    if (value == 'team') {
      return 'department';
    }
    return value;
  }

  String _orgUnitTypeLabel(String unitType, AppLocalizations l10n) {
    return switch (_normalizedOrgUnitType(unitType)) {
      'region' => l10n.text('unit_type_region'),
      'store' => l10n.text('unit_type_store'),
      'department' => l10n.text('unit_type_department'),
      _ => l10n.text('unit_type_department'),
    };
  }

  void _setSearchState(VoidCallback update) {
    (this as dynamic).setState(update);
  }

  void _resetItemComputedCachesForData(_TreeData data) {
    final locale = Localizations.localeOf(context);
    if (!identical(_itemTextCacheData, data) ||
        _itemTextCacheLocale != locale) {
      _itemTextCacheData = data;
      _itemTextCacheLocale = locale;
      _itemLabelCacheByItemKey.clear();
      _itemSubtitleCacheByItemKey.clear();
      _rootLinksCacheData = null;
      _rootLinksCacheLocale = null;
      _rootLinksCacheManualSignature = null;
      _rootLinksCache = null;
    }
  }

  String _computeItemLabel(_ItemRef ref, _TreeData data) {
    final l10n = AppLocalizations.of(context);
    switch (ref.kind) {
      case _ItemKind.department:
        final unit = data.unitById[ref.id];
        return (unit == null ? ref.id : (unit['name'] ?? ref.id)).toString();
      case _ItemKind.space:
        final space = data.spaceById[ref.id];
        return (space == null ? ref.id : (space['name'] ?? ref.id)).toString();
      case _ItemKind.user:
        final user = data.userById[ref.id];
        return (user?['name'] ?? user?['email'] ?? ref.id).toString();
      case _ItemKind.role:
        final role = data.roleByKey[ref.id];
        if (role == null) return ref.id;
        if (role['built_in'] == true) {
          return switch (ref.id) {
            'viewer' => l10n.text('viewer'),
            'moderator' => l10n.text('moderator'),
            'admin' => l10n.text('admin'),
            _ => l10n.text('member'),
          };
        }
        return (role['name'] ?? ref.id).toString();
    }
  }

  String _itemLabel(_ItemRef ref, _TreeData data) {
    _resetItemComputedCachesForData(data);
    return _itemLabelCacheByItemKey.putIfAbsent(
      ref.key,
      () => _computeItemLabel(ref, data),
    );
  }

  String _computeItemSubtitle(_ItemRef ref, _TreeData data) {
    final l10n = AppLocalizations.of(context);
    switch (ref.kind) {
      case _ItemKind.department:
        final unit = data.unitById[ref.id] ?? const <String, dynamic>{};
        final slug = (unit['slug'] ?? '').toString();
        final unitType = _normalizedOrgUnitType(unit['unit_type']);
        final unitTypeLabel = _orgUnitTypeLabel(unitType, l10n);
        final regionLanguage = _regionDefaultLanguageCodeFromMeta(unit);
        final regionLanguagePart =
            unitType == 'region' && regionLanguage != null
            ? ' • ${l10n.text('language')}: $regionLanguage'
            : '';
        return '$slug • $unitTypeLabel$regionLanguagePart';
      case _ItemKind.space:
        final space = data.spaceById[ref.id] ?? const <String, dynamic>{};
        final slug = (space['slug'] ?? '').toString();
        final region = (space['region_code'] ?? '').toString().trim();
        final owner =
            _trimmedOrNull(space['owner_name']) ??
            _trimmedOrNull(space['owner_user_id']);
        final links = data.unitsBySpace[ref.id]?.length ?? 0;
        final regionPart = region.isEmpty
            ? ''
            : ' • ${l10n.text('unit_type_region')}: $region';
        final ownerPart = owner == null
            ? ''
            : ' • ${l10n.text('owner_prefix')}: $owner';
        return '$slug$regionPart$ownerPart • $links ${l10n.text('departments')}';
      case _ItemKind.user:
        final user = data.userById[ref.id] ?? const <String, dynamic>{};
        final email = (user['email'] ?? '').toString();
        final roleKey = _resolvedRoleKeyForUser(user, data).trim();
        final roleLabel = roleKey.isEmpty
            ? l10n.text('no_custom_role')
            : (data.roleByKey[roleKey]?['name'] ?? roleKey).toString();
        final statusParts = <String>[
          if (user['is_active'] == false) l10n.text('inactive'),
          if (user['must_change_password'] == true)
            l10n.text('onboarding_pending'),
        ];
        final status = statusParts.isEmpty
            ? ''
            : ' • ${statusParts.join(' • ')}';
        return '$email • $roleLabel$status';
      case _ItemKind.role:
        final role = data.roleByKey[ref.id] ?? const <String, dynamic>{};
        final roleKey = (role['role_key'] ?? ref.id).toString();
        final level = switch ((role['effective_level'] ?? '').toString()) {
          'viewer' => l10n.text('viewer'),
          'moderator' => l10n.text('moderator'),
          'admin' => l10n.text('admin'),
          _ => l10n.text('member'),
        };
        final builtIn = role['built_in'] == true;
        final tag = builtIn ? l10n.text('built_in') : l10n.text('custom');
        return '$roleKey • $level • $tag';
    }
  }

  String _itemSubtitle(_ItemRef ref, _TreeData data) {
    _resetItemComputedCachesForData(data);
    return _itemSubtitleCacheByItemKey.putIfAbsent(
      ref.key,
      () => _computeItemSubtitle(ref, data),
    );
  }

  IconData _itemIcon(_ItemRef ref) {
    switch (ref.kind) {
      case _ItemKind.department:
        return Icons.account_tree_outlined;
      case _ItemKind.space:
        return Icons.hub_outlined;
      case _ItemKind.user:
        return Icons.person_outline;
      case _ItemKind.role:
        return Icons.security_outlined;
    }
  }

  List<_LinkRef> _sortLinksByLabel(List<_LinkRef> links, _TreeData data) {
    final sorted = links.toList();
    final labelCache = <String, String>{};
    String labelFor(_LinkRef link) {
      return labelCache.putIfAbsent(
        link.ref.key,
        () => _itemLabel(link.ref, data).toLowerCase(),
      );
    }

    sorted.sort((a, b) {
      final rankDiff = _itemSortRank(
        a.ref,
        data,
      ).compareTo(_itemSortRank(b.ref, data));
      if (rankDiff != 0) return rankDiff;
      final al = labelFor(a);
      final bl = labelFor(b);
      if (al != bl) return al.compareTo(bl);
      final kindDiff = a.ref.kind.name.compareTo(b.ref.kind.name);
      if (kindDiff != 0) return kindDiff;
      return a.ref.id.compareTo(b.ref.id);
    });
    return sorted;
  }

  List<_LinkRef> _childrenOf(_ItemRef ref, _TreeData data) {
    final locale = Localizations.localeOf(context);
    if (!identical(_childrenCacheData, data) ||
        _childrenCacheLocale != locale) {
      _childrenCacheData = data;
      _childrenCacheLocale = locale;
      _childrenCacheByItemKey.clear();
    }
    final cachedChildren = _childrenCacheByItemKey[ref.key];
    if (cachedChildren != null) return cachedChildren;

    final children = <_LinkRef>[];

    switch (ref.kind) {
      case _ItemKind.department:
        for (final childId
            in data.childUnitsByParent[ref.id] ?? const <String>{}) {
          children.add(
            _LinkRef(
              ref: _ItemRef(kind: _ItemKind.department, id: childId),
              parent: ref,
              linkKind: _LinkKind.departmentToDepartment,
            ),
          );
        }
        for (final spaceId in data.spacesByUnit[ref.id] ?? const <String>{}) {
          children.add(
            _LinkRef(
              ref: _ItemRef(kind: _ItemKind.space, id: spaceId),
              parent: ref,
              linkKind: _LinkKind.departmentToSpace,
            ),
          );
        }
        for (final userId in data.usersByUnit[ref.id] ?? const <String>{}) {
          children.add(
            _LinkRef(
              ref: _ItemRef(kind: _ItemKind.user, id: userId),
              parent: ref,
              linkKind: _LinkKind.departmentToUser,
            ),
          );
        }
      case _ItemKind.space:
        break;
      case _ItemKind.user:
        for (final reportId
            in data.reportsByManager[ref.id] ?? const <String>{}) {
          children.add(
            _LinkRef(
              ref: _ItemRef(kind: _ItemKind.user, id: reportId),
              parent: ref,
              linkKind: _LinkKind.userToUser,
            ),
          );
        }
      case _ItemKind.role:
        break;
    }

    final sorted = _sortLinksByLabel(children, data);
    _childrenCacheByItemKey[ref.key] = sorted;
    return sorted;
  }

  List<_LinkRef> _rootLinks(_TreeData data) {
    _resetItemComputedCachesForData(data);
    final locale = Localizations.localeOf(context);
    final manualSignature = () {
      final sorted = _manualRootShortcutKeys.toList()..sort();
      return sorted.join('|');
    }();
    if (identical(_rootLinksCacheData, data) &&
        _rootLinksCacheLocale == locale &&
        _rootLinksCacheManualSignature == manualSignature &&
        _rootLinksCache != null) {
      return _rootLinksCache!;
    }

    final rootsByKey = <String, _LinkRef>{};

    void addRoot(_ItemRef ref, {bool isManualRootShortcut = false}) {
      if (ref.kind == _ItemKind.role) return;
      if (!_itemExistsInData(ref, data)) return;
      rootsByKey.putIfAbsent(
        ref.key,
        () => _LinkRef(
          ref: ref,
          linkKind: _LinkKind.root,
          isManualRootShortcut: isManualRootShortcut,
        ),
      );
    }

    for (final unit in data.units) {
      final unitId = (unit['id'] ?? '').toString();
      final linkedParentIds =
          data.parentUnitsByChildUnit[unitId] ?? const <String>{};
      if (unitId.isEmpty || linkedParentIds.isNotEmpty) {
        continue;
      }
      addRoot(_ItemRef(kind: _ItemKind.department, id: unitId));
    }

    for (final space in data.spaces) {
      final spaceId = (space['id'] ?? '').toString();
      if (spaceId.isEmpty) continue;
      final linkedUnits = data.unitsBySpace[spaceId] ?? const <String>{};
      if (linkedUnits.isNotEmpty) continue;
      addRoot(_ItemRef(kind: _ItemKind.space, id: spaceId));
    }

    for (final user in data.users) {
      final userId = (user['id'] ?? '').toString();
      if (userId.isEmpty) continue;
      final hasManager =
          (data.managerIdsByReport[userId] ?? const <String>{}).isNotEmpty;
      final hasReports =
          (data.reportsByManager[userId] ?? const <String>{}).isNotEmpty;
      final hasUnit =
          (data.orgUnitsByUser[userId] ?? const <String>{}).isNotEmpty;
      final hasSpace =
          (data.spacesByUser[userId] ?? const <String>{}).isNotEmpty;
      if (hasManager || hasReports || hasUnit || hasSpace) continue;
      addRoot(_ItemRef(kind: _ItemKind.user, id: userId));
    }

    for (final key in _manualRootShortcutKeys) {
      final ref = _itemRefFromKey(key);
      if (ref == null) continue;
      addRoot(ref, isManualRootShortcut: true);
    }

    final sorted = _sortLinksByLabel(rootsByKey.values.toList(), data);
    _rootLinksCacheData = data;
    _rootLinksCacheLocale = locale;
    _rootLinksCacheManualSignature = manualSignature;
    _rootLinksCache = sorted;
    return sorted;
  }

  _OrgSearchCategory? _normalizeOrgSearchCategory(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'kind' ||
      'kinds' ||
      'type' ||
      'types' ||
      'item' ||
      'items' => _OrgSearchCategory.kind,
      'space' ||
      'spaces' ||
      'user' ||
      'users' ||
      'department' ||
      'departments' ||
      'region' ||
      'regions' ||
      'store' ||
      'stores' ||
      'team' ||
      'teams' => _OrgSearchCategory.kind,
      'role' || 'roles' => _OrgSearchCategory.role,
      'status' || 'state' => _OrgSearchCategory.status,
      'unit' ||
      'units' ||
      'dept' ||
      'department' ||
      'departments' => _OrgSearchCategory.unit,
      _ => null,
    };
  }

  String _orgSearchCategoryToken(_OrgSearchCategory category) {
    return switch (category) {
      _OrgSearchCategory.kind => 'kind',
      _OrgSearchCategory.role => 'role',
      _OrgSearchCategory.status => 'status',
      _OrgSearchCategory.unit => 'unit',
    };
  }

  String _orgSearchCategoryLabel(
    _OrgSearchCategory category,
    AppLocalizations l10n,
  ) {
    return switch (category) {
      _OrgSearchCategory.kind => l10n.text('type'),
      _OrgSearchCategory.role => l10n.text('roles'),
      _OrgSearchCategory.status => l10n.text('status'),
      _OrgSearchCategory.unit => l10n.text('departments'),
    };
  }

  _OrgSearchFlag? _normalizeOrgSearchFlag(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'hide-parents' ||
      'hide-parent' ||
      'flat' ||
      'only-matches' => _OrgSearchFlag.hideParents,
      'show-parents' ||
      'show-parent' ||
      'with-parents' ||
      'keep-parents' => _OrgSearchFlag.showParents,
      _ => null,
    };
  }

  List<_OrgSearchSuggestion> _orgSearchFlagValueSuggestions({
    required String fieldToken,
    required String partialLower,
    required AppLocalizations l10n,
  }) {
    final options = <({String value, String help})>[
      (value: 'hide-parents', help: l10n.text('search_flag_hide_parents_help')),
      (value: 'show-parents', help: l10n.text('search_flag_show_parents_help')),
    ];
    return options
        .where((option) {
          if (partialLower.isEmpty) {
            return true;
          }
          return option.value.contains(partialLower) ||
              option.help.toLowerCase().contains(partialLower);
        })
        .map(
          (option) => _OrgSearchSuggestion(
            label: 'flag:${option.value}',
            tokenText: '@$fieldToken:${option.value}',
            appendSpace: true,
            subtitle: option.help,
          ),
        )
        .toList(growable: false);
  }

  _OrgUnifiedSearchQuery _parseOrgSearchQuery(String raw) {
    final ast = parseSearchQueryAst(raw);
    final kindFilters = <String>{};
    final excludedKindFilters = <String>{};
    final roleFilters = <String>{};
    final excludedRoleFilters = <String>{};
    final statusFilters = <String>{};
    final excludedStatusFilters = <String>{};
    final unitFilters = <String>{};
    final excludedUnitFilters = <String>{};
    final flags = <_OrgSearchFlag>{};
    final structuredTokens = <SearchFieldToken>[];
    final tokenTerms = <String>[];
    for (final token in ast.fieldTokens) {
      final categoryRaw = token.normalizedField;
      final value = token.normalizedValue;
      final isNegated = token.isNegated;
      var usedStructuredToken = false;

      void addKindFilter(String nextValue) {
        if (nextValue.isEmpty) {
          return;
        }
        if (isNegated) {
          excludedKindFilters.add(nextValue);
        } else {
          kindFilters.add(nextValue);
        }
        usedStructuredToken = true;
      }

      void addRoleFilter(String nextValue) {
        if (nextValue.isEmpty) {
          return;
        }
        if (isNegated) {
          excludedRoleFilters.add(nextValue);
        } else {
          roleFilters.add(nextValue);
        }
        usedStructuredToken = true;
      }

      void addStatusFilter(String nextValue) {
        if (nextValue.isEmpty) {
          return;
        }
        if (isNegated) {
          excludedStatusFilters.add(nextValue);
        } else {
          statusFilters.add(nextValue);
        }
        usedStructuredToken = true;
      }

      void addUnitFilter(String nextValue) {
        if (nextValue.isEmpty) {
          return;
        }
        if (isNegated) {
          excludedUnitFilters.add(nextValue);
        } else {
          unitFilters.add(nextValue);
        }
        usedStructuredToken = true;
      }

      void applyFlagValue(String nextValue) {
        final normalizedFlag = _normalizeOrgSearchFlag(nextValue);
        if (normalizedFlag == null) {
          return;
        }
        if (isNegated) {
          flags.remove(normalizedFlag);
        } else {
          flags.add(normalizedFlag);
        }
        usedStructuredToken = true;
      }

      switch (categoryRaw) {
        case 'flag':
        case 'flags':
          final values = splitSearchFlagValues(value);
          for (final flagValue in values) {
            applyFlagValue(flagValue);
          }
          break;
        case 'department':
        case 'departments':
        case 'dept':
          if (value.isEmpty) {
            addKindFilter('department');
          } else {
            addUnitFilter(value);
          }
          break;
        case 'space':
        case 'spaces':
          addKindFilter('space');
          if (!isNegated && value.isNotEmpty) {
            tokenTerms.add(value);
          }
          break;
        case 'user':
        case 'users':
          addKindFilter('user');
          if (!isNegated && value.isNotEmpty) {
            tokenTerms.add(value);
          }
          break;
        case 'region':
        case 'regions':
        case 'store':
        case 'stores':
        case 'team':
        case 'teams':
          addKindFilter(
            categoryRaw.endsWith('s')
                ? categoryRaw.substring(0, categoryRaw.length - 1)
                : categoryRaw,
          );
          if (!isNegated && value.isNotEmpty) {
            tokenTerms.add(value);
          }
          break;
        case 'role':
        case 'roles':
          if (value.isEmpty) {
            addKindFilter('role');
          } else {
            addRoleFilter(value);
          }
          break;
        default:
          final category = _normalizeOrgSearchCategory(categoryRaw);
          if (category == null) {
            if (!isNegated && value.isNotEmpty) {
              tokenTerms.add(value);
            }
            break;
          }
          if (value.isEmpty) {
            break;
          }
          switch (category) {
            case _OrgSearchCategory.kind:
              addKindFilter(value);
              break;
            case _OrgSearchCategory.role:
              addRoleFilter(value);
              break;
            case _OrgSearchCategory.status:
              addStatusFilter(value);
              break;
            case _OrgSearchCategory.unit:
              addUnitFilter(value);
              break;
          }
          break;
      }

      if (usedStructuredToken) {
        structuredTokens.add(token);
      }
    }

    final terms = [...tokenTerms, ...ast.normalizedTerms];

    final sortedKindFilters = kindFilters.toList()..sort();
    final sortedExcludedKindFilters = excludedKindFilters.toList()..sort();
    final sortedRoleFilters = roleFilters.toList()..sort();
    final sortedExcludedRoleFilters = excludedRoleFilters.toList()..sort();
    final sortedStatusFilters = statusFilters.toList()..sort();
    final sortedExcludedStatusFilters = excludedStatusFilters.toList()..sort();
    final sortedUnitFilters = unitFilters.toList()..sort();
    final sortedExcludedUnitFilters = excludedUnitFilters.toList()..sort();
    final sortedFlags = flags.map((flag) => flag.name).toList()..sort();

    final cacheParts = <String>[
      if (terms.isNotEmpty) 't=${terms.join(",")}',
      if (sortedKindFilters.isNotEmpty) 'k=$sortedKindFilters',
      if (sortedExcludedKindFilters.isNotEmpty) 'xk=$sortedExcludedKindFilters',
      if (sortedRoleFilters.isNotEmpty) 'r=$sortedRoleFilters',
      if (sortedExcludedRoleFilters.isNotEmpty) 'xr=$sortedExcludedRoleFilters',
      if (sortedStatusFilters.isNotEmpty) 's=$sortedStatusFilters',
      if (sortedExcludedStatusFilters.isNotEmpty)
        'xs=$sortedExcludedStatusFilters',
      if (sortedUnitFilters.isNotEmpty) 'u=$sortedUnitFilters',
      if (sortedExcludedUnitFilters.isNotEmpty) 'xu=$sortedExcludedUnitFilters',
      if (sortedFlags.isNotEmpty) 'f=$sortedFlags',
    ];

    return _OrgUnifiedSearchQuery(
      terms: terms,
      expression: ast.expression,
      kindFilters: kindFilters,
      excludedKindFilters: excludedKindFilters,
      roleFilters: roleFilters,
      excludedRoleFilters: excludedRoleFilters,
      statusFilters: statusFilters,
      excludedStatusFilters: excludedStatusFilters,
      unitFilters: unitFilters,
      excludedUnitFilters: excludedUnitFilters,
      flags: flags,
      structuredTokens: structuredTokens,
      cacheKey: cacheParts.join('|'),
    );
  }

  _OrgUnifiedSearchQuery _effectiveTreeSearchQuery() {
    final raw = _searchCtrl.text.trim();
    if (raw.isEmpty) {
      return const _OrgUnifiedSearchQuery(
        terms: <String>[],
        expression: null,
        kindFilters: <String>{},
        excludedKindFilters: <String>{},
        roleFilters: <String>{},
        excludedRoleFilters: <String>{},
        statusFilters: <String>{},
        excludedStatusFilters: <String>{},
        unitFilters: <String>{},
        excludedUnitFilters: <String>{},
        flags: <_OrgSearchFlag>{},
        structuredTokens: <SearchFieldToken>[],
        cacheKey: '',
      );
    }
    final parsed = _parseOrgSearchQuery(raw);
    if (!parsed.hasStructuredFilters &&
        raw.length < _AdminOrganizationScreenState._treeSearchMinChars) {
      return const _OrgUnifiedSearchQuery(
        terms: <String>[],
        expression: null,
        kindFilters: <String>{},
        excludedKindFilters: <String>{},
        roleFilters: <String>{},
        excludedRoleFilters: <String>{},
        statusFilters: <String>{},
        excludedStatusFilters: <String>{},
        unitFilters: <String>{},
        excludedUnitFilters: <String>{},
        flags: <_OrgSearchFlag>{},
        structuredTokens: <SearchFieldToken>[],
        cacheKey: '',
      );
    }
    return parsed;
  }

  bool _itemMatchesQuery(
    _ItemRef ref,
    _TreeData data,
    _OrgUnifiedSearchQuery query,
  ) {
    if (query.isEmpty) return true;

    final label = _itemLabel(ref, data).toLowerCase();
    final subtitle = _itemSubtitle(ref, data).toLowerCase();
    final text = '$label $subtitle';

    final kindCandidates = <String>{ref.kind.name};

    Set<String> scopedUnitIds() {
      final direct = switch (ref.kind) {
        _ItemKind.department => <String>{ref.id},
        _ItemKind.user => data.orgUnitsByUser[ref.id] ?? const <String>{},
        _ItemKind.space => data.unitsBySpace[ref.id] ?? const <String>{},
        _ItemKind.role => const <String>{},
      };

      final expanded = <String>{};
      for (final unitId in direct) {
        if (unitId.isEmpty) {
          continue;
        }
        expanded.addAll(data.ancestorUnitIdsByUnit[unitId] ?? <String>{unitId});
      }
      return expanded;
    }

    final unitScopeIds = scopedUnitIds();
    if (ref.kind == _ItemKind.department) {
      final unit = data.unitById[ref.id];
      final unitType = _normalizedOrgUnitType(unit?['unit_type']);
      if (unitType.isNotEmpty) {
        kindCandidates.add(unitType);
      }
      kindCandidates.add('department');
    } else {
      for (final unitId in unitScopeIds) {
        final unit = data.unitById[unitId];
        if (unit == null) {
          continue;
        }
        final unitType = _normalizedOrgUnitType(unit['unit_type']);
        if (unitType.isNotEmpty) {
          kindCandidates.add(unitType);
        }
      }
    }

    final roleCandidates = <String>{};
    if (ref.kind == _ItemKind.user) {
      final user = data.userById[ref.id];
      if (user != null) {
        roleCandidates.add(_resolvedRoleKeyForUser(user, data).toLowerCase());
        final roleLabel = _resolvedRoleLabelForUser(
          user,
          data,
          AppLocalizations.of(context),
        );
        roleCandidates.add(roleLabel.toLowerCase());
      }
    } else if (ref.kind == _ItemKind.role) {
      final role = data.roleByKey[ref.id];
      if (role != null) {
        roleCandidates.add((role['role_key'] ?? '').toString().toLowerCase());
        roleCandidates.add((role['name'] ?? '').toString().toLowerCase());
        roleCandidates.add(
          (role['effective_level'] ?? '').toString().toLowerCase(),
        );
      }
    }

    final statusCandidates = <String>{};
    if (ref.kind == _ItemKind.user) {
      final user = data.userById[ref.id];
      if (user != null) {
        statusCandidates.add(
          user['is_active'] == false ? 'inactive' : 'active',
        );
        if (user['must_change_password'] == true) {
          statusCandidates.add('pending');
          statusCandidates.add('onboarding');
        }
      }
    } else {
      final active = switch (ref.kind) {
        _ItemKind.department => data.unitById[ref.id]?['active'] != false,
        _ItemKind.space => data.spaceById[ref.id]?['active'] != false,
        _ItemKind.role => data.roleByKey[ref.id]?['active'] != false,
        _ItemKind.user => true,
      };
      statusCandidates.add(active ? 'active' : 'inactive');
    }

    final unitTexts = <String>{};
    for (final unitId in unitScopeIds) {
      final unit = data.unitById[unitId];
      if (unit == null) {
        continue;
      }
      unitTexts.add((unit['name'] ?? '').toString().toLowerCase());
      unitTexts.add((unit['slug'] ?? '').toString().toLowerCase());
    }

    bool matchesKindValue(String value) {
      return kindCandidates.any((candidate) => candidate.contains(value));
    }

    bool matchesRoleValue(String value) {
      return roleCandidates.any((candidate) => candidate.contains(value));
    }

    bool matchesStatusValue(String value) {
      return statusCandidates.any((candidate) => candidate.contains(value));
    }

    bool matchesUnitValue(String value) {
      return unitTexts.any((candidate) => candidate.contains(value));
    }

    return evaluateSearchExpression(
      query.expression,
      matchesField: (token) {
        final field = token.normalizedField;
        final value = token.normalizedValue;
        if (field == 'flag' || field == 'flags') {
          return true;
        }
        var applyNegation = true;
        bool baseMatch;

        if (field == 'department' ||
            field == 'departments' ||
            field == 'dept') {
          baseMatch = value.isEmpty
              ? matchesKindValue('department')
              : matchesUnitValue(value);
        } else if (field == 'role' || field == 'roles') {
          baseMatch = value.isEmpty
              ? matchesKindValue('role')
              : matchesRoleValue(value);
        } else {
          final kindAlias = _orgKindAliasFromField(field);
          if (kindAlias != null) {
            if (value.isEmpty || token.isNegated) {
              baseMatch = matchesKindValue(kindAlias);
            } else {
              baseMatch =
                  matchesKindValue(kindAlias) &&
                  (text.contains(value) || matchesUnitValue(value));
            }
          } else {
            final category = _normalizeOrgSearchCategory(field);
            if (category == null) {
              if (value.isEmpty || token.isNegated) {
                return true;
              }
              applyNegation = false;
              baseMatch = text.contains(value);
            } else {
              switch (category) {
                case _OrgSearchCategory.kind:
                  baseMatch = value.isEmpty ? true : matchesKindValue(value);
                  break;
                case _OrgSearchCategory.role:
                  baseMatch = value.isEmpty ? true : matchesRoleValue(value);
                  break;
                case _OrgSearchCategory.status:
                  baseMatch = value.isEmpty ? true : matchesStatusValue(value);
                  break;
                case _OrgSearchCategory.unit:
                  baseMatch = value.isEmpty ? true : matchesUnitValue(value);
                  break;
              }
            }
          }
        }

        return applyNegation && token.isNegated ? !baseMatch : baseMatch;
      },
      matchesText: (token) => text.contains(token.normalizedValue),
    );
  }

  bool _branchMatches(
    _ItemRef ref,
    _TreeData data,
    _OrgUnifiedSearchQuery query,
    Set<String> path,
    Map<String, List<_LinkRef>> childrenCache,
    Map<String, bool> branchMatchCache,
  ) {
    if (query.isEmpty) return true;
    if (path.contains(ref.key)) return false;
    final cacheKey = '${ref.key}|${query.cacheKey}';
    final cached = branchMatchCache[cacheKey];
    if (cached != null) return cached;
    if (_itemMatchesQuery(ref, data, query)) return true;

    final nextPath = <String>{...path, ref.key};
    final children = childrenCache.putIfAbsent(
      ref.key,
      () => _childrenOf(ref, data),
    );
    for (final child in children) {
      if (_branchMatches(
        child.ref,
        data,
        query,
        nextPath,
        childrenCache,
        branchMatchCache,
      )) {
        branchMatchCache[cacheKey] = true;
        return true;
      }
    }
    branchMatchCache[cacheKey] = false;
    return false;
  }

  String _encodeSearchTokenValue(String value) {
    return value.contains(' ') ? '"$value"' : value;
  }

  String? _orgKindAliasFromField(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'space' || 'spaces' => 'space',
      'user' || 'users' => 'user',
      'department' || 'departments' || 'dept' => 'department',
      'role' || 'roles' => 'role',
      'region' || 'regions' => 'region',
      'store' || 'stores' => 'store',
      'team' || 'teams' => 'team',
      _ => null,
    };
  }

  List<_OrgSearchSuggestion> _treeSearchFieldAliasSuggestions(
    AppLocalizations l10n,
    String partialLower,
  ) {
    final aliases = <({String token, String label})>[
      (token: 'spaces', label: l10n.text('spaces')),
      (token: 'users', label: l10n.text('users')),
      (token: 'departments', label: l10n.text('departments')),
      (token: 'roles', label: l10n.text('roles')),
      (token: 'regions', label: l10n.text('unit_type_region')),
      (token: 'stores', label: l10n.text('unit_type_store')),
      (token: 'teams', label: l10n.text('unit_type_team')),
      (token: 'flag', label: l10n.text('search_flags')),
    ];

    return aliases
        .where((alias) {
          if (partialLower.isEmpty) return true;
          return alias.token.contains(partialLower) ||
              alias.label.toLowerCase().contains(partialLower);
        })
        .map(
          (alias) => _OrgSearchSuggestion(
            label: '@${alias.token} - ${alias.label}',
            tokenText: '@${alias.token}',
            appendSpace: true,
            subtitle: l10n.text('search'),
          ),
        )
        .toList(growable: false);
  }

  List<_OrgSearchSuggestion> _treeSearchKindAliasValueSuggestions({
    required String fieldToken,
    required String kindAlias,
    required String partialLower,
    required _TreeData data,
  }) {
    switch (kindAlias) {
      case 'space':
        final rows = data.spaces
            .map((space) {
              final id = (space['id'] ?? '').toString().trim();
              final name = (space['name'] ?? '').toString().trim();
              final slug = (space['slug'] ?? '').toString().trim();
              return (id: id, name: name, slug: slug);
            })
            .where((row) => row.id.isNotEmpty)
            .where((row) {
              if (partialLower.isEmpty) return true;
              return row.id.toLowerCase().contains(partialLower) ||
                  row.name.toLowerCase().contains(partialLower) ||
                  row.slug.toLowerCase().contains(partialLower);
            })
            .take(8)
            .toList(growable: false);
        return rows
            .map((row) {
              final tokenValue = row.slug.isNotEmpty
                  ? row.slug
                  : (row.name.isNotEmpty ? row.name : row.id);
              final label = row.name.isNotEmpty
                  ? row.name
                  : (row.slug.isNotEmpty ? row.slug : row.id);
              return _OrgSearchSuggestion(
                label: label,
                tokenText:
                    '@$fieldToken:${_encodeSearchTokenValue(tokenValue)}',
                appendSpace: true,
              );
            })
            .toList(growable: false);
      case 'user':
        final rows = data.users
            .map((user) {
              final id = (user['id'] ?? '').toString().trim();
              final name = (user['name'] ?? '').toString().trim();
              final email = (user['email'] ?? '').toString().trim();
              return (id: id, name: name, email: email);
            })
            .where((row) => row.id.isNotEmpty)
            .where((row) {
              if (partialLower.isEmpty) return true;
              return row.id.toLowerCase().contains(partialLower) ||
                  row.name.toLowerCase().contains(partialLower) ||
                  row.email.toLowerCase().contains(partialLower);
            })
            .take(8)
            .toList(growable: false);
        return rows
            .map((row) {
              final tokenValue = row.email.isNotEmpty
                  ? row.email
                  : (row.name.isNotEmpty ? row.name : row.id);
              final label = row.name.isNotEmpty
                  ? row.name
                  : (row.email.isNotEmpty ? row.email : row.id);
              return _OrgSearchSuggestion(
                label: row.email.isEmpty ? label : '$label (${row.email})',
                tokenText:
                    '@$fieldToken:${_encodeSearchTokenValue(tokenValue)}',
                appendSpace: true,
              );
            })
            .toList(growable: false);
      case 'department':
      case 'region':
      case 'store':
      case 'team':
        final rows = data.units
            .map((unit) {
              final id = (unit['id'] ?? '').toString().trim();
              final name = (unit['name'] ?? '').toString().trim();
              final slug = (unit['slug'] ?? '').toString().trim();
              final unitType = _normalizedOrgUnitType(unit['unit_type']);
              return (id: id, name: name, slug: slug, unitType: unitType);
            })
            .where((row) => row.id.isNotEmpty)
            .where((row) {
              if (kindAlias == 'department') return true;
              if (kindAlias == 'team') {
                return row.unitType == 'department';
              }
              return row.unitType == kindAlias;
            })
            .where((row) {
              if (partialLower.isEmpty) return true;
              return row.id.toLowerCase().contains(partialLower) ||
                  row.name.toLowerCase().contains(partialLower) ||
                  row.slug.toLowerCase().contains(partialLower);
            })
            .take(8)
            .toList(growable: false);
        return rows
            .map((row) {
              final tokenValue = row.slug.isNotEmpty
                  ? row.slug
                  : (row.name.isNotEmpty ? row.name : row.id);
              final label = row.name.isNotEmpty
                  ? row.name
                  : (row.slug.isNotEmpty ? row.slug : row.id);
              return _OrgSearchSuggestion(
                label: label,
                tokenText:
                    '@$fieldToken:${_encodeSearchTokenValue(tokenValue)}',
                appendSpace: true,
              );
            })
            .toList(growable: false);
      case 'role':
        final rows = data.roleByKey.entries
            .map((entry) {
              final key = entry.key.trim();
              final name = (entry.value['name'] ?? key).toString().trim();
              return (key: key, name: name);
            })
            .where((row) => row.key.isNotEmpty)
            .where((row) {
              if (partialLower.isEmpty) return true;
              return row.key.toLowerCase().contains(partialLower) ||
                  row.name.toLowerCase().contains(partialLower);
            })
            .take(8)
            .toList(growable: false);
        return rows
            .map(
              (row) => _OrgSearchSuggestion(
                label: '${row.name} (${row.key})',
                tokenText: '@$fieldToken:${_encodeSearchTokenValue(row.key)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      default:
        return const <_OrgSearchSuggestion>[];
    }
  }

  List<_OrgSearchSuggestion> _treeSearchSuggestions(
    AppLocalizations l10n,
    _TreeData data,
  ) {
    final context = parseAtTokenSuggestionContext(_searchCtrl.text);
    if (context == null) {
      return _treeRecentQueries
          .take(6)
          .map(
            (query) => _OrgSearchSuggestion(
              label: query,
              tokenText: query,
              appendSpace: false,
              subtitle: l10n.text('search'),
            ),
          )
          .toList(growable: false);
    }

    if (!context.hasValueSeparator) {
      final aliasKind = _orgKindAliasFromField(context.fieldLower);
      if (context.hasTrailingWhitespace && aliasKind != null) {
        return _treeSearchKindAliasValueSuggestions(
          fieldToken: context.fieldLower,
          kindAlias: aliasKind,
          partialLower: '',
          data: data,
        );
      }
      final category = _normalizeOrgSearchCategory(context.fieldLower);
      if (context.hasTrailingWhitespace && category != null) {
        return _treeSearchValueSuggestions(
          category: category,
          partialLower: '',
          l10n: l10n,
          data: data,
        );
      }
      if (context.hasTrailingWhitespace &&
          (context.fieldLower == 'flag' || context.fieldLower == 'flags')) {
        return _orgSearchFlagValueSuggestions(
          fieldToken: context.fieldLower,
          partialLower: '',
          l10n: l10n,
        );
      }
      final partial = context.partialFieldLower;
      final categorySuggestions = _OrgSearchCategory.values
          .where((category) {
            final token = _orgSearchCategoryToken(category);
            final label = _orgSearchCategoryLabel(category, l10n).toLowerCase();
            if (partial.isEmpty) return true;
            return token.contains(partial) || label.contains(partial);
          })
          .map(
            (category) => _OrgSearchSuggestion(
              label:
                  '@${_orgSearchCategoryToken(category)} - ${_orgSearchCategoryLabel(category, l10n)}',
              tokenText: '@${_orgSearchCategoryToken(category)}:',
              appendSpace: false,
              subtitle: l10n.text('search'),
            ),
          )
          .toList(growable: false);

      final aliasSuggestions = _treeSearchFieldAliasSuggestions(l10n, partial);
      return [...categorySuggestions, ...aliasSuggestions];
    }

    final aliasKind = _orgKindAliasFromField(context.fieldLower);
    if (aliasKind != null) {
      return _treeSearchKindAliasValueSuggestions(
        fieldToken: context.fieldLower,
        kindAlias: aliasKind,
        partialLower: context.partialValueLower,
        data: data,
      );
    }

    if (context.fieldLower == 'flag' || context.fieldLower == 'flags') {
      return _orgSearchFlagValueSuggestions(
        fieldToken: context.fieldLower,
        partialLower: context.partialValueLower,
        l10n: l10n,
      );
    }

    final category = _normalizeOrgSearchCategory(context.fieldLower);
    if (category == null) return const <_OrgSearchSuggestion>[];
    return _treeSearchValueSuggestions(
      category: category,
      partialLower: context.partialValueLower,
      l10n: l10n,
      data: data,
    );
  }

  List<_OrgSearchSuggestion> _treeSearchValueSuggestions({
    required _OrgSearchCategory category,
    required String partialLower,
    required AppLocalizations l10n,
    required _TreeData data,
  }) {
    switch (category) {
      case _OrgSearchCategory.kind:
        const values = <String>[
          'department',
          'space',
          'user',
          'role',
          'region',
          'store',
          'team',
        ];
        return values
            .where((value) => value.contains(partialLower))
            .map(
              (value) => _OrgSearchSuggestion(
                label: value,
                tokenText:
                    '@${_orgSearchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _OrgSearchCategory.role:
        final rows = data.roleByKey.entries
            .map((entry) {
              final key = entry.key.trim();
              final name = (entry.value['name'] ?? key).toString().trim();
              return (key: key, name: name);
            })
            .where((row) => row.key.isNotEmpty)
            .where(
              (row) =>
                  row.key.toLowerCase().contains(partialLower) ||
                  row.name.toLowerCase().contains(partialLower),
            )
            .take(8)
            .toList(growable: false);
        return rows
            .map(
              (row) => _OrgSearchSuggestion(
                label: '${row.name} (${row.key})',
                tokenText:
                    '@${_orgSearchCategoryToken(category)}:${_encodeSearchTokenValue(row.key)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _OrgSearchCategory.status:
        const values = <String>['active', 'inactive', 'pending'];
        return values
            .where((value) => value.contains(partialLower))
            .map(
              (value) => _OrgSearchSuggestion(
                label: value,
                tokenText:
                    '@${_orgSearchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _OrgSearchCategory.unit:
        final rows = data.units
            .map((unit) {
              final id = (unit['id'] ?? '').toString().trim();
              final name = (unit['name'] ?? '').toString().trim();
              final slug = (unit['slug'] ?? '').toString().trim();
              return (id: id, name: name, slug: slug);
            })
            .where((row) => row.id.isNotEmpty)
            .where((row) {
              if (partialLower.isEmpty) return true;
              return row.name.toLowerCase().contains(partialLower) ||
                  row.slug.toLowerCase().contains(partialLower);
            })
            .take(8)
            .toList(growable: false);
        return rows
            .map(
              (row) => _OrgSearchSuggestion(
                label: row.slug.isEmpty
                    ? row.name
                    : '${row.name} (${row.slug})',
                tokenText:
                    '@${_orgSearchCategoryToken(category)}:${_encodeSearchTokenValue(row.slug.isEmpty ? row.name : row.slug)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
    }
  }

  void _applyTreeSearchSuggestion(_OrgSearchSuggestion suggestion) {
    final token = suggestion.tokenText.trim();
    final nextText = token.startsWith('@') || token.startsWith('-@')
        ? applyAtTokenSuggestion(
            raw: _searchCtrl.text,
            suggestionToken: suggestion.tokenText,
            appendSpace: suggestion.appendSpace,
          )
        : normalizeSearchInput(token);
    _searchCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    _searchFocusNode.requestFocus();
    _rememberTreeSearchQuery();
    _setSearchState(() {});
  }

  void _removeTreeStructuredSearchToken(SearchFieldToken token) {
    final nextText = removeSearchRangeFromQuery(
      _searchCtrl.text,
      start: token.start,
      end: token.end,
    );
    _searchCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    _searchFocusNode.requestFocus();
  }

  String _branchInstanceKey(_LinkRef link, List<String> ancestorPath) {
    return '${ancestorPath.join('>')}>${link.ref.key}|${link.linkKind.name}';
  }

  ValueNotifier<bool> _expandedNotifierForKey(String key) {
    final existing = _expandedByKey[key];
    if (existing != null) return existing;
    final created = ValueNotifier<bool>(_expandedKeys.contains(key));
    _expandedByKey[key] = created;
    return created;
  }

  void _setExpandedState(String key, bool expanded, {bool notifyUi = true}) {
    final hadExpandedRows = _expandedKeys.isNotEmpty;
    if (expanded) {
      _expandedKeys.add(key);
    } else {
      _expandedKeys.remove(key);
    }
    final notifier = _expandedByKey[key];
    if (notifier != null && notifier.value != expanded) {
      notifier.value = expanded;
    }
    final hasExpandedRows = _expandedKeys.isNotEmpty;
    if (notifyUi && mounted && hadExpandedRows != hasExpandedRows) {
      _setSearchState(() {});
    }
  }

  Set<String> _collectExpandableBranchKeys(_TreeData data) {
    final expandable = <String>{};
    final childrenCache = <String, List<_LinkRef>>{};

    void visit(_LinkRef link, Set<String> path, List<String> ancestorPath) {
      if (path.contains(link.ref.key)) return;
      final children = childrenCache.putIfAbsent(
        link.ref.key,
        () => _childrenOf(link.ref, data),
      );
      final instanceKey = _branchInstanceKey(link, ancestorPath);
      if (children.isNotEmpty) {
        expandable.add(instanceKey);
      }
      if (children.isEmpty) return;
      final nextPath = <String>{...path, link.ref.key};
      final nextAncestorPath = <String>[...ancestorPath, link.ref.key];
      for (final child in children) {
        visit(child, nextPath, nextAncestorPath);
      }
    }

    for (final root in _rootLinks(data)) {
      visit(root, <String>{}, const <String>[]);
    }
    return expandable;
  }

  void _expandAll(_TreeData data) {
    final hadExpandedRows = _expandedKeys.isNotEmpty;
    final keys = _collectExpandableBranchKeys(data);
    _expandedKeys
      ..clear()
      ..addAll(keys);
    for (final entry in _expandedByKey.entries) {
      final shouldExpand = keys.contains(entry.key);
      if (entry.value.value != shouldExpand) {
        entry.value.value = shouldExpand;
      }
    }
    final hasExpandedRows = _expandedKeys.isNotEmpty;
    if (mounted && hadExpandedRows != hasExpandedRows) {
      _setSearchState(() {});
    }
  }

  void _collapseAll() {
    final hadExpandedRows = _expandedKeys.isNotEmpty;
    _expandedKeys.clear();
    for (final entry in _expandedByKey.entries) {
      if (entry.value.value) {
        entry.value.value = false;
      }
    }
    final hasExpandedRows = _expandedKeys.isNotEmpty;
    if (mounted && hadExpandedRows != hasExpandedRows) {
      _setSearchState(() {});
    }
  }

  void _selectItem(_ItemRef ref) {
    _setSearchState(() {
      _selectedItemKey = ref.key;
    });
  }

  void _toggleRowExpansion(_VisibleTreeRow row) {
    final query = _effectiveTreeSearchQuery();
    final canExpand = row.hasChildren && query.isEmpty;
    if (!canExpand) {
      _selectItem(row.ref);
      return;
    }
    final nextExpanded = !_expandedKeys.contains(row.instanceKey);
    _setExpandedState(row.instanceKey, nextExpanded);
  }

  Future<void> _openCreateItemMenu(String value, _TreeData data) async {
    if (value == 'existing_root') {
      final l10n = AppLocalizations.of(context);
      final selected = await _pickGlobalItemDialog(
        data: data,
        allowedKinds: <_ItemKind>{
          _ItemKind.department,
          _ItemKind.space,
          _ItemKind.user,
        },
        announcement: l10n.text('add_existing_to_root'),
        title: l10n.text('add_existing_to_root'),
      );
      if (selected == null) return;
      _setSearchState(() {
        _manualRootShortcutKeys.add(selected.key);
      });
      await _persistManualRootShortcuts();
      return;
    }
    if (value == 'department') {
      await _openUnitEditor(data: data);
      return;
    }
    if (value == 'space') {
      await _openSpaceEditor(data: data);
      return;
    }
    if (value == 'user') {
      await _openUserEditor(data: data);
      return;
    }
    if (value == 'role') {
      await _openRoleEditor();
      return;
    }
  }

  String _itemKindLabel(_ItemKind kind, AppLocalizations l10n) {
    return switch (kind) {
      _ItemKind.department => l10n.text('departments'),
      _ItemKind.space => l10n.text('spaces'),
      _ItemKind.user => l10n.text('users'),
      _ItemKind.role => l10n.text('roles'),
    };
  }

  List<_ItemRef> _allGlobalItemRefs(_TreeData data) {
    return <_ItemRef>[
      for (final unit in data.units)
        _ItemRef(kind: _ItemKind.department, id: (unit['id'] ?? '').toString()),
      for (final space in data.spaces)
        _ItemRef(kind: _ItemKind.space, id: (space['id'] ?? '').toString()),
      for (final user in data.users)
        _ItemRef(kind: _ItemKind.user, id: (user['id'] ?? '').toString()),
      for (final roleKey in data.roleByKey.keys)
        _ItemRef(kind: _ItemKind.role, id: roleKey),
    ].where((ref) => ref.id.isNotEmpty).toList();
  }

  String _itemKindApiName(_ItemKind kind) {
    return switch (kind) {
      _ItemKind.department => 'department',
      _ItemKind.space => 'space',
      _ItemKind.user => 'user',
      _ItemKind.role => 'role',
    };
  }

  bool _isSupportedLinkPair(_ItemKind parentKind, _ItemKind childKind) {
    return switch ((parentKind, childKind)) {
      (_ItemKind.department, _ItemKind.department) => true,
      (_ItemKind.department, _ItemKind.space) => true,
      (_ItemKind.department, _ItemKind.user) => true,
      (_ItemKind.user, _ItemKind.user) => true,
      (_ItemKind.role, _ItemKind.user) => true,
      _ => false,
    };
  }

  _ItemKind? _itemKindFromApiName(String rawKind) {
    final kind = rawKind.trim().toLowerCase();
    return switch (kind) {
      'department' => _ItemKind.department,
      'space' => _ItemKind.space,
      'user' => _ItemKind.user,
      'role' => _ItemKind.role,
      _ => null,
    };
  }

  List<_ItemRef> _refsForKind(_ItemKind kind, _TreeData data) {
    switch (kind) {
      case _ItemKind.department:
        return _sortItemRefs(
          data.units.map(
            (unit) => _ItemRef(
              kind: _ItemKind.department,
              id: (unit['id'] ?? '').toString(),
            ),
          ),
          data,
        );
      case _ItemKind.space:
        return _sortItemRefs(
          data.spaces.map(
            (space) => _ItemRef(
              kind: _ItemKind.space,
              id: (space['id'] ?? '').toString(),
            ),
          ),
          data,
        );
      case _ItemKind.user:
        return _sortItemRefs(
          data.users.map(
            (user) => _ItemRef(
              kind: _ItemKind.user,
              id: (user['id'] ?? '').toString(),
            ),
          ),
          data,
        );
      case _ItemKind.role:
        return _sortItemRefs(
          data.roleByKey.keys.map(
            (roleKey) => _ItemRef(kind: _ItemKind.role, id: roleKey),
          ),
          data,
        );
    }
  }

  List<_ItemKind> _childKindsForParentKind(_ItemKind parentKind) {
    return switch (parentKind) {
      _ItemKind.department => <_ItemKind>[
        _ItemKind.department,
        _ItemKind.space,
        _ItemKind.user,
      ],
      _ItemKind.user => <_ItemKind>[_ItemKind.user],
      _ItemKind.role => <_ItemKind>[_ItemKind.user],
      _ItemKind.space => const <_ItemKind>[],
    };
  }
}
