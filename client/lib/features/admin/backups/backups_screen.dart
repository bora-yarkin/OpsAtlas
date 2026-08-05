// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Administrative backups screen for listing and creating snapshots.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/mfa_guard.dart';
import '../../../core/api/request_error.dart';
import '../../../core/command_palette.dart';
import '../../../core/i18n/app_localizations.dart';
import '../../../core/search/query_ast.dart';
import '../../../core/search/search_capabilities.dart';
import '../../../core/search/search_diagnostics_widget.dart';
import '../../../core/search/search_help.dart';
import '../../../core/search/search_state.dart';
import '../../../core/search/search_validation.dart';
import '../../../core/theme/theme.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/atlas_ui.dart';

final snapshotsProvider = FutureProvider<List<dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final response = await api.dio.get('/admin/backups/snapshots');
  final data = (response.data as Map).cast<String, dynamic>();
  return data['snapshots'] as List<dynamic>;
});

class BackupsScreen extends ConsumerStatefulWidget {
  final String? initialSearchQuery;

  const BackupsScreen({super.key, this.initialSearchQuery});

  @override
  ConsumerState<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends ConsumerState<BackupsScreen> {
  static const String _searchSurfaceId = 'admin_backups';
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _savedViewNameCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final Set<String> _collapsedGroupKeys = <String>{
    _SnapshotGroup.fullKey,
    _SnapshotGroup.incrementalKey,
    _SnapshotGroup.otherKey,
  };
  List<String> _recentQueries = const <String>[];
  List<SearchSavedView> _savedViews = const <SearchSavedView>[];

  void _handleSearchChanged() {
    if (!mounted) return;
    setState(() {});
    _syncSearchRoute();
  }

  Future<void> _loadSearchState() async {
    final recent = await SearchStateStore.loadRecentQueries(_searchSurfaceId);
    final views = await SearchStateStore.loadSavedViews(_searchSurfaceId);
    if (!mounted) return;
    setState(() {
      _recentQueries = recent;
      _savedViews = views;
    });
  }

  Future<void> _rememberCurrentQuery() async {
    final normalized = normalizeSearchInput(_searchCtrl.text);
    if (normalized.isEmpty) return;
    await SearchStateStore.rememberQuery(_searchSurfaceId, normalized);
    final recent = await SearchStateStore.loadRecentQueries(_searchSurfaceId);
    if (!mounted) return;
    setState(() => _recentQueries = recent);
  }

  Future<void> _saveCurrentQueryView() async {
    final name = _savedViewNameCtrl.text.trim();
    final query = normalizeSearchInput(_searchCtrl.text);
    if (name.isEmpty || query.isEmpty) return;
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
    _searchCtrl.value = TextEditingValue(
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
                          if (!mounted) return;
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
                                  if (!mounted) return;
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

  void _syncSearchRoute() {
    if (!mounted) return;
    final state = GoRouterState.of(context);
    final current = state.uri;
    final params = Map<String, String>.from(current.queryParameters);
    final normalized = normalizeSearchInput(_searchCtrl.text);
    if (normalized.isEmpty) {
      params.remove('search');
    } else {
      params['search'] = normalized;
    }
    final nextUri = Uri(
      path: '/organization/backups',
      queryParameters: params.isEmpty ? null : params,
    );
    if (current.path != nextUri.path || current.query != nextUri.query) {
      context.replace(nextUri.toString());
    }
  }

  @override
  void initState() {
    super.initState();
    final initialQuery = normalizeSearchInput(widget.initialSearchQuery ?? '');
    if (initialQuery.isNotEmpty) {
      _searchCtrl.text = initialQuery;
    }
    _searchCtrl.addListener(_handleSearchChanged);
    _searchFocusNode.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
    _loadSearchState();
  }

  @override
  void didUpdateWidget(covariant BackupsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = normalizeSearchInput(oldWidget.initialSearchQuery ?? '');
    final next = normalizeSearchInput(widget.initialSearchQuery ?? '');
    if (next == previous) return;
    final current = normalizeSearchInput(_searchCtrl.text);
    if (next == current) return;
    _searchCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  @override
  void dispose() {
    _searchCtrl
      ..removeListener(_handleSearchChanged)
      ..dispose();
    _savedViewNameCtrl.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _refreshSnapshots() {
    _rememberCurrentQuery();
    ref.invalidate(snapshotsProvider);
  }

  void _goBackToOrganization() {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/organization');
  }

  Future<void> _createSnapshot(String mode) async {
    final l10n = AppLocalizations.of(context);
    final view = View.of(context);
    final textDirection = Directionality.of(context);
    try {
      await runWithMfaRetry<void>(
        context,
        ref,
        (api) => api.dio.post(
          '/admin/backups/snapshots',
          queryParameters: {'mode': mode},
        ),
        title: l10n.text('mfa_verification_required'),
        message: l10n.text('mfa_verify_to_create_snapshots'),
      );
      _refreshSnapshots();
      if (!mounted) return;
      final message = l10n.text('snapshot_created');
      SemanticsService.sendAnnouncement(view, message, textDirection);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on DioException catch (error) {
      if (!mounted) return;
      final message =
          '${l10n.text('create_snapshot_failed')}: ${dioErrorMessage(error, context: context)}';
      SemanticsService.sendAnnouncement(view, message, textDirection);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      final message = '${l10n.text('create_snapshot_failed')}: $e';
      SemanticsService.sendAnnouncement(view, message, textDirection);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _openCreateSnapshotDialog() async {
    String mode = 'full';
    final l10n = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('create_snapshot'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocalState) => AlertDialog(
          title: Text(l10n.text('create_snapshot')),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableText(
                  l10n.text('create_snapshot_help'),
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  initialValue: mode,
                  decoration: InputDecoration(
                    labelText: l10n.text('backup_mode'),
                  ),
                  items: <DropdownMenuItem<String>>[
                    DropdownMenuItem(
                      value: 'full',
                      child: Text(l10n.text('mode_full')),
                    ),
                    DropdownMenuItem(
                      value: 'incremental',
                      child: Text(l10n.text('mode_incremental')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setLocalState(() => mode = value);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await _createSnapshot(mode);
              },
              child: Text(l10n.text('create_snapshot')),
            ),
          ],
        ),
      ),
    );
  }

  _BackupSearchCategory? _normalizeSearchCategory(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'mode' || 'modes' || 'type' || 'types' => _BackupSearchCategory.mode,
      'id' || 'snapshot' || 'snapshots' => _BackupSearchCategory.id,
      'created' || 'date' || 'time' => _BackupSearchCategory.created,
      _ => null,
    };
  }

  _BackupUnifiedSearchQuery _parseSearchQuery(String raw) {
    final ast = parseSearchQueryAst(raw);
    final modeFilters = <String>[];
    final excludedModeFilters = <String>[];
    final idFilters = <String>[];
    final excludedIdFilters = <String>[];
    final createdFilters = <String>[];
    final excludedCreatedFilters = <String>[];
    final structuredTokens = <SearchFieldToken>[];
    for (final token in ast.fieldTokens) {
      final category = _normalizeSearchCategory(token.normalizedField);
      if (category == null || !token.hasValue) continue;
      final normalized = token.normalizedValue;
      structuredTokens.add(token);
      switch (category) {
        case _BackupSearchCategory.mode:
          if (token.isNegated) {
            excludedModeFilters.add(normalized);
          } else {
            modeFilters.add(normalized);
          }
          break;
        case _BackupSearchCategory.id:
          if (token.isNegated) {
            excludedIdFilters.add(normalized);
          } else {
            idFilters.add(normalized);
          }
          break;
        case _BackupSearchCategory.created:
          if (token.isNegated) {
            excludedCreatedFilters.add(normalized);
          } else {
            createdFilters.add(normalized);
          }
          break;
      }
    }
    final terms = ast.normalizedTerms;
    return _BackupUnifiedSearchQuery(
      terms: terms,
      expression: ast.expression,
      modeFilters: modeFilters,
      excludedModeFilters: excludedModeFilters,
      idFilters: idFilters,
      excludedIdFilters: excludedIdFilters,
      createdFilters: createdFilters,
      excludedCreatedFilters: excludedCreatedFilters,
      structuredTokens: structuredTokens,
    );
  }

  bool _snapshotMatchesQuery(
    Map<String, dynamic> snapshot,
    _BackupUnifiedSearchQuery query,
  ) {
    if (query.isEmpty) return true;
    final id = (snapshot['id'] ?? '').toString().toLowerCase();
    final mode = (snapshot['mode'] ?? '').toString().toLowerCase();
    final createdAtRaw = (snapshot['created_at_ms'] ?? '').toString();
    final createdAtPretty = _formatCreatedAtMs(
      snapshot['created_at_ms'],
    ).toLowerCase();
    final allText = '$id $mode $createdAtRaw $createdAtPretty';
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
          _BackupSearchCategory.mode => mode.contains(value),
          _BackupSearchCategory.id => id.contains(value),
          _BackupSearchCategory.created =>
            createdAtRaw.contains(value) || createdAtPretty.contains(value),
        };

        return token.isNegated ? !baseMatch : baseMatch;
      },
      matchesText: (token) => allText.contains(token.normalizedValue),
    );
  }

  String _searchCategoryToken(_BackupSearchCategory category) {
    return switch (category) {
      _BackupSearchCategory.mode => 'mode',
      _BackupSearchCategory.id => 'id',
      _BackupSearchCategory.created => 'created',
    };
  }

  String _searchCategoryLabel(
    _BackupSearchCategory category,
    AppLocalizations l10n,
  ) {
    return switch (category) {
      _BackupSearchCategory.mode => l10n.text('snapshot_mode'),
      _BackupSearchCategory.id => l10n.text('snapshot_label'),
      _BackupSearchCategory.created => l10n.text('created_label'),
    };
  }

  String _encodeSearchTokenValue(String value) {
    return value.contains(' ') ? '"$value"' : value;
  }

  List<_BackupSearchSuggestion> _searchValueSuggestions({
    required _BackupSearchCategory category,
    required String partialLower,
    required List<Map<String, dynamic>> snapshots,
  }) {
    switch (category) {
      case _BackupSearchCategory.mode:
        return const <String>['full', 'incremental']
            .where((value) => value.contains(partialLower))
            .map(
              (value) => _BackupSearchSuggestion(
                label: value,
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _BackupSearchCategory.id:
        return snapshots
            .map((snapshot) => (snapshot['id'] ?? '').toString().trim())
            .where((value) => value.isNotEmpty)
            .where((value) => value.toLowerCase().contains(partialLower))
            .take(8)
            .map(
              (value) => _BackupSearchSuggestion(
                label: value,
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _BackupSearchCategory.created:
        return snapshots
            .map((snapshot) => _formatCreatedAtMs(snapshot['created_at_ms']))
            .where((value) => value != '-')
            .where((value) => value.toLowerCase().contains(partialLower))
            .toSet()
            .take(8)
            .map(
              (value) => _BackupSearchSuggestion(
                label: value,
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
    }
  }

  List<_BackupSearchSuggestion> _searchSuggestions(
    AppLocalizations l10n,
    List<Map<String, dynamic>> snapshots,
  ) {
    final context = parseAtTokenSuggestionContext(_searchCtrl.text);
    if (context == null) {
      return _recentQueries
          .take(6)
          .map(
            (query) => _BackupSearchSuggestion(
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
          snapshots: snapshots,
        );
      }
      final partial = context.partialFieldLower;
      return _BackupSearchCategory.values
          .where((category) {
            final token = _searchCategoryToken(category);
            final label = _searchCategoryLabel(category, l10n).toLowerCase();
            if (partial.isEmpty) return true;
            return token.contains(partial) || label.contains(partial);
          })
          .map(
            (category) => _BackupSearchSuggestion(
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
    if (category == null) return const <_BackupSearchSuggestion>[];
    return _searchValueSuggestions(
      category: category,
      partialLower: context.partialValueLower,
      snapshots: snapshots,
    );
  }

  void _applySearchSuggestion(_BackupSearchSuggestion suggestion) {
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
    _rememberCurrentQuery();
    setState(() {});
  }

  void _removeStructuredSearchToken(SearchFieldToken token) {
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

  String _groupKeyForSnapshot(Map<String, dynamic> snapshot) {
    final mode = (snapshot['mode'] ?? '').toString().trim().toLowerCase();
    if (mode == 'full') return _SnapshotGroup.fullKey;
    if (mode == 'incremental') return _SnapshotGroup.incrementalKey;
    return _SnapshotGroup.otherKey;
  }

  List<_SnapshotGroup> _buildGroups(
    List<Map<String, dynamic>> snapshots,
    AppLocalizations l10n,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{
      _SnapshotGroup.fullKey: <Map<String, dynamic>>[],
      _SnapshotGroup.incrementalKey: <Map<String, dynamic>>[],
      _SnapshotGroup.otherKey: <Map<String, dynamic>>[],
    };

    for (final snapshot in snapshots) {
      final key = _groupKeyForSnapshot(snapshot);
      grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(snapshot);
    }

    return <_SnapshotGroup>[
      _SnapshotGroup(
        key: _SnapshotGroup.fullKey,
        label: l10n.text('mode_full'),
        items:
            grouped[_SnapshotGroup.fullKey] ?? const <Map<String, dynamic>>[],
      ),
      _SnapshotGroup(
        key: _SnapshotGroup.incrementalKey,
        label: l10n.text('mode_incremental'),
        items:
            grouped[_SnapshotGroup.incrementalKey] ??
            const <Map<String, dynamic>>[],
      ),
      _SnapshotGroup(
        key: _SnapshotGroup.otherKey,
        label: l10n.text('snapshot_mode'),
        items:
            grouped[_SnapshotGroup.otherKey] ?? const <Map<String, dynamic>>[],
      ),
    ].where((group) => group.items.isNotEmpty).toList(growable: false);
  }

  void _toggleGroup(String key) {
    setState(() {
      if (_collapsedGroupKeys.contains(key)) {
        _collapsedGroupKeys.remove(key);
      } else {
        _collapsedGroupKeys.add(key);
      }
    });
  }

  void _expandAll(List<_SnapshotGroup> groups) {
    setState(() {
      _collapsedGroupKeys.removeAll(groups.map((group) => group.key));
    });
  }

  void _collapseAll(List<_SnapshotGroup> groups) {
    setState(() {
      _collapsedGroupKeys.addAll(groups.map((group) => group.key));
    });
  }

  String _formatCreatedAtMs(Object? raw) {
    final millis = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value) ?? 0,
      _ => 0,
    };
    if (millis <= 0) return '-';
    final local = DateTime.fromMillisecondsSinceEpoch(
      millis,
      isUtc: true,
    ).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _buildGroupRow(_SnapshotGroup group, bool showColumns) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final collapsed = _collapsedGroupKeys.contains(group.key);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        splashFactory: NoSplash.splashFactory,
        highlightColor: cs.primary.withValues(alpha: 0.08),
        hoverColor: cs.primary.withValues(alpha: 0.05),
        onTap: () => _toggleGroup(group.key),
        child: SizedBox(
          height: 60,
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
                    onPressed: () => _toggleGroup(group.key),
                    icon: Icon(
                      collapsed
                          ? Icons.keyboard_arrow_right
                          : Icons.keyboard_arrow_down,
                      size: 18,
                    ),
                    tooltip: collapsed
                        ? l10n.text('expand')
                        : l10n.text('collapse'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                flex: 4,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.folder_outlined, size: 19),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        group.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '(${group.items.length})',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (showColumns) ...<Widget>[
                const Expanded(flex: 2, child: SizedBox.shrink()),
                const Expanded(flex: 3, child: SizedBox.shrink()),
                const SizedBox(width: 40),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSnapshotRow(
    Map<String, dynamic> snapshot,
    bool showColumns,
    AppLocalizations l10n,
  ) {
    final cs = Theme.of(context).colorScheme;
    final id = (snapshot['id'] ?? '').toString();
    final mode = (snapshot['mode'] ?? '').toString();
    final createdAt = _formatCreatedAtMs(snapshot['created_at_ms']);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.go('/organization/backups/$id'),
        child: Container(
          height: 60,
          padding: const EdgeInsets.only(
            left: AppSpacing.sm + 18,
            right: AppSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              const SizedBox(width: 28, height: 28),
              const Icon(Icons.backup_outlined, size: 18),
              const SizedBox(width: AppSpacing.sm),
              if (!showColumns)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${l10n.text('snapshot_mode')}: $mode • $createdAt',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              else ...<Widget>[
                Expanded(
                  flex: 4,
                  child: Text(
                    id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    mode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    createdAt,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              SizedBox(
                width: 40,
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final asyncSnaps = ref.watch(snapshotsProvider);

    final snapshots = (asyncSnaps.asData?.value ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
    final query = _parseSearchQuery(_searchCtrl.text);
    final searchDiagnostics = validateSearchQueryAst(
      parseSearchQueryAst(_searchCtrl.text),
      capability: backupsSearchCapability,
    ).diagnostics;
    final filteredSnapshots = snapshots
        .where((snapshot) => _snapshotMatchesQuery(snapshot, query))
        .toList(growable: false);
    final searchSuggestions = _searchSuggestions(l10n, snapshots);
    final groups = _buildGroups(filteredSnapshots, l10n);
    final hasExpandedGroups = groups.any(
      (group) => !_collapsedGroupKeys.contains(group.key),
    );

    final fullCount = snapshots
        .where(
          (snapshot) =>
              _groupKeyForSnapshot(snapshot) == _SnapshotGroup.fullKey,
        )
        .length;
    final incrementalCount = snapshots
        .where(
          (snapshot) =>
              _groupKeyForSnapshot(snapshot) == _SnapshotGroup.incrementalKey,
        )
        .length;

    final initialLoading = asyncSnaps.isLoading && snapshots.isEmpty;
    final initialError = asyncSnaps.hasError && snapshots.isEmpty;

    return CommandPaletteScope(
      commands: <ContextCommand>[
        ContextCommand(
          label: l10n.text('refresh'),
          subtitle: l10n.text('backups'),
          icon: Icons.refresh,
          action: _refreshSnapshots,
        ),
        ContextCommand(
          label: l10n.text('create_snapshot'),
          subtitle: l10n.text('backups'),
          icon: Icons.add_circle_outline,
          action: _openCreateSnapshotDialog,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            children: <Widget>[
              _BackupsHeaderSection(
                l10n: l10n,
                searchCtrl: _searchCtrl,
                searchFocusNode: _searchFocusNode,
                searchSuggestions: searchSuggestions,
                query: query,
                searchDiagnostics: searchDiagnostics,
                snapshotCount: snapshots.length,
                fullCount: fullCount,
                incrementalCount: incrementalCount,
                filteredCount: filteredSnapshots.length,
                loading: asyncSnaps.isLoading,
                hasExpandedGroups: hasExpandedGroups,
                canToggleGroups: groups.isNotEmpty,
                onGoBack: _goBackToOrganization,
                onCreateSnapshot: _createSnapshot,
                onApplySearchSuggestion: _applySearchSuggestion,
                onRemoveStructuredToken: _removeStructuredSearchToken,
                onOpenSavedViews: () => _openSavedViewsDialog(l10n),
                onToggleAllGroups: () {
                  if (hasExpandedGroups) {
                    _collapseAll(groups);
                  } else {
                    _expandAll(groups);
                  }
                },
                onRefresh: _refreshSnapshots,
              ),
              const Divider(height: 1),
              _BackupsContentSection(
                l10n: l10n,
                initialLoading: initialLoading,
                initialError: initialError,
                loadError: asyncSnaps.error,
                snapshots: snapshots,
                groups: groups,
                collapsedGroupKeys: _collapsedGroupKeys,
                onRefresh: _refreshSnapshots,
                onOpenCreateSnapshotDialog: _openCreateSnapshotDialog,
                buildGroupRow: _buildGroupRow,
                buildSnapshotRow: _buildSnapshotRow,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackupsHeaderSection extends StatelessWidget {
  final AppLocalizations l10n;
  final TextEditingController searchCtrl;
  final FocusNode searchFocusNode;
  final List<_BackupSearchSuggestion> searchSuggestions;
  final _BackupUnifiedSearchQuery query;
  final List<SearchParseDiagnostic> searchDiagnostics;
  final int snapshotCount;
  final int fullCount;
  final int incrementalCount;
  final int filteredCount;
  final bool loading;
  final bool hasExpandedGroups;
  final bool canToggleGroups;
  final VoidCallback onGoBack;
  final ValueChanged<String> onCreateSnapshot;
  final ValueChanged<_BackupSearchSuggestion> onApplySearchSuggestion;
  final ValueChanged<SearchFieldToken> onRemoveStructuredToken;
  final VoidCallback onOpenSavedViews;
  final VoidCallback onToggleAllGroups;
  final VoidCallback onRefresh;

  const _BackupsHeaderSection({
    required this.l10n,
    required this.searchCtrl,
    required this.searchFocusNode,
    required this.searchSuggestions,
    required this.query,
    required this.searchDiagnostics,
    required this.snapshotCount,
    required this.fullCount,
    required this.incrementalCount,
    required this.filteredCount,
    required this.loading,
    required this.hasExpandedGroups,
    required this.canToggleGroups,
    required this.onGoBack,
    required this.onCreateSnapshot,
    required this.onApplySearchSuggestion,
    required this.onRemoveStructuredToken,
    required this.onOpenSavedViews,
    required this.onToggleAllGroups,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) {
              final searchField = TextField(
                controller: searchCtrl,
                focusNode: searchFocusNode,
                onSubmitted: (_) => onRefresh(),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: l10n.text('search_items'),
                  hintText: structuredSearchHint(
                    l10n: l10n,
                    capability: backupsSearchCapability,
                    baseHint: l10n.text('search_hint_backup_items_tokens'),
                  ),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searchCtrl.text.trim().isEmpty
                      ? null
                      : IconButton(
                          onPressed: searchCtrl.clear,
                          tooltip: l10n.text('clear_search'),
                          icon: const Icon(Icons.close),
                        ),
                ),
              );
              final actionButtons = <Widget>[
                IconButton(
                  onPressed: onGoBack,
                  tooltip: l10n.text('organization_access'),
                  icon: const Icon(Icons.arrow_back),
                ),
                PopupMenuButton<String>(
                  tooltip: l10n.text('new_item'),
                  onSelected: onCreateSnapshot,
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'full',
                      child: Text(l10n.text('mode_full')),
                    ),
                    PopupMenuItem<String>(
                      value: 'incremental',
                      child: Text(l10n.text('mode_incremental')),
                    ),
                  ],
                  icon: const Icon(Icons.add_circle_outline),
                ),
                SearchHowToButton(capability: backupsSearchCapability),
                IconButton(
                  tooltip: l10n.text('save_view'),
                  onPressed: searchCtrl.text.trim().isEmpty
                      ? null
                      : onOpenSavedViews,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
                IconButton(
                  tooltip: l10n.text('load_saved_view'),
                  onPressed: onOpenSavedViews,
                  icon: const Icon(Icons.bookmark_outline),
                ),
                IconButton(
                  tooltip: l10n.text(
                    hasExpandedGroups ? 'collapse_all' : 'expand_all',
                  ),
                  onPressed: canToggleGroups ? onToggleAllGroups : null,
                  icon: Icon(
                    hasExpandedGroups ? Icons.unfold_less : Icons.unfold_more,
                  ),
                ),
                IconButton(
                  onPressed: onRefresh,
                  tooltip: l10n.text('refresh'),
                  icon: const Icon(Icons.refresh),
                ),
              ];
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
                  actionButtons[0],
                  actionButtons[1],
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: searchField),
                  const SizedBox(width: AppSpacing.xs),
                  ...actionButtons.skip(2),
                ],
              );
            },
          ),
          if (searchSuggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.outlineVariant),
                color: cs.surfaceContainerLow,
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
                      onTap: () => onApplySearchSuggestion(suggestion),
                    );
                  },
                ),
              ),
            ),
          ],
          if (query.structuredTokens.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                for (final token in query.structuredTokens)
                  InputChip(
                    label: Text(token.toChipLabel()),
                    onDeleted: () => onRemoveStructuredToken(token),
                  ),
              ],
            ),
          ],
          if (searchDiagnostics.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            SearchDiagnosticsList(diagnostics: searchDiagnostics),
          ],
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      Text(
                        '$snapshotCount ${l10n.text('backups')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '$fullCount ${l10n.text('mode_full').toLowerCase()}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '$incrementalCount ${l10n.text('mode_incremental').toLowerCase()}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '$filteredCount ${l10n.text('matching')}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      if (loading) ...<Widget>[
                        const SizedBox(width: AppSpacing.sm),
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BackupsContentSection extends StatelessWidget {
  final AppLocalizations l10n;
  final bool initialLoading;
  final bool initialError;
  final Object? loadError;
  final List<Map<String, dynamic>> snapshots;
  final List<_SnapshotGroup> groups;
  final Set<String> collapsedGroupKeys;
  final VoidCallback onRefresh;
  final VoidCallback onOpenCreateSnapshotDialog;
  final Widget Function(_SnapshotGroup group, bool showColumns) buildGroupRow;
  final Widget Function(
    Map<String, dynamic> snapshot,
    bool showColumns,
    AppLocalizations l10n,
  )
  buildSnapshotRow;

  const _BackupsContentSection({
    required this.l10n,
    required this.initialLoading,
    required this.initialError,
    required this.loadError,
    required this.snapshots,
    required this.groups,
    required this.collapsedGroupKeys,
    required this.onRefresh,
    required this.onOpenCreateSnapshotDialog,
    required this.buildGroupRow,
    required this.buildSnapshotRow,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: initialLoading
          ? const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : initialError
          ? Center(
              child: AtlasEmptyState(
                icon: Icons.error_outline,
                title: l10n.text('failed_to_load_snapshots'),
                subtitle: loadError.toString(),
                action: FilledButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.text('refresh')),
                ),
              ),
            )
          : groups.isEmpty
          ? Center(
              child: AtlasEmptyState(
                icon: snapshots.isEmpty
                    ? Icons.backup_outlined
                    : Icons.search_off_outlined,
                title: snapshots.isEmpty
                    ? l10n.text('no_snapshots_found')
                    : l10n.text('no_matching_items'),
                action: snapshots.isEmpty
                    ? FilledButton.icon(
                        onPressed: onOpenCreateSnapshotDialog,
                        icon: const Icon(Icons.add),
                        label: Text(l10n.text('create_snapshot')),
                      )
                    : null,
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final showColumns = constraints.maxWidth >= 980;
                return Column(
                  children: <Widget>[
                    if (showColumns)
                      Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        color: cs.surfaceContainerLow,
                        child: Row(
                          children: <Widget>[
                            const SizedBox(width: 44),
                            Expanded(
                              flex: 4,
                              child: Text(l10n.text('snapshot_label')),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(l10n.text('snapshot_mode')),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(l10n.text('created_label')),
                            ),
                            const SizedBox(width: 40),
                          ],
                        ),
                      ),
                    if (showColumns) const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          final group = groups[index];
                          final collapsed = collapsedGroupKeys.contains(
                            group.key,
                          );
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              buildGroupRow(group, showColumns),
                              ClipRect(
                                child: AnimatedSize(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeInOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: collapsed
                                      ? const SizedBox.shrink()
                                      : Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            for (final snapshot in group.items)
                                              buildSnapshotRow(
                                                snapshot,
                                                showColumns,
                                                l10n,
                                              ),
                                          ],
                                        ),
                                ),
                              ),
                              const Divider(height: 1),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _SnapshotGroup {
  static const String fullKey = 'mode:full';
  static const String incrementalKey = 'mode:incremental';
  static const String otherKey = 'mode:other';

  final String key;
  final String label;
  final List<Map<String, dynamic>> items;

  const _SnapshotGroup({
    required this.key,
    required this.label,
    required this.items,
  });
}

enum _BackupSearchCategory { mode, id, created }

class _BackupUnifiedSearchQuery {
  final List<String> terms;
  final SearchExpressionNode? expression;
  final List<String> modeFilters;
  final List<String> excludedModeFilters;
  final List<String> idFilters;
  final List<String> excludedIdFilters;
  final List<String> createdFilters;
  final List<String> excludedCreatedFilters;
  final List<SearchFieldToken> structuredTokens;

  const _BackupUnifiedSearchQuery({
    required this.terms,
    required this.expression,
    required this.modeFilters,
    required this.excludedModeFilters,
    required this.idFilters,
    required this.excludedIdFilters,
    required this.createdFilters,
    required this.excludedCreatedFilters,
    required this.structuredTokens,
  });

  bool get isEmpty =>
      terms.isEmpty &&
      modeFilters.isEmpty &&
      excludedModeFilters.isEmpty &&
      idFilters.isEmpty &&
      excludedIdFilters.isEmpty &&
      createdFilters.isEmpty &&
      excludedCreatedFilters.isEmpty;
}

class _BackupSearchSuggestion {
  final String label;
  final String tokenText;
  final bool appendSpace;
  final String? subtitle;

  const _BackupSearchSuggestion({
    required this.label,
    required this.tokenText,
    required this.appendSpace,
    this.subtitle,
  });
}
