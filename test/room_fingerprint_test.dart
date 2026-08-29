import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  THE UNSAVED-CHANGES FINGERPRINT, AND THE ORDER CONFIGS ARE WRITTEN IN
/// ============================================================================
///  Two things guard the same hot path here, and both of them are the kind of
///  thing that breaks quietly.
///
///  THE ORDER. Every config the app writes goes out through `_sortJson`, so
///  the key order it produces is baked into every file on every share. It used
///  to be produced by a comparator that tokenized both of its arguments with a
///  regex on every call; that is now done once per key instead. The order has
///  to be IDENTICAL, or the next save of an untouched room is a diff of the
///  whole file. The reference implementation below is the old comparator, kept
///  as the oracle: the fast path is checked against it rather than against a
///  golden list somebody would have to maintain by hand.
///
///  THE FINGERPRINT. `roomHasUnsavedChanges` encodes the whole room to answer
///  "is there a dot on the save button", and the toolbar asks it on every
///  rebuild. It is memoised, dropped in `notifyListeners`. The risk a memo
///  carries here is not that it is slow but that it is STALE — a room that has
///  been edited reporting itself clean is somebody's work thrown away at the
///  next close-without-saving. So the cases below are all about a cache that
///  has been warmed and then has to notice a change.
/// ============================================================================

/// The comparator as it stood before the split-once rewrite. The oracle for
/// [_orderMatchesReference] — do not "simplify" this to call the real one.
int _referenceNaturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final aParts = re.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final bParts = re.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (int i = 0; i < aParts.length && i < bParts.length; i++) {
    final an = int.tryParse(aParts[i]);
    final bn = int.tryParse(bParts[i]);
    final c = (an != null && bn != null)
        ? an.compareTo(bn)
        : aParts[i].compareTo(bParts[i]);
    if (c != 0) return c;
  }
  return aParts.length.compareTo(bParts.length);
}

dynamic _referenceSort(dynamic node) {
  if (node is Map) {
    final keys = node.keys.map((k) => k.toString()).toList()
      ..sort(_referenceNaturalCompare);
    return <String, dynamic>{for (final k in keys) k: _referenceSort(node[k])};
  }
  if (node is List) return node.map(_referenceSort).toList();
  return node;
}

/// True when [provider]'s own sorted rendering of the config it holds is the
/// same document, in the same order, as the reference comparator produces.
bool _orderMatchesReference(AppStateProvider provider) {
  final mine = provider.getPrettyConfigString();
  final reference =
      const JsonEncoder.withIndent('    ').convert(_referenceSort(jsonDecode(mine)));
  return mine == reference;
}

