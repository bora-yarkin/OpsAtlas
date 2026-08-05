// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared dialog presentation helpers with app-wide styling and accessibility behavior.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../i18n/app_localizations.dart';

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String? announcement,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: announcement == null || announcement.trim().isEmpty
        ? l10n.text('dismiss_dialog')
        : '${l10n.text('dismiss_item_prefix')} ${announcement.trim()}',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    builder: (dialogContext) {
      final size = MediaQuery.sizeOf(dialogContext);
      final isCompact = size.width < 720;
      final horizontalPadding = isCompact ? 10.0 : 22.0;
      final availableWidth = math.max(
        280.0,
        size.width - (horizontalPadding * 2),
      );
      final maxWidth = isCompact
          ? availableWidth
          : math.min(1360.0, availableWidth);
      final minWidth = isCompact
          ? 0.0
          : size.width >= 1500
          ? 860.0
          : size.width >= 1200
          ? 760.0
          : size.width >= 900
          ? 680.0
          : 560.0;
      final theme = Theme.of(dialogContext);
      final cs = theme.colorScheme;
      final modalTheme = theme.copyWith(
        dialogTheme: theme.dialogTheme.copyWith(
          backgroundColor: cs.surfaceContainerLowest,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)),
          ),
        ),
      );
      final child = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: 12,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: minWidth,
            maxWidth: maxWidth,
            maxHeight: size.height * 0.98,
          ),
          child: Theme(data: modalTheme, child: builder(dialogContext)),
        ),
      );
      final scopedChild = announcement == null || announcement.trim().isEmpty
          ? child
          : Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              label: announcement,
              child: child,
            );

      return FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Semantics(
          liveRegion: announcement != null && announcement.trim().isNotEmpty,
          child: scopedChild,
        ),
      );
    },
  );
}
