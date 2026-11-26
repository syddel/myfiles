import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_backend.dart';

/// Skip intervals for the in-app buttons, the notification and headset controls.
const rewindInterval = Duration(seconds: 10);
const fastForwardInterval = Duration(seconds: 30);

/// Real audio playback: just_audio for the player, audio_service to keep it
/// running in the background (an Android foreground service / the iOS
/// background audio mode) with notification and lock-screen controls.
class ServiceAudioBackend implements AudioBackend {
  ServiceAudioBackend._(this._handler) {
    _player.errorStream.listen(_onPlayerError);
    // Pause from the notification / headset while reconnecting: stop trying.
    _handler.onPauseWhileInterrupted = () => giveUp(null);
  }

  final _MediaHandler _handler;
  AudioPlayer get _player => _handler.player;
  String? _error;

  /// Counts [open] calls, so a load that was replaced by a newer one can't
  /// report its (abandoned) result as the current file's error.
  int _openCount = 0;
  bool _opening = false;

  /// Where playback was when it was interrupted.
  Duration _interruptedAt = Duration.zero;

  /// Start the background audio service. If that fails, audio still plays
  /// while the app is open, just not in the background.
  static Future<ServiceAudioBackend> start({String appName = 'MyFiles'}) async {
    final handler = _MediaHandler();
    try {
      await AudioService.init(
        builder: () => handler,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.myfiles.audio',
          androidNotificationChannelName: 'Audio playback',
          // Stay a foreground service while paused: resuming (e.g. after another
          // app's sound) then never has to restart it from the background, which
          // Android may refuse; and an app needs a foreground service to take the
          // audio focus from the background (Android 15+). NowPlaying releases the
          // service after a long pause. (An "ongoing" notification is only allowed
          // with androidStopForegroundOnPause.)
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          rewindInterval: rewindInterval,
          fastForwardInterval: fastForwardInterval,
        ),
      );
      // audio_service reports failures of its Android side (e.g. the service not
      // being able to enter the foreground) only on this stream; log them, so they
      // show up in `adb logcat` (tag "flutter") instead of disappearing.
      AudioService.asyncError.listen((Object e) => debugPrint('Background audio error: $e'));
    } catch (e) {
      debugPrint('Background audio unavailable: $e');
    }
    try {
      // Pause for phone calls and other apps' audio; pause when headphones are unplugged.
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('Audio session not configured: $e');
    }
    return ServiceAudioBackend._(handler);
  }

  @override
  Stream<void> get changes => _handler.playbackState.map((_) {});

  @override
  bool get interrupted => _handler.interrupted;
  @override
  bool get playing => interrupted || (_player.playing && _player.processingState != ProcessingState.completed);
  @override
  bool get loading =>
      interrupted ||
      _player.processingState == ProcessingState.loading ||
      _player.processingState == ProcessingState.buffering;
  @override
  bool get completed => !interrupted && _player.processingState == ProcessingState.completed;
  @override
  Duration get position => interrupted ? _interruptedAt : _player.position;
  @override
  Duration? get duration => _player.duration;
  @override
  double get speed => _player.speed;
  @override
  String? get error => _error;

  /// A failure after the file had loaded (a load failure is handled in [open]).
  void _onPlayerError(PlayerException e) {
    // (While paused, nothing to rescue: play loads the file again by itself.)
    if (_opening || _error != null || !_player.playing) return;
    debugPrint('Playback interrupted: ${e.code} ${e.message}');
    _interruptedAt = _player.position;
    _handler.interrupted = true;
    _handler.broadcast();
  }

  @override
  Future<void> open({
    required Uri url,
    required Map<String, String> headers,
    required String id,
    required String title,
    String? subtitle,
    Duration start = Duration.zero,
    double speed = 1,
    bool retry = false,
  }) async {
    final thisOpen = ++_openCount;
    _error = null;
    _opening = true;
    if (!retry) _handler.interrupted = false;
    _handler.mediaItem.add(MediaItem(id: id, title: title, album: subtitle));
    try {
      await _player.setSpeed(speed);
      final duration = await _player.setAudioSource(AudioSource.uri(url, headers: headers), initialPosition: start);
      if (thisOpen != _openCount) return;
      _handler.interrupted = false;
      _handler.mediaItem.add(MediaItem(id: id, title: title, album: subtitle, duration: duration));
    } on PlayerException catch (e) {
      if (thisOpen != _openCount) return; // replaced by a newer file: not its error
      if (retry) {
        // Still can't reach it: stay interrupted (the caller tries again later).
        _interruptedAt = start;
        _handler.interrupted = true;
      } else {
        _error = 'This file can\'t be played (${e.message ?? e.code})';
      }
    } on PlayerInterruptedException {
      // Another file was opened before this one finished loading.
    } finally {
      if (thisOpen == _openCount) _opening = false;
      _handler.broadcast();
    }
  }

  @override
  Future<void> giveUp(String? message) async {
    if (!_handler.interrupted) return;
    _handler.interrupted = false;
    _error = message;
    await _player.stop(); // releases the player; the background service ends with it
    _handler.broadcast();
  }

  @override
  Future<void> play() => _handler.play();
  @override
  Future<void> pause() => _handler.pause();
  @override
  Future<void> seek(Duration position) => _handler.seek(position);
  @override
  Future<void> setSpeed(double speed) => _handler.setSpeed(speed);
  @override
  Future<void> stop() {
    _handler.interrupted = false;
    return _handler.stop();
  }

  @override
  void setQueue({
    required bool hasPrevious,
    required bool hasNext,
    void Function()? onPrevious,
    void Function()? onNext,
  }) {
    _handler
      ..hasPrevious = hasPrevious
      ..hasNext = hasNext
      ..onPrevious = onPrevious
      ..onNext = onNext
      ..broadcast();
  }
}

