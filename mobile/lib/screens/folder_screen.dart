import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/uploads.dart';
import '../util/file_actions.dart';
import '../util/format.dart';
import '../widgets/dialogs.dart';
import '../widgets/file_icon.dart';
import '../widgets/node_actions.dart';
import '../widgets/upload_banner.dart';
import 'account_screen.dart';
import 'playlist_screen.dart';
import 'search_screen.dart';

enum SortBy { name, date, size }

/// One folder, as a list like a file explorer. Each folder is its own page,
/// so the system Back gesture goes up a level.
class FolderScreen extends StatefulWidget {
  const FolderScreen({super.key, required this.folderId, this.isHome = false, this.openedFromParent = true});

  final int folderId;
  final bool isHome;

  /// True when the page below this one is the parent folder (so ".." can just go back).
  final bool openedFromParent;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  static SortBy sortBy = SortBy.name;
  static bool sortDescending = false;

  FolderListing? _listing;
  String? _error;
  final _selected = <int>{};
  late final UploadQueue _uploads;

  ApiClient get _api => context.read<AppState>().api!;

  @override
  void initState() {
    super.initState();
    _uploads = context.read<UploadQueue>();
    _uploads.addFinishedListener(_uploadFinished);
    _load();
  }

  @override
  void dispose() {
    _uploads.removeFinishedListener(_uploadFinished);
    super.dispose();
  }

  void _uploadFinished(int folderId) {
    if (folderId == widget.folderId && mounted) _load();
  }

  Future<void> _load() async {
    try {
      final listing = await _api.folder(widget.folderId);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _error = null;
        _selected.retainAll(listing.items.map((n) => n.id));
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  List<Node> get _items {
    final items = [...?_listing?.items];
    int compare(Node a, Node b) => switch (sortBy) {
      SortBy.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortBy.date => a.updatedAt.compareTo(b.updatedAt),
      SortBy.size => a.size.compareTo(b.size),
    };
    items.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final c = compare(a, b);
      return sortDescending ? -c : c;
    });
    return items;
  }

  List<Node> get _selectedNodes => _items.where((n) => _selected.contains(n.id)).toList();

  String get _title {
    if (widget.isHome || _listing?.folder.parentId == null) return 'Home';
    return _listing!.folder.name;
  }

  void _toggle(Node node) =>
      setState(() => _selected.contains(node.id) ? _selected.remove(node.id) : _selected.add(node.id));

