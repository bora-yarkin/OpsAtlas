// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// KB-specific helper methods for search, formatting, and list state.

part of 'space_workspace_screen.dart';

Future<bool?> _showCreateFolderDialog(
  BuildContext context,
  ApiClient api, {
  required String spaceId,
  required String? parentId,
}) async {
  final nameCtrl = TextEditingController();
  String? error;
  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: SelectionArea(child: Text(_t(context, 'create_folder'))),
          content: SelectionArea(
            child: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: _t(context, 'folder_name'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    onChanged: (_) {
                      if (error != null) setState(() => error = null);
                    },
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_t(context, 'cancel')),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    setState(() => error = _t(context, 'name_required'));
                    return;
                  }
                  await api.dio.post(
                    '/kb/folders',
                    data: {
                      'space_id': spaceId,
                      'parent_id': parentId,
                      'name': name,
                    },
                  );
                  if (context.mounted) Navigator.pop(context, true);
                } catch (e) {
                  setState(() => error = _errorText(e));
                }
              },
              child: Text(_t(context, 'create')),
            ),
          ],
        ),
      );
    },
  );
  nameCtrl.dispose();
  return result;
}

Future<bool?> _showEditFolderDialog(
  BuildContext context,
  ApiClient api, {
  required String spaceId,
  required JsonMap existingFolder,
  required List<JsonMap> folders,
  bool focusOnMove = false,
}) async {
  final folderId = (existingFolder['id'] ?? '').toString().trim();
  final folderPath = (existingFolder['path'] ?? '').toString().trim();
  final descendantPrefix = folderPath.isEmpty ? '' : '$folderPath/';
  final availableParents = folders.where((folder) {
    final candidateId = (folder['id'] ?? '').toString().trim();
    final candidatePath = (folder['path'] ?? '').toString().trim();
    if (candidateId.isEmpty || candidateId == folderId) {
      return false;
    }
    if (descendantPrefix.isNotEmpty &&
        candidatePath.startsWith(descendantPrefix)) {
      return false;
    }
    return true;
  }).toList(growable: false);

  final nameCtrl = TextEditingController(
    text: (existingFolder['name'] ?? '').toString(),
  );
  String selectedParentId =
      (existingFolder['parent_id'] ?? '').toString().trim();
  String? error;

  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: SelectionArea(
            child: Text(
              focusOnMove
                  ? _t(context, 'move')
                  : 'Edit folder',
            ),
          ),
          content: SelectionArea(
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: _t(context, 'folder_name'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    onChanged: (_) {
                      if (error != null) setState(() => error = null);
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedParentId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: _t(context, 'folder'),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                    items: [
                      DropdownMenuItem<String>(
                        value: '',
                        child: const Text('Top level'),
                      ),
                      for (final folder in availableParents)
                        DropdownMenuItem<String>(
                          value: (folder['id'] ?? '').toString().trim(),
                          child: Text(
                            (folder['path'] ?? folder['name'] ?? 'Folder')
                                .toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(
                      () => selectedParentId = (value ?? '').trim(),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_t(context, 'cancel')),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    setState(() => error = _t(context, 'name_required'));
                    return;
                  }
                  await api.dio.put(
                    '/kb/folders/$folderId',
                    data: {
                      'name': name,
                      'parent_id': selectedParentId.isEmpty
                          ? null
                          : selectedParentId,
                    },
                  );
                  if (context.mounted) Navigator.pop(context, true);
                } catch (e) {
                  setState(() => error = _errorText(e));
                }
              },
              child: Text(_t(context, 'save')),
            ),
          ],
        ),
      );
    },
  );

  nameCtrl.dispose();
  return result;
}

Future<String?> _showMoveToFolderDialog(
  BuildContext context,
  List<JsonMap> folders, {
  required String title,
  required String typeLabel,
  String? initialFolderId,
}) async {
  String selectedFolderId = (initialFolderId ?? '').trim();
  return showAppDialog<String>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: SelectionArea(child: Text('${_t(context, 'move')} $typeLabel')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedFolderId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _t(context, 'folder'),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      value: '',
                      child: const Text('Top level'),
                    ),
                    for (final folder in folders)
                      DropdownMenuItem<String>(
                        value: (folder['id'] ?? '').toString().trim(),
                        child: Text(
                          (folder['path'] ?? folder['name'] ?? 'Folder')
                              .toString(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(
                    () => selectedFolderId = (value ?? '').trim(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t(context, 'cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selectedFolderId),
              child: Text(_t(context, 'save')),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _showDocSearchDialog(BuildContext context, String spaceId) async {
  final ctrl = TextEditingController();
  final selected = await showAppDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(_t(context, 'search_kb')),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: _t(context, 'query'),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              prefixIcon: const Icon(Icons.search),
            ),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(_t(context, 'search')),
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
  if (selected == null || selected.isEmpty || !context.mounted) return;
  final encoded = Uri(
    path: '/spaces/$spaceId',
  ).toString();
  final uri = Uri.parse(encoded);
  final target = Uri(
    path: uri.path,
    queryParameters: {...uri.queryParameters, 'search': selected},
  );
  // The KB tab already owns its own local search field. Copy the link instead of forcing a route mutation.
  await _copyText(
    context,
    Uri.base.resolveUri(target).toString(),
    _t(context, 'search_link_copied'),
  );
}