/// What the notification, lock screen and headset buttons talk to.
class _MediaHandler extends BaseAudioHandler with SeekHandler {
  _MediaHandler() {
    player.playbackEventStream.listen((_) => broadcast(), onError: (Object _) => broadcast());
    player.playingStream.listen((_) => broadcast());
    player.speedStream.listen((_) => broadcast());
  }

  final player = AudioPlayer(
    // Native request headers (no local proxy): the session cookie goes straight to the server.
    useProxyForRequestHeaders: false,
    // Default buffering (about 50 seconds ahead). With a 10-minute buffer,
    // playback stopped ~10 minutes in with the screen off, i.e. when that
    // buffer ran out; the default lets a stalled connection show up sooner
    // while this is diagnosed.
  );

  /// Playback failed mid-file and the app is reconnecting: keep reporting
  /// "playing" so the background service (and its wake lock) stays up.
  bool interrupted = false;
  Future<void> Function()? onPauseWhileInterrupted;

  // Playlist: previous/next buttons and what they do.
  bool hasPrevious = false;
  bool hasNext = false;
  void Function()? onPrevious;
  void Function()? onNext;

  void broadcast() {
    final playing = player.playing || interrupted;
    _wifiLock.hold(playing);
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          if (hasPrevious) MediaControl.skipToPrevious,
          MediaControl.rewind,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          if (hasNext) MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
        // The compact notification shows rewind, play/pause and fast-forward.
        androidCompactActionIndices: hasPrevious ? const [1, 2, 3] : const [0, 1, 2],
        // While reconnecting, "buffering" rather than the player's "idle", which
        // would make audio_service stop the background service.
        processingState: interrupted
            ? AudioProcessingState.buffering
            : switch (player.processingState) {
                ProcessingState.idle => AudioProcessingState.idle,
                ProcessingState.loading => AudioProcessingState.loading,
                ProcessingState.buffering => AudioProcessingState.buffering,
                ProcessingState.ready => AudioProcessingState.ready,
                ProcessingState.completed => AudioProcessingState.completed,
              },
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  @override
  Future<void> play() async {
    // just_audio's play() completes only when playback stops, so don't wait for it.
    unawaited(player.play());
  }

  @override
  Future<void> pause() async {
    final giveUp = onPauseWhileInterrupted;
    if (interrupted && giveUp != null) return giveUp();
    await player.pause();
  }

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> setSpeed(double speed) => player.setSpeed(speed);

  @override
  Future<void> stop() async {
    interrupted = false;
    await player.stop();
    await super.stop();
  }

  /// Android: the app was swiped away. Keep playing if it is; otherwise clean up.
  @override
  Future<void> onTaskRemoved() async {
    if (!player.playing && !interrupted) await stop();
  }
}

/// Android: keeps Wi-Fi at full power while audio plays with the screen off
/// (what ExoPlayer's "network" wake mode does), so streaming doesn't stall.
/// Implemented in MainActivity.kt.
final _wifiLock = _WifiLock();

class _WifiLock {
  static const _channel = MethodChannel('myfiles/wifi_lock');
  bool _held = false;

  void hold(bool wanted) {
    if (wanted == _held || kIsWeb || !Platform.isAndroid) return;
    _held = wanted;
    _channel.invokeMethod<void>(wanted ? 'acquire' : 'release').catchError((Object e) {
      debugPrint('Wi-Fi lock: $e');
    });
  }
}
