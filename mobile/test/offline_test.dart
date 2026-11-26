import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:myfiles_mobile/main.dart';
import 'package:myfiles_mobile/state/app_state.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late MemoryStorage storage;

  setUp(() {
    server = FakeServer()
      ..signedIn = true
      ..offline = true;
    storage = MemoryStorage()..values.addAll({'server': 'https://files.test/', 'session': 'tok'});
  });

  Future<AppState> launch(WidgetTester tester, {List<Duration> retry = AppState.defaultOfflineRetryDelays}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final app = AppState(storage, makeClient: server.client, offlineRetryDelays: retry);
    await tester.pumpWidget(MyFilesApp(state: app));
    await tester.runAsync(app.start);
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('no network at startup: stays signed in, Try again connects', (tester) async {
    await launch(tester);
    expect(find.text('Can\'t reach the server'), findsOneWidget);
    expect(find.textContaining('still signed in'), findsOneWidget);
    expect(find.text('Connect to your server'), findsNothing); // not the server-address screen
    expect(storage.values['session'], 'tok');

    server.offline = false;
    await tester.tap(find.text('Try again'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsOneWidget); // home, no sign-in needed
  });

  testWidgets('tries again by itself', (tester) async {
    await launch(tester, retry: const [Duration(milliseconds: 30)]);
    expect(find.text('Can\'t reach the server'), findsOneWidget);
    server.offline = false;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsOneWidget);
  });

  testWidgets('coming back to the app tries again at once (and not while away)', (tester) async {
    final app = await launch(tester, retry: const [Duration(hours: 1)]);
    app.appVisible = false;
    server.offline = false;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Can\'t reach the server'), findsOneWidget);
    await tester.runAsync(() async {
      app.appVisible = true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsOneWidget);
  });

  testWidgets('"Use a different server", then the same address: still signed in', (tester) async {
    await launch(tester);
    await tester.tap(find.text('Use a different server'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to your server'), findsOneWidget);
    server.offline = false;
    await tester.tap(find.text('Continue')); // the saved address is filled in
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsOneWidget);
    expect(storage.values['session'], 'tok');
  });

  testWidgets('a different address does need a new sign-in', (tester) async {
    await launch(tester);
    await tester.tap(find.text('Use a different server'));
    await tester.pumpAndSettle();
    server.offline = false;
    await tester.enterText(find.byType(TextField), 'other.test');
    await tester.tap(find.text('Continue'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(storage.values.containsKey('session'), isFalse);
  });

  testWidgets('a session the server rejects goes to sign-in, not the offline screen', (tester) async {
    server
      ..offline = false
      ..signedIn = false;
    await launch(tester);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Can\'t reach the server'), findsNothing);
  });
}
