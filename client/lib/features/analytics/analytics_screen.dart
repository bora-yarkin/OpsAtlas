// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Analytics dashboard screen and supporting data loaders.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/navigation/app_route_navigation.dart';
import '../../core/platform/file_download.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/atlas_ui.dart';
import '../spaces/spaces_screen.dart';

typedef _AnalyticsDashboardQuery = ({
  String spaceId,
  int days,
  String granularity,
});

Map<String, dynamic> _asStringDynamicMap(Object? data) {
  if (data is Map) {
    return data.cast<String, dynamic>();
  }
  return <String, dynamic>{};
}

/// Aggregates the analytics datasets needed for the reporting screen.
final analyticsDashboardProvider =
    FutureProvider.family<AnalyticsDashboardData, _AnalyticsDashboardQuery>((
      ref,
      query,
    ) async {
      final api = ref.watch(apiClientProvider);

      Future<List<Map<String, dynamic>>> loadTop(String entityType) async {
        final response = await api.dio.get(
          '/analytics/spaces/${query.spaceId}/top/$entityType',
          queryParameters: <String, Object?>{'days': query.days},
        );
        return (response.data as List)
            .cast<Map>()
            .map((row) => row.cast<String, dynamic>())
            .toList(growable: false);
      }

      Future<List<Map<String, dynamic>>> loadTrend(String eventTypes) async {
        final response = await api.dio.get(
          '/analytics/spaces/${query.spaceId}/trends',
          queryParameters: <String, Object?>{
            'days': query.days,
            'granularity': query.granularity,
            'event_types': eventTypes,
          },
        );
        return (response.data as List)
            .cast<Map>()
            .map((row) => row.cast<String, dynamic>())
            .toList(growable: false);
      }

      final docsFuture = loadTop('doc');
      final sopsFuture = loadTop('sop');
      final incidentsFuture = loadTop('incident');
      final tasksFuture = loadTop('task');
      final searchQualityFuture = api.dio.get(
        '/analytics/spaces/${query.spaceId}/search-quality',
        queryParameters: <String, Object?>{'days': query.days},
      );
      final usageTrendFuture = loadTrend('view,open');
      final searchTrendFuture = loadTrend(
        'search_query_issued,search_results_shown,search_no_result,search_suggestion_accepted',
      );

      final docs = await docsFuture;
      final sops = await sopsFuture;
      final incidents = await incidentsFuture;
      final tasks = await tasksFuture;
      final searchQuality = _asStringDynamicMap(
        await searchQualityFuture.then((r) => r.data),
      );
      final usageTrend = await usageTrendFuture;
      final searchTrend = await searchTrendFuture;

      return AnalyticsDashboardData(
        docs: docs,
        sops: sops,
        incidents: incidents,
        tasks: tasks,
        searchQuality: searchQuality,
        usageTrend: usageTrend,
        searchTrend: searchTrend,
      );
    });

class AnalyticsDashboardData {
  final List<Map<String, dynamic>> docs;
  final List<Map<String, dynamic>> sops;
  final List<Map<String, dynamic>> incidents;
  final List<Map<String, dynamic>> tasks;
  final Map<String, dynamic> searchQuality;
  final List<Map<String, dynamic>> usageTrend;
  final List<Map<String, dynamic>> searchTrend;

  const AnalyticsDashboardData({
    required this.docs,
    required this.sops,
    required this.incidents,
    required this.tasks,
    required this.searchQuality,
    required this.usageTrend,
    required this.searchTrend,
  });
}

