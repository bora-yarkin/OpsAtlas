// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared shell widgets for workspace-style surfaces and toolbars.

import 'package:flutter/material.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/atlas_ui.dart';

/// Simple action model for overflow or secondary workspace actions.
class WorkspaceAction {
  final String label;
  final IconData icon;
  final VoidCallback? onSelected;

  const WorkspaceAction({
    required this.label,
    required this.icon,
    required this.onSelected,
  });
}

enum WorkspaceScopeMode { current, selected, all }

/// Lightweight space reference used by shared workspace scope controls.
class WorkspaceScopeSpace {
  final String id;
  final String label;

  const WorkspaceScopeSpace({required this.id, required this.label});
}

/// Shared scope model for screens that can act on one, many, or all spaces.
class WorkspaceScopeValue {
  final WorkspaceScopeMode mode;
  final String currentSpaceId;
  final List<String> selectedSpaceIds;

  const WorkspaceScopeValue({
    required this.mode,
    required this.currentSpaceId,
    this.selectedSpaceIds = const <String>[],
  });

  WorkspaceScopeValue copyWith({
    WorkspaceScopeMode? mode,
    String? currentSpaceId,
    List<String>? selectedSpaceIds,
  }) {
    return WorkspaceScopeValue(
      mode: mode ?? this.mode,
      currentSpaceId: currentSpaceId ?? this.currentSpaceId,
      selectedSpaceIds: selectedSpaceIds ?? this.selectedSpaceIds,
    );
  }
}

/// Shared content shell for workspace-like surfaces with header controls and body.
class WorkspaceSurfaceShell extends StatelessWidget {
  final List<Widget> headerSections;
  final Widget body;

  const WorkspaceSurfaceShell({
    super.key,
    required this.headerSections,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactHeader =
            constraints.maxWidth < 980 || constraints.maxHeight < 720;
        final sectionGap = compactHeader ? AppSpacing.xs : AppSpacing.sm;
        return Column(
          children: [
            if (headerSections.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compactHeader ? 2 : 4,
                  0,
                  compactHeader ? 2 : 4,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (
                      var index = 0;
                      index < headerSections.length;
                      index++
                    ) ...[
                      headerSections[index],
                      if (index != headerSections.length - 1)
                        SizedBox(height: sectionGap),
                    ],
                  ],
                ),
              ),
            if (headerSections.isNotEmpty) SizedBox(height: sectionGap),
            Expanded(child: body),
          ],
        );
      },
    );
  }
}

/// Horizontal strip used for compact filters, tabs, and action clusters.
class WorkspaceInlineStrip extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const WorkspaceInlineStrip({
    super.key,
    required this.children,
    this.spacing = AppSpacing.sm,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var index = 0; index < children.length; index++) ...<Widget>[
            if (index > 0) SizedBox(width: spacing),
            children[index],
          ],
        ],
      ),
    );
  }
}

/// Toolbar primitive used by workspace screens to keep search and actions unified.
class WorkspaceSurfaceToolbar extends StatelessWidget {
  final Widget? scope;
  final Widget search;
  final Widget? help;
  final List<Widget> primaryActions;
  final List<WorkspaceAction> secondaryActions;
  final String moreTooltip;

  const WorkspaceSurfaceToolbar({
    super.key,
    this.scope,
    required this.search,
    this.help,
    this.primaryActions = const <Widget>[],
    this.secondaryActions = const <WorkspaceAction>[],
    required this.moreTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final actionWidgets = <Widget>[
      ?scope,
      ?help,
      ...primaryActions,
      if (secondaryActions.isNotEmpty)
        WorkspaceActionMenu(actions: secondaryActions, tooltip: moreTooltip),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              search,
              if (actionWidgets.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: actionWidgets,
                ),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: search),
            if (actionWidgets.isNotEmpty) ...<Widget>[
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: actionWidgets,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Compact button that summarizes the current workspace scope selection.
class WorkspaceScopeButton extends StatelessWidget {
  final String label;
  final String summary;
  final VoidCallback onPressed;

  const WorkspaceScopeButton({
    super.key,
    required this.label,
    required this.summary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.filter_alt_outlined),
      label: Text(
        '$label • $summary',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelLarge,
      ),
    );
  }
}

/// Wrap-based summary card for dense operational stats and chips.
class WorkspaceSummaryCard extends StatelessWidget {
  final List<Widget> children;

  const WorkspaceSummaryCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      ),
    );
  }
}

/// Hero-style card for the most important item in a workspace.
class WorkspaceFocusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  const WorkspaceFocusCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.72)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle.trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(width: 12),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Clickable summary tile used for small metric jumps within a workspace.
class WorkspaceSummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  final Color? tone;

  const WorkspaceSummaryTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.onTap,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final child = SizedBox(
      width: 220,
      child: AtlasStatTile(label: label, value: value, icon: icon, tone: tone),
    );
    if (onTap == null) {
      return child;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: child,
    );
  }
}

