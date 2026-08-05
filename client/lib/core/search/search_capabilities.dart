// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Search field capability definitions shared across structured-search screens.

enum SearchFieldValueType { text, enumeration, booleanValue, number, dateTime }

enum SearchFieldOperator {
  contains,
  equals,
  inList,
  greaterThan,
  greaterOrEqual,
  lessThan,
  lessOrEqual,
  boolEquals,
}

class SearchFieldCapability {
  final String key;
  final List<String> aliases;
  final SearchFieldValueType valueType;
  final List<SearchFieldOperator> operators;

  const SearchFieldCapability({
    required this.key,
    this.aliases = const <String>[],
    this.valueType = SearchFieldValueType.text,
    this.operators = const <SearchFieldOperator>[
      SearchFieldOperator.contains,
      SearchFieldOperator.equals,
    ],
  });

  bool matchesField(String raw) {
    final needle = raw.trim().toLowerCase();
    if (needle.isEmpty) return false;
    if (needle == key.toLowerCase()) return true;
    return aliases.any((alias) => alias.toLowerCase() == needle);
  }
}

class SearchFlagCapability {
  final String key;
  final List<String> aliases;
  final String descriptionLocalizationKey;

  const SearchFlagCapability({
    required this.key,
    this.aliases = const <String>[],
    required this.descriptionLocalizationKey,
  });

  bool matchesFlag(String raw) {
    final needle = raw.trim().toLowerCase();
    if (needle.isEmpty) return false;
    if (needle == key.toLowerCase()) return true;
    return aliases.any((alias) => alias.toLowerCase() == needle);
  }
}

class SearchSurfaceCapability {
  final String surfaceId;
  final List<SearchFieldCapability> fields;
  final List<SearchFlagCapability> flags;
  final List<String> examples;

  const SearchSurfaceCapability({
    required this.surfaceId,
    required this.fields,
    this.flags = const <SearchFlagCapability>[],
    this.examples = const <String>[],
  });

  SearchFieldCapability? findField(String rawField) {
    for (final field in fields) {
      if (field.matchesField(rawField)) {
        return field;
      }
    }
    return null;
  }

  SearchFlagCapability? findFlag(String rawFlag) {
    for (final flag in flags) {
      if (flag.matchesFlag(rawFlag)) {
        return flag;
      }
    }
    return null;
  }
}

const SearchFlagCapability searchFlagHideParents = SearchFlagCapability(
  key: 'hide-parents',
  aliases: <String>['hide-parent', 'flat', 'only-matches'],
  descriptionLocalizationKey: 'search_flag_hide_parents_help',
);

const SearchFlagCapability searchFlagShowParents = SearchFlagCapability(
  key: 'show-parents',
  aliases: <String>['show-parent', 'with-parents', 'keep-parents'],
  descriptionLocalizationKey: 'search_flag_show_parents_help',
);

const SearchSurfaceCapability spacesSearchCapability = SearchSurfaceCapability(
  surfaceId: 'spaces',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(key: 'name', aliases: <String>['title']),
    SearchFieldCapability(key: 'slug'),
    SearchFieldCapability(
      key: 'id',
      aliases: <String>['space', 'spaceid', 'space_id'],
    ),
    SearchFieldCapability(
      key: 'members',
      aliases: <String>['member', 'count'],
      valueType: SearchFieldValueType.number,
      operators: <SearchFieldOperator>[
        SearchFieldOperator.contains,
        SearchFieldOperator.equals,
        SearchFieldOperator.greaterThan,
        SearchFieldOperator.greaterOrEqual,
        SearchFieldOperator.lessThan,
        SearchFieldOperator.lessOrEqual,
      ],
    ),
  ],
  examples: <String>[
    'ops @slug:platform',
    '@name:"customer support" -@members:0',
  ],
);

const SearchSurfaceCapability tasksSearchCapability = SearchSurfaceCapability(
  surfaceId: 'tasks',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(key: 'status', aliases: <String>['state']),
    SearchFieldCapability(key: 'priority', aliases: <String>['prio']),
    SearchFieldCapability(
      key: 'source',
      aliases: <String>['source_kind', 'linked_to'],
    ),
    SearchFieldCapability(
      key: 'space',
      aliases: <String>['space_id', 'spaces', 'spaceid'],
    ),
  ],
  examples: <String>[
    'rollout AND @status:blocked',
    '(@priority:critical OR @priority:high) AND @space:ops',
  ],
);

