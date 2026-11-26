import 'dart:async';

import 'package:myfiles_mobile/audio/audio_backend.dart';

/// A pretend audio player: every file is 10 minutes long and position only
/// moves when a test sets it.
class FakeAudioBackend implements AudioBackend {
  final _changes = StreamController<void>.broadcast();
  final log = <String>[];

  Uri? url;
  Map<String, String>? headers;
  String? title;
  String? failWith;

  @override
  bool playing = false;
  @override
  bool loading = false;
  @override
  bool completed = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration;
  @override
  double speed = 1;
  @override
  String? error;

  void _emit() => _changes.add(null);

  /// Pretend playback reached [to] (e.g. the end).
  void advanceTo(Duration to) {
    position = to;
    if (duration != null && to >= duration!) {
      completed = true;
      playing = false; // like the real backend, which reports a finished file as not playing
      position = duration!;
    }
    _emit();
  }

  /// Behave like the real player while loading (see [open]).
  bool realisticOpen = false;

  /// If set, loading waits until a test completes it.
  Completer<void>? loadGate;
  int _openGeneration = 0;

  int get opens => log.where((l) => l.startsWith('open')).length;

  @override
  Stream<void> get changes => _changes.stream;

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
    log.add('open $title at ${start.inSeconds}s');
    if (retry) retryOpens.add('$title at ${start.inSeconds}s');
    if (realisticOpen) {
      // Like just_audio: setting the speed reports a change while the old,
      // finished file is still loaded, and loading takes a moment.
      final generation = ++_openGeneration;
      _emit();
      await Future<void>.delayed(Duration.zero);
      final gate = loadGate;
      if (gate != null) await gate.future;
      if (generation != _openGeneration) {
        // Replaced by a newer open before it finished loading (the real
        // player reports this as an error for the abandoned file).
        return;
      }
    }
    this.url = url;
    this.headers = headers;
    this.title = title;
    this.speed = speed;
    completed = false;
    if (retry && failReopens > 0) {
      // Still can't reach the server.
      failReopens--;
      interrupted = true;
      position = start;
      _emit();
      return;
    }
    interrupted = false;
    loading = false;
    playing = false;
    error = failWith;
    duration = failWith == null ? const Duration(minutes: 10) : null;
    position = start;
    _emit();
  }

  // ------------------------------------------------------------ interruptions

  @override
  bool interrupted = false;

  /// How many loads made with `retry: true` (reconnections, and files the
  /// playlist moves on to by itself) fail before one works.
  int failReopens = 0;

  /// Loads made with `retry: true`, as "name at Ns".
  final retryOpens = <String>[];

  /// Pretend the network dropped mid-file (the real backend keeps reporting
  /// "playing" so the background service stays up).
  void interrupt() {
    interrupted = true;
    playing = true;
    loading = true;
    _emit();
  }

  @override
  Future<void> giveUp(String? message) async {
    log.add('give up${message == null ? '' : ': $message'}');
    interrupted = false;
    loading = false;
    playing = false;
    error = message;
    _emit();
  }

  @override
  Future<void> play() async {
    log.add('play');
    playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    if (interrupted) return giveUp(null); // like the real backend
    log.add('pause');
    playing = false;
    _emit();
  }

  @override
  Future<void> seek(Duration to) async {
    log.add('seek ${to.inSeconds}s');
    position = to;
    completed = false;
    _emit();
  }

  @override
  Future<void> setSpeed(double value) async {
    log.add('speed $value');
    speed = value;
    _emit();
  }

  @override
  Future<void> stop() async {
    log.add('stop');
    playing = false;
    _emit();
  }

  // What the notification would offer, and pressing its buttons.
  bool hasPrevious = false;
  bool hasNext = false;
  void Function()? _onPrevious;
  void Function()? _onNext;
  void pressNext() => _onNext?.call();
  void pressPrevious() => _onPrevious?.call();

  @override
  void setQueue({
    required bool hasPrevious,
    required bool hasNext,
    void Function()? onPrevious,
    void Function()? onNext,
  }) {
    this.hasPrevious = hasPrevious;
    this.hasNext = hasNext;
    _onPrevious = onPrevious;
    _onNext = onNext;
  }
}
