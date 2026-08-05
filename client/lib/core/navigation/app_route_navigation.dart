// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Navigation helpers for stack-aware routing and edge-swipe back behavior.

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Returns the path segment for a route string, ignoring query parameters.
String atlasRoutePath(String route) {
  try {
    return Uri.parse(route).path;
  } catch (_) {
    return route;
  }
}

/// Space workspaces behave like stack destinations rather than flat tabs.
bool atlasUsesStackNavigation(String route) {
  return atlasRoutePath(route).startsWith('/spaces/');
}

/// Opens a route with `push` for stacked workspaces and `go` for peer screens.
Future<T?> atlasOpenRoute<T>(BuildContext context, String route) {
  if (atlasUsesStackNavigation(route)) {
    return context.push<T>(route);
  }
  context.go(route);
  return Future<T?>.value(null);
}

/// Pops the current navigator when possible, otherwise falls back to a route.
void atlasPopOrGo(BuildContext context, String fallbackRoute) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
    return;
  }
  context.go(fallbackRoute);
}

/// Adds an iOS-style edge-swipe back affordance to compact routes and overlays.
class AtlasEdgeBackGesture extends StatefulWidget {
  final Widget child;
  final VoidCallback? onBack;
  final bool enabled;
  final double edgeWidth;

  const AtlasEdgeBackGesture({
    super.key,
    required this.child,
    this.onBack,
    this.enabled = true,
    this.edgeWidth = 26,
  });

  @override
  State<AtlasEdgeBackGesture> createState() => _AtlasEdgeBackGestureState();
}

class _AtlasEdgeBackGestureState extends State<AtlasEdgeBackGesture> {
  double _dragDistance = 0;

  void _reset() {
    _dragDistance = 0;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeSizeOf(context);
    final isMobile = (media?.width ?? 0) < 980;
    final canPop = Navigator.of(context).canPop() || widget.onBack != null;
    final enabled = widget.enabled && isMobile && canPop;

    if (!enabled) {
      return widget.child;
    }

    return Stack(
      children: <Widget>[
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: widget.edgeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _reset(),
            onHorizontalDragUpdate: (details) {
              final nextDistance = _dragDistance + details.delta.dx;
              _dragDistance = nextDistance < 0 ? 0 : nextDistance;
            },
            onHorizontalDragCancel: _reset,
            onHorizontalDragEnd: (details) {
              final shouldGoBack =
                  _dragDistance >= 72 || (details.primaryVelocity ?? 0) >= 700;
              _reset();
              if (!shouldGoBack) {
                return;
              }
              final onBack = widget.onBack;
              if (onBack != null) {
                onBack();
                return;
              }
              Navigator.of(context).maybePop();
            },
          ),
        ),
      ],
    );
  }
}