  void _goUp() {
    final parentId = _listing?.folder.parentId;
    if (parentId == null) return;
    if (widget.openedFromParent && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => FolderScreen(folderId: parentId, openedFromParent: false)));
    }
  }

  // ------------------------------------------------------------ actions

  Future<void> _newFolder() async {
    final name = await promptText(context, title: 'New folder', label: 'Folder name', confirm: 'Create');
    if (name == null) return;
    try {
      await _api.createFolder(widget.folderId, name);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showError(context, e.message);
    }
  }

  Future<void> _upload() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles();
    } catch (e) {
      if (mounted) showError(context, 'Couldn\'t pick files: $e');
      return;
    }
    if (files.isEmpty || !mounted) return;
    final app = context.read<AppState>();
    final items = <UploadItem>[];
    for (final f in files) {
      final size = f.lengthSync() ?? await f.length() ?? 0;
      items.add(UploadItem(name: f.name, size: size, parentId: widget.folderId, open: f.readAsByteStream));
    }
    final max = app.config?.maxUploadBytes ?? 0;
    final tooBig = items.where((i) => max > 0 && i.size > max).toList();
    if (tooBig.isNotEmpty && mounted) {
      showError(context, '${tooBig.first.name} is larger than the ${formatSize(max)} upload limit');
      items.removeWhere(tooBig.contains);
    }
    if (items.isEmpty) return;
    // Check the quota before sending anything (the server checks again).
    try {
      final stats = await _api.stats();
      final quota = stats.quotaBytes;
      final needed = items.fold<int>(0, (t, i) => t + i.size) + _uploads.pendingBytes;
      if (quota != null && stats.usedBytes + needed > quota) {
        if (mounted) {
          showError(
            context,
            'Not enough space: you have ${formatSize((quota - stats.usedBytes).clamp(0, quota))} left of ${formatSize(quota)}',
          );
        }
        return;
      }
    } on ApiException {
      // Let the server decide.
    }
    _uploads.add(items);
  }

  void _showAddMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Upload files'),
              onTap: () {
                Navigator.pop(ctx);
                _upload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              onTap: () {
                Navigator.pop(ctx);
                _newFolder();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _bulk(Future<bool> Function(BuildContext, List<Node>) action) async {
    try {
      if (await action(context, _selectedNodes)) {
        setState(_selected.clear);
        await _load();
      }
    } on ApiException catch (e) {
      if (mounted) showError(context, e.message);
    }
  }

  void _openSort() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (s, label) in [(SortBy.name, 'Name'), (SortBy.date, 'Modified'), (SortBy.size, 'Size')])
              ListTile(
                title: Text(label),
                leading: Icon(sortBy == s ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                trailing: sortBy == s ? Icon(sortDescending ? Icons.arrow_downward : Icons.arrow_upward) : null,
                onTap: () {
                  setState(() {
                    if (sortBy == s) {
                      sortDescending = !sortDescending;
                    } else {
                      sortBy = s;
                      sortDescending = s != SortBy.name;
                    }
                  });
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ UI

  PreferredSizeWidget _appBar() {
    if (_selected.isNotEmpty) {
      final items = _items;
      return AppBar(
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => setState(_selected.clear),
        ),
        title: Text('${_selected.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Save / send',
            icon: const Icon(Icons.ios_share),
            onPressed: () => downloadAndShare(context, _api, _selectedNodes),
          ),
          IconButton(
            tooltip: 'Move',
            icon: const Icon(Icons.drive_file_move_outline),
            onPressed: () => _bulk(moveNodes),
          ),
          IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _bulk(deleteNodes)),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (action) async {
              switch (action) {
                case 'all':
                  setState(() => _selected.addAll(items.map((n) => n.id)));
                case 'playlist':
                  await addToPlaylist(context, _selectedNodes);
                  if (mounted) setState(_selected.clear);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'all',
                child: ListTile(
                  leading: Icon(Icons.select_all),
                  title: Text('Select all'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'playlist',
                child: ListTile(
                  leading: Icon(Icons.playlist_add),
                  title: Text('Add to playlist'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      );
    }
    final crumbs = _listing?.breadcrumb ?? const <Crumb>[];
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (crumbs.length > 1)
            Text(
              ['Home', ...crumbs.skip(1).map((c) => c.name)].join(' / '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Search',
          icon: const Icon(Icons.search),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
        ),
        IconButton(
          tooltip: 'Playlist',
          icon: const Icon(Icons.queue_music),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaylistScreen())),
        ),
        IconButton(tooltip: 'Sort', icon: const Icon(Icons.sort), onPressed: _openSort),
        IconButton(
          tooltip: 'Account',
          icon: const Icon(Icons.account_circle_outlined),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
        ),
      ],
    );
  }

  Widget _body() {
    if (_listing == null) {
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
              ],
            ),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final items = _items;
    final hasParent = _listing!.folder.parentId != null;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: items.length + (hasParent ? 1 : 0) + (items.isEmpty ? 1 : 0),
        itemBuilder: (context, index) {
          if (hasParent) {
            if (index == 0) {
              return ListTile(
                leading: const SizedBox(width: 40, child: Icon(Icons.arrow_upward)),
                title: const Text('..'),
                subtitle: const Text('Up one level'),
                onTap: _selected.isEmpty ? _goUp : null,
              );
            }
            index--;
          }
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                children: [
                  Icon(Icons.folder_open, size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 8),
                  const Text('This folder is empty'),
                  const SizedBox(height: 4),
                  const Text('Tap + to upload files or make a folder'),
                ],
              ),
            );
          }
          return _row(items[index], items);
        },
      ),
    );
  }

  Widget _row(Node node, List<Node> items) {
    final selecting = _selected.isNotEmpty;
    final selected = _selected.contains(node.id);
    return ListTile(
      key: ValueKey(node.id),
      selected: selected,
      leading: SizedBox(
        width: 40,
        child: selecting ? Checkbox(value: selected, onChanged: (_) => _toggle(node)) : FileIcon(node.kind),
      ),
      title: Row(
        children: [
          Flexible(child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (node.share != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: node.share == 'readwrite' ? 'Shared (view & upload)' : 'Shared by link',
              child: Icon(Icons.link, size: 16, color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ],
      ),
      subtitle: Text(nodeSubtitle(node)),
      trailing: selecting
          ? null
          : PopupMenuButton<NodeAction>(
              tooltip: 'More',
              itemBuilder: (_) => nodeMenuItems(node),
              onSelected: (a) => runNodeAction(context, a, node, siblings: items, onChanged: _load),
            ),
      onTap: selecting ? () => _toggle(node) : () => openNode(context, node, siblings: items).then((_) => _load()),
      onLongPress: () => _toggle(node),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _appBar(),
        body: _body(),
        floatingActionButton: _selected.isEmpty && _listing != null
            ? FloatingActionButton(tooltip: 'Add', onPressed: _showAddMenu, child: const Icon(Icons.add))
            : null,
        bottomNavigationBar: const UploadBanner(),
      ),
    );
  }
}
