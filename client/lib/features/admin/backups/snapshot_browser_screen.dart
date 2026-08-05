// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Administrative snapshot browser for inspecting backup contents.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/command_palette.dart';
import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/theme.dart';
import '../../../core/widgets/atlas_ui.dart';

final treeProvider =
    FutureProvider.family<
      Map<String, dynamic>,
      ({String snapshotId, String path})
    >((ref, args) async {
      final api = ref.watch(apiClientProvider);
      final r = await api.dio.get(
        '/admin/backups/snapshots/${args.snapshotId}/tree',
        queryParameters: {'path': args.path},
      );
      return (r.data as Map).cast<String, dynamic>();
    });

final nodeProvider =
    FutureProvider.family<
      Map<String, dynamic>,
      ({String snapshotId, String path})
    >((ref, args) async {
      final api = ref.watch(apiClientProvider);
      final r = await api.dio.get(
        '/admin/backups/snapshots/${args.snapshotId}/node',
        queryParameters: {'path': args.path},
      );
      return (r.data as Map).cast<String, dynamic>();
    });

class SnapshotBrowserScreen extends ConsumerStatefulWidget {
  final String snapshotId;
  final String? initialPath;

  const SnapshotBrowserScreen({
    super.key,
    required this.snapshotId,
    this.initialPath,
  });

  @override
  ConsumerState<SnapshotBrowserScreen> createState() =>
      _SnapshotBrowserScreenState();
}

class _SnapshotBrowserScreenState extends ConsumerState<SnapshotBrowserScreen> {
  late String path;
  String? selectedFile;

  @override
  void initState() {
    super.initState();
    path = _normalizePath(widget.initialPath ?? '/');
  }

