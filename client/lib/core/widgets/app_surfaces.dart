// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared surface decorations and wrappers for consistent layout styling.

import 'package:flutter/material.dart';

import '../theme/theme.dart';

class AppAmbientBackground extends StatelessWidget {
  final Widget child;

  const AppAmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: cs.surface),
      child: child,
    );
  }
}

class AppGlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final BorderSide? borderSide;
  final List<BoxShadow>? boxShadow;
  final Clip clipBehavior;

  const AppGlassPanel({
    super.key,
    required this.child,
    this.radius = appRadiusLarge,
    this.padding = EdgeInsets.zero,
    this.color,
    this.borderSide,
    this.boxShadow,
    this.clipBehavior = Clip.none,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(radius),
        border: Border.fromBorderSide(
          borderSide ?? BorderSide(color: cs.outlineVariant),
        ),
        boxShadow: boxShadow ?? const <BoxShadow>[],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: clipBehavior,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class AppSectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  const AppSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: padding ?? const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.15,
                      ),
                    ),
                    if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        subtitle!,
                        style: textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.sm),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Divider(color: cs.outlineVariant.withValues(alpha: 0.35), height: 1),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

class AppPageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget>? actions;
  final List<Widget>? chips;

  const AppPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.actions,
    this.chips,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 720;
            final iconBadge = Icon(icon, color: cs.onSurfaceVariant, size: 22);
            final body = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.headlineSmall),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  subtitle,
                  style: textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            );

            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  iconBadge,
                  const SizedBox(height: AppSpacing.sm),
                  body,
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                iconBadge,
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: body),
                if (actions != null && actions!.isNotEmpty)
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: actions!,
                  ),
              ],
            );
          },
        ),
        if (actions != null && actions!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 720) {
                return const SizedBox.shrink();
              }
              return Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: actions!,
              );
            },
          ),
        ],
        if (chips != null && chips!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: chips!,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Divider(color: cs.outlineVariant),
      ],
    );
  }
}
