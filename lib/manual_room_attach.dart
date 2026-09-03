import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'building_project.dart' show ManualRoom;
import 'project_estimate.dart' show roomCodeFromConfig;

/// ============================================================================
///  THE ESTIMATES THAT HAVE BECOME ROOMS
/// ============================================================================
///  A refresh plan starts as four hundred line items and ends, one room at a
///  time over three years, as four hundred drawn rooms. Every one of those
///  swaps used to be a file picker: press Swap on the line, navigate to the
///  config, pick it, repeat. Somebody who has just drawn eleven rooms in the
///  science block is doing that eleven times, and the eleventh time is the one
///  where the wrong file gets picked.
///
///  The rooms name themselves. A config carries its building and room number
///  in SYSTEM_SETUP - see [roomCodeFromConfig] - and a line item is called
///  'SCI 125'. So a folder of configs can be read and matched against the plan
///  in one pass, and the swaps offered as a list somebody checks once.
///
///  MATCHED ON THE ROOM CODE THE CONFIG STATES, not on the file name. A file
///  called `sci125_final_v2.json` is still SCI 125 and a file called
///  `SCI 125.json` that was saved from the wrong room is not. The name of a
///  file is the one fact about it nobody maintains.
///
///  AMBIGUITY IS NOT RESOLVED, IT IS REFUSED. Two configs claiming SCI 125 is
///  somebody's working copy sitting beside the real one, and picking either is
///  a coin toss that ends with a plan pointing at a draft. Both are reported
///  and neither is attached; the file picker on the line is still there for
///  the reader who knows which.
///
///  NOTHING HERE WRITES. See `attachDrawnRooms` in save_actions.dart.
/// ============================================================================

/// One config found on disk, and the room code it states.
typedef DrawnRoom = ({String configPath, String roomCode});

/// A line item and the config that is plainly the same room.
typedef RoomAttachment = ({ManualRoom line, String configPath});

/// What scanning a folder against a plan comes to.
typedef AttachPlan = ({
  /// The swaps that can be made without anybody choosing anything.
  List<RoomAttachment> matches,

  /// Room codes more than one config claims, with the files, as
  /// 'SCI 125: a.json, b.json'. Reported and skipped.
  List<String> ambiguous,

  /// Configs whose room code matches no line item on this plan. Usually a room
  /// that was already on the job, and worth saying so rather than leaving the
  /// reader to wonder why the count is short.
  List<String> unmatched,
});

/// Compared the way two systems that punctuate a room number differently
/// would have to be.
String _key(String name) =>
    name.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');

/// Every room config under [folder], with the room code each one states.
///
/// Recursive, because a campus folder is a folder per building. Project and
/// campus files live in the same trees and are skipped by shape rather than by
/// name: a room config has a SYSTEM_SETUP block and nothing else does.
List<DrawnRoom> findDrawnRooms(Directory folder) {
  final out = <DrawnRoom>[];
  if (!folder.existsSync()) return out;
  for (final entry in folder.listSync(recursive: true, followLinks: false)) {
    if (entry is! File) continue;
    if (path.extension(entry.path).toLowerCase() != '.json') continue;
    Map<String, dynamic> config;
    try {
      final read = jsonDecode(entry.readAsStringSync());
      if (read is! Map) continue;
      config = Map<String, dynamic>.from(read);
    } catch (_) {
      // A file that will not parse is not a room. Reading a folder should
      // never be the thing that throws.
      continue;
    }
    if (config['SYSTEM_SETUP'] is! Map) continue;
    final code = roomCodeFromConfig(config).trim();
    if (code.isEmpty) continue;
    out.add((configPath: entry.path, roomCode: code));
  }
  return out;
}

/// Works out which line items have been drawn. Nothing is written.
AttachPlan planRoomAttachments({
  required List<ManualRoom> lines,
  required List<DrawnRoom> drawn,
}) {
  final byCode = <String, List<String>>{};
  for (final room in drawn) {
    byCode.putIfAbsent(_key(room.roomCode), () => []).add(room.configPath);
  }

  final matches = <RoomAttachment>[];
  final ambiguous = <String>[];
  final claimed = <String>{};

  for (final line in lines) {
    final files = byCode[_key(line.name)];
    if (files == null || files.isEmpty) continue;
    claimed.add(_key(line.name));
    if (files.length > 1) {
      ambiguous.add(
        '${line.name}: ${files.map(path.basename).join(', ')}',
      );
      continue;
    }
    matches.add((line: line, configPath: files.single));
  }

  final unmatched = [
    for (final code in byCode.keys)
      if (!claimed.contains(code)) code,
  ]..sort();

  return (matches: matches, ambiguous: ambiguous, unmatched: unmatched);
}

/// The plan as a sentence, for the dialog that asks whether to apply it.
String describeAttachPlan(AttachPlan plan) => [
  plan.matches.isEmpty
      ? 'No line item on this plan has been drawn yet'
      : '${plan.matches.length} line item'
            '${plan.matches.length == 1 ? '' : 's'} have a room drawn for them',
  if (plan.ambiguous.isNotEmpty)
    '${plan.ambiguous.length} claimed by more than one file',
  if (plan.unmatched.isNotEmpty)
    '${plan.unmatched.length} room${plan.unmatched.length == 1 ? '' : 's'} on '
        'disk match no line item',
].join('  ·  ');
