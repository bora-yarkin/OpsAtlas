// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Administrative media management screen for uploads, attachments, and usage.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/auth_store.dart';
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
import '../../../core/widgets/atlas_ui.dart';
import '../../../core/widgets/media_preview_dialog.dart';

class AdminMediaScreen extends ConsumerStatefulWidget {
  final String? initialSpaceId;
  final String? initialSearchQuery;

  const AdminMediaScreen({
    super.key,
    this.initialSpaceId,
    this.initialSearchQuery,
  });

  @override
  ConsumerState<AdminMediaScreen> createState() => _AdminMediaScreenState();
}

class _AdminMediaScreenState extends ConsumerState<AdminMediaScreen> {
  static const _prefsKey = 'admin_media_saved_filters_v1';
  static const _noBatchValue = '__unchanged__';
  static const _searchSurfaceId = 'admin_media';

  final _searchCtrl = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _listScrollCtrl = ScrollController();
  final _folderPatchCtrl = TextEditingController();
  final _tagsPatchCtrl = TextEditingController();
  final _retentionPatchCtrl = TextEditingController();
  final _savedFilterNameCtrl = TextEditingController();
  final _savedViewNameCtrl = TextEditingController();

  bool _loading = true;
  bool _updating = false;
  bool _prefsLoaded = false;
  bool _includeExpired = false;
  bool _onlyExpired = false;
  bool _clearFolderPatch = false;
  bool _clearTagsPatch = false;
  bool _clearRetentionPatch = false;
  String? _selectedFolder;
  String? _selectedTag;
  String _batchAccessMode = _noBatchValue;
  String? _selectedSpaceId;
  String? _error;
  final Set<String> _collapsedParentKeys = <String>{};

  final int _pageSize = 100;
  int _offset = 0;
  int _totalFiltered = 0;
  bool _hasMore = false;
  bool _loadingMore = false;

  List<Map<String, dynamic>> _assets = const [];
  List<Map<String, dynamic>> _folders = const [];
  List<Map<String, dynamic>> _tags = const [];
  List<Map<String, dynamic>> _spaces = const [];
  List<Map<String, dynamic>> _savedFilters = const [];
  List<String> _recentQueries = const <String>[];
  List<SearchSavedView> _savedViews = const <SearchSavedView>[];
  final Set<String> _selectedAssetIds = <String>{};
  int _expiredCount = 0;
  int _totalAssets = 0;

  bool get _isAdmin => ref.read(authStoreProvider).isAdmin;

