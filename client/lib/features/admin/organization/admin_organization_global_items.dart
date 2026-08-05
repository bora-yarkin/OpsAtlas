// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Global item utilities and UI helpers for the organization management screen.

part of 'admin_organization_screen.dart';

extension _AdminOrganizationScreenStateGlobalItems
    on _AdminOrganizationScreenState {
  bool _isUnusedItem(_ItemRef ref, _TreeData data) {
    switch (ref.kind) {
      case _ItemKind.department:
        final hasParent =
            (data.parentUnitsByChildUnit[ref.id] ?? const <String>{})
                .isNotEmpty;
        final hasChildren =
            (data.childUnitsByParent[ref.id] ?? const <String>{}).isNotEmpty;
        final hasSpaces =
            (data.spacesByUnit[ref.id] ?? const <String>{}).isNotEmpty;
        final hasUsers =
            (data.usersByUnit[ref.id] ?? const <String>{}).isNotEmpty;
        return !hasParent && !hasChildren && !hasSpaces && !hasUsers;
      case _ItemKind.space:
        final hasUnits =
            (data.unitsBySpace[ref.id] ?? const <String>{}).isNotEmpty;
        return !hasUnits;
      case _ItemKind.user:
        final hasManager =
            (data.managerIdsByReport[ref.id] ?? const <String>{}).isNotEmpty;
        final hasReports =
            (data.reportsByManager[ref.id] ?? const <String>{}).isNotEmpty;
        final hasUnit =
            (data.orgUnitsByUser[ref.id] ?? const <String>{}).isNotEmpty;
        final hasSpace =
            (data.spacesByUser[ref.id] ?? const <String>{}).isNotEmpty;
        return !hasManager && !hasReports && !hasUnit && !hasSpace;
      case _ItemKind.role:
        final roleKey = ref.id;
        final assignedAsCustomRole =
            (data.usersByRoleKey[roleKey] ?? const <String>{}).isNotEmpty;
        final assignedToItemLink = data.itemLinks.any(
          (link) => (link['grant_role'] ?? '').toString() == roleKey,
        );
        return !(assignedAsCustomRole || assignedToItemLink);
    }
  }

  bool _isOrphanItem(_ItemRef ref, _TreeData data) {
    final kind = _itemKindApiName(ref.kind);
    return !data.itemLinks.any((link) {
      if (link['active'] == false) return false;
      final childKind = (link['child_kind'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final childId = (link['child_id'] ?? '').toString().trim();
      return childKind == kind && childId == ref.id;
    });
  }

  int _linkedCountFor(_ItemRef ref, _TreeData data) {
    final kind = _itemKindApiName(ref.kind);
    return data.itemLinks.where((link) {
      if (link['active'] == false) return false;
      final parentKind = (link['parent_kind'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final parentId = (link['parent_id'] ?? '').toString().trim();
      final childKind = (link['child_kind'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final childId = (link['child_id'] ?? '').toString().trim();
      final matchesParent = parentKind == kind && parentId == ref.id;
      final matchesChild = childKind == kind && childId == ref.id;
      return matchesParent || matchesChild;
    }).length;
  }

  bool _matchesLinkedCountRange(
    int linkedCount,
    _LinkedCountRangeFilter filter,
  ) {
    return switch (filter) {
      _LinkedCountRangeFilter.any => true,
      _LinkedCountRangeFilter.zero => linkedCount == 0,
      _LinkedCountRangeFilter.oneToTwo => linkedCount >= 1 && linkedCount <= 2,
      _LinkedCountRangeFilter.threeToFive =>
        linkedCount >= 3 && linkedCount <= 5,
      _LinkedCountRangeFilter.sixPlus => linkedCount >= 6,
    };
  }

  Set<String> _roleUsageKindsForItem(_ItemRef ref, _TreeData data) {
    final roleKinds = <String>{};
    final kind = _itemKindApiName(ref.kind);

    void trackRoleKey(String roleKey) {
      final normalized = roleKey.trim().toLowerCase();
      if (normalized.isEmpty) return;
      if (_TreeData.builtInRoleKeys.contains(normalized)) {
        roleKinds.add('built_in');
      } else if (data.roleByKey.containsKey(normalized)) {
        roleKinds.add('custom');
      }
    }

    for (final link in data.itemLinks) {
      if (link['active'] == false) continue;
      final parentKind = (link['parent_kind'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final parentId = (link['parent_id'] ?? '').toString().trim();
      final childKind = (link['child_kind'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final childId = (link['child_id'] ?? '').toString().trim();
      final isRelated =
          (parentKind == kind && parentId == ref.id) ||
          (childKind == kind && childId == ref.id);
      if (!isRelated) continue;
      trackRoleKey((link['grant_role'] ?? '').toString());
    }

    if (ref.kind == _ItemKind.user) {
      final user = data.userById[ref.id] ?? const <String, dynamic>{};
      trackRoleKey(_resolvedRoleKeyForUser(user, data));
    }

    if (ref.kind == _ItemKind.role) {
      final assigned =
          (data.usersByRoleKey[ref.id] ?? const <String>{}).isNotEmpty ||
          data.itemLinks.any((link) {
            if (link['active'] == false) return false;
            return (link['grant_role'] ?? '').toString().trim().toLowerCase() ==
                ref.id;
          });
      if (assigned) {
        trackRoleKey(ref.id);
      }
    }

    return roleKinds;
  }

  bool _matchesRoleUsageFilter(
    _ItemRef ref,
    _TreeData data,
    _RoleUsageFilter filter,
  ) {
    if (filter == _RoleUsageFilter.any) return true;
    final roleKinds = _roleUsageKindsForItem(ref, data);
    return switch (filter) {
      _RoleUsageFilter.any => true,
      _RoleUsageFilter.none => roleKinds.isEmpty,
      _RoleUsageFilter.builtIn => roleKinds.contains('built_in'),
      _RoleUsageFilter.custom => roleKinds.contains('custom'),
    };
  }

  bool _canDeleteRef(_ItemRef ref, _TreeData data) {
    if (ref.kind == _ItemKind.user) return false;
    final builtInRole =
        ref.kind == _ItemKind.role &&
        data.roleByKey[ref.id]?['built_in'] == true;
    if (builtInRole) return false;
    return _isUnusedItem(ref, data);
  }

  _GlobalItemsSearchCategory? _normalizeGlobalItemsSearchCategory(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'kind' ||
      'kinds' ||
      'type' ||
      'types' ||
      'item' ||
      'items' => _GlobalItemsSearchCategory.kind,
      'unused' ||
      'unused_only' ||
      'unlinked' => _GlobalItemsSearchCategory.unused,
      'orphan' || 'orphan_only' => _GlobalItemsSearchCategory.orphan,
      'linked' ||
      'links' ||
      'linked_count' => _GlobalItemsSearchCategory.linked,
      'roleusage' ||
      'role_usage' ||
      'roleusagefilter' ||
      'role_usage_filter' => _GlobalItemsSearchCategory.roleUsage,
      _ => null,
    };
  }

  _ItemKind? _itemKindFromToken(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'department' || 'departments' => _ItemKind.department,
      'space' || 'spaces' => _ItemKind.space,
      'user' || 'users' => _ItemKind.user,
      'role' || 'roles' => _ItemKind.role,
      _ => null,
    };
  }

  bool? _parseBooleanSearchToken(
    String value, {
    required bool defaultWhenEmpty,
  }) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return defaultWhenEmpty;
    if (normalized == 'true' ||
        normalized == 'yes' ||
        normalized == '1' ||
        normalized == 'on') {
      return true;
    }
    if (normalized == 'false' ||
        normalized == 'no' ||
        normalized == '0' ||
        normalized == 'off') {
      return false;
    }
    return null;
  }

  _LinkedCountRangeFilter? _linkedCountFilterFromToken(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'any' || normalized == 'all') {
      return _LinkedCountRangeFilter.any;
    }
    if (normalized == '0' || normalized == 'zero' || normalized == 'none') {
      return _LinkedCountRangeFilter.zero;
    }
    if (normalized == '1-2' ||
        normalized == '1..2' ||
        normalized == 'one-two' ||
        normalized == 'one_to_two') {
      return _LinkedCountRangeFilter.oneToTwo;
    }
    if (normalized == '3-5' ||
        normalized == '3..5' ||
        normalized == 'three-five' ||
        normalized == 'three_to_five') {
      return _LinkedCountRangeFilter.threeToFive;
    }
    if (normalized == '6+' ||
        normalized == '6plus' ||
        normalized == 'six+' ||
        normalized == 'sixplus') {
      return _LinkedCountRangeFilter.sixPlus;
    }
    return null;
  }

  _RoleUsageFilter? _roleUsageFilterFromToken(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      '' || 'any' => _RoleUsageFilter.any,
      'none' => _RoleUsageFilter.none,
      'builtin' || 'built_in' => _RoleUsageFilter.builtIn,
      'custom' => _RoleUsageFilter.custom,
      _ => null,
    };
  }

  _GlobalItemsSearchQuery _parseGlobalItemsSearchQuery(String raw) {
    final ast = parseSearchQueryAst(raw);
    final kindFilters = <_ItemKind>{};
    final excludedKindFilters = <_ItemKind>{};
    bool? unusedOnly;
    bool? orphanOnly;
    _LinkedCountRangeFilter? linkedCountFilter;
    final excludedLinkedCountFilters = <_LinkedCountRangeFilter>{};
    _RoleUsageFilter? roleUsageFilter;
    final excludedRoleUsageFilters = <_RoleUsageFilter>{};
    final structuredTokens = <SearchFieldToken>[];
    final tokenTerms = <String>[];

    for (final token in ast.fieldTokens) {
      final categoryRaw = token.normalizedField;
      final value = token.normalizedValue;
      final isNegated = token.isNegated;
      var usedStructuredToken = false;

      final directKind = _itemKindFromToken(categoryRaw);
      if (directKind != null) {
        if (isNegated) {
          excludedKindFilters.add(directKind);
        } else {
          kindFilters.add(directKind);
        }
        if (!isNegated && value.isNotEmpty) tokenTerms.add(value);
        usedStructuredToken = true;
        if (usedStructuredToken) {
          structuredTokens.add(token);
        }
        continue;
      }

      final category = _normalizeGlobalItemsSearchCategory(categoryRaw);
      if (category == null) {
        if (!isNegated && value.isNotEmpty) tokenTerms.add(value);
        continue;
      }
      switch (category) {
        case _GlobalItemsSearchCategory.kind:
          if (value.isEmpty) break;
          final kind = _itemKindFromToken(value);
          if (kind != null) {
            if (isNegated) {
              excludedKindFilters.add(kind);
            } else {
              kindFilters.add(kind);
            }
            usedStructuredToken = true;
          } else if (!isNegated) {
            tokenTerms.add(value);
          }
          break;
        case _GlobalItemsSearchCategory.unused:
          final parsed = _parseBooleanSearchToken(
            value,
            defaultWhenEmpty: true,
          );
          if (parsed != null) {
            unusedOnly = isNegated ? !parsed : parsed;
            usedStructuredToken = true;
          }
          break;
        case _GlobalItemsSearchCategory.orphan:
          final parsed = _parseBooleanSearchToken(
            value,
            defaultWhenEmpty: true,
          );
          if (parsed != null) {
            orphanOnly = isNegated ? !parsed : parsed;
            usedStructuredToken = true;
          }
          break;
        case _GlobalItemsSearchCategory.linked:
          final parsed = _linkedCountFilterFromToken(value);
          if (parsed != null) {
            if (isNegated) {
              excludedLinkedCountFilters.add(parsed);
            } else {
              linkedCountFilter = parsed;
            }
            usedStructuredToken = true;
          }
          break;
        case _GlobalItemsSearchCategory.roleUsage:
          final parsed = _roleUsageFilterFromToken(value);
          if (parsed != null) {
            if (isNegated) {
              excludedRoleUsageFilters.add(parsed);
            } else {
              roleUsageFilter = parsed;
            }
            usedStructuredToken = true;
          }
          break;
      }

      if (usedStructuredToken) {
        structuredTokens.add(token);
      }
    }

    final terms = [...tokenTerms, ...ast.normalizedTerms];

    return _GlobalItemsSearchQuery(
      terms: terms,
      expression: ast.expression,
      kindFilters: kindFilters,
      excludedKindFilters: excludedKindFilters,
      unusedOnly: unusedOnly,
      orphanOnly: orphanOnly,
      linkedCountFilter: linkedCountFilter,
      excludedLinkedCountFilters: excludedLinkedCountFilters,
      roleUsageFilter: roleUsageFilter,
      excludedRoleUsageFilters: excludedRoleUsageFilters,
      structuredTokens: structuredTokens,
    );
  }

  bool _globalItemMatchesParsedQuery(
    _ItemRef ref,
    _TreeData data,
    _GlobalItemsSearchQuery query,
  ) {
    final text = '${_itemLabel(ref, data)} ${_itemSubtitle(ref, data)}'
        .toLowerCase();
    final unused = _isUnusedItem(ref, data);
    final orphan = _isOrphanItem(ref, data);
    final linkedCount = _linkedCountFor(ref, data);

    return evaluateSearchExpression(
      query.expression,
      matchesField: (token) {
        final field = token.normalizedField;
        final value = token.normalizedValue;
        var applyNegation = true;
        bool baseMatch;

        final directKind = _itemKindFromToken(field);
        if (directKind != null) {
          if (value.isEmpty || token.isNegated) {
            baseMatch = ref.kind == directKind;
          } else {
            baseMatch = ref.kind == directKind && text.contains(value);
          }
        } else {
          final category = _normalizeGlobalItemsSearchCategory(field);
          if (category == null) {
            if (value.isEmpty || token.isNegated) {
              return true;
            }
            applyNegation = false;
            baseMatch = text.contains(value);
          } else {
            switch (category) {
              case _GlobalItemsSearchCategory.kind:
                if (value.isEmpty) {
                  return true;
                }
                final parsedKind = _itemKindFromToken(value);
                if (parsedKind == null) {
                  if (token.isNegated) {
                    return true;
                  }
                  applyNegation = false;
                  baseMatch = text.contains(value);
                } else {
                  baseMatch = ref.kind == parsedKind;
                }
                break;
              case _GlobalItemsSearchCategory.unused:
                final parsed = _parseBooleanSearchToken(
                  value,
                  defaultWhenEmpty: true,
                );
                if (parsed == null) {
                  return true;
                }
                baseMatch = unused == parsed;
                break;
              case _GlobalItemsSearchCategory.orphan:
                final parsed = _parseBooleanSearchToken(
                  value,
                  defaultWhenEmpty: true,
                );
                if (parsed == null) {
                  return true;
                }
                baseMatch = orphan == parsed;
                break;
              case _GlobalItemsSearchCategory.linked:
                final parsed = _linkedCountFilterFromToken(value);
                if (parsed == null) {
                  return true;
                }
                baseMatch = _matchesLinkedCountRange(linkedCount, parsed);
                break;
              case _GlobalItemsSearchCategory.roleUsage:
                final parsed = _roleUsageFilterFromToken(value);
                if (parsed == null) {
                  return true;
                }
                baseMatch = _matchesRoleUsageFilter(ref, data, parsed);
                break;
            }
          }
        }

        return applyNegation && token.isNegated ? !baseMatch : baseMatch;
      },
      matchesText: (token) => text.contains(token.normalizedValue),
    );
  }

  String _globalItemsSearchCategoryToken(_GlobalItemsSearchCategory category) {
    return switch (category) {
      _GlobalItemsSearchCategory.kind => 'kind',
      _GlobalItemsSearchCategory.unused => 'unused',
      _GlobalItemsSearchCategory.orphan => 'orphan',
      _GlobalItemsSearchCategory.linked => 'linked',
      _GlobalItemsSearchCategory.roleUsage => 'roleusage',
    };
  }

  String _globalItemsSearchCategoryLabel(
    _GlobalItemsSearchCategory category,
    AppLocalizations l10n,
  ) {
    return switch (category) {
      _GlobalItemsSearchCategory.kind => l10n.text('type'),
      _GlobalItemsSearchCategory.unused => l10n.text('unused_only'),
      _GlobalItemsSearchCategory.orphan => l10n.text('orphan_only'),
      _GlobalItemsSearchCategory.linked => l10n.text('linked_count_range'),
      _GlobalItemsSearchCategory.roleUsage => l10n.text('role_usage_filter'),
    };
  }

  List<_GlobalItemsSearchSuggestion> _globalItemsFieldAliasSuggestions(
    AppLocalizations l10n,
    String partialLower,
  ) {
    final aliases = <({String token, String label})>[
      (token: 'spaces', label: l10n.text('spaces')),
      (token: 'users', label: l10n.text('users')),
      (token: 'departments', label: l10n.text('departments')),
      (token: 'roles', label: l10n.text('roles')),
    ];

    return aliases
        .where((alias) {
          if (partialLower.isEmpty) return true;
          return alias.token.contains(partialLower) ||
              alias.label.toLowerCase().contains(partialLower);
        })
        .map(
          (alias) => _GlobalItemsSearchSuggestion(
            label: '@${alias.token} - ${alias.label}',
            tokenText: '@${alias.token}',
            appendSpace: true,
            subtitle: l10n.text('search'),
          ),
        )
        .toList(growable: false);
  }

  List<_GlobalItemsSearchSuggestion> _globalItemsKindAliasValueSuggestions({
    required String fieldToken,
    required _ItemKind kind,
    required String partialLower,
    required _TreeData data,
  }) {
    final rows = _allGlobalItemRefs(data)
        .where((ref) => ref.kind == kind)
        .map((ref) {
          final label = _itemLabel(ref, data).trim();
          final subtitle = _itemSubtitle(ref, data).trim();
          return (label: label, subtitle: subtitle, rawId: ref.id);
        })
        .where((row) => row.label.isNotEmpty || row.rawId.isNotEmpty)
        .where((row) {
          if (partialLower.isEmpty) return true;
          return row.label.toLowerCase().contains(partialLower) ||
              row.subtitle.toLowerCase().contains(partialLower) ||
              row.rawId.toLowerCase().contains(partialLower);
        })
        .take(8)
        .toList(growable: false);

    return rows
        .map((row) {
          final tokenValue = row.label.isNotEmpty ? row.label : row.rawId;
          final label = row.subtitle.isEmpty
              ? (row.label.isNotEmpty ? row.label : row.rawId)
              : '${row.label} (${row.subtitle})';
          return _GlobalItemsSearchSuggestion(
            label: label,
            tokenText: '@$fieldToken:${_encodeSearchTokenValue(tokenValue)}',
            appendSpace: true,
          );
        })
        .toList(growable: false);
  }

  List<_GlobalItemsSearchSuggestion> _globalItemsSearchValueSuggestions({
    required _GlobalItemsSearchCategory category,
    required String partialLower,
    required AppLocalizations l10n,
  }) {
    switch (category) {
      case _GlobalItemsSearchCategory.kind:
        return const <String>['department', 'space', 'user', 'role']
            .where((value) => value.contains(partialLower))
            .map(
              (value) => _GlobalItemsSearchSuggestion(
                label: value,
                tokenText:
                    '@${_globalItemsSearchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _GlobalItemsSearchCategory.unused:
      case _GlobalItemsSearchCategory.orphan:
        return const <String>['true', 'false']
            .where((value) => value.contains(partialLower))
            .map(
              (value) => _GlobalItemsSearchSuggestion(
                label: value,
                tokenText:
                    '@${_globalItemsSearchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _GlobalItemsSearchCategory.linked:
        return const <String>['any', '0', '1-2', '3-5', '6+']
            .where((value) => value.contains(partialLower))
            .map(
              (value) => _GlobalItemsSearchSuggestion(
                label: value,
                tokenText:
                    '@${_globalItemsSearchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _GlobalItemsSearchCategory.roleUsage:
        final rows = <({String label, String value})>[
          (label: l10n.text('role_usage_any'), value: 'any'),
          (label: l10n.text('role_usage_none'), value: 'none'),
          (label: l10n.text('role_usage_built_in'), value: 'builtin'),
          (label: l10n.text('role_usage_custom'), value: 'custom'),
        ];
        return rows
            .where(
              (row) =>
                  row.label.toLowerCase().contains(partialLower) ||
                  row.value.toLowerCase().contains(partialLower),
            )
            .take(8)
            .map(
              (row) => _GlobalItemsSearchSuggestion(
                label: row.label,
                tokenText:
                    '@${_globalItemsSearchCategoryToken(category)}:${_encodeSearchTokenValue(row.value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
    }
  }

  List<_GlobalItemsSearchSuggestion> _globalItemsSearchSuggestions(
    AppLocalizations l10n,
    _TreeData data,
  ) {
    final context = parseAtTokenSuggestionContext(_globalItemsSearchCtrl.text);
    if (context == null) {
      return _globalItemsRecentQueries
          .take(6)
          .map(
            (query) => _GlobalItemsSearchSuggestion(
              label: query,
              tokenText: query,
              appendSpace: false,
              subtitle: l10n.text('search'),
            ),
          )
          .toList(growable: false);
    }

    if (!context.hasValueSeparator) {
      final kindAlias = _itemKindFromToken(context.fieldLower);
      if (context.hasTrailingWhitespace && kindAlias != null) {
        return _globalItemsKindAliasValueSuggestions(
          fieldToken: context.fieldLower,
          kind: kindAlias,
          partialLower: '',
          data: data,
        );
      }
      final category = _normalizeGlobalItemsSearchCategory(context.fieldLower);
      if (context.hasTrailingWhitespace && category != null) {
        return _globalItemsSearchValueSuggestions(
          category: category,
          partialLower: '',
          l10n: l10n,
        );
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

      final aliasSuggestions = _globalItemsFieldAliasSuggestions(l10n, partial);
      return [...categorySuggestions, ...aliasSuggestions];
    }

    final kindAlias = _itemKindFromToken(context.fieldLower);
    if (kindAlias != null) {
      return _globalItemsKindAliasValueSuggestions(
        fieldToken: context.fieldLower,
        kind: kindAlias,
        partialLower: context.partialValueLower,
        data: data,
      );
    }

    final category = _normalizeGlobalItemsSearchCategory(context.fieldLower);
    if (category == null) return const <_GlobalItemsSearchSuggestion>[];
    return _globalItemsSearchValueSuggestions(
      category: category,
      partialLower: context.partialValueLower,
      l10n: l10n,
    );
  }

  void _applyGlobalItemsSearchSuggestion(
    _GlobalItemsSearchSuggestion suggestion,
  ) {
    final token = suggestion.tokenText.trim();
    final nextText = token.startsWith('@') || token.startsWith('-@')
        ? applyAtTokenSuggestion(
            raw: _globalItemsSearchCtrl.text,
            suggestionToken: suggestion.tokenText,
            appendSpace: suggestion.appendSpace,
          )
        : normalizeSearchInput(token);
    _globalItemsSearchCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    _rememberGlobalItemsQuery();
  }

  void _removeGlobalItemsStructuredSearchToken(SearchFieldToken token) {
    final nextText = removeSearchRangeFromQuery(
      _globalItemsSearchCtrl.text,
      start: token.start,
      end: token.end,
    );
    _globalItemsSearchCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  Future<void> _openGlobalItemsDialog(_TreeData data) async {
    final l10n = AppLocalizations.of(context);
    final selectedKeys = <String>{};
    _globalItemsSearchCtrl.text = '';

    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('global_items'),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final parsedQuery = _parseGlobalItemsSearchQuery(
            _globalItemsSearchCtrl.text,
          );
          final queryDiagnostics = validateSearchQueryAst(
            parseSearchQueryAst(_globalItemsSearchCtrl.text),
            capability: globalItemsSearchCapability,
          ).diagnostics;
          final searchSuggestions = _globalItemsSearchSuggestions(l10n, data);
          final filtered = _allGlobalItemRefs(data).where((ref) {
            return _globalItemMatchesParsedQuery(ref, data, parsedQuery);
          }).toList();
          final selectedRefs = selectedKeys
              .map(_itemRefFromKey)
              .whereType<_ItemRef>()
              .where((ref) => _itemExistsInData(ref, data))
              .toList(growable: false);
          final userSelectionCount = selectedRefs
              .where((ref) => ref.kind == _ItemKind.user)
              .length;

          filtered.sort((a, b) {
            final al = _itemLabel(a, data).toLowerCase();
            final bl = _itemLabel(b, data).toLowerCase();
            if (al == bl) return a.kind.name.compareTo(b.kind.name);
            return al.compareTo(bl);
          });

          return AlertDialog(
            title: Text(l10n.text('global_items')),
            content: SizedBox(
              width: 920,
              height: 560,
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _globalItemsSearchCtrl,
                          onChanged: (_) => setDialogState(() {}),
                          onSubmitted: (_) async {
                            await _rememberGlobalItemsQuery();
                            if (!context.mounted) return;
                            setDialogState(() {});
                          },
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
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      SearchHowToButton(
                        capability: globalItemsSearchCapability,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      IconButton(
                        tooltip: l10n.text('save_view'),
                        onPressed: _globalItemsSearchCtrl.text.trim().isEmpty
                            ? null
                            : () async {
                                await _openGlobalItemsSavedViewsDialog(l10n);
                                if (!context.mounted) return;
                                setDialogState(() {});
                              },
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: l10n.text('load_saved_view'),
                        onPressed: () async {
                          await _openGlobalItemsSavedViewsDialog(l10n);
                          if (!context.mounted) return;
                          setDialogState(() {});
                        },
                        icon: const Icon(Icons.bookmark_outline),
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
                              _removeGlobalItemsStructuredSearchToken(token);
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
                              onTap: () => setDialogState(() {
                                _applyGlobalItemsSearchSuggestion(suggestion);
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
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: filtered.isEmpty
                            ? null
                            : () => setDialogState(() {
                                selectedKeys
                                  ..clear()
                                  ..addAll(filtered.map((ref) => ref.key));
                              }),
                        icon: const Icon(Icons.select_all),
                        label: Text(l10n.text('select_all_visible')),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      OutlinedButton.icon(
                        onPressed: selectedKeys.isEmpty
                            ? null
                            : () => setDialogState(() {
                                selectedKeys.clear();
                              }),
                        icon: const Icon(Icons.clear_all),
                        label: Text(l10n.text('clear_selection')),
                      ),
                      const Spacer(),
                      Text(
                        '${selectedRefs.length} ${l10n.text('selected_items')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: selectedRefs.isEmpty
                            ? null
                            : () async {
                                final parent = await _pickGlobalItemDialog(
                                  data: data,
                                  allowedKinds: <_ItemKind>{
                                    _ItemKind.department,
                                    _ItemKind.user,
                                    _ItemKind.role,
                                  },
                                  announcement: l10n.text(
                                    'bulk_link_to_parent',
                                  ),
                                  title: l10n.text('bulk_link_to_parent'),
                                );
                                if (parent == null) return;
                                await _bulkLinkItemsToParent(
                                  parent: parent,
                                  children: selectedRefs,
                                  data: data,
                                );
                                if (context.mounted) Navigator.pop(context);
                              },
                        icon: const Icon(Icons.link_outlined),
                        label: Text(l10n.text('bulk_link_to_parent')),
                      ),
                      OutlinedButton.icon(
                        onPressed: selectedRefs.isEmpty
                            ? null
                            : () async {
                                final parent = await _pickGlobalItemDialog(
                                  data: data,
                                  allowedKinds: <_ItemKind>{
                                    _ItemKind.department,
                                    _ItemKind.user,
                                    _ItemKind.role,
                                  },
                                  announcement: l10n.text(
                                    'bulk_unlink_from_parent',
                                  ),
                                  title: l10n.text('bulk_unlink_from_parent'),
                                );
                                if (parent == null) return;
                                await _bulkUnlinkItemsFromParent(
                                  parent: parent,
                                  children: selectedRefs,
                                  data: data,
                                );
                                if (context.mounted) Navigator.pop(context);
                              },
                        icon: const Icon(Icons.link_off_outlined),
                        label: Text(l10n.text('bulk_unlink_from_parent')),
                      ),
                      OutlinedButton.icon(
                        onPressed: userSelectionCount == 0
                            ? null
                            : () async {
                                final role = await _pickGlobalItemDialog(
                                  data: data,
                                  allowedKinds: <_ItemKind>{_ItemKind.role},
                                  announcement: l10n.text('bulk_rebind_role'),
                                  title: l10n.text('bulk_rebind_role'),
                                );
                                if (role == null) return;
                                await _bulkRebindUserRoles(
                                  refs: selectedRefs,
                                  roleKey: role.id,
                                );
                                if (context.mounted) Navigator.pop(context);
                              },
                        icon: const Icon(Icons.security_outlined),
                        label: Text(l10n.text('bulk_rebind_role')),
                      ),
                      OutlinedButton.icon(
                        onPressed: selectedRefs.length == 1
                            ? () async {
                                await _replaceItemDialog(
                                  _rootVisibleRowForRef(
                                    selectedRefs.first,
                                    data,
                                  ),
                                  data,
                                );
                                if (context.mounted) Navigator.pop(context);
                              }
                            : null,
                        icon: const Icon(Icons.swap_horiz_outlined),
                        label: Text(l10n.text('bulk_replace_item')),
                      ),
                    ],
                  ),
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
                              final role = data.roleByKey[ref.id];
                              final builtIn =
                                  ref.kind == _ItemKind.role &&
                                  role?['built_in'] == true;
                              final canDelete = _canDeleteRef(ref, data);
                              return ListTile(
                                dense: true,
                                leading: Checkbox(
                                  value: selectedKeys.contains(ref.key),
                                  onChanged: (_) => setDialogState(() {
                                    if (selectedKeys.contains(ref.key)) {
                                      selectedKeys.remove(ref.key);
                                    } else {
                                      selectedKeys.add(ref.key);
                                    }
                                  }),
                                ),
                                title: Text(_itemLabel(ref, data)),
                                subtitle: Text(_itemSubtitle(ref, data)),
                                onTap: () => setDialogState(() {
                                  if (selectedKeys.contains(ref.key)) {
                                    selectedKeys.remove(ref.key);
                                  } else {
                                    selectedKeys.add(ref.key);
                                  }
                                }),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (value) async {
                                    if (value == 'view') {
                                      await _openItemViewDialog(
                                        ref,
                                        data,
                                        canEdit: true,
                                      );
                                      return;
                                    }
                                    if (value == 'edit') {
                                      await _openEditorForRef(ref, data);
                                      if (context.mounted) {
                                        setDialogState(() {});
                                      }
                                      return;
                                    }
                                    if (value == 'delete') {
                                      if (ref.kind == _ItemKind.department) {
                                        await _deleteUnit(
                                          data.unitById[ref.id] ??
                                              const <String, dynamic>{},
                                        );
                                      } else if (ref.kind == _ItemKind.space) {
                                        await _deleteSpace(
                                          data.spaceById[ref.id] ??
                                              const <String, dynamic>{},
                                        );
                                      } else if (ref.kind == _ItemKind.role) {
                                        await _deleteRole(
                                          data.roleByKey[ref.id] ??
                                              const <String, dynamic>{},
                                        );
                                      }
                                      if (context.mounted) {
                                        setDialogState(() {});
                                      }
                                    }
                                  },
                                  itemBuilder: (context) =>
                                      <PopupMenuEntry<String>>[
                                        PopupMenuItem<String>(
                                          value: 'view',
                                          child: Text(l10n.text('view_item')),
                                        ),
                                        PopupMenuItem<String>(
                                          value: 'edit',
                                          child: Text(l10n.text('edit')),
                                        ),
                                        if (canDelete && !builtIn)
                                          PopupMenuItem<String>(
                                            value: 'delete',
                                            child: Text(l10n.text('delete')),
                                          ),
                                      ],
                                ),
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
}
