import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/room_presets.dart';

/// ============================================================================
///  THE ROOM TYPES OFF THE REFRESH SHEET
/// ============================================================================
///  Every room on the estate is priced against one of twenty-seven room types,
///  and each of those is a tab on the RYG categories spreadsheet with a bill of
///  materials on it. They are generated into room_presets/ by
///  tools/build_ryg_presets.py rather than typed out, because the spreadsheet
///  is the document that gets revised and a few thousand hand-written lines
///  could not be checked against it.
///
///  What is held here is the join: that every preset reads back, and that every
///  device on one is a device the CATALOG actually has. A preset naming a model
///  nothing can price is a room that opens with boxes on it and no money - and
///  the generator can only be as right as the mapping it was given, so the
///  mapping is what gets checked.
/// ============================================================================
void main() {
  final dir = Directory('room_presets');

  List<File> presetFiles() => !dir.existsSync()
      ? const []
      : dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith(kRoomPresetExtension))
            .toList();

  /// The presets built from the master sheet.
  ///
  /// Filtered on [RoomPreset.sourceName] rather than counting the folder,
  /// because the four presets the app SHIPS are written into the same folder
  /// on startup - so a bare count is a number that changes the first time
  /// anybody runs the app.
  List<RoomPreset> fromTheSheet() => [
    for (final file in presetFiles())
      RoomPreset.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(file.readAsStringSync()) as Map,
        ),
      ),
  ].where((p) => p.sourceName.isNotEmpty).toList();

  test('the room types are all there and all readable', () {
    final presets = fromTheSheet();
    expect(
      presets.length,
      27,
      reason: 'one preset per room type on the RYG sheet',
    );

    for (final preset in presets) {
      expect(preset.name.trim(), isNotEmpty, reason: preset.sourceName);
      // THE '!' IS A MARK ON THE MASTER SHEET, not part of a room type's name.
      // It flags a one-off room to whoever maintains the spreadsheet and means
      // nothing inside the app.
      expect(
        preset.name.startsWith('!'),
        isFalse,
        reason: '${preset.name} still carries the spreadsheet marker',
      );
    }
  });

  test('every room type says which sheet it was built from', () {
    // What a line item matches on to find the preset it was priced against -
    // see [RoomPreset.sourceName]. A preset without one is a room type nothing
    // on the plan can be converted into.
    for (final preset in fromTheSheet()) {
      expect(preset.sourceName.trim(), isNotEmpty, reason: preset.name);
    }
    expect(
      fromTheSheet().map((p) => p.sourceName).toSet().length,
      27,
      reason: 'two presets claiming one sheet would make the match ambiguous',
    );
  });

  /// The shipped catalog, read straight off disk - the same file the app loads.
  List<Map<String, dynamic>> catalogDevices() {
    final doc = jsonDecode(File('av_devices.json').readAsStringSync());
    return [
      for (final d in ((doc as Map)['devices'] as List))
        Map<String, dynamic>.from(d as Map),
    ];
  }

  test('every device on every preset is one the catalog can price', () {
    final devices = catalogDevices();
    expect(
      devices,
      isNotEmpty,
      reason: 'the catalog itself has to load for this to mean anything',
    );
    final known = {for (final d in devices) d['model']?.toString()};

    final unknown = <String>{};
    for (final file in presetFiles()) {
      final preset = RoomPreset.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(file.readAsStringSync()) as Map,
        ),
      );
      for (final node in preset.nodes) {
        if (node.model.trim().isEmpty) continue;
        if (!known.contains(node.model)) {
          unknown.add('${preset.name}: ${node.model}');
        }
      }
    }
    expect(unknown, isEmpty, reason: 'models nothing in the catalog matches');
  });

  test('a preset carries the ports the catalog gives that model', () {
    // The reason it matters: a device dropped from a preset and one dropped
    // from the catalog have to be the SAME device, or re-picking the model
    // later orphans every cable on it.
    final devices = catalogDevices();
    final file = File(
      'room_presets/2 Display$kRoomPresetExtension',
    );
    expect(file.existsSync(), isTrue);

    final preset = RoomPreset.fromJson(
      Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map),
    );
    final display = preset.nodes.firstWhere((n) => n.model == 'FW-75EZ20L');
    final catalog = devices.firstWhere((d) => d['model'] == 'FW-75EZ20L');

    expect(
      display.ports.map((p) => p.id).toSet(),
      {
        for (final p in (catalog['ports'] as List))
          (p as Map)['id'].toString(),
      },
    );
  });

  test('a preset prices from the catalog, not from a figure of its own', () {
    // A preset carries MODELS and no money, so a price corrected in the
    // catalog reaches every room type that draws that device without any of
    // them being rebuilt. The conferencing cart is the case that proved it:
    // the Neat bar was priced after the presets were written, and the cart
    // picked the figure up with no change to its own file.
    final devices = catalogDevices();
    final neat = devices.firstWhere((d) => d['model'] == 'Bar BYOD');
    expect(neat['manufacturer'], 'Neat');
    expect(neat['price'], 700.0);
    expect(neat['educationPrice'], 399.0);

    final cart = RoomPreset.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(
          File('room_presets/1 Display Conference _cart_'
                  '$kRoomPresetExtension')
              .readAsStringSync(),
        ) as Map,
      ),
    );
    expect(cart.nodes.any((n) => n.model == 'Bar BYOD'), isTrue);
    // ...and the preset itself says nothing about what any of it costs.
    final raw = jsonDecode(
      File('room_presets/1 Display Conference _cart_$kRoomPresetExtension')
          .readAsStringSync(),
    ) as Map;
    expect(jsonEncode(raw).contains('"price"'), isFalse);
  });

  test('the two room types with no bill of materials are still room types', () {
    // '!CDL' and '!sound system only' have no equipment on the master sheet.
    // They are real room types all the same - three rooms on the estate are
    // priced as sound-system-only - so they exist to be filled in rather than
    // being quietly absent from the picker.
    for (final name in const ['CDL', 'Sound system only']) {
      final file = File('room_presets/$name$kRoomPresetExtension');
      expect(file.existsSync(), isTrue, reason: '$name is missing');
      final preset = RoomPreset.fromJson(
        Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map),
      );
      expect(preset.nodes, isEmpty);
      expect(preset.name, name);
    }
  });

  test('the room types the estate actually uses are all covered', () {
    // Every line item on the campus names its type in its notes ("RYG estimate
    // for 2 Projector"). A type in use with no preset behind it is a room
    // nobody can build from the plan.
    final campus = Directory('RYG campus');
    if (!campus.existsSync()) return;

    final names = {
      for (final file in presetFiles())
        RoomPreset.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(file.readAsStringSync()) as Map,
          ),
        ).name,
    };

    final used = <String>{};
    for (final job in campus.listSync().whereType<File>()) {
      if (!job.path.endsWith('_project.json')) continue;
      final doc = jsonDecode(job.readAsStringSync());
      if (doc is! Map) continue;
      for (final room in (doc['manualRooms'] as List? ?? [])) {
        if (room is! Map) continue;
        final note = room['notes']?.toString() ?? '';
        final match = RegExp(r'RYG estimate for (.+)$').firstMatch(note);
        if (match == null) continue;
        // The note carries the sheet name, sometimes with an annotation after
        // it - 'last update unknown on the master sheet'.
        used.add(match.group(1)!.split('·').first.trim());
      }
    }

    // Matched on the SHEET name, which the preset records in its readme, so
    // this survives the presets being renamed for the picker.
    final sheets = <String>{};
    for (final file in presetFiles()) {
      final doc = jsonDecode(file.readAsStringSync()) as Map;
      final readme = doc['__readme']?.toString() ?? '';
      final match = RegExp(r'sheet "(.+?)"').firstMatch(readme);
      if (match != null) sheets.add(match.group(1)!);
    }

    expect(used.difference(sheets), isEmpty, reason: 'room types with no preset');
    expect(names, isNotEmpty);
  });
}
