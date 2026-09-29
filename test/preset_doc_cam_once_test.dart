import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/save_actions.dart';

/// A room type's document camera is the room's document camera: reopening
/// the room must not draw a second one for the doc cam input.
void main() {
  test('a room built from a room type has one document camera', () async {
    final dir = Directory.systemTemp.createTempSync('doc_cam_once_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final provider = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = Directory.current.path;
    await provider.loadUiSchema();
    await provider.loadKeyMap();
    await provider.loadAvDeviceLibrary();
    await provider.loadFlowRules();
    provider.newProject(name: 'Doc cam');
    provider.addProjectManualRoomList('ARTS 111\t4 Projector 1 Cam 1 Mic');
    final built = await buildLineItemRooms(
      provider,
      List.of(provider.project.manualRooms),
      dir.path,
    );
    expect(built.built, ['ARTS 111']);

    final file = path.join(dir.path, 'ARTS_111_config.json');
    expect(provider.roomConfig['SYSTEM_SETUP']['input_doc_cam'], isNotEmpty);
    expect(await provider.openConfigAtPath(file, remember: false), isTrue);
    provider.loadAvFlowForCurrentConfig();

    final docCams = provider.avNodes
        .where((n) => n.model.toLowerCase().startsWith('document camera'))
        .toList();
    expect(docCams.map((n) => n.model), ['Document Camera (DC-13)']);
  });
}
