import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../screens/now_playing_screen.dart';
import '../state/now_playing.dart';
import 'audio_player_view.dart';
import 'file_icon.dart';

/// A bar under every screen while audio is playing or paused: what's playing,
/// play/pause and close. Tap it to open the full player.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.navigator});

  /// The app's navigator (this bar sits outside it).
  final GlobalKey<NavigatorState> navigator;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<NowPlaying>();
    final node = player.node;
    // Hidden while the keyboard is up, too.
    if (!player.showMiniPlayer || node == null || MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final duration = player.duration;
    final progress = duration == null || duration.inMilliseconds == 0
        ? 0.0
        : (player.position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: InkWell(
          onTap: () => navigator.currentState?.push(MaterialPageRoute(builder: (_) => const NowPlayingScreen())),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress, minHeight: 2),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                child: Row(
                  children: [
                    const FileIcon('audio'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            player.error ??
                                (player.reconnecting ? 'Reconnecting…' : null) ??
                                '${formatTime(player.position)}'
                                    '${duration == null ? '' : ' / ${formatTime(duration)}'}'
                                    '${player.speed == 1 ? '' : ' · ${formatSpeed(player.speed)}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: player.error != null
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // No tooltips: this bar is outside the navigator's overlay. The
                    // labels are for screen readers.
                    Semantics(
                      button: true,
                      label: player.playing ? 'Pause' : 'Play',
                      child: IconButton(
                        icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
                        onPressed: player.error != null ? null : player.toggle,
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Close player',
                      child: IconButton(icon: const Icon(Icons.close), onPressed: player.stop),
                    ),
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
