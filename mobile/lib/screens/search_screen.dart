import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../util/format.dart';
import '../widgets/file_icon.dart';
import '../widgets/node_actions.dart';

/// Search all of the user's files and folders by name.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<Node>? _results;
  String? _error;
  bool _loading = false;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    final generation = ++_generation;
    if (q.isEmpty) {
      setState(() {
        _results = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await context.read<AppState>().api!.search(q);
      if (mounted && generation == _generation) {
        setState(() {
          _results = results;
          _error = null;
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _changed,
          onSubmitted: (_) => _search(),
          decoration: const InputDecoration(hintText: 'Search files and folders', border: InputBorder.none),
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _query.clear();
                _search();
              },
            ),
        ],
        bottom: _loading
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : results == null
          ? const SizedBox.shrink()
          : results.isEmpty
          ? const Center(child: Text('Nothing found'))
          : ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, i) {
                final node = results[i];
                final where = (node.path == null || node.path == '/' || node.path!.isEmpty)
                    ? 'Home'
                    : 'Home${node.path}';
                return ListTile(
                  leading: SizedBox(width: 40, child: FileIcon(node.kind)),
                  title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('$where · ${nodeSubtitle(node)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: PopupMenuButton<NodeAction>(
                    tooltip: 'More',
                    itemBuilder: (_) => nodeMenuItems(node),
                    onSelected: (a) => runNodeAction(context, a, node, onChanged: _search),
                  ),
                  onTap: () => openNode(context, node, fromParent: false),
                );
              },
            ),
    );
  }
}
