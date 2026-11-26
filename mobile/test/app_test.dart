import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:myfiles_mobile/main.dart';
import 'package:myfiles_mobile/state/app_state.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late MemoryStorage storage;

  setUp(() {
    server = FakeServer();
    storage = MemoryStorage();
  });

  Future<AppState> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final app = AppState(storage, makeClient: server.client);
    await tester.pumpWidget(MyFilesApp(state: app));
    await tester.runAsync(app.start);
    await tester.pumpAndSettle();
    return app;
  }

  Future<void> signIn(WidgetTester tester) async {
    storage.values['server'] = 'https://files.test/';
    storage.values['session'] = 'tok';
    server.signedIn = true;
  }

  testWidgets('first launch: server address, then sign in, then Home', (tester) async {
    await launch(tester);
    expect(find.text('Connect to your server'), findsOneWidget);

    // The keyboard is asked not to change anything typed into the address box.
    final box = tester.widget<TextField>(find.byType(TextField));
    expect(box.keyboardType, TextInputType.url);
    expect(box.textCapitalization, TextCapitalization.none);
    expect(box.autocorrect, isFalse);
    expect(box.enableSuggestions, isFalse);
    expect(box.smartDashesType, SmartDashesType.disabled);
    expect(box.smartQuotesType, SmartQuotesType.disabled);
    expect(box.spellCheckConfiguration, const SpellCheckConfiguration.disabled());
    expect(box.enableIMEPersonalizedLearning, isFalse);
    await tester.tap(find.byType(TextField)); // focus it: that's when the keyboard gets these settings
    await tester.pump();
    final config = tester.testTextInput.setClientArgs!;
    expect(config['inputType']['name'], 'TextInputType.url');
    expect(config['autocorrect'], isFalse);
    expect(config['enableSuggestions'], isFalse);
    expect(config['textCapitalization'], 'TextCapitalization.none');

    await tester.enterText(find.byType(TextField), 'files.test');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Test Files'), findsOneWidget);
    expect(find.text('No account yet? Register'), findsOneWidget);
    expect(storage.values['server'], 'https://files.test/');

    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'alice');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong username or password'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(storage.values['session'], 'tok');
  });

  testWidgets('remembers the session and lists folders first, then files', (tester) async {
    await signIn(tester);
    await launch(tester);
    final names = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => ((t.title as Row).children.first as Flexible).child)
        .map((t) => (t as Text).data)
        .toList();
    expect(names, ['Photos', 'notes.txt', 'report.pdf']);
    expect(find.text('..'), findsNothing); // not in Home
  });

  testWidgets('open a folder, then ".." goes back up', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.text('Home / Photos'), findsOneWidget);
    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('beach.jpg'), findsNothing);
  });

  testWidgets('new folder from the + button', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Taxes');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Taxes'), findsOneWidget);
    expect(server.requests, contains('POST folders'));
  });

  testWidgets('rename from the item menu', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'notes.txt'), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'todo.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.text('todo.txt'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
  });

  testWidgets('long-press to select, then move into a folder', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.longPress(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Move'));
    await tester.pumpAndSettle();
    expect(find.text('Move 2 items'), findsOneWidget);
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();

    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('report.pdf'), findsNothing);
    expect(server.nodes[3]!['parent_id'], 2);
    expect(find.text('Moved 2 items'), findsOneWidget);
  });

  testWidgets('a folder can\'t be moved into itself', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.longPress(find.text('Photos'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move'));
    await tester.pumpAndSettle();
    final photos = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Photos'));
    expect(photos.enabled, isFalse);
  });

  testWidgets('delete asks first', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Photos'), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Photos"?'), findsOneWidget);
    expect(find.textContaining('everything inside'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsNothing);
    expect(server.nodes.containsKey(4), isFalse);
  });

  testWidgets('text files open in the preview', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.text('hello world\n'), findsOneWidget);
    expect(find.byTooltip('Open with…'), findsOneWidget);
  });

  testWidgets('search finds files in other folders', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'beach');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.textContaining('Home/Photos'), findsOneWidget);
  });

  testWidgets('share a folder by link, then stop sharing', (tester) async {
    await signIn(tester);
    await launch(tester);
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Photos'), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share by link…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share (view & upload)'));
    await tester.pumpAndSettle();
    expect(find.text('https://files.test/s/abc2'), findsOneWidget);
    expect(server.shares[2]!['mode'], 'readwrite');

    await tester.tap(find.text('Stop sharing'));
    await tester.pumpAndSettle();
    expect(server.shares, isEmpty);
    expect(find.text('Stop sharing'), findsNothing); // sheet closed
  });

  testWidgets('account: folder color applies to folder icons, theme, sign out', (tester) async {
    await signIn(tester);
    final app = await launch(tester);
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('295 KB of 15 GB used'), findsOneWidget);

    await tester.tap(find.byTooltip('Green'));
    await tester.pumpAndSettle();
    expect(server.folderColor, 'green');
    expect(app.folderColor, 'green');

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(server.theme, 'dark');
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);

    await tester.scrollUntilVisible(find.text('Sign out'), 100);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(storage.values.containsKey('session'), isFalse);
    expect(find.text('Account'), findsNothing); // no pages left behind
  });

  testWidgets('an expired session goes back to sign in', (tester) async {
    await signIn(tester);
    await launch(tester);
    server.signedIn = false;
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });
}
