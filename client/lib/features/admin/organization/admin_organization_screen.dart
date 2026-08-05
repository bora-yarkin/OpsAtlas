// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Main organization management screen for graph edits, roles, branding, and policy tools.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/auth_store.dart';
import '../../../core/api/branding.dart';
import '../../../core/api/mfa_guard.dart';
import '../../../core/api/request_error.dart';
import '../../../core/i18n/app_localizations.dart';
import '../../../core/platform/file_download.dart';
import '../../../core/search/query_ast.dart';
import '../../../core/search/search_capabilities.dart';
import '../../../core/search/search_diagnostics_widget.dart';
import '../../../core/search/search_help.dart';
import '../../../core/search/search_state.dart';
import '../../../core/search/search_validation.dart';
import '../../../core/theme/theme.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/atlas_ui.dart';
import '../../../core/widgets/media_upload_section.dart';
import '../../../core/widgets/media_preview_dialog.dart';

part 'admin_organization_models.dart';
part 'admin_organization_mutations.dart';
part 'admin_organization_search.dart';
part 'admin_organization_relationship_actions.dart';
part 'admin_organization_localization_manager.dart';
part 'admin_organization_localization_manager_actions.dart';
part 'admin_organization_translation_review.dart';
part 'admin_organization_tools.dart';
part 'admin_organization_tree_view.dart';
part 'admin_organization_editor_helpers.dart';
part 'admin_organization_global_items.dart';

final adminCustomizationProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(apiClientProvider);
  final r = await api.dio.get('/admin/customization');
  return (r.data as Map).cast<String, dynamic>();
});

final adminOrganizationItemLinksProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(apiClientProvider);
      final r = await api.dio.get('/admin/org/item-links');
      return (r.data as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    });

final adminOrganizationItemsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(apiClientProvider);
      final r = await api.dio.get('/admin/org/items');
      return (r.data as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    });

final adminOrgMeProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final response = await api.dio.get('/auth/me');
  return (response.data as Map).cast<String, dynamic>();
});

class AdminOrganizationScreen extends ConsumerStatefulWidget {
  final String? initialSearchQuery;

  const AdminOrganizationScreen({super.key, this.initialSearchQuery});

  @override
  ConsumerState<AdminOrganizationScreen> createState() =>
      _AdminOrganizationScreenState();
}

