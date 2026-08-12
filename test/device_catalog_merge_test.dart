import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/device_merge.dart';

/// The device catalog is the one file two engineers both edit: one prices the
/// switchers, the other draws their connectors. Merging has to be per
/// difference — never "theirs wins" — and it must never delete a model or
/// overwrite something you filled in with a blank they never got to.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('av_catalog_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AvPort port(String id, PortDirection d) => AvPort(
    id: id,
    label: id.toUpperCase(),
    signal: SignalType.hdmi,
    direction: d,
    side: d == PortDirection.output ? PortSide.right : PortSide.left,
  );

  AvDeviceTemplate entry(
    String model, {
    String manufacturer = '',
    int rackUnits = 0,
    double powerWatts = 0,
    double price = 0,
    List<AvPort> ports = const [],
  }) => AvDeviceTemplate(
    model: model,
    manufacturer: manufacturer,
    rackUnits: rackUnits,
    powerWatts: powerWatts,
    price: price,
    ports: ports,
  );

  String write(String name, List<AvDeviceTemplate> devices) {
    final file = path.join(dir.path, name);
    File(file).writeAsStringSync(
      jsonEncode({'devices': [for (final d in devices) d.toJson()]}),
    );
    return file;
  }

  group('the catalog file', () {
    test('round-trips the facts a room is planned from', () async {
      final library = AvDeviceLibrary.empty();
      library.upsert(
        entry(
          'Switcher Y',
          manufacturer: 'Extron',
          rackUnits: 2,
          powerWatts: 90,
          price: 2500.5,
          ports: [port('in_1', PortDirection.input)],
        ).copyWith(partNumber: '60-1439-13', category: 'Switcher'),
      );

      final target = path.join(dir.path, 'av_devices.json');
      expect(await library.save(toPath: target), target);

      final back = await AvDeviceLibrary.readFile(target);
      final restored = back.templateForModel('switcher y')!;
      expect(restored.model, 'Switcher Y');
      expect(restored.manufacturer, 'Extron');
      expect(restored.partNumber, '60-1439-13');
      expect(restored.category, 'Switcher');
      expect(restored.rackUnits, 2);
      expect(restored.powerWatts, 90);
      expect(restored.price, 2500.5);
      // The mains inlet is reconciled onto the entry as it is written — see
      // test/catalog_power_inlet_test.dart — so the signal connectors are the
      // ones to compare.
      expect(
        [for (final p in restored.ports.where((p) => !p.isPowerInlet)) p.id],
        ['in_1'],
      );
      expect(restored.ports.where((p) => p.isPowerInlet).length, 1);
    });

    test('writes only the entries that are yours', () async {
      // Built-ins the user never touched must stay out of the file, so a
      // later app build can still improve them.
      final library = AvDeviceLibrary.builtIn();
      final builtInCount = library.modelCount;
      library.upsert(entry('My Custom Box', price: 400));

      final target = path.join(dir.path, 'av_devices.json');
      await library.save(toPath: target);

      final written = jsonDecode(File(target).readAsStringSync());
      expect((written['devices'] as List).length, 1);
      expect(library.modelCount, builtInCount + 1);
    });

    test('an exported copy does not repoint later saves', () async {
      final library = AvDeviceLibrary.empty()..filePath = path.join(dir.path, 'mine.json');
      library.upsert(entry('Box', price: 1));

      final copy = path.join(dir.path, 'for_a_colleague.json');
      await library.save(toPath: copy, rebind: false);

      expect(File(copy).existsSync(), isTrue);
      expect(library.filePath, path.join(dir.path, 'mine.json'));
    });

    test('a renamed entry does not leave its old name behind', () {
      final library = AvDeviceLibrary.empty();
      library.upsert(entry('Old Name', price: 10));
      library.upsert(
        entry('New Name', price: 10),
        previousModel: 'Old Name',
      );

      expect(library.templateForModel('Old Name'), isNull);
      expect(library.templateForModel('New Name')?.price, 10);
      expect(library.modelCount, 1);
    });
  });

  group('merging another catalog', () {
    AvDeviceLibrary mine() {
      final library = AvDeviceLibrary.empty();
      library.upsert(
        entry(
          'Switcher Y',
          manufacturer: 'Extron',
          rackUnits: 2,
          price: 2500,
          ports: [port('in_1', PortDirection.input)],
        ),
      );
      library.upsert(entry('Only Mine', price: 99));
      return library;
    }

    test('offers new models and per-field differences, nothing else', () async {
      final theirsFile = write('theirs.json', [
        // Same model: they have the watts I never recorded, and a different
        // price. Manufacturer matches, so it is not a difference.
        entry(
          'Switcher Y',
          manufacturer: 'Extron',
          rackUnits: 2,
          powerWatts: 90,
          price: 2300,
          ports: [port('in_1', PortDirection.input)],
        ),
        entry('Their New Camera', manufacturer: 'AVer', price: 1200),
      ]);

      final diffs = diffCatalogs(
        mine(),
        await AvDeviceLibrary.readFile(theirsFile),
      );

      // "Only Mine" is not a difference: a merge adds and updates, it never
      // deletes.
      expect(diffs.length, 2);

      final added = diffs.firstWhere((d) => d.isNew);
      expect(added.model, 'Their New Camera');

      final changed = diffs.firstWhere((d) => !d.isNew);
      expect(
        changed.fields.map((f) => f.field),
        containsAll([DeviceField.powerWatts, DeviceField.price]),
      );
      expect(
        changed.fields.map((f) => f.field),
        isNot(contains(DeviceField.manufacturer)),
        reason: 'identical values are not differences',
      );
      expect(
        changed.fields.map((f) => f.field),
        isNot(contains(DeviceField.ports)),
        reason: 'the same connector set is not a difference',
      );
    });

    test('their blank never overwrites something I filled in', () async {
      final theirsFile = write('theirs.json', [
        // No manufacturer, no price: they simply never filled those in.
        entry('Switcher Y', rackUnits: 3),
      ]);

      final diffs = diffCatalogs(
        mine(),
        await AvDeviceLibrary.readFile(theirsFile),
      );
      final changed = diffs.single;
      expect(changed.fields.map((f) => f.field), [DeviceField.rackUnits]);
    });

    test('only the ticked differences are applied', () async {
      final theirsFile = write('theirs.json', [
        entry('Switcher Y', manufacturer: 'Extron', powerWatts: 90, price: 2300),
        entry('Their New Camera', price: 1200),
      ]);

      final library = mine();
      final diffs = diffCatalogs(
        library,
        await AvDeviceLibrary.readFile(theirsFile),
      );

      // Take their watts, keep my price, and skip their new camera entirely.
      final changed = diffs.firstWhere((d) => !d.isNew);
      changed.fields
          .firstWhere((f) => f.field == DeviceField.powerWatts)
          .selected = true;

      expect(applyMerge(library, diffs), 1);

      final merged = library.templateForModel('Switcher Y')!;
      expect(merged.powerWatts, 90, reason: 'the ticked field came across');
      expect(merged.price, 2500, reason: 'the unticked one did not');
      expect(merged.rackUnits, 2);
      expect(merged.ports.length, 1, reason: 'my connectors are untouched');
      expect(library.templateForModel('Their New Camera'), isNull);
      expect(library.templateForModel('Only Mine')?.price, 99);
    });

    test('"select all" takes every difference and every new model', () async {
      final theirsFile = write('theirs.json', [
        entry('Switcher Y', powerWatts: 90, price: 2300),
        entry('Their New Camera', price: 1200),
      ]);

      final library = mine();
      final diffs = diffCatalogs(
        library,
        await AvDeviceLibrary.readFile(theirsFile),
      );
      for (final d in diffs) {
        d.setAll(true);
      }

      expect(applyMerge(library, diffs), 2);
      expect(library.templateForModel('Switcher Y')?.price, 2300);
      expect(library.templateForModel('Their New Camera')?.price, 1200);
      expect(library.templateForModel('Only Mine')?.price, 99);
    });

    test('a merged entry becomes mine, so the next save writes it', () async {
      final theirsFile = write('theirs.json', [entry('Their Box', price: 50)]);
      final library = AvDeviceLibrary.builtIn();
      final diffs = diffCatalogs(
        library,
        await AvDeviceLibrary.readFile(theirsFile),
      );
      for (final d in diffs) {
        d.setAll(true);
      }
      applyMerge(library, diffs);

      expect(library.templateForModel('Their Box')?.custom, isTrue);
      expect(library.customCount, diffs.length);
    });
  });
}
