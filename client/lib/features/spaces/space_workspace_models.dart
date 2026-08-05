// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Internal models and view records shared across workspace sections.

part of 'space_workspace_screen.dart';

class _KbDocDetailData {
  final JsonMap doc;
  final List<JsonMap> versions;
  final List<JsonMap> comments;
  final JsonMap? diff;
  _KbDocDetailData({
    required this.doc,
    required this.versions,
    required this.comments,
    required this.diff,
  });
}

class _IncidentLinkOptions {
  final List<JsonMap> docs;
  final List<JsonMap> sops;
  const _IncidentLinkOptions({required this.docs, required this.sops});
}
