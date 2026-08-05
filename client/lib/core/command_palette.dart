// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Command palette state and UI for keyboard-driven navigation and actions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show ConsumerState, ConsumerStatefulWidget;
import 'package:flutter_riverpod/legacy.dart'
    show StateController, StateProvider;

class ContextCommand {
  final String label;
  final String subtitle;
  final IconData icon;
  final VoidCallback action;

  const ContextCommand({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.action,
  });
}

final commandPaletteRegistryProvider = StateProvider<List<ContextCommand>>(
  (ref) => const [],
);

class CommandPaletteScope extends ConsumerStatefulWidget {
  final List<ContextCommand> commands;
  final Widget child;

  const CommandPaletteScope({
    super.key,
    required this.commands,
    required this.child,
  });

  @override
  ConsumerState<CommandPaletteScope> createState() =>
      _CommandPaletteScopeState();
}

class _CommandPaletteScopeState extends ConsumerState<CommandPaletteScope> {
  late final StateController<List<ContextCommand>> _registryController;

  @override
  void initState() {
    super.initState();
    _registryController = ref.read(commandPaletteRegistryProvider.notifier);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant CommandPaletteScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleSync();
  }

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _registryController.state = List<ContextCommand>.unmodifiable(
        widget.commands,
      );
    });
  }

  @override
  void dispose() {
    // Avoid mutating providers during widget disposal; the next mounted
    // scope will publish its own command set.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
