import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:myfiles_mobile/main.dart';
import 'package:myfiles_mobile/state/app_state.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_server.dart';

/// Stands in for the native video player: a 16:9 video, 2 minutes long.
class FakeVideoPlatform extends VideoPlayerPlatform {
  int created = 0;
  final _events = StreamController<VideoEvent>.broadcast();

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    created++;
    return 1;
  }

  @override
  Future<int?> create(DataSource dataSource) async => 1;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    scheduleMicrotask(
      () => _events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: const Size(1920, 1080),
        ),
      ),
    );
    return _events.stream;
  }

  @override
  Future<void> dispose(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => const Duration(seconds: 5);
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const ColoredBox(color: Colors.blue);
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

void main() {
  late FakeVideoPlatform video;
  late List<String> systemUi;

  setUp(() {
    video = FakeVideoPlatform();
    VideoPlayerPlatform.instance = video;
    systemUi = [];
  });

  Future<void> openVideo(WidgetTester tester, {required bool landscape}) async {
    tester.view.devicePixelRatio = 2.5;
    tester.view.physicalSize = landscape ? const Size(2400, 1080) : const Size(1080, 2400);
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') systemUi.add(call.arguments as String);
      return null;
    });
    final server = FakeServer();
    server.nodes[6] = {
      'id': 6,
      'parent_id': 1,
      'name': 'holiday.mp4',
      'is_dir': false,
      'size': 5000000,
      'mime_type': 'video/mp4',
      'kind': 'video',
      'updated_at': '2026-11-01T10:00:00',
    };
    server.signedIn = true;
    final storage = MemoryStorage()..values.addAll({'server': 'https://files.test/', 'session': 'tok'});
    final app = AppState(storage, makeClient: server.client);
    await tester.pumpWidget(MyFilesApp(state: app));
    await tester.runAsync(app.start);
    await tester.pumpAndSettle();
    await tester.tap(find.text('holiday.mp4'));
    await tester.pumpAndSettle();
  }

  double controlsOpacity(WidgetTester tester) => tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  testWidgets('portrait: title bar on top, controls under the video', (tester) async {
    await openVideo(tester, landscape: false);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Zoom to fill'), findsNothing);
    expect(systemUi, isEmpty);
  });

  testWidgets('landscape: video fills the screen, controls float and fade', (tester) async {
    await openVideo(tester, landscape: true);
    expect(find.byType(AppBar), findsNothing);
    expect(systemUi, ['SystemUiMode.immersiveSticky']);

    // The video takes the whole screen width (16:9 on a 20:9 screen: fit = full height).
    final screen = tester.getSize(find.byType(Scaffold).last);
    final video16x9 = tester.getRect(find.byType(ColoredBox).last);
    expect(video16x9.height, closeTo(screen.height, 0.5));
    expect(video16x9.width, closeTo(screen.height * 16 / 9, 0.5));
    expect(video16x9.center.dx, closeTo(screen.width / 2, 0.5));

    // Controls show at first, then fade while playing.
    expect(controlsOpacity(tester), 1);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);

    // Tap brings them back.
    await tester.tapAt(screen.center(Offset.zero));
    await tester.pump(const Duration(milliseconds: 400)); // past the double-tap window
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1);

    // Zoom to fill: the video now covers the full width too (cropping top and bottom).
    await tester.tap(find.byTooltip('Zoom to fill'));
    await tester.pumpAndSettle();
    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);
    expect(tester.getRect(find.byType(ColoredBox).last).width, closeTo(screen.width, 0.5));
    expect(find.byTooltip('Fit to screen'), findsOneWidget);

    // Pausing keeps the controls up.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1);
    expect(find.byTooltip('Play'), findsOneWidget);

    // Back leaves the preview and gives the system bars back.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('holiday.mp4'), findsOneWidget); // back in the folder list
    expect(systemUi.last, 'SystemUiMode.edgeToEdge');
  });

  testWidgets('turning the phone keeps the same video playing', (tester) async {
    await openVideo(tester, landscape: false);
    expect(find.byType(AppBar), findsOneWidget);
    tester.view.physicalSize = const Size(2400, 1080);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('Zoom to fill'), findsOneWidget);
    tester.view.physicalSize = const Size(1080, 2400);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(systemUi, ['SystemUiMode.immersiveSticky', 'SystemUiMode.edgeToEdge']);
    expect(video.created, 1); // not reloaded on rotation
  });
}