  void _handleSearchCtrlChanged() {
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
    await _load(resetOffset: true);
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
    final scopedSpaceId = (_selectedSpaceId ?? widget.initialSpaceId ?? '')
        .trim();
    if (scopedSpaceId.isEmpty) {
      params.remove('spaceId');
    } else {
      params['spaceId'] = scopedSpaceId;
    }

    final nextUri = Uri(
      path: '/organization/media',
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
    _searchCtrl.addListener(_handleSearchCtrlChanged);
    _searchFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    _listScrollCtrl.addListener(_handleListScroll);
    _loadSearchState();
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant AdminMediaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousQuery = normalizeSearchInput(
      oldWidget.initialSearchQuery ?? '',
    );
    final nextQuery = normalizeSearchInput(widget.initialSearchQuery ?? '');
    if (nextQuery != previousQuery) {
      final current = normalizeSearchInput(_searchCtrl.text);
      if (nextQuery != current) {
        _searchCtrl.value = TextEditingValue(
          text: nextQuery,
          selection: TextSelection.collapsed(offset: nextQuery.length),
        );
      }
    }

    final previousSpace = (oldWidget.initialSpaceId ?? '').trim();
    final nextSpace = (widget.initialSpaceId ?? '').trim();
    if (nextSpace == previousSpace) {
      return;
    }
    if (nextSpace.isEmpty) {
      if (_isAdmin && (_selectedSpaceId ?? '').trim().isNotEmpty) {
        setState(() => _selectedSpaceId = null);
        _syncSearchRoute();
        _load(resetOffset: true);
      }
      return;
    }
    final exists = _spaces.any(
      (space) => (space['id'] ?? '').toString().trim() == nextSpace,
    );
    if (exists && (_selectedSpaceId ?? '').trim() != nextSpace) {
      setState(() => _selectedSpaceId = nextSpace);
      _syncSearchRoute();
      _load(resetOffset: true);
    }
  }

  @override
  void dispose() {
    _searchCtrl
      ..removeListener(_handleSearchCtrlChanged)
      ..dispose();
    _searchFocusNode.dispose();
    _listScrollCtrl.dispose();
    _folderPatchCtrl.dispose();
    _tagsPatchCtrl.dispose();
    _retentionPatchCtrl.dispose();
    _savedFilterNameCtrl.dispose();
    _savedViewNameCtrl.dispose();
    super.dispose();
  }

  bool get _hasBatchPatch {
    return _batchAccessMode != _noBatchValue ||
        _folderPatchCtrl.text.trim().isNotEmpty ||
        _tagsPatchCtrl.text.trim().isNotEmpty ||
        int.tryParse(_retentionPatchCtrl.text.trim()) != null ||
        _clearFolderPatch ||
        _clearTagsPatch ||
        _clearRetentionPatch;
  }

  Future<void> _bootstrap() async {
    await _loadSavedFilters();
    await _loadSpaces();
    await _load(resetOffset: true);
  }

  void _handleListScroll() {
    if (!_listScrollCtrl.hasClients) return;
    if (_loading || _loadingMore || !_hasMore) return;
    final position = _listScrollCtrl.position;
    if (position.extentAfter < 480) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      await _load(resetOffset: false, append: true);
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _loadSavedFilters() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_prefsKey) ?? '';
    var parsed = <Map<String, dynamic>>[];
    if (raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          parsed = decoded
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        }
      } catch (_) {
        parsed = [];
      }
    }
    if (!mounted) return;
    setState(() {
      _savedFilters = parsed;
      _prefsLoaded = true;
    });
  }

  Future<void> _persistSavedFilters() async {
    if (!_prefsLoaded) return;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefsKey, jsonEncode(_savedFilters));
  }

  Future<void> _loadSpaces() async {
    final api = ref.read(apiClientProvider);
    try {
      final response = await api.dio.get('/spaces');
      final spaces = _toJsonRows(response.data)
        ..sort(
          (a, b) => (a['name'] ?? '').toString().toLowerCase().compareTo(
            (b['name'] ?? '').toString().toLowerCase(),
          ),
        );
      final validSpaceIds = spaces
          .map((e) => (e['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      String? selected = _selectedSpaceId;

      final initial = widget.initialSpaceId?.trim();
      if (initial != null &&
          initial.isNotEmpty &&
          validSpaceIds.contains(initial)) {
        selected = initial;
      }
      if (!_isAdmin) {
        if (selected == null || !validSpaceIds.contains(selected)) {
          selected = spaces.isEmpty
              ? null
              : (spaces.first['id'] ?? '').toString();
        }
      }
      if (_isAdmin && selected != null && !validSpaceIds.contains(selected)) {
        selected = null;
      }
      if (!mounted) return;
      setState(() {
        _spaces = spaces;
        _selectedSpaceId = selected;
      });
      _syncSearchRoute();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _spaces = const [];
        _error = _dioMessage(context, e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _spaces = const [];
        _error = e.toString();
      });
    }
  }

  Future<void> _load({bool resetOffset = false, bool append = false}) async {
    if (resetOffset) {
      _offset = 0;
      append = false;
    }
    if (!_isAdmin &&
        (_selectedSpaceId == null || _selectedSpaceId!.trim().isEmpty)) {
      setState(() {
        _loading = false;
        _loadingMore = false;
        _assets = const [];
        _error = AppLocalizations.of(context).text('select_space_scope_first');
      });
      return;
    }

    final parsedSearch = _parseUnifiedSearchQuery(_searchCtrl.text);
    final usage = parsedSearch.usageFilters.isEmpty
        ? ''
        : parsedSearch.usageFilters.first;
    final requestSpaceId = _resolveRequestSpaceId(parsedSearch);
    final effectiveFolder = parsedSearch.folderFilters.isEmpty
        ? _selectedFolder
        : parsedSearch.folderFilters.first;
    final effectiveTag = parsedSearch.tagFilters.isEmpty
        ? _selectedTag
        : parsedSearch.tagFilters.first;

    if (!append) {
      setState(() {
        _loading = true;
        _error = null;
        _hasMore = true;
      });
    } else {
      setState(() {
        _error = null;
      });
    }

    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        if (usage.isNotEmpty) 'usage': usage,
        ...?switch (requestSpaceId) {
          String value => {'space_id': value},
          _ => null,
        },
      };

      final summaryResp = await api.dio.get(
        '/media/summary',
        queryParameters: query,
      );
      final pageResp = await api.dio.get(
        '/media/page',
        queryParameters: {
          ...query,
          ...?switch (effectiveFolder) {
            String value => {'folder_path': value},
            _ => null,
          },
          ...?switch (effectiveTag) {
            String value => {'tag': value},
            _ => null,
          },
          'limit': _pageSize,
          'offset': _offset,
          'include_expired': _includeExpired || _onlyExpired,
          'only_expired': _onlyExpired,
        },
      );

      final summary = _toJsonRow(summaryResp.data);
      final pageData = _toJsonRow(pageResp.data);
      final fetched = _toJsonRows(pageData['items']);
      final combinedAssets = append
          ? <Map<String, dynamic>>[..._assets]
          : <Map<String, dynamic>>[];
      if (append && combinedAssets.isNotEmpty) {
        final existingIds = combinedAssets
            .map((item) => (item['id'] ?? '').toString())
            .where((id) => id.isNotEmpty)
            .toSet();
        for (final item in fetched) {
          final id = (item['id'] ?? '').toString();
          if (id.isEmpty || !existingIds.contains(id)) {
            combinedAssets.add(item);
            if (id.isNotEmpty) {
              existingIds.add(id);
            }
          }
        }
      } else {
        combinedAssets.addAll(fetched);
      }

      final validIds = combinedAssets
          .map((item) => (item['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      _selectedAssetIds.removeWhere((id) => !validIds.contains(id));
      final groupKeys = combinedAssets.map((item) {
        final spaceId = _assetSpaceId(item);
        return spaceId.isEmpty ? 'global' : 'space:$spaceId';
      }).toSet();
      final existingGroupKeys = _assets.map((item) {
        final spaceId = _assetSpaceId(item);
        return spaceId.isEmpty ? 'global' : 'space:$spaceId';
      }).toSet();

      if (!mounted) return;
      setState(() {
        _assets = combinedAssets;
        _folders = _toJsonRows(summary['folders']);
        _tags = _toJsonRows(summary['tags']);
        _expiredCount = _toInt(summary['expired_assets']);
        _totalAssets = _toInt(summary['total_assets']);
        _totalFiltered = _toInt(pageData['total']);
        _hasMore = (pageData['has_more'] ?? false) == true;
        if (append) {
          _collapsedParentKeys.addAll(groupKeys.difference(existingGroupKeys));
        } else {
          _collapsedParentKeys
            ..clear()
            ..addAll(groupKeys);
        }
        _offset = _assets.length;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _error = _dioMessage(context, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted && !append) {
        setState(() => _loading = false);
      }
    }
  }

  String? _resolveRequestSpaceId(_MediaUnifiedSearchQuery query) {
    if (!_isAdmin) {
      return _selectedSpaceId;
    }
    if (query.spaceFilters.isEmpty) {
      return _selectedSpaceId;
    }
    final searchSpace = query.spaceFilters.first.trim();
    if (searchSpace.isEmpty) return _selectedSpaceId;
    final normalized = searchSpace.toLowerCase();
    if (normalized == 'global' || normalized == 'all') {
      return null;
    }
    final exactId = _spaces.firstWhere(
      (space) =>
          (space['id'] ?? '').toString().trim().toLowerCase() == normalized,
      orElse: () => const <String, dynamic>{},
    );
    final exactIdValue = (exactId['id'] ?? '').toString().trim();
    if (exactIdValue.isNotEmpty) return exactIdValue;
    final exactName = _spaces.firstWhere(
      (space) =>
          (space['name'] ?? '').toString().trim().toLowerCase() == normalized,
      orElse: () => const <String, dynamic>{},
    );
    final exactNameValue = (exactName['id'] ?? '').toString().trim();
    if (exactNameValue.isNotEmpty) return exactNameValue;
    return _selectedSpaceId;
  }

  Future<void> _applyBatchPatch() async {
    if (_selectedAssetIds.isEmpty || !_hasBatchPatch || _updating) return;
    final retention = int.tryParse(_retentionPatchCtrl.text.trim());
    final payload = <String, dynamic>{
      'asset_ids': _selectedAssetIds.toList(growable: false),
      if (_batchAccessMode != _noBatchValue) 'access_mode': _batchAccessMode,
      if (_folderPatchCtrl.text.trim().isNotEmpty)
        'folder_path': _folderPatchCtrl.text.trim(),
      if (_tagsPatchCtrl.text.trim().isNotEmpty)
        'tags': _tagsPatchCtrl.text
            .split(',')
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList(),
      ...?switch (retention) {
        int retentionDays => {'retention_days': retentionDays},
        _ => null,
      },
      if (_clearFolderPatch) 'clear_folder_path': true,
      if (_clearTagsPatch) 'clear_tags': true,
      if (_clearRetentionPatch) 'clear_retention_days': true,
    };

    if (payload.length <= 1) return;

    final l10n = AppLocalizations.of(context);
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await api.dio.post('/media/bulk-meta', data: payload);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.text('save_changes'))));
      _folderPatchCtrl.clear();
      _tagsPatchCtrl.clear();
      _retentionPatchCtrl.clear();
      _clearFolderPatch = false;
      _clearTagsPatch = false;
      _clearRetentionPatch = false;
      _batchAccessMode = _noBatchValue;
      await _load(resetOffset: true);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _error = _dioMessage(context, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _updating = false);
      }
    }
  }

  Future<void> _cleanupExpired() async {
    if (_updating) return;
    final api = ref.read(apiClientProvider);
    final l10n = AppLocalizations.of(context);
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final parsedSearch = _parseUnifiedSearchQuery(_searchCtrl.text);
      final usage = parsedSearch.usageFilters.isEmpty
          ? ''
          : parsedSearch.usageFilters.first;
      final requestSpaceId = _resolveRequestSpaceId(parsedSearch);
      await api.dio.post(
        '/media/cleanup',
        queryParameters: {
          if (usage.isNotEmpty) 'usage': usage,
          ...?switch (requestSpaceId) {
            String value => {'space_id': value},
            _ => null,
          },
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.text('cleanup_complete'))));
      await _load(resetOffset: true);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _error = _dioMessage(context, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _updating = false);
      }
    }
  }

  Map<String, dynamic> _currentFilterSnapshot() {
    return {
      'search_query': _searchCtrl.text.trim(),
      'folder_path': _selectedFolder,
      'tag': _selectedTag,
      'include_expired': _includeExpired,
      'only_expired': _onlyExpired,
      'space_id': _selectedSpaceId,
    };
  }

  Future<void> _saveCurrentFilter() async {
    final l10n = AppLocalizations.of(context);
    final name = _savedFilterNameCtrl.text.trim();
    if (name.isEmpty) return;
    final snapshot = {'name': name, ..._currentFilterSnapshot()};
    setState(() {
      final idx = _savedFilters.indexWhere(
        (row) =>
            (row['name'] ?? '').toString().toLowerCase() == name.toLowerCase(),
      );
      if (idx >= 0) {
        _savedFilters[idx] = snapshot;
      } else {
        _savedFilters = [snapshot, ..._savedFilters].take(16).toList();
      }
      _savedFilterNameCtrl.clear();
    });
    await _persistSavedFilters();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.text('saved_filter_stored'))));
  }

  Future<void> _applySavedFilter(Map<String, dynamic> filter) async {
    setState(() {
      final query = (filter['search_query'] ?? filter['usage'] ?? '')
          .toString()
          .trim();
      _searchCtrl.text = query;
      _selectedFolder = (filter['folder_path'] ?? '').toString().trim().isEmpty
          ? null
          : (filter['folder_path'] ?? '').toString();
      _selectedTag = (filter['tag'] ?? '').toString().trim().isEmpty
          ? null
          : (filter['tag'] ?? '').toString();
      _includeExpired = filter['include_expired'] == true;
      _onlyExpired = filter['only_expired'] == true;
      if (_isAdmin) {
        final rawSpaceId = (filter['space_id'] ?? '').toString().trim();
        _selectedSpaceId = rawSpaceId.isEmpty ? null : rawSpaceId;
      } else {
        final rawSpaceId = (filter['space_id'] ?? '').toString().trim();
        if (rawSpaceId.isNotEmpty &&
            _spaces.any(
              (space) => (space['id'] ?? '').toString() == rawSpaceId,
            )) {
          _selectedSpaceId = rawSpaceId;
        }
      }
    });
    _syncSearchRoute();
    await _load(resetOffset: true);
  }

  void _clearSavedFilter(Map<String, dynamic> filter) {
    final name = (filter['name'] ?? '').toString().trim().toLowerCase();
    if (name.isEmpty) return;
    setState(() {
      _savedFilters = _savedFilters
          .where(
            (row) =>
                (row['name'] ?? '').toString().trim().toLowerCase() != name,
          )
          .toList();
    });
    _persistSavedFilters();
  }

  Future<void> _goBackToOrganization() async {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/organization');
  }

  void _clearExplorerFilters() {
    _searchCtrl.clear();
    setState(() {
      _selectedFolder = null;
      _selectedTag = null;
      _includeExpired = false;
      _onlyExpired = false;
    });
    _load(resetOffset: true);
  }

  _MediaUnifiedSearchQuery _parseUnifiedSearchQuery(String raw) {
    final ast = parseSearchQueryAst(raw);
    final tagFilters = <String>[];
    final excludedTagFilters = <String>[];
    final folderFilters = <String>[];
    final excludedFolderFilters = <String>[];
    final spaceFilters = <String>[];
    final excludedSpaceFilters = <String>[];
    final usageFilters = <String>[];
    final excludedUsageFilters = <String>[];
    final flags = <String>{};
    final structuredTokens = <SearchFieldToken>[];

    for (final token in ast.fieldTokens) {
      final category = _normalizeSearchCategory(token.normalizedField);
      if (category == null || !token.hasValue) continue;
      final normalized = token.normalizedValue;
      structuredTokens.add(token);
      switch (category) {
        case _SearchCategory.tags:
          if (token.isNegated) {
            excludedTagFilters.add(normalized);
          } else {
            tagFilters.add(normalized);
          }
          break;
        case _SearchCategory.folders:
          if (token.isNegated) {
            excludedFolderFilters.add(normalized);
          } else {
            folderFilters.add(normalized);
          }
          break;
        case _SearchCategory.spaces:
          if (token.isNegated) {
            excludedSpaceFilters.add(normalized);
          } else {
            spaceFilters.add(normalized);
          }
          break;
        case _SearchCategory.usage:
          if (token.isNegated) {
            excludedUsageFilters.add(normalized);
          } else {
            usageFilters.add(normalized);
          }
          break;
        case _SearchCategory.flags:
          for (final value in splitSearchFlagValues(normalized)) {
            final normalizedFlag = _normalizeMediaSearchFlag(value);
            if (normalizedFlag == null) {
              continue;
            }
            if (token.isNegated) {
              flags.remove(normalizedFlag);
            } else {
              flags.add(normalizedFlag);
            }
          }
          break;
      }
    }

    final terms = ast.normalizedTerms;

    return _MediaUnifiedSearchQuery(
      terms: terms,
      expression: ast.expression,
      tagFilters: tagFilters,
      excludedTagFilters: excludedTagFilters,
      folderFilters: folderFilters,
      excludedFolderFilters: excludedFolderFilters,
      spaceFilters: spaceFilters,
      excludedSpaceFilters: excludedSpaceFilters,
      usageFilters: usageFilters,
      excludedUsageFilters: excludedUsageFilters,
      flags: flags,
      structuredTokens: structuredTokens,
    );
  }

  _SearchCategory? _normalizeSearchCategory(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'tags' || 'tag' || 'label' || 'labels' => _SearchCategory.tags,
      'folders' ||
      'folder' ||
      'path' ||
      'folder_path' => _SearchCategory.folders,
      'spaces' || 'space' || 'scope' || 'space_id' => _SearchCategory.spaces,
      'usage' || 'type' || 'types' || 'kind' => _SearchCategory.usage,
      'flag' || 'flags' => _SearchCategory.flags,
      _ => null,
    };
  }

  String? _normalizeMediaSearchFlag(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'hide-parents' ||
      'hide-parent' ||
      'flat' ||
      'only-matches' => 'hide-parents',
      'show-parents' ||
      'show-parent' ||
      'with-parents' ||
      'keep-parents' => 'show-parents',
      _ => null,
    };
  }

  String _searchCategoryToken(_SearchCategory category) {
    return switch (category) {
      _SearchCategory.tags => 'tags',
      _SearchCategory.folders => 'folders',
      _SearchCategory.spaces => 'spaces',
      _SearchCategory.usage => 'usage',
      _SearchCategory.flags => 'flag',
    };
  }

  String _searchCategoryLabel(_SearchCategory category, AppLocalizations l10n) {
    return switch (category) {
      _SearchCategory.tags => l10n.text('tags_label'),
      _SearchCategory.folders => l10n.text('folders'),
      _SearchCategory.spaces => l10n.text('space_scope'),
      _SearchCategory.usage => l10n.text('types'),
      _SearchCategory.flags => l10n.text('search_flags'),
    };
  }

  String _spaceLabelForAsset(
    Map<String, dynamic> asset,
    Map<String, String> spaceNameById,
    AppLocalizations l10n,
  ) {
    final spaceId = _assetSpaceId(asset);
    if (spaceId.isEmpty) return l10n.text('global_scope');
    final named = (spaceNameById[spaceId] ?? '').trim();
    return named.isEmpty ? spaceId : named;
  }

  bool _assetMatchesUnifiedSearch(
    Map<String, dynamic> asset,
    _MediaUnifiedSearchQuery query,
    Map<String, String> spaceNameById,
    AppLocalizations l10n,
  ) {
    final fileName = (asset['original_filename'] ?? asset['id'] ?? '')
        .toString()
        .toLowerCase();
    final usage = (asset['usage'] ?? '').toString().toLowerCase();
    final folder = (asset['folder_path'] ?? '').toString().toLowerCase();
    final accessMode = (asset['access_mode'] ?? '').toString().toLowerCase();
    final spaceId = _assetSpaceId(asset).toLowerCase();
    final spaceLabel = _spaceLabelForAsset(
      asset,
      spaceNameById,
      l10n,
    ).toLowerCase();
    final tags = _stringList(
      asset['tags'],
    ).map((tag) => tag.toLowerCase()).toList(growable: false);
    final allText = [
      fileName,
      usage,
      folder,
      accessMode,
      spaceLabel,
      spaceId,
      ...tags,
    ].join(' ');

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
          _SearchCategory.tags => tags.any((tag) => tag.contains(value)),
          _SearchCategory.folders => folder.contains(value),
          _SearchCategory.usage => usage.contains(value),
          _SearchCategory.flags => true,
          _SearchCategory.spaces => switch (value) {
            'all' => true,
            'global' => spaceId.isEmpty,
            _ => spaceId.contains(value) || spaceLabel.contains(value),
          },
        };

        return token.isNegated ? !baseMatch : baseMatch;
      },
      matchesText: (token) => allText.contains(token.normalizedValue),
    );
  }

  String _encodeSearchTokenValue(String value) {
    return value.contains(' ') ? '"$value"' : value;
  }

  List<_SearchSuggestion> _searchSuggestions(AppLocalizations l10n) {
    final context = parseAtTokenSuggestionContext(_searchCtrl.text);
    if (context == null) {
      return _recentQueries
          .take(6)
          .map(
            (query) => _SearchSuggestion(
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
          l10n: l10n,
        );
      }
      final partial = context.partialFieldLower;
      final categories = _SearchCategory.values
          .where((category) {
            final token = _searchCategoryToken(category);
            final label = _searchCategoryLabel(category, l10n).toLowerCase();
            if (partial.isEmpty) return true;
            return token.contains(partial) || label.contains(partial);
          })
          .map(
            (category) => _SearchSuggestion(
              label:
                  '@${_searchCategoryToken(category)} - ${_searchCategoryLabel(category, l10n)}',
              tokenText: '@${_searchCategoryToken(category)}:',
              appendSpace: false,
              subtitle: l10n.text('search'),
            ),
          )
          .toList(growable: false);
      return categories;
    }

    final category = _normalizeSearchCategory(context.fieldLower);
    if (category == null) return const <_SearchSuggestion>[];

    return _searchValueSuggestions(
      category: category,
      partialLower: context.partialValueLower,
      l10n: l10n,
    );
  }

  List<_SearchSuggestion> _searchValueSuggestions({
    required _SearchCategory category,
    required String partialLower,
    required AppLocalizations l10n,
  }) {
    switch (category) {
      case _SearchCategory.tags:
        return _tags
            .map((item) => (item['value'] ?? '').toString().trim())
            .where((value) => value.isNotEmpty)
            .where((value) => value.toLowerCase().contains(partialLower))
            .take(8)
            .map(
              (value) => _SearchSuggestion(
                label: '#$value',
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _SearchCategory.folders:
        return _folders
            .map((item) => (item['value'] ?? '').toString().trim())
            .where((value) => value.isNotEmpty)
            .where((value) => value.toLowerCase().contains(partialLower))
            .take(8)
            .map(
              (value) => _SearchSuggestion(
                label: value,
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _SearchCategory.spaces:
        return _spaces
            .map((space) {
              final id = (space['id'] ?? '').toString().trim();
              final name = (space['name'] ?? '').toString().trim();
              return (id: id, name: name);
            })
            .where((row) => row.id.isNotEmpty)
            .where((row) {
              if (partialLower.isEmpty) return true;
              return row.id.toLowerCase().contains(partialLower) ||
                  row.name.toLowerCase().contains(partialLower);
            })
            .take(8)
            .map(
              (row) => _SearchSuggestion(
                label: row.name.isEmpty ? row.id : '${row.name} (${row.id})',
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(row.id)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _SearchCategory.usage:
        final usages =
            _assets
                .map((asset) => (asset['usage'] ?? '').toString().trim())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return usages
            .where((value) => value.toLowerCase().contains(partialLower))
            .take(8)
            .map(
              (value) => _SearchSuggestion(
                label: value,
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
              ),
            )
            .toList(growable: false);
      case _SearchCategory.flags:
        const values = <String>['hide-parents', 'show-parents'];
        return values
            .where((value) => value.contains(partialLower))
            .map(
              (value) => _SearchSuggestion(
                label: 'flag:$value',
                tokenText:
                    '@${_searchCategoryToken(category)}:${_encodeSearchTokenValue(value)}',
                appendSpace: true,
                subtitle: value == 'hide-parents'
                    ? l10n.text('search_flag_hide_parents_help')
                    : l10n.text('search_flag_show_parents_help'),
              ),
            )
            .toList(growable: false);
    }
  }

  void _applySearchSuggestion(_SearchSuggestion suggestion) {
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

  String _assetSpaceId(Map<String, dynamic> asset) {
    final direct = (asset['space_id'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final fallback = (asset['scope_space_id'] ?? '').toString().trim();
    if (fallback.isNotEmpty) return fallback;
    if (_selectedSpaceId != null && _selectedSpaceId!.trim().isNotEmpty) {
      return _selectedSpaceId!.trim();
    }
    return '';
  }

  List<_MediaParentGroup> _buildParentGroups(
    List<Map<String, dynamic>> assets,
    AppLocalizations l10n,
  ) {
    final bySpaceId = <String, List<Map<String, dynamic>>>{};
    for (final asset in assets) {
      final spaceId = _assetSpaceId(asset);
      bySpaceId.putIfAbsent(spaceId, () => <Map<String, dynamic>>[]).add(asset);
    }
    final spaceNameById = <String, String>{
      for (final space in _spaces)
        (space['id'] ?? '').toString(): (space['name'] ?? '').toString(),
    };
    final groups =
        bySpaceId.entries.map((entry) {
          final spaceId = entry.key;
          final label = spaceId.isEmpty
              ? l10n.text('global_scope')
              : (spaceNameById[spaceId]?.trim().isNotEmpty == true
                    ? spaceNameById[spaceId]!
                    : spaceId);
          final sortedAssets = [...entry.value]
            ..sort((a, b) {
              final left = (a['original_filename'] ?? a['id'] ?? '')
                  .toString()
                  .toLowerCase();
              final right = (b['original_filename'] ?? b['id'] ?? '')
                  .toString()
                  .toLowerCase();
              return left.compareTo(right);
            });
          return _MediaParentGroup(
            key: spaceId.isEmpty ? 'global' : 'space:$spaceId',
            label: label,
            assets: sortedAssets,
          );
        }).toList()..sort(
          (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
        );
    return groups;
  }

  Future<void> _openCategorizationDialog(AppLocalizations l10n) async {
    var includeExpired = _includeExpired;
    var onlyExpired = _onlyExpired;
    String? selectedFolder = _selectedFolder;
    String? selectedTag = _selectedTag;

    final shouldApply = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(l10n.text('folders')),
              content: SizedBox(
                width: 760,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: <Widget>[
                          FilterChip(
                            label: Text(l10n.text('include_expired')),
                            selected: includeExpired,
                            onSelected: (value) => setDialogState(() {
                              includeExpired = value;
                              if (!value) onlyExpired = false;
                            }),
                          ),
                          FilterChip(
                            label: Text(l10n.text('expired_assets')),
                            selected: onlyExpired,
                            onSelected: (value) => setDialogState(() {
                              onlyExpired = value;
                              if (value) includeExpired = true;
                            }),
                          ),
                        ],
                      ),
                      if (_folders.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          l10n.text('folders'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: <Widget>[
                            for (final item in _folders)
                              FilterChip(
                                label: Text(
                                  '${(item['value'] ?? '').toString()} (${_toInt(item['count'])})',
                                ),
                                selected:
                                    selectedFolder ==
                                    (item['value'] ?? '').toString(),
                                onSelected: (selected) => setDialogState(() {
                                  selectedFolder = selected
                                      ? (item['value'] ?? '').toString()
                                      : null;
                                }),
                              ),
                          ],
                        ),
                      ],
                      if (_tags.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          l10n.text('tags_label'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: <Widget>[
                            for (final item in _tags)
                              FilterChip(
                                label: Text(
                                  '#${(item['value'] ?? '').toString()} (${_toInt(item['count'])})',
                                ),
                                selected:
                                    selectedTag ==
                                    (item['value'] ?? '').toString(),
                                onSelected: (selected) => setDialogState(() {
                                  selectedTag = selected
                                      ? (item['value'] ?? '').toString()
                                      : null;
                                }),
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
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(l10n.text('cancel')),
                ),
                TextButton(
                  onPressed: () {
                    includeExpired = false;
                    onlyExpired = false;
                    selectedFolder = null;
                    selectedTag = null;
                    Navigator.pop(dialogContext, true);
                  },
                  child: Text(l10n.text('clear_filters')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(l10n.text('save_changes')),
                ),
              ],
            );
          },
        );
      },
    );
    if (shouldApply != true) return;
    setState(() {
      _includeExpired = includeExpired;
      _onlyExpired = onlyExpired;
      _selectedFolder = selectedFolder;
      _selectedTag = selectedTag;
    });
    await _load(resetOffset: true);
  }

  Future<void> _openSavedFiltersDialog(AppLocalizations l10n) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(l10n.text('save_filter')),
              content: SizedBox(
                width: 640,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _savedFilterNameCtrl,
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: l10n.text('saved_filter_name'),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              await _saveCurrentFilter();
                              setDialogState(() {});
                            },
                            icon: const Icon(Icons.save_outlined),
                            label: Text(l10n.text('save_filter')),
                          ),
                        ],
                      ),
                      if (_savedFilters.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: <Widget>[
                            for (final filter in _savedFilters)
                              InputChip(
                                label: Text((filter['name'] ?? '').toString()),
                                onPressed: () async {
                                  await _applySavedFilter(filter);
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                },
                                onDeleted: () {
                                  _clearSavedFilter(filter);
                                  setDialogState(() {});
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
                FilledButton(
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

  Future<void> _openBatchActionsDialog(
    AppLocalizations l10n,
    List<Map<String, dynamic>> visibleAssets,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(l10n.text('apply_batch_changes')),
              content: SizedBox(
                width: 920,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${_selectedAssetIds.length} ${l10n.text('selected_items')}',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton(
                            onPressed: visibleAssets.isEmpty
                                ? null
                                : () {
                                    setState(() {
                                      _selectedAssetIds
                                        ..clear()
                                        ..addAll(
                                          visibleAssets
                                              .map(
                                                (item) => (item['id'] ?? '')
                                                    .toString(),
                                              )
                                              .where((id) => id.isNotEmpty),
                                        );
                                    });
                                    setDialogState(() {});
                                  },
                            child: Text(l10n.text('select_all_visible')),
                          ),
                          TextButton(
                            onPressed: _selectedAssetIds.isEmpty
                                ? null
                                : () {
                                    setState(() => _selectedAssetIds.clear());
                                    setDialogState(() {});
                                  },
                            child: Text(l10n.text('clear_selection')),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 860;
                          final accessModeField =
                              DropdownButtonFormField<String>(
                                initialValue: _batchAccessMode,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText: l10n.text('access_mode'),
                                ),
                                items: <DropdownMenuItem<String>>[
                                  DropdownMenuItem(
                                    value: _noBatchValue,
                                    child: Text(l10n.text('unchanged')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'space',
                                    child: Text(l10n.text('space_members')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'private',
                                    child: Text(l10n.text('owner_only')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'authenticated',
                                    child: Text(
                                      l10n.text('any_signed_in_user'),
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'public',
                                    child: Text(l10n.text('public_label')),
                                  ),
                                ],
                                onChanged: (value) => setState(
                                  () =>
                                      _batchAccessMode = value ?? _noBatchValue,
                                ),
                              );
                          final folderField = TextField(
                            controller: _folderPatchCtrl,
                            enabled: !_clearFolderPatch,
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: l10n.text('folder_path_example'),
                            ),
                          );
                          final tagsField = TextField(
                            controller: _tagsPatchCtrl,
                            enabled: !_clearTagsPatch,
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: l10n.text('tags_comma_separated'),
                            ),
                          );
                          final retentionField = TextField(
                            controller: _retentionPatchCtrl,
                            enabled: !_clearRetentionPatch,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: l10n.text('retention_days'),
                            ),
                          );
                          final clearControls = Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            children: <Widget>[
                              FilterChip(
                                label: Text(l10n.text('clear_folder_path')),
                                selected: _clearFolderPatch,
                                onSelected: (selected) {
                                  setState(() => _clearFolderPatch = selected);
                                  setDialogState(() {});
                                },
                              ),
                              FilterChip(
                                label: Text(l10n.text('clear_tags')),
                                selected: _clearTagsPatch,
                                onSelected: (selected) {
                                  setState(() => _clearTagsPatch = selected);
                                  setDialogState(() {});
                                },
                              ),
                              FilterChip(
                                label: Text(l10n.text('clear_retention')),
                                selected: _clearRetentionPatch,
                                onSelected: (selected) {
                                  setState(
                                    () => _clearRetentionPatch = selected,
                                  );
                                  setDialogState(() {});
                                },
                              ),
                            ],
                          );
                          if (compact) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                accessModeField,
                                const SizedBox(height: AppSpacing.xs),
                                folderField,
                                const SizedBox(height: AppSpacing.xs),
                                tagsField,
                                const SizedBox(height: AppSpacing.xs),
                                retentionField,
                                const SizedBox(height: AppSpacing.xs),
                                clearControls,
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(child: accessModeField),
                                  const SizedBox(width: AppSpacing.xs),
                                  Expanded(child: folderField),
                                  const SizedBox(width: AppSpacing.xs),
                                  Expanded(child: tagsField),
                                  const SizedBox(width: AppSpacing.xs),
                                  SizedBox(width: 150, child: retentionField),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              clearControls,
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.text('cancel')),
                ),
                FilledButton.icon(
                  onPressed:
                      (_selectedAssetIds.isEmpty ||
                          !_hasBatchPatch ||
                          _updating)
                      ? null
                      : () async {
                          await _applyBatchPatch();
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l10n.text('apply_batch_changes')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleQuickAction(
    String action,
    List<Map<String, dynamic>> visibleAssets,
    AppLocalizations l10n,
  ) async {
    switch (action) {
      case 'categories':
        await _openCategorizationDialog(l10n);
        return;
      case 'saved_filters':
        await _openSavedFiltersDialog(l10n);
        return;
      case 'batch':
        await _openBatchActionsDialog(l10n, visibleAssets);
        return;
      case 'cleanup':
        await _cleanupExpired();
        return;
      case 'clear_filters':
        _clearExplorerFilters();
        return;
      case 'select_all_visible':
        setState(() {
          _selectedAssetIds
            ..clear()
            ..addAll(
              visibleAssets
                  .map((item) => (item['id'] ?? '').toString())
                  .where((id) => id.isNotEmpty),
            );
        });
        return;
      case 'clear_selection':
        setState(() => _selectedAssetIds.clear());
        return;
    }
  }

  void _expandAllGroups(List<_MediaParentGroup> groups) {
    if (groups.isEmpty) return;
    setState(() {
      _collapsedParentKeys.removeAll(groups.map((group) => group.key));
    });
  }

  void _collapseAllGroups(List<_MediaParentGroup> groups) {
    if (groups.isEmpty) return;
    setState(() {
      _collapsedParentKeys.addAll(groups.map((group) => group.key));
    });
  }

  PopupMenuItem<String> _quickActionMenuItem({
    required String value,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParentGroupRow({
    required String parentKey,
    required String label,
    required int itemCount,
    required int selectedCount,
    required bool showColumns,
  }) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final collapsed = _collapsedParentKeys.contains(parentKey);
    final selectedText = selectedCount > 0
        ? '$selectedCount ${l10n.text('selected_items')}'
        : '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        splashFactory: NoSplash.splashFactory,
        highlightColor: cs.primary.withValues(alpha: 0.08),
        hoverColor: cs.primary.withValues(alpha: 0.05),
        onTap: () => setState(() {
          if (collapsed) {
            _collapsedParentKeys.remove(parentKey);
          } else {
            _collapsedParentKeys.add(parentKey);
          }
        }),
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
                    onPressed: () => setState(() {
                      if (collapsed) {
                        _collapsedParentKeys.remove(parentKey);
                      } else {
                        _collapsedParentKeys.add(parentKey);
                      }
                    }),
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
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '($itemCount)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (showColumns) ...<Widget>[
                Expanded(
                  flex: 2,
                  child: Text(
                    selectedText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                const Expanded(flex: 3, child: SizedBox.shrink()),
                const SizedBox(width: 120),
                const SizedBox(width: 120),
                const SizedBox(width: 40),
              ] else
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Text(
                    selectedText,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
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
    final unifiedQuery = _parseUnifiedSearchQuery(_searchCtrl.text);
    final searchDiagnostics = validateSearchQueryAst(
      parseSearchQueryAst(_searchCtrl.text),
      capability: mediaSearchCapability,
    ).diagnostics;
    final spaceNameById = <String, String>{
      for (final space in _spaces)
        (space['id'] ?? '').toString(): (space['name'] ?? '').toString(),
    };
    final visibleAssets = _assets
        .where(
          (asset) => _assetMatchesUnifiedSearch(
            asset,
            unifiedQuery,
            spaceNameById,
            l10n,
          ),
        )
        .toList(growable: false);
    final searchSuggestions = _searchSuggestions(l10n);
    final showParentGroups = !unifiedQuery.hideParentGroups;
    final parentGroups = showParentGroups
        ? _buildParentGroups(visibleAssets, l10n)
        : const <_MediaParentGroup>[];
    final hasExpandedGroups =
        showParentGroups &&
        parentGroups.any((group) => !_collapsedParentKeys.contains(group.key));

    return CommandPaletteScope(
      commands: <ContextCommand>[
        ContextCommand(
          label: l10n.text('refresh'),
          subtitle: l10n.text('media_manager'),
          icon: Icons.refresh,
          action: () => _load(resetOffset: true),
        ),
        ContextCommand(
          label: l10n.text('cleanup_expired_assets'),
          subtitle: l10n.text('media_manager'),
          icon: Icons.cleaning_services_outlined,
          action: _cleanupExpired,
        ),
        ContextCommand(
          label: l10n.text('apply_batch_changes'),
          subtitle:
              '${_selectedAssetIds.length} ${l10n.text('selected_items')}',
          icon: Icons.save_outlined,
          action: _applyBatchPatch,
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
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final searchField = TextField(
                          controller: _searchCtrl,
                          focusNode: _searchFocusNode,
                          onSubmitted: (_) async {
                            await _rememberCurrentQuery();
                            await _load(resetOffset: true);
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: l10n.text('search'),
                            hintText: structuredSearchHint(
                              l10n: l10n,
                              capability: mediaSearchCapability,
                              baseHint: l10n.text(
                                'search_hint_media_items_tokens',
                              ),
                            ),
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchCtrl.text.trim().isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      _load(resetOffset: true);
                                    },
                                    tooltip: l10n.text('clear_search'),
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                        );
                        final actionButtons = <Widget>[
                          IconButton(
                            onPressed: _goBackToOrganization,
                            tooltip: l10n.text('organization_access'),
                            icon: const Icon(Icons.arrow_back),
                          ),
                          PopupMenuButton<String>(
                            tooltip: l10n.text('new_item'),
                            onSelected: (value) =>
                                _handleQuickAction(value, visibleAssets, l10n),
                            itemBuilder: (context) => <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(
                                value: 'select_all_visible',
                                child: Text(l10n.text('select_all_visible')),
                              ),
                              PopupMenuItem<String>(
                                value: 'clear_selection',
                                child: Text(l10n.text('clear_selection')),
                              ),
                              PopupMenuItem<String>(
                                value: 'batch',
                                child: Text(l10n.text('apply_batch_changes')),
                              ),
                            ],
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                          SearchHowToButton(capability: mediaSearchCapability),
                          IconButton(
                            tooltip: l10n.text('save_view'),
                            onPressed: _searchCtrl.text.trim().isEmpty
                                ? null
                                : () => _openSavedViewsDialog(l10n),
                            icon: const Icon(Icons.bookmark_add_outlined),
                          ),
                          IconButton(
                            tooltip: l10n.text('load_saved_view'),
                            onPressed: () => _openSavedViewsDialog(l10n),
                            icon: const Icon(Icons.bookmark_outline),
                          ),
                          PopupMenuButton<String>(
                            tooltip: l10n.text('more'),
                            onSelected: (value) =>
                                _handleQuickAction(value, visibleAssets, l10n),
                            itemBuilder: (context) => <PopupMenuEntry<String>>[
                              _quickActionMenuItem(
                                value: 'categories',
                                title: l10n.text('folders'),
                                subtitle: l10n.text('tags_label'),
                                icon: Icons.label_outline,
                              ),
                              _quickActionMenuItem(
                                value: 'saved_filters',
                                title: l10n.text('save_filter'),
                                subtitle: l10n.text('saved_filter_name'),
                                icon: Icons.bookmark_border,
                              ),
                              _quickActionMenuItem(
                                value: 'batch',
                                title: l10n.text('apply_batch_changes'),
                                subtitle:
                                    '${_selectedAssetIds.length} ${l10n.text('selected_items')}',
                                icon: Icons.playlist_add_check_circle_outlined,
                              ),
                              _quickActionMenuItem(
                                value: 'cleanup',
                                title: l10n.text('cleanup_expired_assets'),
                                subtitle: l10n.text('expired_assets'),
                                icon: Icons.cleaning_services_outlined,
                              ),
                              const PopupMenuDivider(),
                              _quickActionMenuItem(
                                value: 'clear_filters',
                                title: l10n.text('clear_filters'),
                                subtitle: l10n.text('search'),
                                icon: Icons.filter_alt_off_outlined,
                              ),
                            ],
                            icon: const Icon(Icons.tune_outlined),
                          ),
                          IconButton(
                            tooltip: l10n.text(
                              hasExpandedGroups ? 'collapse_all' : 'expand_all',
                            ),
                            onPressed: !showParentGroups || parentGroups.isEmpty
                                ? null
                                : () {
                                    if (hasExpandedGroups) {
                                      _collapseAllGroups(parentGroups);
                                    } else {
                                      _expandAllGroups(parentGroups);
                                    }
                                  },
                            icon: Icon(
                              hasExpandedGroups
                                  ? Icons.unfold_less
                                  : Icons.unfold_more,
                            ),
                          ),
                          IconButton(
                            onPressed: _loading
                                ? null
                                : () => _load(resetOffset: true),
                            tooltip: l10n.text('refresh'),
                            icon: const Icon(Icons.refresh),
                          ),
                        ];
                        final compact = constraints.maxWidth < 900;
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
                                      if (index > 0)
                                        const SizedBox(width: AppSpacing.xs),
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
                                onTap: () {
                                  _applySearchSuggestion(suggestion);
                                  _load(resetOffset: true);
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                    if (unifiedQuery.structuredTokens.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppSpacing.xs),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: <Widget>[
                          for (final token in unifiedQuery.structuredTokens)
                            InputChip(
                              label: Text(token.toChipLabel()),
                              onDeleted: () {
                                setState(() {
                                  _removeStructuredSearchToken(token);
                                });
                                _load(resetOffset: true);
                              },
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
                                  '${_selectedAssetIds.length} ${l10n.text('selected_items')}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Text(
                                  '$_totalFiltered ${l10n.text('of_label')} $_totalAssets',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Text(
                                  '$_totalAssets ${l10n.text('total_assets')}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Text(
                                  '$_expiredCount ${l10n.text('expired_assets').toLowerCase()}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                                if (_loadingMore) ...<Widget>[
                                  const SizedBox(width: AppSpacing.sm),
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
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
              ),
              const Divider(height: 1),
              Expanded(
                child: _loading && _assets.isEmpty
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _error != null && _assets.isEmpty
                    ? Center(
                        child: AtlasEmptyState(
                          icon: Icons.error_outline,
                          title: l10n.text('media_manager'),
                          subtitle: _error,
                          action: FilledButton.icon(
                            onPressed: () => _load(resetOffset: true),
                            icon: const Icon(Icons.refresh),
                            label: Text(l10n.text('refresh')),
                          ),
                        ),
                      )
                    : (showParentGroups
                          ? parentGroups.isEmpty
                          : visibleAssets.isEmpty)
                    ? Center(
                        child: AtlasEmptyState(
                          icon: Icons.folder_open_outlined,
                          title: l10n.text('no_media_matches_filters'),
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
                                        child: Text(l10n.text('name')),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(l10n.text('folder')),
                                      ),
                                      Expanded(
                                        flex: 3,
                                        child: Text(l10n.text('tags_label')),
                                      ),
                                      SizedBox(
                                        width: 120,
                                        child: Text(l10n.text('access_mode')),
                                      ),
                                      SizedBox(
                                        width: 120,
                                        child: Text(l10n.text('expires_at')),
                                      ),
                                      const SizedBox(width: 40),
                                    ],
                                  ),
                                ),
                              if (showColumns) const Divider(height: 1),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    AppSpacing.sm,
                                    AppSpacing.xs,
                                    AppSpacing.sm,
                                    0,
                                  ),
                                  child: Row(
                                    children: <Widget>[
                                      Icon(
                                        Icons.error_outline,
                                        size: 16,
                                        color: cs.error,
                                      ),
                                      const SizedBox(width: AppSpacing.xs),
                                      Expanded(
                                        child: Text(
                                          _error!,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(color: cs.error),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Expanded(
                                child: showParentGroups
                                    ? ListView.builder(
                                        controller: _listScrollCtrl,
                                        itemCount:
                                            parentGroups.length +
                                            (_loadingMore ? 1 : 0),
                                        itemBuilder: (context, index) {
                                          if (index >= parentGroups.length) {
                                            return const Padding(
                                              padding: EdgeInsets.all(
                                                AppSpacing.sm,
                                              ),
                                              child: Center(
                                                child: SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                              ),
                                            );
                                          }
                                          final group = parentGroups[index];
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: <Widget>[
                                              _buildParentGroupRow(
                                                parentKey: group.key,
                                                label: group.label,
                                                itemCount: group.assets.length,
                                                selectedCount: group.assets
                                                    .where(
                                                      (item) =>
                                                          _selectedAssetIds
                                                              .contains(
                                                                (item['id'] ??
                                                                        '')
                                                                    .toString(),
                                                              ),
                                                    )
                                                    .length,
                                                showColumns: showColumns,
                                              ),
                                              ClipRect(
                                                child: AnimatedSize(
                                                  duration: const Duration(
                                                    milliseconds: 220,
                                                  ),
                                                  curve: Curves.easeInOutCubic,
                                                  alignment:
                                                      Alignment.topCenter,
                                                  child:
                                                      _collapsedParentKeys
                                                          .contains(group.key)
                                                      ? const SizedBox.shrink()
                                                      : Column(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: <Widget>[
                                                            for (final asset
                                                                in group.assets)
                                                              _MediaManagerRow(
                                                                asset: asset,
                                                                indentLevel: 1,
                                                                selected: _selectedAssetIds
                                                                    .contains(
                                                                      (asset['id'] ??
                                                                              '')
                                                                          .toString(),
                                                                    ),
                                                                onSelected: (value) {
                                                                  final id =
                                                                      (asset['id'] ??
                                                                              '')
                                                                          .toString();
                                                                  if (id
                                                                      .isEmpty) {
                                                                    return;
                                                                  }
                                                                  setState(() {
                                                                    if (value) {
                                                                      _selectedAssetIds
                                                                          .add(
                                                                            id,
                                                                          );
                                                                    } else {
                                                                      _selectedAssetIds
                                                                          .remove(
                                                                            id,
                                                                          );
                                                                    }
                                                                  });
                                                                },
                                                              ),
                                                          ],
                                                        ),
                                                ),
                                              ),
                                              const Divider(height: 1),
                                            ],
                                          );
                                        },
                                      )
                                    : ListView.builder(
                                        controller: _listScrollCtrl,
                                        itemCount:
                                            visibleAssets.length +
                                            (_loadingMore ? 1 : 0),
                                        itemBuilder: (context, index) {
                                          if (index >= visibleAssets.length) {
                                            return const Padding(
                                              padding: EdgeInsets.all(
                                                AppSpacing.sm,
                                              ),
                                              child: Center(
                                                child: SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                              ),
                                            );
                                          }
                                          final asset = visibleAssets[index];
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: <Widget>[
                                              _MediaManagerRow(
                                                asset: asset,
                                                indentLevel: 0,
                                                selected: _selectedAssetIds
                                                    .contains(
                                                      (asset['id'] ?? '')
                                                          .toString(),
                                                    ),
                                                onSelected: (value) {
                                                  final id = (asset['id'] ?? '')
                                                      .toString();
                                                  if (id.isEmpty) {
                                                    return;
                                                  }
                                                  setState(() {
                                                    if (value) {
                                                      _selectedAssetIds.add(id);
                                                    } else {
                                                      _selectedAssetIds.remove(
                                                        id,
                                                      );
                                                    }
                                                  });
                                                },
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaParentGroup {
  final String key;
  final String label;
  final List<Map<String, dynamic>> assets;

  const _MediaParentGroup({
    required this.key,
    required this.label,
    required this.assets,
  });
}

enum _SearchCategory { tags, folders, spaces, usage, flags }

class _MediaUnifiedSearchQuery {
  final List<String> terms;
  final SearchExpressionNode? expression;
  final List<String> tagFilters;
  final List<String> excludedTagFilters;
  final List<String> folderFilters;
  final List<String> excludedFolderFilters;
  final List<String> spaceFilters;
  final List<String> excludedSpaceFilters;
  final List<String> usageFilters;
  final List<String> excludedUsageFilters;
  final Set<String> flags;
  final List<SearchFieldToken> structuredTokens;

  const _MediaUnifiedSearchQuery({
    required this.terms,
    required this.expression,
    required this.tagFilters,
    required this.excludedTagFilters,
    required this.folderFilters,
    required this.excludedFolderFilters,
    required this.spaceFilters,
    required this.excludedSpaceFilters,
    required this.usageFilters,
    required this.excludedUsageFilters,
    required this.flags,
    required this.structuredTokens,
  });

  bool get hideParentGroups =>
      flags.contains('hide-parents') && !flags.contains('show-parents');
}

class _SearchSuggestion {
  final String label;
  final String tokenText;
  final bool appendSpace;
  final String? subtitle;

  const _SearchSuggestion({
    required this.label,
    required this.tokenText,
    required this.appendSpace,
    this.subtitle,
  });
}

class _MediaManagerRow extends StatelessWidget {
  final Map<String, dynamic> asset;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final int indentLevel;

  const _MediaManagerRow({
    required this.asset,
    required this.selected,
    required this.onSelected,
    this.indentLevel = 0,
  });

  IconData _iconForContentType(String? contentType) {
    final normalized = (contentType ?? '').toLowerCase();
    if (normalized.startsWith('image/')) return Icons.image_outlined;
    if (normalized.startsWith('video/')) return Icons.movie_outlined;
    if (normalized.startsWith('audio/')) return Icons.music_note_outlined;
    if (normalized.contains('pdf')) return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _expiryLabel(Map<String, dynamic> row, AppLocalizations l10n) {
    if (_isExpired(row)) return l10n.text('expired_assets');
    final raw = (row['expires_at'] ?? '').toString().trim();
    if (raw.isEmpty) return '-';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final filename = (asset['original_filename'] ?? asset['id'] ?? '')
        .toString();
    final url = (asset['url'] ?? '').toString();
    final contentType = asset['content_type']?.toString();
    final folder = (asset['folder_path'] ?? '').toString();
    final tags = _stringList(asset['tags']);
    final tagsText = tags.isEmpty ? '-' : tags.map((tag) => '#$tag').join(', ');
    final usage = (asset['usage'] ?? '').toString();
    final accessMode = (asset['access_mode'] ?? '').toString();
    final typeIcon = _iconForContentType(contentType);
    final expiry = _expiryLabel(asset, l10n);

    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
      child: InkWell(
        onTap: () => onSelected(!selected),
        child: Container(
          height: 62,
          padding: EdgeInsets.only(
            left: AppSpacing.sm + (indentLevel * 18),
            right: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 980;
              if (compact) {
                return Row(
                  children: <Widget>[
                    Checkbox(
                      value: selected,
                      onChanged: (value) => onSelected(value ?? false),
                    ),
                    Icon(typeIcon, size: 18),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$usage • ${folder.isEmpty ? '-' : folder}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    SizedBox(
                      width: 84,
                      child: Text(
                        accessMode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    IconButton(
                      tooltip: l10n.text('preview_media'),
                      onPressed: url.trim().isEmpty
                          ? null
                          : () => showMediaPreviewDialog(
                              context: context,
                              filename: filename,
                              url: url,
                              contentType: contentType,
                            ),
                      icon: const Icon(Icons.open_in_full_outlined),
                    ),
                  ],
                );
              }

              return Row(
                children: <Widget>[
                  SizedBox(
                    width: 44,
                    child: Checkbox(
                      value: selected,
                      onChanged: (value) => onSelected(value ?? false),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Row(
                      children: <Widget>[
                        Icon(typeIcon, size: 18),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                filename,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                usage,
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
                  Expanded(
                    flex: 2,
                    child: Text(
                      folder.isEmpty ? '-' : folder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      tagsText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: Text(
                      accessMode,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: Text(
                      expiry,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      tooltip: l10n.text('preview_media'),
                      onPressed: url.trim().isEmpty
                          ? null
                          : () => showMediaPreviewDialog(
                              context: context,
                              filename: filename,
                              url: url,
                              contentType: contentType,
                            ),
                      icon: const Icon(Icons.open_in_full_outlined),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

Map<String, dynamic> _toJsonRow(Object? raw) {
  if (raw is Map) {
    return raw.cast<String, dynamic>();
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _toJsonRows(Object? raw) {
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
  }
  return const [];
}

List<String> _stringList(Object? raw) {
  if (raw is List) {
    return raw
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  return const [];
}

int _toInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  return 0;
}

bool _isExpired(Map<String, dynamic> asset) {
  final expiresAtRaw = (asset['expires_at'] ?? '').toString().trim();
  if (expiresAtRaw.isEmpty) return false;
  final expiresAt = DateTime.tryParse(expiresAtRaw);
  if (expiresAt == null) return false;
  return expiresAt.isBefore(DateTime.now().toUtc());
}

String _dioMessage(BuildContext context, DioException e) {
  return dioErrorMessage(e, context: context);
}
