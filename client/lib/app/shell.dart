// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared authenticated application shell for navigation, inbox, and session status.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/api_client.dart';
import '../core/api/auth_store.dart';
import '../core/api/branding.dart';
import '../core/analytics_tracker.dart';
import '../core/api/request_error.dart';
import '../core/command_palette.dart';
import '../core/i18n/app_localizations.dart';
import '../core/navigation/app_route_navigation.dart';
import '../core/search/query_ast.dart';
import '../core/search/search_capabilities.dart';
import '../core/search/search_diagnostics_widget.dart';
import '../core/search/search_help.dart';
import '../core/search/search_validation.dart';
import '../core/theme/theme.dart';
import '../core/theme/theme_controller.dart';
import '../core/widgets/brand_asset_image.dart';

/// Shared authenticated shell for navigation chrome, inbox, and session status.
class AppShell extends ConsumerStatefulWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _desktopSidebarExpandedPrefsKey =
      'shell_desktop_sidebar_expanded';

  Timer? _sessionStatusTimer;
  bool _sessionStatusPolling = false;
  Map<String, dynamic>? _sessionStatus;
  String _lastTrackedRouteKey = '';
  bool _desktopSidebarExpanded = true;
  bool _inboxPanelOpen = false;
  Future<_ShellInboxData>? _inboxFuture;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreDesktopSidebarState());
  }

  @override
  void dispose() {
    _sessionStatusTimer?.cancel();
    _sessionStatusTimer = null;
    super.dispose();
  }

  Future<void> _restoreDesktopSidebarState() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_desktopSidebarExpandedPrefsKey);
    if (!mounted || stored == null) {
      return;
    }
    setState(() {
      _desktopSidebarExpanded = stored;
    });
  }

  Future<void> _setDesktopSidebarExpanded(bool expanded) async {
    if (_desktopSidebarExpanded == expanded) {
      return;
    }
    setState(() {
      _desktopSidebarExpanded = expanded;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopSidebarExpandedPrefsKey, expanded);
  }

  void _openInboxPanel() {
    setState(() {
      _inboxPanelOpen = true;
      _inboxFuture = _loadInbox();
    });
  }

  void _closeInboxPanel() {
    if (!_inboxPanelOpen) {
      return;
    }
    setState(() {
      _inboxPanelOpen = false;
    });
  }

  void _refreshInboxPanel() {
    setState(() {
      _inboxFuture = _loadInbox();
    });
  }

  void _syncSessionStatusPolling(bool loggedIn) {
    if (_sessionStatusPolling == loggedIn) {
      return;
    }
    _sessionStatusPolling = loggedIn;
    _sessionStatusTimer?.cancel();
    _sessionStatusTimer = null;
    if (!loggedIn) {
      _sessionStatus = null;
      return;
    }

    unawaited(_fetchSessionStatus());
    _sessionStatusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_fetchSessionStatus());
    });
  }

  /// Polls `/auth/me/session-status` so the shell can warn before expiry.
  Future<void> _fetchSessionStatus() async {
    if (!mounted || !_sessionStatusPolling) {
      return;
    }
    final api = ref.read(apiClientProvider);
    try {
      final response = await api.dio.get(
        '/auth/me/session-status',
        options: Options(extra: <String, dynamic>{'skip_refresh': true}),
      );
      if (!mounted || !_sessionStatusPolling) {
        return;
      }
      final data = response.data;
      if (response.statusCode == 200 && data is Map) {
        setState(() {
          _sessionStatus = data.cast<String, dynamic>();
        });
        return;
      }
    } on DioException {
      // API interceptor handles auth invalidation when needed.
    } catch (_) {
      // Ignore transient polling failures.
    }
    if (!mounted || !_sessionStatusPolling) {
      return;
    }
    setState(() {
      _sessionStatus = null;
    });
  }

  String? _sanitizeReturnTo(String? raw) {
    final candidate = (raw ?? '').trim();
    if (candidate.isEmpty) {
      return null;
    }
    Uri parsed;
    try {
      parsed = Uri.parse(candidate);
    } catch (_) {
      return null;
    }
    if (parsed.hasScheme || parsed.hasAuthority) {
      return null;
    }
    if (!parsed.path.startsWith('/')) {
      return null;
    }
    if (parsed.path.startsWith('/login')) {
      return null;
    }
    return parsed.toString();
  }

  String _loginLocation({String? returnTo}) {
    final safeReturnTo = _sanitizeReturnTo(returnTo);
    if (safeReturnTo == null) {
      return '/login';
    }
    return Uri(
      path: '/login',
      queryParameters: <String, String>{'return_to': safeReturnTo},
    ).toString();
  }

  Widget? _sessionWarningBanner({required String currentLocation}) {
    final status = _sessionStatus;
    if (status == null) {
      return null;
    }
    final warningActive = status['warning_active'] == true;
    if (!warningActive) {
      return null;
    }
    final rawExpiresIn = status['expires_in_seconds'];
    final expiresInSeconds = rawExpiresIn is num ? rawExpiresIn.toInt() : -1;
    if (expiresInSeconds <= 0) {
      return null;
    }
    final profile = (status['session_profile'] ?? '').toString().trim();
    final l10n = AppLocalizations.of(context);
    final profileLabel = profile == 'remember_device'
        ? l10n.text('remember_this_device')
        : l10n.text('this_browser_only');
    final remainingMinutes = (expiresInSeconds / 60).ceil();
    final minutesText = remainingMinutes <= 1
        ? l10n.text('less_than_1_minute')
        : '$remainingMinutes ${l10n.text('minutes_suffix')}';

    return Builder(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        return Material(
          color: cs.tertiaryContainer.withValues(alpha: 0.82),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.schedule, size: 18, color: cs.onTertiaryContainer),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    l10n
                        .text('session_warning_banner')
                        .replaceAll('{minutes}', minutesText)
                        .replaceAll('{profile}', profileLabel),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                TextButton(
                  onPressed: () => _logout(returnTo: currentLocation),
                  child: Text(l10n.text('sign_in_again')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<_NavSpec> _navItemsForRole({
    required bool canAnalytics,
    required bool canAdmin,
    required AppLocalizations l10n,
  }) {
    return <_NavSpec>[
      _NavSpec(
        icon: Icons.dashboard_outlined,
        label: l10n.text('dashboard'),
        path: '/dashboard',
      ),
      _NavSpec(
        icon: Icons.hub_outlined,
        label: l10n.text('spaces'),
        path: '/spaces',
      ),
      _NavSpec(
        icon: Icons.task_alt_outlined,
        label: l10n.text('tasks'),
        path: '/tasks',
      ),
      if (canAnalytics)
        _NavSpec(
          icon: Icons.analytics_outlined,
          label: l10n.text('analytics'),
          path: '/analytics',
        ),
      if (canAdmin)
        _NavSpec(
          icon: Icons.admin_panel_settings_outlined,
          label: l10n.text('organization_access'),
          path: '/organization',
        ),
    ];
  }

  String _canonicalNavPathForUri(Uri uri) {
    final path = uri.path;
    if (path.startsWith('/account')) return '/account';
    if (path.startsWith('/dashboard')) return '/dashboard';
    if (path == '/spaces' || path.startsWith('/spaces/')) return '/spaces';
    if (path.startsWith('/tasks')) return '/tasks';
    if (path.startsWith('/analytics')) return '/analytics';
    if (path.startsWith('/organization')) return '/organization';
    return '/dashboard';
  }

  int _indexForUri(Uri uri, List<_NavSpec> navItems, {int fallback = 0}) {
    final canonical = _canonicalNavPathForUri(uri);
    final idx = navItems.indexWhere((item) => item.path == canonical);
    return idx >= 0 ? idx : fallback;
  }

  String _mobileTitleForUri(Uri uri, AppLocalizations l10n) {
    final path = uri.path;
    if (path.startsWith('/spaces/')) {
      return switch ((uri.queryParameters['tab'] ?? 'kb')
          .trim()
          .toLowerCase()) {
        'sops' => l10n.text('sops'),
        'incidents' => l10n.text('incidents'),
        _ => l10n.text('kb'),
      };
    }
    if (path == '/spaces') {
      return l10n.text('spaces');
    }
    if (path.startsWith('/tasks')) {
      return l10n.text('tasks');
    }
    if (path.startsWith('/analytics')) {
      return l10n.text('analytics');
    }
    if (path.startsWith('/organization/media')) {
      return l10n.text('media_manager');
    }
    if (path.startsWith('/organization/backups/')) {
      return l10n.text('snapshot_browser');
    }
    if (path.startsWith('/organization/backups')) {
      return l10n.text('backups');
    }
    if (path.startsWith('/organization')) {
      return l10n.text('organization_access');
    }
    if (path.startsWith('/account')) {
      return l10n.text('account');
    }
    return l10n.text('dashboard');
  }

  Future<void> _goForNav(_NavSpec item) async {
    if (!mounted) return;
    _closeInboxPanel();
    context.go(item.path);
  }

  Future<void> _logout({String? returnTo}) async {
    final api = ref.read(apiClientProvider);
    final auth = ref.read(authStoreProvider);
    try {
      await api.dio.post(
        '/auth/logout',
        options: Options(extra: <String, dynamic>{'skip_refresh': true}),
      );
    } on DioException {
      // Always clear local session, even if backend logout fails.
    } catch (_) {
      // Always clear local session, even if backend logout fails.
    }
    await auth.clearSession();
    if (!mounted) return;
    context.go(_loginLocation(returnTo: returnTo));
  }

  void _openAccount() {
    _closeInboxPanel();
    context.go('/account');
  }

  void _openDashboard() {
    _closeInboxPanel();
    context.go('/dashboard');
  }

  void _openRoute(String route) {
    _closeInboxPanel();
    atlasOpenRoute(context, route);
  }

  Future<_ShellInboxData> _loadInbox() async {
    // The shell inbox is intentionally cross-feature: it surfaces the three
    // operational signals users most often need regardless of current route.
    final api = ref.read(apiClientProvider);
    final prefsResponse = await api.dio.get('/auth/me/dashboard-preferences');
    final spacesResponse = await api.dio.get('/spaces');

    final prefs = prefsResponse.data is Map
        ? (prefsResponse.data as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final spaces = _shellAsJsonList(spacesResponse.data);
    final preferredSpaceId = _shellNonEmptyText(prefs['selected_space_id']);
    final selectedSpace = spaces.firstWhere(
      (space) => (space['id'] ?? '').toString().trim() == preferredSpaceId,
      orElse: () => spaces.isEmpty ? const <String, dynamic>{} : spaces.first,
    );
    final selectedSpaceId = _shellNonEmptyText(selectedSpace['id']);
    final selectedSpaceLabel =
        _shellNonEmptyText(selectedSpace['name']) ??
        _shellNonEmptyText(selectedSpace['slug']) ??
        selectedSpaceId;

    if (selectedSpaceId == null) {
      return const _ShellInboxData();
    }

    final responses = await Future.wait<dynamic>(<Future<dynamic>>[
      api.dio.get(
        '/kb/spaces/$selectedSpaceId/mentions',
        queryParameters: const <String, dynamic>{
          'unread_only': true,
          'max_age_days': 30,
        },
      ),
      api.dio.get(
        '/analytics/feed',
        queryParameters: <String, dynamic>{
          'limit': 30,
          'space_id': selectedSpaceId,
        },
      ),
      api.dio.get(
        '/sop/spaces/$selectedSpaceId/sops',
        queryParameters: const <String, dynamic>{
          'published_only': false,
          'include_archived': false,
        },
      ),
    ]);

    final mentions = _shellAsJsonList(responses[0].data);
    final reminders = _shellAsJsonList(responses[1].data)
        .where(
          (event) =>
              (event['event_type'] ?? '').toString().trim().toLowerCase() ==
              'incident_action_reminder',
        )
        .toList(growable: false);
    final approvals = _shellAsJsonList(
      responses[2].data,
    ).where((sop) => sop['pending_approval'] == true).toList(growable: false);

    return _ShellInboxData(
      selectedSpaceId: selectedSpaceId,
      selectedSpaceLabel: selectedSpaceLabel,
      mentions: mentions,
      reminders: reminders,
      approvals: approvals,
    );
  }

  List<Widget> _buildInboxSections(
    BuildContext context,
    AppLocalizations l10n,
    _ShellInboxData data,
  ) {
    final sections = <Widget>[];
    if (data.mentions.isNotEmpty) {
      sections.add(
        _buildInboxSection(
          context,
          title: l10n.text('mention_inbox'),
          icon: Icons.mark_email_unread_outlined,
          children: data.mentions
              .map((mention) {
                final route = _mentionRoute(mention);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.mark_email_unread_outlined),
                  title: Text(
                    _shellNonEmptyText(mention['doc_title']) ??
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
    if (data.approvals.isNotEmpty) {
      sections.add(
        _buildInboxSection(
          context,
          title: l10n.text('pending_approvals'),
          icon: Icons.approval_outlined,
          children: data.approvals
              .map((sop) {
                final route = _sopRoute(
                  data.selectedSpaceId,
                  (sop['id'] ?? '').toString(),
                );
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.approval_outlined),
                  title: Text(
                    _shellNonEmptyText(sop['title']) ??
                        _shellNonEmptyText(sop['slug']) ??
                        l10n.text('untitled'),
                  ),
                  subtitle: Text(l10n.text('pending_approval_before_publish')),
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
    if (data.reminders.isNotEmpty) {
      sections.add(
        _buildInboxSection(
          context,
          title: l10n.text('reminder_history'),
          icon: Icons.notifications_active_outlined,
          children: data.reminders
              .map((event) {
                final route = _eventRoute(event);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: Text(_eventTitle(l10n, event)),
                  subtitle: Text(
                    _eventSubtitle(event),
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
    return sections;
  }

  Widget _buildInboxPanel(AppLocalizations l10n, {required bool desktop}) {
    // Desktop uses a docked panel feel, while mobile treats the inbox more like
    // a full-screen overlay destination with back-swipe support.
    final future = _inboxFuture;
    final panel = Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Column(
        children: <Widget>[
          if (desktop)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.72),
                  ),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.sm,
                    AppSpacing.sm,
                    AppSpacing.sm,
                    AppSpacing.sm,
                  ),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: _closeInboxPanel,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: Text(
                          l10n.text('notifications'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.text('refresh'),
                        onPressed: _refreshInboxPanel,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: future == null
                ? const SizedBox.shrink()
                : FutureBuilder<_ShellInboxData>(
                    future: future,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        final error =
                            snapshot.error ?? StateError(l10n.text('no_data'));
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.lg),
                            child: Text(
                              requestErrorMessage(error, context: context),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                      final data = snapshot.data ?? const _ShellInboxData();
                      final sections = _buildInboxSections(context, l10n, data);
                      return Scrollbar(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.md,
                            AppSpacing.lg,
                            AppSpacing.lg,
                          ),
                          children: <Widget>[
                            if ((data.selectedSpaceLabel ?? '')
                                .isNotEmpty) ...<Widget>[
                              Text(
                                '${l10n.text('space')}: ${data.selectedSpaceLabel}',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                            ],
                            if (sections.isEmpty)
                              SizedBox(
                                height: desktop ? 180 : 240,
                                child: Center(
                                  child: Text(
                                    l10n.text('no_activity_events_yet'),
                                  ),
                                ),
                              )
                            else
                              ...sections,
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
    return _ShellInboxOverlay(
      open: _inboxPanelOpen,
      desktop: desktop,
      onDismiss: _closeInboxPanel,
      child: desktop
          ? panel
          : AtlasEdgeBackGesture(onBack: _closeInboxPanel, child: panel),
    );
  }

  Widget _buildInboxSection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18),
              const SizedBox(width: AppSpacing.xs),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          ...children,
        ],
      ),
    );
  }

  String? _mentionRoute(Map<String, dynamic> mention) {
    final spaceId = _shellNonEmptyText(mention['space_id']);
    final docId = _shellNonEmptyText(mention['doc_id']);
    if (spaceId == null || docId == null) {
      return null;
    }
    return Uri(
      path: '/spaces/$spaceId',
      queryParameters: <String, String>{'docId': docId},
    ).toString();
  }

  String? _sopRoute(String? spaceId, String sopId) {
    final cleanSpaceId = (spaceId ?? '').trim();
    final cleanSopId = sopId.trim();
    if (cleanSpaceId.isEmpty || cleanSopId.isEmpty) {
      return null;
    }
    return Uri(
      path: '/spaces/$cleanSpaceId',
      queryParameters: <String, String>{'sopId': cleanSopId},
    ).toString();
  }

  String _eventTitle(AppLocalizations l10n, Map<String, dynamic> event) {
    final meta = _shellAsJsonMap(event['meta']);
    return _shellNonEmptyText(meta['incident_title']) ??
        _shellNonEmptyText(event['entity_title']) ??
        _shellNonEmptyText(meta['title']) ??
        l10n.text('reminder');
  }

  String _eventSubtitle(Map<String, dynamic> event) {
    final meta = _shellAsJsonMap(event['meta']);
    final parts = <String>[];
    final createdAt = _shellNonEmptyText(event['created_at']);
    final message = _shellNonEmptyText(meta['message']);
    if (createdAt != null) {
      parts.add(createdAt);
    }
    if (message != null) {
      parts.add(message);
    }
    return parts.isEmpty ? '' : parts.join(' • ');
  }

  String? _eventRoute(Map<String, dynamic> event) {
    final meta = _shellAsJsonMap(event['meta']);
    final path = _shellNonEmptyText(event['path']);
    if (path != null && path.startsWith('/')) {
      return path;
    }

    final spaceId =
        _shellNonEmptyText(event['space_id']) ??
        _shellNonEmptyText(meta['space_id']);
    final entityType = (_shellNonEmptyText(event['entity_type']) ?? '')
        .toLowerCase();
    final entityId =
        _shellNonEmptyText(event['entity_id']) ??
        _shellNonEmptyText(meta['entity_id']) ??
        _shellNonEmptyText(meta['doc_id']) ??
        _shellNonEmptyText(meta['sop_id']) ??
        _shellNonEmptyText(meta['incident_id']) ??
        _shellNonEmptyText(meta['task_id']);

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
        return _sopRoute(spaceId, entityId ?? '');
      case 'incident':
        if (spaceId == null || entityId == null) {
          return null;
        }
        return Uri(
          path: '/spaces/$spaceId',
          queryParameters: <String, String>{'incidentId': entityId},
        ).toString();
      case 'incident_action_item':
        final incidentId = _shellNonEmptyText(meta['incident_id']);
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
      case 'task':
      case 'task_comment':
        final queryParameters = <String, String>{};
        if (spaceId != null) {
          queryParameters['spaceId'] = spaceId;
        }
        if (entityId != null) {
          queryParameters['search'] = entityId;
        }
        return Uri(path: '/tasks', queryParameters: queryParameters).toString();
      default:
        return null;
    }
  }

  List<ContextCommand> _navCommands(List<_NavSpec> navItems) {
    return navItems
        .map(
          (item) => ContextCommand(
            label: item.label,
            subtitle: item.path,
            icon: item.icon,
            action: () {
              if (!mounted) return;
              context.go(item.path);
            },
          ),
        )
        .toList(growable: false);
  }

  Future<void> _openQuickNav(
    List<ContextCommand> commands,
    AppLocalizations l10n,
  ) async {
    final queryCtrl = TextEditingController();
    final queryFocusNode = FocusNode();

    String encodeSearchTokenValue(String value) {
      return value.contains(' ') ? '"$value"' : value;
    }

    String? normalizeQuickNavCategory(String raw) {
      final key = raw.trim().toLowerCase();
      return switch (key) {
        'label' || 'name' || 'title' => 'label',
        'path' || 'route' || 'subtitle' => 'path',
        _ => null,
      };
    }

    List<({String label, String tokenText, bool appendSpace, String? subtitle})>
    quickNavValueSuggestions(String category, String partialLower) {
      final values = commands
          .map(
            (command) => category == 'label'
                ? command.label.trim()
                : command.subtitle.trim(),
          )
          .where((value) => value.isNotEmpty)
          .toSet()
          .where((value) => value.toLowerCase().contains(partialLower))
          .take(8)
          .toList(growable: false);

      return values
          .map(
            (value) => (
              label: value,
              tokenText: '@$category:${encodeSearchTokenValue(value)}',
              appendSpace: true,
              subtitle: null,
            ),
          )
          .toList(growable: false);
    }

    List<({String label, String tokenText, bool appendSpace, String? subtitle})>
    quickNavSuggestions() {
      final context = parseAtTokenSuggestionContext(queryCtrl.text);
      if (context == null) {
        return const <
          ({String label, String tokenText, bool appendSpace, String? subtitle})
        >[];
      }

      if (!context.hasValueSeparator) {
        final category = normalizeQuickNavCategory(context.fieldLower);
        if (context.hasTrailingWhitespace && category != null) {
          return quickNavValueSuggestions(category, '');
        }

        final partial = context.partialFieldLower;
        final categories = <({String token, String label})>[
          (token: 'label', label: l10n.text('name')),
          (token: 'path', label: l10n.text('path')),
        ];
        return categories
            .where((row) {
              if (partial.isEmpty) return true;
              return row.token.contains(partial) ||
                  row.label.toLowerCase().contains(partial);
            })
            .map(
              (row) => (
                label: '@${row.token} - ${row.label}',
                tokenText: '@${row.token}:',
                appendSpace: false,
                subtitle: l10n.text('search'),
              ),
            )
            .toList(growable: false);
      }

      final category = normalizeQuickNavCategory(context.fieldLower);
      if (category == null) {
        return const <
          ({String label, String tokenText, bool appendSpace, String? subtitle})
        >[];
      }
      return quickNavValueSuggestions(category, context.partialValueLower);
    }

    final selected = await showDialog<ContextCommand>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setLocalState) {
            final ast = parseSearchQueryAst(queryCtrl.text);
            final searchDiagnostics = validateSearchQueryAst(
              ast,
              capability: shellQuickNavSearchCapability,
            ).diagnostics;
            final structuredTokens = ast.fieldTokens
                .where((token) => token.hasValue)
                .toList(growable: false);

            final suggestions = quickNavSuggestions();

            bool matches(ContextCommand item) {
              final label = item.label.toLowerCase();
              final subtitle = item.subtitle.toLowerCase();
              final text = '$label $subtitle';

              return evaluateSearchExpression(
                ast.expression,
                matchesField: (token) {
                  final category = normalizeQuickNavCategory(
                    token.normalizedField,
                  );
                  if (category == null || !token.hasValue) {
                    return false;
                  }

                  final value = token.normalizedValue;
                  final baseMatch = switch (category) {
                    'label' => label.contains(value),
                    'path' => subtitle.contains(value),
                    _ => false,
                  };
                  return token.isNegated ? !baseMatch : baseMatch;
                },
                matchesText: (token) => text.contains(token.normalizedValue),
              );
            }

            final filtered = commands.where(matches).toList(growable: false);
            return Dialog(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 520,
                  maxHeight: 520,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: queryCtrl,
                              focusNode: queryFocusNode,
                              autofocus: true,
                              onChanged: (_) => setLocalState(() {}),
                              decoration: InputDecoration(
                                labelText: l10n.text('search'),
                                hintText: structuredSearchHint(
                                  l10n: l10n,
                                  capability: shellQuickNavSearchCapability,
                                ),
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: queryCtrl.text.trim().isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: l10n.text('clear_search'),
                                        onPressed: () => setLocalState(() {
                                          queryCtrl.clear();
                                          queryFocusNode.requestFocus();
                                        }),
                                        icon: const Icon(Icons.close),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          SearchHowToButton(
                            capability: shellQuickNavSearchCapability,
                          ),
                        ],
                      ),
                      if (structuredTokens.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: <Widget>[
                            for (final token in structuredTokens)
                              InputChip(
                                label: Text(token.toChipLabel()),
                                onDeleted: () => setLocalState(() {
                                  final nextText = removeSearchRangeFromQuery(
                                    queryCtrl.text,
                                    start: token.start,
                                    end: token.end,
                                  );
                                  queryCtrl.value = TextEditingValue(
                                    text: nextText,
                                    selection: TextSelection.collapsed(
                                      offset: nextText.length,
                                    ),
                                  );
                                  queryFocusNode.requestFocus();
                                }),
                              ),
                          ],
                        ),
                      ],
                      if (suggestions.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.xs),
                        Material(
                          color: Theme.of(
                            dialogContext,
                          ).colorScheme.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: Theme.of(
                                dialogContext,
                              ).colorScheme.outlineVariant,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 180),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: suggestions.length,
                              itemBuilder: (context, index) {
                                final suggestion = suggestions[index];
                                return ListTile(
                                  dense: true,
                                  title: Text(suggestion.label),
                                  subtitle: suggestion.subtitle == null
                                      ? null
                                      : Text(suggestion.subtitle!),
                                  onTap: () => setLocalState(() {
                                    final nextText = applyAtTokenSuggestion(
                                      raw: queryCtrl.text,
                                      suggestionToken: suggestion.tokenText,
                                      appendSpace: suggestion.appendSpace,
                                    );
                                    queryCtrl.value = TextEditingValue(
                                      text: nextText,
                                      selection: TextSelection.collapsed(
                                        offset: nextText.length,
                                      ),
                                    );
                                    queryFocusNode.requestFocus();
                                  }),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                      if (searchDiagnostics.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.xs),
                        SearchDiagnosticsList(diagnostics: searchDiagnostics),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(l10n.text('no_commands_match')),
                              )
                            : ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final item = filtered[index];
                                  return ListTile(
                                    leading: Icon(item.icon),
                                    title: Text(item.label),
                                    subtitle: Text(
                                      item.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => Navigator.pop(context, item),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    queryFocusNode.dispose();
    queryCtrl.dispose();
    if (selected == null || !mounted) return;
    selected.action();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStoreProvider);
    _syncSessionStatusPolling(auth.isLoggedIn);
    final branding = ref.watch(brandingProvider).asData?.value;
    final l10n = AppLocalizations.of(context);
    final navItems = _navItemsForRole(
      canAnalytics: auth.canViewAnalytics,
      canAdmin: auth.isAdmin,
      l10n: l10n,
    );
    final registeredCommands = ref.watch(commandPaletteRegistryProvider);
    final paletteCommands = <ContextCommand>[
      ...registeredCommands,
      ..._navCommands(navItems),
    ];
    final uri = GoRouterState.of(context).uri;
    if (!auth.isLoggedIn) {
      _lastTrackedRouteKey = '';
    } else {
      final routeKey = uri.toString();
      if (_lastTrackedRouteKey != routeKey) {
        _lastTrackedRouteKey = routeKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          trackRouteView(ref, uri: uri);
        });
      }
    }
    final sessionWarningBanner = _sessionWarningBanner(
      currentLocation: uri.toString(),
    );
    final selectedIndex = _indexForUri(uri, navItems, fallback: -1);
    final selectedPath = _canonicalNavPathForUri(uri);
    final accountSelected = selectedPath == '/account';
    final mobileTitle = _mobileTitleForUri(uri, l10n);
    final canNavigatorPop = Navigator.of(context).canPop();
    final mobileBackFallbackRoute = switch (uri.path) {
      final path when path.startsWith('/spaces/') => '/spaces',
      final path when path.startsWith('/organization/backups/') =>
        '/organization/backups',
      '/organization/backups' || '/organization/media' => '/organization',
      _ => selectedPath,
    };
    final mobileShowsBack =
        canNavigatorPop ||
        atlasUsesStackNavigation(uri.toString()) ||
        uri.path == '/organization/media' ||
        uri.path == '/organization/backups' ||
        uri.path.startsWith('/organization/backups/');

    final themeCtrl = ref.watch(themeControllerProvider);
    final isDark = themeCtrl.isDarkFor(Theme.of(context).brightness);
    final brandName = (branding?.companyName ?? l10n.text('company_platform'))
        .trim();
    final logoUrl =
        ((isDark ? branding?.darkLogoUrl : branding?.lightLogoUrl) ??
                branding?.logoUrl ??
                (isDark ? branding?.lightLogoUrl : branding?.darkLogoUrl) ??
                '')
            .trim();

    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= 980;
    final inboxPanel = _buildInboxPanel(l10n, desktop: isDesktop);
    final shellChild = CommandPaletteScope(
      commands: const <ContextCommand>[],
      child: widget.child,
    );

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            const _ShellIntent.openCommands(),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            const _ShellIntent.openCommands(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ShellIntent: CallbackAction<_ShellIntent>(
            onInvoke: (intent) {
              _openQuickNav(paletteCommands, l10n);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: isDesktop
              ? _DesktopShell(
                  items: navItems,
                  selectedIndex: selectedIndex,
                  onSelect: (index) => _goForNav(navItems[index]),
                  sidebarExpanded: _desktopSidebarExpanded,
                  onToggleSidebar: () =>
                      _setDesktopSidebarExpanded(!_desktopSidebarExpanded),
                  onOpenCommands: () => _openQuickNav(paletteCommands, l10n),
                  onOpenInbox: _openInboxPanel,
                  onOpenBrand: _openDashboard,
                  onOpenAccount: _openAccount,
                  onToggleTheme: () => ref
                      .read(themeControllerProvider)
                      .toggleLightDarkFor(Theme.of(context).brightness),
                  onLogout: _logout,
                  darkMode: isDark,
                  brandName: brandName,
                  logoUrl: logoUrl.isEmpty ? null : logoUrl,
                  accountSelected: accountSelected,
                  labels: _ShellLabels(
                    command: l10n.text('search'),
                    notifications: l10n.text('notifications'),
                    account: l10n.text('account'),
                    logout: l10n.text('logout'),
                    refresh: l10n.text('refresh'),
                    darkMode: l10n.text('dark_mode'),
                    lightMode: l10n.text('light_mode'),
                    more: l10n.text('more'),
                  ),
                  sessionWarningBanner: sessionWarningBanner,
                  inboxPanel: inboxPanel,
                  child: shellChild,
                )
              : _MobileShell(
                  items: navItems,
                  selectedPath: selectedPath,
                  onSelectDrawerItem: (item) => _goForNav(item),
                  onOpenBrand: _openDashboard,
                  notificationsOpen: _inboxPanelOpen,
                  onCloseNotifications: _closeInboxPanel,
                  onRefreshNotifications: _refreshInboxPanel,
                  onOpenCommands: () => _openQuickNav(paletteCommands, l10n),
                  onOpenInbox: _openInboxPanel,
                  onOpenAccount: _openAccount,
                  showBackButton: mobileShowsBack,
                  onNavigateBack: () =>
                      atlasPopOrGo(context, mobileBackFallbackRoute),
                  onToggleTheme: () => ref
                      .read(themeControllerProvider)
                      .toggleLightDarkFor(Theme.of(context).brightness),
                  onLogout: _logout,
                  darkMode: isDark,
                  accountSelected: accountSelected,
                  title: mobileTitle,
                  notificationsTitle: l10n.text('notifications'),
                  brandName: brandName,
                  logoUrl: logoUrl.isEmpty ? null : logoUrl,
                  labels: _ShellLabels(
                    command: l10n.text('search'),
                    notifications: l10n.text('notifications'),
                    account: l10n.text('account'),
                    logout: l10n.text('logout'),
                    refresh: l10n.text('refresh'),
                    darkMode: l10n.text('dark_mode'),
                    lightMode: l10n.text('light_mode'),
                    more: l10n.text('more'),
                  ),
                  sessionWarningBanner: sessionWarningBanner,
                  inboxPanel: inboxPanel,
                  child: shellChild,
                ),
        ),
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  final Widget child;
  final Widget? sessionWarningBanner;
  final Widget inboxPanel;
  final List<_NavSpec> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool sidebarExpanded;
  final VoidCallback onToggleSidebar;
  final VoidCallback onOpenCommands;
  final VoidCallback onOpenInbox;
  final VoidCallback onOpenBrand;
  final VoidCallback onOpenAccount;
  final VoidCallback onToggleTheme;
  final VoidCallback onLogout;
  final bool darkMode;
  final String brandName;
  final String? logoUrl;
  final bool accountSelected;
  final _ShellLabels labels;

  const _DesktopShell({
    required this.child,
    this.sessionWarningBanner,
    required this.inboxPanel,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.sidebarExpanded,
    required this.onToggleSidebar,
    required this.onOpenCommands,
    required this.onOpenInbox,
    required this.onOpenBrand,
    required this.onOpenAccount,
    required this.onToggleTheme,
    required this.onLogout,
    required this.darkMode,
    required this.brandName,
    required this.logoUrl,
    required this.accountSelected,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final media = MediaQuery.sizeOf(context);
    final shellPadding = media.height < 840 ? AppSpacing.md : AppSpacing.lg;
    final contentRadius = media.height < 840 ? 22.0 : 26.0;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                cs.surface,
                cs.surfaceContainerLowest,
                cs.surface,
              ],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(shellPadding),
              child: Row(
                children: <Widget>[
                  _DesktopSidebar(
                    items: items,
                    selectedIndex: selectedIndex,
                    onSelect: onSelect,
                    expanded: sidebarExpanded,
                    onToggleExpanded: onToggleSidebar,
                    onOpenCommands: onOpenCommands,
                    onOpenInbox: onOpenInbox,
                    onOpenBrand: onOpenBrand,
                    onOpenAccount: onOpenAccount,
                    onToggleTheme: onToggleTheme,
                    onLogout: onLogout,
                    darkMode: darkMode,
                    brandName: brandName,
                    logoUrl: logoUrl,
                    accountSelected: accountSelected,
                    labels: labels,
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Material(
                      color: cs.surfaceContainerLowest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(contentRadius),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: <Widget>[
                          Positioned.fill(
                            child: sessionWarningBanner == null
                                ? child
                                : Column(
                                    children: <Widget>[
                                      sessionWarningBanner!,
                                      Expanded(child: child),
                                    ],
                                  ),
                          ),
                          Positioned.fill(child: inboxPanel),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  final List<_NavSpec> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onOpenCommands;
  final VoidCallback onOpenInbox;
  final VoidCallback onOpenBrand;
  final VoidCallback onOpenAccount;
  final VoidCallback onToggleTheme;
  final VoidCallback onLogout;
  final bool darkMode;
  final String brandName;
  final String? logoUrl;
  final bool accountSelected;
  final _ShellLabels labels;

  const _DesktopSidebar({
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpenCommands,
    required this.onOpenInbox,
    required this.onOpenBrand,
    required this.onOpenAccount,
    required this.onToggleTheme,
    required this.onLogout,
    required this.darkMode,
    required this.brandName,
    required this.logoUrl,
    required this.accountSelected,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasLogo = logoUrl != null && logoUrl!.isNotEmpty;

    return AnimatedContainer(
      duration: AppMotion.standard,
      curve: Curves.easeOutCubic,
      width: expanded ? 272 : 92,
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.84)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            children: <Widget>[
              if (expanded)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _SidebarBrandButton(
                        brandName: brandName,
                        logoUrl: hasLogo ? logoUrl : null,
                        expanded: true,
                        onTap: onOpenBrand,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    IconButton(
                      onPressed: onToggleExpanded,
                      icon: const Icon(Icons.keyboard_double_arrow_left),
                    ),
                  ],
                )
              else
                Column(
                  children: <Widget>[
                    _SidebarBrandButton(
                      brandName: brandName,
                      logoUrl: hasLogo ? logoUrl : null,
                      expanded: false,
                      onTap: onOpenBrand,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    IconButton(
                      onPressed: onToggleExpanded,
                      icon: const Icon(Icons.keyboard_double_arrow_right),
                    ),
                  ],
                ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _SidebarNavButton(
                      selected: selectedIndex == index,
                      expanded: expanded,
                      icon: item.icon,
                      label: item.label,
                      onTap: () => onSelect(index),
                    );
                  },
                ),
              ),
              Divider(
                color: cs.outlineVariant.withValues(alpha: 0.4),
                height: 1,
              ),
              const SizedBox(height: AppSpacing.sm),
              _SidebarActionButton(
                expanded: expanded,
                icon: Icons.search,
                label: labels.command,
                onTap: onOpenCommands,
              ),
              const SizedBox(height: AppSpacing.xs),
              _SidebarActionButton(
                expanded: expanded,
                icon: Icons.notifications_outlined,
                label: labels.notifications,
                onTap: onOpenInbox,
              ),
              const SizedBox(height: AppSpacing.xs),
              _SidebarActionButton(
                expanded: expanded,
                icon: Icons.person_outline,
                label: labels.account,
                onTap: onOpenAccount,
                selected: accountSelected,
              ),
              const SizedBox(height: AppSpacing.xs),
              _SidebarActionButton(
                expanded: expanded,
                icon: darkMode ? Icons.light_mode : Icons.dark_mode,
                label: darkMode ? labels.lightMode : labels.darkMode,
                onTap: onToggleTheme,
              ),
              const SizedBox(height: AppSpacing.xs),
              _SidebarActionButton(
                expanded: expanded,
                icon: Icons.logout,
                label: labels.logout,
                onTap: onLogout,
                tone: cs.error,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarBrandButton extends StatelessWidget {
  final String brandName;
  final String? logoUrl;
  final bool expanded;
  final VoidCallback onTap;

  const _SidebarBrandButton({
    required this.brandName,
    required this.logoUrl,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brandMark = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: BrandAssetImage(
        url: logoUrl,
        fit: BoxFit.contain,
        fallback: Icon(Icons.apartment_outlined, color: cs.onSurface),
      ),
    );
    return Tooltip(
      message: brandName,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Ink(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: expanded ? AppSpacing.sm : 0,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showExpandedBrand =
                    expanded && constraints.maxWidth >= 140;
                if (!showExpandedBrand) {
                  return Center(child: brandMark);
                }
                return Row(
                  children: <Widget>[
                    brandMark,
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        brandName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarNavButton extends StatelessWidget {
  final bool selected;
  final bool expanded;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SidebarNavButton({
    required this.selected,
    required this.expanded,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.primary : cs.onSurface;

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Ink(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: expanded ? AppSpacing.sm : 0,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? cs.primary.withValues(alpha: 0.14)
                    : cs.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected
                      ? cs.primary.withValues(alpha: 0.42)
                      : cs.outlineVariant.withValues(alpha: 0.65),
                ),
              ),
              child: Row(
                mainAxisAlignment: expanded
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.center,
                children: <Widget>[
                  Icon(icon, color: fg, size: 20),
                  if (expanded) ...<Widget>[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarActionButton extends StatelessWidget {
  final bool expanded;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tone;
  final bool selected;

  const _SidebarActionButton({
    required this.expanded,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tone,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final effectiveTone = tone ?? (selected ? cs.primary : cs.onSurface);

    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Ink(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: expanded ? AppSpacing.sm : 0,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.14)
                  : cs.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? cs.primary.withValues(alpha: 0.4)
                    : cs.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 18, color: effectiveTone),
                if (expanded) ...<Widget>[
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: effectiveTone),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileShell extends StatelessWidget {
  final Widget child;
  final Widget? sessionWarningBanner;
  final Widget inboxPanel;
  final List<_NavSpec> items;
  final String selectedPath;
  final bool accountSelected;
  final ValueChanged<_NavSpec> onSelectDrawerItem;
  final VoidCallback onOpenBrand;
  final bool notificationsOpen;
  final VoidCallback onCloseNotifications;
  final VoidCallback onRefreshNotifications;
  final bool showBackButton;
  final VoidCallback onNavigateBack;
  final VoidCallback onOpenCommands;
  final VoidCallback onOpenInbox;
  final VoidCallback onOpenAccount;
  final VoidCallback onToggleTheme;
  final VoidCallback onLogout;
  final bool darkMode;
  final String title;
  final String notificationsTitle;
  final String brandName;
  final String? logoUrl;
  final _ShellLabels labels;

  const _MobileShell({
    required this.child,
    this.sessionWarningBanner,
    required this.inboxPanel,
    required this.items,
    required this.selectedPath,
    required this.accountSelected,
    required this.onSelectDrawerItem,
    required this.onOpenBrand,
    required this.notificationsOpen,
    required this.onCloseNotifications,
    required this.onRefreshNotifications,
    required this.showBackButton,
    required this.onNavigateBack,
    required this.onOpenCommands,
    required this.onOpenInbox,
    required this.onOpenAccount,
    required this.onToggleTheme,
    required this.onLogout,
    required this.darkMode,
    required this.title,
    required this.notificationsTitle,
    required this.brandName,
    required this.logoUrl,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasLogo = logoUrl != null && logoUrl!.isNotEmpty;
    final drawerWidth = (MediaQuery.sizeOf(context).width * 0.88)
        .clamp(280.0, 320.0)
        .toDouble();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        leading: Builder(
          builder: (menuContext) {
            if (notificationsOpen) {
              return IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onCloseNotifications,
                icon: const Icon(Icons.arrow_back),
              );
            }
            if (showBackButton) {
              return IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onNavigateBack,
                icon: const Icon(Icons.arrow_back),
              );
            }
            return IconButton(
              tooltip: labels.more,
              onPressed: () => Scaffold.of(menuContext).openDrawer(),
              icon: const Icon(Icons.menu),
            );
          },
        ),
        title: Text(
          notificationsOpen ? notificationsTitle : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
          ),
        ),
        actions: <Widget>[
          if (notificationsOpen)
            IconButton(
              tooltip: labels.refresh,
              onPressed: onRefreshNotifications,
              icon: const Icon(Icons.refresh),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            color: cs.outlineVariant.withValues(alpha: 0.75),
          ),
        ),
      ),
      drawer: Drawer(
        backgroundColor: cs.surfaceContainerLowest,
        width: drawerWidth,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenBrand();
                    },
                    child: Ink(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.72),
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: BrandAssetImage(
                              url: hasLogo ? logoUrl : null,
                              fit: BoxFit.contain,
                              fallback: Icon(
                                Icons.apartment_outlined,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  brandName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: cs.onSurface,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    0,
                    AppSpacing.md,
                    AppSpacing.lg,
                  ),
                  children: <Widget>[
                    for (final item in items) ...<Widget>[
                      _SidebarNavButton(
                        selected: item.path == selectedPath,
                        expanded: true,
                        icon: item.icon,
                        label: item.label,
                        onTap: () {
                          Navigator.of(context).pop();
                          onSelectDrawerItem(item);
                        },
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    if (items.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        child: Divider(
                          height: 1,
                          color: cs.outlineVariant.withValues(alpha: 0.45),
                        ),
                      ),
                    _SidebarActionButton(
                      expanded: true,
                      icon: Icons.search,
                      label: labels.command,
                      onTap: () {
                        Navigator.of(context).pop();
                        onOpenCommands();
                      },
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    _SidebarActionButton(
                      expanded: true,
                      icon: Icons.notifications_outlined,
                      label: labels.notifications,
                      onTap: () {
                        Navigator.of(context).pop();
                        onOpenInbox();
                      },
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    _SidebarActionButton(
                      expanded: true,
                      icon: Icons.person_outline,
                      label: labels.account,
                      selected: accountSelected,
                      onTap: () {
                        Navigator.of(context).pop();
                        onOpenAccount();
                      },
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    _SidebarActionButton(
                      expanded: true,
                      icon: darkMode ? Icons.light_mode : Icons.dark_mode,
                      label: darkMode ? labels.lightMode : labels.darkMode,
                      onTap: () {
                        Navigator.of(context).pop();
                        onToggleTheme();
                      },
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    _SidebarActionButton(
                      expanded: true,
                      icon: Icons.logout,
                      label: labels.logout,
                      tone: cs.error,
                      onTap: () {
                        Navigator.of(context).pop();
                        onLogout();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[cs.surface, cs.surfaceContainerLowest, cs.surface],
          ),
        ),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: Column(
                children: <Widget>[
                  if (sessionWarningBanner case final banner?) ...<Widget>[
                    banner,
                  ],
                  Expanded(child: child),
                ],
              ),
            ),
            Positioned.fill(child: inboxPanel),
          ],
        ),
      ),
    );
  }
}

class _ShellInboxOverlay extends StatelessWidget {
  final bool open;
  final bool desktop;
  final VoidCallback onDismiss;
  final Widget child;

  const _ShellInboxOverlay({
    required this.open,
    required this.desktop,
    required this.onDismiss,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final panelWidth = desktop ? 420.0 : MediaQuery.sizeOf(context).width;
    final verticalInset = desktop ? AppSpacing.md : 0.0;
    final horizontalInset = desktop ? AppSpacing.md : 0.0;
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedOpacity(
        duration: AppMotion.standard,
        curve: Curves.easeOutCubic,
        opacity: open ? 1 : 0,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.14)),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalInset,
                  verticalInset,
                  horizontalInset,
                  verticalInset,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedSlide(
                    duration: AppMotion.emphasized,
                    curve: Curves.easeOutCubic,
                    offset: Offset(open ? 0 : -1.04, 0),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: panelWidth,
                        minWidth: panelWidth,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(desktop ? 24 : 0),
                          border: desktop
                              ? Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.72),
                                )
                              : null,
                          boxShadow: desktop
                              ? const <BoxShadow>[
                                  BoxShadow(
                                    blurRadius: 28,
                                    offset: Offset(0, 10),
                                    color: Color(0x22000000),
                                  ),
                                ]
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(desktop ? 24 : 0),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavSpec {
  final IconData icon;
  final String label;
  final String path;
  const _NavSpec({required this.icon, required this.label, required this.path});
}

class _ShellLabels {
  final String command;
  final String notifications;
  final String account;
  final String logout;
  final String refresh;
  final String darkMode;
  final String lightMode;
  final String more;

  const _ShellLabels({
    required this.command,
    required this.notifications,
    required this.account,
    required this.logout,
    required this.refresh,
    required this.darkMode,
    required this.lightMode,
    required this.more,
  });
}

class _ShellInboxData {
  final String? selectedSpaceId;
  final String? selectedSpaceLabel;
  final List<Map<String, dynamic>> mentions;
  final List<Map<String, dynamic>> reminders;
  final List<Map<String, dynamic>> approvals;

  const _ShellInboxData({
    this.selectedSpaceId,
    this.selectedSpaceLabel,
    this.mentions = const <Map<String, dynamic>>[],
    this.reminders = const <Map<String, dynamic>>[],
    this.approvals = const <Map<String, dynamic>>[],
  });
}

List<Map<String, dynamic>> _shellAsJsonList(Object? raw) {
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }
  return raw
      .whereType<Map>()
      .map((row) => row.cast<String, dynamic>())
      .toList(growable: false);
}

Map<String, dynamic> _shellAsJsonMap(Object? raw) {
  if (raw is! Map) {
    return const <String, dynamic>{};
  }
  return raw.cast<String, dynamic>();
}

String? _shellNonEmptyText(Object? raw) {
  final text = (raw ?? '').toString().trim();
  return text.isEmpty ? null : text;
}

class _ShellIntent extends Intent {
  const _ShellIntent.openCommands();
}
