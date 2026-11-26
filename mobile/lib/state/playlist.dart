import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import 'app_state.dart';

/// One file in the playlist (enough to show and play it without the server listing).
class PlaylistEntry {
  const PlaylistEntry({required this.id, required this.name, required this.size});

  final int id;
  final String name;
  final int size;

  factory PlaylistEntry.of(Node node) => PlaylistEntry(id: node.id, name: node.name, size: node.size);

  factory PlaylistEntry.fromJson(Map<String, dynamic> j) =>
      PlaylistEntry(id: j['id'] as int, name: j['name'] as String, size: (j['size'] as num?)?.toInt() ?? 0);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'size': size};

  Node toNode() => Node(
    id: id,
    parentId: null,
    name: name,
    isDir: false,
    size: size,
    mimeType: null,
    kind: 'audio',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// The user's one audio playlist, kept on the device (per server and account),
/// with the file they were last on.
class Playlist extends ChangeNotifier {
  Playlist(this.storage, {required this.scope});

  final AppStorage storage;
  final String scope;

  final _entries = <PlaylistEntry>[];
  int? _currentId;

  String get _key => 'playlist:$scope';

  List<PlaylistEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  int get length => _entries.length;

  /// The file last played from the playlist (where "Play" continues from).
  PlaylistEntry? get current => _entries.where((e) => e.id == _currentId).firstOrNull ?? _entries.firstOrNull;
  int get currentIndex => current == null ? -1 : _entries.indexOf(current!);

  bool contains(int fileId) => _entries.any((e) => e.id == fileId);

  PlaylistEntry? after(int fileId) {
    final i = _entries.indexWhere((e) => e.id == fileId);
    return i >= 0 && i + 1 < _entries.length ? _entries[i + 1] : null;
  }

  PlaylistEntry? before(int fileId) {
    final i = _entries.indexWhere((e) => e.id == fileId);
    return i > 0 ? _entries[i - 1] : null;
  }

  Future<void> load() async {
    final raw = await storage.read(_key);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _entries
        ..clear()
        ..addAll([for (final e in data['entries'] as List) PlaylistEntry.fromJson(e as Map<String, dynamic>)]);
      _currentId = data['current'] as int?;
      notifyListeners();
    } catch (_) {
      // Unreadable: start again.
    }
  }

  Future<void> _changed() async {
    notifyListeners();
    await storage.write(
      _key,
      _entries.isEmpty
          ? null
          : jsonEncode({
              'entries': [for (final e in _entries) e.toJson()],
              'current': _currentId,
            }),
    );
  }

  /// Add audio [files] to the end, skipping ones already there. Returns how many were added.
  Future<int> add(Iterable<Node> files) async {
    var added = 0;
    for (final f in files) {
      if (f.isDir || f.kind != 'audio' || contains(f.id)) continue;
      _entries.add(PlaylistEntry.of(f));
      added++;
    }
    if (added > 0) await _changed();
    return added;
  }

  Future<void> setCurrent(int fileId) async {
    if (_currentId == fileId || !contains(fileId)) return;
    _currentId = fileId;
    await _changed();
  }

  Future<void> remove(int fileId) async {
    _entries.removeWhere((e) => e.id == fileId);
    if (_currentId == fileId) _currentId = null;
    await _changed();
  }

  /// Move the entry at [from] so it ends up at index [to].
  Future<void> move(int from, int to) async {
    if (from == to) return;
    final entry = _entries.removeAt(from);
    _entries.insert(to.clamp(0, _entries.length), entry);
    await _changed();
  }

  /// Random order. The file you're on moves to the top, so playback carries on
  /// through the new order from there.
  Future<void> shuffle([Random? random]) async {
    final keep = current;
    _entries.shuffle(random);
    if (keep != null && _currentId != null) {
      _entries
        ..remove(keep)
        ..insert(0, keep);
    }
    await _changed();
  }

  Future<void> clear() async {
    _entries.clear();
    _currentId = null;
    await _changed();
  }
}