const SearchSurfaceCapability mediaSearchCapability = SearchSurfaceCapability(
  surfaceId: 'media',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(
      key: 'tags',
      aliases: <String>['tag', 'label', 'labels'],
    ),
    SearchFieldCapability(
      key: 'folders',
      aliases: <String>['folder', 'path', 'folder_path'],
    ),
    SearchFieldCapability(
      key: 'spaces',
      aliases: <String>['space', 'scope', 'space_id'],
    ),
    SearchFieldCapability(
      key: 'usage',
      aliases: <String>['type', 'types', 'kind'],
    ),
    SearchFieldCapability(key: 'flag', aliases: <String>['flags']),
  ],
  flags: <SearchFlagCapability>[searchFlagHideParents, searchFlagShowParents],
  examples: <String>[
    '@tags:branding AND (@usage:login OR @spaces:global)',
    '@tags:branding AND @flag:hide-parents',
    'logo AND NOT @folders:archive',
  ],
);

const SearchSurfaceCapability backupsSearchCapability = SearchSurfaceCapability(
  surfaceId: 'backups',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(
      key: 'mode',
      aliases: <String>['modes', 'type', 'types'],
    ),
    SearchFieldCapability(
      key: 'id',
      aliases: <String>['snapshot', 'snapshots'],
    ),
    SearchFieldCapability(
      key: 'created',
      aliases: <String>['date', 'time'],
      valueType: SearchFieldValueType.dateTime,
      operators: <SearchFieldOperator>[
        SearchFieldOperator.contains,
        SearchFieldOperator.equals,
        SearchFieldOperator.greaterThan,
        SearchFieldOperator.greaterOrEqual,
        SearchFieldOperator.lessThan,
        SearchFieldOperator.lessOrEqual,
      ],
    ),
  ],
  examples: <String>[
    '@mode:full XOR @mode:incremental',
    '@created:2026 AND NOT @id:"seed snapshot"',
  ],
);

const SearchSurfaceCapability orgTreeSearchCapability = SearchSurfaceCapability(
  surfaceId: 'organization_tree',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(
      key: 'kind',
      aliases: <String>['kinds', 'type', 'types', 'item', 'items'],
    ),
    SearchFieldCapability(key: 'role', aliases: <String>['roles']),
    SearchFieldCapability(key: 'status', aliases: <String>['state']),
    SearchFieldCapability(
      key: 'unit',
      aliases: <String>['units', 'dept', 'department', 'departments'],
    ),
    SearchFieldCapability(key: 'spaces', aliases: <String>['space']),
    SearchFieldCapability(key: 'users', aliases: <String>['user']),
    SearchFieldCapability(key: 'departments', aliases: <String>['department']),
    SearchFieldCapability(key: 'regions', aliases: <String>['region']),
    SearchFieldCapability(key: 'stores', aliases: <String>['store']),
    SearchFieldCapability(key: 'teams', aliases: <String>['team']),
    SearchFieldCapability(key: 'flag', aliases: <String>['flags']),
  ],
  flags: <SearchFlagCapability>[searchFlagHideParents, searchFlagShowParents],
  examples: <String>[
    '@regions:east AND @status:active',
    '@role:shift_lead AND @flag:hide-parents',
    '(@spaces:ops OR @users:alex) NOR @status:inactive',
  ],
);

