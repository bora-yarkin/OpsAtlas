// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Space directory screen and structured-search state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/api/auth_store.dart';
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

/// Builds shared search query parameters for the spaces list endpoint.
Map<String, dynamic> _spacesSearchQueryParameters(String query) {
  final normalized = normalizeSearchInput(query);
  if (normalized.isEmpty) {
    return const <String, dynamic>{};
  }
  return <String, dynamic>{
    'q': normalized,
    'search_ast': encodeSearchAstParamFromRawQuery(normalized),
  };
}

/// Loads the accessible spaces list, optionally filtered by structured search.
final spacesProvider = FutureProvider.family<List<dynamic>, String>((
  ref,
  query,
) async {
  final api = ref.watch(apiClientProvider);
  final queryParameters = _spacesSearchQueryParameters(query);
  final r = await api.dio.get(
    '/spaces',
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  );
  return r.data as List<dynamic>;
});

enum _SpacesSearchCategory { name, slug, id, members }

class _SpacesSearchSuggestion {
  final String label;
  final String tokenText;
  final bool appendSpace;
  final String? subtitle;

  const _SpacesSearchSuggestion({
    required this.label,
    required this.tokenText,
    required this.appendSpace,
    this.subtitle,
  });
}

/// Parsed structured-search model used by the spaces screen.
class _SpacesSearchQuery {
  final List<String> terms;
  final SearchExpressionNode? expression;
  final List<SearchParseDiagnostic> diagnostics;
  final Set<String> nameFilters;
  final Set<String> excludedNameFilters;
  final Set<String> slugFilters;
  final Set<String> excludedSlugFilters;
  final Set<String> idFilters;
  final Set<String> excludedIdFilters;
  final Set<String> membersFilters;
  final Set<String> excludedMembersFilters;
  final List<SearchFieldToken> structuredTokens;

  const _SpacesSearchQuery({
    required this.terms,
    required this.expression,
    required this.diagnostics,
    required this.nameFilters,
    required this.excludedNameFilters,
    required this.slugFilters,
    required this.excludedSlugFilters,
    required this.idFilters,
    required this.excludedIdFilters,
    required this.membersFilters,
    required this.excludedMembersFilters,
    required this.structuredTokens,
  });

  bool get hasStructuredFilters =>
      nameFilters.isNotEmpty ||
      excludedNameFilters.isNotEmpty ||
      slugFilters.isNotEmpty ||
      excludedSlugFilters.isNotEmpty ||
      idFilters.isNotEmpty ||
      excludedIdFilters.isNotEmpty ||
      membersFilters.isNotEmpty ||
      excludedMembersFilters.isNotEmpty;

  bool get isEmpty => terms.isEmpty && !hasStructuredFilters;
}

/// Space directory screen that acts as the launch point into workspaces.
class SpacesScreen extends ConsumerStatefulWidget {
  final String? initialSearchQuery;

  const SpacesScreen({super.key, this.initialSearchQuery});

  @override
  ConsumerState<SpacesScreen> createState() => _SpacesScreenState();
}

class _SpacesScreenState extends ConsumerState<SpacesScreen> {
  static const _queryPrefsKey = 'spaces_screen_query';
  static const _searchSurfaceId = 'spaces';

  final _queryCtrl = TextEditingController();
  final _savedViewNameCtrl = TextEditingController();
  bool _prefsLoaded = false;
  List<String> _recentQueries = const <String>[];
  List<SearchSavedView> _savedViews = const <SearchSavedView>[];
  String _lastTrackedResultSignature = '';

