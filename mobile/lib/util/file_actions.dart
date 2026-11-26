import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../widgets/dialogs.dart';
import 'format.dart';

/// Download [nodes] into the app's cache with a progress dialog: a single file
/// as itself, folders or several items as one zip. Returns the local path, or
/// null if cancelled or failed (the error is shown).
Future<String?> downloadToDevice(BuildContext context, ApiClient api, List<Node> nodes) async {
  final single = nodes.length == 1 && !nodes.first.isDir;
  final name = single
      ? nodes.first.name
      : nodes.length == 1
      ? '${nodes.first.name}.zip'
      : 'Download.zip';
  final dir = Directory('${(await getTemporaryDirectory()).path}/downloads/${DateTime.now().microsecondsSinceEpoch}');
  await dir.create(recursive: true);
  final path = '${dir.path}/${name.replaceAll('/', '_')}';
  final cancel = CancelToken();
  final progress = ValueNotifier<(int, int)>((0, single ? nodes.first.size : -1));
  if (!context.mounted) return null;

  final done = api
      .downloadTo(
        path,
        fileId: single ? nodes.first.id : null,
        zipIds: single ? null : [for (final n in nodes) n.id],
        cancelToken: cancel,
        onProgress: (received, total) => progress.value = (received, total),
      )
      .then((_) => true);

  var dialogOpen = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text('Downloading $name', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: ValueListenableBuilder<(int, int)>(
        valueListenable: progress,
        builder: (_, value, _) {
          final (received, total) = value;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: total > 0 ? received / total : null),
              const SizedBox(height: 8),
              Text(total > 0 ? '${formatSize(received)} of ${formatSize(total)}' : formatSize(received)),
            ],
          );
        },
      ),
      actions: [TextButton(onPressed: () => cancel.cancel(), child: const Text('Cancel'))],
    ),
  ).then((_) => dialogOpen = false);

  try {
    await done;
    return path;
  } on ApiException catch (e) {
    if (context.mounted && !cancel.isCancelled) showError(context, e.message);
    return null;
  } finally {
    if (dialogOpen && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Open a downloaded file in another app ("Open with…").
Future<void> openWithOtherApp(BuildContext context, String path) async {
  final result = await OpenFilex.open(path);
  if (result.type != ResultType.done && context.mounted) {
    showError(
      context,
      result.type == ResultType.noAppToOpen
          ? 'No app on this device can open this file. Try Share instead.'
          : 'Couldn\'t open the file: ${result.message}',
    );
  }
}

/// Hand a downloaded file to the system share sheet (also offers "Save to Files" etc.).
Future<void> shareFile(String path, {Rect? origin}) =>
    SharePlus.instance.share(ShareParams(files: [XFile(path)], sharePositionOrigin: origin));

/// Download, then open in another app.
Future<void> downloadAndOpen(BuildContext context, ApiClient api, Node node) async {
  final path = await downloadToDevice(context, api, [node]);
  if (path != null && context.mounted) await openWithOtherApp(context, path);
}

/// Download, then share / save.
Future<void> downloadAndShare(BuildContext context, ApiClient api, List<Node> nodes) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  final path = await downloadToDevice(context, api, nodes);
  if (path != null) await shareFile(path, origin: origin);
}
