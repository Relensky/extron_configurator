import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_room_options_button.dart';

/// The project total counts the rooms' optional upgrades as the project says:
/// for all rooms, room by room, or option by option - whatever each room's
/// Cost tab shows.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_project_opt'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A $1,000 projector, a $500 optional laser upgrade and a $200 optional
  /// mic, 10% tax: $1,100 without options, $1,870 with both. The room's own
  /// Cost tab counts the options.
  BuildingProject job({
    bool include = true,
    ProjectRoomRef Function(ProjectRoomRef r)? room,
  }) {
    final configPath = path.join(dir.path, 'a_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': 'Room A'},
    }));
    File(path.join(dir.path, 'a_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({'nodes': []}));
    final settings = RoomCostSettings()
      ..taxPercent = 10
      ..ownTaxRate = true
      ..extraEquipment.addAll([
        const CostLineItem(
            id: 'EQP_1', description: 'Projector', unitPrice: 1000),
        const CostLineItem(
            id: 'EQP_2', description: 'Laser upgrade', unitPrice: 500),
        const CostLineItem(id: 'EQP_3', description: 'Mic', unitPrice: 200),
      ])
      ..optionalLines.addAll(['EQP_2', 'EQP_3'])
      ..includeOptional = true;
    File(path.join(dir.path, 'a_config_cost.json'))
        .writeAsStringSync(jsonEncode({'cost': settings.toJson()}));
    final ref = ProjectRoomRef(
      id: 'r1',
      configPath: BuildingProject.storePath(
          configPath, path.join(dir.path, 'job_project.json')),
    );
    return BuildingProject(name: 'Job', includeOptional: include)
      ..rooms.add(room == null ? ref : room(ref));
  }

  ProjectEstimate price(BuildingProject p) => computeProjectEstimate(
    project: p,
    projectPath: path.join(dir.path, 'job_project.json'),
    library: AvDeviceLibrary.empty(),
  );

  test('the project toggle counts every room\'s options or none', () {
    final on = price(job());
    expect(on.grandTotal, 1870);
    expect(on.optionalTotal, 770);
    final off = price(job(include: false));
    expect(off.grandTotal, 1100,
        reason: 'the room counts them, the project does not');
    expect(off.optionalTotal, 0);
    expect(off.grandWithOptions, 1870);
  });

  test('a room goes its own way, either way round', () {
    final out = price(job(room: (r) => r.copyWith(optionalOff: true)));
    expect(out.grandTotal, 1100);
    expect(out.optionalTotal, 0);
    expect(out.grandWithOptions, 1870);
    final inn = price(job(
      include: false,
      room: (r) => r.copyWith(optionalOn: true),
    ));
    expect(inn.grandTotal, 1870,
        reason: 'counted without the project-wide switch');
  });

  test('one option counted, another left out', () {
    final e = price(job(
      room: (r) => r.copyWith(optionalLinesOff: {'EQP_3'}),
    ));
    expect(e.grandTotal, 1650);
    expect(e.grandWithoutOptions, 1100);
    expect(e.grandWithOptions, 1870);
    expect(e.optionalTotal, 550);
    expect(
      e.costedRooms.single.optionLines.map((l) => (l.key, l.amount)),
      [('EQP_2', 500.0), ('EQP_3', 200.0)],
    );
  });

  test('the switches: room, line, and all rooms', () {
    final p = AppStateProvider(autoLoadSettings: false);
    p.project.rooms
        .add(const ProjectRoomRef(id: 'r1', configPath: 'a_config.json'));
    ProjectRoomRef ref() => p.project.rooms.single;
    const all = {'EQP_2', 'EQP_3'};

    // The project leaves options out; the room is counted anyway.
    p.setProjectRoomOptionsCounted('r1', true);
    expect(p.project.optionsCounted(ref()), isTrue);
    expect(ref().optionalOn, isTrue);

    // One line out, then the other: the room is out, and starts whole.
    p.setProjectRoomOptionLine('r1', 'EQP_3', false, allKeys: all);
    expect(ref().optionalLinesOff, {'EQP_3'});
    p.setProjectRoomOptionLine('r1', 'EQP_2', false, allKeys: all);
    expect(p.project.optionsCounted(ref()), isFalse);
    expect(ref().optionalLinesOff, isEmpty);

    // One line of a room that is out: that line only.
    p.setProjectRoomOptionLine('r1', 'EQP_2', true, allKeys: all);
    expect(p.project.optionsCounted(ref()), isTrue);
    expect(ref().optionalLinesOff, {'EQP_3'});

    // All rooms: the room's own way is dropped, its lines are kept.
    p.setProjectIncludeOptional(true);
    expect(ref().optionalOn, isFalse);
    expect(p.project.optionsCounted(ref()), isTrue);
    expect(ref().optionalLinesOff, {'EQP_3'});
    p.setProjectRoomOptionsCounted('r1', false);
    expect(ref().optionalOff, isTrue);

    final back = ProjectRoomRef.fromJson(ref().toJson());
    expect(back.optionalOff, isTrue);
    expect(back.optionalLinesOff, {'EQP_3'});
  });

  testWidgets('the room icon says where the options are and its menu flips '
      'them', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    p.project.includeOptional = true;
    p.project.rooms
        .add(const ProjectRoomRef(id: 'r1', configPath: 'a_config.json'));
    ProjectRoomCost room() {
      final priced = price(job(
        include: p.project.includeOptional,
        room: (_) => p.project.rooms.single,
      ));
      return priced.rooms.single;
    }

    Widget button() => ChangeNotifierProvider<AppStateProvider>.value(
      value: p,
      child: MaterialApp(
        home: Scaffold(
          body: ProjectRoomOptionsButton(room: room(), currency: r'$'),
        ),
      ),
    );
    await tester.pumpWidget(button());
    expect(find.byIcon(Icons.playlist_add_check), findsOneWidget);
    final tip = tester.widget<PopupMenuButton<String>>(
        find.byKey(const ValueKey('project_room_optional_r1')));
    expect(tip.tooltip, contains('in the project total'));

    await tester.tap(find.byKey(const ValueKey('project_room_optional_r1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_room_optional_r1_EQP_3')));
    await tester.pumpAndSettle();
    expect(p.project.rooms.single.optionalLinesOff, {'EQP_3'});
    await tester.pumpWidget(button());
    expect(find.byIcon(Icons.playlist_add), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('project_room_optional_r1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_room_optional_r1_room')));
    await tester.pumpAndSettle();
    expect(p.project.optionsCounted(p.project.rooms.single), isFalse);
    await tester.pumpWidget(button());
    expect(find.byIcon(Icons.playlist_remove), findsOneWidget);
  });
}
