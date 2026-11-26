import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/now_playing.dart';
import '../widgets/audio_player_view.dart';

/// The full player for whatever is playing (follows the playlist as it moves
/// on). Opened from the mini player and the playlist.
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final node = context.select<NowPlaying, int?>((p) => p.node?.id) == null ? null : context.read<NowPlaying>().node;
    return Scaffold(
      appBar: AppBar(title: const Text('Now playing')),
      body: node == null
          ? const Center(child: Text('Nothing is playing'))
          : AudioPlayerView(node: node, api: context.read<AppState>().api!, follow: true),
    );
  }
}