  @override
  void initState() {
    super.initState();
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

  Future<void> _loadSearchState() async {
    final sp = await SharedPreferences.getInstance();
    final routeQuery = normalizeSearchInput(widget.initialSearchQuery ?? '');
    final persisted = normalizeSearchInput(sp.getString(_queryPrefsKey) ?? '');
    final effective = routeQuery.isNotEmpty ? routeQuery : persisted;
    final recent = await SearchStateStore.loadRecentQueries(_searchSurfaceId);
    final views = await SearchStateStore.loadSavedViews(_searchSurfaceId);
    if (!mounted) return;
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
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_queryPrefsKey, normalized);

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
      path: '/spaces',
      queryParameters: nextParams.isEmpty ? null : nextParams,
    );
    if (current.path != nextUri.path || current.query != nextUri.query) {
      context.replace(nextUri.toString());
    }
  }

  Future<void> _rememberCurrentQuery() async {
    final normalized = normalizeSearchInput(_queryCtrl.text);
    if (normalized.isEmpty) return;
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
    final normalized = normalizeSearchInput(view.query);
    _queryCtrl.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
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

  void _trackQueryResults(int resultCount) {
    final normalized = normalizeSearchInput(_queryCtrl.text);
    if (normalized.isEmpty) {
      _lastTrackedResultSignature = '';
      return;
    }
    final signature = '$normalized|$resultCount';
    if (_lastTrackedResultSignature == signature) {
      return;
    }
    _lastTrackedResultSignature = signature;

    final diagnostics = validateSearchQueryAst(
      parseSearchQueryAst(normalized),
      capability: spacesSearchCapability,
    ).diagnostics;

    trackSearchEvent(
      ref,
      eventType: 'search_query_issued',
      surface: 'spaces',
      query: normalized,
      path: '/spaces',
      entityType: 'space',
      extraMeta: <String, Object?>{
        'diagnostics_count': diagnostics.length,
        'diagnostic_codes': diagnostics.map((d) => d.code).toList(),
      },
    );
    trackSearchEvent(
      ref,
      eventType: resultCount > 0 ? 'search_results_shown' : 'search_no_result',
      surface: 'spaces',
      query: normalized,
      path: '/spaces',
      entityType: 'space',
      results: resultCount,
    );
  }

  _SpacesSearchCategory? _normalizeSearchCategory(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'name' || 'title' => _SpacesSearchCategory.name,
      'slug' => _SpacesSearchCategory.slug,
      'id' || 'space' || 'spaceid' || 'space_id' => _SpacesSearchCategory.id,
      'members' || 'member' || 'count' => _SpacesSearchCategory.members,
      _ => null,
    };
  }

  String _searchCategoryToken(_SpacesSearchCategory category) {
    return switch (category) {
      _SpacesSearchCategory.name => 'name',
      _SpacesSearchCategory.slug => 'slug',
      _SpacesSearchCategory.id => 'id',
      _SpacesSearchCategory.members => 'members',
    };
  }

  String _searchCategoryLabel(
    _SpacesSearchCategory category,
    AppLocalizations l10n,
  ) {
    return switch (category) {
      _SpacesSearchCategory.name => l10n.text('name'),
      _SpacesSearchCategory.slug => l10n.text('slug'),
      _SpacesSearchCategory.id => 'ID',
      _SpacesSearchCategory.members => l10n.text('members'),
    };
  }

  _SpacesSearchQuery _parseSearchQuery(String raw) {
    final ast = parseSearchQueryAst(raw);
    final validation = validateSearchQueryAst(
      ast,
      capability: spacesSearchCapability,
    );
    final nameFilters = <String>{};
    final excludedNameFilters = <String>{};
    final slugFilters = <String>{};
    final excludedSlugFilters = <String>{};
    final idFilters = <String>{};
    final excludedIdFilters = <String>{};
    final membersFilters = <String>{};
    final excludedMembersFilters = <String>{};
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
        case _SpacesSearchCategory.name:
          if (token.isNegated) {
            excludedNameFilters.add(value);
          } else {
            nameFilters.add(value);
          }
          break;
        case _SpacesSearchCategory.slug:
          if (token.isNegated) {
            excludedSlugFilters.add(value);
          } else {
            slugFilters.add(value);
          }
          break;
        case _SpacesSearchCategory.id:
          if (token.isNegated) {
            excludedIdFilters.add(value);
          } else {
            idFilters.add(value);
          }
          break;
        case _SpacesSearchCategory.members:
          if (token.isNegated) {
            excludedMembersFilters.add(value);
          } else {
            membersFilters.add(value);
          }
          break;
      }
    }

    return _SpacesSearchQuery(
      terms: ast.normalizedTerms,
      expression: ast.expression,
      diagnostics: validation.diagnostics,
      nameFilters: nameFilters,
      excludedNameFilters: excludedNameFilters,
      slugFilters: slugFilters,
      excludedSlugFilters: excludedSlugFilters,
      idFilters: idFilters,
      excludedIdFilters: excludedIdFilters,
      membersFilters: membersFilters,
      excludedMembersFilters: excludedMembersFilters,
      structuredTokens: structuredTokens,
    );
  }

  bool _matchesSearchQuery(
    Map<String, dynamic> space,
    _SpacesSearchQuery query,
  ) {
    if (query.isEmpty) {
      return true;
    }

    final name = (space['name'] ?? '').toString().toLowerCase();
    final slug = (space['slug'] ?? '').toString().toLowerCase();
    final id = (space['id'] ?? '').toString().toLowerCase();
    final members = (space['member_count'] ?? '').toString().toLowerCase();
    final openTasks = (space['open_task_count'] ?? '').toString().toLowerCase();
    final incidents = (space['active_incident_count'] ?? '')
        .toString()
        .toLowerCase();
    final text = '$name $slug $id $members $openTasks $incidents';

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
          _SpacesSearchCategory.name => name.contains(value),
          _SpacesSearchCategory.slug => slug.contains(value),
          _SpacesSearchCategory.id => id.contains(value),
          _SpacesSearchCategory.members => members.contains(value),
        };
        return token.isNegated ? !baseMatch : baseMatch;
      },
      matchesText: (token) => text.contains(token.normalizedValue),
    );
  }

  List<_SpacesSearchSuggestion> _searchSuggestions(
    AppLocalizations l10n,
    List<Map<String, dynamic>> spaces,
  ) {
    final context = parseAtTokenSuggestionContext(_queryCtrl.text);
    if (context == null) {
      return _recentQueries
          .take(6)
          .map(
            (query) => _SpacesSearchSuggestion(
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
        return _searchValueSuggestions(
          category: category,
          partialLower: '',
          spaces: spaces,
          l10n: l10n,
        );
      }

      final partial = context.partialFieldLower;
      return _SpacesSearchCategory.values
          .where((category) {
            final token = _searchCategoryToken(category);
            final label = _searchCategoryLabel(category, l10n).toLowerCase();
            if (partial.isEmpty) {
              return true;
            }
            return token.contains(partial) || label.contains(partial);
          })
          .map(
            (category) => _SpacesSearchSuggestion(
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
      return const <_SpacesSearchSuggestion>[];
    }
    return _searchValueSuggestions(
      category: category,
      partialLower: context.partialValueLower,
      spaces: spaces,
      l10n: l10n,
    );
  }

  List<_SpacesSearchSuggestion> _searchValueSuggestions({
    required _SpacesSearchCategory category,
    required String partialLower,
    required List<Map<String, dynamic>> spaces,
    required AppLocalizations l10n,
  }) {
    switch (category) {
      case _SpacesSearchCategory.name:
        return spaces
            .map((space) => (space['name'] ?? '').toString().trim())
            .where((value) => value.isNotEmpty)
            .where((value) => value.toLowerCase().contains(partialLower))
            .toSet()
            .take(8)
            .map(
              (value) => _SpacesSearchSuggestion(
                label: value,
                tokenText: '@name:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _SpacesSearchCategory.slug:
        return spaces
            .map((space) => (space['slug'] ?? '').toString().trim())
            .where((value) => value.isNotEmpty)
            .where((value) => value.toLowerCase().contains(partialLower))
            .toSet()
            .take(8)
            .map(
              (value) => _SpacesSearchSuggestion(
                label: value,
                tokenText: '@slug:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _SpacesSearchCategory.id:
        return spaces
            .map((space) => (space['id'] ?? '').toString().trim())
            .where((value) => value.isNotEmpty)
            .where((value) => value.toLowerCase().contains(partialLower))
            .toSet()
            .take(8)
            .map(
              (value) => _SpacesSearchSuggestion(
                label: value,
                tokenText: '@id:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _SpacesSearchCategory.members:
        final values =
            spaces
                .map((space) => (space['member_count'] ?? '').toString().trim())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList(growable: false)
              ..sort((a, b) => a.compareTo(b));
        return values
            .where((value) => value.toLowerCase().contains(partialLower))
            .take(8)
            .map(
              (value) => _SpacesSearchSuggestion(
                label: '${l10n.text('members')}: $value',
                tokenText: '@members:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
    }
  }

  String _encodeSearchTokenValue(String value) {
    return value.contains(' ') ? '"$value"' : value;
  }

  void _applySearchSuggestion(_SpacesSearchSuggestion suggestion) {
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
    trackSearchSuggestionAccepted(
      ref,
      surface: 'spaces',
      query: currentQuery,
      nextQuery: nextText,
      path: '/spaces',
      entityType: 'space',
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

  Future<void> _createSpace(BuildContext context) async {
    final api = ref.read(apiClientProvider);
    final l10n = AppLocalizations.of(context);
    final nameCtrl = TextEditingController();
    final slugCtrl = TextEditingController();
    String? error;

    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(l10n.text('create_space')),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(labelText: l10n.text('name')),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: slugCtrl,
                      decoration: InputDecoration(labelText: l10n.text('slug')),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          slugCtrl.text = _slugify(nameCtrl.text);
                          setDialogState(() => error = null);
                        },
                        icon: const Icon(Icons.auto_fix_high),
                        label: Text(l10n.text('generate_slug')),
                      ),
                    ),
                    if (error != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(dialogContext).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(l10n.text('cancel')),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    final slug = slugCtrl.text.trim().isEmpty
                        ? _slugify(name)
                        : slugCtrl.text.trim();
                    if (name.isEmpty || slug.isEmpty) {
                      setDialogState(
                        () => error = l10n.text('name_and_slug_required'),
                      );
                      return;
                    }
                    try {
                      await api.dio.post(
                        '/spaces',
                        data: <String, dynamic>{'name': name, 'slug': slug},
                      );
                      if (!dialogContext.mounted) return;
                      Navigator.pop(dialogContext, true);
                    } catch (e) {
                      setDialogState(() => error = _errorText(e));
                    }
                  },
                  child: Text(l10n.text('create')),
                ),
              ],
            );
          },
        );
      },
    );

    nameCtrl.dispose();
    slugCtrl.dispose();

    if (created == true) {
      final normalized = normalizeSearchInput(_queryCtrl.text);
      ref.invalidate(spacesProvider(normalized));
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.text('space_created'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = ref.watch(authStoreProvider);
    final normalizedQuery = normalizeSearchInput(_queryCtrl.text);
    final spacesAsync = ref.watch(spacesProvider(normalizedQuery));

    return AtlasCompactPageFrame(
      title: l10n.text('spaces'),
      actions: <Widget>[
        OutlinedButton.icon(
          onPressed: () => ref.invalidate(spacesProvider(normalizedQuery)),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.text('refresh')),
        ),
        if (auth.isAdminLike)
          FilledButton.icon(
            onPressed: () => _createSpace(context),
            icon: const Icon(Icons.add_business_outlined),
            label: Text(l10n.text('create_space')),
          ),
      ],
      child: spacesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AtlasEmptyState(
          icon: Icons.error_outline,
          title: l10n.text('failed_to_load_spaces'),
          subtitle: error.toString(),
        ),
        data: (raw) {
          final spaces = raw
              .cast<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
          final parsedQuery = _parseSearchQuery(_queryCtrl.text);
          final filtered = spaces
              .where((space) => _matchesSearchQuery(space, parsedQuery))
              .toList(growable: false);
          _trackQueryResults(filtered.length);
          final suggestions = _searchSuggestions(l10n, spaces);

          if (spaces.isEmpty) {
            return AtlasEmptyState(
              icon: Icons.hub_outlined,
              title: l10n.text('no_spaces_found'),
              action: auth.isAdminLike
                  ? FilledButton.icon(
                      onPressed: () => _createSpace(context),
                      icon: const Icon(Icons.add_business_outlined),
                      label: Text(l10n.text('create_space')),
                    )
                  : null,
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: AtlasPanel(
                  title: l10n.text('spaces_directory'),
                  subtitle:
                      '${filtered.length} ${l10n.text('matching')} • ${spaces.length} ${l10n.text('total_spaces')}',
                  trailing: Wrap(
                    spacing: AppSpacing.xs,
                    children: <Widget>[
                      SearchHowToButton(capability: spacesSearchCapability),
                      IconButton(
                        tooltip: l10n.text('save_view'),
                        onPressed: _queryCtrl.text.trim().isEmpty
                            ? null
                            : () {
                                _savedViewNameCtrl.text = '';
                                _openSavedViewsDialog(l10n);
                              },
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: l10n.text('load_saved_view'),
                        onPressed: () => _openSavedViewsDialog(l10n),
                        icon: const Icon(Icons.bookmark_outline),
                      ),
                    ],
                  ),
                  expandChild: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
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
                              capability: spacesSearchCapability,
                            ),
                            suffixIcon: _queryCtrl.text.trim().isEmpty
                                ? null
                                : IconButton(
                                    tooltip: l10n.text('clear_search'),
                                    onPressed: () =>
                                        setState(() => _queryCtrl.clear()),
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                        ),
                      ),
                      if (parsedQuery.structuredTokens.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: <Widget>[
                            for (final token in parsedQuery.structuredTokens)
                              InputChip(
                                label: Text(token.toChipLabel()),
                                onDeleted: () =>
                                    _removeStructuredSearchToken(token),
                              ),
                          ],
                        ),
                      ],
                      if (parseAtTokenSuggestionContext(_queryCtrl.text) !=
                              null &&
                          suggestions.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Material(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: suggestions.length,
                              itemBuilder: (context, index) {
                                final suggestion = suggestions[index];
                                return Material(
                                  color: Colors.transparent,
                                  child: ListTile(
                                    dense: true,
                                    title: Text(suggestion.label),
                                    subtitle: suggestion.subtitle == null
                                        ? null
                                        : Text(suggestion.subtitle!),
                                    onTap: () =>
                                        _applySearchSuggestion(suggestion),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                      if (parsedQuery.diagnostics.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        SearchDiagnosticsList(
                          diagnostics: parsedQuery.diagnostics,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      Expanded(
                        child: filtered.isEmpty
                            ? AtlasEmptyState(
                                icon: Icons.search_off,
                                title: l10n.text('no_spaces_found'),
                                action: parsedQuery.isEmpty
                                    ? null
                                    : OutlinedButton.icon(
                                        onPressed: () =>
                                            setState(() => _queryCtrl.clear()),
                                        icon: const Icon(Icons.clear_all),
                                        label: Text(l10n.text('clear_search')),
                                      ),
                              )
                            : ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final space = filtered[index];
                                  final id = (space['id'] ?? '').toString();
                                  final name = (space['name'] ?? '').toString();
                                  final slug = (space['slug'] ?? '').toString();
                                  return Material(
                                    color: Colors.transparent,
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: AppSpacing.xs,
                                            vertical: AppSpacing.xs,
                                          ),
                                      leading: Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.hub_outlined,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onPrimaryContainer,
                                        ),
                                      ),
                                      title: Text(name.isEmpty ? slug : name),
                                      subtitle: slug.trim().isEmpty
                                          ? null
                                          : Text(slug),
                                      trailing: IconButton(
                                        tooltip: l10n.text(
                                          'open_space_section',
                                        ),
                                        onPressed: () => atlasOpenRoute(
                                          context,
                                          '/spaces/$id',
                                        ),
                                        icon: const Icon(
                                          Icons.arrow_forward_ios_rounded,
                                          size: 18,
                                        ),
                                      ),
                                      onTap: () => atlasOpenRoute(
                                        context,
                                        '/spaces/$id',
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _slugify(String input) {
    final normalized = input.toLowerCase().trim().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '-',
    );
    return normalized
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _errorText(Object error) {
    return requestErrorMessage(error, context: context);
  }
}
