import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/now_playing.dart';
import '../util/file_actions.dart';
import '../util/format.dart';
import '../widgets/audio_player_view.dart';

/// Full-screen preview of images, video, audio and text. Swipe for the
/// next/previous file in the folder. Videos fill the whole screen when the
/// phone is turned sideways.
class PreviewScreen extends StatefulWidget {
  const PreviewScreen({super.key, required this.files, required this.initial});

  final List<Node> files;
  final int initial;

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late final PageController _pages = PageController(initialPage: widget.initial.clamp(0, widget.files.length - 1));
  late int _index = widget.initial.clamp(0, widget.files.length - 1);

  /// Whether the system status and navigation bars are currently hidden.
  bool _immersive = false;

  @override
  void dispose() {
    if (_immersive) _setImmersive(false);
    _pages.dispose();
    super.dispose();
  }

  void _setImmersive(bool on) {
    _immersive = on;
    SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api!;
    final node = widget.files[_index];
    final fullscreen = node.kind == 'video' && MediaQuery.orientationOf(context) == Orientation.landscape;
    if (fullscreen != _immersive) _setImmersive(fullscreen);
    return Scaffold(
      backgroundColor: fullscreen ? Colors.black : null,
      appBar: fullscreen
          ? null
          : AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    widget.files.length > 1
                        ? '${formatSize(node.size)} · ${_index + 1} of ${widget.files.length}'
                        : formatSize(node.size),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: 'Open with…',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => downloadAndOpen(context, api, node),
                ),
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Save / send',
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => downloadAndShare(context, api, [node]),
                  ),
                ),
              ],
            ),
      body: PageView.builder(
        controller: _pages,
        // No swiping to the next file while a video fills the screen.
        physics: fullscreen ? const NeverScrollableScrollPhysics() : null,
        itemCount: widget.files.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) =>
            _Page(node: widget.files[i], api: api, active: i == _index, fullscreen: fullscreen && i == _index),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.node, required this.api, required this.active, required this.fullscreen});

  final Node node;
  final ApiClient api;
  final bool active;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    return switch (node.kind) {
      'image' => InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.network(
            api.contentUrl(node.id).toString(),
            headers: api.mediaHeaders,
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : const Center(child: CircularProgressIndicator()),
            errorBuilder: (_, _, _) => const _Message('This image can\'t be shown'),
          ),
        ),
      ),
      'video' => active ? _MediaPlayer(node: node, api: api, fullscreen: fullscreen) : const SizedBox.shrink(),
      'audio' => active ? AudioPlayerView(node: node, api: api) : const SizedBox.shrink(),
      'text' => _TextPreview(node: node, api: api),
      _ => const _Message('No preview for this file'),
    };
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
  );
}

class _TextPreview extends StatefulWidget {
  const _TextPreview({required this.node, required this.api});
  final Node node;
  final ApiClient api;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  static const _limit = 1024 * 1024;
  late final Future<String> _text = widget.api.textStart(widget.node.id, limit: _limit);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<String>(
      future: _text,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _Message(snapshot.error.toString());
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  snapshot.data!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (widget.node.size > _limit) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Showing the first ${formatSize(_limit)} of ${formatSize(widget.node.size)}',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Plays video, streamed from the server. (Audio has its own player,
/// [AudioPlayerView], which keeps playing in the background.)
///
/// Portrait: the video with the controls underneath. Full screen (a video in
/// landscape): the video fills the screen and the controls float over it,
/// appearing on tap and fading out while it plays.
class _MediaPlayer extends StatefulWidget {
  const _MediaPlayer({required this.node, required this.api, required this.fullscreen});
  final Node node;
  final ApiClient api;
  final bool fullscreen;

  @override
  State<_MediaPlayer> createState() => _MediaPlayerState();
}

class _MediaPlayerState extends State<_MediaPlayer> {
  static const _hideAfter = Duration(seconds: 3);

  late final VideoPlayerController _controller;
  String? _error;

  /// Full screen: whether the floating controls are showing.
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// Full screen: fill the screen by cropping, instead of fitting the whole picture.
  bool _zoom = false;

  /// Brings the mini player back when the video closes.
  VoidCallback? _showMiniPlayer;

  @override
  void initState() {
    super.initState();
    // One thing at a time: pause any audio, and keep its mini player out of the way.
    final audio = context.read<NowPlaying?>();
    audio?.pause();
    _showMiniPlayer = audio?.hideMiniPlayer();
    _controller = VideoPlayerController.networkUrl(
      widget.api.contentUrl(widget.node.id),
      httpHeaders: widget.api.mediaHeaders,
    );
    _controller.initialize().then(
      (_) {
        if (!mounted) return;
        setState(() {});
        _controller.play();
        _scheduleHide();
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = 'This file can\'t be played on this device');
      },
    );
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(_MediaPlayer old) {
    super.didUpdateWidget(old);
    if (widget.fullscreen != old.fullscreen) {
      // Show the controls briefly after turning the phone, so you can see where they are.
      _controlsVisible = true;
      _scheduleHide();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _showMiniPlayer?.call();
    _hideTimer?.cancel();
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  /// Hide the floating controls after a few seconds, but only while playing.
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.fullscreen || !_controller.value.isPlaying) return;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted && _controller.value.isPlaying) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _playPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
      _hideTimer?.cancel();
      setState(() => _controlsVisible = true);
    } else {
      _controller.play().then((_) => _scheduleHide());
    }
  }

