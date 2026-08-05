// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Internal enums, records, and view models used by the organization management screen.

part of 'admin_organization_screen.dart';

enum _ItemKind { department, space, user, role }

enum _LinkKind {
  root,
  departmentToDepartment,
  departmentToSpace,
  departmentToUser,
  spaceToUser,
  userToUser,
}

class _ItemRef {
  final _ItemKind kind;
  final String id;

  const _ItemRef({required this.kind, required this.id});

  String get key => '${kind.name}:$id';

  @override
  bool operator ==(Object other) =>
      other is _ItemRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

class _LinkRef {
  final _ItemRef ref;
  final _ItemRef? parent;
  final _LinkKind linkKind;
  final bool isManualRootShortcut;

  const _LinkRef({
    required this.ref,
    this.parent,
    required this.linkKind,
    this.isManualRootShortcut = false,
  });
}

class _VisibleTreeRow {
  final String instanceKey;
  final _ItemRef ref;
  final _ItemRef? parent;
  final _LinkKind linkKind;
  final int depth;
  final List<String> ancestorKeys;
  final bool hasChildren;
  final bool expanded;
  final bool isManualRootShortcut;

  const _VisibleTreeRow({
    required this.instanceKey,
    required this.ref,
    this.parent,
    required this.linkKind,
    required this.depth,
    required this.ancestorKeys,
    required this.hasChildren,
    required this.expanded,
    required this.isManualRootShortcut,
  });
}

class _RelationshipGroup extends StatelessWidget {
  final String title;
  final List<_ItemRef> refs;
  final _TreeData data;
  final IconData Function(_ItemRef) iconForRef;
  final String Function(_ItemRef, _TreeData) labelForRef;
  final String emptyText;

  const _RelationshipGroup({
    required this.title,
    required this.refs,
    required this.data,
    required this.iconForRef,
    required this.labelForRef,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    final visibleRefs = refs.take(10).toList();
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$title (${refs.length})',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (refs.isEmpty)
            Text(emptyText, style: Theme.of(context).textTheme.bodySmall)
          else
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                for (final ref in visibleRefs)
                  Chip(
                    avatar: Icon(iconForRef(ref), size: 16),
                    label: Text(
                      labelForRef(ref, data),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (refs.length > visibleRefs.length)
                  Chip(label: Text('+${refs.length - visibleRefs.length}')),
              ],
            ),
        ],
      ),
    );
  }
}

enum _MetaValueType { text, number, boolean, file }

class _MetaDraft {
  String name;
  _MetaValueType type;
  String textValue;
  bool boolValue;

  _MetaDraft({
    required this.name,
    required this.type,
    this.textValue = '',
    this.boolValue = false,
  });
}

class _MetaDraftException implements Exception {
  final String messageKey;

  const _MetaDraftException(this.messageKey);
}

enum _LinkedCountRangeFilter { any, zero, oneToTwo, threeToFive, sixPlus }

enum _RoleUsageFilter { any, none, builtIn, custom }

enum _GlobalItemsSearchCategory { kind, unused, orphan, linked, roleUsage }

enum _OrgSearchCategory { kind, role, status, unit }

enum _OrgSearchFlag { hideParents, showParents }

class _OrgSearchSuggestion {
  final String label;
  final String tokenText;
  final bool appendSpace;
  final String? subtitle;

  const _OrgSearchSuggestion({
    required this.label,
    required this.tokenText,
    required this.appendSpace,
    this.subtitle,
  });
}

class _GlobalItemsSearchSuggestion {
  final String label;
  final String tokenText;
  final bool appendSpace;
  final String? subtitle;

  const _GlobalItemsSearchSuggestion({
    required this.label,
    required this.tokenText,
    required this.appendSpace,
    this.subtitle,
  });
}

class _OrgUnifiedSearchQuery {
  final List<String> terms;
  final SearchExpressionNode? expression;
  final Set<String> kindFilters;
  final Set<String> excludedKindFilters;
  final Set<String> roleFilters;
  final Set<String> excludedRoleFilters;
  final Set<String> statusFilters;
  final Set<String> excludedStatusFilters;
  final Set<String> unitFilters;
  final Set<String> excludedUnitFilters;
  final Set<_OrgSearchFlag> flags;
  final List<SearchFieldToken> structuredTokens;
  final String cacheKey;

