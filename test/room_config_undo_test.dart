import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// UNDO FOR THE ROOM'S CONFIG, WHICH HAD NONE.
///
/// The four drawing tabs have had undo for years. The config — the wizard, the
/// device forms, system settings, the raw JSON — is the document somebody
/// spends the afternoon in, and a device deleted off it or a preset applied
/// over typed values was a one-way door.
///
/// It records the document rather than each edit, because the config is
/// mutated from two dozen files and the call site that got forgotten would be
/// an edit Undo silently stepped over. So what has to hold: a step goes back
/// and comes forward again; the restored config is WRITABLE, because a room
/// restored as read-only maps looks fine until the next keystroke throws; and
/// one room's history can never reach into another's.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_cfg_undo_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A provider with a room open, from a file on disk — the history is keyed
  /// on the file, so a room with no path is a different case.
  AppStateProvider room({String stem = 'bss101'}) {
    final file = path.join(dir.path, '${stem}_config.json');
    File(file).writeAsStringSync(
      '{"SYSTEM_SETUP":{"gui_full_room_name":"Bessey 101"},'
      '"DISPLAY_1":{"model":"NEC C651Q"}}',
    );
    final p = AppStateProvider(autoLoadSettings: false);
    p.currentConfigPath = file;
    p.roomConfig = {
      'SYSTEM_SETUP': {'gui_full_room_name': 'Bessey 101'},
      'DISPLAY_1': {'model': 'NEC C651Q'},
    };
    // The first notification after the path changes is what baselines the
    // history against this file — which is what every loader in the app does
    // as its last act, and why none of them has to know this exists.
    p.notifyListeners();
    return p;
  }

  void step(AppStateProvider p) => p.recordUndoPoint();

  /// An edit made the way the forms make one: straight into the map, then a
  /// notification. Nothing in this feature is instrumented, which is the whole
  /// point — this is what a device form does.
  void edit(AppStateProvider p, void Function() change) {
    change();
    p.notifyListeners();
  }

  group('a step goes back, and forward again', () {
    test('a typed value goes back without taking the block with it', () {
      final p = room();
      edit(p, () => p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65');
      step(p);
      edit(p, () => p.roomConfig['DISPLAY_1']['input'] = 'HDMI 2');
      step(p);

      expect(p.undoRoomConfig(), isNotEmpty);

      expect(p.roomConfig['DISPLAY_1']['input'], isNull, reason: 'undone');
      expect(p.roomConfig['DISPLAY_1']['model'], 'Sony FW-65',
          reason: 'the edit before it stayed');
    });

    test('a deleted block comes back whole', () {
      final p = room();
      edit(p, () => p.roomConfig.remove('DISPLAY_1'));
      step(p);
      expect(p.roomConfig.containsKey('DISPLAY_1'), isFalse);

      p.undoRoomConfig();

      expect(p.roomConfig['DISPLAY_1']['model'], 'NEC C651Q');
    });

    test('redo puts it back', () {
      final p = room();
      edit(p, () => p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65');
      step(p);

      p.undoRoomConfig();
      expect(p.roomConfig['DISPLAY_1']['model'], 'NEC C651Q');

      expect(p.redoRoomConfig(), isNotEmpty);
      expect(p.roomConfig['DISPLAY_1']['model'], 'Sony FW-65');
    });

    test('nothing to undo is said rather than guessed at', () {
      final p = room();
      expect(p.undoRoomConfig(), '');
      expect(p.redoRoomConfig(), '');
    });
  });

  group('what comes back is a room you can go on editing', () {
    test('the restored blocks are writable', () {
      final p = room();
      edit(p, () => p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65');
      step(p);

      p.undoRoomConfig();

      // THE FAILURE THIS GUARDS is invisible until the next keystroke: a
      // config decoded straight out of JSON hands back maps that throw the
      // moment a value of another type is written into one, from inside a text
      // field's onChanged where nothing reports it. The digit simply never
      // lands and the field looks broken. See [AppStateProvider.roomConfig].
      p.roomConfig['DISPLAY_1']['baud'] = 9600;
      expect(p.roomConfig['DISPLAY_1']['baud'], 9600);

      p.roomConfig['NEW_BLOCK'] = {'model': 'DTP T USW 233'};
      expect(p.roomConfig['NEW_BLOCK']['model'], 'DTP T USW 233');
    });

    test('the forms are told to rebuild', () {
      final p = room();
      final before = p.configRevision;
      edit(p, () => p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65');
      step(p);

      p.undoRoomConfig();

      // A field reads its initial value once per element. Without this the
      // form on screen goes on showing the value that was just undone.
      expect(p.configRevision, greaterThan(before));
    });
  });

  group('the step is named after what moved', () {
    test('one block changed is named for that block', () {
      final p = room();
      edit(p, () => p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65');
      step(p);
      expect(p.roomConfigUndoLabel, 'DISPLAY_1');
    });

    test('a block added and a block removed say so', () {
      final p = room();
      edit(p, () => p.roomConfig['PROJECTOR_2'] = {'model': 'Epson L630'});
      step(p);
      expect(p.roomConfigUndoLabel, 'Added PROJECTOR_2');

      edit(p, () => p.roomConfig.remove('DISPLAY_1'));
      step(p);
      expect(p.roomConfigUndoLabel, 'Removed DISPLAY_1');
    });

    test('a sweep across the room is counted rather than listed', () {
      final p = room();
      edit(p, () {
        p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65';
        p.roomConfig['SYSTEM_SETUP']['gui_full_room_name'] = 'Bessey 102';
      });
      step(p);
      expect(p.roomConfigUndoLabel, '2 blocks');
    });
  });

  group('one room\'s history does not reach into another', () {
    test('opening a different room starts again', () {
      final p = room();
      edit(p, () => p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65');
      step(p);
      expect(p.roomConfigUndoDepth, greaterThan(0));

      // What loading another room looks like from here: a new path and a new
      // document. There are eight places in the app that do this and none of
      // them has to know the history exists.
      p.currentConfigPath = path.join(dir.path, 'bss205_config.json');
      p.roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Bessey 205'},
      };
      p.notifyListeners();

      expect(p.roomConfigUndoDepth, 0);
      expect(p.undoRoomConfig(), '');
      // The hazard this exists to stop: the last room's devices pasted into
      // this one by a button somebody pressed expecting a safety net.
      expect(p.roomConfig.containsKey('DISPLAY_1'), isFalse);
    });
  });

  group('the drawings and the config are separate histories', () {
    test('undoing the config leaves the AV flow alone', () {
      final p = room();
      p.loadAvFlowForCurrentConfig();
      edit(p, () => p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65');
      step(p);

      p.undoRoomConfig();

      // The two never touch the same keys: the config is its own file, and the
      // four drawing scopes divide the sidecar between them.
      expect(p.canUndoRoomConfig, isFalse);
      expect(p.roomConfig['DISPLAY_1']['model'], 'NEC C651Q');
    });
  });
}
