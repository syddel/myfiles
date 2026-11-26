import 'package:flutter_test/flutter_test.dart';
import 'package:myfiles_mobile/api/api_client.dart';
import 'package:myfiles_mobile/util/format.dart';

void main() {
  test('formatSize uses 1024-based units like the website', () {
    expect(formatSize(0), '0 B');
    expect(formatSize(1023), '1023 B');
    expect(formatSize(1024), '1.0 KB');
    expect(formatSize(1536), '1.5 KB');
    expect(formatSize(15 * 1024 * 1024 * 1024), '15 GB');
    expect(formatSize(null), '');
  });

  test('formatDate shows time today, day+month this year, else the year', () {
    final now = DateTime(2026, 11, 18, 15);
    expect(formatDate(DateTime(2026, 11, 18, 9, 5), now: now), '09:05');
    expect(formatDate(DateTime(2026, 9, 3), now: now), '3 Sep');
    expect(formatDate(DateTime(2024, 9, 3), now: now), '3 Sep 2024');
  });

  test('normalizeServerUrl adds https and a trailing slash, keeps sub-paths', () {
    expect(normalizeServerUrl('files.example.com').toString(), 'https://files.example.com/');
    expect(normalizeServerUrl(' http://192.168.1.5:8000 ').toString(), 'http://192.168.1.5:8000/');
    expect(normalizeServerUrl('https://example.com/files').toString(), 'https://example.com/files/');
    expect(normalizeServerUrl('https://example.com/files/#/folder/3').toString(), 'https://example.com/files/');
    expect(normalizeServerUrl('http://nas.lan:8080/files?x=1').toString(), 'http://nas.lan:8080/files/');
    expect(() => normalizeServerUrl(''), throwsFormatException);
    expect(() => normalizeServerUrl('ftp://example.com'), throwsFormatException);
  });

  test('sessionFromSetCookie finds the session cookie', () {
    expect(sessionFromSetCookie(['myfiles_session=abc123; HttpOnly; Path=/; SameSite=lax']), 'abc123');
    expect(
      sessionFromSetCookie(['other=1; Path=/, myfiles_session=xyz; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/']),
      'xyz',
    );
    expect(sessionFromSetCookie(['myfiles_session=""; Max-Age=0']), isNull);
    expect(sessionFromSetCookie(null), isNull);
  });

  test('kindIcon uses the user\'s folder color for folders', () {
    expect(kindIcon('folder', folderColor: 'green').color, folderColors['green']!.color);
    expect(kindIcon('folder', folderColor: 'nonsense').color, folderColors['amber']!.color);
    expect(folderColors.length, 20);
  });
}
