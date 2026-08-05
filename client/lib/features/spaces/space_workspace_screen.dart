// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Unified space workspace that merges KB docs, SOPs, and incidents into one explorer.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:html_editor_enhanced/html_editor.dart';

import '../../core/api/api_client.dart';
import '../../core/api/auth_store.dart';
import '../../core/api/request_error.dart';
import '../../core/analytics_tracker.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/navigation/app_route_navigation.dart';
import '../../core/search/query_ast.dart';
import '../../core/search/search_capabilities.dart';
import '../../core/search/search_diagnostics_widget.dart';
import '../../core/search/search_help.dart';
import '../../core/search/search_validation.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/media_preview_dialog.dart';
import '../../core/widgets/rich_content.dart';
import 'spaces_screen.dart';
import 'workspace_surface_shell.dart';

part 'space_workspace_core.dart';
part 'space_workspace_kb_doc_editor.dart';
part 'space_workspace_sop_editor.dart';
part 'space_workspace_incident_editor.dart';
part 'space_workspace_incident_support_dialogs.dart';
part 'space_workspace_shared_widgets.dart';
part 'space_workspace_models.dart';
part 'space_workspace_sop_editor_support.dart';
part 'space_workspace_kb_helpers.dart';
part 'space_workspace_shared_dialogs.dart';

class SpaceWorkspaceScreen extends ConsumerStatefulWidget {
  final String spaceId;
  final String initialSection;
  final String? initialSearchQuery;
  final String? createAction;
  final String? openDocId;
  final String? openDocSlug;
  final String? openSopId;
  final String? openSopSlug;
  final String? openSopStepId;
  final String? openSopRunId;
  final String? openIncidentId;
  final String? openTimelineId;
  final String? openActionItemId;
  final String? openTaskId;

  const SpaceWorkspaceScreen({
    super.key,
    required this.spaceId,
    this.initialSection = 'kb',
    this.initialSearchQuery,
    this.createAction,
    this.openDocId,
    this.openDocSlug,
    this.openSopId,
    this.openSopSlug,
    this.openSopStepId,
    this.openSopRunId,
    this.openIncidentId,
    this.openTimelineId,
    this.openActionItemId,
    this.openTaskId,
  });

  @override
  ConsumerState<SpaceWorkspaceScreen> createState() =>
      _SpaceWorkspaceScreenState();
}

class _SpaceWorkspaceScreenState extends ConsumerState<SpaceWorkspaceScreen> {
  static const String _searchSurfaceId = 'space_workspace_unified';
  static const Set<String> _defaultExpandedTreeIds = <String>{};

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final Set<String> _expandedTreeIds = <String>{..._defaultExpandedTreeIds};
  final Map<String, Future<_KbDocDetailData>> _docDetailFutures =
      <String, Future<_KbDocDetailData>>{};
  final Map<String, Future<JsonMap>> _sopDetailFutures =
      <String, Future<JsonMap>>{};
  final Map<String, Future<JsonMap>> _incidentDetailFutures =
      <String, Future<JsonMap>>{};
  final Map<String, String?> _selectedSopRunIds = <String, String?>{};
  late Future<_WorkspaceBundle> _bundleFuture;

