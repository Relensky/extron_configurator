import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/flow_rules.dart';

/// What a Root Folder starts with, and an avatar kept in it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String root;
  late String app;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('root_defaults_');
    root = path.join(dir.path, 'root');
    app = path.join(dir.path, 'app');
    Directory(root).createSync();
    // What the installer puts beside the app.
    File(path.join(app, 'devices', 'extr_switcher.py'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# module');
    File(path.join(app, 'documentation', 'manual.pdf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('pdf');
    AppStateProvider.appBaseDirForTest = app;
  });
  tearDown(() {
    AppStateProvider.appBaseDirForTest = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('the Root Folder starts with', () {
    test('a blank rules file, and the devices and documentation folders',
        () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = root;
      final made = await p.ensureRootDefaults(force: true);
      expect(made, hasLength(3));

      final rules = File(path.join(root, 'av_flow_rules.json'));
      final doc = jsonDecode(rules.readAsStringSync()) as Map<String, dynamic>;
      // Blank still draws the way the app always has.
      expect(
        FlowRules.fromJson(doc).sourceBoxes.length,
        FlowRules.builtIn().sourceBoxes.length,
      );

      // Filled from the installed copies, so nothing is lost by moving.
      expect(
        File(path.join(root, 'devices', 'extr_switcher.py')).existsSync(),
        isTrue,
      );
      expect(
        File(path.join(root, 'documentation', 'manual.pdf')).existsSync(),
        isTrue,
      );
      expect(p.effectiveModulesPath, path.join(root, 'devices'));
      expect(p.effectiveDocumentationPath, path.join(root, 'documentation'));
      // No half-copied folder left behind.
      expect(
        Directory(root).listSync().map((e) => path.basename(e.path)),
        isNot(contains(startsWith('devices.partial'))),
      );
    });

    test('the installed rules rather than a blank file, when there are some',
        () async {
      File(path.join(app, 'av_flow_rules.json')).writeAsStringSync('{"x":1}');
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = root;
      await p.ensureRootDefaults(force: true);
      expect(
        File(path.join(root, 'av_flow_rules.json')).readAsStringSync(),
        '{"x":1}',
      );
    });

    test('nothing already there is touched, nor anything chosen elsewhere',
        () async {
      File(path.join(root, 'av_flow_rules.json')).writeAsStringSync('mine');
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = root
        ..modulesPath = path.join(dir.path, 'elsewhere');
      final made = await p.ensureRootDefaults(force: true);
      expect(made, [path.join(root, 'documentation')]);
      expect(
        File(path.join(root, 'av_flow_rules.json')).readAsStringSync(),
        'mine',
      );
      expect(Directory(path.join(root, 'devices')).existsSync(), isFalse);
    });

    test('not under test unless asked - a test must not write to a share',
        () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = root;
      expect(await p.ensureRootDefaults(), isEmpty);
    });
  });

  group('the avatar', () {
    /// A copy of the app on its own computer: same root, its own local
    /// folder.
    AppStateProvider computer(String name) => AppStateProvider(
          autoLoadSettings: false,
        )
          ..rootFolderPath = root
          ..localAvatarFolderOverride = path.join(dir.path, 'local_$name');

    String shareFolder() => path.join(root, 'assets', 'avatars');

    test('is kept in the root\'s assets folder, named for the login, and '
        'drawn from a local copy', () async {
      final p = computer('mine');
      expect(p.myAvatarFile, isNull);

      final picture = File(path.join(dir.path, 'me.png'))
        ..writeAsBytesSync([1, 2, 3]);
      expect(await p.setMyAvatar(picture.path), isEmpty);

      // On the share, for everybody...
      final stem = path.basenameWithoutExtension(p.myAvatarFile!);
      final onShare = File(path.join(shareFolder(), '$stem.png'));
      expect(onShare.readAsBytesSync(), [1, 2, 3]);
      // ...and drawn from this computer's own copy, at once.
      final kept = p.myAvatarFile!;
      expect(path.dirname(kept), p.localAvatarFolder);
      expect(File(kept).readAsBytesSync(), [1, 2, 3]);

      // Somebody else on the same root gets their own copy once it has been
      // checked against the share.
      final other = computer('theirs');
      expect(other.avatarFileFor(p.collab.me.user), isNull);
      await other.refreshAvatar(p.collab.me.user);
      final theirs = other.avatarFileFor(p.collab.me.user)!;
      expect(path.dirname(theirs), other.localAvatarFolder);
      expect(File(theirs).readAsBytesSync(), [1, 2, 3]);

      // A JPEG replaces the PNG rather than sitting beside it.
      final jpeg = File(path.join(dir.path, 'me.jpg'))..writeAsBytesSync([4]);
      expect(await p.setMyAvatar(jpeg.path), isEmpty);
      expect(path.extension(p.myAvatarFile!), '.jpg');
      expect(onShare.existsSync(), isFalse);
      expect(File(kept).existsSync(), isFalse);

      await p.removeMyAvatar();
      expect(p.myAvatarFile, isNull);
    });

    test('a different file on the share replaces the local copy; none there '
        'takes it away; a share not answering leaves it', () async {
      final p = computer('mine');
      final picture = File(path.join(dir.path, 'me.png'))
        ..writeAsBytesSync([1, 2, 3]);
      await p.setMyAvatar(picture.path);
      final user = p.collab.me.user;
      final local = p.myAvatarFile!;
      final onShare =
          File(path.join(shareFolder(), path.basename(local)));

      // Changed on the share from another computer.
      onShare.writeAsBytesSync([9, 9]);
      await p.refreshAvatar(user);
      expect(File(p.avatarFileFor(user)!).readAsBytesSync(), [9, 9]);

      // The share unreachable: the copy stays.
      final moved = Directory(shareFolder()).renameSync('${shareFolder()}_x');
      await p.refreshAvatar(user);
      expect(p.avatarFileFor(user), local);
      moved.renameSync(shareFolder());

      // Taken off the share: taken away here too.
      onShare.deleteSync();
      await p.refreshAvatar(user);
      expect(p.avatarFileFor(user), isNull);
      expect(File(local).existsSync(), isFalse);
    });

    test('only takes a picture', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = root;
      final text = File(path.join(dir.path, 'notes.txt'))..writeAsStringSync('');
      expect(await p.setMyAvatar(text.path), contains('PNG or JPEG'));
    });
  });
}