  const _OrgUnifiedSearchQuery({
    required this.terms,
    required this.expression,
    required this.kindFilters,
    required this.excludedKindFilters,
    required this.roleFilters,
    required this.excludedRoleFilters,
    required this.statusFilters,
    required this.excludedStatusFilters,
    required this.unitFilters,
    required this.excludedUnitFilters,
    required this.flags,
    required this.structuredTokens,
    required this.cacheKey,
  });

  bool get hasStructuredFilters =>
      kindFilters.isNotEmpty ||
      excludedKindFilters.isNotEmpty ||
      roleFilters.isNotEmpty ||
      excludedRoleFilters.isNotEmpty ||
      statusFilters.isNotEmpty ||
      excludedStatusFilters.isNotEmpty ||
      unitFilters.isNotEmpty ||
      excludedUnitFilters.isNotEmpty ||
      flags.isNotEmpty;

  bool get hideParentContext =>
      flags.contains(_OrgSearchFlag.hideParents) &&
      !flags.contains(_OrgSearchFlag.showParents);

  bool get isEmpty => terms.isEmpty && !hasStructuredFilters;
}

class _GlobalItemsSearchQuery {
  final List<String> terms;
  final SearchExpressionNode? expression;
  final Set<_ItemKind> kindFilters;
  final Set<_ItemKind> excludedKindFilters;
  final bool? unusedOnly;
  final bool? orphanOnly;
  final _LinkedCountRangeFilter? linkedCountFilter;
  final Set<_LinkedCountRangeFilter> excludedLinkedCountFilters;
  final _RoleUsageFilter? roleUsageFilter;
  final Set<_RoleUsageFilter> excludedRoleUsageFilters;
  final List<SearchFieldToken> structuredTokens;

  const _GlobalItemsSearchQuery({
    required this.terms,
    required this.expression,
    required this.kindFilters,
    required this.excludedKindFilters,
    required this.unusedOnly,
    required this.orphanOnly,
    required this.linkedCountFilter,
    required this.excludedLinkedCountFilters,
    required this.roleUsageFilter,
    required this.excludedRoleUsageFilters,
    required this.structuredTokens,
  });

  bool get hasStructuredFilters =>
      kindFilters.isNotEmpty ||
      excludedKindFilters.isNotEmpty ||
      unusedOnly != null ||
      orphanOnly != null ||
      linkedCountFilter != null ||
      excludedLinkedCountFilters.isNotEmpty ||
      roleUsageFilter != null ||
      excludedRoleUsageFilters.isNotEmpty;
}

class _LocalizationLanguageChoice {
  final String code;
  final String name;

  const _LocalizationLanguageChoice({required this.code, required this.name});
}

class _LocalizationProviderModelChoice {
  final String id;
  final String label;
  final double usageMultiplier;

  const _LocalizationProviderModelChoice({
    required this.id,
    required this.label,
    required this.usageMultiplier,
  });
}

class _OrganizationToolLauncherAction {
  final IconData icon;
  final String label;
  final String subtitle;
  final Future<void> Function() onTap;

  const _OrganizationToolLauncherAction({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });
}

class _TreeData {
  static const builtInRoleKeys = <String>[
    'viewer',
    'member',
    'moderator',
    'admin',
  ];

  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> itemLinks;

  static Map<String, dynamic> _flattenItem(Map<String, dynamic> item) {
    final flattened = <String, dynamic>{...item};
    final details = item['details'];
    if (details is Map) {
      flattened.addAll(details.cast<String, dynamic>());
    }
    return flattened;
  }

  static bool _isKind(Map<String, dynamic> item, String kind) {
    return (item['kind'] ?? '').toString().trim().toLowerCase() == kind;
  }

  static bool _isActiveLink(Map<String, dynamic> link) {
    return link['active'] != false;
  }

