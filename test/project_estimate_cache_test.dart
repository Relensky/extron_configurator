import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// Pricing a job once per change instead of once per frame.
///
/// The Project tab asks for the estimate on every build, and it rebuilds on
/// every keystroke. A forty-room job is about a thousand priced lines merged
/// onto one master list, so the tab was pricing the whole building several
/// times a second while somebody typed its name into a box.
///
/// The failure this guards is the other one: a cached answer that outlives the
/// change that invalidated it. A quote that is fast and wrong is worse than a
/// quote that is slow.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_estimate_cache'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'd1',
          label: 'Lectern TX',
          model: 'DTP2 T 211',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
      ],
    }));
    return configPath;
  }

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'DTP2 T 211',
        manufacturer: 'Extron',
        partNumber: '60-1439-13',
        category: 'Transmitter',
        price: 500,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.addRoomToProject(writeRoom('a', 'Bessey 101'));
    return p;
  }

  test('asking twice with nothing in between is asking once', () {
    final p = withProject();
    final first = p.priceProject();
    // The same object, not an equal one: the tab asks for this on every build
    // and the point is that no work happened the second time.
    expect(identical(p.priceProject(), first), isTrue);
  });

  test('typing a job name does not re-price the building', () {
    final p = withProject();
    final first = p.priceProject();

    p.setProjectField(name: 'Bessey Hall AV refresh');
    // The estimate holds the project itself, so the new name is already on the
    // cached answer — there is nothing to recompute and nothing stale.
    final after = p.priceProject();
    expect(identical(after, first), isTrue);
    expect(after.project.name, 'Bessey Hall AV refresh');
  });

  test('changing the currency does re-price it', () {
    final p = withProject();
    final first = p.priceProject();

    p.setProjectField(currency: '€');
    final after = p.priceProject();
    // Every money figure on the estimate was formatted with the old symbol.
    expect(identical(after, first), isFalse);
    expect(after.currency, '€');
  });

  group('a change that moves a number is never served from the cache', () {
    test('a second room', () {
      final p = withProject();
      final before = p.priceProject().grandTotal;
      p.addRoomToProject(writeRoom('b', 'Bessey 103'));
      expect(p.priceProject().grandTotal, greaterThan(before));
    });

    test('a room taken off the job', () {
      final p = withProject();
      expect(p.priceProject().grandTotal, greaterThan(0));

      p.updateProjectRoom(p.project.rooms.first.id, included: false);
      expect(p.priceProject().grandTotal, 0);
    });

    test('a room renamed on the job', () {
      final p = withProject();
      expect(p.priceProject().rooms.first.name, 'Bessey 101');

      // Room refs are immutable and a label edit replaces one, so a cached
      // estimate would go on holding the ref it was built with.
      p.updateProjectRoom(
        p.project.rooms.first.id,
        label: 'Bessey 101 (phase 2)',
      );
      expect(p.priceProject().rooms.first.name, 'Bessey 101 (phase 2)');
    });

    test('a part pinned to another vendor', () {
      final p = withProject();
      final line = p.priceProject().master.first;
      final vendor = p.project.vendors.last;

      p.pinProjectPart(line.key, vendor.id, partName: line.description);
      expect(p.priceProject().master.first.vendor?.id, vendor.id);
    });

    test('saving the open room re-reads that room and no other', () async {
      final p = withProject();
      final second = writeRoom('b', 'Bessey 103');
      p.addRoomToProject(second);
      expect(
        [for (final r in p.priceProject().rooms) r.name],
        ['Bessey 101', 'Bessey 103'],
      );

      // The open room, edited and saved.
      await p.openConfigAtPath(p.project.rooms.first.configPath);
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      setup['gui_full_room_name'] = 'Bessey 101 West';
      // Somebody else's window moved the OTHER room while this one was being
      // saved. It stays cached: a save is not a Refresh, and re-reading forty
      // files to learn that one of them moved is what this replaced.
      writeRoom('b', 'Bessey 103 Annex');

      await p.saveCurrentConfigToFile();

      final after = [for (final r in p.priceProject().rooms) r.name];
      expect(after.first, 'Bessey 101 West', reason: 'the room that changed');
      expect(after[1], 'Bessey 103', reason: 'still the cached read');

      // And Refresh is still the thing that picks the other one up.
      p.refreshProjectRooms();
      expect(p.priceProject().rooms[1].name, 'Bessey 103 Annex');
    });

    test('the rooms being re-read off disk', () {
      final p = withProject();
      expect(p.priceProject().rooms.first.name, 'Bessey 101');

      // Somebody else's window saved the room. Refresh is the only thing that
      // can know, and the estimate has to follow it.
      writeRoom('a', 'Bessey 101 West');
      p.refreshProjectRooms();
      expect(p.priceProject().rooms.first.name, 'Bessey 101 West');
    });
  });
}
