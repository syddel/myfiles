import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:myfiles_mobile/api/models.dart';
import 'package:myfiles_mobile/main.dart';
import 'package:myfiles_mobile/state/app_state.dart';
import 'package:myfiles_mobile/state/now_playing.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_audio.dart';
import 'fake_server.dart';
import 'video_test.dart' show FakeVideoPlatform;

Map<String, dynamic> _file(int id, String name, String kind) => {
  'id': id,
  'parent_id': 1,
  'name': name,
  'is_dir': false,
  'size': 30000000,
  'mime_type': null,
  'kind': kind,
  'updated_at': '2026-11-01T10:00:00',
};

void main() {
  late FakeServer server;
  late FakeAudioBackend audio;
  late MemoryStorage storage;

  setUp(() {
    server = FakeServer()
      ..nodes[7] = _file(7, 'episode-12.mp3', 'audio')
      ..nodes[8] = _file(8, 'episode-13.mp3', 'audio')
      ..nodes[9] = _file(9, 'holiday.mp4', 'video');
    audio = FakeAudioBackend();
    storage = MemoryStorage();
  });

  group('NowPlaying', () {
    late NowPlaying player;
    final api = FakeServer().client(Uri.parse('https://files.test/'), 'tok');
    Node file(int id) => Node.fromJson(_file(id, 'f$id.mp3', 'audio'));

    setUp(() => player = NowPlaying(audio, storage, scope: 'srv|7'));
    tearDown(() => player.dispose());

    test('streams from the server with the session, and plays', () async {
      await player.playFile(api, file(7));
      expect(audio.url.toString(), 'https://files.test/api/files/7/content');
      expect(audio.headers!['Cookie'], 'myfiles_session=tok');
      expect(audio.playing, isTrue);
      expect(player.resumedFrom, isNull);
    });

    test('remembers the position on pause and resumes from it next time', () async {
      await player.playFile(api, file(7));
      audio.advanceTo(const Duration(minutes: 3, seconds: 20));
      await player.pause();
      expect(storage.values['audio_pos:srv|7:7'], '200000');

      await player.playFile(api, file(8)); // something else
      await player.playFile(api, file(7)); // back again
      expect(audio.log, contains('open f7.mp3 at 200s'));
      expect(player.resumedFrom, const Duration(minutes: 3, seconds: 20));

      await player.startOver();
      expect(audio.position, Duration.zero);
      expect(player.resumedFrom, isNull);
    });

    test('switching files saves where the previous one was', () async {
      await player.playFile(api, file(7));
      audio.advanceTo(const Duration(minutes: 1));
      await player.playFile(api, file(8));
      expect(storage.values['audio_pos:srv|7:7'], '60000');
    });

    test('the first few seconds aren\'t worth resuming from', () async {
      await player.playFile(api, file(7));
      audio.advanceTo(const Duration(seconds: 3));
      await player.pause();
      expect(storage.values.containsKey('audio_pos:srv|7:7'), isFalse);
    });

    test('finishing a file forgets its position, and play starts it again', () async {
      storage.values['audio_pos:srv|7:7'] = '500000';
      await player.playFile(api, file(7));
      audio.advanceTo(const Duration(minutes: 10));
      await Future<void>.delayed(Duration.zero);
      expect(storage.values.containsKey('audio_pos:srv|7:7'), isFalse);
      await player.play();
      expect(audio.log.reversed.take(2), ['play', 'seek 0s']);
    });

    test('positions are kept per account', () async {
      storage.values['audio_pos:srv|other:7'] = '500000';
      await player.playFile(api, file(7));
      expect(audio.log, contains('open f7.mp3 at 0s'));
    });

    test('speed is remembered for the next file and the next launch', () async {
      await player.setSpeed(1.5);
      expect(storage.values['audio_speed'], '1.5');
      final again = NowPlaying(audio, storage, scope: 'srv|7');
      await again.loadPreferences();
      expect(again.speed, 1.5);
      await again.playFile(api, file(8));
      expect(audio.speed, 1.5);
      again.dispose();
    });

    test('skip stays within the file', () async {
      await player.playFile(api, file(7));
      await player.skip(const Duration(seconds: -10));
      expect(audio.position, Duration.zero);
      audio.advanceTo(const Duration(minutes: 9, seconds: 50));
      await player.skip(const Duration(seconds: 30));
      expect(audio.position, const Duration(minutes: 10));
    });

    test('a file that can\'t be played shows why', () async {
      audio.failWith = 'This file can\'t be played (format)';
      await player.playFile(api, file(7));
      expect(player.error, contains('can\'t be played'));
      expect(audio.playing, isFalse);
    });
  });

  group('in the app', () {
    Future<AppState> launch(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      server.signedIn = true;
      storage.values.addAll({'server': 'https://files.test/', 'session': 'tok'});
      final app = AppState(storage, makeClient: server.client, audio: audio);
      await tester.pumpWidget(MyFilesApp(state: app));
      await tester.runAsync(app.start);
      await tester.pumpAndSettle();
      return app;
    }

    Finder miniPlayer() => find.byWidgetPredicate((w) => w.runtimeType.toString() == 'MiniPlayer');

    testWidgets('keeps playing after leaving, with a mini player on every screen', (tester) async {
      await launch(tester);
      await tester.tap(find.text('episode-12.mp3'));
      await tester.pumpAndSettle();
      expect(audio.playing, isTrue);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Forward 30 seconds'), findsOneWidget);
      expect(find.byTooltip('Back 10 seconds'), findsOneWidget);
      expect(miniPlayer(), findsNothing); // the full player is showing

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(audio.playing, isTrue); // still playing
      expect(miniPlayer(), findsOneWidget);
      expect(find.descendant(of: miniPlayer(), matching: find.text('episode-12.mp3')), findsOneWidget);

      // It's there on other screens too.
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      expect(miniPlayer(), findsOneWidget);

      // Pause from the mini player.
      await tester.tap(find.descendant(of: miniPlayer(), matching: find.byIcon(Icons.pause)));
      await tester.pumpAndSettle();
      expect(audio.playing, isFalse);

      // Tap it to open the full player again.
      await tester.tap(find.descendant(of: miniPlayer(), matching: find.text('episode-12.mp3')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Playback speed'), findsOneWidget);
      expect(audio.log.where((l) => l.startsWith('open')), hasLength(1)); // not reloaded
    });

    testWidgets('closing the mini player stops playback', (tester) async {
      await launch(tester);
      await tester.tap(find.text('episode-12.mp3'));
      await tester.pumpAndSettle();
      audio.advanceTo(const Duration(minutes: 2));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: miniPlayer(), matching: find.byIcon(Icons.close)));
      await tester.pumpAndSettle();
      expect(miniPlayer(), findsNothing);
      expect(audio.log.last, 'stop');
      expect(storage.values['audio_pos:https://files.test/|7:7'], '120000');
    });

    testWidgets('continues where you left off, with "Start over"', (tester) async {
      storage.values['audio_pos:https://files.test/|7:7'] = '754000';
      await launch(tester);
      await tester.tap(find.text('episode-12.mp3'));
      await tester.pumpAndSettle();
      expect(audio.position, const Duration(minutes: 12, seconds: 34));
      expect(find.text('Continuing from 12:34'), findsOneWidget);
      await tester.tap(find.text('Start over'));
      await tester.pumpAndSettle();
      expect(audio.position, Duration.zero);
      expect(find.text('Continuing from 12:34'), findsNothing);
    });

    testWidgets('playback speed and skip buttons', (tester) async {
      await launch(tester);
      await tester.tap(find.text('episode-12.mp3'));
      await tester.pumpAndSettle();
      expect(find.text('1×'), findsOneWidget);
      await tester.tap(find.byTooltip('Playback speed'));
      await tester.pumpAndSettle();
      expect(find.text('1.25×'), findsOneWidget);
      await tester.tap(find.text('1.5×').last);
      await tester.pumpAndSettle();
      expect(audio.speed, 1.5);
      expect(find.text('1.5×'), findsOneWidget);

      await tester.tap(find.byTooltip('Forward 30 seconds'));
      await tester.pumpAndSettle();
      expect(audio.position, const Duration(seconds: 30));
      await tester.tap(find.byTooltip('Back 10 seconds'));
      await tester.pumpAndSettle();
      expect(audio.position, const Duration(seconds: 20));

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.descendant(of: miniPlayer(), matching: find.textContaining('1.5×')), findsOneWidget);
    });

    testWidgets('playing a video pauses the audio and hides the mini player', (tester) async {
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      await launch(tester);
      await tester.tap(find.text('episode-12.mp3'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(miniPlayer(), findsOneWidget);

      await tester.tap(find.text('holiday.mp4'));
      await tester.pumpAndSettle();
      expect(audio.playing, isFalse);
      expect(miniPlayer(), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(miniPlayer(), findsOneWidget); // back, paused, ready to resume
    });

    testWidgets('signing out stops the audio', (tester) async {
      await launch(tester);
      await tester.tap(find.text('episode-12.mp3'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Sign out'), 100);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
      expect(audio.log.last, 'stop');
      expect(miniPlayer(), findsNothing);
    });
  });
}
