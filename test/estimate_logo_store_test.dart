import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_logo_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a logo goes beside the avatars on the share, with a local copy, and '
      'an export still finds it when the original is gone', () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = path.join(dir.path, 'share');
    final picked = File(path.join(dir.path, 'logo.png'))
      ..writeAsBytesSync([1, 2, 3]);

    expect(await p.setMyEstimateLogo(picked.path), '');
    final shared = File(p.estimateLogoPath);
    expect(path.dirname(shared.path), p.logoFolder);
    expect(path.dirname(p.logoFolder), path.dirname(p.avatarFolder));
    expect(shared.readAsBytesSync(), [1, 2, 3]);
    expect(
      File(path.join(p.localLogoFolder, path.basename(shared.path)))
          .existsSync(),
      isTrue,
    );

    // The share copy goes missing: the export uses this computer's copy.
    picked.deleteSync();
    shared.deleteSync();
    expect(p.estimateLogoForExport,
        path.join(p.localLogoFolder, path.basename(shared.path)));
    Directory(p.localLogoFolder).deleteSync(recursive: true);
  });

  test('anything but a PNG or JPEG is refused', () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = path.join(dir.path, 'share');
    final picked = File(path.join(dir.path, 'logo.gif'))..writeAsStringSync('x');
    expect(await p.setMyEstimateLogo(picked.path), isNotEmpty);
    expect(p.estimateLogoPath, '');
  });
}
