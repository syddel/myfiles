import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../audio/service_backend.dart' show fastForwardInterval, rewindInterval;
import '../screens/now_playing_screen.dart';
import '../screens/playlist_screen.dart';
import '../state/now_playing.dart';
import '../state/playlist.dart';
import 'node_actions.dart' show addToPlaylist;

String formatTime(Duration d) {
  final s = d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

String formatSpeed(double speed) => '${speed.toString().replaceAll(RegExp(r'\.0$'), '')}×';

/// The full audio player. In a preview it starts [node] playing (or shows it
/// if it already is); with [follow] it shows whatever is playing, moving on
/// with the playlist. Playback carries on after leaving the screen.
class AudioPlayerView extends StatefulWidget {
  const AudioPlayerView({super.key, required this.node, required this.api, this.follow = false});

  final Node node;
  final ApiClient api;
  final bool follow;

  @override
  State<AudioPlayerView> createState() => _AudioPlayerViewState();
}

class _AudioPlayerViewState extends State<AudioPlayerView> {
  late final NowPlaying _player = context.read<NowPlaying>();
  late final VoidCallback _showMiniPlayer;

  /// While dragging the seek bar: where the thumb is.
  double? _dragging;

  @override
  void initState() {
    super.initState();
    _showMiniPlayer = _player.hideMiniPlayer();
    if (!widget.follow) _player.playFile(widget.api, widget.node);
  }

  @override
  void dispose() {
    _showMiniPlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<NowPlaying>();
    final playlist = context.watch<Playlist>();
    final theme = Theme.of(context);
    final node = widget.follow ? (player.node ?? widget.node) : widget.node;
    final current = player.node?.id == node.id;
    // In a preview, the playlist may have moved on to another file.
    final elsewhere = !widget.follow && player.node != null && !current ? player.node : null;
    final position = current ? player.position : Duration.zero;
    final duration = current ? player.duration : null;
    final error = current ? player.error : null;
    final resumed = current ? player.resumedFrom : null;
    final maxMs = (duration?.inMilliseconds ?? 0).toDouble();

    return SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(Icons.music_note_rounded, size: 96, color: theme.colorScheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      node.name,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (current && player.reconnecting) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Lost the connection to the server. Reconnecting…',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        error,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    if (elsewhere != null) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.graphic_eq),
                          title: Text('Now playing: ${elsewhere.name}', maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () =>
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NowPlayingScreen())),
                        ),
                      ),
                    ],
                    if (resumed != null) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.center,
                        children: [
                          Text(
                            'Continuing from ${formatTime(resumed)}',
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                          ),
                          TextButton(onPressed: player.startOver, child: const Text('Start over')),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Slider(
              value: (_dragging ?? position.inMilliseconds.toDouble()).clamp(0, maxMs > 0 ? maxMs : 1),
              max: maxMs > 0 ? maxMs : 1,
              onChanged: maxMs > 0 ? (v) => setState(() => _dragging = v) : null,
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                player.seek(Duration(milliseconds: v.round()));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(
              children: [
                Text(formatTime(_dragging != null ? Duration(milliseconds: _dragging!.round()) : position)),
                const Spacer(),
                Text(duration == null ? '--:--' : formatTime(duration)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                PopupMenuButton<double>(
                  tooltip: 'Playback speed',
                  initialValue: player.speed,
                  onSelected: player.setSpeed,
                  itemBuilder: (_) => [
                    for (final s in NowPlaying.speeds) PopupMenuItem(value: s, child: Text(formatSpeed(s))),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(formatSpeed(player.speed), style: theme.textTheme.titleMedium),
                  ),
                ),
                IconButton(
                  iconSize: 36,
                  tooltip: 'Back ${rewindInterval.inSeconds} seconds',
                  icon: const Icon(Icons.replay_10),
                  onPressed: current ? () => player.skip(-rewindInterval) : null,
                ),
                SizedBox(
                  width: 72,
                  height: 72,
                  child: current && player.loading && !player.playing
                      ? const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator())
                      : IconButton.filled(
                          iconSize: 40,
                          tooltip: current && player.playing ? 'Pause' : 'Play',
                          icon: Icon(current && player.playing ? Icons.pause : Icons.play_arrow),
                          onPressed: current ? player.toggle : () => player.playFile(widget.api, node),
                        ),
                ),
                IconButton(
                  iconSize: 36,
                  tooltip: 'Forward ${fastForwardInterval.inSeconds} seconds',
                  icon: const Icon(Icons.forward_30),
                  onPressed: current ? () => player.skip(fastForwardInterval) : null,
                ),
                IconButton(
                  tooltip: 'Playlist',
                  icon: const Icon(Icons.queue_music),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaylistScreen())),
                ),
              ],
            ),
          ),
          _playlistRow(context, player, playlist, node, current),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Previous / "2 of 5" / next while playing from the playlist; otherwise a
  /// way to add this file to it.
  Widget _playlistRow(BuildContext context, NowPlaying player, Playlist playlist, Node node, bool current) {
    final theme = Theme.of(context);
    if (current && player.inPlaylist) {
      final index = playlist.entries.indexWhere((e) => e.id == node.id);
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous in playlist',
            icon: const Icon(Icons.skip_previous),
            onPressed: player.previous,
          ),
          Text(
            '${index + 1} of ${playlist.length} in the playlist',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          IconButton(
            tooltip: 'Next in playlist',
            icon: const Icon(Icons.skip_next),
            onPressed: player.nextInPlaylist == null ? null : player.next,
          ),
        ],
      );
    }
    if (playlist.contains(node.id)) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('In the playlist', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return TextButton.icon(
      onPressed: () => addToPlaylist(context, [node]),
      icon: const Icon(Icons.playlist_add),
      label: const Text('Add to playlist'),
    );
  }
}
