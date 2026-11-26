import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/uploads.dart';
import '../util/format.dart';

/// A strip at the bottom of the file list while uploads run; tap for details.
class UploadBanner extends StatelessWidget {
  const UploadBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<UploadQueue>();
    if (queue.items.isEmpty) return const SizedBox.shrink();
    final active = queue.active;
    final failed = queue.items.where((i) => i.status == UploadStatus.failed).length;
    final theme = Theme.of(context);
    final String label;
    if (active.isNotEmpty) {
      label = 'Uploading ${plural(active.length, 'file')} · ${formatSize(queue.pendingBytes)} left';
    } else if (failed > 0) {
      label = '${plural(failed, 'upload')} failed';
    } else {
      label = 'Uploads complete';
    }
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => showUploadSheet(context),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active.isNotEmpty) LinearProgressIndicator(value: queue.overallProgress),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(
                      active.isNotEmpty
                          ? Icons.cloud_upload_outlined
                          : failed > 0
                          ? Icons.error_outline
                          : Icons.cloud_done_outlined,
                      color: failed > 0 && active.isEmpty ? theme.colorScheme.error : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(label)),
                    if (active.isEmpty)
                      IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close), onPressed: queue.clearFinished)
                    else
                      const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.expand_less)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void showUploadSheet(BuildContext context) {
  final queue = context.read<UploadQueue>();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => ChangeNotifierProvider.value(value: queue, child: const _UploadSheet()),
  );
}

class _UploadSheet extends StatelessWidget {
  const _UploadSheet();

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<UploadQueue>();
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: Text('Uploads', style: theme.textTheme.titleLarge)),
                if (queue.active.isNotEmpty) TextButton(onPressed: queue.cancelAll, child: const Text('Cancel all')),
                if (queue.items.any((i) => !i.active))
                  TextButton(onPressed: queue.clearFinished, child: const Text('Clear finished')),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                for (final item in queue.items.reversed)
                  ListTile(
                    title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: switch (item.status) {
                      UploadStatus.uploading => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: item.progress),
                          const SizedBox(height: 4),
                          Text('${formatSize(item.sent)} of ${formatSize(item.size)}'),
                        ],
                      ),
                      UploadStatus.queued => Text('Waiting · ${formatSize(item.size)}'),
                      UploadStatus.done => Text('Uploaded · ${formatSize(item.size)}'),
                      UploadStatus.cancelled => const Text('Cancelled'),
                      UploadStatus.failed => Text(
                        item.error ?? 'Failed',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    },
                    trailing: item.active
                        ? IconButton(
                            tooltip: 'Cancel',
                            icon: const Icon(Icons.close),
                            onPressed: () => queue.cancel(item),
                          )
                        : Icon(
                            switch (item.status) {
                              UploadStatus.done => Icons.check_circle,
                              UploadStatus.failed => Icons.error,
                              _ => Icons.remove_circle_outline,
                            },
                            color: switch (item.status) {
                              UploadStatus.done => Colors.green,
                              UploadStatus.failed => theme.colorScheme.error,
                              _ => theme.colorScheme.outline,
                            },
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
