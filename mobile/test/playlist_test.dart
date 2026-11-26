import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:myfiles_mobile/api/models.dart';
import 'package:myfiles_mobile/main.dart';
import 'package:myfiles_mobile/state/app_state.dart';
import 'package:myfiles_mobile/state/now_playing.dart';
import 'package:myfiles_mobile/state/playlist.dart';

import 'fake_audio.dart';
import 'fake_server.dart';

Map<String, dynamic> _file(int id, String name, String kind, {int parent = 1}) => {
  'id': id,
  'parent_id': parent,
  'name': name,
  'is_dir': false,
  'size': 1000000,
  'mime_type': null,
  'kind': kind,
  'updated_at': '2026-11-01T10:00:00',
};

Node _audio(int id) => Node.fromJson(_file(id, 'ep$id.mp3', 'audio'));

void main() {
  late MemoryStorage storage;
  late FakeAudioBackend audio;

  setUp(() {
    storage = MemoryStorage();
    audio = FakeAudioBackend();
  });

  group('Playlist', () {
    late Playlist playlist;
    setUp(() => playlist = Playlist(storage, scope: 's|1'));

    List<int> ids() => [for (final e in playlist.entries) e.id];

    test('adds audio files only, once each, and is kept between launches', () async {
      final text = Node.fromJson(_file(5, 'notes.txt', 'text'));
      expect(await playlist.add([_audio(1), _audio(2), text, _audio(1)]), 2);
      expect(await playlist.add([_audio(2), _audio(3)]), 1);
      expect(ids(), [1, 2, 3]);
      await playlist.setCurrent(2);

      final again = Playlist(storage, scope: 's|1');
      await again.load();
      expect([for (final e in again.entries) e.id], [1, 2, 3]);
      expect(again.current!.id, 2);
      expect(again.entries.first.name, 'ep1.mp3');

      // Another account has its own.
      final other = Playlist(storage, scope: 's|2');
      await other.load();
      expect(other.isEmpty, isTrue);
    });

    test('remove, clear, then a new one', () async {
      await playlist.add([_audio(3), _audio(4), _audio(5)]);
      await playlist.remove(4);
      expect(ids(), [3, 5]);
      await playlist.clear();
      expect(playlist.isEmpty, isTrue);
      expect(storage.values.containsKey('playlist:s|1'), isFalse);
      await playlist.add([_audio(7)]);
      expect(ids(), [7]);
    });

    test('move and shuffle (the current file goes to the top)', () async {
      await playlist.add([for (var i = 1; i <= 6; i++) _audio(i)]);
      await playlist.move(0, 3);
      expect(ids(), [2, 3, 4, 1, 5, 6]);
      await playlist.move(5, 0);
      expect(ids(), [6, 2, 3, 4, 1, 5]);

      await playlist.setCurrent(4);
      await playlist.shuffle(Random(1));
      expect(ids().first, 4);
      expect(ids().toSet(), {1, 2, 3, 4, 5, 6});
      expect(playlist.current!.id, 4);
    });
  });

  group('playing a playlist', () {
    late NowPlaying player;
    final api = FakeServer().client(Uri.parse('https://files.test/'), 'tok');

    setUp(() async {
      player = NowPlaying(audio, storage, scope: 's|1');
      await player.playlist.add([_audio(1), _audio(2), _audio(3)]);
    });
    tearDown(() => player.dispose());

    test('plays on to the next file, and stops after the last', () async {
      await player.playPlaylist(api);
      expect(player.node!.id, 1);
      audio.advanceTo(const Duration(minutes: 10)); // end of file 1
      await pumpEventQueue();
      expect(player.node!.id, 2);
      expect(audio.playing, isTrue);
      expect(player.playlist.current!.id, 2);

      await player.playFile(api, _audio(3));
      audio.advanceTo(const Duration(minutes: 10));
      await pumpEventQueue();
      expect(player.node!.id, 3); // last one: stays there
      expect(audio.playing, isFalse);
    });

    test('after a file finishes, the next one loads once and plays (no skipping ahead)', () async {
      audio.realisticOpen = true;
      await player.playPlaylist(api);
      await pumpEventQueue();
      expect(player.node!.id, 1);
      audio.advanceTo(const Duration(minutes: 10)); // file 1 finishes
      await pumpEventQueue();
      expect(audio.log.where((l) => l.startsWith('open')), ['open ep1.mp3 at 0s', 'open ep2.mp3 at 0s']);
      expect(player.node!.id, 2);
      expect(player.error, isNull);
      expect(audio.playing, isTrue);

      // And again from 2 to 3.
      audio.advanceTo(const Duration(minutes: 10));
      await pumpEventQueue();
      expect(audio.opens, 3);
      expect(player.node!.id, 3);
      expect(audio.playing, isTrue);
    });

    test('skipping ahead mid-file doesn\'t save the old file\'s position for the new one', () async {
      audio.realisticOpen = true;
      await player.playPlaylist(api);
      await pumpEventQueue();
      audio.advanceTo(const Duration(minutes: 4));
      audio.loadGate = Completer<void>();
      final skip = player.next();
      await pumpEventQueue();
      expect(player.node!.id, 2); // switched; file 2 still loading, the player still says 4:00
      await player.pause(); // a save while it loads
      audio.loadGate!.complete();
      await skip;
      await pumpEventQueue();
      expect(storage.values['audio_pos:s|1:1'], '240000'); // file 1 keeps its place
      expect(storage.values.containsKey('audio_pos:s|1:2'), isFalse);
    });

    test('continues the playlist at the file and position you were at', () async {
      await player.playPlaylist(api);
      await player.next();
      audio.advanceTo(const Duration(minutes: 4));
      await player.pause();
      await player.stop();

      // Next launch.
      final later = NowPlaying(audio, storage, scope: 's|1');
      await later.playlist.load();
      await later.playPlaylist(api);
      expect(later.node!.id, 2);
      expect(audio.log.last, 'play');
      expect(audio.log, contains('open ep2.mp3 at 240s'));
      later.dispose();
    });

    test('next and previous (previous restarts a file that\'s been playing a while)', () async {
      await player.playPlaylist(api, entry: player.playlist.entries[1]);
      expect(audio.hasPrevious && audio.hasNext, isTrue);
      await player.next();
      expect(player.node!.id, 3);
      expect(audio.hasNext, isFalse);

      audio.advanceTo(const Duration(seconds: 30));
      await player.previous();
      expect(player.node!.id, 3);
      expect(audio.position, Duration.zero);
      await player.previous();
      expect(player.node!.id, 2);
    });

    test('the notification\'s next / previous buttons work', () async {
      await player.playPlaylist(api);
      audio.pressNext();
      await pumpEventQueue();
      expect(player.node!.id, 2);
      audio.pressPrevious();
      await pumpEventQueue();
      expect(player.node!.id, 1);
    });

    test('start all from the beginning forgets every saved position (and rewinds the loaded one)', () async {
      storage.values['audio_pos:s|1:1'] = '100000';
      storage.values['audio_pos:s|1:3'] = '200000';
      storage.values['audio_pos:s|1:9'] = '300000'; // not in the playlist: kept
      await player.playPlaylist(api, entry: player.playlist.entries[2]);
      expect(audio.position, const Duration(seconds: 200));

      await player.forgetPositions(player.playlist.entries.map((e) => e.id));
      expect(storage.values.containsKey('audio_pos:s|1:1'), isFalse);
      expect(storage.values.containsKey('audio_pos:s|1:3'), isFalse);
      expect(storage.values['audio_pos:s|1:9'], '300000');
      expect(audio.position, Duration.zero);
      expect(audio.playing, isTrue);
    });

    test('a file that isn\'t in the playlist doesn\'t move on', () async {
      await player.playFile(api, _audio(9));
      expect(player.inPlaylist, isFalse);
      expect(audio.hasNext, isFalse);
      audio.advanceTo(const Duration(minutes: 10));
      await pumpEventQueue();
      expect(player.node!.id, 9);
    });

    test('clearing the playlist keeps the current file playing, without moving on', () async {
      await player.playPlaylist(api);
      await player.playlist.clear();
      expect(player.node!.id, 1);
      expect(audio.playing, isTrue);
      expect(audio.hasNext, isFalse);
    });
  });

  group('when playback breaks off (e.g. the network drops with the screen off)', () {
    late NowPlaying player;
    final server = FakeServer()..signedIn = true;
    final api = server.client(Uri.parse('https://files.test/'), 'tok');
    const quick = [Duration(milliseconds: 1), Duration(milliseconds: 1), Duration(milliseconds: 1)];
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

    setUp(() async {
      player = NowPlaying(audio, storage, scope: 's|1', retryDelays: quick);
      await player.playlist.add([_audio(1), _audio(2)]);
    });
    tearDown(() => player.dispose());

    test('reconnects and carries on from the same place', () async {
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      player.notifyListeners(); // (a tick)
      await settle();
      storage.values['audio_pos:s|1:1'] = '180000';
      audio.interrupt();
      expect(player.reconnecting, isTrue);
      expect(player.loading, isTrue);
      await settle();
      expect(audio.retryOpens, ['ep1.mp3 at 180s']);
      expect(audio.log.last, 'play');
      expect(player.reconnecting, isFalse);
      expect(player.error, isNull);
      expect(audio.playing, isTrue);
      expect(storage.values['audio_pos:s|1:1'], '180000'); // not overwritten while it was down
    });

    test('keeps trying while the server can\'t be reached, then plays on', () async {
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      await settle();
      audio.failReopens = 2;
      audio.interrupt();
      await settle();
      expect(audio.retryOpens, List.filled(3, 'ep1.mp3 at 180s'));
      expect(audio.playing, isTrue);
      expect(player.error, isNull);
    });

    test('gives up after the last try, and says why', () async {
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      await settle();
      audio.failReopens = 99;
      audio.interrupt();
      await settle();
      expect(audio.retryOpens, hasLength(quick.length));
      expect(audio.log.last, 'give up: ${NowPlaying.connectionLostMessage}');
      expect(player.error, startsWith(NowPlaying.connectionLostMessage));
      expect(player.node!.id, 1); // doesn't skip ahead in the playlist
    });

    test('an interruption doesn\'t count as finishing the file', () async {
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      await settle();
      audio.failReopens = 99;
      audio.interrupt();
      await settle();
      expect(audio.log.any((l) => l.contains('ep2')), isFalse); // never moved on to ep2
    });

    test('when the playlist moves on and the next file fails to load, it keeps trying', () async {
      await player.playPlaylist(api);
      audio.failReopens = 2; // the next file can't be loaded at first ("Source error")
      audio.advanceTo(const Duration(minutes: 10)); // ep1 finishes
      await settle();
      expect(player.node!.id, 2);
      expect(audio.retryOpens, List.filled(3, 'ep2.mp3 at 0s'));
      expect(player.error, isNull);
      expect(audio.playing, isTrue);
    });

    test('the notification\'s next button also keeps trying', () async {
      await player.playPlaylist(api);
      audio.failReopens = 1;
      audio.pressNext();
      await settle();
      expect(player.node!.id, 2);
      expect(audio.retryOpens, hasLength(2));
      expect(audio.playing, isTrue);
    });

    test('a file you choose that can\'t be played says so at once, with what the server says', () async {
      audio.failWith = 'This file can\'t be played (Source error)';
      await player.playFile(api, _audio(2));
      expect(audio.retryOpens, isEmpty);
      await settle();
      expect(player.error, startsWith('This file can\'t be played (Source error)\n'));
      expect(player.error, contains('The server is sending the file normally'));
    });

    test('a session the server no longer accepts shows up in the message', () async {
      final signedOut = FakeServer().client(Uri.parse('https://files.test/'), 'tok');
      audio.failWith = 'This file can\'t be played (Source error)';
      await player.playFile(signedOut, _audio(2));
      await settle();
      expect(player.error, contains('The server answered 401'));
    });

    test('giving up also says what the server says', () async {
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      await settle();
      audio.failReopens = 99;
      audio.interrupt();
      await settle();
      expect(player.error, startsWith(NowPlaying.connectionLostMessage));
      expect(player.error, contains('The server is sending the file normally'));
    });

    test('a long pause releases the background service; play loads it again where it was', () async {
      player.dispose();
      player = NowPlaying(audio, storage, scope: 's|1', pauseRelease: const Duration(milliseconds: 20));
      await player.playlist.load();
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      await player.pause();
      await settle();
      expect(audio.log.last, 'stop'); // service released
      expect(player.node!.id, 1); // still the current file (mini player stays)
      await player.play();
      expect(audio.log, contains('open ep1.mp3 at 180s'));
      expect(audio.playing, isTrue);
    });

    test('a short pause keeps the background service', () async {
      player.dispose();
      player = NowPlaying(audio, storage, scope: 's|1', pauseRelease: const Duration(seconds: 30));
      await player.playlist.load();
      await player.playPlaylist(api);
      await player.pause();
      await settle();
      await player.play();
      expect(audio.log, isNot(contains('stop')));
      expect(audio.log.where((l) => l.startsWith('open')), hasLength(1));
    });

    test('off screen, the position isn\'t redrawn twice a second', () async {
      await player.playPlaylist(api);
      var updates = 0;
      player.addListener(() => updates++);
      player.setVisible(false);
      for (var i = 1; i <= 4; i++) {
        audio.position = Duration(seconds: i); // moves on without other events
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(updates, 0);
      player.setVisible(true);
      expect(updates, 1); // shown at once when back on screen
      audio.position = const Duration(seconds: 9);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(updates, greaterThan(1));
    });

    test('pausing while reconnecting stops trying; play loads it again where it was', () async {
      player.dispose();
      player = NowPlaying(audio, storage, scope: 's|1', retryDelays: const [Duration(seconds: 30)]);
      await player.playlist.load();
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      await settle();
      audio.interrupt();
      await player.pause();
      await settle();
      expect(player.reconnecting, isFalse);
      expect(audio.log.last, 'give up');
      await player.play();
      expect(audio.log, contains('open ep1.mp3 at 180s'));
      expect(audio.playing, isTrue);
    });

    test('after it plays on, a later drop gets the full set of tries again', () async {
      await player.playPlaylist(api);
      audio.advanceTo(const Duration(minutes: 3));
      await settle();
      audio.failReopens = 2;
      audio.interrupt();
      await settle();
      audio.advanceTo(const Duration(minutes: 5)); // played on well past it
      await settle();
      audio.failReopens = 2;
      audio.interrupt();
      await settle();
      expect(player.error, isNull);
      expect(audio.playing, isTrue);
      expect(audio.log.last, 'play');
    });
  });

  group('in the app', () {
    late FakeServer server;

    Future<AppState> launch(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      server = FakeServer()..signedIn = true;
      server.nodes[10] = {..._file(10, 'Podcasts', 'folder'), 'is_dir': true};
      server.nodes[11] = _file(11, 'b-episode.mp3', 'audio', parent: 10);
      server.nodes[12] = _file(12, 'a-episode.mp3', 'audio', parent: 10);
      server.nodes[13] = _file(13, 'cover.jpg', 'image', parent: 10);
      server.nodes[14] = _file(14, 'song.mp3', 'audio');
      storage.values.addAll({'server': 'https://files.test/', 'session': 'tok'});
      final app = AppState(storage, makeClient: server.client, audio: audio);
      await tester.pumpWidget(MyFilesApp(state: app));
      await tester.runAsync(app.start);
      await tester.pumpAndSettle();
      return app;
    }

    Future<void> menu(WidgetTester tester, String name, String action) async {
      await tester.tap(find.descendant(of: find.widgetWithText(ListTile, name), matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }

    List<String> playlistNames(AppState app) => [for (final e in app.nowPlaying!.playlist.entries) e.name];

    testWidgets('add a folder\'s audio, then a file: it just adds them', (tester) async {
      final app = await launch(tester);
      await menu(tester, 'Podcasts', 'Add its audio to playlist');
      expect(playlistNames(app), ['a-episode.mp3', 'b-episode.mp3']); // audio only, by name
      expect(find.text('Added 2 files to the playlist'), findsOneWidget);

      await menu(tester, 'song.mp3', 'Add to playlist');
      expect(find.text('Start a new playlist'), findsNothing); // no question
      expect(find.byType(BottomSheet), findsNothing);
      expect(playlistNames(app), ['a-episode.mp3', 'b-episode.mp3', 'song.mp3']);
      expect(find.text('Added 1 file to the playlist'), findsOneWidget);

      // A new playlist: clear it on the playlist screen, then add.
      await tester.tap(find.byTooltip('Playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await menu(tester, 'song.mp3', 'Add to playlist');
      expect(playlistNames(app), ['song.mp3']);

      // Only audio files and folders offer it.
      await tester.tap(
        find.descendant(of: find.widgetWithText(ListTile, 'notes.txt'), matching: find.byTooltip('More')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Add to playlist'), findsNothing);
    });

    testWidgets('the result shows as a message that closes when tapped, or by itself', (tester) async {
      await launch(tester);
      await menu(tester, 'song.mp3', 'Add to playlist');
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Added 1 file to the playlist'), findsOneWidget);
      await tester.tap(find.text('Added 1 file to the playlist'));
      await tester.pumpAndSettle();
      expect(find.text('Added 1 file to the playlist'), findsNothing);

      // Adding it again: says so, then goes away on its own.
      await menu(tester, 'song.mp3', 'Add to playlist');
      expect(find.text('Already in the playlist'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('Already in the playlist'), findsNothing);

      // A new message replaces the one showing.
      await menu(tester, 'notes.txt', 'Rename'); // (any other action) – close the dialog
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await menu(tester, 'Podcasts', 'Add its audio to playlist');
      await menu(tester, 'song.mp3', 'Add to playlist');
      expect(find.text('Added 2 files to the playlist'), findsNothing);
      expect(find.text('Already in the playlist'), findsOneWidget);
    });

    testWidgets('add several selected items', (tester) async {
      final app = await launch(tester);
      await tester.longPress(find.text('song.mp3'));
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      expect(playlistNames(app), ['song.mp3']);
      expect(find.text('2 selected'), findsNothing); // selection ends
    });

    testWidgets('playlist screen: play, reorder, remove, shuffle, clear', (tester) async {
      final app = await launch(tester);
      await app.nowPlaying!.playlist.add([
        for (final id in [11, 12, 14]) Node.fromJson(server.nodes[id]!),
      ]);
      storage.values['audio_pos:https://files.test/|7:12'] = '95000';
      await tester.tap(find.byTooltip('Playlist'));
      await tester.pumpAndSettle();
      expect(find.text('Playlist (3)'), findsOneWidget);
      expect(find.text('Continue from 1:35'), findsOneWidget);

      // Drag the first one to the bottom.
      await tester.drag(find.byIcon(Icons.drag_handle).first, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(playlistNames(app), ['a-episode.mp3', 'song.mp3', 'b-episode.mp3']);

      // Swipe one away.
      await tester.drag(find.text('song.mp3'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(playlistNames(app), ['a-episode.mp3', 'b-episode.mp3']);
      await tester.pump(const Duration(seconds: 5)); // let the "Removed" message go
      await tester.pumpAndSettle();

      // Play from an entry: opens the player, which follows the playlist.
      await tester.tap(find.text('a-episode.mp3'));
      await tester.pumpAndSettle();
      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('1 of 2 in the playlist'), findsOneWidget);
      expect(audio.log, contains('open a-episode.mp3 at 95s'));
      await tester.tap(find.byTooltip('Next in playlist'));
      await tester.pumpAndSettle();
      expect(find.text('b-episode.mp3'), findsOneWidget);
      expect(find.text('2 of 2 in the playlist'), findsOneWidget);

      // When a file finishes, the player shows the next one.
      await tester.tap(find.byTooltip('Previous in playlist'));
      await tester.pumpAndSettle();
      audio.advanceTo(const Duration(minutes: 10));
      // The player was created in real time (app.start ran in runAsync), so let real time run.
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(app.nowPlaying!.node!.name, 'b-episode.mp3');
      expect(find.text('b-episode.mp3'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Shuffle'));
      await tester.pumpAndSettle();
      expect(find.text('Shuffled'), findsOneWidget);
      expect(playlistNames(app).first, 'b-episode.mp3'); // the one playing stays on top

      await tester.tap(find.byTooltip('Clear playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(find.text('The playlist is empty'), findsOneWidget);
      expect(app.nowPlaying!.node!.name, 'b-episode.mp3'); // still playing
    });

    testWidgets('menu: start all from the beginning', (tester) async {
      final app = await launch(tester);
      await app.nowPlaying!.playlist.add([
        for (final id in [11, 12]) Node.fromJson(server.nodes[id]!),
      ]);
      storage.values['audio_pos:https://files.test/|7:11'] = '95000';
      storage.values['audio_pos:https://files.test/|7:12'] = '65000';
      await tester.tap(find.byTooltip('Playlist'));
      await tester.pumpAndSettle();
      expect(find.text('Continue from 1:35'), findsOneWidget);
      expect(find.text('Continue from 1:05'), findsOneWidget);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start all from the beginning'));
      await tester.pumpAndSettle();
      expect(find.text('Start all from the beginning?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Start from the beginning'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Continue from'), findsNothing);
      expect(find.text('All files will start from the beginning'), findsOneWidget);
      expect(storage.values.keys.where((k) => k.startsWith('audio_pos:')), isEmpty);
      await tester.tap(find.text('All files will start from the beginning')); // close the message
      await tester.pumpAndSettle();

      await tester.tap(find.text('b-episode.mp3'));
      await tester.pumpAndSettle();
      expect(audio.log, contains('open b-episode.mp3 at 0s'));
      expect(find.textContaining('Continuing from'), findsNothing);
    });

    testWidgets('the player offers "Add to playlist" for a file that isn\'t in it', (tester) async {
      final app = await launch(tester);
      await tester.tap(find.text('song.mp3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      expect(playlistNames(app), ['song.mp3']);
      expect(find.text('1 of 1 in the playlist'), findsOneWidget);
    });
  });
}