class WorkspaceActionMenu extends StatelessWidget {
  final List<WorkspaceAction> actions;
  final String tooltip;

  const WorkspaceActionMenu({
    super.key,
    required this.actions,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final enabledActions = actions
        .where((action) => action.onSelected != null)
        .toList(growable: false);
    if (enabledActions.isEmpty) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<WorkspaceAction>(
      tooltip: tooltip,
      onSelected: (action) => action.onSelected?.call(),
      itemBuilder: (context) => [
        for (final action in enabledActions)
          PopupMenuItem<WorkspaceAction>(
            value: action,
            child: Row(
              children: [
                Icon(action.icon, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(action.label)),
              ],
            ),
          ),
      ],
      icon: const Icon(Icons.more_horiz),
    );
  }
}

Future<WorkspaceScopeValue?> showWorkspaceScopeDialog({
  required BuildContext context,
  required String title,
  required String closeLabel,
  required String applyLabel,
  required String currentSpaceLabel,
  required String selectedSpacesLabel,
  required String allAccessibleSpacesLabel,
  required String emptySelectionLabel,
  required List<WorkspaceScopeSpace> spaces,
  required WorkspaceScopeValue initialValue,
  bool allowSelectingCurrentSpace = true,
}) async {
  return showDialog<WorkspaceScopeValue>(
    context: context,
    builder: (dialogContext) {
      var draft = initialValue;
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final selectedIds = draft.selectedSpaceIds.toSet();
          WorkspaceScopeSpace? currentSpace;
          for (final space in spaces) {
            if (space.id == draft.currentSpaceId) {
              currentSpace = space;
              break;
            }
          }
          final canApply =
              draft.mode != WorkspaceScopeMode.selected ||
              selectedIds.isNotEmpty;

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SegmentedButton<WorkspaceScopeMode>(
                    segments: <ButtonSegment<WorkspaceScopeMode>>[
                      ButtonSegment<WorkspaceScopeMode>(
                        value: WorkspaceScopeMode.current,
                        label: Text(currentSpaceLabel),
                        icon: const Icon(Icons.near_me_outlined),
                      ),
                      ButtonSegment<WorkspaceScopeMode>(
                        value: WorkspaceScopeMode.selected,
                        label: Text(selectedSpacesLabel),
                        icon: const Icon(Icons.checklist_outlined),
                      ),
                      ButtonSegment<WorkspaceScopeMode>(
                        value: WorkspaceScopeMode.all,
                        label: Text(allAccessibleSpacesLabel),
                        icon: const Icon(Icons.hub_outlined),
                      ),
                    ],
                    selected: <WorkspaceScopeMode>{draft.mode},
                    onSelectionChanged: (next) {
                      if (next.isEmpty) return;
                      setDialogState(() {
                        draft = draft.copyWith(mode: next.first);
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (draft.mode == WorkspaceScopeMode.current)
                    if (allowSelectingCurrentSpace)
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: ListView(
                            shrinkWrap: true,
                            children: <Widget>[
                              for (final space in spaces)
                                Material(
                                  color: Colors.transparent,
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      draft.currentSpaceId == space.id
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off_outlined,
                                    ),
                                    title: Text(space.label),
                                    onTap: () {
                                      setDialogState(() {
                                        draft = draft.copyWith(
                                          currentSpaceId: space.id,
                                        );
                                      });
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      )
                    else
                      Text(currentSpace?.label ?? draft.currentSpaceId)
                  else if (draft.mode == WorkspaceScopeMode.selected)
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: ListView(
                          shrinkWrap: true,
                          children: <Widget>[
                            for (final space in spaces)
                              CheckboxListTile(
                                value: selectedIds.contains(space.id),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                onChanged: (value) {
                                  setDialogState(() {
                                    if (value == true) {
                                      selectedIds.add(space.id);
                                    } else {
                                      selectedIds.remove(space.id);
                                    }
                                    draft = draft.copyWith(
                                      selectedSpaceIds: selectedIds.toList(
                                        growable: false,
                                      ),
                                    );
                                  });
                                },
                                title: Text(space.label),
                              ),
                          ],
                        ),
                      ),
                    )
                  else
                    Text(
                      spaces.isEmpty
                          ? emptySelectionLabel
                          : '${spaces.length} $allAccessibleSpacesLabel',
                    ),
                  if (draft.mode == WorkspaceScopeMode.selected &&
                      selectedIds.isEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      emptySelectionLabel,
                      style: Theme.of(dialogContext).textTheme.bodySmall
                          ?.copyWith(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(closeLabel),
              ),
              FilledButton(
                onPressed: canApply
                    ? () => Navigator.pop(dialogContext, draft)
                    : null,
                child: Text(applyLabel),
              ),
            ],
          );
        },
      );
    },
  );
}
