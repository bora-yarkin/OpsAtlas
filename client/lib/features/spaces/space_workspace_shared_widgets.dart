// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Reusable widgets shared across the space workspace sections.

part of 'space_workspace_screen.dart';

class _DocDiffPreview extends StatelessWidget {
  final String fromLabel;
  final String toLabel;
  final List<JsonMap> rows;

  const _DocDiffPreview({
    required this.fromLabel,
    required this.toLabel,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(fromLabel, style: textTheme.titleMedium)),
            const SizedBox(width: 12),
            Expanded(child: Text(toLabel, style: textTheme.titleMedium)),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final row = rows[index];
              final kind = (row['kind'] ?? 'equal').toString();
              final tint = switch (kind) {
                'replace' => cs.tertiaryContainer.withValues(alpha: 0.52),
                'insert' => cs.primaryContainer.withValues(alpha: 0.48),
                'delete' => cs.errorContainer.withValues(alpha: 0.44),
                _ => cs.surfaceContainerLow,
              };
              return Container(
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.55),
                  ),
                ),
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _DiffCell(
                        lineNo: (row['left_line_no'] as num?)?.toInt(),
                        text: (row['left_text'] ?? '').toString(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _DiffCell(
                        lineNo: (row['right_line_no'] as num?)?.toInt(),
                        text: (row['right_text'] ?? '').toString(),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DiffCell extends StatelessWidget {
  final int? lineNo;
  final String text;

  const _DiffCell({required this.lineNo, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: cs.surface.withValues(alpha: 0.65),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lineNo == null ? '—' : lineNo.toString(),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          SelectableText(
            text.isEmpty ? ' ' : text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _DocInlineAnnotations extends StatelessWidget {
  final List<JsonMap> rows;
  final ValueChanged<JsonMap>? onAccept;
  final ValueChanged<JsonMap>? onReject;

  const _DocInlineAnnotations({
    required this.rows,
    this.onAccept,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final visible = rows
        .where((row) => (row['kind'] ?? 'equal').toString() != 'equal')
        .take(12)
        .toList();
    if (visible.isEmpty) {
      return Text(
        _t(context, 'no_changed_lines_compared_with_latest_saved_version'),
      );
    }
    return Column(
      children: [
        for (var index = 0; index < visible.length; index++) ...<Widget>[
          if (index > 0) const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final row = visible[index];
              final kind = (row['kind'] ?? 'replace').toString();
              final label = switch (kind) {
                'insert' => _t(context, 'added'),
                'delete' => _t(context, 'removed'),
                _ => _t(context, 'changed'),
              };
              final before = (row['left_text'] ?? '').toString();
              final after = (row['right_text'] ?? '').toString();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.55),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$label line',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    if (before.trim().isNotEmpty)
                      Text(
                        'Before: $before',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (after.trim().isNotEmpty)
                      Text(
                        'After: $after',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (onAccept != null || onReject != null) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (onAccept != null)
                            OutlinedButton.icon(
                              onPressed: () => onAccept!(row),
                              icon: const Icon(Icons.check_circle_outline),
                              label: Text(_t(context, 'apply_change')),
                            ),
                          if (onReject != null)
                            OutlinedButton.icon(
                              onPressed: () => onReject!(row),
                              icon: const Icon(Icons.undo_outlined),
                              label: Text(_t(context, 'revert_change')),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (status) {
      'published' || 'resolved' => cs.tertiary,
      'monitoring' => cs.secondary,
      'open' || 'draft' => cs.primary,
      _ => cs.onSurfaceVariant,
    };
    final bg = color.withValues(alpha: 0.16);
    final fg = appBestForegroundColor(bg);
    return Chip(
      label: Text(_statusText(context, status)),
      side: BorderSide(color: color.withValues(alpha: 0.42)),
      backgroundColor: bg,
      labelStyle: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w700),
    );
  }
}

class _DialogScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget body;
  final Widget? footer;
  final VoidCallback? onClose;
  final bool scrollBody;
  final List<Widget> headerBadges;
  final Widget? primaryAction;
  final List<WorkspaceAction> secondaryActions;

  const _DialogScaffold({
    required this.title,
    required this.body,
    this.subtitle,
    this.footer,
    this.onClose,
    this.scrollBody = false,
    this.headerBadges = const <Widget>[],
    this.primaryAction,
    this.secondaryActions = const <WorkspaceAction>[],
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scaffold = LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPad = constraints.maxWidth < 720
            ? AppSpacing.md
            : AppSpacing.lg;
        final titleBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (subtitle != null && subtitle!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Semantics(
              header: true,
              child: SelectionArea(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        );
        final titleHeader = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (onClose != null) ...<Widget>[
              IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onClose,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            Expanded(child: titleBlock),
          ],
        );
        final actionWidgets = <Widget>[
          ...?(primaryAction == null ? null : <Widget>[primaryAction!]),
          if (secondaryActions.isNotEmpty)
            WorkspaceActionMenu(
              actions: secondaryActions,
              tooltip: _t(context, 'more'),
            ),
        ];
        final actionStrip = actionWidgets.isEmpty
            ? null
            : WorkspaceInlineStrip(
                spacing: AppSpacing.xs,
                children: actionWidgets,
              );

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1480),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPad,
                AppSpacing.xs,
                horizontalPad,
                AppSpacing.sm,
              ),
              child: Column(
                children: <Widget>[
                  Material(
                    color: cs.surfaceContainerLowest,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                      side: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.72),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          LayoutBuilder(
                            builder: (context, headerConstraints) {
                              final stacked = headerConstraints.maxWidth < 920;
                              if (stacked) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    titleHeader,
                                    if (actionStrip != null) ...<Widget>[
                                      const SizedBox(height: AppSpacing.sm),
                                      actionStrip,
                                    ],
                                  ],
                                );
                              }
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Expanded(child: titleHeader),
                                  if (actionStrip != null) ...<Widget>[
                                    const SizedBox(width: AppSpacing.sm),
                                    Flexible(
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: actionStrip,
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                          if (headerBadges.isNotEmpty) ...<Widget>[
                            const SizedBox(height: AppSpacing.sm),
                            WorkspaceInlineStrip(
                              spacing: AppSpacing.xs,
                              children: headerBadges,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Expanded(
                    child: scrollBody
                        ? Scrollbar(
                            child: SingleChildScrollView(
                              primary: true,
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.md,
                              ),
                              child: body,
                            ),
                          )
                        : body,
                  ),
                  if (footer != null)
                    Material(
                      color: cs.surfaceContainerLowest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                        side: BorderSide(
                          color: cs.outlineVariant.withValues(alpha: 0.72),
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: SafeArea(
                        top: false,
                        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                        child: footer!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    final enableBackSwipe = onClose != null && Navigator.of(context).canPop();
    return enableBackSwipe
        ? AtlasEdgeBackGesture(onBack: onClose, child: scaffold)
        : scaffold;
  }
}