void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AppStateProvider room(Map<String, dynamic> config) =>
      AppStateProvider(autoLoadSettings: false)
        ..uiSchema = schema
        ..roomConfig.addAll(config);

  group('the order configs are written in', () {
    test('a real config sorts exactly as the old comparator did', () {
      final doc = jsonDecode(File('config.json').readAsStringSync());
      expect(_orderMatchesReference(room(Map<String, dynamic>.from(doc as Map))),
          isTrue);
    });

    test('every room preset sorts exactly as the old comparator did', () {
      var checked = 0;
      for (final file in Directory('room_presets').listSync().whereType<File>()) {
        if (!file.path.endsWith('.json')) continue;
        final doc = jsonDecode(file.readAsStringSync());
        if (doc is! Map) continue;
        checked++;
        expect(_orderMatchesReference(room(Map<String, dynamic>.from(doc))),
            isTrue,
            reason: 'key order changed for ${path.basename(file.path)}');
      }
      // A guard on the guard: a preset folder that has moved would otherwise
      // make this test pass by checking nothing.
      expect(checked, greaterThan(0));
    });

    test('digit runs still read as numbers, not as text', () {
      final sorted = (jsonDecode(room({
        for (final k in [
          'PROJECTORDEVICE_10',
          'PROJECTORDEVICE_2',
          'PROJECTORDEVICE_1',
          'projectordevice_3',
        ])
          k: <String, dynamic>{},
      }).getPrettyConfigString()) as Map)
          .keys
          .toList();
      expect(sorted, [
        'PROJECTORDEVICE_1',
        'PROJECTORDEVICE_2',
        'projectordevice_3',
        'PROJECTORDEVICE_10',
      ]);
    });

    test('awkward keys sort as the old comparator did', () {
      // Separators, spaces, mixed case, leading zeros, empty strings and digit
      // runs far too long for an int — the cases a hand-written list forgets.
      final rnd = Random(20260828);
      const alphabet = ['a', 'B', '_', ' ', '0', '1', '9', '.', '-', 'z'];
      final keys = <String>{
        '',
        '1',
        '01',
        '001',
        'a1',
        'a01',
        '99999999999999999999999999',
        '99999999999999999999999998',
        for (var i = 0; i < 3000; i++)
          List.generate(rnd.nextInt(9),
              (_) => alphabet[rnd.nextInt(alphabet.length)]).join(),
      }.toList();

      final expected = List<String>.from(keys)..sort(_referenceNaturalCompare);
      final actual = (jsonDecode(
                  room({for (final k in keys) k: 1}).getPrettyConfigString())
              as Map)
          .keys
          .map((e) => e.toString())
          .toList();
      expect(actual, expected);
    });
  });

  group('the unsaved-changes fingerprint', () {
    late Directory dir;
    late String configPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('room_fingerprint_test_');
      configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    AppStateProvider savedRoom() {
      final p = room({
        'SYSTEM_SETUP': <String, dynamic>{'dev_projectors': '1'},
        'PROJECTORDEVICE_1': <String, dynamic>{'name': 'Projector', 'model': ''},
      })
        ..currentConfigPath = configPath;
      p.markRoomSaved();
      return p;
    }

    test('a room that matches its file reads clean', () {
      expect(savedRoom().roomHasUnsavedChanges, isFalse);
    });

    test('an edit is noticed even when the answer was already asked for', () {
      final p = savedRoom();
      // Warming the memo first is the whole point: this is the state the
      // toolbar leaves it in on every frame.
      expect(p.roomHasUnsavedChanges, isFalse);
      p.updateDeviceValue('PROJECTORDEVICE_1', 'name', 'Main projector');
      expect(p.roomHasUnsavedChanges, isTrue);
    });

    test('a repeated read does not go stale between edits', () {
      final p = savedRoom();
      for (var i = 0; i < 3; i++) {
        expect(p.roomHasUnsavedChanges, isFalse);
      }
      p.updateDeviceValue('PROJECTORDEVICE_1', 'model', 'PN-L705');
      for (var i = 0; i < 3; i++) {
        expect(p.roomHasUnsavedChanges, isTrue);
      }
    });

    test('a direct write to the config is noticed once it is announced', () {
      // control_prefill.dart writes device blocks straight into roomConfig and
      // announces them with roomConfigChanged(). The memo has to come off on
      // that announcement, not on the write.
      final p = savedRoom();
      expect(p.roomHasUnsavedChanges, isFalse);
      p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{'name': 'Switcher'};
      p.roomConfigChanged();
      expect(p.roomHasUnsavedChanges, isTrue);
    });

    test('saving makes it clean again, and the next edit dirty again', () {
      final p = savedRoom();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'name', 'Main projector');
      expect(p.roomHasUnsavedChanges, isTrue);
      p.markRoomSaved();
      expect(p.roomHasUnsavedChanges, isFalse);
      p.updateDeviceValue('PROJECTORDEVICE_1', 'name', 'Ceiling projector');
      expect(p.roomHasUnsavedChanges, isTrue);
    });

    test('a change to the diagram counts as unsaved work too', () {
      // The fingerprint covers the sidecars, not just the config — a moved box
      // is work somebody would be upset to lose.
      final p = savedRoom();
      expect(p.roomHasUnsavedChanges, isFalse);
      p.addAvLocation(const RoomLocation(id: '', name: 'Rack closet'));
      expect(p.roomHasUnsavedChanges, isTrue);
    });
  });
}
