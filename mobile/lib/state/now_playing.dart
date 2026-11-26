import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../audio/audio_backend.dart';
import 'app_state.dart';
import 'playlist.dart';

/// The audio file that's playing (or paused), shared by the full player, the
/// mini player and the notification. Remembers where you stopped in each file.
class NowPlaying extends ChangeNotifier {
  NowPlaying(
    this.backend,
    this.storage, {
    required this.scope,
    Playlist? playlist,
    this.retryDelays = defaultRetryDelays,
    this.pauseRelease = defaultPauseRelease,
  }) : playlist = playlist ?? Playlist(storage, scope: scope) {
    _changes = backend.changes.listen((_) => _changed());
    this.playlist.addListener(_playlistChanged);
  }

  final AudioBackend backend;
  final AppStorage storage;

  /// The user's playlist. Files in it play one after another.
  final Playlist playlist;

  /// For loading the next file in the playlist.
  ApiClient? _api;

  /// Saved positions are kept per server and account.
  final String scope;

  static const speeds = [1.0, 1.25, 1.5, 2.0];

  /// When playback breaks off mid-file (e.g. the network dropped with the
  /// screen off), reconnect after each of these delays (about 2 minutes in all)
  /// before giving up.
  static const defaultRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];
  final List<Duration> retryDelays;

  /// The background service stays running while paused, so playback can
  /// resume after another app's sound. After this long paused, it's released
  /// (notification gone, phone free to sleep); play loads the file again.
  static const defaultPauseRelease = Duration(minutes: 15);
  final Duration pauseRelease;
  Timer? _pauseReleaseTimer;

  /// Whether the app is on screen. Off screen, the position isn't redrawn
  /// twice a second, only saved every few seconds (Android limits the CPU
  /// background apps may use).
  bool _visible = true;
  static const connectionLostMessage = 'Playback stopped: the connection to the server was lost';

  /// How often the position is saved while playing.
  static const saveEvery = Duration(seconds: 5);

  /// Positions this close to the start aren't worth resuming from.
  static const minResume = Duration(seconds: 5);

  StreamSubscription<void>? _changes;
  Timer? _ticker;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  Node? node;

  /// Set when playback picked up from a saved position (cleared when you seek).
  Duration? resumedFrom;
  double speed = 1;
  bool _completionHandled = false;

  /// The file the player has finished loading. While another one is loading,
  /// the player still reports the old one's state (e.g. "finished"), which
  /// mustn't count as the new file finishing.
  int? _loadedId;

  // Reconnecting after an interruption.
  int _retries = 0;
  Timer? _retryTimer;
  bool _retrying = false;
  Duration? _retryFrom;

  /// The last position the current file actually played to (where a
  /// reconnection picks up).
  Duration _lastGood = Duration.zero;

  /// Paused during a reconnection: play loads the file again.
  bool _reloadOnPlay = false;

  /// Things on screen that already show the controls (the full player, a
  /// video) hide the mini player while they're open.
  int _hiders = 0;

  bool get playing => backend.playing;
  bool get loading => backend.loading;
  Duration get position => backend.position;
  Duration? get duration => backend.duration;
  String? get error {
    final message = node == null ? null : backend.error;
    if (message == null) return null;
    final detail = _errorDetail;
    return detail == null ? message : '$message\n$detail';
  }

  /// What the server says about a file that failed (see [ApiClient.diagnose]).
  String? _errorDetail;
  bool get showMiniPlayer => node != null && _hiders == 0;

  /// Playback broke off and the app is reconnecting.
  bool get reconnecting => node != null && backend.interrupted;

  /// The current file is in the playlist, so the next one follows it.
  bool get inPlaylist => node != null && playlist.contains(node!.id);
  PlaylistEntry? get nextInPlaylist => node == null ? null : playlist.after(node!.id);
  PlaylistEntry? get previousInPlaylist => node == null ? null : playlist.before(node!.id);

  String _key(int fileId) => 'audio_pos:$scope:$fileId';

  Future<void> loadPreferences() async {
    final saved = double.tryParse(await storage.read('audio_speed') ?? '');
    if (saved != null && speeds.contains(saved)) speed = saved;
  }

  /// The position saved for [fileId], if any.
  Future<Duration?> savedPosition(int fileId) async {
    final ms = int.tryParse(await storage.read(_key(fileId)) ?? '');
    return ms == null ? null : Duration(milliseconds: ms);
  }

  /// Play [file], continuing where it was left off. If it's already the
  /// current file, just make sure it's playing.
  ///
  /// [automatic]: the playlist moved on by itself, or next/previous was pressed
  /// in the notification. A load that fails then is retried like a dropped
  /// connection, rather than stopping straight away.
  Future<void> playFile(ApiClient api, Node file, {bool automatic = false}) async {
    _api = api;
    if (playlist.contains(file.id)) await playlist.setCurrent(file.id);
    if (node?.id == file.id && backend.error == null) {
      if (!backend.playing) await play();
      return;
    }
    await _savePosition();
    _cancelRetry();
    _errorDetail = null;
    node = file;
    _loadedId = null;
    resumedFrom = null;
    _completionHandled = false;
    _updateQueue();
    notifyListeners();
    final saved = await savedPosition(file.id);
    final start = saved != null && saved >= minResume ? saved : Duration.zero;
    _lastGood = start;
    await backend.open(
      url: api.contentUrl(file.id),
      headers: api.mediaHeaders,
      id: '${file.id}',
      title: file.name,
      start: start,
      speed: speed,
      retry: automatic,
    );
    if (node?.id != file.id) return; // another file was chosen meanwhile
    _loadedId = file.id;
    if (backend.interrupted) return; // couldn't load it: reconnecting (see _changed)
    if (backend.error != null) {
      notifyListeners();
      _diagnose(file);
      return;
    }
    if (start > Duration.zero) resumedFrom = start;
    await play();
  }

  Future<void> play() async {
    if (node == null) return;
    if (_reloadOnPlay) {
      // Paused while reconnecting, or released after a long pause: load it again where it was.
      _reloadOnPlay = false;
      await _open(_lastGood, retry: false);
      if (backend.error != null) return notifyListeners();
    }
    if (backend.completed) await backend.seek(Duration.zero);
    _completionHandled = false;
    await backend.play();
    _changed();
  }

  Future<void> pause() async {
    if (backend.interrupted) {
      // Stop reconnecting; play loads it again.
      _cancelRetry();
      _reloadOnPlay = true;
      await backend.giveUp(null);
      return _changed();
    }
    await backend.pause();
    await _savePosition();
    _changed();
  }

  Future<void> toggle() => backend.playing ? pause() : play();

  Future<void> seek(Duration to) async {
    final max = backend.duration;
    if (to < Duration.zero) to = Duration.zero;
    if (max != null && to > max) to = max;
    resumedFrom = null;
    if (backend.interrupted || _reloadOnPlay) {
      // Nothing loaded to seek in: reconnecting / playing again starts there.
      _lastGood = to;
      await storage.write(_key(node!.id), to >= minResume ? '${to.inMilliseconds}' : null);
      return _changed();
    }
    await backend.seek(to);
    await _savePosition();
    _changed();
  }

  Future<void> skip(Duration by) => seek(backend.position + by);

  /// Go back to the beginning (offered after resuming).
  Future<void> startOver() => seek(Duration.zero);

  /// Forget where you stopped in each of [fileIds], so they all start from
  /// the beginning. If one of them is loaded now, it goes back to the start too.
  Future<void> forgetPositions(Iterable<int> fileIds) async {
    final ids = fileIds.toSet();
    for (final id in ids) {
      await storage.write(_key(id), null);
    }
    final current = node;
    if (current != null && ids.contains(current.id) && _loadedId == current.id) {
      await seek(Duration.zero);
    }
  }

  Future<void> setSpeed(double value) async {
    speed = value;
    await backend.setSpeed(value);
    await storage.write('audio_speed', '$value');
    _changed();
  }

  /// Play the playlist from the file you were on (at its saved position), or from [entry].
  Future<void> playPlaylist(ApiClient api, {PlaylistEntry? entry}) async {
    final start = entry ?? playlist.current;
    if (start != null) await playFile(api, start.toNode());
  }

  /// Next file in the playlist. [automatic]: see [playFile].
  Future<void> next({bool automatic = false}) async {
    final entry = nextInPlaylist;
    final api = _api;
    if (entry != null && api != null) await playFile(api, entry.toNode(), automatic: automatic);
  }

  /// Back to the start of this file or, if it's only just started, the previous one.
  Future<void> previous({bool automatic = false}) async {
    final entry = previousInPlaylist;
    final api = _api;
    if (entry != null && api != null && backend.position < const Duration(seconds: 5)) {
      await playFile(api, entry.toNode(), automatic: automatic);
    } else {
      await seek(Duration.zero);
    }
  }

  /// Stop and close the player (keeps the saved position).
  Future<void> stop() async {
    _pauseReleaseTimer?.cancel();
    _pauseReleaseTimer = null;
    await _savePosition();
    _cancelRetry();
    _reloadOnPlay = false;
    node = null;
    _loadedId = null;
    resumedFrom = null;
    _ticker?.cancel();
    _ticker = null;
    await backend.stop();
    backend.setQueue(hasPrevious: false, hasNext: false);
    notifyListeners();
  }

  /// Hide the mini player while something else shows the controls. Returns
  /// the function that undoes it.
  VoidCallback hideMiniPlayer() {
    _hiders++;
    _notifySoon();
    var undone = false;
    return () {
      if (undone) return;
      undone = true;
      _hiders--;
      _notifySoon();
    };
  }

  // Called from widget lifecycles, which mustn't trigger rebuilds synchronously.
  void _notifySoon() => scheduleMicrotask(() {
    if (!_disposed) notifyListeners();
  });

  void _changed() {
    if (node == null) return;
    _noteProgress();
    if (backend.interrupted && _retryTimer == null && !_retrying) _scheduleRetry();
    if (_retryTimer != null && !backend.interrupted && !backend.playing && backend.error == null) {
      // Paused from the notification while reconnecting: stop trying; play loads it again.
      _cancelRetry();
      _reloadOnPlay = true;
    }
    if (backend.completed && !_completionHandled && _loadedId == node!.id) {
      // Finished: next time, start from the beginning.
      _completionHandled = true;
      resumedFrom = null;
      storage.write(_key(node!.id), null);
      _lastSave = DateTime.now();
      // In the playlist: on to the next file.
      if (inPlaylist && nextInPlaylist != null) scheduleMicrotask(() => next(automatic: true));
    }
    if (backend.playing) {
      _ticker ??= _startTicker();
      if (!backend.interrupted) _reloadOnPlay = false; // resumed by itself (e.g. after a phone call)
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
    _updatePauseRelease();
    notifyListeners();
  }

  Timer _startTicker() => Timer.periodic(_visible ? const Duration(milliseconds: 500) : saveEvery, (_) => _tick());

  /// The app came on screen or went off it (see [AppState.appVisible]).
  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (_ticker != null) {
      _ticker!.cancel();
      _ticker = _startTicker();
    }
    if (visible && node != null) notifyListeners(); // show the current position at once
  }

  /// Start (or cancel) the countdown to releasing the background service while paused.
  void _updatePauseRelease() {
    final paused =
        node != null &&
        _loadedId == node!.id &&
        !backend.playing &&
        !backend.interrupted &&
        backend.error == null &&
        !_reloadOnPlay;
    if (!paused) {
      _pauseReleaseTimer?.cancel();
      _pauseReleaseTimer = null;
    } else {
      _pauseReleaseTimer ??= Timer(pauseRelease, _releaseAfterPause);
    }
  }

  Future<void> _releaseAfterPause() async {
    _pauseReleaseTimer = null;
    if (node == null || backend.playing || backend.interrupted) return;
    await _savePosition();
    if (backend.completed) _lastGood = Duration.zero; // finished: play starts it again
    _reloadOnPlay = true; // play loads it again where it was
    await backend.stop(); // ends the background service and its notification
    notifyListeners();
  }

  Duration? _lastTickPosition;

  void _tick() {
    _noteProgress();
    if (DateTime.now().difference(_lastSave) >= saveEvery) _savePosition();
    if (!_visible) return; // nothing on screen to update
    final position = backend.position;
    if (position == _lastTickPosition) return; // e.g. buffering: nothing to redraw
    _lastTickPosition = position;
    notifyListeners();
  }

  Future<void> _savePosition() async {
    final current = node;
    // (While a file is loading, the player's position is still the previous file's.)
    if (current == null ||
        _loadedId != current.id ||
        backend.completed ||
        backend.error != null ||
        backend.interrupted ||
        _reloadOnPlay) {
      return;
    }
    _lastSave = DateTime.now();
    final pos = backend.position;
    await storage.write(_key(current.id), pos >= minResume ? '${pos.inMilliseconds}' : null);
  }

  void _playlistChanged() {
    _updateQueue();
    if (node != null) notifyListeners();
  }

  /// Tell the notification which playlist buttons to show.
  void _updateQueue() {
    final hasPrevious = previousInPlaylist != null;
    final hasNext = nextInPlaylist != null;
    backend.setQueue(
      hasPrevious: hasPrevious,
      hasNext: hasNext,
      // (From the notification / lock screen: often with the screen off.)
      onPrevious: hasPrevious ? () => previous(automatic: true) : null,
      onNext: hasNext ? () => next(automatic: true) : null,
    );
  }

  // ------------------------------------------------------------ reconnecting

  /// Remember how far the file has really played; once it has played on
  /// well past a reconnection, a later interruption gets the full set of retries.
  void _noteProgress() {
    final current = node;
    if (current == null || _loadedId != current.id) return;
    if (backend.interrupted || backend.completed || backend.error != null || _reloadOnPlay) return;
    final position = backend.position;
    if (position > Duration.zero) _lastGood = position;
    final from = _retryFrom;
    if (from != null && position > from + const Duration(seconds: 10)) {
      _retries = 0;
      _retryFrom = null;
    }
  }

  void _scheduleRetry() {
    if (_retries >= retryDelays.length) {
      // Out of tries: stop for good, and say why.
      _retries = 0;
      _retryFrom = null;
      final file = node;
      backend.giveUp(connectionLostMessage).then((_) {
        if (file != null) _diagnose(file);
      });
      return;
    }
    _retryTimer = Timer(retryDelays[_retries++], _retry);
  }

  Future<void> _retry() async {
    _retryTimer = null;
    final file = node;
    if (file == null || !backend.interrupted) return;
    _retrying = true;
    _retryFrom = _lastGood;
    try {
      await _open(_lastGood, retry: true);
    } finally {
      _retrying = false;
    }
    if (node?.id != file.id) return;
    if (backend.interrupted) {
      _scheduleRetry(); // still can't reach it
      return;
    }
    await backend.play();
    _changed();
  }

  /// Load the current file again at [start].
  Future<void> _open(Duration start, {required bool retry}) async {
    final file = node;
    final api = _api;
    if (file == null || api == null) return;
    await backend.open(
      url: api.contentUrl(file.id),
      headers: api.mediaHeaders,
      id: '${file.id}',
      title: file.name,
      start: start,
      speed: speed,
      retry: retry,
    );
    if (node?.id == file.id) _loadedId = file.id;
  }

  /// Ask the server why [file] failed, and add the answer to [error].
  Future<void> _diagnose(Node file) async {
    final api = _api;
    if (api == null) return;
    final detail = await api.diagnose(file.id);
    if (node?.id != file.id || backend.error == null || _disposed) return;
    _errorDetail = detail;
    notifyListeners();
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retries = 0;
    _retryFrom = null;
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _pauseReleaseTimer?.cancel();
    playlist.removeListener(_playlistChanged);
    _ticker?.cancel();
    _changes?.cancel();
    super.dispose();
  }
}
