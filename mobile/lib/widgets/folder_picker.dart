import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'file_icon.dart';

/// Choose a destination folder for a move. Returns the folder id, or null.
///
/// [excluded] are the folders being moved: they (and everything inside them)
/// can't be chosen.
Future<int?> pickFolder(BuildContext context, {required String title, Set<int> excluded = const {}}) {
  return Navigator.of(context).push<int>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FolderPicker(title: title, excluded: excluded),
    ),
  );
}

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.title, required this.excluded});

  final String title;
  final Set<int> excluded;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  List<FolderRef>? _folders;
  String? _error;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = context.read<AppState>().user!.rootId;
    _load();
  }

  Future<void> _load() async {
    try {
      final folders = await context.read<AppState>().api!.allFolders();
      if (mounted) setState(() => _folders = folders);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  FolderRef? _byId(int id) => _folders!.where((f) => f.id == id).firstOrNull;

  List<FolderRef> get _path {
    final path = <FolderRef>[];
    FolderRef? f = _byId(_current);
    while (f != null) {
      path.insert(0, f);
      f = f.parentId == null ? null : _byId(f.parentId!);
    }
    return path;
  }

  bool get _currentAllowed => !_path.any((f) => widget.excluded.contains(f.id));

  @override
  Widget build(BuildContext context) {
    final root = context.read<AppState>().user!.rootId;
    final folders = _folders;
    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    } else if (folders == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final children = folders.where((f) => f.parentId == _current).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final path = _path;
      body = Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final (i, f) in path.indexed) ...[
                  if (i > 0) const Icon(Icons.chevron_right, size: 18),
                  TextButton(
                    onPressed: () => setState(() => _current = f.id),
                    child: Text(f.id == root ? 'Home' : f.name),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                if (_current != root)
                  ListTile(
                    leading: const Icon(Icons.arrow_upward),
                    title: const Text('..'),
                    onTap: () => setState(() => _current = _byId(_current)!.parentId!),
                  ),
                for (final f in children)
                  ListTile(
                    enabled: !widget.excluded.contains(f.id),
                    leading: const FileIcon('folder'),
                    title: Text(f.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _current = f.id),
                  ),
                if (children.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('No folders here')),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: body,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: folders != null && _currentAllowed ? () => Navigator.pop(context, _current) : null,
            child: const Text('Move here'),
          ),
        ),
      ),
    );
  }
}