  String? _handledCreateSignature;
  Timer? _routeSyncDebounce;
  bool _seededInitialFolderExpansion = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = _initialWorkspaceQuery(widget);
    _bundleFuture = _loadBundle();
    _searchCtrl.addListener(_handleSearchChanged);
  }

  @override
  void didUpdateWidget(covariant SpaceWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spaceId != widget.spaceId) {
      _expandedTreeIds
        ..clear()
        ..addAll(_defaultExpandedTreeIds);
      _clearDetailCaches();
      _bundleFuture = _loadBundle();
      _handledCreateSignature = null;
      _seededInitialFolderExpansion = false;
    }
    final nextQuery = _initialWorkspaceQuery(widget);
    final currentQuery = _normalizeWorkspaceSearchInput(_searchCtrl.text);
    if (nextQuery != currentQuery) {
      _searchCtrl.value = TextEditingValue(
        text: nextQuery,
        selection: TextSelection.collapsed(offset: nextQuery.length),
      );
    }
  }

  @override
  void dispose() {
    _routeSyncDebounce?.cancel();
    _searchCtrl.removeListener(_handleSearchChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String _initialWorkspaceQuery(SpaceWorkspaceScreen widget) {
    final explicit = _normalizeWorkspaceSearchInput(
      widget.initialSearchQuery ?? '',
    );
    if (explicit.isNotEmpty) {
      return explicit;
    }
    return '';
  }

  void _handleSearchChanged() {
    _scheduleRouteSync();
  }

  Future<_WorkspaceBundle> _loadBundle() async {
    final api = ref.read(apiClientProvider);
    final auth = ref.read(authStoreProvider);
    final canEditSpace = auth.role != 'viewer';

    Future<Response<dynamic>?> optionalGet(
      String path, {
      Map<String, dynamic>? queryParameters,
    }) async {
      try {
        return await api.dio.get(path, queryParameters: queryParameters);
      } catch (_) {
        return null;
      }
    }

    final responses = await Future.wait<Object?>(<Future<Object?>>[
      api.dio.get(
        '/kb/spaces/${widget.spaceId}/folders',
        queryParameters: {'flat': true},
      ),
      api.dio.get(
        '/kb/spaces/${widget.spaceId}/docs',
        queryParameters: {
          'all_folders': true,
          'published_only': !canEditSpace,
          if (canEditSpace) 'include_deleted': false,
        },
      ),
      optionalGet('/kb/spaces/${widget.spaceId}/tags'),
      optionalGet('/kb/spaces/${widget.spaceId}/review-summary'),
      api.dio.get(
        '/sop/spaces/${widget.spaceId}/sops',
        queryParameters: {
          'published_only': !canEditSpace,
          if (canEditSpace) 'include_archived': true,
        },
      ),
      optionalGet('/sop/spaces/${widget.spaceId}/due-runs'),
      api.dio.get(
        '/incidents/spaces/${widget.spaceId}',
        queryParameters: {if (canEditSpace) 'include_archived': true},
      ),
      optionalGet('/incidents/spaces/${widget.spaceId}/analytics'),
    ]);

    final foldersResponse = responses[0] as Response<dynamic>;
    final docsResponse = responses[1] as Response<dynamic>;
    final tagsResponse = responses[2] as Response<dynamic>?;
    final reviewSummaryResponse = responses[3] as Response<dynamic>?;
    final sopsResponse = responses[4] as Response<dynamic>;
    final dueRunsResponse = responses[5] as Response<dynamic>?;
    final incidentsResponse = responses[6] as Response<dynamic>;
    final incidentAnalyticsResponse = responses[7] as Response<dynamic>?;

    return _WorkspaceBundle(
      folders: _asJsonList(foldersResponse.data),
      docs: _asJsonList(docsResponse.data),
      tags: _asStringList(_asJsonMap(tagsResponse?.data)['tags']),
      reviewSummary: reviewSummaryResponse == null
          ? null
          : _asJsonMap(reviewSummaryResponse.data),
      sops: _asJsonList(sopsResponse.data),
      dueRuns: dueRunsResponse == null
          ? const <JsonMap>[]
          : _asJsonList(dueRunsResponse.data),
      incidents: _asJsonList(incidentsResponse.data),
      incidentAnalytics: incidentAnalyticsResponse == null
          ? <String, dynamic>{}
          : _asJsonMap(incidentAnalyticsResponse.data),
      tasks: const <JsonMap>[],
    );
  }

  void _reloadBundle({bool clearCaches = false}) {
    if (clearCaches) {
      _clearDetailCaches();
    }
    setState(() {
      _bundleFuture = _loadBundle();
    });
  }

  void _clearDetailCaches() {
    _docDetailFutures.clear();
    _sopDetailFutures.clear();
    _incidentDetailFutures.clear();
  }

  void _scheduleRouteSync() {
    _routeSyncDebounce?.cancel();
    _routeSyncDebounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) {
        _syncRouteFromState();
      }
    });
  }

  void _syncRouteFromState({bool immediate = false}) {
    if (!mounted) {
      return;
    }
    final normalizedQuery = _normalizeWorkspaceSearchInput(_searchCtrl.text);
    final currentUri = GoRouterState.of(context).uri;
    final nextParams = Map<String, String>.from(currentUri.queryParameters);
    nextParams.remove('tab');
    nextParams.remove('docId');
    nextParams.remove('docSlug');
    nextParams.remove('sopId');
    nextParams.remove('sopSlug');
    nextParams.remove('sopStepId');
    nextParams.remove('sopRunId');
    nextParams.remove('incidentId');
    nextParams.remove('timelineId');
    nextParams.remove('actionItemId');
    nextParams.remove('create');
    if (normalizedQuery.isEmpty) {
      nextParams.remove('search');
    } else {
      nextParams['search'] = normalizedQuery;
    }
    nextParams.remove('taskId');
    final nextUri = Uri(
      path: '/spaces/${widget.spaceId}',
      queryParameters: nextParams.isEmpty ? null : nextParams,
    );
    if (currentUri.path == nextUri.path && currentUri.query == nextUri.query) {
      return;
    }
    if (immediate) {
      context.replace(nextUri.toString());
      return;
    }
    context.replace(nextUri.toString());
  }

  _WorkspaceEntityRef? _desiredEntityFromWidget(_WorkspaceBundle bundle) {
    String normalizeId(String? raw) => (raw ?? '').trim();

    final docId = normalizeId(widget.openDocId);
    if (docId.isNotEmpty) {
      return _WorkspaceEntityRef(_WorkspaceEntityType.doc, docId);
    }
    final docSlug = normalizeId(widget.openDocSlug);
    if (docSlug.isNotEmpty) {
      for (final row in bundle.docs) {
        if ((row['slug'] ?? '').toString().trim() == docSlug) {
          return _WorkspaceEntityRef(
            _WorkspaceEntityType.doc,
            (row['id'] ?? '').toString(),
          );
        }
      }
    }

    final sopId = normalizeId(widget.openSopId);
    if (sopId.isNotEmpty) {
      return _WorkspaceEntityRef(_WorkspaceEntityType.sop, sopId);
    }
    final sopSlug = normalizeId(widget.openSopSlug);
    if (sopSlug.isNotEmpty) {
      for (final row in bundle.sops) {
        if ((row['slug'] ?? '').toString().trim() == sopSlug) {
          return _WorkspaceEntityRef(
            _WorkspaceEntityType.sop,
            (row['id'] ?? '').toString(),
          );
        }
      }
    }

    final incidentId = normalizeId(widget.openIncidentId);
    if (incidentId.isNotEmpty) {
      return _WorkspaceEntityRef(_WorkspaceEntityType.incident, incidentId);
    }
    return null;
  }

  bool _routeTargetsEntity() {
    bool present(String? value) => (value ?? '').trim().isNotEmpty;
    return present(widget.openDocId) ||
        present(widget.openDocSlug) ||
        present(widget.openSopId) ||
        present(widget.openSopSlug) ||
        present(widget.openIncidentId);
  }

  Future<void> _maybeHandlePendingCreate() async {
    final createAction = (widget.createAction ?? '').trim();
    if (createAction.isEmpty) {
      return;
    }
    final signature = '${widget.spaceId}:$createAction';
    if (_handledCreateSignature == signature) {
      return;
    }
    _handledCreateSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      bool? changed;
      switch (createAction) {
        case 'doc':
          changed = await _openDocEditor();
          break;
        case 'sop':
          changed = await _openSopEditor();
          break;
        case 'incident':
          changed = await _openIncidentEditor();
          break;
      }
      if (!mounted) {
        return;
      }
      _syncRouteFromState(immediate: true);
      if (changed == true) {
        _reloadBundle(clearCaches: true);
      }
    });
  }

  String _spaceRoute({
    String? search,
    String? docId,
    String? sopId,
    String? incidentId,
  }) {
    final queryParameters = <String, String>{
      if ((search ?? '').trim().isNotEmpty) 'search': search!.trim(),
      if ((docId ?? '').trim().isNotEmpty) 'docId': docId!.trim(),
      if ((sopId ?? '').trim().isNotEmpty) 'sopId': sopId!.trim(),
      if ((incidentId ?? '').trim().isNotEmpty)
        'incidentId': incidentId!.trim(),
    };
    return Uri(
      path: '/spaces/${widget.spaceId}',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    ).toString();
  }

  String _routeForEntity(_WorkspaceEntityRef entity) {
    final search = _normalizeWorkspaceSearchInput(_searchCtrl.text);
    return switch (entity.type) {
      _WorkspaceEntityType.doc => _spaceRoute(search: search, docId: entity.id),
      _WorkspaceEntityType.sop => _spaceRoute(search: search, sopId: entity.id),
      _WorkspaceEntityType.incident => _spaceRoute(
        search: search,
        incidentId: entity.id,
      ),
      _WorkspaceEntityType.task => Uri(
        path: '/tasks',
        queryParameters: <String, String>{
          if (widget.spaceId.trim().isNotEmpty) 'spaceId': widget.spaceId,
          if (entity.id.trim().isNotEmpty) 'search': entity.id,
        },
      ).toString(),
    };
  }

  Future<void> _openEntityScreen(_WorkspaceEntityRef entity) async {
    await atlasOpenRoute<void>(context, _routeForEntity(entity));
    if (mounted) {
      _reloadBundle(clearCaches: true);
    }
  }

  void _applySearchText(String raw) {
    final normalized = _normalizeWorkspaceSearchInput(raw);
    _searchCtrl.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
    _syncRouteFromState(immediate: true);
  }

  void _clearSearch() {
    if (_searchCtrl.text.isEmpty) {
      return;
    }
    _applySearchText('');
  }

  void _toggleTreeNode(String nodeId) {
    setState(() {
      if (_expandedTreeIds.contains(nodeId)) {
        _expandedTreeIds.remove(nodeId);
      } else {
        _expandedTreeIds.add(nodeId);
      }
    });
  }

  void _seedInitialFolderExpansion(_WorkspaceBundle bundle) {
    if (_seededInitialFolderExpansion) {
      return;
    }
    _seededInitialFolderExpansion = true;
    for (final folder in bundle.folders) {
      final parentId = (folder['parent_id'] ?? '').toString().trim();
      final folderId = (folder['id'] ?? '').toString().trim();
      if (parentId.isNotEmpty || folderId.isEmpty) {
        continue;
      }
      _expandedTreeIds.add('folder:$folderId');
    }
  }

  Future<bool?> _openDocEditor({JsonMap? existingDoc, String? folderId}) {
    return _showLargeDialog<bool>(
      context,
      _KbDocEditorDialog(
        spaceId: widget.spaceId,
        folderId: existingDoc?['folder_id']?.toString() ?? folderId,
        existingDoc: existingDoc,
      ),
    );
  }

  Future<bool?> _openSopEditor({JsonMap? existingSopDetail, String? folderId}) {
    return _showLargeDialog<bool>(
      context,
      _SopEditorDialog(
        spaceId: widget.spaceId,
        folderId: existingSopDetail?['folder_id']?.toString() ?? folderId,
        existingSopDetail: existingSopDetail,
      ),
    );
  }

  Future<bool?> _openIncidentEditor({
    JsonMap? existingIncidentDetail,
    String? folderId,
  }) {
    return _showLargeDialog<bool>(
      context,
      _IncidentEditorDialog(
        spaceId: widget.spaceId,
        folderId: existingIncidentDetail?['folder_id']?.toString() ?? folderId,
        existingIncidentDetail: existingIncidentDetail,
      ),
    );
  }

  Future<bool?> _openIncidentStatusUpdate({
    required String incidentId,
    required JsonMap incidentDetail,
  }) {
    return _showLargeDialog<bool>(
      context,
      _IncidentStatusUpdateDialog(
        incidentId: incidentId,
        incidentDetail: incidentDetail,
        allowPublic: true,
        allowPrivate: true,
      ),
    );
  }

  Future<bool?> _openIncidentActionItemDialog({
    required String incidentId,
    JsonMap? existingItem,
  }) {
    return _showLargeDialog<bool>(
      context,
      _IncidentActionItemDialog(
        incidentId: incidentId,
        spaceId: widget.spaceId,
        existingItem: existingItem,
      ),
    );
  }

  Future<bool?> _openIncidentTimelineEntryDialog({required String incidentId}) {
    return _showLargeDialog<bool>(
      context,
      _TimelineEntryDialog(incidentId: incidentId, spaceId: widget.spaceId),
    );
  }

  Future<List<JsonMap>> _loadFoldersFlat() async {
    final api = ref.read(apiClientProvider);
    final response = await api.dio.get(
      '/kb/spaces/${widget.spaceId}/folders',
      queryParameters: const {'flat': true},
    );
    return _asJsonList(response.data);
  }

  Future<bool> _moveWorkspaceItem(_WorkspaceItemRecord item) async {
    if (item.type == _WorkspaceEntityType.task) {
      return false;
    }

    final folders = await _loadFoldersFlat();
    if (!mounted) {
      return false;
    }
    final targetFolderId = await _showMoveToFolderDialog(
      context,
      folders,
      title: item.title,
      typeLabel: item.typeLabel,
      initialFolderId: item.folderId,
    );
    if (targetFolderId == null) {
      return false;
    }

    final normalizedFolderId = targetFolderId.trim().isEmpty
        ? null
        : targetFolderId.trim();
    final currentFolderId = (item.folderId ?? '').trim();
    if ((normalizedFolderId ?? '') == currentFolderId) {
      return false;
    }

    final api = ref.read(apiClientProvider);
    try {
      switch (item.type) {
        case _WorkspaceEntityType.doc:
          await api.dio.put(
            '/kb/docs/${item.ref.id}',
            data: {
              'title': (item.raw['title'] ?? '').toString(),
              'slug': (item.raw['slug'] ?? '').toString(),
              'content_md': (item.raw['content_md'] ?? '').toString(),
              'folder_id': normalizedFolderId,
              'tags': _asStringList(item.raw['tags']),
              'review_due_at': item.raw['review_due_at'],
              'reviewer_user_id':
                  (item.raw['reviewer_user_id'] ?? '').toString().trim().isEmpty
                  ? null
                  : item.raw['reviewer_user_id'],
              'review_reminder_days': item.raw['review_reminder_days'],
              'base_updated_at': item.raw['updated_at'],
            },
          );
          break;
        case _WorkspaceEntityType.sop:
          await api.dio.put(
            '/sop/sops/${item.ref.id}',
            data: {
              'title': (item.raw['title'] ?? '').toString(),
              'slug': (item.raw['slug'] ?? '').toString(),
              'overview_md': (item.raw['overview_md'] ?? '').toString(),
              'folder_id': normalizedFolderId,
              'review_due_at': item.raw['review_due_at'],
              'reviewer_user_id':
                  (item.raw['reviewer_user_id'] ?? '').toString().trim().isEmpty
                  ? null
                  : item.raw['reviewer_user_id'],
              'requires_approval': item.raw['requires_approval'] == true,
            },
          );
          break;
        case _WorkspaceEntityType.incident:
          await api.dio.put(
            '/incidents/${item.ref.id}',
            data: {
              'title': (item.raw['title'] ?? '').toString(),
              'status': (item.raw['status'] ?? 'open').toString(),
              'severity': _asInt(item.raw['severity']),
              'folder_id': normalizedFolderId,
              'incident_type': (item.raw['incident_type'] ?? 'service')
                  .toString(),
              'summary_md':
                  (item.raw['summary_md'] ?? item.raw['summary'] ?? '')
                      .toString(),
              'transition_note': '',
            },
          );
          break;
        case _WorkspaceEntityType.task:
          break;
      }
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_errorText(error))));
      return false;
    }
  }

  Future<_KbDocDetailData> _loadDocDetail(String docId) {
    final existing = _docDetailFutures[docId];
    if (existing != null) {
      return existing;
    }
    final future = () async {
      final api = ref.read(apiClientProvider);
      final detailResponse = await api.dio.get('/kb/docs/$docId/detail');
      final commentsResponse = await api.dio.get('/kb/docs/$docId/comments');
      List<JsonMap> versions = const <JsonMap>[];
      try {
        final versionsResponse = await api.dio.get('/kb/docs/$docId/versions');
        versions = _asJsonList(versionsResponse.data);
      } catch (_) {
        versions = const <JsonMap>[];
      }
      JsonMap? diff;
      try {
        final diffResponse = await api.dio.get('/kb/docs/$docId/diff');
        diff = _asJsonMap(diffResponse.data);
      } catch (_) {
        diff = null;
      }
      trackEntityView(
        ref,
        entityType: 'doc',
        entityId: docId,
        path: '/spaces/${widget.spaceId}?docId=$docId',
        spaceId: widget.spaceId,
        surface: _searchSurfaceId,
      );
      return _KbDocDetailData(
        doc: _asJsonMap(detailResponse.data),
        versions: versions,
        comments: _asJsonList(commentsResponse.data),
        diff: diff,
      );
    }();
    _docDetailFutures[docId] = future;
    return future;
  }

  Future<JsonMap> _loadSopDetail(String sopId) {
    final existing = _sopDetailFutures[sopId];
    if (existing != null) {
      return existing;
    }
    final future = () async {
      final api = ref.read(apiClientProvider);
      final response = await api.dio.get('/sop/sops/$sopId/detail');
      trackEntityView(
        ref,
        entityType: 'sop',
        entityId: sopId,
        path: '/spaces/${widget.spaceId}?sopId=$sopId',
        spaceId: widget.spaceId,
        surface: _searchSurfaceId,
      );
      return _asJsonMap(response.data);
    }();
    _sopDetailFutures[sopId] = future;
    return future;
  }

  Future<JsonMap> _loadIncidentDetail(String incidentId) {
    final existing = _incidentDetailFutures[incidentId];
    if (existing != null) {
      return existing;
    }
    final future = () async {
      final api = ref.read(apiClientProvider);
      final response = await api.dio.get('/incidents/$incidentId');
      final detail = _asJsonMap(response.data);
      trackEntityView(
        ref,
        entityType: 'incident',
        entityId: incidentId,
        path: '/spaces/${widget.spaceId}?incidentId=$incidentId',
        spaceId: widget.spaceId,
        surface: _searchSurfaceId,
      );
      return detail;
    }();
    _incidentDetailFutures[incidentId] = future;
    return future;
  }

  List<_WorkspaceTreeNode> _buildTreeNodes(
    _WorkspaceBundle bundle,
    List<_WorkspaceItemRecord> visibleItems,
    _WorkspaceSearchQuery query,
  ) {
    final searching = query.ast.raw.trim().isNotEmpty;
    final knownFolderIds = bundle.folders
        .map((folder) => (folder['id'] ?? '').toString().trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    final foldersByParent = <String?, List<JsonMap>>{};
    for (final folder in bundle.folders) {
      final parentId = (folder['parent_id'] ?? '').toString().trim();
      (foldersByParent[parentId.isEmpty ? null : parentId] ??= <JsonMap>[]).add(
        folder,
      );
    }
    for (final rows in foldersByParent.values) {
      rows.sort((left, right) {
        final leftName = (left['name'] ?? '').toString().toLowerCase();
        final rightName = (right['name'] ?? '').toString().toLowerCase();
        return leftName.compareTo(rightName);
      });
    }

    final itemsByFolder = <String?, List<_WorkspaceItemRecord>>{};

    for (final item in visibleItems) {
      final rawFolderId = (item.folderId ?? '').trim();
      final folderId = knownFolderIds.contains(rawFolderId) ? rawFolderId : '';
      (itemsByFolder[folderId.isEmpty ? null : folderId] ??=
              <_WorkspaceItemRecord>[])
          .add(item);
    }

    List<_WorkspaceTreeNode> buildItemNodes(
      Iterable<_WorkspaceItemRecord> rows,
    ) {
      return rows
          .map(
            (item) => _WorkspaceTreeNode(
              id: 'item:${item.type.name}:${item.ref.id}',
              kind: _WorkspaceTreeNodeKind.item,
              category: item.type,
              title: item.title,
              subtitle: _itemTreeSubtitle(item),
              icon: _itemIcon(item.type),
              entity: item.ref,
              record: item,
            ),
          )
          .toList(growable: false);
    }

    List<_WorkspaceTreeNode> buildFolderNodes(String? parentId) {
      final nodes = <_WorkspaceTreeNode>[];
      for (final folder in foldersByParent[parentId] ?? const <JsonMap>[]) {
        final folderId = (folder['id'] ?? '').toString().trim();
        final children = <_WorkspaceTreeNode>[
          ...buildFolderNodes(folderId),
          ...buildItemNodes(
            itemsByFolder[folderId] ?? const <_WorkspaceItemRecord>[],
          ),
        ];
        if (searching && children.isEmpty) {
          continue;
        }
        nodes.add(
          _WorkspaceTreeNode(
            id: 'folder:$folderId',
            kind: _WorkspaceTreeNodeKind.folder,
            category: _WorkspaceEntityType.doc,
            title: ((folder['name'] ?? 'Folder').toString().trim()).isEmpty
                ? 'Folder'
                : (folder['name'] ?? 'Folder').toString(),
            subtitle: _folderTreeSubtitle(children),
            icon: Icons.folder_outlined,
            folder: folder,
            children: children,
          ),
        );
      }
      return nodes;
    }

    return <_WorkspaceTreeNode>[
      ...buildFolderNodes(null),
      ...buildItemNodes(itemsByFolder[null] ?? const <_WorkspaceItemRecord>[]),
    ];
  }

  String _folderTreeSubtitle(List<_WorkspaceTreeNode> children) {
    var folderCount = 0;
    var itemCount = 0;
    for (final child in children) {
      if (child.kind == _WorkspaceTreeNodeKind.folder) {
        folderCount++;
      }
      if (child.kind == _WorkspaceTreeNodeKind.item) {
        itemCount++;
      }
    }
    final parts = <String>[
      if (folderCount > 0)
        '$folderCount subfolder${folderCount == 1 ? '' : 's'}',
      '$itemCount item${itemCount == 1 ? '' : 's'}',
    ];
    return parts.join(' • ');
  }

  String _itemTreeSubtitle(_WorkspaceItemRecord item) {
    final parts = <String>[
      if (item.type == _WorkspaceEntityType.doc &&
          (item.folderPath ?? '').trim().isNotEmpty)
        item.folderPath!.trim(),
      if (item.status.trim().isNotEmpty) item.status.replaceAll('_', ' '),
      if (item.type == _WorkspaceEntityType.sop && item.runOverdue)
        'overdue run',
      if (item.severity != null) 'SEV ${item.severity}',
      if (item.dueAt != null)
        'due ${_formatDate(item.dueAt!.toIso8601String())}',
      if (item.updatedAt != null)
        'updated ${_formatDate(item.updatedAt!.toIso8601String())}',
    ];
    if (parts.isEmpty) {
      return item.typeLabel;
    }
    return parts.join(' • ');
  }

  IconData _itemIcon(_WorkspaceEntityType type) {
    return switch (type) {
      _WorkspaceEntityType.doc => Icons.description_outlined,
      _WorkspaceEntityType.sop => Icons.checklist_outlined,
      _WorkspaceEntityType.incident => Icons.report_problem_outlined,
      _WorkspaceEntityType.task => Icons.assignment_outlined,
    };
  }

  List<_WorkspaceItemRecord> _buildItems(_WorkspaceBundle bundle) {
    final now = DateTime.now().toUtc();
    final dueRunBySopId = <String, JsonMap>{};
    for (final run in bundle.dueRuns) {
      final sopId = (run['sop_id'] ?? '').toString().trim();
      if (sopId.isEmpty) {
        continue;
      }
      dueRunBySopId[sopId] = run;
    }

    final items = <_WorkspaceItemRecord>[];

    for (final doc in bundle.docs) {
      final id = (doc['id'] ?? '').toString().trim();
      if (id.isEmpty) {
        continue;
      }
      final title = (doc['title'] ?? '').toString().trim();
      final content = (doc['content_md'] ?? '').toString();
      final tags = _asStringList(doc['tags']);
      final folderPath = (doc['folder_path'] ?? '').toString().trim();
      items.add(
        _WorkspaceItemRecord(
          ref: _WorkspaceEntityRef(_WorkspaceEntityType.doc, id),
          title: title.isEmpty ? 'Untitled doc' : title,
          typeLabel: 'KB',
          slug: (doc['slug'] ?? '').toString(),
          status: (doc['status'] ?? '').toString().trim(),
          summary: _richPreviewText(content).isEmpty
              ? folderPath
              : _richPreviewText(content),
          searchText: [
            title,
            (doc['slug'] ?? '').toString(),
            content,
            folderPath,
            tags.join(' '),
            (doc['reviewer_name'] ?? '').toString(),
          ].join(' ').toLowerCase(),
          folderId: (doc['folder_id'] ?? '').toString().trim(),
          folderPath: folderPath,
          updatedAt: DateTime.tryParse(
            (doc['updated_at'] ?? '').toString(),
          )?.toUtc(),
          createdAt: DateTime.tryParse(
            (doc['created_at'] ?? '').toString(),
          )?.toUtc(),
          dueAt: DateTime.tryParse(
            (doc['review_due_at'] ?? '').toString(),
          )?.toUtc(),
          severity: null,
          tags: tags,
          archived: doc['deleted_at'] != null,
          needsReview: doc['is_stale'] == true,
          reviewDue:
              DateTime.tryParse(
                (doc['review_due_at'] ?? '').toString(),
              )?.toUtc().isBefore(now) ==
              true,
          hasLinkedTasks: false,
          runOverdue: false,
          runActive: false,
          sourceKind: '',
          raw: doc,
        ),
      );
    }

    for (final sop in bundle.sops) {
      final id = (sop['id'] ?? '').toString().trim();
      if (id.isEmpty) {
        continue;
      }
      final folderPath = (sop['folder_path'] ?? '').toString().trim();
      final dueRun = dueRunBySopId[id];
      final dueAt = DateTime.tryParse(
        (dueRun?['next_due_at'] ?? '').toString(),
      )?.toUtc();
      final overdue =
          dueRun?['overdue'] == true ||
          (dueAt != null && dueAt.isBefore(now) && sop['archived_at'] == null);
      items.add(
        _WorkspaceItemRecord(
          ref: _WorkspaceEntityRef(_WorkspaceEntityType.sop, id),
          title: ((sop['title'] ?? '').toString().trim()).isEmpty
              ? 'Untitled SOP'
              : (sop['title'] ?? '').toString(),
          typeLabel: 'SOP',
          slug: (sop['slug'] ?? '').toString(),
          status: (sop['status'] ?? '').toString().trim(),
          summary: [
            if (folderPath.isNotEmpty) folderPath,
            if ((sop['reviewer_name'] ?? '').toString().trim().isNotEmpty)
              'Reviewer ${(sop['reviewer_name'] ?? '').toString().trim()}',
            if (dueAt != null)
              'Next run ${_formatDate(dueAt.toIso8601String())}',
            if (sop['pending_approval'] == true) 'Pending approval',
          ].join(' • '),
          searchText: [
            (sop['title'] ?? '').toString(),
            (sop['slug'] ?? '').toString(),
            (sop['status'] ?? '').toString(),
            folderPath,
            (sop['reviewer_name'] ?? '').toString(),
            dueRun?['title']?.toString() ?? '',
            if (overdue) 'overdue run',
          ].join(' ').toLowerCase(),
          folderId: (sop['folder_id'] ?? '').toString().trim(),
          folderPath: folderPath,
          updatedAt: DateTime.tryParse(
            (sop['updated_at'] ?? '').toString(),
          )?.toUtc(),
          createdAt: DateTime.tryParse(
            (sop['created_at'] ?? '').toString(),
          )?.toUtc(),
          dueAt: dueAt,
          severity: null,
          tags: const <String>[],
          archived: sop['archived'] == true || sop['archived_at'] != null,
          needsReview: false,
          reviewDue:
              DateTime.tryParse(
                (sop['review_due_at'] ?? '').toString(),
              )?.toUtc().isBefore(now) ==
              true,
          hasLinkedTasks: _asInt(sop['linked_task_count']) > 0,
          runOverdue: overdue,
          runActive: false,
          sourceKind: '',
          raw: <String, dynamic>{...sop, 'due_run': dueRun},
        ),
      );
    }

    for (final incident in bundle.incidents) {
      final id = (incident['id'] ?? '').toString().trim();
      if (id.isEmpty) {
        continue;
      }
      final folderPath = (incident['folder_path'] ?? '').toString().trim();
      items.add(
        _WorkspaceItemRecord(
          ref: _WorkspaceEntityRef(_WorkspaceEntityType.incident, id),
          title: ((incident['title'] ?? '').toString().trim()).isEmpty
              ? 'Untitled incident'
              : (incident['title'] ?? '').toString(),
          typeLabel: 'Incident',
          slug: (incident['slug'] ?? '').toString(),
          status: (incident['status'] ?? '').toString().trim(),
          summary: (incident['summary'] ?? incident['summary_md'] ?? '')
              .toString(),
          searchText: [
            (incident['title'] ?? '').toString(),
            (incident['summary'] ?? incident['summary_md'] ?? '').toString(),
            (incident['status'] ?? '').toString(),
            folderPath,
            (incident['severity'] ?? '').toString(),
            (incident['on_call_user_name'] ?? '').toString(),
          ].join(' ').toLowerCase(),
          folderId: (incident['folder_id'] ?? '').toString().trim(),
          folderPath: folderPath,
          updatedAt: DateTime.tryParse(
            (incident['updated_at'] ?? '').toString(),
          )?.toUtc(),
          createdAt: DateTime.tryParse(
            (incident['created_at'] ?? '').toString(),
          )?.toUtc(),
          dueAt: null,
          severity: _asInt(incident['severity']),
          tags: const <String>[],
          archived:
              incident['archived'] == true || incident['archived_at'] != null,
          needsReview: false,
          reviewDue: false,
          hasLinkedTasks: _asInt(incident['linked_task_count']) > 0,
          runOverdue: false,
          runActive: false,
          sourceKind: '',
          raw: incident,
        ),
      );
    }

    return items;
  }

  _WorkspaceSearchQuery _parseWorkspaceSearchQuery(String raw) {
    final normalized = _normalizeWorkspaceSearchInput(raw);
    final ast = parseSearchQueryAst(normalized);
    _WorkspaceSortMode sortMode = _WorkspaceSortMode.updated;
    for (final token in ast.fieldTokens) {
      if (token.normalizedField != 'sort' || !token.hasValue) {
        continue;
      }
      sortMode = switch (token.normalizedValue) {
        'created' => _WorkspaceSortMode.created,
        'title' => _WorkspaceSortMode.title,
        'status' => _WorkspaceSortMode.status,
        'due' => _WorkspaceSortMode.due,
        'severity' => _WorkspaceSortMode.severity,
        _ => _WorkspaceSortMode.updated,
      };
    }
    return _WorkspaceSearchQuery(ast: ast, sortMode: sortMode);
  }

  bool _matchesWorkspaceItem(
    _WorkspaceItemRecord item,
    _WorkspaceSearchQuery query,
  ) {
    if (query.ast.raw.trim().isEmpty) {
      return true;
    }
    return evaluateSearchExpression(
      query.ast.expression,
      matchesField: (token) => _matchesFieldToken(item, token),
      matchesText: (token) => item.searchText.contains(token.normalizedValue),
    );
  }

  bool _matchesFieldToken(_WorkspaceItemRecord item, SearchFieldToken token) {
    if (!token.hasValue) {
      return true;
    }
    final value = token.normalizedValue;
    bool matched = switch (token.normalizedField) {
      'type' ||
      'types' ||
      'category' ||
      'kind' ||
      'item' ||
      'items' => _matchesTypeValue(item.type, value),
      'status' || 'state' => item.status.toLowerCase().contains(value),
      'folder' || 'path' =>
        (item.folderId ?? '').toLowerCase().contains(value) ||
            (item.folderPath ?? '').toLowerCase().contains(value),
      'tag' ||
      'tags' => item.tags.any((tag) => tag.toLowerCase().contains(value)),
      'stale' || 'needs_review' =>
        item.type == _WorkspaceEntityType.doc &&
            (_parseBoolSearchValue(value) == item.needsReview),
      'review' =>
        (item.type == _WorkspaceEntityType.doc ||
                item.type == _WorkspaceEntityType.sop) &&
            (_parseBoolSearchValue(value) == item.reviewDue),
      'severity' || 'sev' || 's' => item.severity?.toString() == value,
      'run' => _matchesRunValue(item, value),
      'source' ||
      'source_kind' => item.sourceKind.toLowerCase().contains(value),
      'archived' || 'archive' => _parseBoolSearchValue(value) == item.archived,
      'linked' ||
      'task' ||
      'tasks' ||
      'linked_work' => _parseBoolSearchValue(value) == item.hasLinkedTasks,
      'sort' => true,
      _ => true,
    };
    if (token.isNegated) {
      matched = !matched;
    }
    return matched;
  }

  bool _matchesTypeValue(_WorkspaceEntityType type, String value) {
    return switch (type) {
      _WorkspaceEntityType.doc => <String>{
        'doc',
        'docs',
        'document',
        'documents',
        'kb',
      }.contains(value),
      _WorkspaceEntityType.sop => <String>{
        'sop',
        'sops',
        'procedure',
        'procedures',
      }.contains(value),
      _WorkspaceEntityType.incident => <String>{
        'incident',
        'incidents',
        'report',
        'reports',
      }.contains(value),
      _WorkspaceEntityType.task => <String>{
        'task',
        'tasks',
        'tracker',
        'tracking',
      }.contains(value),
    };
  }

  bool _matchesRunValue(_WorkspaceItemRecord item, String value) {
    if (item.type == _WorkspaceEntityType.task) {
      return switch (value) {
        'active' => item.runActive,
        'overdue' =>
          item.dueAt != null && item.dueAt!.isBefore(DateTime.now().toUtc()),
        _ => item.sourceKind.toLowerCase().contains(value),
      };
    }
    if (item.type != _WorkspaceEntityType.sop) {
      return false;
    }
    return switch (value) {
      'overdue' => item.runOverdue,
      'active' => item.runActive,
      'scheduled' || 'recent' => item.dueAt != null,
      _ => false,
    };
  }

  List<_WorkspaceItemRecord> _visibleItems(
    _WorkspaceBundle bundle,
    _WorkspaceSearchQuery query,
  ) {
    final visible = _buildItems(bundle)
        .where((item) => _matchesWorkspaceItem(item, query))
        .toList(growable: false);
    final items = List<_WorkspaceItemRecord>.from(visible);
    items.sort((left, right) {
      switch (query.sortMode) {
        case _WorkspaceSortMode.title:
          return left.title.toLowerCase().compareTo(right.title.toLowerCase());
        case _WorkspaceSortMode.created:
          return _compareDates(right.createdAt, left.createdAt);
        case _WorkspaceSortMode.status:
          return left.status.toLowerCase().compareTo(
            right.status.toLowerCase(),
          );
        case _WorkspaceSortMode.due:
          return _compareDates(left.dueAt, right.dueAt);
        case _WorkspaceSortMode.severity:
          return (right.severity ?? -1).compareTo(left.severity ?? -1);
        case _WorkspaceSortMode.updated:
          return _compareDates(right.updatedAt, left.updatedAt);
      }
    });
    return items;
  }

  int _compareDates(DateTime? left, DateTime? right) {
    if (left == null && right == null) {
      return 0;
    }
    if (left == null) {
      return 1;
    }
    if (right == null) {
      return -1;
    }
    return left.compareTo(right);
  }

  List<_WorkspaceSearchSuggestion> _searchSuggestions(_WorkspaceBundle bundle) {
    final raw = _searchCtrl.text;
    final tokenContext = parseAtTokenSuggestionContext(raw);
    if (tokenContext == null) {
      return const <_WorkspaceSearchSuggestion>[];
    }

    if (!tokenContext.hasValueSeparator) {
      const fieldSuggestions = <MapEntry<String, String>>[
        MapEntry<String, String>('type', 'type'),
        MapEntry<String, String>('status', 'status'),
        MapEntry<String, String>('folder', 'folder'),
        MapEntry<String, String>('tag', 'tag'),
        MapEntry<String, String>('stale', 'stale'),
        MapEntry<String, String>('review', 'review'),
        MapEntry<String, String>('severity', 'severity'),
        MapEntry<String, String>('run', 'run'),
        MapEntry<String, String>('source', 'source'),
        MapEntry<String, String>('sort', 'sort'),
      ];
      return fieldSuggestions
          .where(
            (entry) =>
                entry.key.startsWith(tokenContext.partialFieldLower.trim()),
          )
          .map(
            (entry) => _WorkspaceSearchSuggestion(
              label: '@${entry.value}',
              tokenText: '@${entry.key}:',
              appendSpace: false,
            ),
          )
          .toList(growable: false);
    }

    Iterable<_WorkspaceSearchSuggestion> valuesForField(String field) {
      switch (field) {
        case 'type':
          return <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: _t(context, 'kb'),
              tokenText: '@type:kb',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'sops'),
              tokenText: '@type:sop',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'incidents'),
              tokenText: '@type:incident',
              appendSpace: true,
            ),
          ];
        case 'status':
          return <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: _statusText(context, 'draft'),
              tokenText: '@status:draft',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _statusText(context, 'published'),
              tokenText: '@status:published',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _statusText(context, 'open'),
              tokenText: '@status:open',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _statusText(context, 'monitoring'),
              tokenText: '@status:monitoring',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _statusText(context, 'resolved'),
              tokenText: '@status:resolved',
              appendSpace: true,
            ),
          ];
        case 'stale':
          return <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: _t(context, 'meta_value_true'),
              tokenText: '@stale:true',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'meta_value_false'),
              tokenText: '@stale:false',
              appendSpace: true,
            ),
          ];
        case 'archived':
          return <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: _t(context, 'meta_value_true'),
              tokenText: '@archived:true',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'meta_value_false'),
              tokenText: '@archived:false',
              appendSpace: true,
            ),
          ];
        case 'review':
          return <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: _t(context, 'meta_value_true'),
              tokenText: '@review:true',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'meta_value_false'),
              tokenText: '@review:false',
              appendSpace: true,
            ),
          ];
        case 'run':
          return <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: _t(context, 'overdue'),
              tokenText: '@run:overdue',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'active_label'),
              tokenText: '@run:active',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'scheduled'),
              tokenText: '@run:scheduled',
              appendSpace: true,
            ),
          ];
        case 'source':
          return const <_WorkspaceSearchSuggestion>[];
        case 'sort':
          return <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: _t(context, 'updated_label'),
              tokenText: '@sort:updated',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'created_label'),
              tokenText: '@sort:created',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'title_label'),
              tokenText: '@sort:title',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'status'),
              tokenText: '@sort:status',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'due'),
              tokenText: '@sort:due',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: _t(context, 'severity'),
              tokenText: '@sort:severity',
              appendSpace: true,
            ),
          ];
        case 'folder':
          return bundle.folders.map((folder) {
            final path = (folder['path'] ?? folder['name'] ?? '').toString();
            return _WorkspaceSearchSuggestion(
              label: path,
              tokenText: '@folder:${_quoteSearchValue(path)}',
              appendSpace: true,
            );
          });
        case 'tag':
          return bundle.tags.map(
            (tag) => _WorkspaceSearchSuggestion(
              label: tag,
              tokenText: '@tag:$tag',
              appendSpace: true,
            ),
          );
        case 'severity':
          return const <_WorkspaceSearchSuggestion>[
            _WorkspaceSearchSuggestion(
              label: '1',
              tokenText: '@severity:1',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: '2',
              tokenText: '@severity:2',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: '3',
              tokenText: '@severity:3',
              appendSpace: true,
            ),
            _WorkspaceSearchSuggestion(
              label: '4',
              tokenText: '@severity:4',
              appendSpace: true,
            ),
          ];
      }
      return const <_WorkspaceSearchSuggestion>[];
    }

    return valuesForField(tokenContext.fieldLower)
        .where(
          (suggestion) =>
              tokenContext.partialValueLower.isEmpty ||
              suggestion.tokenText.toLowerCase().contains(
                tokenContext.partialValueLower,
              ) ||
              suggestion.label.toLowerCase().contains(
                tokenContext.partialValueLower,
              ),
        )
        .toList(growable: false);
  }

  void _applyWorkspaceSearchSuggestion(_WorkspaceSearchSuggestion suggestion) {
    final next = applyAtTokenSuggestion(
      raw: _searchCtrl.text,
      suggestionToken: suggestion.tokenText,
      appendSpace: suggestion.appendSpace,
    );
    _searchCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _searchFocus.requestFocus();
    _syncRouteFromState(immediate: true);
  }

  Future<void> _handleCreateAction(String action, {String? folderId}) async {
    bool? changed;
    switch (action) {
      case 'doc':
        changed = await _openDocEditor(folderId: folderId);
        break;
      case 'sop':
        changed = await _openSopEditor(folderId: folderId);
        break;
      case 'incident':
        changed = await _openIncidentEditor(folderId: folderId);
        break;
      case 'folder':
        final api = ref.read(apiClientProvider);
        changed = await _showCreateFolderDialog(
          context,
          api,
          spaceId: widget.spaceId,
          parentId: folderId,
        );
        break;
    }
    if (changed == true && mounted) {
      _reloadBundle(clearCaches: true);
    }
  }

  Future<void> _handleToolbarAction(
    String action,
    _WorkspaceBundle bundle,
  ) async {
    switch (action) {
      case 'info':
        await _showWorkspaceStats(bundle);
        return;
      case 'doc':
      case 'sop':
      case 'incident':
      case 'folder':
        await _handleCreateAction(action);
        return;
      case 'docs-review':
        _applySearchText('@type:kb @stale:true');
        return;
      case 'sops-overdue':
        _applySearchText('@type:sop @run:overdue');
        return;
      case 'incidents-open':
        _applySearchText('@type:incident @status:open');
        return;
      case 'incidents-monitoring':
        _applySearchText('@type:incident @status:monitoring');
        return;
      case 'sort-updated':
        _applySearchText('@sort:updated');
        return;
      case 'sort-created':
        _applySearchText('@sort:created');
        return;
      case 'sort-title':
        _applySearchText('@sort:title');
        return;
      case 'sort-due':
        _applySearchText('@sort:due');
        return;
      case 'clear':
        _clearSearch();
        return;
    }
  }

  List<PopupMenuEntry<String>> _treeMenuEntries(_WorkspaceTreeNode node) {
    if (node.kind == _WorkspaceTreeNodeKind.folder) {
      return <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'create_doc',
          child: Text(_t(context, 'new_doc')),
        ),
        PopupMenuItem<String>(
          value: 'create_sop',
          child: Text(_t(context, 'create_sop')),
        ),
        PopupMenuItem<String>(
          value: 'create_incident',
          child: Text(_t(context, 'new_incident')),
        ),
        PopupMenuItem<String>(
          value: 'create_folder',
          child: Text(_t(context, 'new_folder')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'rename_folder',
          child: Text(_t(context, 'rename_folder')),
        ),
        PopupMenuItem<String>(
          value: 'move_folder',
          child: Text(_t(context, 'move_folder')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'filter_folder',
          child: Text(_t(context, 'search_this_folder')),
        ),
        PopupMenuItem<String>(
          value: 'copy_folder_path',
          child: Text(_t(context, 'copy_folder_path')),
        ),
      ];
    }

    return switch (node.category) {
      _WorkspaceEntityType.doc => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'open', child: Text(_t(context, 'open'))),
        PopupMenuItem<String>(value: 'edit', child: Text(_t(context, 'edit'))),
        PopupMenuItem<String>(
          value: 'move_item',
          child: Text(_t(context, 'move')),
        ),
        PopupMenuItem<String>(
          value: 'copy_link',
          child: Text(_t(context, 'copy_link')),
        ),
      ],
      _WorkspaceEntityType.sop => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'open', child: Text(_t(context, 'open'))),
        PopupMenuItem<String>(value: 'edit', child: Text(_t(context, 'edit'))),
        PopupMenuItem<String>(
          value: 'move_item',
          child: Text(_t(context, 'move')),
        ),
        PopupMenuItem<String>(
          value: 'copy_link',
          child: Text(_t(context, 'copy_link')),
        ),
      ],
      _WorkspaceEntityType.incident => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'open', child: Text(_t(context, 'open'))),
        PopupMenuItem<String>(value: 'edit', child: Text(_t(context, 'edit'))),
        PopupMenuItem<String>(
          value: 'move_item',
          child: Text(_t(context, 'move')),
        ),
        PopupMenuItem<String>(
          value: 'copy_link',
          child: Text(_t(context, 'copy_link')),
        ),
      ],
      _WorkspaceEntityType.task => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'open', child: Text(_t(context, 'open'))),
        PopupMenuItem<String>(
          value: 'open_tasks',
          child: Text(_t(context, 'open_tasks')),
        ),
      ],
    };
  }

  Future<void> _handleTreeNodeAction(
    _WorkspaceTreeNode node,
    String action,
  ) async {
    switch (action) {
      case 'create_doc':
        await _handleCreateAction(
          'doc',
          folderId: node.folder?['id']?.toString(),
        );
        return;
      case 'create_folder':
        await _handleCreateAction(
          'folder',
          folderId: node.folder?['id']?.toString(),
        );
        return;
      case 'create_sop':
        await _handleCreateAction(
          'sop',
          folderId: node.folder?['id']?.toString(),
        );
        return;
      case 'create_incident':
        await _handleCreateAction(
          'incident',
          folderId: node.folder?['id']?.toString(),
        );
        return;
      case 'rename_folder':
        if (node.folder == null) {
          return;
        }
        final api = ref.read(apiClientProvider);
        final folders = await _loadFoldersFlat();
        if (!mounted) {
          return;
        }
        final changed = await _showEditFolderDialog(
          context,
          api,
          spaceId: widget.spaceId,
          existingFolder: node.folder!,
          folders: folders,
        );
        if (changed == true && mounted) {
          _reloadBundle(clearCaches: true);
        }
        return;
      case 'move_folder':
        if (node.folder == null) {
          return;
        }
        final api = ref.read(apiClientProvider);
        final folders = await _loadFoldersFlat();
        if (!mounted) {
          return;
        }
        final changed = await _showEditFolderDialog(
          context,
          api,
          spaceId: widget.spaceId,
          existingFolder: node.folder!,
          folders: folders,
          focusOnMove: true,
        );
        if (changed == true && mounted) {
          _reloadBundle(clearCaches: true);
        }
        return;
      case 'filter_folder':
        final path = (node.folder?['path'] ?? node.folder?['name'] ?? '')
            .toString()
            .trim();
        if (path.isNotEmpty) {
          _applySearchText('@folder:${_quoteSearchValue(path)}');
        }
        return;
      case 'copy_folder_path':
        final path = (node.folder?['path'] ?? node.folder?['name'] ?? '')
            .toString()
            .trim();
        if (path.isNotEmpty) {
          await _copyText(context, path, _t(context, 'folder_path_copied'));
        }
        return;
      case 'open':
        if (node.entity != null) {
          await _openEntityScreen(node.entity!);
        }
        return;
      case 'edit':
        if (node.record == null) {
          return;
        }
        bool? changed;
        switch (node.record!.type) {
          case _WorkspaceEntityType.doc:
            changed = await _openDocEditor(existingDoc: node.record!.raw);
            break;
          case _WorkspaceEntityType.sop:
            changed = await _openSopEditor(existingSopDetail: node.record!.raw);
            break;
          case _WorkspaceEntityType.incident:
            changed = await _openIncidentEditor(
              existingIncidentDetail: node.record!.raw,
            );
            break;
          case _WorkspaceEntityType.task:
            changed = null;
            break;
        }
        if (changed == true && mounted) {
          _reloadBundle(clearCaches: true);
        }
        return;
      case 'copy_link':
        if (node.entity == null) {
          return;
        }
        final link = switch (node.entity!.type) {
          _WorkspaceEntityType.doc => _docIdLink(
            widget.spaceId,
            node.entity!.id,
          ),
          _WorkspaceEntityType.sop => _spaceRoute(sopId: node.entity!.id),
          _WorkspaceEntityType.incident => _spaceIncidentLink(
            widget.spaceId,
            node.entity!.id,
          ),
          _WorkspaceEntityType.task => Uri(
            path: '/tasks',
            queryParameters: <String, String>{
              if (widget.spaceId.trim().isNotEmpty) 'spaceId': widget.spaceId,
              if (node.entity!.id.trim().isNotEmpty) 'search': node.entity!.id,
            },
          ).toString(),
        };
        await _copyText(context, link, 'Link copied');
        return;
      case 'move_item':
        if (node.record == null) {
          return;
        }
        final changed = await _moveWorkspaceItem(node.record!);
        if (changed == true && mounted) {
          _reloadBundle(clearCaches: true);
        }
        return;
      case 'open_tasks':
        final taskSearch = node.record?.type == _WorkspaceEntityType.task
            ? node.record!.ref.id
            : null;
        GoRouter.of(context).go(
          Uri(
            path: '/tasks',
            queryParameters: <String, String>{
              'spaceId': widget.spaceId,
              if ((taskSearch ?? '').trim().isNotEmpty) 'search': taskSearch!,
            },
          ).toString(),
        );
        return;
    }
  }

  Widget _buildTreePane({
    required _WorkspaceBundle bundle,
    required List<_WorkspaceTreeNode> nodes,
    required List<SearchParseDiagnostic> diagnostics,
    required List<_WorkspaceSearchSuggestion> suggestions,
    required _WorkspaceSearchQuery parsedQuery,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _WorkspacePanel(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compactToolbar = constraints.maxWidth < 560;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          focusNode: _searchFocus,
                          textInputAction: TextInputAction.search,
                          autocorrect: true,
                          enableSuggestions: true,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: structuredSearchHint(
                              l10n: AppLocalizations.of(context),
                              capability: workspaceSearchCapability,
                              baseHint: _t(context, 'workspace_search_hint'),
                            ),
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchCtrl.text.trim().isEmpty
                                ? null
                                : IconButton(
                                    tooltip: AppLocalizations.of(
                                      context,
                                    ).text('clear_search'),
                                    onPressed: _clearSearch,
                                    icon: const Icon(Icons.close),
                                  ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            filled: true,
                            fillColor: cs.surfaceContainerLowest,
                          ),
                          onSubmitted: (_) =>
                              _syncRouteFromState(immediate: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (compactToolbar)
                        PopupMenuButton<String>(
                          tooltip: AppLocalizations.of(context).text('more'),
                          onSelected: (value) =>
                              _handleToolbarAction(value, bundle),
                          itemBuilder: (context) => <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(
                              value: 'info',
                              child: Text(_t(context, 'workspace_stats')),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem<String>(
                              value: 'doc',
                              child: Text(_t(context, 'new_doc')),
                            ),
                            PopupMenuItem<String>(
                              value: 'sop',
                              child: Text(_t(context, 'create_sop')),
                            ),
                            PopupMenuItem<String>(
                              value: 'incident',
                              child: Text(_t(context, 'new_incident')),
                            ),
                            PopupMenuItem<String>(
                              value: 'folder',
                              child: Text(_t(context, 'new_folder')),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem<String>(
                              value: 'clear',
                              child: Text(_t(context, 'clear_search')),
                            ),
                          ],
                          icon: const Icon(Icons.more_horiz),
                        )
                      else ...<Widget>[
                        IconButton(
                          tooltip: _t(context, 'workspace_stats'),
                          onPressed: () => _showWorkspaceStats(bundle),
                          icon: const Icon(Icons.info_outline),
                        ),
                        PopupMenuButton<String>(
                          tooltip: AppLocalizations.of(context).text('create'),
                          onSelected: (value) => _handleCreateAction(value),
                          itemBuilder: (context) => <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(
                              value: 'doc',
                              child: Text(_t(context, 'new_doc')),
                            ),
                            PopupMenuItem<String>(
                              value: 'sop',
                              child: Text(_t(context, 'create_sop')),
                            ),
                            PopupMenuItem<String>(
                              value: 'incident',
                              child: Text(_t(context, 'new_incident')),
                            ),
                            PopupMenuItem<String>(
                              value: 'folder',
                              child: Text(_t(context, 'new_folder')),
                            ),
                          ],
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ],
                  ),
                  if (_searchCtrl.text.trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      _tf(context, 'workspace_matches_summary', {
                        'count': nodes.fold<int>(
                          0,
                          (count, node) => count + _countTreeItems(node),
                        ),
                        'sort': _workspaceSortLabel(
                          context,
                          parsedQuery.sortMode,
                        ),
                      }),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (suggestions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: cs.outlineVariant),
                          color: cs.surfaceContainerLow,
                        ),
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
                                  onTap: () => _applyWorkspaceSearchSuggestion(
                                    suggestion,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  if (diagnostics.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SearchDiagnosticsList(diagnostics: diagnostics),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _WorkspacePanel(
            padding: EdgeInsets.zero,
            child: nodes.isEmpty
                ? _WorkspaceStateMessage(
                    icon: Icons.search_off_outlined,
                    title: _t(context, 'no_results'),
                    body: _t(context, 'workspace_no_results_help'),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: _buildTreeNodeWidgets(
                      nodes,
                      depth: 0,
                      searching: _searchCtrl.text.trim().isNotEmpty,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  int _countTreeItems(_WorkspaceTreeNode node) {
    var total = node.kind == _WorkspaceTreeNodeKind.item ? 1 : 0;
    for (final child in node.children) {
      total += _countTreeItems(child);
    }
    return total;
  }

  String _workspaceSortLabel(
    BuildContext context,
    _WorkspaceSortMode sortMode,
  ) {
    return switch (sortMode) {
      _WorkspaceSortMode.created => _t(context, 'created_label'),
      _WorkspaceSortMode.title => _t(context, 'title_label'),
      _WorkspaceSortMode.status => _t(context, 'status'),
      _WorkspaceSortMode.due => _t(context, 'due'),
      _WorkspaceSortMode.severity => _t(context, 'severity'),
      _WorkspaceSortMode.updated => _t(context, 'updated_label'),
    };
  }

  List<Widget> _buildTreeNodeWidgets(
    List<_WorkspaceTreeNode> nodes, {
    required int depth,
    required bool searching,
  }) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      widgets.add(_buildTreeNode(node, depth: depth, searching: searching));
    }
    return widgets;
  }

  Widget _buildTreeNode(
    _WorkspaceTreeNode node, {
    required int depth,
    required bool searching,
  }) {
    final hasChildren = node.children.isNotEmpty;
    final expanded = searching || _expandedTreeIds.contains(node.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildTreeRow(
          node,
          depth: depth,
          hasChildren: hasChildren,
          expanded: expanded,
        ),
        ClipRect(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: hasChildren && expanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _buildTreeNodeWidgets(
                      node.children,
                      depth: depth + 1,
                      searching: searching,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _buildTreeRow(
    _WorkspaceTreeNode node, {
    required int depth,
    required bool hasChildren,
    required bool expanded,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isFolder = node.kind == _WorkspaceTreeNodeKind.folder;
    final canExpand = hasChildren;
    return KeyedSubtree(
      key: ValueKey<String>(node.id),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Material(
            color: Colors.transparent,
            child: InkWell(
              splashFactory: NoSplash.splashFactory,
              highlightColor: cs.primary.withValues(alpha: 0.08),
              hoverColor: cs.primary.withValues(alpha: 0.05),
              onTap: () {
                if (node.kind == _WorkspaceTreeNodeKind.item &&
                    node.entity != null) {
                  _openEntityScreen(node.entity!);
                  return;
                }
                if (canExpand) {
                  _toggleTreeNode(node.id);
                }
              },
              child: Container(
                height: 60,
                padding: EdgeInsets.only(
                  left: AppSpacing.sm + (depth * 18),
                  right: AppSpacing.xs,
                ),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: canExpand
                          ? Center(
                              child: IconButton(
                                constraints: const BoxConstraints.tightFor(
                                  width: 24,
                                  height: 24,
                                ),
                                padding: EdgeInsets.zero,
                                splashRadius: 14,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _toggleTreeNode(node.id),
                                icon: Icon(
                                  expanded
                                      ? Icons.keyboard_arrow_down
                                      : Icons.keyboard_arrow_right,
                                  size: 18,
                                ),
                              ),
                            )
                          : null,
                    ),
                    Icon(node.icon, size: isFolder ? 18 : 17),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            node.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  fontWeight: isFolder
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                ),
                          ),
                          if (node.subtitle.trim().isNotEmpty) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              node.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (node.record?.needsReview == true)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.rate_review_outlined,
                          size: 18,
                          color: cs.tertiary,
                        ),
                      ),
                    if (node.record?.runOverdue == true)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.timer_off_outlined,
                          size: 18,
                          color: cs.error,
                        ),
                      ),
                    if (node.record != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _WorkspaceTypeBadge(type: node.record!.type),
                      ),
                    if ((node.record?.status ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _WorkspaceTrailingStatus(
                          status: node.record!.status,
                        ),
                      ),
                    PopupMenuButton<String>(
                      tooltip: AppLocalizations.of(context).text('more'),
                      onSelected: (value) => _handleTreeNodeAction(node, value),
                      itemBuilder: (context) => _treeMenuEntries(node),
                      icon: const Icon(Icons.more_vert),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return FutureBuilder<List<dynamic>>(
      future: ref.read(spacesProvider('').future),
      builder: (context, spacesSnapshot) {
        if (spacesSnapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (spacesSnapshot.hasError) {
          return _WorkspaceFullWidthFrame(
            title: l10n.text('space'),
            child: Center(
              child: Text(
                '${l10n.text('failed_to_load_spaces')}: ${spacesSnapshot.error}',
              ),
            ),
          );
        }
        final spaces = (spacesSnapshot.data ?? const <dynamic>[])
            .whereType<Map>()
            .map((row) => row.cast<String, dynamic>())
            .toList(growable: false);
        JsonMap? space;
        for (final row in spaces) {
          if ((row['id'] ?? '').toString() == widget.spaceId) {
            space = row;
            break;
          }
        }
        if (space == null) {
          return _WorkspaceFullWidthFrame(
            title: l10n.text('space'),
            child: Center(
              child: Text(l10n.text('space_not_found_or_inaccessible')),
            ),
          );
        }

        final spaceName = (space['name'] ?? l10n.text('space')).toString();
        final backToWorkspaceRoute = _spaceRoute(
          search: _normalizeWorkspaceSearchInput(
            widget.initialSearchQuery ?? '',
          ),
        );

        return _WorkspaceFullWidthFrame(
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => atlasPopOrGo(
              context,
              _routeTargetsEntity() ? backToWorkspaceRoute : '/spaces',
            ),
            icon: const Icon(Icons.arrow_back),
          ),
          title: spaceName,
          child: FutureBuilder<_WorkspaceBundle>(
            future: _bundleFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _WorkspaceStateMessage(
                  icon: Icons.error_outline,
                  title: _t(context, 'workspace_failed_to_load'),
                  body: requestErrorMessage(snapshot.error!),
                  actionLabel: l10n.text('retry'),
                  onAction: () => _reloadBundle(clearCaches: true),
                );
              }

              final bundle = snapshot.data!;
              _seedInitialFolderExpansion(bundle);
              final parsedQuery = _parseWorkspaceSearchQuery(_searchCtrl.text);
              final diagnostics = validateSearchQueryAst(
                parsedQuery.ast,
                capability: workspaceSearchCapability,
              );
              final suggestions = _searchSuggestions(bundle);
              final items = _visibleItems(bundle, parsedQuery);
              _maybeHandlePendingCreate();
              final openEntity = _desiredEntityFromWidget(bundle);
              if (openEntity != null) {
                return _buildDetailPane(
                  bundle: bundle,
                  selectedEntity: openEntity,
                  backButton: null,
                );
              }

              final treeNodes = _buildTreeNodes(bundle, items, parsedQuery);
              return _buildTreePane(
                bundle: bundle,
                nodes: treeNodes,
                diagnostics: diagnostics.diagnostics,
                suggestions: suggestions,
                parsedQuery: parsedQuery,
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showWorkspaceStats(_WorkspaceBundle bundle) async {
    final staleDocs = _asInt(bundle.reviewSummary?['stale_docs']);
    final dueDocs = _asInt(bundle.reviewSummary?['docs_due_for_review']);
    final openIncidents = _asInt(bundle.incidentAnalytics['open_incidents']);
    final monitoringIncidents = _asInt(
      bundle.incidentAnalytics['monitoring_incidents'],
    );

    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t(context, 'workspace_stats')),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _StatLine(
                label: _t(context, 'docs'),
                value: bundle.docs.length.toString(),
              ),
              _StatLine(
                label: _t(context, 'needs_review'),
                value: staleDocs.toString(),
              ),
              _StatLine(
                label: _t(context, 'review_due'),
                value: dueDocs.toString(),
              ),
              _StatLine(
                label: _t(context, 'sops'),
                value: bundle.sops.length.toString(),
              ),
              _StatLine(
                label: _t(context, 'overdue_runs'),
                value: bundle.dueRuns
                    .where((row) => row['overdue'] == true)
                    .length
                    .toString(),
              ),
              _StatLine(
                label: _t(context, 'incidents'),
                value: bundle.incidents.length.toString(),
              ),
              _StatLine(
                label: _t(context, 'open_incidents_label'),
                value: openIncidents.toString(),
              ),
              _StatLine(
                label: _statusText(context, 'monitoring'),
                value: monitoringIncidents.toString(),
              ),
              _StatLine(
                label: _t(context, 'avg_mttr'),
                value:
                    '${_asInt(bundle.incidentAnalytics['avg_mttr_minutes'])} min',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context).text('close')),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailPane({
    required _WorkspaceBundle bundle,
    required _WorkspaceEntityRef selectedEntity,
    required Widget? backButton,
  }) {
    return switch (selectedEntity.type) {
      _WorkspaceEntityType.doc => _buildDocDetailPane(
        docId: selectedEntity.id,
        wide: false,
        backButton: backButton,
      ),
      _WorkspaceEntityType.sop => _buildSopDetailPane(
        sopId: selectedEntity.id,
        wide: false,
        backButton: backButton,
      ),
      _WorkspaceEntityType.incident => _buildIncidentDetailPane(
        incidentId: selectedEntity.id,
        wide: false,
        backButton: backButton,
      ),
      _WorkspaceEntityType.task => _WorkspaceStateMessage(
        icon: Icons.assignment_outlined,
        title: _t(context, 'open_tasks'),
        body: _t(context, 'workspace_tasks_live_on_tasks_page'),
      ),
    };
  }

  Widget _buildDocDetailPane({
    required String docId,
    required bool wide,
    required Widget? backButton,
  }) {
    return FutureBuilder<_KbDocDetailData>(
      future: _loadDocDetail(docId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _WorkspaceStateMessage(
            icon: Icons.description_outlined,
            title: _t(context, 'document_failed_to_load'),
            body: requestErrorMessage(snapshot.error!),
            actionLabel: AppLocalizations.of(context).text('retry'),
            onAction: () {
              _docDetailFutures.remove(docId);
              setState(() {});
            },
          );
        }
        final data = snapshot.data!;
        final doc = data.doc;
        final content = (doc['content_md'] ?? '').toString().trim();
        final header = _WorkspaceDetailHeader(
          backButton: backButton,
          title: (doc['title'] ?? 'Document').toString(),
          subtitle: (doc['folder_path'] ?? doc['slug'] ?? '').toString(),
          badges: <Widget>[
            _StatusChip((doc['status'] ?? 'draft').toString()),
            if (doc['is_stale'] == true)
              _WorkspaceInlineBadge(
                label: _t(context, 'needs_review'),
                icon: Icons.rate_review_outlined,
              ),
            if ((doc['review_due_at'] ?? '').toString().trim().isNotEmpty)
              _WorkspaceInlineBadge(
                label: _tf(context, 'workspace_review_badge', {
                  'date': _formatDate((doc['review_due_at'] ?? '').toString()),
                }),
                icon: Icons.event_outlined,
              ),
            for (final tag in _asStringList(doc['tags']).take(4))
              _WorkspaceInlineBadge(label: tag, icon: Icons.sell_outlined),
          ],
          actions: <Widget>[
            TextButton.icon(
              onPressed: () => _showDocHistory(data),
              icon: const Icon(Icons.history),
              label: Text(_t(context, 'view_history')),
            ),
            TextButton.icon(
              onPressed: () => _showDocComments(data),
              icon: const Icon(Icons.comment_outlined),
              label: Text(_t(context, 'comments')),
            ),
            TextButton.icon(
              onPressed: () async {
                final changed = await _openDocEditor(existingDoc: doc);
                if (changed == true) {
                  _docDetailFutures.remove(docId);
                  _reloadBundle(clearCaches: true);
                }
              },
              icon: const Icon(Icons.edit_outlined),
              label: Text(_t(context, 'edit')),
            ),
            IconButton(
              tooltip: AppLocalizations.of(context).text('copy_link'),
              onPressed: () => _copyText(
                context,
                _docIdLink(widget.spaceId, docId),
                AppLocalizations.of(context).text('direct_doc_link_copied'),
              ),
              icon: const Icon(Icons.link_outlined),
            ),
          ],
        );
        final contentSurface = _WorkspaceContentSurface(
          child: content.isEmpty
              ? Text(AppLocalizations.of(context).text('no_content'))
              : RichContentView(content: content),
        );
        return _WorkspacePanel(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Scrollbar(
            child: SingleChildScrollView(
              primary: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  header,
                  const SizedBox(height: 14),
                  contentSurface,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showDocHistory(_KbDocDetailData data) async {
    final diffRows = data.diff == null
        ? const <JsonMap>[]
        : _asJsonList(data.diff!['rows'] ?? const []);
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t(context, 'view_history')),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (diffRows.isNotEmpty) ...<Widget>[
                  SizedBox(
                    height: 280,
                    child: _DocDiffPreview(
                      fromLabel: (data.diff?['from_label'] ?? 'Before')
                          .toString(),
                      toLabel: (data.diff?['to_label'] ?? 'Current').toString(),
                      rows: diffRows,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                for (final version in data.versions)
                  Material(
                    color: Colors.transparent,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        (version['name'] ?? version['title'] ?? 'Version')
                            .toString(),
                      ),
                      subtitle: Text(
                        [
                          (version['author_name'] ?? '').toString(),
                          _formatDateTime(version['created_at']?.toString()),
                        ].where((row) => row.trim().isNotEmpty).join(' • '),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context).text('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _showDocComments(_KbDocDetailData data) async {
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t(context, 'comments')),
        content: SizedBox(
          width: 720,
          child: data.comments.isEmpty
              ? Text(AppLocalizations.of(context).text('no_content'))
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: data.comments
                        .map((comment) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _WorkspaceContentSurface(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    [
                                          (comment['author_name'] ?? '')
                                              .toString(),
                                          _formatDateTime(
                                            comment['created_at']?.toString(),
                                          ),
                                        ]
                                        .where((row) => row.trim().isNotEmpty)
                                        .join(' • '),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 8),
                                  RichContentView(
                                    content: (comment['body_md'] ?? '')
                                        .toString(),
                                  ),
                                ],
                              ),
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context).text('close')),
          ),
        ],
      ),
    );
  }

  Widget _buildSopDetailPane({
    required String sopId,
    required bool wide,
    required Widget? backButton,
  }) {
    return FutureBuilder<JsonMap>(
      future: _loadSopDetail(sopId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _WorkspaceStateMessage(
            icon: Icons.checklist_outlined,
            title: _t(context, 'sop_failed_to_load'),
            body: requestErrorMessage(snapshot.error!),
            actionLabel: AppLocalizations.of(context).text('retry'),
            onAction: () {
              _sopDetailFutures.remove(sopId);
              setState(() {});
            },
          );
        }

        final sop = snapshot.data!;
        final steps = _asJsonList(sop['steps'] ?? const []);
        final stepById = <String, JsonMap>{
          for (final step in steps) (step['id'] ?? '').toString().trim(): step,
        };
        final runs = _asJsonList(sop['runs'] ?? const []);
        JsonMap? activeRun;
        for (final run in runs) {
          final status = (run['status'] ?? '').toString().trim();
          if (status == 'active' || status == 'in_progress') {
            activeRun = run;
            break;
          }
        }
        final activeRunId = (activeRun?['id'] ?? '').toString().trim();
        final historyRuns = runs
            .where(
              (run) =>
                  activeRunId.isEmpty ||
                  (run['id'] ?? '').toString().trim() != activeRunId,
            )
            .toList(growable: false);
        final selectedHistoryRunId = _selectedSopRunIds[sopId];
        JsonMap? selectedHistoryRun;
        for (final run in historyRuns) {
          if ((run['id'] ?? '').toString().trim() == selectedHistoryRunId) {
            selectedHistoryRun = run;
            break;
          }
        }

        final header = _WorkspaceDetailHeader(
          backButton: backButton,
          title: (sop['title'] ?? 'SOP').toString(),
          subtitle: (sop['slug'] ?? '').toString(),
          badges: <Widget>[
            _StatusChip((sop['status'] ?? 'draft').toString()),
            if (sop['pending_approval'] == true)
              _WorkspaceInlineBadge(
                label: _t(context, 'pending_approval'),
                icon: Icons.pending_actions_outlined,
              ),
            if ((sop['review_due_at'] ?? '').toString().trim().isNotEmpty)
              _WorkspaceInlineBadge(
                label: _tf(context, 'workspace_review_badge', {
                  'date': _formatDate((sop['review_due_at'] ?? '').toString()),
                }),
                icon: Icons.event_outlined,
              ),
          ],
          actions: <Widget>[
            WorkspaceActionMenu(
              tooltip: _t(context, 'more'),
              actions: <WorkspaceAction>[
                WorkspaceAction(
                  label: _t(context, 'edit'),
                  icon: Icons.edit_outlined,
                  onSelected: () async {
                    final changed = await _openSopEditor(
                      existingSopDetail: sop,
                    );
                    if (changed == true) {
                      _sopDetailFutures.remove(sopId);
                      _reloadBundle(clearCaches: true);
                    }
                  },
                ),
                if (activeRun != null)
                  WorkspaceAction(
                    label: _t(context, 'open_tasks'),
                    icon: Icons.assignment_outlined,
                    onSelected: () => _openSopRunTasks(),
                  ),
              ],
            ),
          ],
        );
        final contentSections = <Widget>[
          _WorkspaceContentSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () => _startSopRun(sopId),
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: Text(
                    activeRun == null
                        ? _t(context, 'start_run')
                        : _t(context, 'start_another_run'),
                  ),
                ),
                if (activeRun != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(_t(context, 'workspace_active_run_continue_help')),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => _openSopRunTasks(
                      taskId: (activeRun?['task_id'] ?? '').toString(),
                    ),
                    icon: const Icon(Icons.arrow_forward_outlined),
                    label: Text(_t(context, 'continue_in_tasks')),
                  ),
                ],
              ],
            ),
          ),
          if (activeRun != null) ...<Widget>[
            const SizedBox(height: 14),
            _WorkspaceContentSurface(
              child: _WorkspaceSopRunSummary(
                title: _t(context, 'active_run'),
                run: activeRun,
                stepDefinitions: stepById,
              ),
            ),
          ],
          if (historyRuns.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            _WorkspaceContentSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _t(context, 'run_history'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedHistoryRun == null
                        ? null
                        : (selectedHistoryRun['id'] ?? '').toString().trim(),
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: _t(context, 'run_history'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: <DropdownMenuItem<String>>[
                      for (final run in historyRuns)
                        DropdownMenuItem<String>(
                          value: (run['id'] ?? '').toString().trim(),
                          child: Text(
                            _formatDateTime(
                              (run['started_at'] ?? '').toString(),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedSopRunIds[sopId] = value;
                      });
                    },
                  ),
                  if (selectedHistoryRun != null) ...<Widget>[
                    const SizedBox(height: 14),
                    _WorkspaceSopRunSummary(
                      title: _formatDateTime(
                        (selectedHistoryRun['started_at'] ?? '').toString(),
                      ),
                      run: selectedHistoryRun,
                      stepDefinitions: stepById,
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          _WorkspaceContentSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _t(context, 'overview'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                if ((sop['overview_md'] ?? '').toString().trim().isEmpty)
                  Text(AppLocalizations.of(context).text('no_content'))
                else
                  RichContentView(
                    content: (sop['overview_md'] ?? '').toString(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _WorkspaceContentSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _t(context, 'procedure'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                for (var index = 0; index < steps.length; index++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: index == steps.length - 1 ? 0 : 12,
                    ),
                    child: _WorkspaceStepBlock(
                      stepNumber: index + 1,
                      title: (steps[index]['title'] ?? 'Step').toString(),
                      body: (steps[index]['body_md'] ?? '').toString(),
                      meta: [
                        if (steps[index]['requires_evidence'] == true)
                          _t(context, 'evidence_required'),
                        if ((steps[index]['follow_up_task_id'] ?? '')
                            .toString()
                            .trim()
                            .isNotEmpty)
                          _t(context, 'open_linked_task'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ];

        return _WorkspacePanel(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              header,
              const SizedBox(height: 14),
              ...contentSections,
            ],
          ),
        );
      },
    );
  }

  Future<void> _startSopRun(String sopId) async {
    try {
      final api = ref.read(apiClientProvider);
      final optionsResponse = await api.dio.get(
        '/sop/sops/$sopId/run-assignment-options',
      );
      final selection = await _pickSopRunAssignment(
        _asJsonMap(optionsResponse.data),
      );
      if (selection == null) {
        return;
      }
      final response = await api.dio.post(
        '/sop/sops/$sopId/runs',
        data: <String, Object?>{
          if ((selection.assigneeUserId ?? '').trim().isNotEmpty)
            'assignee_user_id': selection.assigneeUserId,
          if ((selection.forwardManagerUserId ?? '').trim().isNotEmpty)
            'forward_manager_user_id': selection.forwardManagerUserId,
        },
      );
      final payload = _asJsonMap(response.data);
      final taskId = (payload['task_id'] ?? '').toString().trim();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            taskId.isEmpty
                ? 'Run started. Continue in tasks.'
                : 'Run task $taskId created. Continue in tasks.',
          ),
        ),
      );
      _openSopRunTasks(taskId: taskId);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(requestErrorMessage(error))));
    }
  }

  void _openSopRunTasks({String? taskId}) {
    final normalizedTaskId = (taskId ?? '').trim();
    GoRouter.of(context).go(
      Uri(
        path: '/tasks',
        queryParameters: <String, String>{
          'spaceId': widget.spaceId,
          'search': normalizedTaskId.isEmpty
              ? 'source:sop_run'
              : normalizedTaskId,
        },
      ).toString(),
    );
  }

  Future<({String? assigneeUserId, String? forwardManagerUserId})?>
  _pickSopRunAssignment(JsonMap options) async {
    final directAssignees = _asJsonList(
      options['direct_assignees'] ?? const [],
    );
    final forwardManagers = _asJsonList(
      options['forward_managers'] ?? const [],
    );
    if (directAssignees.isEmpty && forwardManagers.isEmpty) {
      return (assigneeUserId: null, forwardManagerUserId: null);
    }

    String mode = 'self';
    String selectedAssigneeUserId = directAssignees.isEmpty
        ? ''
        : (directAssignees.first['user_id'] ?? '').toString();
    String selectedForwardManagerUserId = forwardManagers.isEmpty
        ? ''
        : (forwardManagers.first['user_id'] ?? '').toString();

    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Widget optionCard({
            required String value,
            required String title,
            required String subtitle,
          }) {
            final selected = mode == value;
            final cs = Theme.of(dialogContext).colorScheme;
            return Material(
              color: selected
                  ? cs.primaryContainer.withValues(alpha: 0.72)
                  : cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => setDialogState(() => mode = value),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              title,
                              style: Theme.of(dialogContext)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              style: Theme.of(
                                dialogContext,
                              ).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: Text(_t(context, 'start_run')),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_t(context, 'workspace_run_assignment_help')),
                    const SizedBox(height: 14),
                    optionCard(
                      value: 'self',
                      title: _t(context, 'assign_to_me'),
                      subtitle: _t(context, 'assign_to_me_help'),
                    ),
                    if (directAssignees.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      optionCard(
                        value: 'delegate',
                        title: _t(context, 'assign_directly'),
                        subtitle: _t(context, 'assign_directly_help'),
                      ),
                      if (mode == 'delegate')
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedAssigneeUserId,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: _t(context, 'operator'),
                              border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                            ),
                            items: [
                              for (final assignee in directAssignees)
                                DropdownMenuItem<String>(
                                  value: (assignee['user_id'] ?? '').toString(),
                                  child: Text(
                                    [
                                      _memberNameOrFallback(context, assignee),
                                      if (_asInt(assignee['report_count']) > 0)
                                        '${_asInt(assignee['report_count'])} report(s)',
                                    ].join(' • '),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) => setDialogState(
                              () => selectedAssigneeUserId = value ?? '',
                            ),
                          ),
                        ),
                    ],
                    if (forwardManagers.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      optionCard(
                        value: 'forward',
                        title: _t(context, 'forward_to_manager'),
                        subtitle: _t(context, 'forward_to_manager_help'),
                      ),
                      if (mode == 'forward')
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedForwardManagerUserId,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: _t(context, 'manager'),
                              border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                            ),
                            items: [
                              for (final manager in forwardManagers)
                                DropdownMenuItem<String>(
                                  value: (manager['user_id'] ?? '').toString(),
                                  child: Text(
                                    [
                                      _memberNameOrFallback(context, manager),
                                      '${_asInt(manager['report_count'])} report(s)',
                                    ].join(' • '),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) => setDialogState(
                              () => selectedForwardManagerUserId = value ?? '',
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(AppLocalizations.of(context).text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(_t(context, 'start_run')),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed != true) {
      return null;
    }
    return switch (mode) {
      'delegate' => (
        assigneeUserId: selectedAssigneeUserId,
        forwardManagerUserId: null,
      ),
      'forward' => (
        assigneeUserId: null,
        forwardManagerUserId: selectedForwardManagerUserId,
      ),
      _ => (assigneeUserId: null, forwardManagerUserId: null),
    };
  }

  Widget _buildIncidentDetailPane({
    required String incidentId,
    required bool wide,
    required Widget? backButton,
  }) {
    return FutureBuilder<JsonMap>(
      future: _loadIncidentDetail(incidentId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _WorkspaceStateMessage(
            icon: Icons.report_problem_outlined,
            title: _t(context, 'incident_failed_to_load'),
            body: requestErrorMessage(snapshot.error!),
            actionLabel: AppLocalizations.of(context).text('retry'),
            onAction: () {
              _incidentDetailFutures.remove(incidentId);
              setState(() {});
            },
          );
        }

        final incident = snapshot.data!;
        final actionItems = _asJsonList(incident['action_items'] ?? const []);
        final statusUpdates = _asJsonList(
          incident['status_updates'] ?? const [],
        );
        final transitions = _asJsonList(incident['status_history'] ?? const []);
        final reminders = _asJsonList(incident['reminders'] ?? const []);
        final timeline = _asJsonList(incident['timeline'] ?? const []);
        final links = _asJsonList(incident['links'] ?? const []);
        final postmortem = (incident['postmortem_md'] ?? '').toString().trim();
        final activity = _buildIncidentActivity(
          statusUpdates: statusUpdates,
          transitions: transitions,
          reminders: reminders,
          timeline: timeline,
        );
        final incidentStatus = (incident['status'] ?? 'open').toString();
        final showPostmortemFirst =
            postmortem.isNotEmpty &&
            <String>{
              'resolved',
              'closed',
            }.contains(incidentStatus.toLowerCase());

        return _WorkspacePanel(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Scrollbar(
            child: SingleChildScrollView(
              primary: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _WorkspaceDetailHeader(
                    backButton: backButton,
                    title: (incident['title'] ?? 'Incident').toString(),
                    subtitle: [
                      if ((incident['on_call_user_name'] ?? '')
                          .toString()
                          .trim()
                          .isNotEmpty)
                        'On-call ${(incident['on_call_user_name'] ?? '').toString().trim()}',
                      if (_asInt(incident['severity']) > 0)
                        'Severity ${_asInt(incident['severity'])}',
                    ].join(' • '),
                    badges: <Widget>[
                      _StatusChip(incidentStatus),
                      if (_asInt(incident['severity']) > 0)
                        _WorkspaceInlineBadge(
                          label: 'SEV ${_asInt(incident['severity'])}',
                          icon: Icons.priority_high_outlined,
                        ),
                      if ((incident['incident_type'] ?? '')
                          .toString()
                          .trim()
                          .isNotEmpty)
                        _WorkspaceInlineBadge(
                          label: (incident['incident_type'] ?? '')
                              .toString()
                              .replaceAll('_', ' '),
                          icon: Icons.layers_outlined,
                        ),
                    ],
                    actions: <Widget>[
                      FilledButton.icon(
                        onPressed: () async {
                          final changed = await _openIncidentStatusUpdate(
                            incidentId: incidentId,
                            incidentDetail: incident,
                          );
                          if (changed == true) {
                            _incidentDetailFutures.remove(incidentId);
                            _reloadBundle(clearCaches: true);
                          }
                        },
                        icon: const Icon(Icons.campaign_outlined),
                        label: Text(_t(context, 'add_status_update')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final changed = await _openIncidentStatusUpdate(
                            incidentId: incidentId,
                            incidentDetail: incident,
                          );
                          if (changed == true) {
                            _incidentDetailFutures.remove(incidentId);
                            _reloadBundle(clearCaches: true);
                          }
                        },
                        icon: const Icon(Icons.sync_alt_outlined),
                        label: Text(_t(context, 'change_status')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final changed = await _openIncidentActionItemDialog(
                            incidentId: incidentId,
                          );
                          if (changed == true) {
                            _incidentDetailFutures.remove(incidentId);
                            _reloadBundle(clearCaches: true);
                          }
                        },
                        icon: const Icon(Icons.playlist_add_check_outlined),
                        label: Text(_t(context, 'new_action_item')),
                      ),
                      WorkspaceActionMenu(
                        tooltip: _t(context, 'more'),
                        actions: <WorkspaceAction>[
                          WorkspaceAction(
                            label: _t(context, 'add_timeline_entry'),
                            icon: Icons.timeline_outlined,
                            onSelected: () async {
                              final changed =
                                  await _openIncidentTimelineEntryDialog(
                                    incidentId: incidentId,
                                  );
                              if (changed == true) {
                                _incidentDetailFutures.remove(incidentId);
                                _reloadBundle(clearCaches: true);
                              }
                            },
                          ),
                          WorkspaceAction(
                            label: _t(context, 'edit'),
                            icon: Icons.edit_outlined,
                            onSelected: () async {
                              final changed = await _openIncidentEditor(
                                existingIncidentDetail: incident,
                              );
                              if (changed == true) {
                                _incidentDetailFutures.remove(incidentId);
                                _reloadBundle(clearCaches: true);
                              }
                            },
                          ),
                          WorkspaceAction(
                            label: AppLocalizations.of(
                              context,
                            ).text('copy_link'),
                            icon: Icons.link_outlined,
                            onSelected: () => _copyText(
                              context,
                              _spaceIncidentLink(widget.spaceId, incidentId),
                              AppLocalizations.of(context).text('link_copied'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (showPostmortemFirst) ...<Widget>[
                    _WorkspaceContentSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _t(context, 'postmortem'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 10),
                          RichContentView(content: postmortem),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  _WorkspaceContentSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _t(context, 'activity_title'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        if (activity.isEmpty)
                          Text(_t(context, 'no_activity_yet'))
                        else
                          for (final entry in activity)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _WorkspaceIncidentActivityCard(
                                entry: entry,
                                highlighted:
                                    entry.kind == 'timeline' &&
                                    (widget.openTimelineId ?? '').trim() ==
                                        (entry.data['id'] ?? '')
                                            .toString()
                                            .trim(),
                              ),
                            ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _WorkspaceContentSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _t(context, 'action_items'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        if (actionItems.isEmpty)
                          Text(_t(context, 'no_action_items_yet'))
                        else
                          for (final item in actionItems)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _WorkspaceIncidentActionCard(
                                item: item,
                                highlighted:
                                    (widget.openActionItemId ?? '').trim() ==
                                    (item['id'] ?? '').toString().trim(),
                                onOpenTask: () {
                                  final taskId =
                                      (item['task_id'] ??
                                              item['linked_task_id'] ??
                                              '')
                                          .toString()
                                          .trim();
                                  if (taskId.isEmpty) {
                                    return;
                                  }
                                  GoRouter.of(context).go(
                                    Uri(
                                      path: '/tasks',
                                      queryParameters: <String, String>{
                                        'spaceId': widget.spaceId,
                                        'search': taskId,
                                      },
                                    ).toString(),
                                  );
                                },
                              ),
                            ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _WorkspaceContentSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _t(context, 'summary_label'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        if ((incident['summary_md'] ?? '')
                            .toString()
                            .trim()
                            .isEmpty)
                          Text(AppLocalizations.of(context).text('no_content'))
                        else
                          RichContentView(
                            content: (incident['summary_md'] ?? '').toString(),
                          ),
                      ],
                    ),
                  ),
                  if (!showPostmortemFirst &&
                      postmortem.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    _WorkspaceContentSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _t(context, 'postmortem'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 10),
                          RichContentView(content: postmortem),
                        ],
                      ),
                    ),
                  ],
                  if (links.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    _WorkspaceContentSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _t(context, 'related_records'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 10),
                          for (final link in links)
                            Material(
                              color: Colors.transparent,
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(switch ((link['target_type'] ??
                                        '')
                                    .toString()
                                    .trim()) {
                                  'doc' => Icons.description_outlined,
                                  'sop' => Icons.checklist_outlined,
                                  _ => Icons.link_outlined,
                                }),
                                title: Text(
                                  (link['title'] ?? 'Linked record').toString(),
                                ),
                                onTap: () {
                                  final targetType = (link['target_type'] ?? '')
                                      .toString()
                                      .trim();
                                  final targetId = (link['target_id'] ?? '')
                                      .toString()
                                      .trim();
                                  if (targetId.isEmpty) {
                                    return;
                                  }
                                  final target = switch (targetType) {
                                    'doc' => _WorkspaceEntityRef(
                                      _WorkspaceEntityType.doc,
                                      targetId,
                                    ),
                                    'sop' => _WorkspaceEntityRef(
                                      _WorkspaceEntityType.sop,
                                      targetId,
                                    ),
                                    _ => null,
                                  };
                                  if (target != null) {
                                    _openEntityScreen(target);
                                  }
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<_WorkspaceIncidentActivityEntry> _buildIncidentActivity({
    required List<JsonMap> statusUpdates,
    required List<JsonMap> transitions,
    required List<JsonMap> reminders,
    required List<JsonMap> timeline,
  }) {
    DateTime parse(String? raw) =>
        DateTime.tryParse(raw ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    final rows = <_WorkspaceIncidentActivityEntry>[
      for (final row in statusUpdates)
        _WorkspaceIncidentActivityEntry(
          kind: 'status_update',
          timestamp: parse(row['created_at']?.toString()),
          data: row,
        ),
      for (final row in transitions)
        _WorkspaceIncidentActivityEntry(
          kind: 'status_transition',
          timestamp: parse(row['changed_at']?.toString()),
          data: row,
        ),
      for (final row in reminders)
        _WorkspaceIncidentActivityEntry(
          kind: 'reminder',
          timestamp: parse(
            row['created_at']?.toString() ?? row['due_at']?.toString(),
          ),
          data: row,
        ),
      for (final row in timeline)
        _WorkspaceIncidentActivityEntry(
          kind: 'timeline',
          timestamp: parse(row['ts']?.toString()),
          data: row,
        ),
    ];
    rows.sort((left, right) => right.timestamp.compareTo(left.timestamp));
    return rows;
  }
}

enum _WorkspaceEntityType { doc, sop, incident, task }

enum _WorkspaceSortMode { updated, created, title, status, due, severity }

class _WorkspaceBundle {
  final List<JsonMap> folders;
  final List<JsonMap> docs;
  final List<String> tags;
  final JsonMap? reviewSummary;
  final List<JsonMap> sops;
  final List<JsonMap> dueRuns;
  final List<JsonMap> incidents;
  final JsonMap incidentAnalytics;
  final List<JsonMap> tasks;

  const _WorkspaceBundle({
    required this.folders,
    required this.docs,
    required this.tags,
    required this.reviewSummary,
    required this.sops,
    required this.dueRuns,
    required this.incidents,
    required this.incidentAnalytics,
    required this.tasks,
  });
}

class _WorkspaceEntityRef {
  final _WorkspaceEntityType type;
  final String id;

  const _WorkspaceEntityRef(this.type, this.id);

  @override
  bool operator ==(Object other) =>
      other is _WorkspaceEntityRef && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);
}

enum _WorkspaceTreeNodeKind { folder, item }

class _WorkspaceTreeNode {
  final String id;
  final _WorkspaceTreeNodeKind kind;
  final _WorkspaceEntityType category;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<_WorkspaceTreeNode> children;
  final _WorkspaceEntityRef? entity;
  final JsonMap? folder;
  final _WorkspaceItemRecord? record;

  const _WorkspaceTreeNode({
    required this.id,
    required this.kind,
    required this.category,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.children = const <_WorkspaceTreeNode>[],
    this.entity,
    this.folder,
    this.record,
  });
}

class _WorkspaceItemRecord {
  final _WorkspaceEntityRef ref;
  final String title;
  final String typeLabel;
  final String slug;
  final String status;
  final String summary;
  final String searchText;
  final String? folderId;
  final String? folderPath;
  final DateTime? updatedAt;
  final DateTime? createdAt;
  final DateTime? dueAt;
  final int? severity;
  final List<String> tags;
  final bool archived;
  final bool needsReview;
  final bool reviewDue;
  final bool hasLinkedTasks;
  final bool runOverdue;
  final bool runActive;
  final String sourceKind;
  final JsonMap raw;

  const _WorkspaceItemRecord({
    required this.ref,
    required this.title,
    required this.typeLabel,
    required this.slug,
    required this.status,
    required this.summary,
    required this.searchText,
    required this.folderId,
    required this.folderPath,
    required this.updatedAt,
    required this.createdAt,
    required this.dueAt,
    required this.severity,
    required this.tags,
    required this.archived,
    required this.needsReview,
    required this.reviewDue,
    required this.hasLinkedTasks,
    required this.runOverdue,
    required this.runActive,
    required this.sourceKind,
    required this.raw,
  });

  _WorkspaceEntityType get type => ref.type;
}

class _WorkspaceSearchQuery {
  final SearchQueryAst ast;
  final _WorkspaceSortMode sortMode;

  const _WorkspaceSearchQuery({required this.ast, required this.sortMode});
}

class _WorkspacePanel extends StatelessWidget {
  final EdgeInsetsGeometry padding;
  final Widget child;

  const _WorkspacePanel({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class _WorkspaceFullWidthFrame extends StatelessWidget {
  final String title;
  final Widget? leading;
  final Widget child;

  const _WorkspaceFullWidthFrame({
    required this.title,
    required this.child,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[cs.surface, cs.surfaceContainerLowest, cs.surface],
          ),
        ),
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPad = constraints.maxWidth < 720
                  ? AppSpacing.md
                  : AppSpacing.lg;
              return Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.xs,
                  bottom: AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                      child: Row(
                        children: <Widget>[
                          if (leading != null) ...<Widget>[
                            leading!,
                            const SizedBox(width: AppSpacing.sm),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Expanded(child: child),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WorkspaceContentSurface extends StatelessWidget {
  final Widget child;

  const _WorkspaceContentSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.all(18),
      child: child,
    );
  }
}

class _WorkspaceStateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _WorkspaceStateMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 30, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (onAction != null && actionLabel != null) ...<Widget>[
              const SizedBox(height: 14),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkspaceTrailingStatus extends StatelessWidget {
  final String status;

  const _WorkspaceTrailingStatus({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _WorkspaceTypeBadge extends StatelessWidget {
  final _WorkspaceEntityType type;

  const _WorkspaceTypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = switch (type) {
      _WorkspaceEntityType.doc => 'KB',
      _WorkspaceEntityType.sop => 'SOP',
      _WorkspaceEntityType.incident => 'INC',
      _WorkspaceEntityType.task => 'TASK',
    };
    final color = switch (type) {
      _WorkspaceEntityType.doc => cs.primary,
      _WorkspaceEntityType.sop => cs.secondary,
      _WorkspaceEntityType.incident => cs.error,
      _WorkspaceEntityType.task => cs.tertiary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _WorkspaceDetailHeader extends StatelessWidget {
  final Widget? backButton;
  final String title;
  final String subtitle;
  final List<Widget> badges;
  final List<Widget> actions;

  const _WorkspaceDetailHeader({
    required this.backButton,
    required this.title,
    required this.subtitle,
    required this.badges,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 720;
        final titleBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (subtitle.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (stacked) ...<Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (backButton != null) ...<Widget>[
                    backButton!,
                    const SizedBox(width: 4),
                  ],
                  Expanded(child: titleBlock),
                ],
              ),
              if (actions.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (backButton != null) ...<Widget>[
                    backButton!,
                    const SizedBox(width: 4),
                  ],
                  Expanded(child: titleBlock),
                  if (actions.isNotEmpty)
                    Flexible(
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: actions,
                      ),
                    ),
                ],
              ),
            if (badges.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: badges),
            ],
          ],
        );
      },
    );
  }
}

class _WorkspaceInlineBadge extends StatelessWidget {
  final String label;
  final IconData icon;

  const _WorkspaceInlineBadge({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(140.0, 320.0)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceStepBlock extends StatelessWidget {
  final int stepNumber;
  final String title;
  final String body;
  final List<String> meta;

  const _WorkspaceStepBlock({
    required this.stepNumber,
    required this.title,
    required this.body,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              stepNumber.toString(),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                if (body.trim().isEmpty)
                  Text(AppLocalizations.of(context).text('no_content'))
                else
                  RichContentView(content: body),
                if (meta.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: meta
                        .map(
                          (row) => _WorkspaceInlineBadge(
                            label: row,
                            icon: Icons.info_outline,
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceSopRunSummary extends StatelessWidget {
  final String title;
  final JsonMap run;
  final Map<String, JsonMap> stepDefinitions;

  const _WorkspaceSopRunSummary({
    required this.title,
    required this.run,
    required this.stepDefinitions,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final runSteps = _asJsonList(run['steps'] ?? const []);
    JsonMap? currentStep;
    for (final step in runSteps) {
      if (step['completed'] != true) {
        currentStep = step;
        break;
      }
    }
    final completedAt = (run['completed_at'] ?? '').toString().trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _StatusChip((run['status'] ?? 'in_progress').toString()),
            if (currentStep != null)
              _WorkspaceInlineBadge(
                label:
                    '${l10n.text('current')} ${l10n.text('step')} ${_asInt(currentStep['step_order'])}',
                icon: Icons.flag_outlined,
              ),
            if (completedAt.isNotEmpty)
              _WorkspaceInlineBadge(
                label: completedAt,
                icon: Icons.check_circle_outline,
              ),
          ],
        ),
        const SizedBox(height: 14),
        for (var index = 0; index < runSteps.length; index++)
          Padding(
            padding: EdgeInsets.only(
              bottom: index == runSteps.length - 1 ? 0 : 12,
            ),
            child: _WorkspaceSopRunStepBlock(
              runStep: runSteps[index],
              stepDefinition:
                  stepDefinitions[(runSteps[index]['step_id'] ?? '')
                      .toString()
                      .trim()],
            ),
          ),
      ],
    );
  }
}

class _WorkspaceSopRunStepBlock extends StatelessWidget {
  final JsonMap runStep;
  final JsonMap? stepDefinition;

  const _WorkspaceSopRunStepBlock({
    required this.runStep,
    required this.stepDefinition,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final completed = runStep['completed'] == true;
    final evidenceNote = (runStep['evidence_note'] ?? '').toString().trim();
    final body = (stepDefinition?['body_md'] ?? '').toString();
    final completedAt = (runStep['completed_at'] ?? '').toString().trim();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: completed
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(
                  completed ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${l10n.text('step')} ${_asInt(runStep['step_order'])}',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      (runStep['title'] ?? 'Step').toString(),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (body.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            RichContentView(content: body),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (runStep['evidence_required'] == true)
                _WorkspaceInlineBadge(
                  label: l10n.text('evidence_required'),
                  icon: Icons.rule_folder_outlined,
                ),
              if (completedAt.isNotEmpty)
                _WorkspaceInlineBadge(
                  label: completedAt,
                  icon: Icons.schedule_outlined,
                ),
            ],
          ),
          if (evidenceNote.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              l10n.text('evidence_note'),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            RichContentView(content: evidenceNote),
          ],
          const SizedBox(height: 12),
          _WorkspaceRunAttachmentList(
            runStepId: (runStep['id'] ?? '').toString(),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceRunAttachmentList extends ConsumerWidget {
  final String runStepId;

  const _WorkspaceRunAttachmentList({required this.runStepId});

  Future<List<JsonMap>> _loadAttachments(WidgetRef ref) async {
    final normalizedRunStepId = runStepId.trim();
    if (normalizedRunStepId.isEmpty) {
      return const <JsonMap>[];
    }
    final api = ref.read(apiClientProvider);
    final response = await api.dio.get(
      '/media/attachments',
      queryParameters: <String, String>{
        'entity_type': 'sop_run_step',
        'entity_id': normalizedRunStepId,
      },
    );
    return _asJsonList(response.data);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<List<JsonMap>>(
      future: _loadAttachments(ref),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 24,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return Text(
            requestErrorMessage(snapshot.error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          );
        }
        final attachments = snapshot.data ?? const <JsonMap>[];
        if (attachments.isEmpty) {
          return Text(
            l10n.text('no_data'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.text('evidence_attachments'),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final attachment in attachments)
              Material(
                color: Colors.transparent,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.attach_file_outlined),
                  title: Text(
                    (attachment['original_filename'] ?? 'Attachment')
                        .toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => showMediaPreviewDialog(
                    context: context,
                    filename: (attachment['original_filename'] ?? '')
                        .toString(),
                    url: (attachment['url'] ?? '').toString(),
                    contentType: (attachment['content_type'] ?? '').toString(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _WorkspaceIncidentActionCard extends StatelessWidget {
  final JsonMap item;
  final bool highlighted;
  final VoidCallback onOpenTask;

  const _WorkspaceIncidentActionCard({
    required this.item,
    required this.highlighted,
    required this.onOpenTask,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlighted
            ? cs.primary.withValues(alpha: 0.11)
            : cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  (item['title'] ?? 'Action item').toString(),
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              _WorkspaceTrailingStatus(
                status: (item['status'] ?? 'open').toString(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              if ((item['owner_name'] ?? '').toString().trim().isNotEmpty)
                _WorkspaceMetaPill(
                  label: _t(context, 'owner_prefix'),
                  value: (item['owner_name'] ?? '').toString(),
                ),
              if ((item['due_at'] ?? '').toString().trim().isNotEmpty)
                _WorkspaceMetaPill(
                  label: _t(context, 'due'),
                  value: _formatDate(item['due_at']?.toString()),
                ),
            ],
          ),
          if ((item['notes_md'] ?? '')
              .toString()
              .trim()
              .isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            RichContentView(content: (item['notes_md'] ?? '').toString()),
          ],
          if ((item['task_id'] ?? item['linked_task_id'] ?? '')
              .toString()
              .trim()
              .isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onOpenTask,
              icon: const Icon(Icons.assignment_outlined),
              label: Text(_t(context, 'open_linked_task')),
            ),
          ],
        ],
      ),
    );
  }
}

class _WorkspaceMetaPill extends StatelessWidget {
  final String label;
  final String value;

  const _WorkspaceMetaPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text.rich(
        TextSpan(
          text: '$label ',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w800,
          ),
          children: <InlineSpan>[
            TextSpan(
              text: value,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceIncidentActivityEntry {
  final String kind;
  final DateTime timestamp;
  final JsonMap data;

  const _WorkspaceIncidentActivityEntry({
    required this.kind,
    required this.timestamp,
    required this.data,
  });
}

class _WorkspaceIncidentActivityCard extends StatelessWidget {
  final _WorkspaceIncidentActivityEntry entry;
  final bool highlighted;

  const _WorkspaceIncidentActivityCard({
    required this.entry,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final row = entry.data;
    final title = switch (entry.kind) {
      'status_update' => 'Status update',
      'status_transition' => 'Status audit',
      'reminder' => 'Reminder',
      _ => 'Timeline',
    };
    final subtitle = switch (entry.kind) {
      'status_transition' =>
        '${(row['from_status'] ?? '—').toString()} -> ${(row['to_status'] ?? '').toString()}',
      'reminder' => (row['reminder_key'] ?? '').toString(),
      _ => '',
    };
    final content = switch (entry.kind) {
      'status_update' => (row['message_md'] ?? '').toString(),
      'status_transition' => (row['note_md'] ?? '').toString(),
      'reminder' => [
        if ((row['owner_name'] ?? '').toString().trim().isNotEmpty)
          'Owner ${(row['owner_name'] ?? '').toString().trim()}',
        if ((row['due_at_snapshot'] ?? row['due_at'] ?? '')
            .toString()
            .trim()
            .isNotEmpty)
          'Due ${_formatDateTime((row['due_at_snapshot'] ?? row['due_at']).toString())}',
      ].join(' • '),
      _ => (row['entry_md'] ?? '').toString(),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlighted
            ? cs.primary.withValues(alpha: 0.11)
            : cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _WorkspaceInlineBadge(
                label: title,
                icon: switch (entry.kind) {
                  'status_update' => Icons.campaign_outlined,
                  'status_transition' => Icons.sync_alt_outlined,
                  'reminder' => Icons.alarm_outlined,
                  _ => Icons.timeline_outlined,
                },
              ),
              Text(
                _formatDateTime(entry.timestamp.toIso8601String()),
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          if (subtitle.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
          if (content.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            if (entry.kind == 'reminder')
              Text(content)
            else
              RichContentView(content: content),
          ],
        ],
      ),
    );
  }
}

class _StatLine extends StatelessWidget {
  final String label;
  final String value;

  const _StatLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

String _quoteSearchValue(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  if (!trimmed.contains(RegExp(r'\s'))) {
    return trimmed;
  }
  return '"${trimmed.replaceAll('"', r'\"')}"';
}

String _normalizeWorkspaceSearchInput(String raw) {
  final tightened = raw.replaceAllMapped(
    RegExp(r'([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*'),
    (match) => '${match.group(1)}:',
  );
  return normalizeSearchInput(tightened);
}
