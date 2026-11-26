import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/file_icon.dart';
import '../widgets/share_sheet.dart';
import 'folder_screen.dart';

/// Everything the user shares by link.
class SharesScreen extends StatefulWidget {
  const SharesScreen({super.key});

  @override
  State<SharesScreen> createState() => _SharesScreenState();
}

class _SharesScreenState extends State<SharesScreen> {
  List<ShareInfo>? _shares;
  String? _error;

  ApiClient get _api => context.read<AppState>().api!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final shares = await _api.shares();
      if (mounted) {
        setState(() {
          _shares = shares;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  String _where(ShareInfo s) => s.path.isEmpty || s.path == '/' ? 'Home' : 'Home${s.path}';

  @override
  Widget build(BuildContext context) {
    final shares = _shares;
    return Scaffold(
      appBar: AppBar(title: const Text('Shared links')),
      body: shares == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: shares.isEmpty
                  ? ListView(
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(48),
                          child: Text(
                            'You aren\'t sharing anything yet. Use "Share by link" in a file\'s menu.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      itemCount: shares.length,
                      itemBuilder: (context, i) {
                        final s = shares[i];
                        final mode = s.isDir ? (s.mode == 'readwrite' ? 'View & upload' : 'View only') : 'Link';
                        return ListTile(
                          leading: SizedBox(width: 40, child: FileIcon(s.isDir ? 'folder' : s.kind)),
                          title: Row(
                            children: [
                              Flexible(child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                              if (s.hasPassword) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.lock_outline, size: 16),
                              ],
                            ],
                          ),
                          subtitle: Text('$mode · ${_where(s)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'More',
                            onSelected: (a) async {
                              switch (a) {
                                case 'copy':
                                  await Clipboard.setData(ClipboardData(text: _api.shareLink(s)));
                                  if (context.mounted) showMessage(context, 'Link copied');
                                case 'show':
                                  final folder = s.isDir ? s.nodeId : s.parentId;
                                  if (folder != null) {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => FolderScreen(folderId: folder, openedFromParent: false),
                                      ),
                                    );
                                  }
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'copy', child: Text('Copy link')),
                              PopupMenuItem(value: 'show', child: Text(s.isDir ? 'Open folder' : 'Show in folder')),
                            ],
                          ),
                          onTap: () async {
                            if (await showShareSheet(context, nodeId: s.nodeId, name: s.name, isDir: s.isDir)) _load();
                          },
                        );
                      },
                    ),
            ),
    );
  }
}
