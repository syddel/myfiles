import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'screens/folder_screen.dart';
import 'screens/login_screen.dart';
import 'screens/offline_screen.dart';
import 'screens/server_screen.dart';
import 'audio/service_backend.dart';
import 'state/app_state.dart';
import 'state/now_playing.dart';
import 'widgets/app_logo.dart';
import 'widgets/mini_player.dart';

// Kept for the life of the app (only its listener is needed).
// ignore: unused_element
AppLifecycleListener? _lifecycle;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Background audio (notification / lock-screen controls) must be set up before the app starts.
  final audio = await ServiceAudioBackend.start();
  final state = AppState(DeviceStorage(), audio: audio);
  // On screen or not: retries when offline, and the player's position display.
  _lifecycle = AppLifecycleListener(onStateChange: (s) => state.appVisible = s == AppLifecycleState.resumed);
  runApp(MyFilesApp(state: state..start()));
}

class MyFilesApp extends StatelessWidget {
  const MyFilesApp({super.key, required this.state});

  final AppState state;

  static ThemeData theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB), brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, scrolledUnderElevation: 1),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }

  /// One navigator per stage and user (see the MaterialApp key below), so the
  /// mini player, which sits outside the navigator, can open pages in it.
  static final _navigators = <String, GlobalKey<NavigatorState>>{};

  static GlobalKey<NavigatorState> _navigatorFor(String key) {
    _navigators.removeWhere((k, _) => k != key);
    return _navigators.putIfAbsent(key, GlobalKey<NavigatorState>.new);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: state,
      child: Consumer<AppState>(
        builder: (context, app, _) {
          final appKey = '${app.stage.name}-${app.user?.id}';
          final navigator = _navigatorFor(appKey);
          return MaterialApp(
            // A fresh navigator whenever the stage or user changes, so signing
            // out never leaves the old user's pages behind.
            key: ValueKey(appKey),
            navigatorKey: navigator,
            title: app.appName,
            debugShowCheckedModeBanner: false,
            theme: theme(Brightness.light),
            darkTheme: theme(Brightness.dark),
            themeMode: app.themeMode,
            home: switch (app.stage) {
              Stage.starting => const _Starting(),
              Stage.offline => const OfflineScreen(),
              Stage.needServer => const ServerScreen(),
              Stage.needLogin => const LoginScreen(),
              Stage.ready => FolderScreen(folderId: app.user!.rootId, isHome: true),
            },
            // Above the navigator, so every page and sheet can see the upload
            // queue and the audio player, and the mini player sits under every page.
            builder: (context, child) {
              Widget content = child!;
              final nowPlaying = app.nowPlaying;
              if (nowPlaying != null) {
                content = MultiProvider(
                  providers: [
                    ChangeNotifierProvider.value(value: nowPlaying),
                    ChangeNotifierProvider.value(value: nowPlaying.playlist),
                  ],
                  child: _WithMiniPlayer(navigator: navigator, child: content),
                );
              }
              final uploads = app.uploads;
              return uploads == null ? content : ChangeNotifierProvider.value(value: uploads, child: content);
            },
          );
        },
      ),
    );
  }
}

/// The app's pages, with the mini player underneath while audio is loaded.
class _WithMiniPlayer extends StatelessWidget {
  const _WithMiniPlayer({required this.navigator, required this.child});

  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final showing =
        context.select<NowPlaying, bool>((p) => p.showMiniPlayer) && MediaQuery.viewInsetsOf(context).bottom == 0;
    return Column(
      children: [
        Expanded(
          // The mini player takes care of the bottom system inset when it's showing.
          child: MediaQuery.removePadding(context: context, removeBottom: showing, child: child),
        ),
        if (showing) MiniPlayer(navigator: navigator),
      ],
    );
  }
}

/// Shown while the app reconnects: the same icon as the native splash screen,
/// in the same place, with a small spinner underneath.
class _Starting extends StatelessWidget {
  const _Starting();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          Center(child: AppLogo()),
          Positioned(
            bottom: 96,
            child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
        ],
      ),
    );
  }
}
