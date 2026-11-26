/// The audio player the app talks to. The real one ([ServiceAudioBackend])
/// keeps playing in the background and shows notification / lock-screen
/// controls; tests use a fake.
abstract class AudioBackend {
  /// Fires whenever something below changes (not for every position tick).
  Stream<void> get changes;

  bool get playing;
  bool get loading;

  /// Reached the end of the file.
  bool get completed;
  Duration get position;
  Duration? get duration;
  double get speed;

  /// Why the last [open] failed, or why playback stopped for good, if it did.
  String? get error;

  /// Playback failed part-way through a file (e.g. the network dropped). The
  /// backend keeps reporting "playing" (so a background service isn't shut
  /// down) until the file is opened again, or [giveUp] is called.
  bool get interrupted;

  /// Load a file, ready to play from [start].
  Future<void> open({
    required Uri url,
    required Map<String, String> headers,
    required String id,
    required String title,
    String? subtitle,
    Duration start = Duration.zero,
    double speed = 1,
    bool retry = false, // reconnecting after an interruption: a failure counts as another interruption
  });

  /// Stop trying after an interruption. With a [message], it becomes [error].
  Future<void> giveUp(String? message);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);

  /// Stop and unload (also removes the notification).
  Future<void> stop();

  /// Playlist controls for the notification / lock screen / headset: which of
  /// previous and next to offer, and what they do.
  void setQueue({
    required bool hasPrevious,
    required bool hasNext,
    void Function()? onPrevious,
    void Function()? onNext,
  });
}

/// Plays nothing. Used where no real player is available (e.g. widget tests
/// that don't involve audio).
class NoAudioBackend implements AudioBackend {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  bool get playing => false;
  @override
  bool get loading => false;
  @override
  bool get completed => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  double get speed => 1;
  @override
  String? get error => 'Audio playback isn\'t available';
  @override
  bool get interrupted => false;
  @override
  Future<void> giveUp(String? message) async {}
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
  }) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> stop() async {}
  @override
  void setQueue({
    required bool hasPrevious,
    required bool hasNext,
    void Function()? onPrevious,
    void Function()? onNext,
  }) {}
}
