import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/now_playing.dart';
import '../state/playlist.dart';
import '../util/format.dart';
import '../widgets/audio_player_view.dart' show formatTime;
import '../widgets/dialogs.dart';
import '../widgets/toast.dart';
import 'now_playing_screen.dart';

/// The audio playlist: play, reorder (drag), shuffle, remove (swipe) and clear.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  /// Saved positions, read once per file (refreshed when the playing file changes).
  final _saved = <int, Future<Duration?>>{};
  int? _savedFor;

  Future<void> _play(PlaylistEntry? entry) async {
    final app = context.read<AppState>();
    final navigator = Navigator.of(context);
    await app.nowPlaying!.playPlaylist(app.api!, entry: entry);
    navigator.push(MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
  }

  Future<void> _startAllFromBeginning(Playlist playlist) async {
    final ok = await confirm(
      context,
      title: 'Start all from the beginning?',
      message:
          'This forgets where you stopped in each of the ${plural(playlist.length, 'file')} in the playlist, '
          'so they all play from the start.',
      confirmLabel: 'Start from the beginning',
    );
    if (!ok || !mounted) return;
    await context.read<NowPlaying>().forgetPositions(playlist.entries.map((e) => e.id));
    if (!mounted) return;
    setState(_saved.clear); // re-read the (now forgotten) positions
    showToast(context, 'All files will start from the beginning', icon: Icons.restart_alt);
  }

  Future<void> _clear(Playlist playlist) async {
    final ok = await confirm(
      context,
      title: 'Clear the playlist?',
      message:
          'This removes all ${plural(playlist.length, 'file')} from the playlist, so you can start a new one. '
          'The files themselves aren\'t deleted.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (ok) await playlist.clear();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<Playlist>();
    final player = context.watch<NowPlaying>();
    final theme = Theme.of(context);
    final entries = playlist.entries;
    final current = playlist.current;
    if (_savedFor != player.node?.id) {
      _saved.clear();
      _savedFor = player.node?.id;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(entries.isEmpty ? 'Playlist' : 'Playlist (${entries.length})'),
        actions: [
          IconButton(
            tooltip: 'Shuffle',
            icon: const Icon(Icons.shuffle),
            onPressed: entries.length < 2
                ? null
                : () async {
                    await playlist.shuffle();
                    if (context.mounted) showToast(context, 'Shuffled', icon: Icons.shuffle);
                  },
          ),
          IconButton(
            tooltip: 'Clear playlist',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: entries.isEmpty ? null : () => _clear(playlist),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            enabled: entries.isNotEmpty,
            onSelected: (action) {
              if (action == 'restart') _startAllFromBeginning(playlist);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'restart',
                child: ListTile(
                  leading: Icon(Icons.restart_alt),
                  title: Text('Start all from the beginning'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: entries.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _play(null),
              icon: const Icon(Icons.play_arrow),
              label: Text(player.inPlaylist ? 'Now playing' : (current == entries.first ? 'Play' : 'Continue')),
            ),
      body: entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.queue_music, size: 56),
                    SizedBox(height: 12),
                    Text('The playlist is empty', textAlign: TextAlign.center),
                    SizedBox(height: 4),
                    Text(
                      'Add audio files with "Add to playlist" in a file\'s or folder\'s ⋮ menu.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: entries.length,
              onReorderItem: playlist.move,
              itemBuilder: (context, i) {
                final e = entries[i];
                final isPlaying = player.node?.id == e.id;
                final isCurrent = current?.id == e.id;
                final saved = _saved.putIfAbsent(e.id, () => player.savedPosition(e.id));
                return Dismissible(
                  key: ValueKey(e.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: theme.colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: Icon(Icons.remove_circle_outline, color: theme.colorScheme.onErrorContainer),
                  ),
                  onDismissed: (_) {
                    playlist.remove(e.id);
                    // The row is gone by now, so use the screen's context.
                    showToast(this.context, 'Removed "${e.name}" from the playlist', icon: Icons.playlist_remove);
                  },
                  child: ListTile(
                    selected: isCurrent,
                    leading: SizedBox(
                      width: 32,
                      child: Center(
                        child: isPlaying
                            ? Icon(player.playing ? Icons.graphic_eq : Icons.pause, color: theme.colorScheme.primary)
                            : Text('${i + 1}', style: theme.textTheme.titleSmall),
                      ),
                    ),
                    title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: isPlaying
                        ? Text('${player.playing ? 'Playing' : 'Paused'} · ${formatTime(player.position)}')
                        : FutureBuilder<Duration?>(
                            future: saved,
                            builder: (_, snap) => Text(
                              snap.data != null ? 'Continue from ${formatTime(snap.data!)}' : formatSize(e.size),
                            ),
                          ),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle)),
                    ),
                    onTap: () => _play(e),
                  ),
                );
              },
            ),
    );
  }
}
