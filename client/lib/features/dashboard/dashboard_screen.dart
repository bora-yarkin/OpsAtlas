// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Dashboard screen and aggregate providers for operational overview widgets.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/api/request_error.dart';
import '../../core/command_palette.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/navigation/app_route_navigation.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/atlas_ui.dart';

typedef DashboardOverviewRequest = ({
  String? selectedSpaceId,
  int timeRangeDays,
});

const List<String> _defaultDashboardWidgetOrder = <String>[
  'profile_actions',
  'my_tasks',
  'incident_queue',
  'due_runs',
  'mentions',
  'activity_feed',
  'spaces_overview',
];

/// Loads the current user profile used by dashboard personalization and greetings.
final meProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final response = await api.dio.get('/auth/me');
  return (response.data as Map).cast<String, dynamic>();
});

/// Loads widget layout, hidden-widget state, and selected-space preferences.
final dashboardPreferencesProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(apiClientProvider);
  final response = await api.dio.get('/auth/me/dashboard-preferences');
  return (response.data as Map).cast<String, dynamic>();
});

/// Aggregates the multi-source dashboard overview payload for the chosen scope.
final dashboardOverviewProvider =
    FutureProvider.family<DashboardOverview, DashboardOverviewRequest>((
      ref,
      request,
    ) async {
      final api = ref.watch(apiClientProvider);
      final spacesResponse = await api.dio.get('/spaces');
      final spaces = _asJsonList(spacesResponse.data);
      final requestedSpaceId = _nonEmptyText(request.selectedSpaceId);
      final selectedSpaceId =
          requestedSpaceId != null &&
              spaces.any(
                (space) =>
                    (space['id'] ?? '').toString().trim() == requestedSpaceId,
              )
          ? requestedSpaceId
          : _nonEmptyText(spaces.isEmpty ? null : spaces.first['id']);
      final cutoff = DateTime.now().subtract(
        Duration(days: request.timeRangeDays),
      );

      final myTasksFuture = api.dio.get('/tasks/my');
      final feedFuture = api.dio.get(
        '/analytics/feed',
        queryParameters: <String, dynamic>{
          'limit': 40,
          'space_id': ?selectedSpaceId,
        },
      );
      final dueRunsFuture = selectedSpaceId == null
          ? null
          : api.dio.get('/sop/spaces/$selectedSpaceId/due-runs');
      final mentionsFuture = selectedSpaceId == null
          ? null
          : api.dio.get(
              '/kb/spaces/$selectedSpaceId/mentions',
              queryParameters: <String, dynamic>{
                'unread_only': true,
                'max_age_days': request.timeRangeDays,
              },
            );
      final incidentsFuture = selectedSpaceId == null
          ? null
          : api.dio.get(
              '/incidents/spaces/$selectedSpaceId',
              queryParameters: const <String, dynamic>{
                'include_archived': false,
              },
            );

      final responses = await Future.wait<dynamic>(<Future<dynamic>>[
        myTasksFuture,
        feedFuture,
        ?dueRunsFuture,
        ?mentionsFuture,
        ?incidentsFuture,
      ]);

      final myTasks = _asJsonList(responses[0].data)
          .where(
            (task) =>
                selectedSpaceId == null ||
                (task['space_id'] ?? '').toString().trim() == selectedSpaceId,
          )
          .toList();
      final feed =
          _asJsonList(responses[1].data).where((event) {
            final ts = _parseDateTime(event['ts'] ?? event['created_at']);
            return ts == null || !ts.isBefore(cutoff);
          }).toList()..sort((left, right) {
            final rightTs =
                _parseDateTime(right['ts'] ?? right['created_at']) ??
                DateTime.fromMillisecondsSinceEpoch(0);
            final leftTs =
                _parseDateTime(left['ts'] ?? left['created_at']) ??
                DateTime.fromMillisecondsSinceEpoch(0);
            return rightTs.compareTo(leftTs);
          });

      var responseIndex = 2;
      final dueRuns = dueRunsFuture == null
          ? const <Map<String, dynamic>>[]
          : (() {
              final items = _asJsonList(
                responses[responseIndex++].data,
              ).toList();
              items.sort((left, right) {
                final leftDue =
                    _parseDateTime(left['next_due_at']) ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                final rightDue =
                    _parseDateTime(right['next_due_at']) ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                return leftDue.compareTo(rightDue);
              });
              return items;
            })();

      final mentions = mentionsFuture == null
          ? const <Map<String, dynamic>>[]
          : (() {
              final items = _asJsonList(
                responses[responseIndex++].data,
              ).toList();
              items.sort((left, right) {
                final rightTs =
                    _parseDateTime(right['created_at']) ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                final leftTs =
                    _parseDateTime(left['created_at']) ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                return rightTs.compareTo(leftTs);
              });
              return items;
            })();

      final incidents = incidentsFuture == null
          ? const <Map<String, dynamic>>[]
          : (() {
              final items =
                  _asJsonList(responses[responseIndex++].data)
                      .where((incident) {
                        final status = (incident['status'] ?? '')
                            .toString()
                            .trim()
                            .toLowerCase();
                        return incident['archived'] != true &&
                            status != 'resolved';
                      })
                      .toList(growable: false)
                    ..sort((left, right) {
                      final leftSeverity = _intValue(left['severity']);
                      final rightSeverity = _intValue(right['severity']);
                      if (leftSeverity != rightSeverity) {
                        return leftSeverity.compareTo(rightSeverity);
                      }
                      final byOpenItems = _intValue(
                        right['open_action_items'],
                      ).compareTo(_intValue(left['open_action_items']));
                      if (byOpenItems != 0) {
                        return byOpenItems;
                      }
                      final rightUpdated =
                          _parseDateTime(
                            right['updated_at'] ?? right['created_at'],
                          ) ??
                          DateTime.fromMillisecondsSinceEpoch(0);
                      final leftUpdated =
                          _parseDateTime(
                            left['updated_at'] ?? left['created_at'],
                          ) ??
                          DateTime.fromMillisecondsSinceEpoch(0);
                      return rightUpdated.compareTo(leftUpdated);
                    });
              return items;
            })();

      return DashboardOverview(
        spaces: spaces,
        myTasks: myTasks,
        feed: feed,
        dueRuns: dueRuns,
        mentions: mentions,
        incidents: incidents,
      );
    });