class _AdminOrganizationScreenState
    extends ConsumerState<AdminOrganizationScreen> {
  static const String _manualRootShortcutPrefsKey =
      'admin_organization_manual_root_shortcuts_v2';
  static const int _treeSearchMinChars = 3;
  static const String _treeSearchSurfaceId = 'organization_tree';
  static const String _globalItemsSearchSurfaceId = 'organization_global_items';

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _globalItemsSearchCtrl = TextEditingController();
  final TextEditingController _treeSavedViewNameCtrl = TextEditingController();
  final TextEditingController _globalItemsSavedViewNameCtrl =
      TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _treeScrollCtrl = ScrollController();

  final Set<String> _expandedKeys = <String>{};
  final Map<String, ValueNotifier<bool>> _expandedByKey =
      <String, ValueNotifier<bool>>{};
  final Set<String> _manualRootShortcutKeys = <String>{};
  String? _selectedItemKey;
  bool _moreActionsExpanded = false;

  List<Map<String, dynamic>>? _cachedItemsSource;
  List<Map<String, dynamic>>? _cachedItemLinksSource;
  _TreeData? _cachedTreeData;
  _TreeData? _childrenCacheData;
  Locale? _childrenCacheLocale;
  final Map<String, List<_LinkRef>> _childrenCacheByItemKey =
      <String, List<_LinkRef>>{};
  _TreeData? _itemTextCacheData;
  Locale? _itemTextCacheLocale;
  final Map<String, String> _itemLabelCacheByItemKey = <String, String>{};
  final Map<String, String> _itemSubtitleCacheByItemKey = <String, String>{};
  _TreeData? _rootLinksCacheData;
  Locale? _rootLinksCacheLocale;
  String? _rootLinksCacheManualSignature;
  List<_LinkRef>? _rootLinksCache;
  List<String> _treeRecentQueries = const <String>[];
  List<SearchSavedView> _treeSavedViews = const <SearchSavedView>[];
  List<String> _globalItemsRecentQueries = const <String>[];
  List<SearchSavedView> _globalItemsSavedViews = const <SearchSavedView>[];
  final Map<String, Future<List<Map<String, dynamic>>>>
  _auditEventsFutureByItemKey = <String, Future<List<Map<String, dynamic>>>>{};

  Future<void> _loadSearchState() async {
    final treeRecent = await SearchStateStore.loadRecentQueries(
      _treeSearchSurfaceId,
    );
    final treeViews = await SearchStateStore.loadSavedViews(
      _treeSearchSurfaceId,
    );
    final globalRecent = await SearchStateStore.loadRecentQueries(
      _globalItemsSearchSurfaceId,
    );
    final globalViews = await SearchStateStore.loadSavedViews(
      _globalItemsSearchSurfaceId,
    );
    if (!mounted) return;
    setState(() {
      _treeRecentQueries = treeRecent;
      _treeSavedViews = treeViews;
      _globalItemsRecentQueries = globalRecent;
      _globalItemsSavedViews = globalViews;
    });
  }

  Future<void> _rememberTreeSearchQuery() async {
    final normalized = normalizeSearchInput(_searchCtrl.text);
    if (normalized.isEmpty) return;
    await SearchStateStore.rememberQuery(_treeSearchSurfaceId, normalized);
    final recent = await SearchStateStore.loadRecentQueries(
      _treeSearchSurfaceId,
    );
    if (!mounted) return;
    setState(() => _treeRecentQueries = recent);
  }

  Future<void> _saveTreeQueryView() async {
    final name = _treeSavedViewNameCtrl.text.trim();
    final query = normalizeSearchInput(_searchCtrl.text);
    if (name.isEmpty || query.isEmpty) {
      return;
    }
    await SearchStateStore.saveView(
      _treeSearchSurfaceId,
      name: name,
      query: query,
    );
    final views = await SearchStateStore.loadSavedViews(_treeSearchSurfaceId);
    if (!mounted) return;
    setState(() {
      _treeSavedViewNameCtrl.clear();
      _treeSavedViews = views;
    });
  }

  Future<void> _applyTreeSavedView(SearchSavedView view) async {
    final normalized = normalizeSearchInput(view.query);
    _searchCtrl.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
    await SearchStateStore.touchView(_treeSearchSurfaceId, view.id);
    await _rememberTreeSearchQuery();
  }

  Future<void> _deleteTreeSavedView(SearchSavedView view) async {
    await SearchStateStore.deleteView(_treeSearchSurfaceId, view.id);
    final views = await SearchStateStore.loadSavedViews(_treeSearchSurfaceId);
    if (!mounted) return;
    setState(() => _treeSavedViews = views);
  }

  Future<void> _rememberGlobalItemsQuery() async {
    final normalized = normalizeSearchInput(_globalItemsSearchCtrl.text);
    if (normalized.isEmpty) return;
    await SearchStateStore.rememberQuery(
      _globalItemsSearchSurfaceId,
      normalized,
    );
    final recent = await SearchStateStore.loadRecentQueries(
      _globalItemsSearchSurfaceId,
    );
    if (!mounted) return;
    setState(() => _globalItemsRecentQueries = recent);
  }

  Future<void> _saveGlobalItemsQueryView() async {
    final name = _globalItemsSavedViewNameCtrl.text.trim();
    final query = normalizeSearchInput(_globalItemsSearchCtrl.text);
    if (name.isEmpty || query.isEmpty) {
      return;
    }
    await SearchStateStore.saveView(
      _globalItemsSearchSurfaceId,
      name: name,
      query: query,
    );
    final views = await SearchStateStore.loadSavedViews(
      _globalItemsSearchSurfaceId,
    );
    if (!mounted) return;
    setState(() {
      _globalItemsSavedViewNameCtrl.clear();
      _globalItemsSavedViews = views;
    });
  }

  Future<void> _applyGlobalItemsSavedView(SearchSavedView view) async {
    final normalized = normalizeSearchInput(view.query);
    _globalItemsSearchCtrl.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
    await SearchStateStore.touchView(_globalItemsSearchSurfaceId, view.id);
    await _rememberGlobalItemsQuery();
  }

  Future<void> _deleteGlobalItemsSavedView(SearchSavedView view) async {
    await SearchStateStore.deleteView(_globalItemsSearchSurfaceId, view.id);
    final views = await SearchStateStore.loadSavedViews(
      _globalItemsSearchSurfaceId,
    );
    if (!mounted) return;
    setState(() => _globalItemsSavedViews = views);
  }

  Future<void> _openSavedViewsDialog({
    required AppLocalizations l10n,
    required TextEditingController nameCtrl,
    required List<SearchSavedView> initialViews,
    required Future<void> Function() onSaveCurrent,
    required Future<List<SearchSavedView>> Function() reloadViews,
    required Future<void> Function(SearchSavedView view) onApply,
    required Future<void> Function(SearchSavedView view) onDelete,
    required void Function(List<SearchSavedView> views) updateViews,
  }) async {
    var dialogViews = List<SearchSavedView>.from(initialViews);
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
                        controller: nameCtrl,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: l10n.text('saved_view_name'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          await onSaveCurrent();
                          final views = await reloadViews();
                          if (!mounted) return;
                          updateViews(views);
                          setDialogState(() => dialogViews = views);
                        },
                        icon: const Icon(Icons.save_outlined),
                        label: Text(l10n.text('save_view')),
                      ),
                      if (dialogViews.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: <Widget>[
                            for (final view in dialogViews)
                              InputChip(
                                label: Text(view.name),
                                onPressed: () async {
                                  await onApply(view);
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                },
                                onDeleted: () async {
                                  await onDelete(view);
                                  final views = await reloadViews();
                                  if (!mounted) return;
                                  updateViews(views);
                                  setDialogState(() => dialogViews = views);
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

  Future<void> _openTreeSavedViewsDialog(AppLocalizations l10n) async {
    _treeSavedViewNameCtrl.text = '';
    await _openSavedViewsDialog(
      l10n: l10n,
      nameCtrl: _treeSavedViewNameCtrl,
      initialViews: _treeSavedViews,
      onSaveCurrent: _saveTreeQueryView,
      reloadViews: () => SearchStateStore.loadSavedViews(_treeSearchSurfaceId),
      onApply: _applyTreeSavedView,
      onDelete: _deleteTreeSavedView,
      updateViews: (views) => setState(() => _treeSavedViews = views),
    );
  }

  Future<void> _openGlobalItemsSavedViewsDialog(AppLocalizations l10n) async {
    _globalItemsSavedViewNameCtrl.text = '';
    await _openSavedViewsDialog(
      l10n: l10n,
      nameCtrl: _globalItemsSavedViewNameCtrl,
      initialViews: _globalItemsSavedViews,
      onSaveCurrent: _saveGlobalItemsQueryView,
      reloadViews: () =>
          SearchStateStore.loadSavedViews(_globalItemsSearchSurfaceId),
      onApply: _applyGlobalItemsSavedView,
      onDelete: _deleteGlobalItemsSavedView,
      updateViews: (views) => setState(() => _globalItemsSavedViews = views),
    );
  }

  void _handleTreeSearchChanged() {
    if (!mounted) return;
    setState(() {});
    _syncSearchRoute();
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
      path: '/organization',
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
    _searchCtrl.addListener(_handleTreeSearchChanged);
    _searchFocusNode.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    _loadSearchState();
    _loadManualRootShortcuts();
  }

  @override
  void didUpdateWidget(covariant AdminOrganizationScreen oldWidget) {
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
    for (final notifier in _expandedByKey.values) {
      notifier.dispose();
    }
    _searchCtrl
      ..removeListener(_handleTreeSearchChanged)
      ..dispose();
    _globalItemsSearchCtrl.dispose();
    _treeSavedViewNameCtrl.dispose();
    _globalItemsSavedViewNameCtrl.dispose();
    _searchFocusNode.dispose();
    _treeScrollCtrl.dispose();
    super.dispose();
  }

  _ItemRef? _itemRefFromKey(String key) {
    final parts = key.split(':');
    if (parts.length != 2) return null;
    final type = parts.first.trim();
    final id = parts.last.trim();
    if (id.isEmpty) return null;
    final kind = switch (type) {
      'department' => _ItemKind.department,
      'space' => _ItemKind.space,
      'user' => _ItemKind.user,
      'role' => _ItemKind.role,
      _ => null,
    };
    if (kind == null) return null;
    return _ItemRef(kind: kind, id: id);
  }

  Future<void> _loadManualRootShortcuts() async {
    final sp = await SharedPreferences.getInstance();
    final saved =
        sp.getStringList(_manualRootShortcutPrefsKey) ?? const <String>[];
    final normalized = <String>{};
    for (final entry in saved) {
      final ref = _itemRefFromKey(entry);
      if (ref == null || ref.kind == _ItemKind.role) continue;
      normalized.add(ref.key);
    }
    if (!mounted) return;
    setState(() {
      _manualRootShortcutKeys
        ..clear()
        ..addAll(normalized);
    });
  }

  Future<void> _persistManualRootShortcuts() async {
    final sp = await SharedPreferences.getInstance();
    final values = _manualRootShortcutKeys.toList()..sort();
    await sp.setStringList(_manualRootShortcutPrefsKey, values);
  }

  bool _itemExistsInData(_ItemRef ref, _TreeData data) {
    return switch (ref.kind) {
      _ItemKind.department => data.unitById.containsKey(ref.id),
      _ItemKind.space => data.spaceById.containsKey(ref.id),
      _ItemKind.user => data.userById.containsKey(ref.id),
      _ItemKind.role => data.roleByKey.containsKey(ref.id),
    };
  }

  _TreeData _buildTreeData({
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>> itemLinks,
  }) {
    final canReuse =
        identical(_cachedItemsSource, items) &&
        identical(_cachedItemLinksSource, itemLinks);
    if (canReuse && _cachedTreeData != null) {
      return _cachedTreeData!;
    }
    final built = _TreeData(items: items, itemLinks: itemLinks);
    _cachedItemsSource = items;
    _cachedItemLinksSource = itemLinks;
    _cachedTreeData = built;
    return built;
  }

  void _refreshAll() {
    _auditEventsFutureByItemKey.clear();
    ref.invalidate(adminCustomizationProvider);
    ref.invalidate(brandingProvider);
    ref.invalidate(adminOrganizationItemsProvider);
    ref.invalidate(adminOrganizationItemLinksProvider);
    ref.invalidate(adminOrgMeProvider);
  }

  String? _normalizeLanguageCode(Object? raw) {
    if (raw is! String) return null;
    final normalized = raw.trim().replaceAll('_', '-').toLowerCase();
    return normalized.isEmpty ? null : normalized;
  }

  Future<List<_LocalizationLanguageChoice>>
  _loadLocalizationLanguageChoices() async {
    final api = ref.read(apiClientProvider);
    final l10n = AppLocalizations.of(context);
    try {
      final response = await api.dio.get('/localization/catalog');
      final payload = (response.data as Map).cast<String, dynamic>();
      final rawLanguages = payload['languages'];
      if (rawLanguages is List) {
        final choices = <_LocalizationLanguageChoice>[];
        for (final row in rawLanguages) {
          if (row is! Map) continue;
          final mapped = row.cast<String, dynamic>();
          final code = _normalizeLanguageCode(mapped['code']);
          if (code == null) continue;
          if (mapped['enabled'] != true && mapped['is_default'] != true) {
            continue;
          }
          final rawName = (mapped['name'] ?? '').toString().trim();
          choices.add(
            _LocalizationLanguageChoice(
              code: code,
              name: rawName.isEmpty ? code.toUpperCase() : rawName,
            ),
          );
        }
        choices.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        if (choices.isNotEmpty) {
          return choices;
        }
      }
    } catch (_) {
      // fall back to static defaults when localization APIs are unavailable
    }
    return <_LocalizationLanguageChoice>[
      _LocalizationLanguageChoice(code: 'de', name: l10n.text('german')),
      _LocalizationLanguageChoice(code: 'en', name: l10n.text('english')),
      _LocalizationLanguageChoice(code: 'tr', name: l10n.text('turkish')),
    ];
  }

  Future<Map<String, dynamic>?> _loadUserLocalizationPreference(
    String userId,
  ) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return null;
    }
    final api = ref.read(apiClientProvider);
    try {
      final response = await api.dio.get(
        '/localization/preferences/users/$normalizedUserId',
      );
      final payload = response.data;
      if (payload is Map) {
        return payload.cast<String, dynamic>();
      }
    } catch (_) {
      // ignore and keep editor usable without localization preference preload
    }
    return null;
  }

  Future<void> _saveUserLocalizationPreference({
    required String userId,
    required String selection,
  }) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return;
    final api = ref.read(apiClientProvider);
    if (selection == '__org_default__') {
      await api.dio.patch(
        '/localization/preferences/users/$normalizedUserId',
        data: <String, dynamic>{'language_code': null, 'use_org_default': true},
      );
      return;
    }
    await api.dio.patch(
      '/localization/preferences/users/$normalizedUserId',
      data: <String, dynamic>{
        'language_code': selection,
        'use_org_default': false,
      },
    );
  }

  String? _regionDefaultLanguageCodeFromMeta(Map<String, dynamic>? unit) {
    if (unit == null) return null;
    final rawMeta = unit['meta'];
    if (rawMeta is! Map) return null;
    return _normalizeLanguageCode(rawMeta['default_language_code']);
  }

  String _slugify(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _dioMessage(DioException error) {
    return requestErrorMessage(error, context: context);
  }

  @override
  Widget build(BuildContext context) {
    return _buildOrganizationTreeScreen(context);
  }
}
