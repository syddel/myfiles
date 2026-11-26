import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../audio/audio_backend.dart';
import 'now_playing.dart';
import 'uploads.dart';

/// Where the server address and the login session are kept between launches.
abstract class AppStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

/// The real storage: the session token goes in the platform's secure storage
/// (Keychain / Keystore); everything else in shared preferences.
class DeviceStorage implements AppStorage {
  static const _secureKeys = {'session'};
  final _secure = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    if (_secureKeys.contains(key)) return _secure.read(key: key);
    return (await SharedPreferences.getInstance()).getString(key);
  }

  @override
  Future<void> write(String key, String? value) async {
    if (_secureKeys.contains(key)) {
      value == null ? await _secure.delete(key: key) : await _secure.write(key: key, value: value);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    value == null ? await prefs.remove(key) : await prefs.setString(key, value);
  }
}

class MemoryStorage implements AppStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async => value == null ? values.remove(key) : values[key] = value;
}

/// offline: signed in, but the server can't be reached right now (keeps retrying).
enum Stage { starting, offline, needServer, needLogin, ready }

/// App-wide state: which server, who's signed in, and their display preferences.
class AppState extends ChangeNotifier {
  AppState(
    this.storage, {
    this.makeClient = _defaultClient,
    AudioBackend? audio,
    this.offlineRetryDelays = defaultOfflineRetryDelays,
  }) : audio = audio ?? NoAudioBackend();

