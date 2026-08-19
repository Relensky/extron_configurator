import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// The Active Deployment Target is the room the next upload talks to, and it
/// belongs to the room that was open when somebody picked it. Carried across a
/// file open, it becomes the quietest mistake this app can make: BSS 103's
/// config, uploaded to SSC 210's processor, with the tab that says so two
/// screens away.
///
/// So opening or creating a different config drops it. The SFTP download does
/// not — that config came off the target, and the target is exactly right.
void main() {
  late Directory dir;
  late String templatePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('deployment_target_test_');
    templatePath = path.join(dir.path, 'config.json');
    File(templatePath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
    }));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> room() =>
      {'roomId': '2', 'roomName': 'SSC 210', 'ip': '10.248.210.8'};

  test('a new config from the template clears it', () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = templatePath
      ..selectProcessor(room());

    expect(await p.createNewConfig(), isTrue);

    expect(p.selectedProcessor, isNull,
        reason: 'a room built from the template has been deployed nowhere');
  });

  test('clearing announces itself once, and is quiet with nothing to clear',
      () {
    final p = AppStateProvider(autoLoadSettings: false);
    var notifications = 0;
    p.addListener(() => notifications++);

    // Nothing selected: nothing to say, and no rebuild to ask for.
    p.clearDeploymentTarget();
    expect(notifications, 0);

    p.selectProcessor(room());
    p.clearDeploymentTarget();
    expect(p.selectedProcessor, isNull);
    expect(notifications, 2, reason: 'the pick and the clear');
  });
}
