// Runs the API client against a real MyFiles server with open registration:
//
//   MYFILES_TEST_SERVER=http://localhost:8000 flutter test test/server_api_test.dart
//
// Skipped when MYFILES_TEST_SERVER isn't set.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myfiles_mobile/api/api_client.dart';

void main() {
  final address = Platform.environment['MYFILES_TEST_SERVER'];
  final skip = address == null ? 'Set MYFILES_TEST_SERVER to run against a real server' : null;

  test(
    'register, browse, upload, preview, download, move, rename, share, search, delete',
    () async {
      final server = normalizeServerUrl(address!);
      var expired = 0;
      final api = ApiClient(server, onUnauthorized: () => expired++);
      final config = await api.config();
      expect(config.registrationOpen, isTrue, reason: 'the test server must allow registration');

      final username = 'mobile${DateTime.now().millisecondsSinceEpoch}';
      final user = await api.register(username, 'password1', '');
      expect(user.username, username);
      expect(api.session, isNotNull);
      expect((await api.me()).id, user.id);

      final docs = await api.createFolder(user.rootId, 'Docs');
      final archive = await api.createFolder(user.rootId, 'Archive');

      // Upload with progress.
      final bytes = utf8.encode('Hello from the mobile app\n' * 2000);
      final progress = <int>[];
      final file = await api.upload(
        parentId: docs.id,
        name: 'hello.txt',
        data: Stream.fromIterable([
          for (var i = 0; i < bytes.length; i += 8192) bytes.sublist(i, (i + 8192).clamp(0, bytes.length)),
        ]),
        length: bytes.length,
        onProgress: (sent, _) => progress.add(sent),
      );
      expect(file.size, bytes.length);
      expect(file.kind, 'text');
      expect(progress.last, bytes.length);

      final listing = await api.folder(docs.id);
      expect(listing.items.map((n) => n.name), ['hello.txt']);
      expect(listing.breadcrumb.map((c) => c.id), [user.rootId, docs.id]);

      // Text preview reads only the start of the file.
      final start = await api.textStart(file.id, limit: 100);
      expect(start.length, 100);
      expect(start, startsWith('Hello from the mobile app'));

      // Media requests with the session header work (as video_player / Image.network send them).
      final media = await HttpClient().getUrl(api.contentUrl(file.id));
      api.mediaHeaders.forEach(media.headers.set);
      final mediaResponse = await media.close();
      expect(mediaResponse.statusCode, 200);
      await mediaResponse.drain<void>();

      // Download a file, and a folder as a zip.
      final tmp = await Directory.systemTemp.createTemp('myfiles_mobile_test');
      addTearDown(() => tmp.delete(recursive: true));
      await api.downloadTo('${tmp.path}/hello.txt', fileId: file.id);
      expect(await File('${tmp.path}/hello.txt').readAsBytes(), bytes);
      await api.downloadTo('${tmp.path}/docs.zip', zipIds: [docs.id, archive.id]);
      final zip = await File('${tmp.path}/docs.zip').readAsBytes();
      expect(zip.sublist(0, 2), [0x50, 0x4b]); // "PK"

      // Rename, move, search.
      await api.rename(file.id, 'greeting.txt');
      await api.move([file.id], archive.id);
      final found = await api.search('greeting');
      expect(found.single.id, file.id);
      expect(found.single.path, '/Archive');
      expect((await api.allFolders()).map((f) => f.name), containsAll(['Docs', 'Archive']));

      // Can't move a folder into itself.
      await expectLater(api.move([archive.id], archive.id), throwsA(isA<ApiException>()));

      // Sharing.
      expect(await api.getShare(archive.id), isNull);
      var share = await api.setShare(archive.id, 'readwrite');
      expect(share.mode, 'readwrite');
      share = await api.setSharePassword(archive.id, 'letmein');
      expect(share.hasPassword, isTrue);
      expect((await api.shares()).single.nodeId, archive.id);
      final link = api.shareLink(share);
      expect(link, contains(share.token));
      final shareFolder = (await api.folder(user.rootId)).items.firstWhere((n) => n.id == archive.id);
      expect(shareFolder.share, 'readwrite');
      await api.stopSharing(archive.id);
      expect(await api.shares(), isEmpty);

      // Preferences.
      final prefs = await api.setPreferences(folderColor: 'teal', theme: 'dark');
      expect(prefs.folderColor, 'teal');
      expect(prefs.theme, 'dark');
      final stats = await api.stats();
      expect(stats.usedBytes, bytes.length);
      expect(stats.fileCount, 1);

      // Errors carry the server's message.
      await expectLater(
        api.createFolder(user.rootId, 'Docs'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', isNot(contains('Something went wrong')))),
      );

      // Cancelled uploads leave nothing behind.
      final cancel = CancelToken();
      final big = api.upload(
        parentId: docs.id,
        name: 'big.bin',
        data: Stream.periodic(const Duration(milliseconds: 20), (_) => List.filled(65536, 0)).take(200),
        length: 200 * 65536,
        cancelToken: cancel,
        onProgress: (sent, _) {
          if (sent > 65536 * 3) cancel.cancel();
        },
      );
      await expectLater(big, throwsA(isA<ApiException>()));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect((await api.folder(docs.id)).items, isEmpty);

      // Delete, then sign out: the old session no longer works.
      await api.delete([docs.id, archive.id]);
      expect((await api.folder(user.rootId)).items, isEmpty);
      final old = api.session;
      await api.logout();
      expect(api.session, isNull);
      final stale = ApiClient(server, session: old, onUnauthorized: () => expired++);
      await expectLater(stale.me(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
      expect(expired, 1);

      // Wrong password is reported, not treated as an expired session.
      await expectLater(
        api.login(username, 'nope'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
      expect(expired, 1);
      expect((await api.login(username, 'password1')).id, user.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
