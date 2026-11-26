import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../screens/folder_screen.dart';
import '../screens/preview_screen.dart';
import '../state/app_state.dart';
import '../util/file_actions.dart';
import '../util/format.dart';
import 'dialogs.dart';
import 'folder_picker.dart';
import 'share_sheet.dart';
import 'toast.dart';

/// Open an item: folders are browsed, previewable files shown in the app,
/// anything else (PDFs, documents…) handed to another app.
Future<void> openNode(BuildContext context, Node node, {List<Node>? siblings, bool fromParent = true}) async {
  final api = context.read<AppState>().api!;
  if (node.isDir) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FolderScreen(folderId: node.id, openedFromParent: fromParent),
      ),
    );
  } else if (node.previewable) {
    final files = (siblings ?? [node]).where((n) => n.previewable).toList();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PreviewScreen(files: files, initial: files.indexWhere((n) => n.id == node.id)),
      ),
    );
  } else {
    await downloadAndOpen(context, api, node);
  }
}

enum NodeAction { open, openWith, save, playlist, link, rename, move, delete }

/// The ⋮ menu for one item. [onChanged] runs after a rename/move/delete/share change.
Future<void> runNodeAction(
  BuildContext context,
  NodeAction action,
  Node node, {
  List<Node>? siblings,
  required VoidCallback onChanged,
}) async {
  final api = context.read<AppState>().api!;
  try {
    switch (action) {
      case NodeAction.open:
        await openNode(context, node, siblings: siblings);
      case NodeAction.openWith:
        await downloadAndOpen(context, api, node);
      case NodeAction.save:
        await downloadAndShare(context, api, [node]);
      case NodeAction.link:
        if (await showShareSheet(context, nodeId: node.id, name: node.name, isDir: node.isDir)) onChanged();
      case NodeAction.rename:
        final name = await promptText(context, title: 'Rename', label: 'Name', initial: node.name, confirm: 'Rename');
        if (name != null && name != node.name) {
          await api.rename(node.id, name);
          onChanged();
        }
      case NodeAction.move:
        if (await moveNodes(context, [node])) onChanged();
      case NodeAction.playlist:
        await addToPlaylist(context, [node]);
      case NodeAction.delete:
        if (await deleteNodes(context, [node])) onChanged();
    }
  } on ApiException catch (e) {
    if (context.mounted) showError(context, e.message);
  }
}

/// Ask where to, then move. Returns true if moved.
Future<bool> moveNodes(BuildContext context, List<Node> nodes) async {
  final api = context.read<AppState>().api!;
  final target = await pickFolder(
    context,
    title: nodes.length == 1 ? 'Move "${nodes.first.name}"' : 'Move ${nodes.length} items',
    excluded: {
      for (final n in nodes)
        if (n.isDir) n.id,
    },
  );
  if (target == null) return false;
  if (nodes.every((n) => n.parentId == target)) return false;
  await api.move([for (final n in nodes) n.id], target);
  if (context.mounted) {
    showMessage(context, nodes.length == 1 ? 'Moved "${nodes.first.name}"' : 'Moved ${nodes.length} items');
  }
  return true;
}

/// Confirm, then delete. Returns true if deleted.
Future<bool> deleteNodes(BuildContext context, List<Node> nodes) async {
  final api = context.read<AppState>().api!;
  final what = nodes.length == 1 ? '"${nodes.first.name}"' : '${nodes.length} items';
  final hasFolder = nodes.any((n) => n.isDir);
  final ok = await confirm(
    context,
    title: 'Delete $what?',
    message: hasFolder
        ? 'Folders are deleted with everything inside them. This can\'t be undone.'
        : 'This can\'t be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!ok) return false;
  await api.delete([for (final n in nodes) n.id]);
  if (context.mounted) showMessage(context, 'Deleted $what');
  return true;
}

/// Menu entries for one item.
List<PopupMenuEntry<NodeAction>> nodeMenuItems(Node node) {
  PopupMenuItem<NodeAction> item(NodeAction a, IconData icon, String label) => PopupMenuItem(
    value: a,
    child: ListTile(leading: Icon(icon), title: Text(label), contentPadding: EdgeInsets.zero),
  );
  return [
    if (node.isDir)
      item(NodeAction.open, Icons.folder_open_outlined, 'Open')
    else if (node.previewable)
      item(NodeAction.open, Icons.visibility_outlined, 'Preview'),
    if (!node.isDir) item(NodeAction.openWith, Icons.open_in_new, 'Open with…'),
    item(NodeAction.save, Icons.ios_share, node.isDir ? 'Download as zip' : 'Save / send'),
    if (node.isDir || node.kind == 'audio')
      item(NodeAction.playlist, Icons.playlist_add, node.isDir ? 'Add its audio to playlist' : 'Add to playlist'),
    item(NodeAction.link, Icons.link, node.share != null ? 'Share link…' : 'Share by link…'),
    const PopupMenuDivider(),
    item(NodeAction.rename, Icons.drive_file_rename_outline, 'Rename'),
    item(NodeAction.move, Icons.drive_file_move_outline, 'Move'),
    item(NodeAction.delete, Icons.delete_outline, 'Delete'),
  ];
}

/// Add the audio files among [nodes] to the end of the playlist. A folder adds
/// the audio files directly inside it, by name. (A new playlist is started by
/// clearing the old one on the playlist screen.)
Future<void> addToPlaylist(BuildContext context, List<Node> nodes) async {
  final app = context.read<AppState>();
  final playlist = app.nowPlaying?.playlist;
  if (playlist == null) return;
  final files = <Node>[];
  try {
    for (final n in nodes) {
      if (n.isDir) {
        final inside = (await app.api!.folder(n.id)).items.where((i) => !i.isDir && i.kind == 'audio').toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        files.addAll(inside);
      } else if (n.kind == 'audio') {
        files.add(n);
      }
    }
  } on ApiException catch (e) {
    if (context.mounted) showError(context, e.message);
    return;
  }
  if (!context.mounted) return;
  if (files.isEmpty) {
    showToast(
      context,
      icon: Icons.info_outline,
      nodes.any((n) => n.isDir) ? 'There are no audio files in there' : 'Only audio files can go in the playlist',
    );
    return;
  }

  final added = await playlist.add(files);
  final already = files.length - added;
  final String text;
  if (added == 0) {
    text = files.length == 1 ? 'Already in the playlist' : 'Those are all in the playlist already';
  } else {
    text = 'Added ${plural(added, 'file')} to the playlist${already > 0 ? ' ($already already in it)' : ''}';
  }
  if (context.mounted) {
    showToast(context, text, icon: added == 0 ? Icons.info_outline : Icons.playlist_add_check);
  }
}
