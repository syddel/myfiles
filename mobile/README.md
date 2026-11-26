# MyFiles mobile app

A Flutter app for Android and iOS that talks to your MyFiles server. It uses the same API as the website, so the server needs no changes and your accounts, files, folder color and theme are shared between the two.

## What it does

- Connect to your server by address (`files.example.com`, `https://example.com/files`, `http://192.168.1.10:8000`), then sign in, or register if the server allows it. The session is kept in the phone's secure storage (Keychain / Keystore).
- Browse folders as a list, folders first. Sort by name, date or size, and pull down to refresh. The `..` row and the system Back gesture go up a level.
- Upload files from the phone with a progress bar. Two files upload at a time. Each upload can be cancelled. The app checks your quota before it starts.
- Preview images (pinch to zoom), video, audio and text files. Swipe between the files in a folder.
- Audio files (music, podcasts) keep playing when you leave the player, switch apps or lock the screen. Controls appear in the notification and on the lock screen, and headset and Bluetooth buttons work. A mini player at the bottom of every screen shows what's playing; tap it to open the full player. Audio pauses for phone calls and when headphones are unplugged.
  - It continues where you left off: the position in each audio file is saved on the phone (per server and account), and **Start over** goes back to the beginning. Files you listened to the end start from the beginning next time.
  - Buttons skip back 10 seconds and forward 30 seconds. Playback speed can be 1×, 1.25×, 1.5× or 2×, and the app remembers your choice.
- **Playlist** (one at a time, kept on the phone per server and account). Use "Add to playlist" in an audio file's ⋮ menu, in a folder's menu (adds the audio files directly in it, by name), on a selection, or in the player. Files are added to the end of the playlist.
  - Files play one after another, in the background too. Previous and next are in the player, the notification and on the lock screen.
  - The playlist remembers which file you were on, and each file's position, so **Continue** picks up exactly where you stopped.
  - On the playlist screen (the playlist icon at the top of the file list), drag files to reorder them, swipe one left to remove it, **Shuffle** to mix up the order (the file you're on moves to the top) or **Clear** to empty it. Clearing is how you start a new playlist. The ⋮ menu's **Start all from the beginning** forgets the saved position of every file in the playlist.
  - On Android, audio keeps playing even if you swipe the app away from the recent-apps list. iOS always stops an app that's swiped away, audio included.
- Turn the phone sideways while a video plays and it fills the whole screen. Tap the video to show the controls, which fade out again while it plays. The zoom button (or a double-tap) fills the screen completely by cropping the edges of the picture.
- PDFs and other files open in another app with **Open with…**. **Save / send** hands a file to the phone's share sheet (Save to Files, email…). A folder, or a selection of several items, downloads as a zip.
- New folder, rename, move (with a folder picker) and delete. Long-press an item to select several.
- Search all your files and folders.
- Share a file or folder by link: view only, or view & upload for folders. You can set a password, copy the link, or stop sharing. **Account → Shared links** lists everything you share.
- Account page: storage used against your quota, light/dark/system theme, folder color, change password, change server, sign out.

Admin pages (user quotas) stay on the website.

The app icon and splash screen use the website's folder icon in orange. On Android the icon is the folder alone, with no background. On iOS it sits on white, because iOS requires app icons to be opaque. The icon artwork is in `android/app/src/main/res/` (`ic_launcher_foreground.xml`, `launch_folder.xml`, `splash_icon.xml`, plus PNGs in the `mipmap-*` folders) and in `ios/Runner/Assets.xcassets/`.

## Building

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.50 or later), plus Android Studio / the Android SDK for Android, or Xcode on a Mac for iOS.

```sh
cd mobile
flutter pub get
flutter run                      # on a connected phone or emulator

flutter build apk --release      # Android: build/app/outputs/flutter-apk/app-release.apk
flutter build ipa                # iOS (needs an Apple developer account to install on a phone)
```

To install the APK, copy it to the phone and open it, allowing installs from that source when Android asks. Or, with the phone connected over USB and USB debugging on, run `flutter install`.

The release APK is signed with the debug key. That's fine for installing it yourself. To publish it on an app store, set up signing as described in [Flutter's Android release guide](https://docs.flutter.dev/deployment/android).

### Plain http:// servers

Use https if you can. The app also accepts `http://` addresses for servers on your home network: Android's cleartext setting and iOS's App Transport Security exception are both enabled. If your server is only reached over https, you can remove `android:usesCleartextTraffic` from `android/app/src/main/AndroidManifest.xml` and the `NSAppTransportSecurity` block from `ios/Runner/Info.plist`.

## Development

```sh
flutter analyze
flutter test                                                              # unit + widget tests (fake server)
MYFILES_TEST_SERVER=http://localhost:8000 flutter test test/server_api_test.dart  # against a real server
```

The real-server test registers a throwaway user, so the server must have `REGISTRATION_MODE=open`. Use a development server, not your real one.

```
lib/
  api/          API client (dio) and data models
  state/        app state (server, session, preferences), upload queue
  screens/      server address, sign in, folder list, preview, search, account, shared links
  widgets/      item menu actions, share sheet, folder picker, upload banner, dialogs
  util/         sizes/dates/icons, downloading and opening files
test/           unit tests, widget tests against a fake server, real-server API test
```

The app signs in through `/api/auth/login` and sends the session token as the `myfiles_session` cookie on each request, together with the `X-Requested-With: myfiles` header the server requires for changes. Video, audio and images are streamed straight from `/api/files/{id}/content` with the same headers.
