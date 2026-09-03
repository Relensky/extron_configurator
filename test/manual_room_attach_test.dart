import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/manual_room_attach.dart';

/// ============================================================================
///  THE ESTIMATES THAT HAVE BECOME ROOMS
/// ============================================================================
///  A refresh plan starts as four hundred line items and becomes, one room at
///  a time over three years, four hundred drawn rooms. Every one of those
///  swaps was a file picker, and the eleventh one in an afternoon is the one
///  where the wrong file gets picked.
///
///  What is held here: that a config is matched on the room code it STATES
///  rather than on its file name, and that two files claiming one room are
///  refused rather than guessed between - because picking either ends with a
///  budget pointing at somebody's working copy.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('attach_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A room config on disk, stating its own building and number.
  String writeRoom(
    String fileName, {
    required String building,
    required String number,
    String? under,
  }) {
    final folder = under == null
        ? dir
        : Directory(path.join(dir.path, under))
      ..createSync(recursive: true);
    final file = File(path.join(folder.path, fileName));
    file.writeAsStringSync(
      jsonEncode({
        'SYSTEM_SETUP': {
          'gve_bldg': building,
          'gve_room': number,
          'gui_full_room_name': '$building $number',
        },
      }),
    );
    return file.path;
  }

  ManualRoom line(String id, String name) => ManualRoom(id: id, name: name);

  test('a config is found by the room code it states, not its file name', () {
    writeRoom('sci125_final_v2.json', building: 'SCI', number: '125');

    final found = findDrawnRooms(dir);
    expect(found, hasLength(1));
    expect(found.single.roomCode, 'SCI 125');
  });

  test('a campus is a folder per building, so the scan goes down', () {
    writeRoom('a.json', building: 'SCI', number: '125', under: 'SCI');
    writeRoom('b.json', building: 'BSS', number: '214', under: 'BSS/rooms');

    expect(
      findDrawnRooms(dir).map((r) => r.roomCode).toList()..sort(),
      ['BSS 214', 'SCI 125'],
    );
  });

  test('a project file in the same tree is not a room', () {
    File(path.join(dir.path, 'SCI_project.json')).writeAsStringSync(
      jsonEncode(BuildingProject(name: 'Physical Science').toJson()),
    );
    File(path.join(dir.path, 'notes.json')).writeAsStringSync('{ broken');

    expect(findDrawnRooms(dir), isEmpty);
  });

  test('lines that have been drawn are matched, the rest are left', () {
    final sci = writeRoom('anything.json', building: 'SCI', number: '125');
    writeRoom('other.json', building: 'SCI', number: '999');

    final plan = planRoomAttachments(
      lines: [line('manual1', 'SCI 125'), line('manual2', 'SCI 131')],
      drawn: findDrawnRooms(dir),
    );

    expect(plan.matches, hasLength(1));
    expect(plan.matches.single.line.id, 'manual1');
    expect(plan.matches.single.configPath, sci);
    expect(plan.ambiguous, isEmpty);
    expect(
      plan.unmatched,
      ['SCI 999'],
      reason: 'a room on disk that is not on this plan is worth saying',
    );
  });

  test('two files claiming one room are refused, not guessed between', () {
    writeRoom('real.json', building: 'SCI', number: '125');
    writeRoom('working_copy.json', building: 'SCI', number: '125');

    final plan = planRoomAttachments(
      lines: [line('manual1', 'SCI 125')],
      drawn: findDrawnRooms(dir),
    );

    expect(plan.matches, isEmpty, reason: 'a coin toss is not an answer');
    expect(plan.ambiguous, hasLength(1));
    expect(plan.ambiguous.single, contains('SCI 125'));
    expect(plan.ambiguous.single, contains('real.json'));
    expect(plan.ambiguous.single, contains('working_copy.json'));
  });

  test('the room code is compared the way two systems spell it', () {
    writeRoom('a.json', building: 'sci', number: '125');

    final plan = planRoomAttachments(
      lines: [line('manual1', '  SCI   125 ')],
      drawn: findDrawnRooms(dir),
    );
    expect(plan.matches, hasLength(1));
  });

  test('the plan reads as a sentence somebody can answer', () {
    writeRoom('a.json', building: 'SCI', number: '125');
    writeRoom('b.json', building: 'SCI', number: '999');

    final said = describeAttachPlan(
      planRoomAttachments(
        lines: [line('manual1', 'SCI 125')],
        drawn: findDrawnRooms(dir),
      ),
    );
    expect(said, contains('1 line item'));
    expect(said, contains('match no line item'));
  });
}