class DashboardOverview {
  final List<Map<String, dynamic>> spaces;
  final List<Map<String, dynamic>> myTasks;
  final List<Map<String, dynamic>> feed;
  final List<Map<String, dynamic>> dueRuns;
  final List<Map<String, dynamic>> mentions;
  final List<Map<String, dynamic>> incidents;

  const DashboardOverview({
    required this.spaces,
    required this.myTasks,
    required this.feed,
    required this.dueRuns,
    required this.mentions,
    required this.incidents,
  });
}

enum _DashboardTimeRange { day, week, month }

/// Home screen that consolidates tasks, incidents, mentions, and activity feed.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String? _selectedSpaceId;
  bool _myScopeOnly = true;
  _DashboardTimeRange _timeRange = _DashboardTimeRange.week;
  bool _preferencesInitialized = false;
  List<String> _widgetOrder = const <String>[];
  Set<String> _hiddenWidgets = const <String>{};
  DateTime? _feedSeenAt;

  void _openRoute(String route) {
    atlasOpenRoute(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final meAsync = ref.watch(meProvider);
    final prefsAsync = ref.watch(dashboardPreferencesProvider);
    final prefs = prefsAsync.asData?.value;
    if (prefs != null) {
      _initializePreferences(prefs);
    }
    final overviewRequest = (
      selectedSpaceId: _selectedSpaceId,
      timeRangeDays: _timeRangeDays(_timeRange),
    );
    final overviewAsync = ref.watch(dashboardOverviewProvider(overviewRequest));
    final me = meAsync.asData?.value;
    final currentUserId = (me?['id'] ?? '').toString().trim();
    final displayName =
        _nonEmptyText(me?['display_name']) ??
        _nonEmptyText(me?['name']) ??
        _nonEmptyText(me?['email']) ??
        l10n.text('user_fallback');

    return CommandPaletteScope(
      commands: _dashboardCommands(l10n),
      child: AtlasPageFrame(
        title: l10n.text('dashboard'),
        subtitle: l10n.text('workspace_summary_desc'),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.text('customize_dashboard_widgets'),
            onPressed: () => _openCustomizeWidgetsDialog(l10n),
            icon: const Icon(Icons.tune),
          ),
          OutlinedButton.icon(
            onPressed: () {
              setState(() => _preferencesInitialized = false);
              ref.invalidate(meProvider);
              ref.invalidate(dashboardPreferencesProvider);
              ref.invalidate(dashboardOverviewProvider(overviewRequest));
            },
            icon: const Icon(Icons.refresh),
            label: Text(l10n.text('refresh')),
          ),
        ],
        child: overviewAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AtlasEmptyState(
            icon: Icons.error_outline,
            title: l10n.text('no_data'),
            subtitle: requestErrorMessage(error, context: context),
            action: FilledButton.icon(
              onPressed: () =>
                  ref.invalidate(dashboardOverviewProvider(overviewRequest)),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.text('refresh')),
            ),
          ),
          data: (overview) {
            _ensureValidSelectedSpace(overview.spaces);

            final selectedSpace = overview.spaces.firstWhere(
              (space) =>
                  (space['id'] ?? '').toString().trim() ==
                  (_selectedSpaceId ?? '').trim(),
              orElse: () => const <String, dynamic>{},
            );
            final selectedSpaceName =
                _nonEmptyText(selectedSpace['name']) ??
                _nonEmptyText(selectedSpace['slug']) ??
                l10n.text('all_spaces');
            final openTasks = overview.myTasks
                .where((task) {
                  final status = (task['status'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();
                  return status != 'done';
                })
                .toList(growable: false);
            final overdueTasks = openTasks
                .where(_isTaskOverdue)
                .toList(growable: false);
            final dueSoonTasks = openTasks
                .where(
                  (task) => _isTaskDueSoon(
                    task,
                    withinDays: _timeRangeDays(_timeRange),
                  ),
                )
                .toList(growable: false);
            final visibleDueRuns = overview.dueRuns
                .where((row) {
                  if (!_myScopeOnly) {
                    return true;
                  }
                  final operatorUserId = (row['operator_user_id'] ?? '')
                      .toString()
                      .trim();
                  return operatorUserId.isEmpty ||
                      operatorUserId == currentUserId;
                })
                .toList(growable: false);
            final visibleFeed = overview.feed
                .where((event) {
                  if (!_myScopeOnly) {
                    return true;
                  }
                  return (event['user_id'] ?? '').toString().trim() ==
                      currentUserId;
                })
                .toList(growable: false);
            final unreadFeedCount = visibleFeed.where((event) {
              final ts = _parseDateTime(event['ts'] ?? event['created_at']);
              if (ts == null) {
                return false;
              }
              if (_feedSeenAt == null) {
                return true;
              }
              return ts.isAfter(_feedSeenAt!);
            }).length;
            final unresolvedIncidents = overview.incidents.length;
            final visibleWidgetIds =
                _normalizedWidgetOrder(
                      _widgetOrder.isEmpty
                          ? _defaultDashboardWidgetOrder
                          : _widgetOrder,
                    )
                    .where((widgetId) => !_hiddenWidgets.contains(widgetId))
                    .toList(growable: false);

            final widgetById = <String, Widget>{
              'profile_actions': _buildProfileActionsPanel(
                l10n: l10n,
                overview: overview,
                selectedSpaceName: selectedSpaceName,
              ),
              'my_tasks': _buildMyTasksPanel(
                l10n: l10n,
                openTasks: openTasks,
                overdueTasks: overdueTasks,
                dueSoonTasks: dueSoonTasks,
              ),
              'incident_queue': _buildIncidentQueuePanel(
                l10n: l10n,
                incidents: overview.incidents,
                selectedSpaceName: selectedSpaceName,
              ),
              'due_runs': _buildDueRunsPanel(
                l10n: l10n,
                dueRuns: visibleDueRuns,
                selectedSpaceName: selectedSpaceName,
              ),
              'mentions': _buildMentionsPanel(
                l10n: l10n,
                mentions: overview.mentions,
                selectedSpaceName: selectedSpaceName,
              ),
              'activity_feed': _buildActivityFeedPanel(
                l10n: l10n,
                feed: visibleFeed,
                unreadCount: unreadFeedCount,
              ),
              'spaces_overview': _buildSpacesPanel(
                l10n: l10n,
                spaces: overview.spaces,
              ),
            };

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: Text(
                      '${l10n.text('welcome_back')}, $displayName',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 980
                          ? 4
                          : constraints.maxWidth >= 700
                          ? 2
                          : 1;
                      final tiles = <Widget>[
                        AtlasStatTile(
                          label: l10n.text('spaces_overview'),
                          value: overview.spaces.length.toString(),
                          icon: Icons.hub_outlined,
                        ),
                        AtlasStatTile(
                          label: l10n.text('my_assigned_tasks'),
                          value: openTasks.length.toString(),
                          icon: Icons.task_alt_outlined,
                        ),
                        AtlasStatTile(
                          label: l10n.text('incidents'),
                          value: unresolvedIncidents.toString(),
                          icon: Icons.report_outlined,
                        ),
                        AtlasStatTile(
                          label: l10n.text('mention_inbox'),
                          value: overview.mentions.length.toString(),
                          icon: Icons.mark_email_unread_outlined,
                        ),
                      ];
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: AppSpacing.sm,
                          mainAxisSpacing: AppSpacing.sm,
                          mainAxisExtent: 96,
                        ),
                        itemCount: tiles.length,
                        itemBuilder: (_, index) => tiles[index],
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (visibleWidgetIds.isEmpty)
                    AtlasEmptyState(
                      icon: Icons.dashboard_customize_outlined,
                      title: l10n.text('all_widgets_hidden'),
                      subtitle: l10n.text('re_enable_dashboard_widgets'),
                      action: FilledButton.icon(
                        onPressed: () => _openCustomizeWidgetsDialog(l10n),
                        icon: const Icon(Icons.tune),
                        label: Text(l10n.text('customize_dashboard_widgets')),
                      ),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final stacked = constraints.maxWidth < 1100;
                        if (stacked) {
                          return Column(
                            children: visibleWidgetIds
                                .map(
                                  (widgetId) => Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: AppSpacing.md,
                                    ),
                                    child: widgetById[widgetId]!,
                                  ),
                                )
                                .toList(growable: false),
                          );
                        }

                        final rows = <Widget>[];
                        for (
                          var index = 0;
                          index < visibleWidgetIds.length;
                          index += 2
                        ) {
                          final leftId = visibleWidgetIds[index];
                          final rightId = index + 1 < visibleWidgetIds.length
                              ? visibleWidgetIds[index + 1]
                              : null;
                          rows.add(
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.md,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Expanded(child: widgetById[leftId]!),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: rightId == null
                                        ? const SizedBox.shrink()
                                        : widgetById[rightId]!,
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        return Column(children: rows);
                      },
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _initializePreferences(Map<String, dynamic> prefs) {
    if (_preferencesInitialized) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _preferencesInitialized) {
        return;
      }
      setState(() {
        _preferencesInitialized = true;
        _selectedSpaceId = _nonEmptyText(prefs['selected_space_id']);
        _widgetOrder = _normalizedWidgetOrder(
          _stringList(prefs['widget_order']),
        );
        _hiddenWidgets = _stringList(prefs['hidden_widgets']).toSet();
        _feedSeenAt = _parseDateTime(prefs['feed_seen_at']);
      });
    });
  }

  void _ensureValidSelectedSpace(List<Map<String, dynamic>> spaces) {
    if (spaces.isEmpty) {
      return;
    }
    final current = (_selectedSpaceId ?? '').trim();
    final exists = spaces.any(
      (space) => (space['id'] ?? '').toString().trim() == current,
    );
    if (current.isNotEmpty && exists) {
      return;
    }
    final fallbackId = (spaces.first['id'] ?? '').toString().trim();
    if (fallbackId.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedSpaceId == fallbackId) {
        return;
      }
      setState(() => _selectedSpaceId = fallbackId);
      _patchDashboardPreferences(
        applySelectedSpaceId: true,
        selectedSpaceId: fallbackId,
      );
    });
  }

  List<String> _normalizedWidgetOrder(List<String> raw) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final widgetId in raw) {
      final value = widgetId.trim();
      if (value.isEmpty || seen.contains(value)) {
        continue;
      }
      if (!_defaultDashboardWidgetOrder.contains(value)) {
        continue;
      }
      seen.add(value);
      normalized.add(value);
    }
    for (final widgetId in _defaultDashboardWidgetOrder) {
      if (seen.add(widgetId)) {
        normalized.add(widgetId);
      }
    }
    return normalized;
  }

  Future<void> _patchDashboardPreferences({
    bool applySelectedSpaceId = false,
    String? selectedSpaceId,
    bool applyWidgetOrder = false,
    List<String>? widgetOrder,
    bool applyHiddenWidgets = false,
    Set<String>? hiddenWidgets,
    bool applyFeedSeenAt = false,
    DateTime? feedSeenAt,
    String? successMessage,
  }) async {
    final api = ref.read(apiClientProvider);
    final payload = <String, dynamic>{
      if (applySelectedSpaceId) 'selected_space_id': selectedSpaceId,
      if (applyWidgetOrder) 'widget_order': widgetOrder,
      if (applyHiddenWidgets)
        'hidden_widgets': hiddenWidgets?.toList(growable: false),
      if (applyFeedSeenAt)
        'feed_seen_at': feedSeenAt?.toUtc().toIso8601String(),
    };
    if (payload.isEmpty) {
      return;
    }
    try {
      await api.dio.patch('/auth/me/dashboard-preferences', data: payload);
      ref.invalidate(dashboardPreferencesProvider);
      if (!mounted || successMessage == null || successMessage.isEmpty) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(requestErrorMessage(error, context: context))),
      );
    }
  }

  Future<void> _openCustomizeWidgetsDialog(AppLocalizations l10n) async {
    final orderDraft = List<String>.from(
      _normalizedWidgetOrder(
        _widgetOrder.isEmpty ? _defaultDashboardWidgetOrder : _widgetOrder,
      ),
    );
    final hiddenDraft = Set<String>.from(_hiddenWidgets);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(l10n.text('customize_dashboard_layout')),
              content: SizedBox(
                width: 560,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(l10n.text('dashboard_layout_help')),
                    const SizedBox(height: AppSpacing.sm),
                    SizedBox(
                      height: 320,
                      child: ReorderableListView.builder(
                        itemCount: orderDraft.length,
                        onReorderItem: (oldIndex, newIndex) {
                          setDialogState(() {
                            final moved = orderDraft.removeAt(oldIndex);
                            orderDraft.insert(newIndex, moved);
                          });
                        },
                        itemBuilder: (context, index) {
                          final widgetId = orderDraft[index];
                          final visible = !hiddenDraft.contains(widgetId);
                          return ListTile(
                            key: ValueKey<String>(widgetId),
                            leading: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_handle),
                            ),
                            title: Text(_widgetLabel(l10n, widgetId)),
                            subtitle: Text(
                              visible
                                  ? l10n.text('visible')
                                  : l10n.text('hidden'),
                            ),
                            trailing: Switch(
                              value: visible,
                              onChanged: (value) {
                                setDialogState(() {
                                  if (value) {
                                    hiddenDraft.remove(widgetId);
                                  } else {
                                    hiddenDraft.add(widgetId);
                                  }
                                });
                              },
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
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.text('cancel')),
                ),
                FilledButton(
                  onPressed: () async {
                    setState(() {
                      _widgetOrder = List<String>.from(orderDraft);
                      _hiddenWidgets = Set<String>.from(hiddenDraft);
                    });
                    await _patchDashboardPreferences(
                      applyWidgetOrder: true,
                      widgetOrder: orderDraft,
                      applyHiddenWidgets: true,
                      hiddenWidgets: hiddenDraft,
                      successMessage: l10n.text('dashboard_layout_saved'),
                    );
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                    }
                  },
                  child: Text(l10n.text('apply_layout')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<ContextCommand> _dashboardCommands(AppLocalizations l10n) {
    final spaceId = _nonEmptyText(_selectedSpaceId);
    if (spaceId == null) {
      return const <ContextCommand>[];
    }
    return <ContextCommand>[
      ContextCommand(
        label: l10n.text('new_task'),
        subtitle: l10n.text('create_current_space_task_help'),
        icon: Icons.add_task_outlined,
        action: () => context.go(_taskCreateRoute(spaceId)),
      ),
      ContextCommand(
        label: l10n.text('new_document'),
        subtitle: l10n.text('create_current_space_doc_help'),
        icon: Icons.note_add_outlined,
        action: () => _openRoute(_spaceCreateRoute(spaceId, 'doc')),
      ),
      ContextCommand(
        label: l10n.text('new_sop'),
        subtitle: l10n.text('create_current_space_sop_help'),
        icon: Icons.playlist_add_outlined,
        action: () => _openRoute(_spaceCreateRoute(spaceId, 'sop')),
      ),
      ContextCommand(
        label: l10n.text('new_incident'),
        subtitle: l10n.text('create_current_space_incident_help'),
        icon: Icons.report_outlined,
        action: () => _openRoute(_spaceCreateRoute(spaceId, 'incident')),
      ),
      ContextCommand(
        label: l10n.text('open_current_space'),
        subtitle: l10n.text('open_current_space_help'),
        icon: Icons.open_in_new_outlined,
        action: () => _openRoute('/spaces/$spaceId'),
      ),
    ];
  }

  Widget _buildProfileActionsPanel({
    required AppLocalizations l10n,
    required DashboardOverview overview,
    required String selectedSpaceName,
  }) {
    final hasSelectedSpace = _nonEmptyText(_selectedSpaceId) != null;
    return AtlasPanel(
      title: l10n.text('profile_actions'),
      subtitle: l10n.text('profile_actions_desc'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedSpaceId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.text('space')),
                  items: overview.spaces
                      .map(
                        (space) => DropdownMenuItem<String>(
                          value: (space['id'] ?? '').toString().trim(),
                          child: Text(
                            _nonEmptyText(space['name']) ??
                                _nonEmptyText(space['slug']) ??
                                l10n.text('space'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) async {
                    final nextValue = _nonEmptyText(value);
                    setState(() => _selectedSpaceId = nextValue);
                    await _patchDashboardPreferences(
                      applySelectedSpaceId: true,
                      selectedSpaceId: nextValue,
                    );
                  },
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<_DashboardTimeRange>(
                  initialValue: _timeRange,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.text('time_range'),
                  ),
                  items: _DashboardTimeRange.values
                      .map(
                        (range) => DropdownMenuItem<_DashboardTimeRange>(
                          value: range,
                          child: Text(_timeRangeLabel(l10n, range)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() => _timeRange = value);
                  },
                ),
              ),
              FilterChip(
                selected: _myScopeOnly,
                label: Text(l10n.text('my_scope')),
                onSelected: (value) {
                  setState(() => _myScopeOnly = value);
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (!hasSelectedSpace)
            Text(l10n.text('select_space_for_quick_actions'))
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () =>
                      context.go(_taskCreateRoute(_selectedSpaceId!)),
                  icon: const Icon(Icons.add_task_outlined),
                  label: Text(l10n.text('new_task')),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      _openRoute(_spaceCreateRoute(_selectedSpaceId!, 'doc')),
                  icon: const Icon(Icons.note_add_outlined),
                  label: Text(l10n.text('new_document')),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      _openRoute(_spaceCreateRoute(_selectedSpaceId!, 'sop')),
                  icon: const Icon(Icons.playlist_add_outlined),
                  label: Text(l10n.text('new_sop')),
                ),
                OutlinedButton.icon(
                  onPressed: () => _openRoute(
                    _spaceCreateRoute(_selectedSpaceId!, 'incident'),
                  ),
                  icon: const Icon(Icons.report_outlined),
                  label: Text(l10n.text('new_incident')),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            selectedSpaceName,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyTasksPanel({
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> openTasks,
    required List<Map<String, dynamic>> overdueTasks,
    required List<Map<String, dynamic>> dueSoonTasks,
  }) {
    if (openTasks.isEmpty) {
      return AtlasPanel(
        title: l10n.text('my_assigned_tasks'),
        subtitle: l10n.text('my_tasks_desc'),
        child: AtlasEmptyState(
          icon: Icons.task_alt_outlined,
          title: l10n.text('my_tasks_empty'),
        ),
      );
    }

    final rows = overdueTasks.isNotEmpty
        ? overdueTasks.take(4).toList(growable: false)
        : dueSoonTasks.isNotEmpty
        ? dueSoonTasks.take(4).toList(growable: false)
        : openTasks.take(4).toList(growable: false);

    return AtlasPanel(
      title: l10n.text('my_assigned_tasks'),
      subtitle: l10n.text('my_tasks_desc'),
      child: Column(
        children: rows
            .map((task) {
              final route = _taskRoute(task);
              final dueAt = _nonEmptyText(task['due_at']);
              final dueText = dueAt == null ? '' : _formatDue(dueAt);
              final prefix = overdueTasks.contains(task)
                  ? l10n.text('overdue')
                  : dueSoonTasks.contains(task)
                  ? l10n.text('due_soon')
                  : _taskStatusLabel(l10n, (task['status'] ?? '').toString());
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  overdueTasks.contains(task)
                      ? Icons.warning_amber_outlined
                      : dueSoonTasks.contains(task)
                      ? Icons.schedule_outlined
                      : Icons.task_alt_outlined,
                ),
                title: Text(
                  _nonEmptyText(task['title']) ?? l10n.text('no_data'),
                ),
                subtitle: Text(dueText.isEmpty ? prefix : '$prefix • $dueText'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _openRoute(route),
              );
            })
            .toList(growable: false),
      ),
    );
  }

  Widget _buildDueRunsPanel({
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> dueRuns,
    required String selectedSpaceName,
  }) {
    return AtlasPanel(
      title: l10n.text('due_sop_runs'),
      subtitle: selectedSpaceName,
      child: dueRuns.isEmpty
          ? AtlasEmptyState(
              icon: Icons.schedule_outlined,
              title: l10n.text('no_data'),
            )
          : Column(
              children: dueRuns
                  .take(4)
                  .map((dueRun) {
                    final route = _dueRunRoute(dueRun);
                    final dueText = _formatDue(
                      (dueRun['next_due_at'] ?? '').toString(),
                    );
                    final operatorName =
                        _nonEmptyText(dueRun['operator_name']) ??
                        (dueRun['overdue'] == true
                            ? l10n.text('overdue')
                            : l10n.text('due_soon'));
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule_outlined),
                      title: Text(
                        dueText.isEmpty ? l10n.text('due_sop_runs') : dueText,
                      ),
                      subtitle: Text(operatorName),
                      trailing: route == null
                          ? null
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: route == null ? null : () => _openRoute(route),
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }

  Widget _buildIncidentQueuePanel({
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> incidents,
    required String selectedSpaceName,
  }) {
    return AtlasPanel(
      title: l10n.text('incidents'),
      subtitle: selectedSpaceName,
      child: incidents.isEmpty
          ? AtlasEmptyState(
              icon: Icons.report_outlined,
              title: l10n.text('no_data'),
            )
          : Column(
              children: incidents
                  .take(4)
                  .map((incident) {
                    final route = _incidentRoute(incident);
                    final summary = (incident['summary_md'] ?? '')
                        .toString()
                        .trim();
                    final status = _incidentStatusLabel(
                      l10n,
                      (incident['status'] ?? '').toString(),
                    );
                    final openItems = _intValue(incident['open_action_items']);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        child: Text('${incident['severity'] ?? '?'}'),
                      ),
                      title: Text(
                        _nonEmptyText(incident['title']) ??
                            l10n.text('untitled_incident'),
                      ),
                      subtitle: Text(
                        '$status • $openItems ${l10n.text('open_items_suffix')}'
                        '${summary.isEmpty ? '' : ' • ${summary.replaceAll('\n', ' ')}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: route == null
                          ? null
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: route == null ? null : () => _openRoute(route),
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }

  Widget _buildMentionsPanel({
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> mentions,
    required String selectedSpaceName,
  }) {
    return AtlasPanel(
      title: l10n.text('mention_inbox'),
      subtitle: selectedSpaceName,
      child: mentions.isEmpty
          ? AtlasEmptyState(
              icon: Icons.mark_email_unread_outlined,
              title: l10n.text('no_activity_events_yet'),
            )
          : Column(
              children: mentions
                  .take(4)
                  .map((mention) {
                    final route = _mentionRoute(mention);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.mark_email_unread_outlined),
                      title: Text(
                        _nonEmptyText(mention['doc_title']) ??
                            l10n.text('untitled'),
                      ),
                      subtitle: Text(
                        (mention['comment_excerpt'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: route == null
                          ? null
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: route == null ? null : () => _openRoute(route),
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }

  Widget _buildActivityFeedPanel({
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> feed,
    required int unreadCount,
  }) {
    return AtlasPanel(
      title: l10n.text('activity_feed'),
      subtitle: l10n.text('activity_feed_desc'),
      trailing: unreadCount <= 0
          ? null
          : TextButton.icon(
              onPressed: () => _markFeedRead(l10n),
              icon: const Icon(Icons.done_all_outlined),
              label: Text('${l10n.text('mark_read')} ($unreadCount)'),
            ),
      child: feed.isEmpty
          ? AtlasEmptyState(
              icon: Icons.notifications_off_outlined,
              title: l10n.text('no_activity_events_yet'),
            )
          : Column(
              children: feed
                  .take(6)
                  .map((event) {
                    final line = _feedLine(l10n, event);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.bolt_outlined),
                      title: Text(
                        line.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(line.subtitle),
                      trailing: line.route == null
                          ? null
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: line.route == null
                          ? null
                          : () => _openRoute(line.route!),
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }

  Widget _buildSpacesPanel({
    required AppLocalizations l10n,
    required List<Map<String, dynamic>> spaces,
  }) {
    return AtlasPanel(
      title: l10n.text('spaces_overview'),
      subtitle: l10n.text('spaces_overview_desc'),
      child: spaces.isEmpty
          ? AtlasEmptyState(
              icon: Icons.hub_outlined,
              title: l10n.text('no_spaces_yet'),
            )
          : Column(
              children: spaces
                  .take(6)
                  .map((space) {
                    final spaceId = (space['id'] ?? '').toString().trim();
                    final label =
                        _nonEmptyText(space['name']) ??
                        _nonEmptyText(space['slug']) ??
                        l10n.text('space');
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.hub_outlined),
                      title: Text(label),
                      subtitle: Text(
                        '${l10n.text('members')}: ${_intValue(space['member_count'])} • '
                        '${l10n.text('tasks')}: ${_intValue(space['open_task_count'])} • '
                        '${l10n.text('incidents')}: ${_intValue(space['active_incident_count'])}',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openRoute('/spaces/$spaceId'),
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }

  String _widgetLabel(AppLocalizations l10n, String widgetId) {
    return switch (widgetId) {
      'profile_actions' => l10n.text('profile_actions'),
      'my_tasks' => l10n.text('my_assigned_tasks'),
      'incident_queue' => l10n.text('incidents'),
      'due_runs' => l10n.text('due_sop_runs'),
      'mentions' => l10n.text('mention_inbox'),
      'activity_feed' => l10n.text('activity_feed'),
      'spaces_overview' => l10n.text('spaces_overview'),
      _ => widgetId,
    };
  }

  String _timeRangeLabel(AppLocalizations l10n, _DashboardTimeRange range) {
    return switch (range) {
      _DashboardTimeRange.day => l10n.text('last_24_hours'),
      _DashboardTimeRange.week => l10n.text('last_7_days'),
      _DashboardTimeRange.month => l10n.text('last_30_days'),
    };
  }

  int _timeRangeDays(_DashboardTimeRange range) {
    return switch (range) {
      _DashboardTimeRange.day => 1,
      _DashboardTimeRange.week => 7,
      _DashboardTimeRange.month => 30,
    };
  }

  String _taskCreateRoute(String spaceId) {
    return Uri(
      path: '/tasks',
      queryParameters: <String, String>{'spaceId': spaceId, 'create': 'task'},
    ).toString();
  }

  String _spaceCreateRoute(String spaceId, String create) {
    return Uri(
      path: '/spaces/$spaceId',
      queryParameters: <String, String>{'create': create},
    ).toString();
  }

  String _taskRoute(Map<String, dynamic> task) {
    final taskId = (task['id'] ?? '').toString().trim();
    final spaceId = (task['space_id'] ?? '').toString().trim();
    return Uri(
      path: '/tasks',
      queryParameters: <String, String>{
        if (spaceId.isNotEmpty) 'spaceId': spaceId,
        if (taskId.isNotEmpty) 'search': taskId,
      },
    ).toString();
  }

  String? _mentionRoute(Map<String, dynamic> mention) {
    final spaceId = (mention['space_id'] ?? '').toString().trim();
    final docId = (mention['doc_id'] ?? '').toString().trim();
    if (spaceId.isEmpty || docId.isEmpty) {
      return null;
    }
    return Uri(
      path: '/spaces/$spaceId',
      queryParameters: <String, String>{'docId': docId},
    ).toString();
  }

  String? _dueRunRoute(Map<String, dynamic> dueRun) {
    final sopId = (dueRun['sop_id'] ?? '').toString().trim();
    final spaceId = (_selectedSpaceId ?? '').trim();
    if (spaceId.isEmpty || sopId.isEmpty) {
      return null;
    }
    return Uri(
      path: '/spaces/$spaceId',
      queryParameters: <String, String>{'sopId': sopId},
    ).toString();
  }

  String _incidentStatusLabel(AppLocalizations l10n, String status) {
    return switch (status.trim().toLowerCase()) {
      'monitoring' => l10n.text('status_monitoring'),
      'resolved' => l10n.text('status_resolved'),
      _ => l10n.text('status_open'),
    };
  }

  String? _incidentRoute(Map<String, dynamic> incident) {
    final incidentId = (incident['id'] ?? '').toString().trim();
    final spaceId = (incident['space_id'] ?? _selectedSpaceId ?? '')
        .toString()
        .trim();
    if (incidentId.isEmpty || spaceId.isEmpty) {
      return null;
    }
    return Uri(
      path: '/spaces/$spaceId',
      queryParameters: <String, String>{'incidentId': incidentId},
    ).toString();
  }

  Future<void> _markFeedRead(AppLocalizations l10n) async {
    final seenAt = DateTime.now();
    setState(() => _feedSeenAt = seenAt);
    await _patchDashboardPreferences(
      applyFeedSeenAt: true,
      feedSeenAt: seenAt,
      successMessage: l10n.text('activity_feed_marked_read'),
    );
  }
}

_FeedLine _feedLine(AppLocalizations l10n, Map<String, dynamic> event) {
  final meta = event['meta'] is Map
      ? (event['meta'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final actor = _firstHumanText(<Object?>[
    event['actor_name'],
    meta['actor_name'],
    meta['actor'],
  ]);
  final action = _activityActionLabel(l10n, event, meta);
  final namedEntity = _activityEntityName(l10n, event, meta);
  final entityType = (event['entity_type'] ?? '').toString().trim();
  final entityLabel = _entityTypeLabel(l10n, entityType);

  var base = action;
  if (namedEntity.isNotEmpty) {
    base = '$base $namedEntity'.trim();
  } else if (entityLabel.isNotEmpty &&
      !base.toLowerCase().contains(entityLabel.toLowerCase())) {
    base = '$base $entityLabel'.trim();
  }
  if (base.isEmpty) {
    base = l10n.text('activity_title');
  }
  final title = actor.isNotEmpty ? '$actor • $base' : base;
  final when = _formatFeedTimestamp(event);
  final spaceName =
      _nonEmptyText(event['space_name']) ?? _nonEmptyText(meta['space_name']);
  final detailText = _activityDetailText(l10n, event, meta);
  final subtitleParts = <String>[
    if (when.isNotEmpty) when,
    if (spaceName != null && spaceName.isNotEmpty) spaceName,
    if (detailText.isNotEmpty && detailText != spaceName) detailText,
  ];
  final subtitle = subtitleParts.isEmpty ? when : subtitleParts.join(' • ');

  return _FeedLine(
    title: title,
    subtitle: subtitle,
    route: _eventRoute(event, meta),
  );
}

String _activityActionLabel(
  AppLocalizations l10n,
  Map<String, dynamic> event,
  Map<String, dynamic> meta,
) {
  final type = (event['event_type'] ?? '').toString().trim().toLowerCase();
  if (type == 'task_updated' && meta['comment'] == true) {
    return l10n.text('activity_commented_task_named_prefix');
  }
  if (type == 'task_updated' &&
      (meta['status'] ?? '').toString().trim().toLowerCase() == 'done') {
    return l10n.text('activity_completed_task_named_prefix');
  }
  return switch (type) {
    'view' => l10n.text('activity_viewed_named_prefix'),
    'open' => l10n.text('activity_viewed_named_prefix'),
    'search_query_issued' => l10n.text('activity_searched_named_prefix'),
    'search_results_shown' => l10n.text('activity_searched_named_prefix'),
    'search_no_result' => l10n.text('activity_searched_named_prefix'),
    'search_suggestion_accepted' => l10n.text('activity_searched_named_prefix'),
    'kb_search_no_results' => l10n.text('activity_searched_named_prefix'),
    'task_created' => l10n.text('activity_created_task_named_prefix'),
    'task_updated' => l10n.text('activity_updated_task_named_prefix'),
    'doc_comment_mention' => l10n.text('activity_mentioned_in_named_prefix'),
    'incident_action_reminder' => l10n.text(
      'activity_sent_reminder_named_prefix',
    ),
    'incident_status_update' => l10n.text(
      'activity_updated_incident_named_prefix',
    ),
    _ => _humanizeToken(type),
  };
}

String _activityEntityName(
  AppLocalizations l10n,
  Map<String, dynamic> event,
  Map<String, dynamic> meta,
) {
  final eventType = (event['event_type'] ?? '').toString().trim().toLowerCase();
  if (<String>{
    'kb_search_no_results',
    'search_query_issued',
    'search_results_shown',
    'search_no_result',
  }.contains(eventType)) {
    final query = _firstHumanText(<Object?>[meta['query']]);
    if (query.isNotEmpty) {
      return '"$query"';
    }
  }
  if (eventType == 'search_suggestion_accepted') {
    final nextQuery = _firstHumanText(<Object?>[
      meta['next_query'],
      meta['query'],
    ]);
    if (nextQuery.isNotEmpty) {
      return '"$nextQuery"';
    }
  }
  final direct = _firstHumanText(<Object?>[
    event['entity_title'],
    event['title'],
    meta['entity_title'],
    meta['title'],
    meta['name'],
    meta['doc_title'],
    meta['sop_title'],
    meta['incident_title'],
    meta['task_title'],
  ]);
  if (direct.isNotEmpty) {
    return direct;
  }
  return _activityPathLabel(l10n, event, meta);
}

String _entityTypeLabel(AppLocalizations l10n, String type) {
  final normalized = type.trim().toLowerCase();
  return switch (normalized) {
    'doc' || 'document' => l10n.text('entity_type_document'),
    'sop' => l10n.text('entity_type_sop'),
    'incident' => l10n.text('entity_type_incident'),
    'task' => l10n.text('entity_type_task'),
    'space' => l10n.text('entity_type_space'),
    'task_comment' => l10n.text('entity_type_task_comment'),
    'incident_action_item' => l10n.text('action_items'),
    'incident_status_update' => l10n.text('incidents'),
    _ => _humanizeToken(normalized),
  };
}

String? _eventRoute(Map<String, dynamic> event, Map<String, dynamic> meta) {
  final spaceId =
      _nonEmptyText(event['space_id']) ?? _nonEmptyText(meta['space_id']);
  final entityType = (_nonEmptyText(event['entity_type']) ?? '').toLowerCase();
  final rawEntityId =
      _nonEmptyText(event['entity_id']) ?? _nonEmptyText(meta['entity_id']);
  final entityId =
      rawEntityId ??
      _nonEmptyText(meta['doc_id']) ??
      _nonEmptyText(meta['sop_id']) ??
      _nonEmptyText(meta['incident_id']) ??
      _nonEmptyText(meta['task_id']);

  switch (entityType) {
    case 'doc':
    case 'document':
      if (spaceId == null || entityId == null) {
        return null;
      }
      return Uri(
        path: '/spaces/$spaceId',
        queryParameters: <String, String>{'docId': entityId},
      ).toString();
    case 'sop':
      if (spaceId == null || entityId == null) {
        return null;
      }
      return Uri(
        path: '/spaces/$spaceId',
        queryParameters: <String, String>{'sopId': entityId},
      ).toString();
    case 'incident':
      if (spaceId == null || entityId == null) {
        return null;
      }
      return Uri(
        path: '/spaces/$spaceId',
        queryParameters: <String, String>{'incidentId': entityId},
      ).toString();
    case 'incident_action_item':
      final incidentId = _nonEmptyText(meta['incident_id']);
      if (spaceId == null || incidentId == null || entityId == null) {
        return null;
      }
      return Uri(
        path: '/spaces/$spaceId',
        queryParameters: <String, String>{
          'incidentId': incidentId,
          'actionItemId': entityId,
        },
      ).toString();
    case 'incident_status_update':
      final incidentId = _nonEmptyText(meta['incident_id']);
      if (spaceId == null || incidentId == null) {
        return null;
      }
      return Uri(
        path: '/spaces/$spaceId',
        queryParameters: <String, String>{'incidentId': incidentId},
      ).toString();
    case 'task':
      final taskId = entityId;
      return Uri(
        path: '/tasks',
        queryParameters: <String, String>{
          'spaceId': ?spaceId,
          'search': ?taskId,
        },
      ).toString();
    case 'task_comment':
      final taskId = _nonEmptyText(meta['task_id']) ?? entityId;
      return Uri(
        path: '/tasks',
        queryParameters: <String, String>{
          'spaceId': ?spaceId,
          'search': ?taskId,
        },
      ).toString();
    default:
      final path = _nonEmptyText(event['path']);
      if (path != null && path.startsWith('/')) {
        return path;
      }
      return null;
  }
}

String _activityPathLabel(
  AppLocalizations l10n,
  Map<String, dynamic> event,
  Map<String, dynamic> meta,
) {
  final rawPath = _nonEmptyText(event['path']);
  if (rawPath == null) {
    return '';
  }
  final uri = Uri.tryParse(rawPath);
  final path = uri?.path ?? rawPath;
  if (path == '/dashboard') {
    return l10n.text('dashboard');
  }
  if (path == '/spaces') {
    return l10n.text('spaces');
  }
  if (path == '/tasks') {
    return l10n.text('tasks');
  }
  if (path == '/analytics') {
    return l10n.text('analytics');
  }
  if (path == '/organization') {
    return l10n.text('organization_access');
  }
  if (path == '/organization/media') {
    return l10n.text('media_manager');
  }
  if (path.startsWith('/organization/backups/')) {
    return l10n.text('snapshot_browser');
  }
  if (path.startsWith('/organization/backups')) {
    return l10n.text('backups');
  }
  if (path.startsWith('/spaces/')) {
    final tab =
        (_nonEmptyText(uri?.queryParameters['tab']) ??
                _nonEmptyText(meta['tab']) ??
                'kb')
            .toLowerCase();
    return switch (tab) {
      'sops' => l10n.text('sops'),
      'incidents' => l10n.text('incidents'),
      _ => l10n.text('kb'),
    };
  }
  return '';
}

String _activityDetailText(
  AppLocalizations l10n,
  Map<String, dynamic> event,
  Map<String, dynamic> meta,
) {
  final direct = _firstHumanText(<Object?>[
    event['detail_text'],
    meta['detail_text'],
  ]);
  if (direct.isNotEmpty) {
    return direct;
  }

  final type = (event['event_type'] ?? '').toString().trim().toLowerCase();
  switch (type) {
    case 'task_created':
    case 'task_updated':
      final parts = <String>[];
      final status = _nonEmptyText(meta['status']);
      final priority = _nonEmptyText(meta['priority']);
      if (status != null) {
        parts.add(_taskStatusLabel(l10n, status));
      }
      if (priority != null) {
        parts.add(_taskPriorityLabel(l10n, priority));
      }
      return parts.join(' • ');
    case 'incident_action_reminder':
      final due = _formatFeedDateValue(
        meta['due_at'] ?? meta['due_at_snapshot'],
      );
      return due.isEmpty ? '' : '${l10n.text('due_prefix')} $due';
    case 'incident_status_update':
      final parts = <String>[];
      final status = _nonEmptyText(meta['status']);
      if (status != null && status.toLowerCase() != 'update') {
        parts.add(status);
      }
      final stream = _nonEmptyText(meta['stream_type']);
      if (stream != null) {
        parts.add(_humanizeToken(stream));
      }
      return parts.join(' • ');
    default:
      return '';
  }
}

String _humanizeToken(String value) {
  final token = value.trim();
  if (token.isEmpty) {
    return '';
  }
  final words = token
      .split(RegExp(r'[_\s-]+'))
      .where((word) => word.isNotEmpty);
  return words
      .map((word) {
        if (word.length <= 2) {
          return word.toUpperCase();
        }
        final lower = word.toLowerCase();
        return '${lower[0].toUpperCase()}${lower.substring(1)}';
      })
      .join(' ')
      .trim();
}

String _firstHumanText(List<Object?> candidates) {
  for (final raw in candidates) {
    final text = (raw ?? '').toString().trim();
    if (text.isEmpty) {
      continue;
    }
    if (_looksLikeId(text)) {
      continue;
    }
    return text;
  }
  return '';
}

bool _looksLikeId(String value) {
  final v = value.trim();
  if (v.isEmpty) {
    return true;
  }
  final uuidLike = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  if (uuidLike.hasMatch(v)) {
    return true;
  }
  final shortHexLike = RegExp(r'^[0-9a-fA-F-]{20,}$');
  return shortHexLike.hasMatch(v);
}

String _formatFeedTimestamp(Map<String, dynamic> event) {
  final raw = (event['ts'] ?? event['created_at'] ?? '').toString().trim();
  final dt = DateTime.tryParse(raw)?.toLocal();
  if (dt == null) {
    return raw.isEmpty ? '-' : raw;
  }
  final y = dt.year;
  final m = dt.month < 10 ? '0${dt.month}' : '${dt.month}';
  final d = dt.day < 10 ? '0${dt.day}' : '${dt.day}';
  final h = dt.hour < 10 ? '0${dt.hour}' : '${dt.hour}';
  final min = dt.minute < 10 ? '0${dt.minute}' : '${dt.minute}';
  return '$y-$m-$d $h:$min';
}

String _formatFeedDateValue(Object? value) {
  final dt = _parseDateTime(value);
  if (dt == null) {
    return '';
  }
  final y = dt.year;
  final m = dt.month < 10 ? '0${dt.month}' : '${dt.month}';
  final d = dt.day < 10 ? '0${dt.day}' : '${dt.day}';
  return '$y-$m-$d';
}

String _taskStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'in_progress' => l10n.text('task_status_in_progress'),
    'blocked' => l10n.text('task_status_blocked'),
    'done' => l10n.text('task_status_done'),
    _ => l10n.text('task_status_todo'),
  };
}

String _taskPriorityLabel(AppLocalizations l10n, String priority) {
  return switch (priority.trim().toLowerCase()) {
    'low' => l10n.text('priority_low'),
    'high' => l10n.text('priority_high'),
    'critical' => l10n.text('priority_critical'),
    _ => l10n.text('priority_medium'),
  };
}

bool _isTaskOverdue(Map<String, dynamic> task) {
  final dueAt = _parseDateTime(task['due_at']);
  if (dueAt == null) {
    return false;
  }
  final now = DateTime.now();
  final currentDay = DateTime(now.year, now.month, now.day);
  final dueDay = DateTime(dueAt.year, dueAt.month, dueAt.day);
  return dueDay.isBefore(currentDay);
}

bool _isTaskDueSoon(Map<String, dynamic> task, {required int withinDays}) {
  final dueAt = _parseDateTime(task['due_at']);
  if (dueAt == null || _isTaskOverdue(task)) {
    return false;
  }
  final now = DateTime.now();
  final currentDay = DateTime(now.year, now.month, now.day);
  final dueDay = DateTime(dueAt.year, dueAt.month, dueAt.day);
  return !dueDay.isBefore(currentDay) &&
      dueDay.isBefore(currentDay.add(Duration(days: withinDays + 1)));
}

List<Map<String, dynamic>> _asJsonList(Object? value) {
  if (value is! List) {
    return const <Map<String, dynamic>>[];
  }
  return value
      .whereType<Map>()
      .map((entry) => entry.cast<String, dynamic>())
      .toList(growable: false);
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return value
      .map((entry) => entry.toString().trim())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
}

String? _nonEmptyText(Object? value) {
  final text = (value ?? '').toString().trim();
  return text.isEmpty ? null : text;
}

DateTime? _parseDateTime(Object? value) {
  if (value is DateTime) {
    return value.toLocal();
  }
  final text = _nonEmptyText(value);
  if (text == null) {
    return null;
  }
  return DateTime.tryParse(text)?.toLocal();
}

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
}

String _formatDue(String raw) {
  final parsed = DateTime.tryParse(raw)?.toLocal();
  if (parsed == null) {
    return raw;
  }
  final month = parsed.month < 10 ? '0${parsed.month}' : '${parsed.month}';
  final day = parsed.day < 10 ? '0${parsed.day}' : '${parsed.day}';
  return '${parsed.year}-$month-$day';
}

class _FeedLine {
  final String title;
  final String subtitle;
  final String? route;

  const _FeedLine({required this.title, required this.subtitle, this.route});
}
