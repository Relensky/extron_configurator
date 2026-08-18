import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// ============================================================================
///  TWO PEOPLE IN ONE CATALOG
/// ============================================================================
///  av_devices.json is one file, and everybody's Save rewrites all of it. Put
///  it on a share so the department can keep one price list and the second
///  person to press Save erases the first one's afternoon — silently, because
///  the file it writes is perfectly valid.
///
///  So a save now reads the file back first and settles it field by field
///  against what this copy last saw there. Different models, or different
///  fields of one model, and both people keep their work. The same field of
///  the same model is the only contest, and the one who saves second wins.
/// ============================================================================
void main() {
  late Directory dir;
  late String catalog;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog_merge');
    catalog = '${dir.path}/av_devices.json';
    await File(catalog).writeAsString(jsonEncode({
      'devices': [
        {
          'model': 'DTP CrossPoint 84',
          'category': 'Matrix',
          'price': 100.0,
          'rackUnits': 2,
          'ports': <Map<String, dynamic>>[],
        },
        {
          'model': 'DMP 64',
          'category': 'DSP',
          'price': 200.0,
          'rackUnits': 1,
          'ports': <Map<String, dynamic>>[],
        },
      ],
    }));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// One person's copy of the shared catalog, opened fresh.
  Future<AvDeviceLibrary> open() => AvDeviceLibrary.readFile(catalog);

  /// What the file says a model costs, read straight off the disk.
  Future<double?> priceOnDisk(String model) async {
    final doc = jsonDecode(await File(catalog).readAsString()) as Map;
    for (final d in (doc['devices'] as List)) {
      if (d['model'] == model) return (d['price'] as num?)?.toDouble();
    }
    return null;
  }

  /// [model] with one field changed, put back into [library].
  void reprice(AvDeviceLibrary library, String model, double price) {
    library.upsert(library.templateForModel(model)!.copyWith(price: price));
  }

  test('two people pricing two models both keep their work', () async {
    final mine = await open();
    final theirs = await open();

    // They price the DSP and save. I am still looking at the old figure.
    reprice(theirs, 'DMP 64', 250);
    await theirs.save();

    // I price the matrix and save over the top of them.
    reprice(mine, 'DTP CrossPoint 84', 150);
    await mine.save();

    expect(await priceOnDisk('DTP CrossPoint 84'), 150, reason: 'mine');
    expect(await priceOnDisk('DMP 64'), 250,
        reason: 'theirs, which the old full-file rewrite erased');
  });

  test('two fields of one model survive together', () async {
    final mine = await open();
    final theirs = await open();

    // They draw the matrix's connectors.
    theirs.upsert(theirs.templateForModel('DTP CrossPoint 84')!.copyWith(
          ports: [
            const AvPort(
              id: 'hdmi_1',
              label: 'HDMI 1',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          ],
        ));
    await theirs.save();

    // I price the same box, knowing nothing about their connectors.
    reprice(mine, 'DTP CrossPoint 84', 150);
    await mine.save();

    final back = await open();
    final entry = back.templateForModel('DTP CrossPoint 84')!;
    expect(entry.price, 150, reason: 'mine');
    // A save also gives an entry with connectors its mains inlet, which is
    // why POWER is on the end of this and not something either of us drew.
    expect(entry.ports.map((p) => p.label), ['HDMI 1', 'POWER'],
        reason: 'theirs');
  });

  test('the same field twice goes to whoever saved second', () async {
    final mine = await open();
    final theirs = await open();

    reprice(theirs, 'DMP 64', 250);
    await theirs.save();

    reprice(mine, 'DMP 64', 275);
    await mine.save();

    expect(await priceOnDisk('DMP 64'), 275);
  });

  test('a model somebody else added is not deleted by my save', () async {
    final mine = await open();
    final theirs = await open();

    theirs.upsert(const AvDeviceTemplate(
      model: 'AV Bridge 2x1',
      category: 'Recorder / streamer',
      price: 900,
      ports: [],
      custom: true,
    ));
    await theirs.save();

    reprice(mine, 'DMP 64', 250);
    await mine.save();

    expect(await priceOnDisk('AV Bridge 2x1'), 900);
    expect(await priceOnDisk('DMP 64'), 250);
  });

  test('my own second save is not undone by my first', () async {
    // The merge must not treat the file this copy just wrote as somebody
    // else's work, or a price could only ever be edited once per session.
    final mine = await open();

    reprice(mine, 'DMP 64', 250);
    await mine.save();
    reprice(mine, 'DMP 64', 300);
    await mine.save();

    expect(await priceOnDisk('DMP 64'), 300);
  });

  test('an export to a file this copy never read still overwrites it',
      () async {
    // 'Export a copy' hands a colleague the catalog as it stands. Merging
    // into whatever happened to be at that path would be a surprise.
    final mine = await open();
    reprice(mine, 'DMP 64', 250);

    final other = '${dir.path}/theirs.json';
    await File(other).writeAsString(jsonEncode({
      'devices': [
        {'model': 'DMP 64', 'price': 999.0, 'ports': <Map<String, dynamic>>[]},
      ],
    }));

    await mine.save(toPath: other, rebind: false);
    final doc = jsonDecode(await File(other).readAsString()) as Map;
    final dmp = (doc['devices'] as List)
        .firstWhere((d) => d['model'] == 'DMP 64');
    expect(dmp['price'], 250);
    // And it has not repointed my own saves at their folder.
    expect(mine.filePath, catalog);
  });

  test('the file is never seen half written', () async {
    // Written through a temporary and renamed into place, so a colleague
    // reading the share during a save gets the old file or the new one.
    final mine = await open();
    reprice(mine, 'DMP 64', 250);
    await mine.save();

    expect(await File('$catalog.tmp').exists(), isFalse);
    expect(
      jsonDecode(await File(catalog).readAsString()),
      isA<Map<String, dynamic>>(),
    );
  });
}