/// Privileged reporting screen for content usage and search quality signals.
class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  String? _selectedSpaceId;
  int _selectedWindowDays = 30;
  String _selectedGranularity = 'day';
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final spacesAsync = ref.watch(spacesProvider(''));

    return AtlasPageFrame(
      title: l10n.text('analytics'),
      subtitle: l10n.text('analytics_signal_overview_hint'),
      actions: <Widget>[
        OutlinedButton.icon(
          onPressed: () => ref.invalidate(spacesProvider('')),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.text('refresh')),
        ),
      ],
      child: spacesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AtlasEmptyState(
          icon: Icons.error_outline,
          title: l10n.text('failed_to_load_spaces'),
          subtitle: error.toString(),
        ),
        data: (rawSpaces) {
          final spaces = rawSpaces
              .cast<Map>()
              .map((entry) => entry.cast<String, dynamic>())
              .toList(growable: false);
          if (spaces.isEmpty) {
            return AtlasEmptyState(
              icon: Icons.hub_outlined,
              title: l10n.text('no_spaces_found'),
              action: FilledButton.icon(
                onPressed: () => context.go('/spaces'),
                icon: const Icon(Icons.hub_outlined),
                label: Text(l10n.text('spaces')),
              ),
            );
          }

          final selected = spaces.firstWhere(
            (space) => (space['id'] ?? '').toString() == _selectedSpaceId,
            orElse: () => spaces.first,
          );
          final selectedId = (selected['id'] ?? '').toString();
          final selectedName = (selected['name'] ?? '').toString();
          final query = (
            spaceId: selectedId,
            days: _selectedWindowDays,
            granularity: _selectedGranularity,
          );
          final dashboardAsync = ref.watch(analyticsDashboardProvider(query));

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AtlasPanel(
                title: l10n.text('analytics_signal_overview'),
                subtitle: l10n.text('analytics_signal_overview_hint'),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 720;
                    return Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        SizedBox(
                          width: compact ? constraints.maxWidth : 260,
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedId,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: l10n.text('space'),
                            ),
                            items: <DropdownMenuItem<String>>[
                              for (final space in spaces)
                                DropdownMenuItem<String>(
                                  value: (space['id'] ?? '').toString(),
                                  child: Text((space['name'] ?? '').toString()),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null || value.isEmpty) {
                                return;
                              }
                              setState(() => _selectedSpaceId = value);
                            },
                          ),
                        ),
                        SizedBox(
                          width: compact ? constraints.maxWidth : 180,
                          child: DropdownButtonFormField<int>(
                            initialValue: _selectedWindowDays,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: l10n.text('analytics_data_window'),
                            ),
                            items: <DropdownMenuItem<int>>[
                              DropdownMenuItem<int>(
                                value: 7,
                                child: Text(l10n.text('last_7_days')),
                              ),
                              DropdownMenuItem<int>(
                                value: 30,
                                child: Text(l10n.text('last_30_days')),
                              ),
                              DropdownMenuItem<int>(
                                value: 90,
                                child: Text(l10n.text('last_90_days')),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() => _selectedWindowDays = value);
                            },
                          ),
                        ),
                        SizedBox(
                          width: compact ? constraints.maxWidth : 180,
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedGranularity,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: l10n.text(
                                'analytics_trend_granularity',
                              ),
                            ),
                            items: <DropdownMenuItem<String>>[
                              DropdownMenuItem<String>(
                                value: 'day',
                                child: Text(l10n.text('analytics_daily')),
                              ),
                              DropdownMenuItem<String>(
                                value: 'week',
                                child: Text(l10n.text('analytics_weekly')),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null || value.isEmpty) {
                                return;
                              }
                              setState(() => _selectedGranularity = value);
                            },
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _exporting
                              ? null
                              : () => _exportAnalytics(
                                  context,
                                  spaceId: selectedId,
                                  formatName: 'json',
                                ),
                          icon: const Icon(Icons.data_object_outlined),
                          label: Text(l10n.text('analytics_export_json')),
                        ),
                        OutlinedButton.icon(
                          onPressed: _exporting
                              ? null
                              : () => _exportAnalytics(
                                  context,
                                  spaceId: selectedId,
                                  formatName: 'csv',
                                ),
                          icon: const Icon(Icons.table_view_outlined),
                          label: Text(l10n.text('export_csv')),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: dashboardAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => AtlasEmptyState(
                    icon: Icons.error_outline,
                    title: l10n.text('failed_to_load_analytics'),
                    subtitle: error.toString(),
                  ),
                  data: (dashboard) {
                    final docViews = _totalViews(dashboard.docs);
                    final sopViews = _totalViews(dashboard.sops);
                    final incidentViews = _totalViews(dashboard.incidents);
                    final taskViews = _totalViews(dashboard.tasks);

                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final columns = constraints.maxWidth >= 1100
                                  ? 4
                                  : constraints.maxWidth >= 720
                                  ? 2
                                  : 1;
                              final tiles = <Widget>[
                                AtlasStatTile(
                                  label: l10n.text('top_docs'),
                                  value: docViews.toString(),
                                  icon: Icons.description_outlined,
                                ),
                                AtlasStatTile(
                                  label: l10n.text('top_sops'),
                                  value: sopViews.toString(),
                                  icon: Icons.checklist,
                                ),
                                AtlasStatTile(
                                  label: l10n.text('top_incidents'),
                                  value: incidentViews.toString(),
                                  icon: Icons.report_outlined,
                                ),
                                AtlasStatTile(
                                  label: l10n.text('analytics_top_tasks'),
                                  value: taskViews.toString(),
                                  icon: Icons.task_alt_outlined,
                                ),
                              ];
                              return GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
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
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final wide = constraints.maxWidth >= 960;
                              return Wrap(
                                spacing: AppSpacing.md,
                                runSpacing: AppSpacing.md,
                                children: <Widget>[
                                  SizedBox(
                                    width: wide
                                        ? (constraints.maxWidth -
                                                  AppSpacing.md) /
                                              2
                                        : constraints.maxWidth,
                                    child: _SearchQualityPanel(
                                      searchQuality: dashboard.searchQuality,
                                    ),
                                  ),
                                  SizedBox(
                                    width: wide
                                        ? (constraints.maxWidth -
                                                  AppSpacing.md) /
                                              2
                                        : constraints.maxWidth,
                                    child: _TrendPanel(
                                      title: l10n.text('analytics_usage_trend'),
                                      subtitle: l10n.text(
                                        _selectedGranularity == 'week'
                                            ? 'analytics_weekly'
                                            : 'analytics_daily',
                                      ),
                                      rows: dashboard.usageTrend,
                                    ),
                                  ),
                                  SizedBox(
                                    width: wide
                                        ? (constraints.maxWidth -
                                                  AppSpacing.md) /
                                              2
                                        : constraints.maxWidth,
                                    child: _TrendPanel(
                                      title: l10n.text(
                                        'analytics_search_trend',
                                      ),
                                      subtitle: l10n.text(
                                        _selectedGranularity == 'week'
                                            ? 'analytics_weekly'
                                            : 'analytics_daily',
                                      ),
                                      rows: dashboard.searchTrend,
                                    ),
                                  ),
                                  SizedBox(
                                    width: wide
                                        ? (constraints.maxWidth -
                                                  AppSpacing.md) /
                                              2
                                        : constraints.maxWidth,
                                    child: AtlasPanel(
                                      title: l10n.text('space'),
                                      subtitle: selectedName,
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: OutlinedButton.icon(
                                          onPressed: () => atlasOpenRoute(
                                            context,
                                            '/spaces/$selectedId',
                                          ),
                                          icon: const Icon(
                                            Icons.open_in_new_outlined,
                                          ),
                                          label: Text(
                                            '${l10n.text('open_space_section')}: $selectedName',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _TopEntityPanel(
                            title: l10n.text('top_docs'),
                            rows: dashboard.docs,
                            fallbackPathPrefix: '/spaces/$selectedId?docId=',
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _TopEntityPanel(
                            title: l10n.text('top_sops'),
                            rows: dashboard.sops,
                            fallbackPathPrefix: '/spaces/$selectedId?sopId=',
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _TopEntityPanel(
                            title: l10n.text('top_incidents'),
                            rows: dashboard.incidents,
                            fallbackPathPrefix:
                                '/spaces/$selectedId?incidentId=',
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _TopEntityPanel(
                            title: l10n.text('analytics_top_tasks'),
                            rows: dashboard.tasks,
                            fallbackPathPrefix:
                                '/tasks?spaceId=$selectedId&search=',
                          ),
                        ],
                      ),
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

  Future<void> _exportAnalytics(
    BuildContext context, {
    required String spaceId,
    required String formatName,
  }) async {
    setState(() => _exporting = true);
    final api = ref.read(apiClientProvider);
    try {
      final response = await api.dio.get<List<int>>(
        '/analytics/spaces/$spaceId/export',
        queryParameters: <String, Object?>{
          'format_name': formatName,
          'days': _selectedWindowDays,
        },
        options: Options(responseType: ResponseType.bytes),
      );
      if (!context.mounted) {
        return;
      }
      final bytes = List<int>.from(response.data ?? const <int>[]);
      final contentDisposition =
          (response.headers.value('content-disposition') ?? '').trim();
      final filename =
          _filenameFromContentDisposition(contentDisposition) ??
          'analytics-$spaceId.$formatName';
      await downloadBytes(
        bytes: bytes,
        filename: filename,
        mimeType: formatName == 'json' ? 'application/json' : 'text/csv',
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppLocalizations.of(context).text('analytics_export_failed')}: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  int _totalViews(List<Map<String, dynamic>> rows) {
    var total = 0;
    for (final row in rows) {
      total += int.tryParse((row['views'] ?? '0').toString()) ?? 0;
    }
    return total;
  }

  String? _filenameFromContentDisposition(String raw) {
    if (raw.isEmpty) {
      return null;
    }
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(raw);
    return match?.group(1);
  }
}

class _SearchQualityPanel extends StatelessWidget {
  final Map<String, dynamic> searchQuality;

  const _SearchQualityPanel({required this.searchQuality});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final queryCount = _asInt(searchQuality['query_count']);
    final parseRate = _asDouble(searchQuality['parse_diagnostic_rate']);
    final suggestionRate = _asDouble(
      searchQuality['suggestion_acceptance_rate'],
    );
    final recoveryRate = _asDouble(searchQuality['zero_result_recovery_rate']);
    final refinementDepth = _asDouble(
      searchQuality['average_refinement_depth'],
    );

    return AtlasPanel(
      title: l10n.text('analytics_search_quality'),
      subtitle: l10n.text('analytics_search_quality_hint'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 720 ? 2 : 1;
          final tiles = <Widget>[
            AtlasStatTile(
              label: l10n.text('analytics_search_queries'),
              value: queryCount.toString(),
              icon: Icons.search_outlined,
            ),
            AtlasStatTile(
              label: l10n.text('analytics_parse_diagnostic_rate'),
              value: _formatPercent(parseRate),
              icon: Icons.rule_folder_outlined,
            ),
            AtlasStatTile(
              label: l10n.text('analytics_suggestion_acceptance_rate'),
              value: _formatPercent(suggestionRate),
              icon: Icons.tips_and_updates_outlined,
            ),
            AtlasStatTile(
              label: l10n.text('analytics_zero_result_recovery_rate'),
              value: _formatPercent(recoveryRate),
              icon: Icons.restart_alt_outlined,
            ),
            AtlasStatTile(
              label: l10n.text('analytics_average_refinement_depth'),
              value: refinementDepth.toStringAsFixed(2),
              icon: Icons.timeline_outlined,
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
    );
  }

  int _asInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse((value ?? '').toString()) ?? 0;
  }

  double _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse((value ?? '').toString()) ?? 0;
  }

  String _formatPercent(double value) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }
}

class _TrendPanel extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Map<String, dynamic>> rows;

  const _TrendPanel({
    required this.title,
    required this.subtitle,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final maxCount = rows.fold<int>(
      0,
      (current, row) => current > _count(row) ? current : _count(row),
    );

    return AtlasPanel(
      title: title,
      subtitle: subtitle,
      child: rows.isEmpty
          ? AtlasEmptyState(
              icon: Icons.show_chart_outlined,
              title: l10n.text('no_data'),
            )
          : Column(
              children: rows
                  .map((row) {
                    final count = _count(row);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  (row['bucket_label'] ?? '').toString(),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              Text('$count'),
                            ],
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value: maxCount <= 0 ? 0 : count / maxCount,
                            minHeight: 8,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }

  int _count(Map<String, dynamic> row) {
    final value = row['count'];
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse((value ?? '').toString()) ?? 0;
  }
}

class _TopEntityPanel extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> rows;
  final String fallbackPathPrefix;

  const _TopEntityPanel({
    required this.title,
    required this.rows,
    required this.fallbackPathPrefix,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AtlasPanel(
      title: title,
      subtitle: rows.isEmpty ? '' : '${rows.length}',
      child: rows.isEmpty
          ? AtlasEmptyState(
              icon: Icons.insights_outlined,
              title: l10n.text('no_data'),
            )
          : Column(
              children: rows
                  .take(8)
                  .map((row) {
                    final itemTitle = (row['title'] ?? '').toString().trim();
                    final views = (row['views'] ?? '0').toString();
                    final entityId = (row['entity_id'] ?? '').toString().trim();
                    final path = (row['path'] ?? '').toString().trim();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.trending_up_outlined),
                      title: Text(itemTitle.isEmpty ? '—' : itemTitle),
                      subtitle: Text('$views ${l10n.text('views_suffix')}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        final destination = path.isNotEmpty
                            ? path
                            : '$fallbackPathPrefix$entityId';
                        atlasOpenRoute(context, destination);
                      },
                    );
                  })
                  .toList(growable: false),
            ),
    );
  }
}