  /// While the server can't be reached: try again after each of these delays
  /// (the last one repeats), as long as the app is on screen.
  static const defaultOfflineRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];
  final List<Duration> offlineRetryDelays;

  final AppStorage storage;

  /// The audio player (kept for the life of the app; it may be playing in the background).
  final AudioBackend audio;

  /// Builds the API client (tests pass one backed by a fake HTTP adapter).
  final ApiClient Function(Uri server, String? session) makeClient;
  static ApiClient _defaultClient(Uri server, String? session) => ApiClient(server, session: session);

  Stage stage = Stage.starting;
  ApiClient? api;
  ServerConfig? config;
  User? user;
  ThemeMode themeMode = ThemeMode.system;
  String folderColor = 'amber';
  String? startupError;

  /// Upload queue for the signed-in user.
  UploadQueue? uploads;

  /// The audio file playing for the signed-in user.
  NowPlaying? nowPlaying;

  String get appName => config?.appName ?? 'MyFiles';

  // ------------------------------------------------------------ offline

  Timer? _offlineRetry;
  int _offlineAttempts = 0;

  /// A reconnection attempt is under way (the offline screen shows a spinner).
  bool reconnecting = false;

  /// Whether the app is on screen. Off screen, nothing is retried (Android
  /// gives background apps no network in deep sleep anyway) and the audio
  /// player's position display isn't updated.
  bool get appVisible => _appVisible;
  bool _appVisible = true;
  set appVisible(bool visible) {
    if (visible == _appVisible) return;
    _appVisible = visible;
    nowPlaying?.setVisible(visible);
    if (stage == Stage.offline) {
      if (visible) {
        retryConnection(); // back in the app: try at once
      } else {
        _offlineRetry?.cancel();
        _offlineRetry = null;
      }
    }
  }

  /// Try to reach the server again (the offline screen's Try again).
  Future<void> retryConnection() async {
    if (stage != Stage.offline || reconnecting) return;
    _offlineRetry?.cancel();
    _offlineRetry = null;
    reconnecting = true;
    notifyListeners();
    try {
      await _reconnect();
    } finally {
      reconnecting = false;
      notifyListeners();
    }
  }

  void _scheduleOfflineRetry() {
    _offlineRetry?.cancel();
    _offlineRetry = null;
    if (!_appVisible || stage != Stage.offline) return;
    final delays = offlineRetryDelays;
    final delay = delays[_offlineAttempts.clamp(0, delays.length - 1)];
    _offlineAttempts++;
    _offlineRetry = Timer(delay, retryConnection);
  }

  /// Restore the last server and session, if any.
  Future<void> start() async {
    themeMode = _themeFrom(await storage.read('theme'));
    final saved = await storage.read('server');
    if (saved == null) return _setStage(Stage.needServer);
    api = _client(Uri.parse(saved), await storage.read('session'));
    await _reconnect();
  }

  /// Contact the saved server with the saved session. If it can't be reached,
  /// stay signed in (the offline screen) and try again later.
  Future<void> _reconnect() async {
    final client = api!;
    try {
      config = await client.config();
      startupError = null;
      _offlineAttempts = 0;
      if (client.session == null) return _setStage(Stage.needLogin);
      _signedIn(await client.me());
    } on ApiException catch (e) {
      if (e.status == 401) {
        // The session is no longer valid: sign in again.
        startupError = null;
        client.session = null;
        await storage.write('session', null);
        return _setStage(Stage.needLogin);
      }
      startupError = e.message;
      if (client.session == null) return _setStage(Stage.needLogin);
      // No network, or the server isn't answering properly: keep the session.
      _setStage(Stage.offline);
      _scheduleOfflineRetry();
    }
  }

  ApiClient _client(Uri server, String? session) {
    final client = makeClient(server, session);
    client.onUnauthorized = _sessionExpired;
    return client;
  }

  /// Check an address and remember it if a MyFiles server answers there.
  /// The same address as before keeps the saved session (no need to sign in again).
  Future<void> connect(String address) async {
    final server = normalizeServerUrl(address);
    final sameServer = await storage.read('server') == server.toString();
    final savedSession = sameServer ? await storage.read('session') : null;
    final client = _client(server, savedSession);
    ServerConfig cfg;
    try {
      cfg = await client.config();
    } catch (_) {
      throw ApiException(0, 'No MyFiles server found at $server');
    }
    _offlineRetry?.cancel();
    _offlineRetry = null;
    config = cfg;
    api = client;
    startupError = null;
    await storage.write('server', server.toString());
    if (savedSession != null) {
      try {
        return _signedIn(await client.me());
      } on ApiException {
        client.session = null; // expired, or unreachable after all: sign in
      }
    }
    await storage.write('session', null);
    _setStage(Stage.needLogin);
  }

  Future<void> signIn(String username, String password) async {
    final client = api!;
    _signedIn(await client.login(username, password));
    await storage.write('session', client.session);
  }

  Future<void> register(String username, String password, String inviteCode) async {
    final client = api!;
    _signedIn(await client.register(username, password, inviteCode));
    await storage.write('session', client.session);
  }

  void _signedIn(User u) {
    user = u;
    uploads = UploadQueue(api!);
    nowPlaying?.dispose();
    nowPlaying = NowPlaying(audio, storage, scope: '${api!.server}|${u.id}')
      ..loadPreferences()
      ..setVisible(_appVisible);
    nowPlaying!.playlist.load();
    folderColor = u.folderColor;
    themeMode = _themeFrom(u.theme);
    storage.write('theme', u.theme);
    _setStage(Stage.ready);
  }

  Future<void> signOut() async {
    uploads?.cancelAll();
    await _stopAudio();
    await api?.logout();
    await storage.write('session', null);
    user = null;
    _setStage(Stage.needLogin);
  }

  /// Go back to the server address screen. Signed in, this signs out; from the
  /// offline screen the session is kept, so entering the same address again
  /// doesn't need a new sign-in (a different address clears it, see [connect]).
  Future<void> changeServer() async {
    _offlineRetry?.cancel();
    _offlineRetry = null;
    await _stopAudio();
    if (user != null) {
      await api?.logout();
      await storage.write('session', null);
    }
    user = null;
    _setStage(Stage.needServer);
  }

  void _sessionExpired() {
    if (stage != Stage.ready) return;
    _stopAudio();
    storage.write('session', null);
    user = null;
    _setStage(Stage.needLogin);
  }

  /// Stop playback when the user signs out (it belongs to their account).
  Future<void> _stopAudio() async {
    final player = nowPlaying;
    nowPlaying = null;
    if (player == null) return;
    await player.stop();
    player.dispose();
  }

  Future<void> setTheme(String theme) async {
    final previous = themeMode;
    themeMode = _themeFrom(theme);
    notifyListeners();
    await storage.write('theme', theme);
    try {
      await api!.setPreferences(theme: theme);
    } on ApiException {
      themeMode = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setFolderColor(String color) async {
    final previous = folderColor;
    folderColor = color;
    notifyListeners();
    try {
      await api!.setPreferences(folderColor: color);
    } on ApiException {
      folderColor = previous;
      notifyListeners();
      rethrow;
    }
  }

  static ThemeMode _themeFrom(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String themeKey(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };

  void _setStage(Stage s) {
    stage = s;
    notifyListeners();
  }
}
