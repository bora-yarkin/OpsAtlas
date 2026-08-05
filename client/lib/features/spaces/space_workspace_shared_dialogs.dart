// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Dialog helpers reused across KB, SOP, and incident workspace sections.

part of 'space_workspace_screen.dart';

Future<T?> _showLargeDialog<T>(
  BuildContext context,
  Widget child, {
  String? announcement,
}) {
  if (announcement != null && announcement.trim().isNotEmpty) {
    SemanticsService.sendAnnouncement(
      View.of(context),
      announcement,
      Directionality.of(context),
    );
  }
  return Navigator.of(context).push<T>(
    CupertinoPageRoute<T>(
      builder: (routeContext) {
        return Scaffold(
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Theme.of(routeContext).colorScheme.surface,
                  Theme.of(routeContext).colorScheme.surfaceContainerLowest,
                  Theme.of(routeContext).colorScheme.surface,
                ],
              ),
            ),
            child: SafeArea(child: child),
          ),
        );
      },
    ),
  );
}