  String _time(Duration d) {
    final s = d.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
  }

  /// Play/pause, times and the seek bar, plus [extra] buttons at the end.
  Widget _controls({Color? color, List<Widget> extra = const []}) {
    final value = _controller.value;
    final text = TextStyle(color: color);
    return Row(
      children: [
        IconButton(
          iconSize: 36,
          color: color,
          tooltip: value.isPlaying ? 'Pause' : 'Play',
          icon: Icon(value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill),
          onPressed: _playPause,
        ),
        Text(_time(value.position), style: text),
        Expanded(
          child: Slider(
            value: value.position.inMilliseconds.clamp(0, value.duration.inMilliseconds).toDouble(),
            max: value.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
            onChangeStart: (_) => _hideTimer?.cancel(),
            onChanged: (ms) => _controller.seekTo(Duration(milliseconds: ms.round())),
            onChangeEnd: (_) => _scheduleHide(),
          ),
        ),
        Text(_time(value.duration), style: text),
        ...extra,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _Message(_error!);
    final value = _controller.value;
    if (!value.isInitialized) return const Center(child: CircularProgressIndicator());
    if (widget.fullscreen) return _fullscreen(context);

    return Column(
      children: [
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: _playPause,
              child: AspectRatio(aspectRatio: value.aspectRatio, child: VideoPlayer(_controller)),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(padding: const EdgeInsets.fromLTRB(8, 0, 16, 8), child: _controls()),
        ),
      ],
    );
  }

  Widget _fullscreen(BuildContext context) {
    final value = _controller.value;
    final size = value.size;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTap: () => setState(() => _zoom = !_zoom),
          child: FittedBox(
            fit: _zoom ? BoxFit.cover : BoxFit.contain,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(_controller)),
          ),
        ),
        IgnorePointer(
          ignoring: !_controlsVisible,
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: Theme(
              data: ThemeData(
                colorScheme: const ColorScheme.dark(
                  primary: Colors.white,
                  onPrimary: Colors.black,
                  secondaryContainer: Colors.white38, // seek bar, unplayed part
                  surfaceContainerHighest: Colors.white38,
                ),
              ),
              child: Column(
                children: [
                  // Top: back and the file name.
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black54, Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          const BackButton(color: Colors.white),
                          Expanded(
                            child: Text(
                              widget.node.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Bottom: play/pause, seek bar, zoom.
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black54, Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                        child: _controls(
                          color: Colors.white,
                          extra: [
                            IconButton(
                              color: Colors.white,
                              tooltip: _zoom ? 'Fit to screen' : 'Zoom to fill',
                              icon: Icon(_zoom ? Icons.fit_screen : Icons.zoom_out_map),
                              onPressed: () {
                                setState(() => _zoom = !_zoom);
                                _scheduleHide();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