const SearchSurfaceCapability
globalItemsSearchCapability = SearchSurfaceCapability(
  surfaceId: 'global_items',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(
      key: 'kind',
      aliases: <String>['kinds', 'type', 'types', 'item', 'items'],
    ),
    SearchFieldCapability(key: 'spaces', aliases: <String>['space']),
    SearchFieldCapability(key: 'users', aliases: <String>['user']),
    SearchFieldCapability(key: 'departments', aliases: <String>['department']),
    SearchFieldCapability(key: 'roles', aliases: <String>['role']),
    SearchFieldCapability(
      key: 'unused',
      aliases: <String>['unused_only', 'unlinked'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'orphan',
      aliases: <String>['orphan_only'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'linked',
      aliases: <String>['links', 'linked_count'],
      valueType: SearchFieldValueType.number,
      operators: <SearchFieldOperator>[
        SearchFieldOperator.equals,
        SearchFieldOperator.inList,
      ],
    ),
    SearchFieldCapability(
      key: 'roleusage',
      aliases: <String>['role_usage', 'roleusagefilter', 'role_usage_filter'],
      valueType: SearchFieldValueType.enumeration,
      operators: <SearchFieldOperator>[SearchFieldOperator.equals],
    ),
  ],
  examples: <String>[
    '@spaces AND @unused:true XOR @roleusage:custom',
    '@kind:user AND NOT @linked:0',
  ],
);

const SearchSurfaceCapability kbSearchCapability = SearchSurfaceCapability(
  surfaceId: 'kb',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(key: 'status', aliases: <String>['state']),
    SearchFieldCapability(key: 'tag', aliases: <String>['tags']),
    SearchFieldCapability(
      key: 'folder',
      aliases: <String>['folder_id', 'path'],
    ),
    SearchFieldCapability(
      key: 'stale',
      aliases: <String>['needs_review'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'trash',
      aliases: <String>['deleted'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
  ],
  examples: <String>[
    'runbook AND @status:published AND NOT @trash:true',
    '@tag:incident OR @folder:oncall',
  ],
);

const SearchSurfaceCapability sopSearchCapability = SearchSurfaceCapability(
  surfaceId: 'sop',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(key: 'status', aliases: <String>['state']),
    SearchFieldCapability(
      key: 'archived',
      aliases: <String>['archive'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'review',
      aliases: <String>['needs_review'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'run',
      aliases: <String>['last_run', 'recently_run'],
    ),
    SearchFieldCapability(
      key: 'task',
      aliases: <String>['tasks', 'linked_work', 'follow_up'],
    ),
  ],
  examples: <String>[
    'deploy AND @status:published',
    '@review:true OR @run:recent',
  ],
);

const SearchSurfaceCapability incidentsSearchCapability =
    SearchSurfaceCapability(
      surfaceId: 'incidents',
      fields: <SearchFieldCapability>[
        SearchFieldCapability(key: 'status', aliases: <String>['state']),
        SearchFieldCapability(key: 'severity', aliases: <String>['sev', 's']),
        SearchFieldCapability(
          key: 'archived',
          aliases: <String>['archive'],
          valueType: SearchFieldValueType.booleanValue,
          operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
        ),
        SearchFieldCapability(
          key: 'task',
          aliases: <String>['tasks', 'linked_work', 'follow_up'],
        ),
      ],
      examples: <String>[
        '@severity:1 OR @status:open',
        '(@status:open OR @status:monitoring) AND @task:linked',
      ],
    );

const SearchSurfaceCapability
workspaceSearchCapability = SearchSurfaceCapability(
  surfaceId: 'space_workspace',
  fields: <SearchFieldCapability>[
    SearchFieldCapability(
      key: 'type',
      aliases: <String>['types', 'category', 'kind', 'item', 'items'],
    ),
    SearchFieldCapability(key: 'status', aliases: <String>['state']),
    SearchFieldCapability(
      key: 'folder',
      aliases: <String>['path', 'folder_id'],
    ),
    SearchFieldCapability(key: 'tag', aliases: <String>['tags']),
    SearchFieldCapability(
      key: 'stale',
      aliases: <String>['needs_review'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'review',
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'severity',
      aliases: <String>['sev', 's'],
      valueType: SearchFieldValueType.number,
      operators: <SearchFieldOperator>[
        SearchFieldOperator.contains,
        SearchFieldOperator.equals,
        SearchFieldOperator.greaterThan,
        SearchFieldOperator.greaterOrEqual,
        SearchFieldOperator.lessThan,
        SearchFieldOperator.lessOrEqual,
      ],
    ),
    SearchFieldCapability(key: 'run', aliases: <String>['runs', 'run_state']),
    SearchFieldCapability(
      key: 'source',
      aliases: <String>['source_kind', 'linked_to'],
    ),
    SearchFieldCapability(
      key: 'archived',
      aliases: <String>['archive'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'linked',
      aliases: <String>['task', 'tasks', 'linked_work'],
      valueType: SearchFieldValueType.booleanValue,
      operators: <SearchFieldOperator>[SearchFieldOperator.boolEquals],
    ),
    SearchFieldCapability(
      key: 'sort',
      aliases: <String>['order'],
      valueType: SearchFieldValueType.enumeration,
      operators: <SearchFieldOperator>[SearchFieldOperator.equals],
    ),
  ],
  examples: <String>[
    '@type:kb @stale:true',
    '(@type:incident AND @status:monitoring) OR (@type:sop AND @run:overdue)',
    '@folder:"/Billing" AND @sort:updated',
  ],
);

const SearchSurfaceCapability shellQuickNavSearchCapability =
    SearchSurfaceCapability(
      surfaceId: 'shell_quick_nav',
      fields: <SearchFieldCapability>[
        SearchFieldCapability(key: 'label', aliases: <String>['name', 'title']),
        SearchFieldCapability(
          key: 'path',
          aliases: <String>['route', 'subtitle'],
        ),
      ],
      examples: <String>[
        'settings OR @path:/organization',
        '@label:tasks AND NOT @path:/legacy',
      ],
    );
