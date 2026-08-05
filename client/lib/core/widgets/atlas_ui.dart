// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared page frames, panels, and UI primitives for the OpsAtlas design system.

import 'package:flutter/material.dart';

import '../navigation/app_route_navigation.dart';
import '../theme/theme.dart';

/// Standard page frame for top-level desktop-style routes with roomy headers.
class AtlasPageFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;

  const AtlasPageFrame({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
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
            final compactHeader =
                constraints.maxWidth < 980 || constraints.maxHeight < 820;
            final horizontalPad = constraints.maxWidth < 720
                ? AppSpacing.md
                : AppSpacing.xl;
            final showTitleBlock = !compactHeader;
            final showHeader = showTitleBlock || actions.isNotEmpty;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPad,
                    compactHeader ? AppSpacing.sm : AppSpacing.lg,
                    horizontalPad,
                    compactHeader ? AppSpacing.lg : AppSpacing.xxl,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (showHeader)
                        LayoutBuilder(
                          builder: (context, headerConstraints) {
                            final stacked = headerConstraints.maxWidth < 920;
                            final titleBlock = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  title,
                                  style: textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if (subtitle != null &&
                                    subtitle!.trim().isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: AppSpacing.xs,
                                    ),
                                    child: Text(
                                      subtitle!,
                                      style: textTheme.bodyMedium?.copyWith(
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                            final actionWrap = actions.isEmpty
                                ? const SizedBox.shrink()
                                : Wrap(
                                    spacing: AppSpacing.xs,
                                    runSpacing: AppSpacing.xs,
                                    children: actions,
                                  );
                            if (!showTitleBlock) {
                              return Align(
                                alignment: Alignment.centerRight,
                                child: actionWrap,
                              );
                            }
                            if (stacked) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  titleBlock,
                                  if (actions.isNotEmpty) ...<Widget>[
                                    const SizedBox(height: AppSpacing.md),
                                    actionWrap,
                                  ],
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Expanded(child: titleBlock),
                                if (actions.isNotEmpty) ...<Widget>[
                                  const SizedBox(width: AppSpacing.md),
                                  actionWrap,
                                ],
                              ],
                            );
                          },
                        ),
                      if (showHeader)
                        SizedBox(
                          height: showTitleBlock
                              ? AppSpacing.lg
                              : AppSpacing.sm,
                        ),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Compact page frame used by mobile and detail-style routes.
class AtlasCompactPageFrame extends StatelessWidget {
  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final Widget child;

  const AtlasCompactPageFrame({
    super.key,
    required this.title,
    required this.child,
    this.leading,
    this.actions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final frame = DecoratedBox(
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
            final compactHeader =
                leading == null &&
                (constraints.maxWidth < 980 || constraints.maxHeight < 820);
            final canPop = Navigator.of(context).canPop();
            final hideInlineLeading = constraints.maxWidth < 980 && canPop;
            final effectiveLeading = hideInlineLeading ? null : leading;
            final horizontalPad = constraints.maxWidth < 720
                ? AppSpacing.md
                : AppSpacing.lg;
            final showTitleRow = !compactHeader;
            final showHeader = showTitleRow || actions.isNotEmpty;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPad,
                    compactHeader ? AppSpacing.sm : AppSpacing.md,
                    horizontalPad,
                    compactHeader ? AppSpacing.md : AppSpacing.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (showHeader)
                        LayoutBuilder(
                          builder: (context, headerConstraints) {
                            final stacked = headerConstraints.maxWidth < 840;
                            final titleRow = Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (effectiveLeading != null) ...<Widget>[
                                  effectiveLeading,
                                  const SizedBox(width: AppSpacing.sm),
                                ],
                                Flexible(
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
                            );
                            final actionWrap = actions.isEmpty
                                ? const SizedBox.shrink()
                                : Wrap(
                                    spacing: AppSpacing.xs,
                                    runSpacing: AppSpacing.xs,
                                    children: actions,
                                  );
                            if (!showTitleRow) {
                              return Align(
                                alignment: Alignment.centerRight,
                                child: actionWrap,
                              );
                            }
                            if (stacked) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  titleRow,
                                  if (actions.isNotEmpty) ...<Widget>[
                                    const SizedBox(height: AppSpacing.sm),
                                    actionWrap,
                                  ],
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: <Widget>[
                                Expanded(child: titleRow),
                                if (actions.isNotEmpty) ...<Widget>[
                                  const SizedBox(width: AppSpacing.sm),
                                  actionWrap,
                                ],
                              ],
                            );
                          },
                        ),
                      if (showHeader)
                        SizedBox(
                          height: showTitleRow ? AppSpacing.md : AppSpacing.xs,
                        ),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    final allowBackSwipe = leading != null && Navigator.of(context).canPop();
    return allowBackSwipe
        ? AtlasEdgeBackGesture(
            onBack: () => Navigator.of(context).maybePop(),
            child: frame,
          )
        : frame;
  }
}

/// Shared content section with a title row and consistent panel styling.
class AtlasPanel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final bool expandChild;

  const AtlasPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.expandChild = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackHeader = trailing != null && constraints.maxWidth < 420;
        return Material(
          color: cs.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.72)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (stackHeader) ...<Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _AtlasPanelHeading(
                        title: title,
                        subtitle: subtitle,
                        textTheme: textTheme,
                        onSurfaceVariant: cs.onSurfaceVariant,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Align(alignment: Alignment.centerLeft, child: trailing!),
                    ],
                  ),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: _AtlasPanelHeading(
                          title: title,
                          subtitle: subtitle,
                          textTheme: textTheme,
                          onSurfaceVariant: cs.onSurfaceVariant,
                        ),
                      ),
                      if (trailing != null) ...<Widget>[
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(child: trailing!),
                      ],
                    ],
                  ),
                const SizedBox(height: AppSpacing.md),
                if (expandChild) Expanded(child: child) else child,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AtlasPanelHeading extends StatelessWidget {
  final String title;
  final String? subtitle;
  final TextTheme textTheme;
  final Color onSurfaceVariant;

  const _AtlasPanelHeading({
    required this.title,
    required this.subtitle,
    required this.textTheme,
    required this.onSurfaceVariant,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (subtitle != null && subtitle!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              subtitle!,
              style: textTheme.bodySmall?.copyWith(color: onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class AtlasStatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? tone;

  const AtlasStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconTone = tone ?? cs.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.75)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconTone.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: iconTone, size: 20),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    label,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AtlasEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const AtlasEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 34, color: cs.onSurfaceVariant),
              const SizedBox(height: AppSpacing.sm),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (subtitle != null && subtitle!.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              if (action != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
