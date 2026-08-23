import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_presets.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  BLANK PAPER TO LAY THE ROOM OUT ON
/// ============================================================================
///  A floor plan sheet used to need an image behind it. Without one it drew
///  the message saying the image could not be found, and every export skipped
///  it — so there was nowhere to put the room until somebody had the
///  architect's PDF, which is usually the last thing to arrive and never the
///  first thing needed.
///
///  A sheet with no image is now blank paper. The room presets ship one with
///  their own locations already placed on it, so the layout can be walked and
///  marked up on day one; import a drawing later and the markers are already
///  where that room type puts them.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  Future<AppStateProvider> emptyRoom() async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library;
    p.roomConfig
      ..clear()
      ..addAll(Map<String, dynamic>.from(
          jsonDecode(File('config.json').readAsStringSync()) as Map));
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  const shipsASheet = ['Basic classroom', 'Hyflex', 'Active learning'];

  group('what the presets carry', () {
    for (final name in shipsASheet) {
      final preset =
          builtInRoomPresets().firstWhere((p) => p.name == name);

      test('$name ships one blank sheet', () {
        expect(preset.floorPlans, hasLength(1));
        final sheet = preset.floorPlans.single;
        // No image: a drawing belongs to a building, and this is paper.
        expect(sheet.hasImage, isFalse);
        expect(sheet.markers, isNotEmpty);
      });

      test('$name only places locations it actually has', () {
        final ids = {for (final l in preset.locations) l.id};
        for (final key in preset.floorPlans.single.markers.keys) {
          expect(ids, contains(key),
              reason: '$name places $key, which it has no location for');
        }
      });
    }

    test('the Huddle room ships none, and that is fine', () {
      // Not every room type wants one; the field is optional.
      final huddle =
          builtInRoomPresets().firstWhere((p) => p.name == 'Huddle');
      expect(huddle.floorPlans, isEmpty);
    });
  });

  group('applying one', () {
    test('the sheet comes across with the room own location ids', () async {
      final p = await emptyRoom();
      final preset =
          builtInRoomPresets().firstWhere((x) => x.name == 'Active learning');
      p.applyRoomPreset(preset);

      expect(p.avFloorPlans, hasLength(1));
      final sheet = p.avFloorPlans.single;
      expect(sheet.name, 'Room layout');
      expect(sheet.markers, hasLength(preset.floorPlans.single.markers.length));

      // Every marker names a location this ROOM has, not one the preset had.
      final roomIds = {for (final l in p.avLocations) l.id};
      for (final key in sheet.markers.keys) {
        expect(roomIds, contains(key));
      }
    });

    test('a location the room already had keeps its own id', () async {
      final p = await emptyRoom();
      // Applying a preset to a room that already has locations is the normal
      // case: it reuses them by name rather than making a second "Ceiling".
      final existing = p.addAvLocation(const RoomLocation(
        id: '',
        name: 'Ceiling',
        zone: RoomZone.ceiling,
      ));
      p.applyRoomPreset(
          builtInRoomPresets().firstWhere((x) => x.name == 'Basic classroom'));

      final sheet = p.avFloorPlans.single;
      expect(sheet.markers.keys, contains(existing.id),
          reason: 'the marker followed the location it was reused onto');
    });

    test('it does not overwrite a sheet the room already has', () async {
      final p = await emptyRoom();
      final here = p.addAvLocation(const RoomLocation(
        id: '',
        name: 'Somewhere I surveyed',
        zone: RoomZone.wall,
      ));
      final mine = p.addFloorPlanSheet(name: 'Room layout');
      p.moveAvLocationMarker(mine.id, here.id, const Offset(11, 22));

      p.applyRoomPreset(
          builtInRoomPresets().firstWhere((x) => x.name == 'Hyflex'));

      // An imported drawing is a fact about the building; a preset has no
      // business replacing one that shares its name.
      expect(p.avFloorPlans, hasLength(1));
      expect(p.avFloorPlans.single.markers[here.id], const Offset(11, 22));
    });
  });

  group('and it is worth putting on paper', () {
    test('a blank sheet with the room on it counts as drawn', () async {
      final p = await emptyRoom();
      p.applyRoomPreset(
          builtInRoomPresets().firstWhere((x) => x.name == 'Hyflex'));

      // This is the rule the exports read: it used to be "has an image", and
      // a preset sheet would have been skipped by every one of them.
      expect(sheetsWorthDrawing(p), hasLength(1));
    });

    test('a sheet somebody named and never used does not', () async {
      final p = await emptyRoom();
      p.addFloorPlanSheet(name: 'Level 2');
      expect(sheetsWorthDrawing(p), isEmpty,
          reason: 'nothing has been placed on it - there is nothing to print');
    });
  });
}
