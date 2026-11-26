import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'dialogs.dart';

/// Bottom sheet to share a file or folder by link. Returns true if sharing changed.
Future<bool> showShareSheet(
  BuildContext context, {
  required int nodeId,
  required String name,
  required bool isDir,
}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<AppState>(),
      child: _ShareSheet(nodeId: nodeId, name: name, isDir: isDir),
    ),
  );
  return changed ?? false;
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.nodeId, required this.name, required this.isDir});

  final int nodeId;
  final String name;
  final bool isDir;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  ShareInfo? _share;
  bool _loading = true;
  bool _busy = false;
  bool _changed = false;
  String? _error;

  ApiClient get _api => context.read<AppState>().api!;

  @override
  void initState() {
    super.initState();
    _api
        .getShare(widget.nodeId)
        .then(
          (s) {
            if (mounted) {
              setState(() {
                _share = s;
                _loading = false;
              });
            }
          },
          onError: (Object e) {
            if (mounted) {
              setState(() {
                _error = e.toString();
                _loading = false;
              });
            }
          },
        );
  }

  Future<void> _run(Future<ShareInfo?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await action();
      if (mounted) {
        setState(() {
          _share = s;
          _changed = true;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPassword() async {
    final password = await promptText(
      context,
      title: _share!.hasPassword ? 'Change password' : 'Set a password',
      label: 'Password for the link',
      confirm: 'Save',
    );
    if (password != null) await _run(() => _api.setSharePassword(widget.nodeId, password));
  }

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.stopSharing(widget.nodeId);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = _share;
    final link = share == null ? null : _api.shareLink(share);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Share "${widget.name}"',
                style: theme.textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              if (_loading)
                const Center(
                  child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
                )
              else if (share == null) ...[
                Text(
                  widget.isDir
                      ? 'Anyone with the link can open this folder, without an account.'
                      : 'Anyone with the link can view and download this file, without an account.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (widget.isDir) ...[
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _run(() => _api.setShare(widget.nodeId, 'read')),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('Share (view only)'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(() => _api.setShare(widget.nodeId, 'readwrite')),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Share (view & upload)'),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _run(() => _api.setShare(widget.nodeId, 'read')),
                    icon: const Icon(Icons.link),
                    label: const Text('Create link'),
                  ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: SelectableText(link!, maxLines: 2, style: theme.textTheme.bodySmall)),
                      IconButton(
                        tooltip: 'Copy link',
                        icon: const Icon(Icons.copy),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: link));
                          if (context.mounted) showMessage(context, 'Link copied');
                        },
                      ),
                    ],
                  ),
                ),
                if (widget.isDir) ...[
                  const SizedBox(height: 16),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'read', label: Text('View only'), icon: Icon(Icons.visibility_outlined)),
                      ButtonSegment(value: 'readwrite', label: Text('View & upload'), icon: Icon(Icons.edit_outlined)),
                    ],
                    selected: {share.mode},
                    onSelectionChanged: _busy ? null : (s) => _run(() => _api.setShare(widget.nodeId, s.first)),
                  ),
                ],
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(share.hasPassword ? Icons.lock_outline : Icons.lock_open_outlined),
                  title: Text(share.hasPassword ? 'Protected by a password' : 'No password'),
                  trailing: Wrap(
                    children: [
                      if (share.hasPassword)
                        TextButton(
                          onPressed: _busy ? null : () => _run(() => _api.setSharePassword(widget.nodeId, null)),
                          child: const Text('Remove'),
                        ),
                      TextButton(
                        onPressed: _busy ? null : _setPassword,
                        child: Text(share.hasPassword ? 'Change' : 'Set'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  onPressed: _busy ? null : _stop,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Stop sharing'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