  static bool _isDepartmentToSpaceLink(Map<String, dynamic> link) {
    final parentKind = (link['parent_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final childKind = (link['child_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return parentKind == 'department' && childKind == 'space';
  }

  static bool _isDepartmentToUserLink(Map<String, dynamic> link) {
    return _isItemLinkKind(link, parentKind: 'department', childKind: 'user');
  }

  static bool _isItemLinkKind(
    Map<String, dynamic> link, {
    required String parentKind,
    required String childKind,
  }) {
    final rawParentKind = (link['parent_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final rawChildKind = (link['child_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return rawParentKind == parentKind && rawChildKind == childKind;
  }

  static String _linkParentId(Map<String, dynamic> link) {
    return (link['parent_id'] ?? '').toString().trim();
  }

  static String _linkChildId(Map<String, dynamic> link) {
    return (link['child_id'] ?? '').toString().trim();
  }

  late final List<Map<String, dynamic>> activeItemLinks = itemLinks
      .where((link) => _isActiveLink(link))
      .toList(growable: false);

  late final List<Map<String, dynamic>> departmentSpaceLinks = activeItemLinks
      .where((link) => _isActiveLink(link) && _isDepartmentToSpaceLink(link))
      .toList(growable: false);

  late final List<Map<String, dynamic>> departmentUserLinks = activeItemLinks
      .where((link) => _isActiveLink(link) && _isDepartmentToUserLink(link))
      .toList(growable: false);

  late final List<Map<String, dynamic>> departmentDepartmentLinks =
      activeItemLinks
          .where(
            (link) => _isItemLinkKind(
              link,
              parentKind: 'department',
              childKind: 'department',
            ),
          )
          .toList(growable: false);

  late final List<Map<String, dynamic>> userUserLinks = activeItemLinks
      .where(
        (link) => _isItemLinkKind(link, parentKind: 'user', childKind: 'user'),
      )
      .toList(growable: false);

  late final List<Map<String, dynamic>> roleUserLinks = activeItemLinks
      .where(
        (link) => _isItemLinkKind(link, parentKind: 'role', childKind: 'user'),
      )
      .toList(growable: false);

  late final List<Map<String, dynamic>> units = items
      .where((item) => _isKind(item, 'department'))
      .map(_flattenItem)
      .toList(growable: false);

  late final List<Map<String, dynamic>> spaces = items
      .where((item) => _isKind(item, 'space'))
      .map(_flattenItem)
      .toList(growable: false);

  late final List<Map<String, dynamic>> users = items
      .where((item) => _isKind(item, 'user'))
      .map(_flattenItem)
      .toList(growable: false);

  late final List<Map<String, dynamic>> roleItems = items
      .where((item) => _isKind(item, 'role'))
      .map(_flattenItem)
      .toList(growable: false);

  late final List<Map<String, dynamic>> customRoles = roleItems
      .where((role) => role['built_in'] != true)
      .toList(growable: false);

  late final Map<String, Map<String, dynamic>> unitById = {
    for (final unit in units) (unit['id'] ?? '').toString(): unit,
  }..removeWhere((k, v) => k.isEmpty);

  late final Map<String, Map<String, dynamic>> spaceById = {
    for (final space in spaces) (space['id'] ?? '').toString(): space,
  }..removeWhere((k, v) => k.isEmpty);

  late final Map<String, Map<String, dynamic>> userById = {
    for (final user in users) (user['id'] ?? '').toString(): user,
  }..removeWhere((k, v) => k.isEmpty);

  late final Map<String, Map<String, dynamic>> roleByKey = {
    for (final key in builtInRoleKeys)
      key: <String, dynamic>{
        'id': key,
        'role_key': key,
        'name': key,
        'effective_level': key,
        'active': true,
        'built_in': true,
      },
    for (final role in roleItems)
      ((role['role_key'] ?? role['id'] ?? '').toString().trim().toLowerCase()):
          role,
  }..removeWhere((k, v) => k.isEmpty);

  late final Map<String, Set<String>> managerIdsByReport = () {
    final mapped = <String, Set<String>>{};
    for (final link in userUserLinks) {
      final report = _linkChildId(link);
      final manager = _linkParentId(link);
      if (report.isEmpty || manager.isEmpty) continue;
      mapped.putIfAbsent(report, () => <String>{}).add(manager);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> reportsByManager = () {
    final mapped = <String, Set<String>>{};
    for (final link in userUserLinks) {
      final report = _linkChildId(link);
      final manager = _linkParentId(link);
      if (report.isEmpty || manager.isEmpty) continue;
      mapped.putIfAbsent(manager, () => <String>{}).add(report);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> roleKeysByUser = () {
    final mapped = <String, Set<String>>{};
    for (final link in roleUserLinks) {
      final roleKey = _linkParentId(link).toLowerCase();
      final userId = _linkChildId(link);
      if (roleKey.isEmpty || userId.isEmpty) continue;
      mapped.putIfAbsent(userId, () => <String>{}).add(roleKey);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> usersByRoleKey = () {
    final mapped = <String, Set<String>>{};
    for (final entry in roleKeysByUser.entries) {
      final userId = entry.key;
      for (final roleKey in entry.value) {
        mapped.putIfAbsent(roleKey, () => <String>{}).add(userId);
      }
    }
    return mapped;
  }();

  late final Map<String, Set<String>> childUnitsByParent = () {
    final mapped = <String, Set<String>>{};
    for (final link in departmentDepartmentLinks) {
      final parentId = _linkParentId(link);
      final childId = _linkChildId(link);
      if (parentId.isEmpty || childId.isEmpty) continue;
      mapped.putIfAbsent(parentId, () => <String>{}).add(childId);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> parentUnitsByChildUnit = () {
    final mapped = <String, Set<String>>{};
    for (final link in departmentDepartmentLinks) {
      final parentId = _linkParentId(link);
      final childId = _linkChildId(link);
      if (parentId.isEmpty || childId.isEmpty) continue;
      mapped.putIfAbsent(childId, () => <String>{}).add(parentId);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> spacesByUnit = () {
    final mapped = <String, Set<String>>{};
    for (final link in departmentSpaceLinks) {
      final unitId = _linkParentId(link);
      final spaceId = _linkChildId(link);
      if (unitId.isEmpty || spaceId.isEmpty) continue;
      mapped.putIfAbsent(unitId, () => <String>{}).add(spaceId);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> unitsBySpace = () {
    final mapped = <String, Set<String>>{};
    for (final link in departmentSpaceLinks) {
      final unitId = _linkParentId(link);
      final spaceId = _linkChildId(link);
      if (unitId.isEmpty || spaceId.isEmpty) continue;
      mapped.putIfAbsent(spaceId, () => <String>{}).add(unitId);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> usersByUnit = () {
    final mapped = <String, Set<String>>{};
    for (final link in departmentUserLinks) {
      final unitId = _linkParentId(link);
      final userId = _linkChildId(link);
      if (unitId.isEmpty || userId.isEmpty) continue;
      mapped.putIfAbsent(unitId, () => <String>{}).add(userId);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> orgUnitsByUser = () {
    final mapped = <String, Set<String>>{};
    for (final link in departmentUserLinks) {
      final unitId = _linkParentId(link);
      final userId = _linkChildId(link);
      if (unitId.isEmpty || userId.isEmpty) continue;
      mapped.putIfAbsent(userId, () => <String>{}).add(unitId);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> ancestorUnitIdsByUnit = () {
    final mapped = <String, Set<String>>{};

    Set<String> collectAncestors(String unitId, [Set<String>? path]) {
      final cached = mapped[unitId];
      if (cached != null) return cached;
      final activePath = path ?? <String>{};
      if (activePath.contains(unitId)) {
        return <String>{unitId};
      }
      activePath.add(unitId);
      final chain = <String>{unitId};
      for (final parentId
          in parentUnitsByChildUnit[unitId] ?? const <String>{}) {
        chain.addAll(collectAncestors(parentId, activePath));
      }
      activePath.remove(unitId);
      mapped[unitId] = chain;
      return chain;
    }

    for (final unitId in unitById.keys) {
      collectAncestors(unitId);
    }
    return mapped;
  }();

  late final Map<String, Set<String>> spacesByUser = () {
    final mapped = <String, Set<String>>{};
    for (final user in users) {
      final userId = (user['id'] ?? '').toString();
      if (userId.isEmpty) continue;
      final userUnitIds = orgUnitsByUser[userId] ?? const <String>{};
      if (userUnitIds.isEmpty) continue;

      for (final link in departmentSpaceLinks) {
        final spaceId = _linkChildId(link);
        final linkedDepartmentId = _linkParentId(link);
        if (spaceId.isEmpty || linkedDepartmentId.isEmpty) continue;
        final inherit = link['inherit_to_descendants'] != false;
        final matches = userUnitIds.any((unitId) {
          if (unitId == linkedDepartmentId) return true;
          if (!inherit) return false;
          return ancestorUnitIdsByUnit[unitId]?.contains(linkedDepartmentId) ==
              true;
        });
        if (matches) {
          mapped.putIfAbsent(userId, () => <String>{}).add(spaceId);
        }
      }
    }
    return mapped;
  }();

  late final Map<String, Set<String>> usersBySpace = () {
    final mapped = <String, Set<String>>{};
    for (final entry in spacesByUser.entries) {
      final userId = entry.key;
      for (final spaceId in entry.value) {
        mapped.putIfAbsent(spaceId, () => <String>{}).add(userId);
      }
    }
    return mapped;
  }();

  _TreeData({required this.items, required this.itemLinks});
}