  static String _normalizePath(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == '/') return '/';
    final withPrefix = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    final compact = withPrefix.replaceAll(RegExp(r'/+'), '/');
    return compact;
  }

  void _refreshCurrent() {
    ref.invalidate(treeProvider((snapshotId: widget.snapshotId, path: path)));
    if (selectedFile != null) {
      ref.invalidate(
        nodeProvider((snapshotId: widget.snapshotId, path: selectedFile!)),
      );
    }
  }

  void _goUp() {
    if (path == '/') return;
    final parts = path.split('/')..removeWhere((e) => e.isEmpty);
    if (parts.isNotEmpty) parts.removeLast();
    setState(() {
      path = '/${parts.join('/')}';
      if (path.trim().isEmpty || path == '//') path = '/';
      selectedFile = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final treeAsync = ref.watch(
      treeProvider((snapshotId: widget.snapshotId, path: path)),
    );
    final l10n = AppLocalizations.of(context);

    Future<void> copyLinkAction() async {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final link = Uri(
        path: '/organization/backups/${widget.snapshotId}',
        queryParameters: {'path': path},
      ).toString();
      await Clipboard.setData(ClipboardData(text: link));
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.text('link_copied'))),
      );
    }

    return CommandPaletteScope(
      commands: [
        ContextCommand(
          label: l10n.text('refresh'),
          subtitle: path,
          icon: Icons.refresh,
          action: _refreshCurrent,
        ),
        ContextCommand(
          label: l10n.text('copy_current_link'),
          subtitle: path,
          icon: Icons.link_outlined,
          action: copyLinkAction,
        ),
      ],
      child: AtlasPageFrame(
        title: l10n.text('snapshot_browser'),
        subtitle: path,
        actions: <Widget>[
          OutlinedButton.icon(
            onPressed: _refreshCurrent,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.text('refresh')),
          ),
          OutlinedButton.icon(
            onPressed: copyLinkAction,
            icon: const Icon(Icons.link_outlined),
            label: Text(l10n.text('copy_current_link')),
          ),
          OutlinedButton.icon(
            onPressed: () => context.go('/organization/backups'),
            icon: const Icon(Icons.backup_outlined),
            label: Text(l10n.text('backups')),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AtlasPanel(
              title: l10n.text('snapshot_browser'),
              subtitle: path,
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  Chip(
                    avatar: const Icon(Icons.route_outlined, size: 16),
                    label: SelectableText(path),
                  ),
                  if (selectedFile != null)
                    Chip(
                      avatar: const Icon(Icons.description_outlined, size: 16),
                      label: SelectableText(selectedFile!),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final tabbed = constraints.maxWidth < 700;
                  final stacked = constraints.maxWidth < 940;

                  final treePane = _TreePane(
                    snapshotId: widget.snapshotId,
                    currentPath: path,
                    treeAsync: treeAsync,
                    onGoUp: _goUp,
                    onOpenFolder: (nextPath) {
                      setState(() {
                        path = _normalizePath(nextPath);
                        selectedFile = null;
                      });
                    },
                    onSelectFile: (filePath) {
                      setState(() => selectedFile = filePath);
                    },
                  );

                  final previewPane = _PreviewPane(
                    snapshotId: widget.snapshotId,
                    selectedFile: selectedFile,
                  );

                  if (tabbed) {
                    return DefaultTabController(
                      length: 2,
                      child: AtlasPanel(
                        title: l10n.text('snapshot_browser'),
                        subtitle: l10n.text('backup_tree'),
                        expandChild: true,
                        child: Column(
                          children: [
                            Material(
                              color: Colors.transparent,
                              child: TabBar(
                                tabs: [
                                  Tab(
                                    icon: const Icon(
                                      Icons.folder_open_outlined,
                                    ),
                                    text: l10n.text('backup_tree'),
                                  ),
                                  Tab(
                                    icon: const Icon(Icons.preview_outlined),
                                    text: l10n.text('preview_pane'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  AtlasPanel(
                                    title: l10n.text('backup_tree'),
                                    expandChild: true,
                                    child: treePane,
                                  ),
                                  AtlasPanel(
                                    title: l10n.text('preview_pane'),
                                    expandChild: true,
                                    child: previewPane,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (stacked) {
                    return Column(
                      children: [
                        Expanded(
                          child: AtlasPanel(
                            title: l10n.text('backup_tree'),
                            subtitle: path,
                            expandChild: true,
                            child: treePane,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Expanded(
                          child: AtlasPanel(
                            title: l10n.text('preview_pane'),
                            subtitle: selectedFile ?? l10n.text('dash'),
                            expandChild: true,
                            child: previewPane,
                          ),
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(
                        child: AtlasPanel(
                          title: l10n.text('backup_tree'),
                          subtitle: path,
                          expandChild: true,
                          child: treePane,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: AtlasPanel(
                          title: l10n.text('preview_pane'),
                          subtitle: selectedFile ?? l10n.text('dash'),
                          expandChild: true,
                          child: previewPane,
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
    );
  }
}

class _TreePane extends StatelessWidget {
  final String snapshotId;
  final String currentPath;
  final AsyncValue<Map<String, dynamic>> treeAsync;
  final VoidCallback onGoUp;
  final ValueChanged<String> onOpenFolder;
  final ValueChanged<String> onSelectFile;

  const _TreePane({
    required this.snapshotId,
    required this.currentPath,
    required this.treeAsync,
    required this.onGoUp,
    required this.onOpenFolder,
    required this.onSelectFile,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedSwitcher(
      duration: AppMotion.standard,
      child: treeAsync.when(
        data: (tree) {
          final children = (tree['children'] as List? ?? const [])
              .cast<Map>()
              .map((row) => row.cast<String, dynamic>())
              .toList();
          return ListView(
            key: ValueKey('tree_$currentPath'),
            children: [
              ListTile(
                leading: const Icon(Icons.arrow_upward),
                title: const SelectableText('..'),
                onTap: currentPath == '/' ? null : onGoUp,
              ),
              for (final child in children)
                Semantics(
                  button: true,
                  label: '${child['type']} ${(child['name'] ?? '').toString()}',
                  child: ListTile(
                    leading: Icon(
                      child['type'] == 'folder'
                          ? Icons.folder_outlined
                          : Icons.description_outlined,
                    ),
                    title: SelectableText((child['name'] ?? '').toString()),
                    subtitle: SelectableText((child['path'] ?? '').toString()),
                    onTap: () {
                      if (child['type'] == 'folder') {
                        onOpenFolder((child['path'] ?? '/').toString());
                      } else {
                        onSelectFile((child['path'] ?? '').toString());
                      }
                    },
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(
          key: ValueKey('tree_loading'),
          child: CircularProgressIndicator(),
        ),
        error: (e, _) => Center(
          key: const ValueKey('tree_error'),
          child: SelectableText('${l10n.text('failed_to_load_tree')}: $e'),
        ),
      ),
    );
  }
}

class _PreviewPane extends ConsumerWidget {
  final String snapshotId;
  final String? selectedFile;

  const _PreviewPane({required this.snapshotId, required this.selectedFile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (selectedFile == null || selectedFile!.trim().isEmpty) {
      return Center(child: SelectableText(l10n.text('select_file_to_preview')));
    }
    final nodeAsync = ref.watch(
      nodeProvider((snapshotId: snapshotId, path: selectedFile!)),
    );
    return AnimatedSwitcher(
      duration: AppMotion.standard,
      child: nodeAsync.when(
        data: (node) => SingleChildScrollView(
          key: ValueKey('node_$selectedFile'),
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                selectedFile!,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              SelectableText((node['content'] ?? '').toString()),
            ],
          ),
        ),
        loading: () => const Center(
          key: ValueKey('node_loading'),
          child: CircularProgressIndicator(),
        ),
        error: (e, _) => Center(
          key: const ValueKey('node_error'),
          child: SelectableText('${l10n.text('failed_to_load_node')}: $e'),
        ),
      ),
    );
  }
}
