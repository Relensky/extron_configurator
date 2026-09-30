import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/shared_json.dart';

/// Several people save the same shared files. Nobody's save may undo
/// anybody else's, and every added item says who added it.
void main() {
  late Directory dir;
  late String file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shared_json_');
    file = path.join(dir.path, 'vendor_list.json');
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> read() =>
      jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;

  test('two people adding at once both keep what they added', () async {
    final start = {
      'vendors': [
        {'id': 'v1', 'name': 'CDW'},
      ],
    };
    File(file).writeAsStringSync(jsonEncode(start));

    // Both read the same file...
    rememberSharedJson(file, start);
    final amy = {
      'vendors': [
        {'id': 'v1', 'name': 'CDW'},
        {'id': 'v2', 'name': 'Markertek'},
      ],
    };
    // ...Amy saves first.
    final first = await saveSharedJson(file, amy, user: 'amy');
    expect(first.tookTheirs, isFalse);

    // Ben still has the file as it was when he opened it.
    rememberSharedJson(file, start);
    final ben = {
      'vendors': [
        {'id': 'v1', 'name': 'CDW Government'},
        {'id': 'v3', 'name': 'B&H'},
      ],
    };
    final second = await saveSharedJson(file, ben, user: 'ben');
    expect(second.tookTheirs, isTrue);

    final vendors = read()['vendors'] as List;
    expect(vendors.map((v) => v['id']), ['v1', 'v3', 'v2']);
    expect(vendors[0]['name'], 'CDW Government');
    expect(vendors[0]['changedBy'], 'ben');
    expect(vendors[1]['addedBy'], 'ben');
    expect(vendors[2]['addedBy'], 'amy');
  });

  test('a deletion by one and an edit by the other keeps the edit', () {
    final base = {
      'costs': [
        {'category': 'Projector', 'price': 1},
      ],
    };
    final mine = {'costs': <Object>[]};
    final theirs = {
      'costs': [
        {'category': 'Projector', 'price': 2},
      ],
    };
    expect(mergeJson(base, mine, theirs), theirs);
  });

  test('stamps survive a model class that does not know them', () {
    final prior = {
      'costs': [
        {'category': 'Projector', 'price': 1, 'addedBy': 'amy', 'addedAt': 'x'},
      ],
    };
    final unchanged = stampSharedItems(
      {
        'costs': [
          {'category': 'Projector', 'price': 1},
        ],
      },
      prior,
      user: 'ben',
      at: 'y',
    );
    expect((unchanged['costs'] as List).single, {
      'category': 'Projector',
      'price': 1,
      'addedBy': 'amy',
      'addedAt': 'x',
    });

    final edited = stampSharedItems(
      {
        'costs': [
          {'category': 'Projector', 'price': 5},
        ],
      },
      prior,
      user: 'ben',
      at: 'y',
    );
    final item = (edited['costs'] as List).single as Map;
    expect(item['addedBy'], 'amy');
    expect(item['changedBy'], 'ben');
  });

  test('a lock left by a copy that died is taken over', () async {
    final lock = File('$file.lock')..writeAsStringSync('old');
    lock.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    var ran = false;
    await withFileLock(file, () async => ran = true);
    expect(ran, isTrue);
    expect(lock.existsSync(), isFalse);
  });

  test('saves wait their turn for a live lock', () async {
    final order = <String>[];
    final a = withFileLock(file, () async {
      order.add('a in');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      order.add('a out');
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final b = withFileLock(file, () async => order.add('b'));
    await Future.wait([a, b]);
    expect(order, ['a in', 'a out', 'b']);
  });

  test('the catalog says who added and who changed an entry', () async {
    final catalogFile = path.join(dir.path, 'av_devices.json');
    File(catalogFile).writeAsStringSync(jsonEncode({
      'devices': [
        {'model': 'Shipped', 'rackUnits': 1, 'ports': []},
      ],
    }));
    final lib = await AvDeviceLibrary.readFile(catalogFile);

    lib.upsert(const AvDeviceTemplate(
      model: 'Mine',
      ports: [],
      addedByUser: true,
    ));
    expect(await lib.save(toPath: catalogFile), catalogFile);
    final mine = lib.templateForModel('Mine')!;
    expect(mine.addedBy, isNotEmpty);
    expect(mine.addedAt, isNotEmpty);
    expect(lib.templateForModel('Shipped')!.addedBy, isEmpty,
        reason: 'an entry nobody added here is not credited to anybody');

    lib.upsert(mine.copyWith(price: 10));
    await lib.save(toPath: catalogFile);
    expect(lib.templateForModel('Mine')!.changedBy, isNotEmpty);

    final back = await AvDeviceLibrary.readFile(catalogFile);
    expect(back.templateForModel('Mine')!.addedBy, mine.addedBy);
  });
}
