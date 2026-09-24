// Tests for lib/updater/ - the folder-watching app updater. The same file is
// copied into every app that carries the updater; only the package name in
// the imports differs.
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:extron_configurator/updater/folder_updater.dart';
import 'package:extron_configurator/updater/update_platform_io.dart';
import 'package:extron_configurator/updater/update_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake exe: junk, the VS_VERSION_INFO key in UTF-16, padding, then a
/// VS_FIXEDFILEINFO carrying [v].
Uint8List fakeExe(AppBuildVersion v) {
  final b = BytesBuilder();
  b.add(List.filled(300, 0x90));
  for (final c in 'VS_VERSION_INFO'.codeUnits) {
    b.add([c, 0]);
  }
  b.add([0, 0, 0, 0]); // padding to the DWORD boundary
  final info = ByteData(52);
  info.setUint32(0, 0xFEEF04BD, Endian.little);
  info.setUint32(4, 0x00010000, Endian.little);
  info.setUint32(8, (v.major << 16) | v.minor, Endian.little);
  info.setUint32(12, (v.patch << 16) | v.build, Endian.little);
  b.add(info.buffer.asUint8List());
  b.add(List.filled(100, 0));
  return b.takeBytes();
}

/// Minimal zip writer: deflate for most entries, stored for names ending in
/// `.stored`, directories for names ending in `/`.
Uint8List makeZip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final isDir = entry.key.endsWith('/');
    final stored = isDir || entry.key.endsWith('.stored');
    final data = stored
        ? entry.value
        : ZLibEncoder(raw: true).convert(entry.value);
    final offset = out.length;
    final local = ByteData(30);
    local.setUint32(0, 0x04034b50, Endian.little);
    local.setUint16(4, 20, Endian.little);
    local.setUint16(6, 0x800, Endian.little);
    local.setUint16(8, stored ? 0 : 8, Endian.little);
    local.setUint32(18, data.length, Endian.little);
    local.setUint32(22, entry.value.length, Endian.little);
    local.setUint16(26, name.length, Endian.little);
    out.add(local.buffer.asUint8List());
    out.add(name);
    out.add(data);

    final c = ByteData(46);
    c.setUint32(0, 0x02014b50, Endian.little);
    c.setUint16(4, 20, Endian.little);
    c.setUint16(6, 20, Endian.little);
    c.setUint16(8, 0x800, Endian.little);
    c.setUint16(10, stored ? 0 : 8, Endian.little);
    c.setUint32(20, data.length, Endian.little);
    c.setUint32(24, entry.value.length, Endian.little);
    c.setUint16(28, name.length, Endian.little);
    c.setUint32(42, offset, Endian.little);
    central.add(c.buffer.asUint8List());
    central.add(name);
    count++;
  }
  final dirOffset = out.length;
  final dir = central.takeBytes();
  out.add(dir);
  final end = ByteData(22);
  end.setUint32(0, 0x06054b50, Endian.little);
  end.setUint16(8, count, Endian.little);
  end.setUint16(10, count, Endian.little);
  end.setUint32(12, dir.length, Endian.little);
  end.setUint32(16, dirOffset, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

String get runningExeName =>
    Platform.resolvedExecutable.split(RegExp(r'[\\/]')).last;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('folder_updater_test');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('AppBuildVersion', () {
    test('parses pubspec and exe shapes', () {
      expect(AppBuildVersion.tryParse('1.2.3'), const AppBuildVersion(1, 2, 3));
      expect(AppBuildVersion.tryParse('1.2.3+4'),
          const AppBuildVersion(1, 2, 3, 4));
      expect(AppBuildVersion.tryParse('1.2.3.4'),
          const AppBuildVersion(1, 2, 3, 4));
      expect(AppBuildVersion.tryParse('v2'), const AppBuildVersion(2, 0, 0));
      expect(AppBuildVersion.tryParse('9_11_2026'), isNull);
    });

    test('orders by every part, build number last', () {
      const a = AppBuildVersion(1, 1, 0, 2);
      expect(const AppBuildVersion(1, 1, 0, 3) > a, isTrue);
      expect(const AppBuildVersion(1, 2, 0) > a, isTrue);
      expect(const AppBuildVersion(1, 0, 9, 99) > a, isFalse);
      expect(const AppBuildVersion(1, 1, 0, 2) > a, isFalse);
      expect(a.toString(), '1.1.0+2');
      expect(const AppBuildVersion(1, 1, 0).toString(), '1.1.0');
    });
  });

  test('release file names need the prefix and a separator', () {
    expect(isReleaseFileName('cts_dashboard_9_11_2026.zip', 'cts_dashboard'),
        isTrue);
    expect(isReleaseFileName('CTS_Dashboard-1.2.zip', 'cts_dashboard'), isTrue);
    expect(isReleaseFileName('cts_dashboard.zip', 'cts_dashboard'), isTrue);
    expect(isReleaseFileName('cts_dashboards.zip', 'cts_dashboard'), isFalse);
    expect(isReleaseFileName('cts_dashboard_9_11_2026', 'cts_dashboard'),
        isFalse);
    expect(isReleaseFileName('quizzer_9_11_2026.zip', 'cts_dashboard'), isFalse);
  });

  group('exe version resource', () {
    test('reads a synthetic VS_FIXEDFILEINFO', () {
      expect(readExeVersion(fakeExe(const AppBuildVersion(3, 14, 15, 9))),
          const AppBuildVersion(3, 14, 15, 9));
      expect(readExeVersion(Uint8List(1000)), isNull);
    });

    test('reads a real Windows exe', () {
      final notepad = File(r'C:\Windows\System32\notepad.exe');
      if (!notepad.existsSync()) return;
      final v = readExeVersion(notepad.readAsBytesSync());
      expect(v, isNotNull);
      expect(v!.major, greaterThanOrEqualTo(6));
    });
  });

  group('zip reading', () {
    test('finds the exe at the root or one folder down', () {
      final exe = fakeExe(const AppBuildVersion(2, 0, 0, 1));
      final nested = File('${tmp.path}\\nested.zip')
        ..writeAsBytesSync(makeZip({
          'app/': [],
          'app/data/app.so': List.filled(5000, 7),
          'app/my_app.exe': exe,
          'app/deeper/my_app.exe': fakeExe(const AppBuildVersion(9, 0, 0)),
        }));
      final r = inspectReleaseZip(nested.path, 'MY_APP.exe');
      expect(r, isNotNull);
      expect(r!.version, const AppBuildVersion(2, 0, 0, 1));
      expect(r.payloadRoot, 'app/');

      final flat = File('${tmp.path}\\flat.zip')
        ..writeAsBytesSync(makeZip({'my_app.exe.stored': exe}));
      expect(inspectReleaseZip(flat.path, 'my_app.exe'), isNull,
          reason: 'the name must match exactly');
      final flat2 = File('${tmp.path}\\flat2.zip')
        ..writeAsBytesSync(makeZip({'my_app.exe': exe}));
      expect(inspectReleaseZip(flat2.path, 'my_app.exe')!.payloadRoot, '');

      expect(inspectReleaseZip(nested.path, 'other.exe'), isNull);
    });

    test('rejects paths that escape the install folder', () {
      ZipEntry e(String name) => ZipEntry(
          name: name,
          method: 0,
          flags: 0,
          compressedSize: 0,
          size: 0,
          localHeaderOffset: 0);
      expect(payloadRelativePath(e('app/data/x.so'), 'app/'), 'data/x.so');
      expect(payloadRelativePath(e('app/../evil.dll'), 'app/'), isNull);
      expect(payloadRelativePath(e('other/x.dll'), 'app/'), isNull);
      expect(payloadRelativePath(e('app/'), 'app/'), isNull);
      expect(payloadRelativePath(e('C:/x.dll'), ''), isNull);
    });

    test('unpacks deflated and stored entries under the root', () {
      final big = List.generate(300000, (i) => (i * 31) % 251);
      final zip = File('${tmp.path}\\r.zip')
        ..writeAsBytesSync(makeZip({
          'app/': [],
          'app/data/flutter_assets/big.bin': big,
          'app/readme.txt.stored': utf8.encode('hello'),
          'app/empty.txt': [],
          'stray.txt': utf8.encode('outside the root'),
        }));
      final dest = '${tmp.path}\\out';
      final progress = <double>[];
      unpackReleaseZip(zip.path, 'app/', dest, onProgress: progress.add);
      expect(File('$dest\\data\\flutter_assets\\big.bin').readAsBytesSync(),
          big);
      expect(File('$dest\\readme.txt.stored').readAsStringSync(), 'hello');
      expect(File('$dest\\empty.txt').lengthSync(), 0);
      expect(File('$dest\\stray.txt').existsSync(), isFalse);
      expect(File('${tmp.path}\\stray.txt').existsSync(), isFalse);
      expect(progress, isNotEmpty);
    });

    test('reads a zip made by Windows (Compress-Archive)', () async {
      final src = Directory('${tmp.path}\\src\\bundle')
        ..createSync(recursive: true);
      File('${src.path}\\Supported Locations.csv')
          .writeAsStringSync('a,b\n' * 5000);
      Directory('${src.path}\\data').createSync();
      File('${src.path}\\data\\app.so')
          .writeAsBytesSync(List.generate(100000, (i) => i % 256));
      final zipPath = '${tmp.path}\\win.zip';
      final r = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Compress-Archive -Path '${src.path}' -DestinationPath '$zipPath'",
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');

      final dest = '${tmp.path}\\winout';
      unpackReleaseZip(zipPath, 'bundle/', dest);
      expect(File('$dest\\Supported Locations.csv').readAsStringSync(),
          'a,b\n' * 5000);
      expect(File('$dest\\data\\app.so').readAsBytesSync(),
          List.generate(100000, (i) => i % 256));
    });

    test('a truncated zip is an error, not a crash', () {
      final zip = makeZip({'a/x.exe': fakeExe(const AppBuildVersion(1, 0, 0))});
      final f = File('${tmp.path}\\cut.zip')
        ..writeAsBytesSync(zip.sublist(0, zip.length - 30));
      expect(() => inspectReleaseZip(f.path, 'x.exe'),
          throwsA(isA<ZipFormatException>()));
    });
  });

  group('findNewestRelease', () {
    test('picks the newest matching zip that is newer than the app', () async {
      final exeName = runningExeName;
      void release(String file, AppBuildVersion v, {String exe = ''}) {
        File('${tmp.path}\\$file').writeAsBytesSync(makeZip({
          'bundle/${exe.isEmpty ? exeName : exe}': fakeExe(v),
        }));
      }

      release('my_app_9_1_2026.zip', const AppBuildVersion(1, 0, 0, 5));
      release('my_app_9_8_2026.zip', const AppBuildVersion(1, 2, 0));
      release('my_app_9_9_2026.zip', const AppBuildVersion(1, 1, 0));
      release('my_app_admin_9_9_2026.zip', const AppBuildVersion(8, 0, 0),
          exe: 'my_app_admin.exe');
      release('other_9_9_2026.zip', const AppBuildVersion(9, 0, 0));
      File('${tmp.path}\\my_app_broken.zip').writeAsStringSync('not a zip');

      final found = await findNewestRelease(
        folder: tmp.path,
        prefix: 'my_app',
        newerThan: const AppBuildVersion(1, 0, 0, 5),
      );
      expect(found, isNotNull);
      expect(found!.version, const AppBuildVersion(1, 2, 0));
      expect(found.fileName, 'my_app_9_8_2026.zip');
      expect(found.payloadRoot, 'bundle/');

      expect(
          await findNewestRelease(
              folder: tmp.path,
              prefix: 'my_app',
              newerThan: const AppBuildVersion(1, 2, 0)),
          isNull);
    });

    test('a missing folder is reported as unavailable', () {
      expect(
          findNewestRelease(
              folder: '${tmp.path}\\nope',
              prefix: 'x',
              newerThan: const AppBuildVersion(1, 0, 0)),
          throwsA(isA<ReleaseFolderUnavailable>()));
    });
  });

  group('update notice', () {
    FolderUpdater availableUpdater() => FolderUpdater(
          appName: 'Test App',
          releasePrefix: 'test_app',
        )..debugSetAvailable(
            AvailableUpdate(
              version: const AppBuildVersion(2, 0, 0),
              zipPath: r'C:\releases\test_app_1.zip',
              sizeBytes: 1,
              modified: DateTime(2026),
              payloadRoot: '',
            ),
            const AppBuildVersion(1, 0, 0));

    Widget app(FolderUpdater u, {bool hidden = false}) => MaterialApp(
          builder: (context, child) =>
              UpdateNoticeHost(updater: u, hidden: hidden, child: child!),
          home: Scaffold(body: UpdateSettingsSection(updater: u)),
        );

    testWidgets('offers the update and Later hides it', (tester) async {
      final u = availableUpdater();
      await tester.pumpWidget(app(u));
      expect(find.text('Update available'), findsOneWidget);
      expect(find.textContaining('Test App 2.0.0 is ready'), findsOneWidget);

      await tester.tap(find.text('Later'));
      await tester.pump();
      expect(find.text('Update available'), findsNothing);
      // Still installable from settings.
      expect(find.text('Update to 2.0.0'), findsOneWidget);
      u.dispose();
    });

    testWidgets('the notice and settings offer Close and Update in one click',
        (tester) async {
      final u = availableUpdater();
      await tester.pumpWidget(app(u));
      final notice = tester.widget<FilledButton>(
          find.byKey(const ValueKey('update_close_and_update')));
      expect(find.text('Close and Update'), findsOneWidget);
      // Tests are not release builds, so installing is refused up front.
      expect(notice.onPressed, isNull);
      expect(find.text('Close and Update to 2.0.0'), findsOneWidget);
      u.dispose();
    });

    testWidgets('Options asks before closing, and Cancel backs out',
        (tester) async {
      final u = availableUpdater();
      await tester.pumpWidget(app(u));
      await tester.tap(find.text('Options...'));
      await tester.pump();
      expect(find.text('Update to version 2.0.0?'), findsOneWidget);
      final close = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Close and Update'));
      // Tests are not release builds, so installing is refused up front.
      expect(close.onPressed, isNull);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Update available'), findsOneWidget);
      u.dispose();
    });

    testWidgets('hidden keeps the offer away but not a started install',
        (tester) async {
      final u = availableUpdater();
      await tester.pumpWidget(app(u, hidden: true));
      expect(find.text('Update available'), findsNothing);
      await tester.tap(find.text('Update to 2.0.0'));
      await tester.pump();
      expect(find.text('Update to version 2.0.0?'), findsOneWidget);
      u.dispose();
    });

    testWidgets('userBusy holds the offer back until the user is free',
        (tester) async {
      final u = availableUpdater()..setBusy(#game, true);
      await tester.pumpWidget(app(u));
      expect(find.text('Update available'), findsNothing);
      u
        ..setBusy(#typing, true)
        ..setBusy(#game, false);
      await tester.pump();
      expect(find.text('Update available'), findsNothing,
          reason: 'still busy while any reason is');
      u.setBusy(#typing, false);
      await tester.pump();
      expect(find.text('Update available'), findsOneWidget);
      u.dispose();
    });

    testWidgets('a click on the card does not hide it mid-tap',
        (tester) async {
      final u = availableUpdater();
      final watcher = UserActivityWatcher(u)..start();
      await tester.pumpWidget(app(u));
      expect(find.text('Update available'), findsOneWidget);

      // The pointer-down marks the user busy before the tap lands.
      await tester.tap(find.text('Options...'));
      await tester.pump();
      expect(u.userBusy, isTrue);
      expect(find.text('Update to version 2.0.0?'), findsOneWidget);
      expect(find.text('Close and Update'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Update available'), findsOneWidget,
          reason: 'already on screen, so busy does not take it away');
      watcher.dispose();
      u.dispose();
    });
  });

  // [FEATURE - APP UPDATES]: an update offers Desktop and Start menu
  // shortcuts. These make real shortcuts, in temp folders standing in for the
  // Desktop and the Start menu.
  group('shortcuts', () {
    test('file names drop characters Windows refuses', () {
      expect(shortcutFileName('CTS Dashboard'), 'CTS Dashboard');
      expect(shortcutFileName('A/B: "C"?'), 'AB C');
    });

    test('made shortcuts point at the exe and are found again', () async {
      final exe = Platform.resolvedExecutable;
      final desktop = '${tmp.path}\\Desktop';
      final start = '${tmp.path}\\Start Menu';
      Directory(desktop).createSync();

      var found = await findShortcuts(
          exePath: exe, desktopFolders: [desktop], startMenuFolders: [start]);
      expect(found.desktop, isFalse);
      expect(found.startMenu, isFalse);

      await createShortcuts("Test App's",
          desktop: true,
          startMenu: false,
          exePath: exe,
          desktopFolder: desktop,
          startMenuFolder: start);
      expect(File("$desktop\\Test App's.lnk").existsSync(), isTrue);
      found = await findShortcuts(
          exePath: exe, desktopFolders: [desktop], startMenuFolders: [start]);
      expect(found.desktop, isTrue);
      expect(found.startMenu, isFalse);

      // The Start menu folder is made if missing, and searched to any depth.
      await createShortcuts('Test App',
          desktop: false,
          startMenu: true,
          exePath: exe,
          desktopFolder: desktop,
          startMenuFolder: '$start\\Tools');
      found = await findShortcuts(
          exePath: exe, desktopFolders: [desktop], startMenuFolders: [start]);
      expect(found.startMenu, isTrue);

      // A shortcut to some other program does not count.
      found = await findShortcuts(
          exePath: '${tmp.path}\\other.exe',
          desktopFolders: [desktop],
          startMenuFolders: [start]);
      expect(found.desktop, isFalse);
      expect(found.startMenu, isFalse);
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  // [FEATURE - APP UPDATES]: the release folder is editable in Settings, so
  // a build can be tried from a test copy of the folder without a rebuild.
  // The choice is remembered in a file beside the updater's work folder;
  // every test here puts that file back the way it found it.
  group('release folder', () {
    setUp(() => writeSavedReleaseFolder(null));
    tearDown(() => writeSavedReleaseFolder(null));

    FolderUpdater updater({String? folder}) => FolderUpdater(
          appName: 'Test App',
          releasePrefix: 'test_app',
          releaseFolder: folder ?? '${tmp.path}\built_in',
        );

    test('defaults to the folder the app was built with', () {
      final u = updater();
      expect(u.releaseFolder, '${tmp.path}\built_in');
      expect(u.releaseFolderIsCustom, isFalse);
      expect(readSavedReleaseFolder(), isNull);
      u.dispose();
    });

    test('a folder set in Settings is used and remembered', () async {
      final u = updater()..releaseFolder = tmp.path;
      expect(u.releaseFolder, tmp.path);
      expect(u.releaseFolderIsCustom, isTrue);
      expect(readSavedReleaseFolder(), tmp.path,
          reason: 'saved for the next launch');
      await u.checkNow();
      u.dispose();

      // A fresh updater - the next launch - starts on the saved folder.
      final next = updater();
      expect(next.releaseFolder, tmp.path);
      expect(next.builtInReleaseFolder, '${tmp.path}\built_in');
      next.dispose();
    });

    test('blank leaves the folder alone', () {
      final u = updater()..releaseFolder = '   ';
      expect(u.releaseFolder, '${tmp.path}\built_in');
      expect(readSavedReleaseFolder(), isNull);
      u.dispose();
    });

    test('Use default forgets the folder that was set', () async {
      final u = updater()..releaseFolder = tmp.path;
      expect(readSavedReleaseFolder(), isNotNull);

      u.resetReleaseFolder();
      expect(u.releaseFolder, '${tmp.path}\built_in');
      expect(u.releaseFolderIsCustom, isFalse);
      expect(readSavedReleaseFolder(), isNull);
      await u.checkNow();
      u.dispose();
    });

    test('reachable says whether the folder can be seen from here', () {
      final u = updater(folder: tmp.path);
      expect(u.releaseFolderReachable, isTrue);
      u.releaseFolder = '${tmp.path}\nope';
      expect(u.releaseFolderReachable, isFalse,
          reason: 'the hint under the field reports this');
      u.dispose();
    });
  });

  group('timed checks', () {
    // The folder is missing, so a check ends quickly as folderUnavailable.
    FolderUpdater updater({required Duration first, required Duration every}) =>
        FolderUpdater(
          appName: 'Test App',
          releasePrefix: 'test_app',
          releaseFolder: '${tmp.path}\\nope',
          firstCheckDelay: first,
          checkInterval: every,
        );

    test('the launch check runs even when the user is busy', () async {
      final u = updater(first: Duration.zero, every: const Duration(hours: 1))
        ..setBusy(#game, true);
      await u.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await u.checkNow(); // joins it if it is still running
      expect(u.lastChecked, isNotNull);
      u.dispose();
    });

    test('later checks wait while the user is busy, then run', () async {
      final u = updater(
          first: const Duration(hours: 1),
          every: const Duration(milliseconds: 20))
        ..setBusy(#game, true);
      await u.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(u.lastChecked, isNull, reason: 'no check while busy');

      u.setBusy(#game, false);
      await u.checkNow(); // joins the check that was held back
      expect(u.lastChecked, isNotNull);
      u.dispose();
    });
  });

  testWidgets('UserActivityWatcher stays busy until the user stops',
      (tester) async {
    final u = FolderUpdater(appName: 'Test App', releasePrefix: 'test_app');
    final watcher =
        UserActivityWatcher(u, quietPeriod: const Duration(seconds: 10))
          ..start();
    await tester.pumpWidget(
        const MaterialApp(home: Material(child: TextField(autofocus: true))));
    await tester.pump();

    expect(u.userBusy, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(u.userBusy, isTrue);
    await tester.pump(const Duration(seconds: 6));
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(seconds: 6));
    expect(u.userBusy, isTrue, reason: 'the click restarted the quiet period');
    await tester.pump(const Duration(seconds: 5));
    expect(u.userBusy, isFalse);

    watcher.dispose();
    u.dispose();
  });

  group('apply helper script', () {
    late Directory install;
    late Directory staged;
    late Directory work;

    setUp(() {
      install = Directory('${tmp.path}\\install O\'Brien')..createSync();
      staged = Directory('${tmp.path}\\staged')..createSync();
      work = Directory('${tmp.path}\\work')..createSync();
      void put(Directory d, String rel, String text) {
        final f = File('${d.path}\\$rel');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(text);
      }

      put(install, 'my_app.exe', 'old exe');
      put(install, 'plugin.dll', 'old dll');
      put(install, 'data\\app.so', 'old so');
      put(install, 'config.json', 'user config');
      put(install, 'logs\\today.log', 'user log');

      put(staged, 'my_app.exe', 'new exe');
      put(staged, 'plugin.dll', 'new dll');
      put(staged, 'new_plugin.dll', 'new plugin');
      put(staged, 'data\\app.so', 'new so');
      put(staged, 'data\\flutter_assets\\added.json', 'new asset');
      put(staged, 'config.json', 'releaser config');
      put(staged, 'logs\\today.log', 'releaser log');
      put(staged, 'reference.csv', 'new reference file');
    });

    Future<ProcessResult> runScript({int moveAttempts = 40}) async {
      final script = File('${work.path}\\apply_update.ps1');
      script.writeAsBytesSync([
        0xEF, 0xBB, 0xBF,
        ...utf8.encode(buildApplyScript(
          processId: 999999,
          installDir: install.path,
          exeName: 'my_app.exe',
          stagedDir: staged.path,
          workDir: work.path,
          workingDirectory: install.path,
          arguments: const ['--kiosk'],
          fromVersion: '1.0.0',
          toVersion: '1.1.0',
          elevated: false,
          startApp: false,
          moveAttempts: moveAttempts,
        )),
      ]);
      return Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
      ]);
    }

    String read(String rel) => File('${install.path}\\$rel').readAsStringSync();

    Map<String, dynamic> result() {
      var text = File('${work.path}\\last_update.json').readAsStringSync();
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      return jsonDecode(text) as Map<String, dynamic>;
    }

    test('replaces the program and keeps the user files', () async {
      final r = await runScript();
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(result()['ok'], isTrue, reason: '${result()}');
      expect(result()['to'], '1.1.0');

      expect(read('my_app.exe'), 'new exe');
      expect(read('plugin.dll'), 'new dll');
      expect(read('new_plugin.dll'), 'new plugin');
      expect(read('data\\app.so'), 'new so');
      expect(read('data\\flutter_assets\\added.json'), 'new asset');
      expect(read('reference.csv'), 'new reference file');
      expect(read('config.json'), 'user config');
      expect(read('logs\\today.log'), 'user log');

      expect(File('${work.path}\\helper_started.txt').existsSync(), isTrue);
      expect(File('${work.path}\\backup\\my_app.exe').readAsStringSync(),
          'old exe');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('rolls back when a file cannot be replaced', () async {
      // Holding app.so open without delete sharing makes the move fail.
      final lock = File('${install.path}\\data\\app.so')
          .openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      try {
        final r = await runScript(moveAttempts: 1);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      } finally {
        lock.unlockSync();
        lock.closeSync();
      }
      expect(result()['ok'], isFalse, reason: '${result()}');
      expect(read('my_app.exe'), 'old exe');
      expect(read('plugin.dll'), 'old dll');
      expect(read('data\\app.so'), 'old so');
      expect(File('${install.path}\\new_plugin.dll').existsSync(), isFalse);
      expect(File('${install.path}\\reference.csv').existsSync(), isFalse);
      expect(read('config.json'), 'user config');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
